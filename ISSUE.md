# Daemon burns 100-230% CPU on macOS from transient `_tmp_<pid>_<hex>` files; fixed on master, not backported to 23.2.x

**Minimal reproduction:** https://github.com/rouzbeh-hatamy/nx-daemon-tmp-churn-repro

```bash
git clone https://github.com/rouzbeh-hatamy/nx-daemon-tmp-churn-repro && cd nx-daemon-tmp-churn-repro
pnpm install && ./measure.sh
```

## Current Behavior

On macOS, an idle Nx workspace drives the daemon into sustained 100-230% CPU with no build, dev server, or `nx` command running. The outputs watcher reports an endless stream of deletions of transient `_tmp_<pid>_<hex>` files, and `daemon.log` grows at roughly 11 MB/min (400 MB in ~35 min in the first workspace I hit this in).

```
[NX v23.2.0 Daemon Server] - [WATCHER]: Processing file changes in outputs
[NX v23.2.0 Daemon Server] - [WATCHER]: 0 file(s) created or restored, 0 file(s) modified, 5 file(s) deleted
[NX v23.2.0 Daemon Server] - [WATCHER]: [watcher] routeWorkspaceChanges batch: 5 events: delete:_tmp_80947_019f92b8, delete:_tmp_80949_021dd308, delete:_tmp_80946_00c08cf8, ...
```

Two things worth noting up front, because they shape the diagnosis:

- **This is not graph recomputation.** `Recomputing project graph` stays at **0-1** across the whole window. The CPU is spent elsewhere in the change-handling path.
- **It is not framework-, plugin-, or project-specific.** A bare `create-nx-workspace` output with **zero projects** reproduces it, and it still reproduces with `plugins: []`. I first hit it independently in a Next 16 workspace and in an Angular + Playwright workspace with no `next` dependency anywhere. The only shared component is `nx` itself.

- **The default path for a new user is affected**, because `create-nx-workspace@23.2.1` installs nx **23.2.0**.

I was not able to identify what creates the `_tmp_<pid>_<hex>` files. They do not appear in `nx`'s JS, in `nx.darwin-arm64.node`, or in `next/dist`. They are also created under 22.7.1, which does **not** exhibit the runaway — so the writer is not the regression.

## Expected Behavior

Transient temp files that classify as nothing should not cost measurable CPU, as in 22.7.1 and as on current `master`.

## Version bisect

Same cloned workspace (80 projects), same machine, no `.nxignore`, 30-second settle window after a single `nx graph`. `nx` and all 12 `@nx/*` packages pinned together each run. Every run was verified to emit an identical 80-project graph, so no result is a silent plugin-load failure.

| version | `daemon.log` | growth | `_tmp_` events | `Recomputing project graph` | node CPU |
|---|---|---|---|---|---|
| 22.7.1 | 196 KB | flat | 83 | 1 | — |
| 23.2.0 | 2.0 MB | +305 KB/10s | 2,982 | 1 | 190.3% |
| **23.2.1** (latest stable) | 2.0 MB | +381 KB/10s | 2,212 | 1 | 116.9% |
| 23.3.0-beta.5 | 32 KB | flat | 14 | 0 | 6.1% |

The same bisect on the minimal empty workspace (zero projects), 25s settle + 10s growth sample:

| configuration | `daemon.log` | growth | `_tmp_` events |
|---|---|---|---|
| nx 23.2.0, default `@nx/js/typescript` plugin | 644 KB | +222 KB/10s | 735 |
| nx 23.2.0, `plugins: []` | 580 KB | +210 KB/10s | 629 |
| nx 23.2.0 + `.nxignore` | 20 KB | flat | **0** |
| nx 23.3.0-beta.5 | 24 KB | flat | 7 |

The 23.2.x runs were still accelerating when stopped. Stopping the daemon returns the machine to ~4.6% immediately.

## This looks already fixed on master

`23.3.0-beta.5` resolves it. Diffing `23.2.1` against it, the change that looks responsible is in `packages/nx/src/daemon/server/handle-outputs-changes.ts`, where a per-path `isKnownWorkspaceFile()` became a batched `trackedFilesInContext()` guarded by `invalidating.length`, with this comment:

> Skips the napi call, which takes the files mutex and can wait out a re-walk, for the common batch that classifies nothing.

That matches the symptom exactly: these temp-file batches classify as nothing, so 23.2.x made a per-path napi call taking the files mutex on every batch. (Stated as a hypothesis — I traced it by diffing published tarballs, not by profiling.)

That change appears to have landed in #36912, with follow-up in #37025, superseding #36566 and #36811.

## The actual request: backport to 23.2.x

The `23.2.x` branch does not have it:

```
23.2.x : clearRecordedOutputsHashes -> 0 occurrences
master : clearRecordedOutputsHashes -> 1 occurrence
```

`23.2.1` is the current `latest` tag, so every user on it is exposed, and upgrading within 23.2.x does not help. Would you accept a backport of #36912 onto `23.2.x`? I'm happy to open that PR if it's welcome.

One note on framing: #36566 motivates the work through **Linux inotify overflow** and **Windows** recursive watches, and states that Nx handles rescan on no platform. The reproduction here is **macOS**, idle, with no bulk file operation involved — so if the macOS path reaches the same code by a different route, that may be worth confirming before a backport is cut.

## Workaround

```
printf '_tmp_*\n' >> .nxignore
npx nx daemon --stop
rm -rf .nx/workspace-data/d
```

Verified stable in two workspaces over six days: zero `_tmp_` events, `daemon.log` at 132 KB and 1.1 MB instead of hundreds of MB. Note that stopping the daemon alone is not enough — the next `nx` invocation or IDE connection restarts it into the same loop.

## Steps to Reproduce

```bash
git clone https://github.com/rouzbeh-hatamy/nx-daemon-tmp-churn-repro
cd nx-daemon-tmp-churn-repro
pnpm install
./measure.sh
```

`measure.sh` stops the daemon, clears the log, computes the graph once, waits 25s, then samples log growth over 10s. On 23.2.0 it reports something like:

```
nx 23.2.0  .nxignore: none
log=836K  growth=+220KB/10s  tmp_events=999  recomputes=1  node_cpu=83.6%
```

Expected: a log that stops growing and no `_tmp_` events. To confirm the diagnosis in place, `printf '_tmp_*\n' > .nxignore` and re-run — it drops to `tmp_events=0` and flat growth.

## Nx Report

From the original affected workspace (the minimal repro above is a bare `create-nx-workspace` with the same Node/OS/pnpm):

```
Node           : 24.21.0
OS             : darwin-arm64
Native Target  : aarch64-macos
pnpm           : 12.4.2
daemon         : Available

nx                 : 23.2.0
@nx/js             : 23.2.0
@nx/eslint         : 23.2.0
@nx/workspace      : 23.2.0
@nx/angular        : 23.2.0
@nx/jest           : 23.2.0
@nx/devkit         : 23.2.0
@nx/esbuild        : 23.2.0
@nx/eslint-plugin  : 23.2.0
@nx/node           : 23.2.0
@nx/playwright     : 23.2.0
@nx/web            : 23.2.0
@nx/docker         : 23.2.0
typescript         : 6.0.3
---------------------------------------
Registered Plugins:
@nx/playwright/plugin
@nx/eslint/plugin
```

macOS Darwin 27.0.0, arm64.
