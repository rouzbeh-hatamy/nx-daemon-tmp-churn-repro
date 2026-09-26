# Repro: Nx 23.2.x daemon churns on transient `_tmp_<pid>_<hex>` files (macOS)

Minimal reproduction for an Nx daemon that never goes idle. This is a bare
`create-nx-workspace` output with **zero projects**. Nothing is running: no dev
server, no build, no `nx` command after the initial graph.

The outputs watcher reports an endless stream of deletions of transient
`_tmp_<pid>_<hex>` files created in the workspace root, and `daemon.log` grows
continuously.

Fixed on `master` (appears to be #36912, follow-up #37025), **not backported to
the `23.2.x` branch**, so the current `latest` tag is affected.

## Reproduce

```bash
pnpm install
./measure.sh
```

`measure.sh` stops the daemon, clears the log, computes the graph once, waits,
and then reports log size, growth rate and `_tmp_` event count.

## Observed

Each row is the same workspace, 25s settle + 10s growth sample, on
macOS 27.0.0 / arm64 / Node 24.21.0 / pnpm 12.4.2.

| configuration | `daemon.log` | growth | `_tmp_` events |
|---|---|---|---|
| nx 23.2.0, default `@nx/js/typescript` plugin | 644 KB | +222 KB/10s | 735 |
| nx 23.2.0, `plugins: []` | 580 KB | +210 KB/10s | 629 |
| nx 23.2.0 + `.nxignore` containing `_tmp_*` | 20 KB | flat | **0** |
| nx 23.3.0-beta.5 | 24 KB | flat | 7 |

Notes on what this rules out:

- **Not plugin-related.** It reproduces with `plugins: []`.
- **Not project-related.** There are no projects.
- **Not graph recomputation.** `Recomputing project graph` stays at 0-1 through
  the whole window; the work is elsewhere in the change-handling path.
- **The temp files are not new.** 22.7.1 creates them too (83 events in an
  equivalent window) without the runaway, so whatever writes them is not the
  regression. I was unable to identify the writer: the names do not appear in
  `nx`'s JS or in `nx.darwin-arm64.node`, and the processes named in them exit
  too fast to inspect. The files are zero-length and land in the workspace root.

On a real 80-project workspace the same loop reached 190% node CPU, a
`daemon.log` growing ~11 MB/min (400 MB in 35 minutes), and a load average of
10.86. It also accelerates: process spawn rate hit ~55/s.

## Log excerpt

```
[NX v23.2.0 Daemon Server] - [WATCHER]: Processing file changes in outputs
[NX v23.2.0 Daemon Server] - [WATCHER]: 0 file(s) created or restored, 0 file(s) modified, 5 file(s) deleted
[NX v23.2.0 Daemon Server] - [WATCHER]: [watcher] routeWorkspaceChanges batch: 5 events: delete:_tmp_80947_019f92b8, delete:_tmp_80949_021dd308, ...
```

## Workaround

```bash
printf '_tmp_*\n' >> .nxignore
npx nx daemon --stop
rm -rf .nx/workspace-data/d
```

Stopping the daemon alone is not enough; the next `nx` invocation or IDE
connection restarts it into the same loop.

## Suspected cause

Diffing the published `23.2.1` and `23.3.0-beta.5` tarballs, the relevant change
is in `packages/nx/src/daemon/server/handle-outputs-changes.ts`: a per-path
`isKnownWorkspaceFile()` became a batched `trackedFilesInContext()` guarded by
`invalidating.length`, commented:

> Skips the napi call, which takes the files mutex and can wait out a re-walk,
> for the common batch that classifies nothing.

These temp-file batches classify as nothing, which matches. Stated as a
hypothesis — traced by diffing tarballs, not by profiling.
