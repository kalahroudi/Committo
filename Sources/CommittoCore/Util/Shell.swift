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

private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let emit: @Sendable (String) -> Void
    init(_ emit: @escaping @Sendable (String) -> Void) { self.emit = emit }
    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(d)
        while let nl = pending.firstIndex(of: 0x0A) {
            emit(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending = Data(pending[pending.index(after: nl)...])
        }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { emit(String(decoding: pending, as: UTF8.self)); pending = Data() }
    }
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

    static func makeProcess(_ exe: String, _ args: [String], cwd: URL?, env: [String: String]) throws -> Process {
        guard let path = which(exe) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "`\(exe)` not found in PATH"]) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = searchPath.joined(separator: ":")
        e["GIT_TERMINAL_PROMPT"] = "0"
        e["LC_ALL"] = "en_US.UTF-8"
        for (k, v) in env { e[k] = v }
        p.environment = e
        return p
    }

    @discardableResult
    public static func run(_ exe: String, _ args: [String], cwd: URL? = nil,
                           env: [String: String] = [:], stdin: String? = nil) async throws -> ShellResult {
        let p = try makeProcess(exe, args, cwd: cwd, env: env)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        let ob = Buffer(), eb = Buffer()
        out.fileHandleForReading.readabilityHandler = { ob.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { eb.append($0.availableData) }
        return try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                ob.append(out.fileHandleForReading.readDataToEndOfFile())
                eb.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: ShellResult(status: proc.terminationStatus, stdout: ob.string, stderr: eb.string))
            }
            do {
                try p.run()
                if let s = stdin {
                    inp.fileHandleForWriting.write(Data(s.utf8))
                    try? inp.fileHandleForWriting.close()
                }
            } catch { cont.resume(throwing: error) }
        }
    }

    /// Like `run` but throws `ShellError` on non-zero exit.
    public static func check(_ exe: String, _ args: [String], cwd: URL? = nil,
                             env: [String: String] = [:], stdin: String? = nil) async throws -> String {
        let r = try await run(exe, args, cwd: cwd, env: env, stdin: stdin)
        guard r.ok else { throw ShellError(command: ([exe] + args).joined(separator: " "), result: r) }
        return r.stdout
    }

    /// Streams stdout line by line (stderr merged). Cancelling the consumer terminates the process.
    public static func stream(_ exe: String, _ args: [String], cwd: URL? = nil,
                              env: [String: String] = [:], stdin: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            do {
                let p = try makeProcess(exe, args, cwd: cwd, env: env)
                let pipe = Pipe(), inp = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
                let splitter = LineSplitter { cont.yield($0) }
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty else { return }
                    splitter.feed(d)
                }
                p.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    splitter.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                    splitter.finish()
                    if proc.terminationStatus == 0 { cont.finish() }
                    else { cont.finish(throwing: ShellError(command: ([exe] + args).joined(separator: " "),
                                                            result: ShellResult(status: proc.terminationStatus, stdout: "", stderr: "exit \(proc.terminationStatus)"))) }
                }
                cont.onTermination = { _ in if p.isRunning { p.terminate() } }
                try p.run()
                if let s = stdin { inp.fileHandleForWriting.write(Data(s.utf8)); try? inp.fileHandleForWriting.close() }
            } catch { cont.finish(throwing: error) }
        }
    }
}
