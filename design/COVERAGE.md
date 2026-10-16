# Vision coverage

Every request made so far, mapped to where it appears. Legend: **M** = in the mockup, **S** = in the spec, **C** = code exists in the scaffold (compiled/tested only for CommittoCore, CLI, MCP), **–** = not covered.

| # | Request | Mock | Spec | Code |
|---|---|---|---|---|
| 1 | Native Mac app, Swift | – | §2 | C (app uncompiled) |
| 2 | Menu-bar popover with arrow, recent repos, quick actions | 1 | §3.1 | C (uncompiled) |
| 3 | **PR and issue counters on most active repos (popover)** | 1 | §3.1 | – |
| 4 | OAuth and tokens for popular providers, gh auth | 8, 12 | §10 | C |
| 5 | MCP server for agents; **all features MCP-exposed** | 7 | §11 | C (12 tools; registry not built) |
| 6 | Agent lens view (what every agent is doing, per branch) | 6, 9 | §8 | C |
| 7 | PR deep dive: security scan, agent review | 4, 11 | §7 | C |
| 8 | PR hooks into local CI, agent review, **agent test** | 4 | §7.2–7.3 | partial (CI, review: C; agent test: –) |
| 9 | Claude headless CLI; other agents via MCP bridge and API (Command Code, dsh…) | 6, 12 | §8.2 | C |
| 10 | Full-featured git client and advanced workflows | 2, 3, 9, 10 | §4, §13 | partial (see gaps) |
| 11 | Visualization | 9, 11 | §4.4, §4.8 | C (graph, heatmap, charts; uncompiled UI) |
| 12 | Modern UI, easy for vibe coders | 13 | §3.3 | – (guided mode, plain-language ⌘K) |
| 13 | Icon | – | §2 | C (script, uncompiled) |
| 14 | Local CI runners like act; MCP link; LAN server option | 4, 12 | §7.2 | C (act runner, LAN server uncompiled) |
| 15 | Mockup + spec first | all | all | – |
| 16 | Self-update | 1, 8 | §12 | – |
| 17 | Built-in diff and merge tool | 2, 3 | §5 | – (parsing only; no merge engine) |
| 18 | **AI link in diff and merge** | 2, 3, 9, 10 | §5.4 | – |
| 19 | Pull PRs and issues, local management | 4, 10 | §7.1 | partial (PR list/files: C; issues, local checkout: –) |
| 20 | New repo: main branch, rulesets/protection | 5 | §6.2–6.3 | – (ruleset JSON only) |
| 21 | Auto license, .gitignore, README and other setup | 5 | §6.4 | – |
| 22 | Create local repo, import, clone | 1, 5 | §6.1 | partial (init/clone: C) |
| 23 | Signing and the usual git flows | 2, 8, 9, 10 | §4, §9 | – (signing); flows partial |
| 24 | Canvas view of the mock | – | – | done |
| 26 | **Merge options visualize how commits land on main; educational for students** | 14 | §7.6, §3.4 | – (preview component not built) |
| 27 | **Tags, tag management, releases** | 15 | §7.8 | – |
| 28 | **Light, fast, effective, a delight** | 14 (keyboard, instant preview) | §16 | – (budgets defined, not measured) |
| 29 | **Better logo than a generic "C"** | 18 | §2 | **A chosen**; logo.svg, menubar.svg, icon script (icon script uncompiled) |
| 30 | **CI status highlighted: running, local, remote, self-hosted** | 1, 15 | §7.9 | partial (act + LAN runner exist, uncompiled UI; hosted-provider status: –) |
| 31 | **SecurityCage integration: setup, install, auto-appearing scan, pinned latest, updates** | 4, 5, 13, 16 | §7.10 | **install/pin/update/rollback/scan/MCP implemented and tested live**; UI mock only |
| 32 | **Tailscale: local machines/servers connect as CI runners; setup automated in-app** | 15, 16, 12 | §7.11 | – (mock and spec only; untested against a real tailnet) |
| 33 | **Managing branches whose PRs are merged** | 10 | §7.12 | – (spec and mock only) |
| 34 | **GitHub Pages so the mockup and screenshots can be shared** | – | README | site built in `docs/`; **needs one-time Pages setting** (Settings → Pages → branch `main`, `/docs`) |
| 35 | **All git operations: cherry-pick, interactive rebase, reset, force push and the rest** | 6, 7 (new) | §4.9, GIT-OPERATIONS.md | catalog of 64 operations; engine has 15 done and 20 basic; interactive rebase, continue/skip, force-lease flow not built |
| 36 | **Everything tested; memory management** | – | §16, QUALITY.md | plan written; 16 Core tests today; app untested; 9 code risks listed |
| 25 | main branch, protected; Apache 2.0; README with agent prompt, logo, screenshots | – | – | main + README + LICENSE done; protection **pending** (needs `Scripts/protect-main.sh`) |

## Screens in the mockup (21)

1 Menu bar · 2 Changes · 3 Diff & merge · 4 PRs & issues · 5 New repo · 6 Agent Lens · 7 MCP surface · 8 Updates & signing · 9 History & graph · 10 Branches & stacks · 11 Insights & security · 12 Accounts, agents & CI · 13 First run & ⌘K · 14 Merge preview · 15 CI live · 16 Tailscale runners · 17 SecurityCage · 18 Tags & releases · 19 Logo

## Known gaps (not yet in the mock)

- Interactive rebase editor and the rename/delete conflict card (named in the spec only).
- PR creation form and inline review comments (PR screen shows the gates, not the diff review).
- Issue detail and create form.
- Clone-from-provider browser (the wizard has a Clone tab but no repo picker).
- Blame and file-history views (buttons exist, no screen).
- Image diff, patch import/export dialogs, git-flow and LFS settings beyond toggles.
- Multiple-window layout and repo groups/tags.
