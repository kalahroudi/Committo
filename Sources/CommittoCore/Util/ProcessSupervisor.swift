import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ShellFailure: Error, LocalizedError, Sendable {
    case timedOut(command: String, seconds: Double)
    case outputLimit(command: String, bytes: Int)
    public var errorDescription: String? {
        switch self {
        case .timedOut(let c, let s): return "`\(c)` timed out after \(Int(s)) s and was stopped"
        case .outputLimit(let c, let b): return "`\(c)` produced more than \(b / 1_048_576) MB of output and was stopped"
        }
    }
}

/// Owns every child process Committo starts.
///
/// - Each child leads its own process group, so cancel, timeout, output overflow and app quit
///   signal the whole tree (agents and `act` spawn trees; killing only the direct child orphans them).
/// - Termination is SIGTERM, then SIGKILL after `killGrace` if anything is still alive.
/// - When the direct child exits, any stragglers in its group are killed; nothing a supervised
///   command started outlives it. Daemons that call `setsid` leave the group and are not touched.
public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared = ProcessSupervisor()

    public enum Reason: Sendable, Equatable { case none, cancelled, timedOut, outputLimit }
    public struct Exit: Sendable { public let status: Int32; public let reason: Reason }

    /// Time between SIGTERM and SIGKILL.
    public var killGrace: TimeInterval = 2

    private let lock = NSLock()
    private var runs: [pid_t: Run] = [:]
    private let spawnLock = NSLock()

    private init() { signal(SIGPIPE, SIG_IGN) }

    /// Children currently running. Returns to its baseline after every operation (process hygiene tests).
    public var liveCount: Int { lock.lock(); defer { lock.unlock() }; return runs.count }

    /// Kills every supervised process tree. Called on app quit.
    public func terminateAll() {
        lock.lock(); let all = Array(runs.values); lock.unlock()
        for r in all { r.kill(.cancelled, grace: killGrace) }
    }

    // MARK: Run

    /// Runs `path` to completion. `onOutput(data, isStderr)` is called from background threads;
    /// returning `false` stops the process (used for output caps).
    func execute(path: String, args: [String], cwd: URL?, env: [String: String], stdin: Data?,
                 mergeStderr: Bool, timeout: TimeInterval?,
                 onOutput: @escaping @Sendable (Data, Bool) -> Bool) async throws -> Exit {
        let child = try spawn(path: path, args: args, cwd: cwd, env: env, wantStdin: stdin != nil, merge: mergeStderr)
        let run = Run(pid: child.pid)
        register(run)
        let grace = killGrace

        if let timeout {
            let item = DispatchWorkItem { run.kill(.timedOut, grace: grace) }
            run.timeoutItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }
        if let data = stdin, let fd = child.stdin {
            DispatchQueue.global().async { Self.writeAll(fd, data); close(fd) }
        }
        run.readers.enter()
        DispatchQueue.global().async {
            Self.pump(child.stdout, run) { if !onOutput($0, false) { run.kill(.outputLimit, grace: grace); return false }; return true }
            run.readers.leave()
        }
        if let efd = child.stderr {
            run.readers.enter()
            DispatchQueue.global().async {
                Self.pump(efd, run) { if !onOutput($0, true) { run.kill(.outputLimit, grace: grace); return false }; return true }
                run.readers.leave()
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Exit, Never>) in
                DispatchQueue.global().async {
                    var st: Int32 = 0
                    while waitpid(child.pid, &st, 0) < 0 && errno == EINTR {}
                    run.leaderExited()
                    killpg(child.pid, SIGKILL)          // stragglers in the group
                    run.markFinished()
                    run.readers.wait()
                    run.timeoutItem?.cancel()
                    self.unregister(child.pid)
                    let status: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
                    cont.resume(returning: Exit(status: status, reason: run.reason))
                }
            }
        } onCancel: {
            run.kill(.cancelled, grace: grace)
        }
    }

    private func register(_ r: Run) { lock.lock(); runs[r.pid] = r; lock.unlock() }
    private func unregister(_ pid: pid_t) { lock.lock(); runs[pid] = nil; lock.unlock() }

    // MARK: Spawn

    private struct Spawned { let pid: pid_t; let stdin: Int32?; let stdout: Int32; let stderr: Int32? }

    private func spawn(path: String, args: [String], cwd: URL?, env: [String: String], wantStdin: Bool, merge: Bool) throws -> Spawned {
        // Pipes are created CLOEXEC and spawned under one lock so concurrent spawns never inherit each other's ends.
        spawnLock.lock(); defer { spawnLock.unlock() }
        var inP: [Int32] = [-1, -1], outP: [Int32] = [-1, -1], errP: [Int32] = [-1, -1]
        func closeAll() { for fd in inP + outP + errP where fd >= 0 { close(fd) } }
        func mk(_ p: inout [Int32]) throws {
            guard pipe(&p) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for fd in p { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        do { try mk(&outP); if !merge { try mk(&errP) }; if wantStdin { try mk(&inP) } } catch { closeAll(); throw error }

        #if canImport(Darwin)
        var fa: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var fa = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }

        if wantStdin { posix_spawn_file_actions_adddup2(&fa, inP[0], 0) } else { posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_adddup2(&fa, merge ? outP[1] : errP[1], 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&fa, cwd.path) }

        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGPIPE)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: Int(POSIX_SPAWN_SETPGROUP) | Int(POSIX_SPAWN_SETSIGDEF)))

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &fa, &attr, argv, envp)
        guard rc == 0 else { closeAll(); throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO) }
        // Parent keeps the read end of out/err and the write end of in.
        close(outP[1]); if errP[1] >= 0 { close(errP[1]) }; if inP[0] >= 0 { close(inP[0]) }
        return Spawned(pid: pid, stdin: wantStdin ? inP[1] : nil, stdout: outP[0], stderr: merge ? nil : errP[0])
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    /// Reads until EOF. If the direct child is gone and something (a daemon) still holds the pipe, gives up after a grace period.
    private static func pump(_ fd: Int32, _ run: Run, _ sink: (Data) -> Bool) {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 100)
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { if run.leaderGone(for: 3) { break }; continue }
            let n = read(fd, &buf, buf.count)
            if n > 0 { if !sink(Data(buf[0..<n])) { break } }
            else if n == 0 { break }
            else if errno != EINTR && errno != EAGAIN { break }
        }
        close(fd)
    }
}

/// State of one supervised process.
final class Run: @unchecked Sendable {
    let pid: pid_t
    let readers = DispatchGroup()
    var timeoutItem: DispatchWorkItem?
    private let lock = NSLock()
    private var _reason = ProcessSupervisor.Reason.none
    private var finished = false
    private var exitedAt: Date?

    init(pid: pid_t) { self.pid = pid }

    var reason: ProcessSupervisor.Reason { lock.lock(); defer { lock.unlock() }; return _reason }

    /// SIGTERM the group now, SIGKILL after `grace` if the leader is still running. First reason wins.
    func kill(_ r: ProcessSupervisor.Reason, grace: TimeInterval) {
        lock.lock()
        if finished || _reason != .none { lock.unlock(); return }
        _reason = r
        lock.unlock()
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            lock.lock(); let done = finished; lock.unlock()
            if !done { killpg(pid, SIGKILL) }
        }
    }
    func leaderExited() { lock.lock(); exitedAt = Date(); lock.unlock() }
    func markFinished() { lock.lock(); finished = true; lock.unlock() }
    func leaderGone(for seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = exitedAt else { return false }
        return Date().timeIntervalSince(t) > seconds
    }
}
