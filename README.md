# Committo

A native macOS (SwiftUI, macOS 14+) git companion that lives in your menu bar, built for people who code with agents.

- **Menu-bar popover** (NSPopover, so it has the native arrow pointing at the icon): recent repos with branch / dirty / ahead-behind, hover actions (Terminal, editor, Finder), quick tiles (Open, Clone, Fetch all, Lens, Scan, CI), live agent strip.
- **Main window**: Changes (line/hunk staging, AI commit messages), History (lane-routed commit graph), Branches / stashes / worktrees / tags, Reflog "Time Machine", ⌘K command palette, ⌘Z undo of the last history change.
- **Agent Lens** (agent-focused, for agents): every branch/worktree attributed to Claude, Codex, Cursor, Copilot, Gemini, Aider, Command Code, Devin…, with live "working" pulse, commit timeline, churn bars. Dispatch an agent into its own worktree and watch tool calls stream in.
- **PR deep dive**: risk score, offline security scan of added lines, check runs, agent review, post as comment (GitHub + GitLab).
- **Security scan**: secrets, risky code patterns, CI/workflow red flags, sensitive files; OSV.dev client for dependency CVEs.
- **Agents**: Claude Code headless (`claude -p --output-format stream-json`), direct APIs (Anthropic, OpenAI-compatible), CLI adapters (Codex, Gemini CLI, Aider, Command Code, dsh — editable templates), and an **MCP bridge** that wraps any MCP server tool as an agent.
- **MCP server for agents** (`committo mcp`): list repos, status, log, diff, security scan, Agent Lens, create branch, commit (refuses on high-severity findings), CI list/run.
- **Local CI**: [`act`](https://github.com/nektos/act) integration, plus `committo ci-serve` to turn any box on your LAN into a runner (Bonjour-discoverable, bearer-token auth).
- **Auth**: `gh` CLI reuse / `gh auth login --web`, OAuth device flow (GitHub, GitLab; bring your own OAuth client id), PKCE helper for others, personal access tokens for GitHub, GitLab, Bitbucket, Azure DevOps, Gitea. Secrets live in the Keychain.
- Insights: contribution heatmap, contributors, churn hotspots (Swift Charts / Canvas).

## Build

```sh
swift build            # core + CLI on Linux or macOS; app target on macOS only
swift test             # 12 tests, incl. real-git integration
Scripts/bundle.sh      # macOS: universal Committo.app in ./dist (generates the icon)
```

`CommittoCore` is Foundation-only and builds/tests on Linux; the SwiftUI app is macOS-only.

## Status — read this

| Area | State |
|---|---|
| CommittoCore, `committo` CLI, MCP server, tests | **Compiled and tested** (Swift 6.0.3, Linux): 12/12 pass |
| SwiftUI app, status item, icon script, `CIServer` (Network.framework) | **Written and syntax-checked only — never compiled or run.** Expect compile fixes and layout polish on first `swift build` on a Mac |
| Bitbucket / Azure DevOps / Gitea | Auth + clone only; PR API not implemented |
| Interactive rebase, conflict wizard, LFS, git-flow, SSH/GPG UI, submodule UI, file history/blame UI, branch comparison, patch export UI | Engine has some (blame, submodules, patch export, worktrees); UI not built |
| Advanced workflows: stacked branches, automatic branch cleanup, PR-based merge detection, self-hosted provider presets | Not started |
| Agent CLI flags (Codex, Gemini, Aider, Command Code, dsh) | Defaults are best guesses — verify with each tool's `--help` |
| LAN CI runner | HTTP + token only (no TLS); remote runs need the work pushed to `origin` |

## Git feature coverage

Done/partial: clone & accounts, status w/ diffs, hunk staging, commit/amend, AI commit messages, discard, ignore, stash, branches/tags/remotes, merge/rebase/cherry-pick/revert, force-with-lease, history search, undo, reflog, worktrees, submodules (engine), dark mode, command-line tool, PRs (GitHub/GitLab).
Missing: line-level staging, conflict wizard, interactive rebase, git-flow, LFS, profiles, external diff, signing UI, 1Password SSH agent, groups/tags for repos, multiple windows, git-svn.
