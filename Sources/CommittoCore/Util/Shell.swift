import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var ok: Bool { status == 0 }
}

public struct ShellError: Error, LocalizedError, Sendable {
    public let command: String
    public let result: ShellResult
    public var errorDescription: String? {
        let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command)` failed (\(result.status)): \(msg.isEmpty ? result.stdout : msg)"
    }
}

/// Collects stdout/stderr up to a combined byte cap; `append` returns false once the cap is exceeded.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ d: Data, stderr: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if out.count + err.count + d.count > limit { return false }
        if stderr { err.append(d) } else { out.append(d) }
        return true
    }
    var strings: (String, String) { lock.lock(); defer { lock.unlock() }; return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)) }
}

public enum Shell {
    /// GUI apps inherit a minimal PATH; add the usual tool locations.
    public static var searchPath: [String] {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                     "\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.cargo/bin"]
        let current = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (current + extra).filter { seen.insert($0).inserted }
    }

    public static func which(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in searchPath {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func resolve(_ exe: String) throws -> String {
        guard let path = which(exe) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "`\(exe)` not found in PATH"]) }
        return path
    }

    static func environment(_ extra: [String: String]) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = searchPath.joined(separator: ":")
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["LC_ALL"] = "en_US.UTF-8"
        for (k, v) in extra { e[k] = v }
        return e
    }

    /// Runs a command to completion under the process supervisor.
    /// Cancelling the calling task, exceeding `timeout`, or producing more than `maxOutput` bytes kills the whole process tree.
    @discardableResult
    public static func run(_ exe: String, _ args: [String], cwd: URL? = nil,
                           env: [String: String] = [:], stdin: String? = nil,
                           timeout: TimeInterval? = nil, maxOutput: Int = 64 << 20) async throws -> ShellResult {
        let path = try resolve(exe)
        let cap = Capture(limit: maxOutput)
        let exit = try await ProcessSupervisor.shared.execute(
            path: path, args: args, cwd: cwd, env: environment(env), stdin: stdin.map { Data($0.utf8) },
            mergeStderr: false, timeout: timeout) { cap.append($0, stderr: $1) }
        let command = ([exe] + args).joined(separator: " ")
        switch exit.reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ShellFailure.timedOut(command: command, seconds: timeout ?? 0)
        case .outputLimit: throw ShellFailure.outputLimit(command: command, bytes: maxOutput)
        case .none:
            let (o, e) = cap.strings
            return ShellResult(status: exit.status, stdout: o, stderr: e)
        }
    }

    /// Like `run` but throws `ShellError` on non-zero exit.
    public static func check(_ exe: String, _ args: [String], cwd: URL? = nil,
                             env: [String: String] = [:], stdin: String? = nil,
                             timeout: TimeInterval? = nil, maxOutput: Int = 64 << 20) async throws -> String {
        let r = try await run(exe, args, cwd: cwd, env: env, stdin: stdin, timeout: timeout, maxOutput: maxOutput)
        guard r.ok else { throw ShellError(command: ([exe] + args).joined(separator: " "), result: r) }
        return r.stdout
    }

    /// Streams stdout and stderr (merged) line by line without buffering the output.
    /// Ending the consumer (break, cancel, deinit) kills the whole process tree.
    public static func stream(_ exe: String, _ args: [String], cwd: URL? = nil,
                              env: [String: String] = [:], stdin: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let splitter = RecordSplitter { data, truncated in cont.yield(String(decoding: data, as: UTF8.self) + (truncated ? " …[line truncated]" : "")) }
            let task = Task {
                do {
                    let path = try resolve(exe)
                    let exit = try await ProcessSupervisor.shared.execute(
                        path: path, args: args, cwd: cwd, env: environment(env), stdin: stdin.map { Data($0.utf8) },
                        mergeStderr: true, timeout: nil) { d, _ in splitter.feed(d); return true }
                    splitter.finish()
                    if exit.reason == .cancelled || exit.status == 0 { cont.finish() }
                    else { cont.finish(throwing: ShellError(command: ([exe] + args).joined(separator: " "),
                                                            result: ShellResult(status: exit.status, stdout: "", stderr: "exit \(exit.status)"))) }
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams stdout split on `separator` (stderr is kept aside for the error). Records are bounded by `maxRecord`.
    /// Ending the consumer kills the whole process tree, so a caller that has enough can just stop iterating.
    public static func records(_ exe: String, _ args: [String], cwd: URL? = nil, env: [String: String] = [:],
                               separator: UInt8 = 0x0A, maxRecord: Int = 1 << 20) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let splitter = RecordSplitter(separator: separator, maxRecord: maxRecord) { data, _ in cont.yield(data) }
            let errTail = Capture(limit: 64 << 10)
            let task = Task {
                do {
                    let path = try resolve(exe)
                    let exit = try await ProcessSupervisor.shared.execute(
                        path: path, args: args, cwd: cwd, env: environment(env), stdin: nil, mergeStderr: false, timeout: nil) { d, isErr in
                        if isErr { _ = errTail.append(d, stderr: true) } else { splitter.feed(d) }
                        return true
                    }
                    splitter.finish()
                    if exit.reason == .cancelled || exit.status == 0 { cont.finish() }
                    else {
                        cont.finish(throwing: ShellError(command: ([exe] + args).joined(separator: " "),
                                                         result: ShellResult(status: exit.status, stdout: "", stderr: errTail.strings.1)))
                    }
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
