import Foundation

public enum LFSMode: Sendable, Equatable {
    case now                    // let git-lfs download during checkout (the default)
    case onDemand               // clone with pointer files; fetch later
    case paths([String])        // clone with pointer files, then `git lfs pull --include`
}

public struct CloneOptions: Sendable, Equatable {
    public var branch: String?
    public var depth: Int?
    public var filter: String?              // e.g. "blob:none"
    public var sparsePaths: [String] = []
    public var lfs: LFSMode = .now
    public var submodules = true
    public var shallowSubmodules = false
    public var jobs = 4
    public var sshToHTTPS = false           // rewrite SSH submodule URLs for this clone only
    public var gitConfig: [String: String] = [:]
    public init() {}
}

public enum SubmoduleState: String, Sendable, Equatable { case clean, outOfDate, uninitialised, conflicting }

public struct SubmoduleStatus: Sendable, Equatable {
    public let path: String, state: SubmoduleState, commit: String
}

/// Result for one top-level submodule; a failure here never stops the others.
public struct SubmoduleResult: Sendable, Equatable {
    public let path: String
    public let error: String?
    public var ok: Bool { error == nil }
}

public enum CloneEvent: Sendable, Equatable {
    case progress(String)
    case lfsDetected(gitLFSInstalled: Bool)
    case submodule(SubmoduleResult)
    case finished(failedSubmodules: [String])
}

public enum Clone {
    /// Clones `remote` into `dest`. Cancelling the consuming task kills git and removes a destination this call created.
    public static func run(_ remote: String, into dest: URL, options: CloneOptions = CloneOptions()) -> AsyncThrowingStream<CloneEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                let fm = FileManager.default
                let existed = fm.fileExists(atPath: dest.path)
                if existed, let kids = try? fm.contentsOfDirectory(atPath: dest.path), !kids.isEmpty {
                    cont.finish(throwing: CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(dest.path) already exists and is not empty"]))
                    return
                }
                func cleanup() { if !existed { try? fm.removeItem(at: dest) } else if let k = try? fm.contentsOfDirectory(atPath: dest.path) { for n in k { try? fm.removeItem(at: dest.appendingPathComponent(n)) } } }
                do {
                    var env: [String: String] = [:]
                    if options.lfs != .now { env["GIT_LFS_SKIP_SMUDGE"] = "1" }
                    for try await line in Shell.stream("git", configArgs(options) + cloneArgs(remote, dest, options), env: env) { cont.yield(.progress(line)) }
                    try Task.checkCancellation()
                    let repo = GitRepository(url: dest)

                    if !options.sparsePaths.isEmpty { try await repo.git(["sparse-checkout", "set", "--cone", "--"] + options.sparsePaths) }

                    if await repo.usesLFS() {
                        let installed = Shell.which("git-lfs") != nil
                        cont.yield(.lfsDetected(gitLFSInstalled: installed))
                        if installed, case .paths(let p) = options.lfs, !p.isEmpty { try await repo.lfsPull(include: p) }
                    }

                    var failed: [String] = []
                    if options.submodules {
                        for r in await updateSubmodules(in: repo, paths: nil, options: options) {
                            cont.yield(.submodule(r)); if !r.ok { failed.append(r.path) }
                        }
                    }
                    try Task.checkCancellation()
                    cont.yield(.finished(failedSubmodules: failed))
                    cont.finish()
                } catch {
                    cleanup()
                    if error is CancellationError { cont.finish() } else { cont.finish(throwing: error) }
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Re-runs only the given submodules (the "Retry failed" button).
    public static func retrySubmodules(_ paths: [String], in repo: GitRepository, options: CloneOptions = CloneOptions()) async -> [SubmoduleResult] {
        await updateSubmodules(in: repo, paths: paths, options: options)
    }

    static func updateSubmodules(in repo: GitRepository, paths: [String]?, options: CloneOptions) async -> [SubmoduleResult] {
        var list = paths ?? []
        if paths == nil { list = (try? await repo.submodulePaths()) ?? [] }
        var out: [SubmoduleResult] = []
        for p in list {
            var args = configArgs(options) + ["submodule", "update", "--init", "--recursive", "--jobs", "\(max(1, options.jobs))"]
            if options.shallowSubmodules { args += ["--depth", "1"] }
            args += ["--", p]
            let env = options.lfs == .now ? [:] : ["GIT_LFS_SKIP_SMUDGE": "1"]
            do { _ = try await Shell.check("git", args, cwd: repo.url, env: env); out.append(SubmoduleResult(path: p, error: nil)) }
            catch is CancellationError { break }
            catch let e as ShellError { out.append(SubmoduleResult(path: p, error: e.result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
            catch { out.append(SubmoduleResult(path: p, error: error.localizedDescription)) }
        }
        return out
    }

    static func configArgs(_ o: CloneOptions) -> [String] {
        var cfg = o.gitConfig
        if o.sshToHTTPS {
            for host in ["github.com", "gitlab.com", "bitbucket.org"] {
                cfg["url.https://\(host)/.insteadOf"] = "git@\(host):"
            }
        }
        return cfg.sorted { $0.key < $1.key }.flatMap { ["-c", "\($0.key)=\($0.value)"] }
    }

    static func cloneArgs(_ remote: String, _ dest: URL, _ o: CloneOptions) -> [String] {
        var a = ["clone", "--progress", "--no-recurse-submodules"]
        if let b = o.branch { a += ["--branch", b] }
        if let d = o.depth { a += ["--depth", "\(d)"] }
        if let f = o.filter { a += ["--filter=\(f)"] }
        if !o.sparsePaths.isEmpty { a.append("--sparse") }
        return a + ["--", remote, dest.path]
    }
}

// MARK: Existing repositories
extension GitRepository {
    /// True when any `.gitattributes` on HEAD routes files through the LFS filter.
    public func usesLFS() async -> Bool {
        let r = try? await Shell.run("git", ["grep", "-q", "-e", "filter=lfs", "HEAD", "--", ":(glob)**/.gitattributes"], cwd: url)
        return r?.status == 0
    }

    public func lfsPull(include: [String] = []) async throws {
        var a = ["lfs", "pull"]
        if !include.isEmpty { a.append("--include=" + include.joined(separator: ",")) }
        try await git(a)
    }

    /// Total bytes of LFS objects in HEAD (from `git lfs ls-files --size`), or nil when git-lfs is unavailable.
    public func lfsTotalSize() async -> Int64? {
        guard Shell.which("git-lfs") != nil, let out = try? await git(["lfs", "ls-files", "--size"]) else { return nil }
        return Clone.parseLFSSizes(out)
    }

    public func submodulePaths() async throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".gitmodules").path) else { return [] }
        let out = try await git(["config", "-f", ".gitmodules", "-z", "--get-regexp", #"^submodule\..*\.path$"#])
        return out.split(separator: "\0").compactMap { $0.split(separator: "\n", maxSplits: 1).last.map(String.init) }
    }

    public func submodules() async throws -> [SubmoduleStatus] {
        Clone.parseSubmoduleStatus(try await git(["submodule", "status", "--recursive"]))
    }
}

extension Clone {
    static func parseSubmoduleStatus(_ text: String) -> [SubmoduleStatus] {
        text.split(separator: "\n").compactMap { line in
            guard let flag = line.first else { return nil }
            let rest = line.dropFirst().split(separator: " ", maxSplits: 2)
            guard rest.count >= 2 else { return nil }
            let state: SubmoduleState
            switch flag { case "-": state = .uninitialised; case "+": state = .outOfDate; case "U": state = .conflicting; default: state = .clean }
            return SubmoduleStatus(path: String(rest[1]), state: state, commit: String(rest[0]))
        }
    }

    /// `git lfs ls-files --size` lines end in "(1.2 MB)"; sums them as bytes.
    static func parseLFSSizes(_ text: String) -> Int64 {
        var total = 0.0
        for line in text.split(separator: "\n") {
            guard let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { continue }
            let parts = line[line.index(after: open)..<close].split(separator: " ")
            guard parts.count == 2, let n = Double(parts[0]) else { continue }
            let unit: Double
            switch parts[1].uppercased() {
            case "B": unit = 1
            case "KB": unit = 1_000
            case "MB": unit = 1_000_000
            case "GB": unit = 1_000_000_000
            case "TB": unit = 1_000_000_000_000
            default: continue
            }
            total += n * unit
        }
        return Int64(total)
    }
}
