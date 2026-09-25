# One work tree per agent

More than one agent works in this repo on the nova host at the same time. They
used to share the single checkout at `~/github/jules-ops`, which does not work:
`git switch` is repo-global, so when one agent changed branch the tracked files
under the *other* agent silently changed too — including `repos.allow` and
`repos.priority`, which decide what Jules may write to and in what order.

That is not a theoretical failure. On 24/09/2026 a dispatch run found itself on
`dispatch/auto-land-pipeline` mid-task, reading a `repos.allow` that was missing
`dotfiles`. Nothing errored; the config just quietly became a different file.

## The layout

```
~/github/jules-ops                      reference checkout, stays on main, read-only
~/github/.worktrees/<agent>/jules-ops   one per agent, this is where you work
```

Current work trees: `chief-of-staff`, `dispatch`, `relay`. They share one object
store and one set of refs with `~/github/jules-ops`, so pushing and fetching work
exactly as before — only the checked-out branch is now private to each agent.

## The rules

1. **Work only in your own work tree.** Never run a mutating `git` command
   (`switch`, `checkout`, `reset`, `stash`, `clean`) against `~/github/jules-ops`
   or against another agent's path. Per-agent work trees stop branch clobbering;
   they do not stop an agent that reaches into a directory it does not own.
2. **One branch, one work tree.** Git refuses to check the same branch out twice,
   which is the point. If you need a branch someone else has checked out, branch
   off `origin/<name>` instead of trying to take it.
3. **Leave `~/github/jules-ops` on `main`.** It exists so anything that just
   wants to read current config gets current config.

## Adding a work tree for a new agent

```sh
cd ~/github/jules-ops
git fetch origin
git worktree add --detach ~/github/.worktrees/<agent>/jules-ops origin/main
```

Then, inside it, start your branch: `git switch -c <topic>`. A detached HEAD is
the deliberate starting state — it means an agent that forgets to branch cannot
accidentally commit onto a shared one.

## Cleaning up

```sh
cd ~/github/jules-ops
git worktree list                      # what exists now
git worktree remove ~/github/.worktrees/<agent>/jules-ops
git worktree prune                     # drop records for directories already gone
```
