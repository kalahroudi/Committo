import Foundation

public struct PRRisk: Sendable { public let score: Int; public let level: String; public let reasons: [String] }

public struct PRDeepDive: Sendable {
    public let pr: PullRequest
    public let files: [PRFile]
    public let checks: [CheckRun]
    public let findings: [Finding]
    public let risk: PRRisk
    public var agentReview: String?
}

public enum PRAnalyzer {
    /// Security scan + risk model over the provider's PR file patches. Pure and offline.
    public static func analyze(pr: PullRequest, files: [PRFile], checks: [CheckRun]) -> PRDeepDive {
        let diffs: [FileDiff] = files.compactMap { f in
            guard let p = f.patch else { return nil }
            return GitParse.diff("diff --git a/\(f.filename) b/\(f.filename)\n--- a/\(f.filename)\n+++ b/\(f.filename)\n" + p).first
        }
        var findings = SecurityScanner().scan(diff: diffs)
        // Files without a patch (too large / binary) can't be scanned: say so rather than imply they're clean.
        for f in files where f.patch == nil && f.status != "removed" {
            findings.append(.init(rule: "scan.skipped", title: "Not scanned (no patch available)", severity: .info, file: f.filename, line: 0, snippet: "", advice: "Review manually or fetch locally."))
        }
        return PRDeepDive(pr: pr, files: files, checks: checks, findings: findings, risk: risk(pr: pr, files: files, checks: checks, findings: findings))
    }

    static func risk(pr: PullRequest, files: [PRFile], checks: [CheckRun], findings: [Finding]) -> PRRisk {
        var score = 0; var why: [String] = []
        let churn = files.reduce(0) { $0 + $1.additions + $1.deletions }
        if churn > 1000 { score += 25; why.append("Very large change (\(churn) lines)") } else if churn > 400 { score += 12; why.append("Large change (\(churn) lines)") }
        if files.count > 30 { score += 10; why.append("\(files.count) files touched") }
        let hasTests = files.contains { $0.filename.lowercased().contains("test") || $0.filename.lowercased().contains("spec") }
        if !hasTests && churn > 100 { score += 12; why.append("No test changes") }
        let sensitive = files.filter { f in [".github/workflows", "Dockerfile", "auth", "payment", "migration", "secrets", "Package.swift", "package.json"].contains { f.filename.contains($0) } }
        if !sensitive.isEmpty { score += 10; why.append("Touches sensitive paths: \(sensitive.prefix(3).map(\.filename).joined(separator: ", "))") }
        let crit = findings.filter { $0.severity >= .high }.count
        if crit > 0 { score += min(40, crit * 15); why.append("\(crit) high/critical security finding(s)") }
        let failing = checks.filter { $0.conclusion == "failure" || $0.conclusion == "timed_out" }.count
        if failing > 0 { score += 15; why.append("\(failing) failing check(s)") }
        if pr.isDraft { why.append("Draft") }
        score = min(score, 100)
        return PRRisk(score: score, level: score >= 60 ? "High" : score >= 30 ? "Medium" : "Low", reasons: why)
    }

    public static func reviewPrompt(_ d: PRDeepDive) -> String {
        let patches = d.files.prefix(40).map { "### \($0.filename) (\($0.status), +\($0.additions)/-\($0.deletions))\n```diff\n\(($0.patch ?? "(no patch)").prefix(6000))\n```" }.joined(separator: "\n\n")
        let sec = d.findings.prefix(25).map { "- [\($0.severity.label)] \($0.title) @ \($0.file):\($0.line)" }.joined(separator: "\n")
        return """
        You are a senior engineer reviewing pull request #\(d.pr.number) "\(d.pr.title)" by @\(d.pr.author) (\(d.pr.headRef) → \(d.pr.baseRef)).
        Description:
        \(d.pr.body.prefix(3000))

        Static scan flagged:
        \(sec.isEmpty ? "(nothing)" : sec)

        Review for: correctness bugs, security issues, concurrency/data-loss risks, missing tests, API/behaviour breaks.
        Be concrete: cite file and line, explain the failure scenario, suggest a fix. Skip style nits.
        Finish with a verdict line: APPROVE, REQUEST_CHANGES, or COMMENT, and a 2-sentence summary.

        \(patches)
        """
    }
}
