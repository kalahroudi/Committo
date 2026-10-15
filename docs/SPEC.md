# Committo — Product & Technical Spec (v0, for approval)

Status: **draft for approval**. The clickable mockup is `docs/mockup/index.html` (also published as an artifact). Nothing here is built beyond what `README.md` lists as done.

## 1. Goals and non-goals

**Goals.** A native macOS git client for people who work with AI agents: fast menu-bar access, first-class PR/issue handling, a built-in diff and merge tool, one-screen repo setup, local CI, and agent workflows (review, test, dispatch) with every feature also available over MCP.

**Non-goals (v1).** Windows/Linux UI, full git-svn, a hosted service, code editing beyond conflict resolution, replacing the provider's web UI for admin tasks.

**Principles.**
1. *Local first.* Reads and checks happen on the machine; the remote is touched only on explicit push/merge.
2. *One action registry.* Every user-visible action is declared once and rendered as a button, a ⌘K entry and an MCP tool (§11).
3. *AI is a link, never a gate.* The ✦ action is available wherever the user may be stuck, always read-only until the user applies a result.
4. *Preview before apply.* Anything that changes a remote or rewrites history shows a plan first.

## 2. Platform and architecture

- macOS 14+, Swift 5.9+/SwiftUI, universal binary. Git is executed through the system `git` CLI (hooks, signing, LFS, credential helpers behave as in a terminal).
- Modules: `CommittoCore` (Foundation-only: git, providers, agents, scan, CI, MCP, action registry), `Committo` (SwiftUI app), `committo` (CLI: `mcp`, `ci-serve`, `scan`).
- Secrets in the macOS Keychain. No telemetry by default.
- Distribution: notarized, Developer ID signed `.app` in a DMG; updates via Sparkle (§12).

## 3. Surfaces

### 3.1 Menu-bar popover (mock 1)
`NSStatusItem` + `NSPopover` (native arrow). Sections: search/jump (⌘K scope: repos, branches, PRs, issues, actions); update banner; tiles (New, Clone, Import, Fetch all, PRs, Issues, Lens, CI); "Needs you" (review requests, failing CI, conflicts across repos); Recent repos (branch, dirty count, ahead/behind, last activity, hover: Terminal/Editor/Finder); Lens strip; footer (Open, Settings, Quit). Status icon shows a badge count of "Needs you".

**Counters.** The "Most active" list ranks repos by recent commits, PR and issue events, and shows two live counters per row: open PRs (accent when one awaits your review, red when CI is failing, faint at zero) and open issues. A 6-point sparkline shows recent activity. Header shows totals across listed repos. Clicking a counter opens that repo's PR or issue list. Counters come from provider APIs (cached, refreshed every 5 min and on popover open) and are exposed as `repo_list` fields over MCP.

### 3.2 Main window
Sidebar groups: Work (Changes, History, Branches), Collaborate (Pull requests, Issues), Agents (Lens), Quality (Security, CI Runners), Explore (Insights, Time Machine). Toolbar: ⌘K, Undo, Fetch, Pull, Push. Multiple windows per repo supported.

### 3.3 First run, Guided mode and ⌘K (mock 13)
First run: six steps (connect account, find repos, pick agent, install MCP, add security scans, set up signing), each skippable and re-runnable from Settings. **Guided mode** (on by default for new users) uses plain labels ("save your work" for commit, "send" for push) and confirms risky actions; off shows standard git names. **⌘K** accepts plain language, maps it to registry actions, and always shows the exact git command before running. Anything it cannot map falls back to "Ask Claude" (read-only suggestion).

### 3.4 Teach mode (mock 13, 14)
A per-user toggle (on for new users, "Teach me / Just merge" on the merge screen). When on, every history-changing action (merge, squash, rebase, cherry-pick, revert, reset, force-push, amend) first shows a **before/after graph** drawn locally from the repo's real commits, with new commits highlighted, replaced commits faded, and a plain-language explanation plus the exact git command. A glossary (commit, parent, branch, main, merge, fast-forward, rebase, HEAD) is one hover away; ✦ "Explain like I'm new" answers follow-ups. For students: **Practice mode** creates a throwaway repo from scenarios (diverged branches, conflict, messy history to clean up) and checks the result. Teach mode never blocks: Just merge hides it.

## 4. Git feature set

Target: a complete desktop git client on macOS. Advanced workflow items (stacked branches, automatic cleanup, PR-based merge detection, self-hosted providers) are tracked in §13.

4.1 **Repos:** create, import (add existing), clone (with background progress), groups/tags, search, worktrees, submodules (init/update/open).
4.2 **Working copy:** flat/tree file list, unified/split diff, hunk and **line-level staging**, discard, ignore, amend, commit templates, gitmoji, signoff, patches (apply/export).
4.3 **Branches/tags/remotes:** create/switch/delete, merge, rebase (incl. `--autostash`), interactive rebase UI (reorder/squash/fixup/reword/drop), compare branches, tracking and unsynced indicators, force-push with lease.
4.4 **History:** lane-routed graph, search by message/author/hash/path, file history, blame, browse revision files, cherry-pick, revert, reset (soft/mixed/hard with preview), export ZIP/patch.
4.5 **Stash:** save (incl. untracked), partial apply, inspect diff, drop.
4.6 **Safety:** Undo (reflog-based, with a plain-language confirm), Reflog "Time Machine" restore to branch, automatic stash on pull/checkout.
4.7 **Flows:** git-flow naming option, LFS auto-detect and track, pull-rebase default option, default branch name setting.
4.8 **Visualization and insights (mock 9, 11):** commit graph with agent and signature badges; activity heatmap; authorship split (human vs each agent); churn hotspots; review health (PR cycle time, first-try merge rate, stale PRs, CI pass rate); security summary. Stacked-branch ladder with PR state (mock 10).

## 5. Diff and merge tool (mock 3)

5.1 **Diff:** unified, split, word-level highlight, moved-line detection, image diff (swipe/onion), binary summary, whitespace toggles, syntax coloring (Tree-sitter grammars bundled for the top ~25 languages, plain fallback).
5.2 **Merge:** 3-way (mine / theirs / editable result) with base available on demand. Per-chunk take mine / theirs / both / neither, gutter arrows, prev/next conflict, file list with resolved state, "Take all mine/theirs" per file, Mark resolved (stages file), Abort. Works for merge, rebase, cherry-pick, revert and stash apply. Handles rename/delete conflicts with a dedicated resolution card.
5.3 **Data model:** conflicts parsed from index stages 1/2/3 (`git show :1:path` etc.), not from marker text, so edits to the result pane never corrupt markers.
5.4 **AI link (✦):** buttons: *Explain change* (diff), *Explain conflict*, *Suggest resolution*, *Resolve file*, *Ask a question*. The agent receives base/mine/theirs hunks plus surrounding code and the commit messages of both sides. Output: plain-English explanation and a proposed result; **Apply to result** is a separate click and is undoable. Backends: Claude Code headless, API agents, MCP-bridged agents (§8). Context sent is limited to the files in the conflict; the first use per repo shows what will be sent.
5.5 **External tools:** optional default to Kaleidoscope, Beyond Compare, VS Code or any command template.
5.6 Acceptance: resolving a 3-conflict file with the built-in tool never leaves marker text in the result; undo restores the pre-resolution state.

## 6. Repo creation, import, setup (mock 5)

6.1 One wizard with three entries: *Create new*, *Add existing* (detects missing pieces and offers them), *Clone*.
6.2 **Main branch:** configurable name (default `main`), initial (optionally signed) commit so rules can attach.
6.3 **Rulesets / protection:** presets (Solo, Team, Strict) → provider-specific payloads, shown as a diff of "what will exist" before apply. Contents: require PR + N approvals, required status checks (auto-filled from generated CI), block force-push/deletion, linear history, optional signed commits, CODEOWNERS review. Applied through the provider API; failures are reported per rule.
6.4 **Generated files (each toggle):** README (templates by project type, optional ✦ draft from a description), LICENSE (SPDX picker, fills name/year), .gitignore (from detected stack; GitHub's templates), CONTRIBUTING, CODEOWNERS, PR/issue templates, SECURITY.md, Dependabot/Renovate config, starter CI workflow, `.gitattributes`/LFS rules, editorconfig.
6.5 **Remote:** create on a connected provider (visibility, owner/org), set origin, push, set upstream.
6.6 **Verify:** run the generated CI locally once with `act` so the first PR isn't the first test.
6.7 **Provider support matrix** shown in the wizard (full / partial / none) so nothing silently fails: GitHub full; GitLab full; Gitea/Forgejo partial (branch protection, no rulesets); Bitbucket (branch restrictions, no rulesets); Azure DevOps (branch policies).

## 7. Pull requests and issues (mock 4)

7.1 **Local copy:** list PRs/issues, fetch `refs/pull/*` (or MR refs), check out into a managed worktree, comment, review (approve/request changes), draft state. Offline browsing of previously synced items.
7.2 **Gates in the PR view:** (a) Local CI (`act`, this Mac or LAN runner), (b) Agent review, (c) Agent test, (d) Security scan, plus provider checks and mergeability. A single "Ready to merge?" card summarises them and respects the repo ruleset (shows what the ruleset still requires).
7.3 **Agent test:** the agent reads the diff, writes tests in a throwaway worktree, runs them, and returns results; user can "Add tests to PR" (commit to the PR branch) or discard.
7.4 **Issues:** list/filter, create, comment, **Issue → agent** (create branch `agent/<n>-<slug>`, worktree, start task with issue text), link PR to issue.
7.5 **Providers:** GitHub and GitLab full; Gitea/Forgejo next; Bitbucket and Azure DevOps read + comment first, then merge. Capabilities are declared per provider and the UI hides unsupported actions.
7.6 **Merge options and preview (mock 14):** merge locally and push, or merge on the provider (merge commit, squash, rebase; auto-merge when checks pass). Choosing an option redraws **what main will look like**: a graph of "now" next to "after", commits that will exist highlighted, commits that stay on the branch faded and dashed, rebased commits annotated with old hash. Under it, six consequence tiles: history shape, what is added to main, hash changes, signature effect (GitHub signs squash/merge commits with its own key and drops signatures on rebase-merge; local merges re-sign with the user's key), how to undo (exact command), bisect/blame granularity. Options forbidden by the ruleset (e.g. "linear history" disables Merge commit) are locked with the reason; the default option is the repo's historical habit (most used in the last N merges), else the provider default. Keys 1/2/3 select, ↩ merges. The preview is computed locally from the PR's commit list and `git merge-tree`/`git cherry` dry-runs; it never waits on the network after the commit list is cached. The same preview component serves rebase, cherry-pick, revert, reset and stash apply.

7.8 **Tags and releases (mock 15):** tag list as a timeline with signed state, commits since previous tag, whether a release exists, download counts. Create (lightweight/annotated/signed), annotate, push, compare tags, delete local/remote, move (with a warning listing who may have fetched it, double confirm). **Release draft:** version bump suggested from conventional commits and PR labels (patch/minor/major, overridable); notes generated and grouped (features, fixes, docs, breaking) with PR links and contributors including agents; ✦ polishes wording; checks (CI green on the commit, no unsigned commits since last tag, security scan, open release-blocker PRs); artifacts (upload, notarization status, checksums); one action to create the signed tag, push, publish the provider release and update the Sparkle appcast (§12). GitHub and GitLab releases first. MCP: `tag_list`, `tag_create`, `tag_push`, `tag_delete` (destructive), `release_draft`, `release_publish` (destructive).

7.9 **CI live status (mock 15):** one board for every runner: This Mac (`act`), LAN machines running `committo ci-serve`, GitHub Actions, GitLab CI and other self-hosted runners. Each run shows repo, workflow/job, ref or PR, **runner and location**, step tree, progress, elapsed and ETA, and a live log tail (streamed locally; polled with backoff for hosted providers, webhooks when a relay is configured). Runner health strip: slots in use, latency, load, queue length. Queued runs explain why (position, plan limits) and offer "run on another runner". Failed runs offer ✦ Explain failure, Fix with agent, re-run failed jobs, reproduce locally. **Status is ambient:** sidebar footer in every window, popover "Live now" card, menu-bar icon spinner (red on failure), PR and repo counters. The same workflow file runs on any runner; switching runner is one click. MCP: `ci_status`, `ci_logs`, `ci_run`, `ci_cancel`, `ci_rerun`.

7.10 **SecurityCage integration (mock 16):** Committo integrates [kalahroudi/securitycage](https://github.com/kalahroudi/securitycage) for PR security scans.
- **Detection and offer:** if SecurityCage is installed, every PR shows its scan card automatically; if not, the card offers "Enable" (one consent) provided Node 22.18+ and npm exist (otherwise a short fix-it hint). Also offered in first run (step 5), the new-repo wizard, and Settings.
- **Install = pin.** The repo has no tags/releases yet, so the pin is a full commit SHA: the latest release if any, else the head of the default branch. Committo downloads that SHA's tarball, records its SHA-256, extracts, runs `npm ci --ignore-scripts --omit=dev --no-audit --no-fund` (same as the project's own GitHub Action), then **self-tests on a known-bad fixture and refuses to activate a build that does not flag it**. Activation is an atomic symlink swap; the previous pin stays on disk for **rollback**. Location: `~/Library/Application Support/Committo/tools/securitycage/<sha>/` with `current`. The npm package named `securitycage` is an unrelated placeholder and must not be used; `install.sh` in that repo installs it and should be fixed upstream.
- **Update:** daily check (GitHub API: release, else commit head), compare with the pin, show commit count and headlines, **ask before updating** by default (auto-update optional), verify, switch, keep old for rollback. Repos whose workflow pins an older SHA get a one-click "open bump PR".
- **Running it:** `plan --json --untrusted --changed <files> --out <cache>` in the PR's worktree (about a second, offline, free). Results are written to Committo's cache, never into the repo. PR code is **always untrusted** (`--untrusted`) so a PR cannot vouch for itself via `securitycage.json`; `--trust-repo-config` only for repos the user owns and approved. Depth levels in the UI: Plan (free), Deep scan (AI with the user's key and a cost cap), Prove (`--prove`, Docker/Podman, confirms exploits in a no-network sandbox, needs `prove init`). Findings (what, why, certainty confirmed/likely/worth-a-look, action, fix prompt) are merged into the PR gate; "Fix with agent" hands the fix prompt to the chosen agent.
- **GitHub Action:** the wizard and "Add workflow" write `.github/workflows/securitycage.yml` using `kalahroudi/securitycage@<pinned SHA>` on `pull_request` (never `pull_request_target`) with least permissions.
- **MCP:** `securitycage_status`, `securitycage_install` (also updates), `securitycage_scan`. CLI: `committo securitycage status|install [sha]|update|rollback|scan <path>`.
- **Status:** the manager, CLI and MCP tools are implemented and tested against the real repo (install, update, rollback, scan); UI is mock only.

## 8. Agents and Lens (mock 6)

8.1 **Attribution:** branch prefix (`claude/`, `codex/`, `cursor/`, `copilot/`, `cmd/`…), `Co-Authored-By` trailers, bot authors. User-extensible rules.
8.2 **Backends:** Claude Code headless (`claude -p --output-format stream-json`, read-only mode uses plan permissions and a git-only tool allowlist); direct APIs (Anthropic, OpenAI-compatible); CLI adapters with editable templates (Codex, Gemini CLI, Aider, Command Code, dsh); **MCP bridge** (any MCP server tool as an agent).
8.3 **Dispatch:** prompt, backend, own worktree (default on), read-only toggle, stop. Live console of tool calls and cost. Results land as a branch visible in Lens.
8.4 **Lens:** per-branch/worktree cards (agent, commits timeline, files, +/−, live state from dirty worktrees), summary chart, review/merge actions.

## 9. Signing

SSH signing (default), GPG, 1Password SSH agent. Wizard: pick/generate key → write git config (`gpg.format`, `user.signingkey`, allowed signers) → upload public key to connected providers. Commit list shows verified/unverified badges. Setting "require signed commits" is also offered in rulesets (§6.3).

## 10. Accounts and auth

`gh` CLI reuse and `gh auth login --web`; OAuth device flow (GitHub, GitLab; user-supplied client id, no embedded secrets); OAuth PKCE via ASWebAuthenticationSession for providers without device flow; personal access tokens for all providers. Keychain storage; per-account scopes shown; git credential helper integration (`gh auth setup-git` or Keychain helper).

## 11. MCP exposure

11.1 **Action registry.** Each action: `id`, title, params schema (JSON Schema), risk tier, handler, UI placement. UI buttons, ⌘K and MCP `tools/list` are generated from it. A unit test fails the build if an action lacks a schema or tier. Result: *all features are MCP-exposed by construction.*
11.2 **Tiers:** read, write, destructive. Destructive (force-push, remote merge, rule apply, branch/repo delete, hard reset) are disabled for agents by default and always require in-app confirmation when enabled.
11.3 **Per-agent scopes + audit log** (who, tool, args, result, time) visible in Settings → MCP.
11.4 **Transports:** stdio (`committo mcp`), optional localhost streamable HTTP with bearer token. Resources: repo status, Lens, open PRs. Prompts: "review this PR", "resolve conflicts".
11.5 Tool names follow the table in mock 7 (`repo_*`, `merge_*`, `pr_*`, `issue_*`, `ci_*`, `ruleset_*`, `lens_*`, `agent_*`, `update_*`).

## 12. Self-update

Sparkle 2: signed appcast (EdDSA) hosted on GitHub Releases or a static host; notarized builds; delta updates; stable and beta channels; check on launch and every 24 h; download in background; install on quit or via popover banner; release notes in-app; optional "install without asking". Updates are never applied mid-merge or while an agent run is active. MCP: `update_check`, `update_install` (write tier). The CLI helper (`committo`) is bundled in the app and updated with it.

## 13. Roadmap beyond v1

Stacked branches and a stack-aware PR flow, automatic branch cleanup, PR-based merge detection, self-hosted provider presets, LFS UI, conflict wizard for rename/delete, custom workflows, CLI shell completions, iPad companion for PR review.

## 14. Milestones

| M | Scope | Exit criteria |
|---|---|---|
| M0 | Build the existing scaffold on a Mac; fix compile errors; icon + bundle | App launches, popover and window usable |
| M1 | Core git parity (§4), line staging, signing | Daily-drive on own repos |
| M2 | Diff/merge tool (§5) with AI link | Resolve real conflicts without leaving app |
| M3 | PRs/issues + gates (§7), CI runners | Review a PR end to end locally |
| M4 | Repo wizard + rulesets (§6) | New repo to first green CI in one screen |
| M5 | Action registry + MCP tiers + audit (§11) | Registry test enforces coverage |
| M6 | Sparkle updates, notarization, public beta (§12) | Update from 0.1 to 0.2 on a clean Mac |

## 15. Risks and open questions

- **Provider API gaps** (rulesets outside GitHub). Mitigation: capability matrix, no silent partial applies.
- **AI context and privacy.** Conflicts and diffs go to the chosen backend; show a first-use disclosure and allow local-only mode (no AI).
- **Agent CLI flags drift.** Keep adapters as editable templates; add a "test agent" button.
- **act fidelity** (macOS/Windows runners, secrets). Document unsupported workflows; LAN runner is plain HTTP + token, add TLS/mTLS before recommending beyond a trusted network.
- **SecurityCage supply chain:** installs from a commit pin without scripts and self-tests, but the tarball checksum is recorded on first download (trust on first use); add signed releases upstream so Committo can verify a publisher signature. The upstream `install.sh` and README install the wrong npm package.
- **Open:** pricing/licensing model; whether to bundle Tree-sitter grammars or load on demand; Sparkle vs. a custom updater if distributed via the Mac App Store (Sparkle is not allowed there, so v1 is Developer ID only).

## 16. Performance and feel

Light, fast and a delight is a requirement, not a polish pass.

- **Budgets (Apple silicon, repo with 100k commits):** popover visible in <80 ms from cached state; cold launch to usable window <400 ms; repo switch <150 ms; status refresh <100 ms; graph scroll at 60 fps; merge preview redraw <16 ms; memory <150 MB idle.
- **How:** never block the main thread; stream `git log` and parse incrementally; virtualized lists and a lane-layout cache keyed by commit ranges; rely on `core.fsmonitor`, `feature.manyFiles` and the commit-graph file; cache provider data (stale-while-revalidate) so counters render instantly and refresh behind; cancel superseded git processes; coalesce file-system events.
- **Feel:** keyboard-first (⌘K, 1/2/3, ↩ to confirm), optimistic UI for local actions, skeletons instead of spinners after 200 ms, every long operation cancellable and resumable, animations under 250 ms and disabled by Reduce Motion, native controls and system fonts, no web views.
- **Footprint:** single signed app, no background daemon unless MCP/CI server is switched on, idle CPU ~0.
- **Measure:** a benchmark target in CI (synthetic 100k-commit repo) fails the build on regression beyond 15%.
