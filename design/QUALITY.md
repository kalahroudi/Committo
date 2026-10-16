# Quality plan: testing, memory, release gates

"Bug free" is not a claim anyone can make. The goal is narrower and checkable: **every operation has a test, every risky invariant has an automated check, memory and process growth are measured continuously, and nothing ships if a gate is red.**

## Where we are today

- 16 tests in `CommittoCore` (git parsing, graph layout, scanner, MCP, SecurityCage install/update/rollback), all passing on Linux. One of them hits the network and is opt-in.
- The SwiftUI app has **never been compiled or run**: no UI tests, no memory measurements, no sanitizer runs.
- 29 of the 64 operations in `GIT-OPERATIONS.md` have no engine code, so no tests either.

## Known risks in the current code

Found by reading the code. Each becomes a test first, then a fix.

| Risk | Where | Fix | By |
|---|---|---|---|
| Whole output of `git log/diff/blame` is buffered in memory | `Shell.run` (unbounded buffer) | Stream and parse incrementally; hard cap with "truncated" result | M1 — **done**: `Shell.records`, `StatusParser`/`DiffParser`, 64 MB run cap, 20k-line file cap, 32 MB diff cap |
| Process cancel kills only the direct child; agents and `act` spawn trees | `Shell.stream`, `MCPClient.stop` | One `ProcessSupervisor` owns every child, uses process groups, kills the tree on cancel, timeout and app quit | M1 — **done**: `ProcessSupervisor` (`Shell` and `MCPClient`) |
| CI log and agent console lines grow forever | `CIModel.log`, `AgentRunModel.lines` | Ring buffer (about 5,000 lines) with a "saved to file" link | M1 — ring buffers **done** (`RingBuffer`: CI 5,000, console 2,000); "saved to file" link still open |
| Filesystem scan runs on the main actor at launch | `AppModel.bootstrap` → `RepoStore.discover` | Move off the main actor, cancellable, incremental results | M0 — **done** (off-main; not yet incremental) |
| Graph layout holds per-row lane arrays for every commit | `CommitGraph.layout` | Page by range, cache by commit range, release off-screen rows | M1 |
| Lens scan spawns many git processes per refresh | `AgentLens.scan` | Batch with one `for-each-ref`/`log` call; bounded concurrency | M1 |
| Parallel writes to one repo can collide on `index.lock` | all write ops | Per-repo serial queue for write operations | M1 |
| 8 `@unchecked Sendable` escape hatches | `Shell`, `RepoStore`, others | Replace with actors or document and test each | M1 |
| Timers and handlers never torn down | `StatusItemController` | Invalidate in `deinit`; weak-reference tests | M0 — **done**: `tearDown()` on quit plus deinit canaries |

## Test layers

| Layer | What it proves | Runs |
|---|---|---|
| Unit | Parsers, graph layout, scanner rules, JSON-RPC, version logic. Includes malformed and hostile input (fuzzing). | every push, Linux and macOS |
| Property tests | Graph: every edge links two real rows, parents follow children, lanes stay bounded. Undo: **snapshot, operation, undo gives back identical HEAD, index and working tree hashes**. | every push |
| Real-git integration | Each catalog operation against scripted repos: conflicts, rebase, cherry-pick, reset, stash, submodules, worktrees, LFS, signed commits, 100k-commit and 10k-file repos built with `fast-import`. Clone matrix: plain, shallow, partial, sparse; LFS (now, on demand, chosen paths, git-lfs missing, quota error); nested and private submodules (one failing, then retry); fork then sync (fast-forward and diverged). | every push (small), nightly (large) |
| Preview equals reality | The merge/squash/rebase preview is compared with what git actually produces in a throwaway clone. | every push |
| Differential | Our parsed status/log/diff compared with git plumbing on random repos. | nightly |
| Safety | Hostile file, branch and commit names (spaces, quotes, leading `-`, newlines, ANSI escapes) never reach a shell; secrets never appear in logs; PR code is always scanned as untrusted; destructive tools are blocked for agents by default. A test fails if any action lacks a tier or schema. | every push |
| Providers | Recorded GitHub/GitLab responses (rate limits, errors, pagination) plus a nightly live run against a throwaway repo. | every push, nightly |
| Agents and MCP | Fake agent CLIs that emit bad JSON, hang, or flood output; cancellation; cost accounting; MCP protocol conformance. | every push |
| Network features | CI server and Tailscale paths: auth, oversized and malformed requests, path traversal in remote URLs. | every push |
| Updater | Tampered archive rejected, downgrade refused, rollback works. | every release |
| UI | XCUITest flows for the main journeys; snapshot tests in light and dark; keyboard-only run; accessibility audit. | every push (macOS) |

Traceability: every row of `GIT-OPERATIONS.md` carries a test id, and a test fails if a row has none.

## Memory and resource plan

**Design rules.** Stream, never slurp. Every buffer has a cap. Lists are virtualised. Caches are `NSCache` with a cost limit. Closures that outlive a call capture `self` weakly. One owner per child process. No unsafe pointers (we shell out to `git`, we do not link libgit2).

**Tools.**
- Address, Thread and Undefined-behaviour sanitizers in CI, each as its own job.
- Swift strict concurrency set to complete, so data races become compile errors.
- `leaks --atExit` after UI and integration runs; Malloc Stack Logging when it flags something.
- Instruments (Allocations, Leaks, VM Tracker) for each release candidate.
- `XCTMemoryMetric` and clock metrics with stored baselines; more than 15% regression fails.

**Tests that target memory.**
- *Deinit canaries:* every long-lived object (view models, process wrappers, MCP client, CI server connections, popover and window controllers) is created, used, released, and asserted gone through a weak reference. This catches retain cycles directly.
- *Process hygiene:* after every operation and every cancel, the child-process count returns to the baseline (no orphans or zombies).
- *Big-input tests:* a 50 MB diff, a 1 GB log, a 100k-commit graph. Peak memory must stay under its budget, and results are truncated or paged, never crash.
- *Soak:* 24 to 72 hours on a macOS runner, scripted to open and close the popover, switch repos, fetch, scroll the graph, stream CI logs and run a fake agent. Footprint is sampled each minute with `footprint`/`vmmap`. Fails if growth exceeds 5 MB per hour after warm-up or if peak exceeds budget; `leaks` snapshots at 0, 12 and 24 hours are diffed.

**Budgets** (also in spec §16): idle under 150 MB; 100k-commit repo under 300 MB peak; child processes back to baseline after each operation.

**Memory pressure.** On a system memory-pressure signal the app drops graph, diff and provider caches and keeps working. A test simulates the signal.

**Failure injection.** Git killed mid-operation, disk full, permission denied, repo corruption (`fsck`), network drop, a worktree deleted underneath us. Operations either finish atomically or leave a recoverable snapshot, and the UI never blocks forever (every call has a timeout).

## Gates

| Gate | Must be true |
|---|---|
| Every pull request (required checks) | Build with warnings as errors, lint, Core tests on Linux and macOS, sanitizer jobs, UI smoke and snapshot tests, catalog traceability |
| Nightly | Large-repo suite, differential tests, live provider run, performance baselines |
| Weekly | 24-hour soak, leak diff, dependency and security scan (SecurityCage on our own code) |
| Release candidate | 72-hour soak clean, Instruments pass, updater tests, manual checklist for destructive operations (reset hard, force push with lease, interactive rebase, branch cleanup) |
| Public beta exit | Two weeks of dogfooding on the beta channel, crash-free sessions at or above 99.5%, no open data-loss bug |

Crash and hang reporting is opt-in and local first (MetricKit diagnostics). Any data-loss report outranks every other work item.

## Milestone exits

The same items are tracked in the roadmap table in `SPEC.md` §14.

- **M0:** app compiles; sanitizers wired in CI; deinit canaries for controllers; main-thread scan fixed.
- **M1:** process supervisor, streaming parsers, ring buffers, per-repo write queue; undo-equality property tests for every working-copy and history operation.
- **M2:** merge tool tests, including "result never contains conflict markers" and undo.
- **M3:** provider contract tests; CI and agent cancellation tests; soak starts running weekly.
- **M4:** wizard and ruleset tests against a throwaway GitHub repo.
- **M5:** registry test enforces tiers, schemas and traceability.
- **M6:** updater tests; release-candidate gate; beta exit criteria.
