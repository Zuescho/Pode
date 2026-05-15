# Orbital-Command local patches against Pode 2.13.2

This fork is consumed by the Orbital-Command platform
(`C:\Users\d150111\Documents\Git\Orbital-Command`), imported in `server.ps1`
via `Import-Module ..\Pode\src\Pode.psd1 -Force`. Three concurrency bugs in
Pode 2.13.2's task-pool plumbing are fixed here; everything else is unchanged
upstream. See Orbital-Command's `docs/Platform-Plan.md` §15d for the full
diagnosis.

## Branch state

- Branched from upstream tag `v2.13.2` on `orbital-command-patches`.
- `upstream` remote points at https://github.com/Badgerati/Pode.git.
- `git log upstream/v2.13.2..HEAD` shows our delta as discrete commits.

## The three patches

### 1. `src/Private/Tasks.ps1` — `Start-PodeTaskHousekeeper`

Five null-deref / race fixes in the recurring 20-second housekeeper timer
that empties `$PodeContext.Tasks.Processes`:

| # | Problem | Fix |
|---|---|---|
| a | `$process` can be `$null` between `Keys.Clone()` and `Processes[$key]` if another thread races `Close-PodeTaskInternal`. | `if ($null -eq $process) { continue }` |
| b | `$process.Task` can be `$null` on a half-constructed entry inserted by `Invoke-PodeTaskInternal` (line 199) but not yet completed (line 226). | `if ($null -eq $process.Task) { continue }` |
| c | `$task = $PodeContext.Tasks.Items[$process.Task]` can return `$null` if the task was removed mid-flight via `Clear-PodeTasks` / `Remove-PodeTask`. | `if ($null -eq $task) { continue }` |
| d | `$process.Runspace` is `$null` either transiently (the construction window) or permanently (if `Add-PodeRunspace` itself threw and left an orphan). Original code blows up on `$process.Runspace.Handler.IsCompleted`. | Skip transient; sweep entries with `Runspace=$null` more than 60 seconds past `CreateTime`. |
| e | `$process.CompletedTime.AddMinutes(1)` throws if State is `Completed` but `CompletedTime` is `$null` (residual orphan state). Same shape for `ExpireTime`. | Null-check both before dereferencing. |

Bonus fix: `$PodeContext.Tasks.Processes.Keys.Clone()` does NOT safely snapshot
a synchronized hashtable on PowerShell 7 — calling `.Remove()` inside the
loop throws "Collection was modified". Replaced with
`@($PodeContext.Tasks.Processes.Keys)`, which does materialise a real array.

### 2. `src/Private/Tasks.ps1` — `Invoke-PodeTaskInternal`

If `Add-PodeRunspace` throws after the process record has been inserted into
`$PodeContext.Tasks.Processes` (line 199 inserts; line 223 calls
`Add-PodeRunspace`; line 226 assigns the runspace), the outer catch at
line 232 only logs. The half-constructed entry stays in `Processes` with
`Runspace = $null` forever. Even with the housekeeper patches above, that's
just symptom-management — the real fix is to roll back the insert.

The patch wraps `Add-PodeRunspace` + the `Runspace` assignment in a nested
try and rolls back `Processes[$processId]` before rethrowing.

### 3. `src/Private/Runspaces.ps1` — `Add-PodeRunspace`

Pode initialises the per-type runspace pool wrappers (`Tasks`, `Timers`,
`Schedules`, etc.) at `Private/Server.ps1:96` — AFTER it invokes the user
scriptblock at `Server.ps1:71`. Any user code that calls `Invoke-PodeTask`
during scriptblock execution therefore hits `Add-PodeRunspace` (line 114)
which does `++$PodeContext.RunspacePools[$Type].LastId`. When the wrapper
doesn't exist, the error is `The property 'LastId' cannot be found on this
object`.

The patch adds a lazy-init guard at the top of `Add-PodeRunspace`: if the
wrapper for `$Type` is missing, create it on demand with `Pool` /
`State='Waiting'` / `LastId=0`. The Pool object is opened later by the
normal `Open-PodeRunspacePool` flow; any pipelines queued in the meantime
run as soon as that happens (standard .NET RunspacePool behaviour).

## Upgrade procedure

When Pode releases a new version:

```powershell
cd C:\Users\d150111\Documents\Git\Pode
git fetch upstream
git rebase upstream/v<next>   # on orbital-command-patches
```

Inspect `git log upstream/v<next>..HEAD` — that's the patch set. If upstream
fixed one of the three, drop that commit during the rebase. Re-test by
restarting Orbital-Command's `server.ps1` and watching `logs/errors_*.log`.

Also refresh `src/Libs/` from the new PSGallery release:

```powershell
$src = "$home\Documents\PowerShell\Modules\Pode\<new-version>\Libs"
Copy-Item $src -Destination src/Libs -Recurse -Force
```

## Not upstreamed

Deliberate, as of 2026-05-15. Observing locally first to confirm the patches
resolve the recurring task-pool errors in production before submitting a PR
to Badgerati/Pode. This document is precise enough to lift into a PR
description when we're ready.
