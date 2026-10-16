<p align="center">
  <img src="docs/assets/logo.svg" width="128" alt="Committo logo">
</p>

<h1 align="center">Committo</h1>

<p align="center">
  A native macOS git companion for people who build with AI agents.<br>
  Menu-bar popover · built-in diff &amp; merge with AI help · PRs and issues with local CI and agent review · every feature exposed over MCP.
</p>

<p align="center">
  <a href="https://kalahroudi.github.io/Committo/">Live preview</a> ·
  <a href="design/SPEC.md">Spec</a> ·
  <a href="design/mockup/index.html">Mockup</a> ·
  <a href="design/COVERAGE.md">Coverage</a> ·
  <a href="design/GIT-OPERATIONS.md">Git operations</a> ·
  <a href="LICENSE">Apache 2.0</a>
</p>

## Prompt for coding agents

Paste this into Claude Code, Codex, Cursor or any agent that has access to this repo on a Mac.

```text
You are continuing development of Committo, a native macOS git client (Swift 5.9+, SwiftUI, macOS 14+).

Read first, in order: README.md (status table), design/SPEC.md (product + technical spec),
design/mockup/index.html (approved screens; open in a browser), Package.swift.

Ground rules
- Modules: CommittoCore (Foundation-only; must build and test on Linux and macOS), Committo (SwiftUI app,
  macOS only), committo-cli. Keep UI logic out of Core.
- Run `swift build && swift test` before every commit. Do not mark work done on code you have not compiled.
- Every user-facing action goes through the single action registry (SPEC section 11) so it is automatically
  a button, a command-palette entry and an MCP tool, with a JSON schema and a risk tier (read/write/destructive).
  Destructive tools stay disabled for agents by default.
- Never embed secrets or OAuth client secrets. Tokens live in the Keychain.
- AI features are read-only until the user clicks Apply. Show what context will be sent on first use.
- Shell out to the system `git`; do not reimplement git.
- Work in small PRs against `main`. `main` is protected: open a PR, wait for CI (core-linux, app-macos), sign commits.

Current state: CommittoCore, the CLI and the MCP server are compiled and tested (16 tests, incl. a live SecurityCage install/update/rollback). The SwiftUI app, the
menu-bar item, the LAN CI server and the icon script were written but never compiled; start with milestone M0
(SPEC section 14): build on a Mac, fix compile errors, launch the app, verify the popover and main window.

Then proceed M1 to M6 in order. After each milestone update the status table in README.md and add tests for any
logic that does not need a UI. Ask before changing anything under design/SPEC.md sections 1 and 11.
```

## Screenshots

These are mockups of the intended UI (see [design/mockup](design/mockup/index.html)); the app is not shipped yet.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/popover.png" alt="Menu-bar popover"><br><sub><b>Menu-bar popover</b>: PR and issue counters for your most active repos</sub></td>
    <td width="50%"><img src="docs/screenshots/merge.png" alt="Merge tool with AI help"><br><sub><b>Diff &amp; merge</b>: 3-way merge with an AI link</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/prs.png" alt="Pull request with local CI and agent review"><br><sub><b>Pull requests</b>: local CI, agent review, agent test, security</sub></td>
    <td><img src="docs/screenshots/new.png" alt="New repository wizard"><br><sub><b>New repo</b>: main branch, rules, license, README, CI</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/changes.png" alt="Changes and commit"><br><sub><b>Changes</b>: line-level staging, AI commit message, signing</sub></td>
    <td><img src="docs/screenshots/lens.png" alt="Agent Lens"><br><sub><b>Agent Lens</b>: what every agent is doing, live</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/mcp.png" alt="MCP surface"><br><sub><b>MCP</b>: every feature as a tool, with risk tiers</sub></td>
    <td><img src="docs/screenshots/settings.png" alt="Updates and signing"><br><sub><b>Settings</b>: self-update, signing, accounts</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/history.png" alt="History and graph"><br><sub><b>History</b>: lane graph, agent and signature badges</sub></td>
    <td><img src="docs/screenshots/branches.png" alt="Branches and stacks"><br><sub><b>Branches</b>: stacks, stash, worktrees, compare</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/insights.png" alt="Insights and security"><br><sub><b>Insights</b>: activity, authorship, hotspots, security</sub></td>
    <td><img src="docs/screenshots/integrations.png" alt="Accounts, agents and CI runners"><br><sub><b>Integrations</b>: accounts, agents, LAN CI runners</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/first.png" alt="First run and command bar"><br><sub><b>First run</b> and the plain-language ⌘K bar</sub></td>
    <td></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/mergeviz.png" alt="Merge preview"><br><sub><b>Merge preview</b>: see how commits land on main before you merge</sub></td>
    <td><img src="docs/screenshots/releases.png" alt="Tags and releases"><br><sub><b>Releases</b>: tags, notes, artifacts, one-click publish</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/ci.png" alt="CI live board"><br><sub><b>CI live</b>: every run on every runner, in one place</sub></td>
    <td><img src="docs/screenshots/securitycage.png" alt="SecurityCage setup"><br><sub><b>SecurityCage</b>: one-click pinned install, updates, auto PR scans</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/rebase.png" alt="Interactive rebase"><br><sub><b>Interactive rebase</b>: plan on the left, result on the right</sub></td>
    <td><img src="docs/screenshots/rewrite.png" alt="Reset and force push"><br><sub><b>Reset and force push</b>: backups, leases, recovery</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/tailscale.png" alt="Tailscale runners"><br><sub><b>Tailscale</b>: turn any of your machines into a CI runner, set up by the app</sub></td>
    <td></td>
  </tr>
</table>

A native macOS (SwiftUI, macOS 14+) git companion that lives in your menu bar, built for people who code with agents.

- **Menu-bar popover** (NSPopover, so it has the native arrow pointing at the icon): recent repos with branch / dirty / ahead-behind, hover actions (Terminal, editor, Finder), quick tiles (Open, Clone, Fetch all, Lens, Scan, CI), live agent strip.
- **Main window**: Changes (line/hunk staging, AI commit messages), History (lane-routed commit graph), Branches / stashes / worktrees / tags, Reflog "Time Machine", ⌘K command palette, ⌘Z undo of the last history change.
- **Agent Lens** (built for agents): every branch/worktree attributed to Claude, Codex, Cursor, Copilot, Gemini, Aider, Command Code, Devin…, with live "working" pulse, commit timeline, churn bars. Dispatch an agent into its own worktree and watch tool calls stream in.
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
swift test             # 16 tests incl. real-git integration; COMMITTO_NETWORK_TESTS=1 adds the live SecurityCage test
Scripts/bundle.sh      # macOS: universal Committo.app in ./dist (generates the icon)
```

`CommittoCore` is Foundation-only and builds/tests on Linux; the SwiftUI app is macOS-only.

## Status — read this

| Area | State |
|---|---|
| CommittoCore, `committo` CLI, MCP server, tests | **Compiled and tested** (Swift 6.0.3, Linux): 16/16 pass |
| SecurityCage installer (pin, verify, self-test, update, rollback), scan, MCP tools | **Compiled and tested live** against github.com/kalahroudi/securitycage; UI is mock only |
| SwiftUI app, status item, icon script, `CIServer` (Network.framework) | **Written and syntax-checked only — never compiled or run.** Expect compile fixes and layout polish on first `swift build` on a Mac |
| Tailscale CI runners | Mock and spec only; not tested against a real tailnet |
| Bitbucket / Azure DevOps / Gitea | Auth + clone only; PR API not implemented |
| Interactive rebase, conflict wizard, LFS, git-flow, SSH/GPG UI, submodule UI, file history/blame UI, branch comparison, patch export UI | Engine has some (blame, submodules, patch export, worktrees); UI not built |
| Advanced workflows: stacked branches, automatic branch cleanup, PR-based merge detection, self-hosted provider presets | Not started |
| Agent CLI flags (Codex, Gemini, Aider, Command Code, dsh) | Defaults are best guesses — verify with each tool's `--help` |
| LAN CI runner | HTTP + token only (no TLS); remote runs need the work pushed to `origin` |

## Git feature coverage

Done/partial: clone & accounts, status w/ diffs, hunk staging, commit/amend, AI commit messages, discard, ignore, stash, branches/tags/remotes, merge/rebase/cherry-pick/revert, force-with-lease, history search, undo, reflog, worktrees, submodules (engine), dark mode, command-line tool, PRs (GitHub/GitLab).
Missing: line-level staging, conflict wizard, interactive rebase, git-flow, LFS, profiles, external diff, signing UI, 1Password SSH agent, groups/tags for repos, multiple windows, git-svn.

## Share the mockup (GitHub Pages)

The site lives in `docs/`: a landing page with all screenshots (`docs/index.html`) and the clickable mockup as a standalone page (`docs/demo/`). To publish it once:

1. GitHub: **Settings → Pages → Build and deployment → Source: Deploy from a branch**, branch `main`, folder `/docs`.
2. After a minute it is live at **https://kalahroudi.github.io/Committo/** (mockup at `/demo/`).

After editing `design/mockup/index.html`, run `python3 Scripts/build-pages.py` to refresh `docs/demo/index.html` before committing.

## License

Apache License 2.0. See [LICENSE](LICENSE).
