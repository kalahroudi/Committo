# Git operations catalog

Every git operation Committo will support, where it lives, how risky it is, how to undo it, and its MCP tool. Tiers: **R** read, **W** write, **D** destructive (agents blocked by default, always confirmed). *Mock* = shown in the clickable mockup. *Engine* = a working wrapper exists in `CommittoCore` today (Linux-tested), where "partial" means a basic form only.

**69 operations.** Mock: 34 shown, 8 partly, 27 not yet. Engine: 15 done, 20 basic, 34 not started.

| Area | Operation | Where | Tier | Undo | MCP tool | Mock | Engine |
|---|---|---|---|---|---|---|---|
| Repository | Init, with main branch | New repo | W | delete folder | `repo_create` | yes | yes |
| Repository | Clone: URL or provider picker, shallow, partial, sparse | Clone sheet | W | delete folder | `repo_clone` | partial | partial |
| Repository | Clone with LFS: detect, install git-lfs, download now, on demand or chosen paths, size shown first | Clone sheet | W | delete folder | `repo_clone` (lfs) | no | no |
| Repository | Clone with submodules: init and update recursively, parallel, shallow, HTTPS rewrite, retry failed | Clone sheet | W | delete folder | `repo_clone` (submodules) | no | no |
| Repository | Import existing | New repo | W | none needed | `repo_import` | yes | no |
| Repository | Fork on the provider, clone it, add `upstream` | Clone sheet / PR screen | W | delete fork on provider | `repo_fork` | no | no |
| Repository | Sync fork with upstream (fast-forward, or rebase/merge with preview) | Branches | W / D | Undo | `fork_sync` | no | no |
| Working copy | Stage and unstage file | Changes | W | unstage | `stage / unstage` | yes | yes |
| Working copy | Stage hunk or single lines | Changes | W | unstage | `stage_lines` | yes | yes |
| Working copy | Discard changes (file, hunk, all) | Changes | D | snapshot restore | `discard` | partial | yes |
| Working copy | Clean untracked files, with a dry-run list | Changes | D | snapshot restore | `clean` | no | partial |
| Working copy | Ignore file or pattern | Changes menu | W | edit .gitignore | `ignore_add` | yes | yes |
| Working copy | Rename, move, delete tracked file | Changes menu | W | undo | `file_move / file_delete` | no | no |
| Working copy | Restore file from a commit | History menu | W | snapshot restore | `file_restore` | no | no |
| Working copy | Create and apply patch | Changes / History | W | reverse patch | `patch_create / patch_apply` | no | partial |
| Stash | Push, apply, pop, drop | Branches | W / D (drop) | drop kept 30 days | `stash_*` | yes | yes |
| Stash | Stash to branch, show diff | Branches | W | none needed | `stash_branch / stash_show` | no | no |
| Commit | Commit (template, co-authors, signoff, sign, empty) | Changes | W | Undo | `commit` | yes | partial |
| Commit | Amend (message, add files, keep message) | Changes | D if pushed | Undo | `amend` | yes | partial |
| Commit | Fixup / squash commit for autosquash | History menu | W | Undo | `commit_fixup` | yes | no |
| Branches | Create from commit, tag or remote | Branches / History | W | delete | `branch_create` | yes | yes |
| Branches | Rename | Branches menu | W | rename back | `branch_rename` | no | no |
| Branches | Delete local | Branches | D | restore 30 days | `branch_delete` | yes | yes |
| Branches | Delete remote branch or tag | Branches | D | restore 30 days | `remote_delete` | no | no |
| Branches | Set or unset upstream | Branches menu | W | set again | `branch_upstream` | no | partial |
| Branches | Switch, carrying, stashing or discarding changes | Reset & force push | W / D | snapshot restore | `switch` | yes | partial |
| Branches | Detached HEAD: save to branch, go back | Banner | W | none needed | `head_save / head_return` | yes | no |
| Branches | Orphan branch | Advanced | W | delete | `branch_orphan` | no | no |
| History rewrite | Merge: fast-forward, merge commit, squash | Merge preview | W | Undo | `merge` | yes | partial |
| History rewrite | Continue, skip, abort any operation in progress | Banner | W | n/a | `op_continue / op_skip / op_abort` | yes | partial |
| History rewrite | Rebase onto a branch (autostash) | Branches | D if pushed | Undo | `rebase` | yes | partial |
| History rewrite | Interactive rebase: pick, reword, edit, squash, fixup, drop, reorder | Interactive rebase | D | backup restore | `rebase_interactive` | yes | no |
| History rewrite | Rebase --onto (restack a branch stack) | Branches | D | backup restore | `stack_restack` | yes | no |
| History rewrite | Cherry-pick: one, range, -x, no-commit, merge parent | Reset & force push | W | Undo | `cherry_pick` | yes | partial |
| History rewrite | Revert: one, range, merge parent, no-commit | Reset & force push | W | Undo | `revert` | yes | partial |
| History rewrite | Reset: soft, mixed, hard, keep | Reset & force push | D (hard) | backup restore | `reset` | yes | partial |
| History rewrite | Restore a lost commit or branch from the reflog | Time Machine | W | n/a | `reflog_restore` | no | partial |
| History rewrite | Undo last history change | Toolbar | W | redo | `undo` | yes | yes |
| History rewrite | Remove a file or secret from all history | Security | D | backup bundle | `history_scrub` | no | no |
| History rewrite | Reuse recorded conflict resolutions (rerere) | Settings | W | off | `config_set` | no | no |
| Remotes | Add, rename, remove, change URL | Repo settings | W | reverse | `remote_*` | no | no |
| Remotes | Fetch (all, prune, tags) | Toolbar | R | n/a | `fetch` | yes | yes |
| Remotes | Pull: fast-forward only, rebase, merge | Toolbar | W | Undo | `pull` | partial | partial |
| Remotes | Push, set upstream, push tags | Toolbar | W | n/a | `push` | yes | partial |
| Remotes | Push rejected: pull with rebase, or merge | Banner | W | Undo | `push_recover` | yes | no |
| Remotes | Force push with lease (and force-if-includes) | Reset & force push | D | remote old SHA logged 30 days | `push_force_lease` | yes | yes |
| Remotes | Plain force push (advanced, blocked on protected) | Reset & force push | D | remote old SHA logged 30 days | `push_force` | yes | no |
| Inspect | History graph, filter, search | History | R | n/a | `log` | yes | yes |
| Inspect | Search content (pickaxe -S, -G, grep) | History | R | n/a | `log_search` | no | no |
| Inspect | Blame and file history | History menu | R | n/a | `blame / file_history` | partial | yes |
| Inspect | Diff: working, staged, commit, branches, word-level | Many | R | n/a | `diff` | yes | yes |
| Inspect | Range-diff (compare before and after a rebase) | PR / Rebase | R | n/a | `range_diff` | no | no |
| Inspect | Bisect, guided, optionally with an agent test | History | W | bisect reset | `bisect_*` | no | no |
| Inspect | Stats, contributors, describe | Insights | R | n/a | `stats` | yes | yes |
| Tags | Create: lightweight, annotated, signed | Releases | W | delete | `tag_create` | yes | partial |
| Tags | Push, delete, move | Releases | D | restore 30 days | `tag_push / tag_delete / tag_move` | yes | no |
| Extras | Submodules: add, update, sync, remove | Branches | W | reverse | `submodule_*` | partial | partial |
| Extras | Initialise submodules in an existing clone; keep them in step on pull and switch | Branches | W | deinit | `submodule_init` | no | no |
| Extras | Worktrees: add, remove, lock, prune | Branches | W | re-add | `worktree_*` | yes | partial |
| Extras | LFS: track, pull, lock | Settings | W | untrack | `lfs_*` | partial | no |
| Extras | LFS in an existing repo: fetch missing files, prune old ones, list locks | Settings | W | refetch | `lfs_fetch` / `lfs_prune` | no | no |
| Extras | Sparse checkout, partial clone | Clone sheet | W | reset sparse set | `sparse_*` | no | no |
| Extras | Hooks: view, enable, skip once | Settings | W | revert | `hooks_*` | no | no |
| Extras | Config: identity, profiles, aliases | Settings | W | revert | `config_*` | partial | no |
| Extras | Signing: SSH, GPG, 1Password | Settings | W | revert | `signing_*` | yes | no |
| Extras | Maintenance: gc, repack, prune, fsck | Repo settings | W | n/a | `maintenance` | no | no |
| Extras | git-flow | Settings | W | n/a | `flow_*` | partial | no |
| Extras | Export: ZIP, patch, bundle | History menu | R | n/a | `export` | no | partial |
| Extras | Notes (git notes), mailmap, attributes | Advanced | W | revert | `notes_* / config_set` | no | no |

## Safety model for risky operations

Applies to every **D** row and to any operation that can lose uncommitted work.

1. **Preview.** Show what changes: commits that move, become unreachable, or get new hashes (the same before/after graph as the merge preview).
2. **Snapshot first.** Before reset --hard, forced switch, discard, clean, rebase or amend: save uncommitted work (including untracked files) to a stash-like snapshot and record the old HEAD in `refs/committo/backup/<time>`. Kept 30 days. Undo and Time Machine restore from it.
3. **Force push means lease.** Always `--force-with-lease` with the expected remote SHA (plus `--force-if-includes` where available). If the remote has commits you have not fetched, the push is blocked and the app offers Fetch and review. Plain `--force` is an advanced option, never the default, and is refused on protected branches.
4. **Name the loss.** The button says what is lost ("Reset hard, 4 changes lost"). Irreversible-on-remote actions (delete remote branch, move a pushed tag) ask twice.
5. **Operations in progress are first-class.** Merge, rebase, cherry-pick, revert and stash-apply show one banner with Continue, Skip and Abort, and conflicts open the merge tool.
6. **Agents.** Destructive tools are off for agents until enabled, and then still require in-app confirmation.

"Force HEAD" in practice means: reset --hard, forced switch/checkout that discards changes, detaching HEAD, and moving a branch pointer. All four follow the rules above.
