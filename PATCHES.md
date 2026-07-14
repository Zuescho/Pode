# Orbital-Command local patches against Pode 2.13.4

This fork is consumed by the Orbital-Command platform
(`C:\Users\d150111\Documents\Git\Orbital-Command`), imported in `server.ps1`
via `Import-Module ..\Pode\src\Pode.psd1 -Force`. Six patches live here:
four concurrency races in the task/schedule-pool plumbing, one Int32
truncation in the IIS auth handler, and a real-cancel rework of the task
teardown path (stop before dispose). Everything else is unchanged upstream.
See Orbital-Command's `docs/Platform-Plan.md` §15d for the concurrency-race
diagnosis.

## Branch state

- Branched from upstream tag `v2.13.2` on `orbital-command-patches`;
  rebased onto `v2.13.4` on 2026-07-14 (clean rebase, no conflicts —
  upstream's only touch on a patched file was `Invoke-PodeAuthEvent` in
  `Authentication.ps1`, a different function than our patch 5 target).
  `src/Libs/` refreshed from the PSGallery 2.13.4 release (picks up the
  #1717 socket-close fix in `PodeRequestHandler.cs`).
- `upstream` remote points at https://github.com/Badgerati/Pode.git.
- `git log v2.13.4..HEAD` shows our delta as discrete commits.

## The six patches

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
`State='Waiting'` / `LastId=0`, then immediately call `.Pool.Open()` so
`BeginInvoke` can succeed right away. (Without the `.Open()` step the
caller hits `Cannot perform the operation because the runspace pool is
not in the 'Opened' state`.) Pode's normal `Open-PodeRunspacePool` flow at
`Server.ps1:97` later replaces the lazy pool with the canonical one for
that type, so this is genuinely a startup-window shim, not a permanent
extra pool. `.Open()` is idempotent.

### 4. `src/Private/Schedules.ps1` — `Start-PodeScheduleRunspace` housekeeper

Pode 2.13.2 ships the same race-vulnerable housekeeper for schedules as for
tasks: line 34 dereferences `$process.Runspace.Handler.IsCompleted` without
a null-check, and line 29 uses `Keys.Clone()` on a synchronized hashtable.
Mirror the task-housekeeper patch: `@(Keys)` snapshot, null-checks for
`$process` / `$process.Runspace` / `$process.ExpireTime` before
dereferencing. Same surfaced symptom (`You cannot call a method on a
null-valued expression`), same fix shape.

### 5. `src/Private/Authentication.ps1` — `Get-PodeAuthWindowsADIISMethod`

`MS-ASPNETCORE-WINAUTHTOKEN` is the impersonation token IIS passes through
the AspNetCoreModuleV2 to the downstream worker. The header value is the
hex representation of a Windows `HANDLE` — a 64-bit value on x64.

Pode 2.13.2's line 987 parses it with:

```powershell
$winAuthToken = [System.IntPtr][Int]"0x$($token)"
```

`[Int]` is `[Int32]`. PowerShell parses `"0xFFFFFFFF"` style strings as
hex fine, but on x64 every handle that doesn't fit in 31 bits is silently
sign-extended to a *different* 64-bit IntPtr. `WindowsIdentity::new` then
calls `DuplicateTokenEx` on that corrupted handle and the kernel returns
`ERROR_INVALID_HANDLE`, surfaced as the managed message:

> Exception calling ".ctor" with "2" argument(s): "Invalid token for
> impersonation - it cannot be duplicated."

On the IIS-hosted Orbital-Command install the call site fires for every
request (auth middleware) so the error log accumulated ~3 paired entries
per second. The paired downstream error (`The property 'Headers' cannot
be found on this object` at `Authentication.ps1:1332`) is chained
reportage of the same failure — the catch returns a hashtable with only
`Message`, and the validator builds the 401 response shape from it.

Patch: parse as Int64 explicitly and reject empty tokens up-front with a
clean 401 instead of letting `[Convert]::ToInt64('', 16)` throw into the
catch. Trim + optional `0x`-prefix strip before the parse — `Convert.ToInt64`
with `-fromBase 16` does NOT accept either, whereas the upstream `[Int]"0x..."`
form did. Without the strip we'd break differently than upstream on
hypothetical `0x`-prefixed headers (ANCM normally sends bare hex):

```powershell
if ([string]::IsNullOrEmpty($token)) {
    return @{ Message = 'Empty WINAUTHTOKEN'; Code = 401 }
}
$parsed = $token.Trim()
if ($parsed.StartsWith('0x', [System.StringComparison]::OrdinalIgnoreCase)) {
    $parsed = $parsed.Substring(2)
}
$winAuthToken = [System.IntPtr]::new([Convert]::ToInt64($parsed, 16))
```

The `finally` block at the end of the function also gets a null-guard so
the empty-token short-circuit and any pre-`WindowsIdentity` parse failure
don't end up calling `CloseHandle(IntPtr.Zero)`:

```powershell
finally {
    if ($null -ne $winAuthToken -and $winAuthToken -ne [System.IntPtr]::Zero) {
        $win32Handler::CloseHandle($winAuthToken)
    }
}
```

Upstream `develop` is unchanged — line 987 still parses with `[Int]`
(re-verified 2026-07-14 against `develop` post-v2.13.4). Worth a PR.

Heads-up for the next rebase: `develop` adds a `Logs` runspace type to
`Add-PodeRunspace`'s `ValidateSet` and switches `throw $_.Exception` to
bare `throw` in `Runspaces.ps1`/`Schedules.ps1` — adjacent to patches 3
and 4 but different lines; expect at most trivial conflicts.

### 6. `src/Private/Tasks.ps1` — `Close-PodeTaskInternal` (real cancel) + `src/Public/Tasks.ps1` — `Get-PodeTaskProcess` snapshot

Stock `Close-PodeTaskInternal` tears a task down with
`Close-PodeDisposable → Dispose()` only. Two problems once tasks are closed
while RUNNING — which Orbital-Command now does routinely (manifest
`MaxRuntimeMinutes` → `Invoke-PodeTask -Timeout`, plus the
`/api/runs/:id/cancel` route):

1. **`Dispose()` on a running pipeline performs a synchronous `Stop()`.** A
   pipeline wedged inside a blocking native call (hung LDAP / WinRM — the
   exact things a runaway collector waits on) can never reach Stopped, so
   the housekeeper thread hangs and every future timeout enforcement dies
   with it. The patch calls `BeginStop()` (never blocks), polls
   `InvocationStateInfo.State` for up to 3 s, disposes only once the
   pipeline actually left Running/Stopping, and otherwise ABANDONS the
   object to the GC finalizer with a loud error-log entry. An abandoned
   runner slot stays busy until its blocking call returns — unavoidable on
   .NET Core (no thread aborts) — but the housekeeper survives to enforce
   every other task's timeout. **`Stopping` is deliberately treated exactly
   like `Running`** in both the entry check and the poll: a pipeline enters
   Stopping the instant a CONCURRENT Close calls `BeginStop` (the cancel
   route racing the housekeeper's expiry close); treating it as "already
   stopped" would `Dispose()` a not-yet-stopped pipeline — the very hang
   this patch exists to prevent. A state probe on a mid-teardown pipeline
   can throw `ObjectDisposedException` — caught and treated as "someone
   else already stopped it".
2. **Concurrent table mutation.** `Processes` is a plain hashtable — safe
   for many readers plus ONE writer; concurrent `.Remove()` is the same
   torn-state family patch #1 guards against. All three `Remove` paths are
   serialised via `Lock-PodeObject -Object
   $PodeContext.Threading.Lockables.Global`: Close's own Remove, and the
   housekeeper's orphan-sweep Remove (Runspace-null branch).
   `Get-PodeTaskProcess` additionally snapshots `.Values` (`@(...)`) —
   direct enumeration races a concurrent Remove into "Collection was
   modified" (the cancel route enumerates it per request).

Note: disposing `$Process.Result` in the abandoned branch is deliberate —
a wedged pipeline that eventually resumes and writes to its output
collection throws into the (already dead) task body, which helps kill it;
expect occasional `ObjectDisposedException` noise in the error log from
exactly that. Empirical stop-semantics ground truth (measured on PS7):
during a `BeginStop`, `finally` blocks still execute (including cmdlet
calls); `catch` blocks are SKIPPED — consumer code must put cleanup in
flag-guarded `finally` blocks.

Upstream `develop` is unchanged here (no `.Stop()`/`BeginStop` anywhere in
the task teardown path). Worth a PR together with patches 1/2.

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

### Compatibility checks before declaring the rebase done

Orbital-Command relies on two private-API surfaces that aren't covered by Pode's
test suite. Verify both still behave as expected after each rebase — they're
the load-bearing parts of the cold-start fix (Orbital-Command plan §15j):

1. **`Import-PodeModulesIntoRunspaceState` in `src/Private/AutoImport.ps1`** —
   must enumerate `Get-Module` and call `$PodeContext.RunspaceState.ImportPSModule()`
   for each loaded module BEFORE the task runspace pool is opened (currently
   ordered at `src/Private/Server.ps1:78` for auto-import vs `:96` for pool
   creation). Orbital-Command's `server.ps1` relies on this to preload the
   ActiveDirectory module into every task runspace via the cloned
   `InitialSessionState`. If the rebase reorders pool creation BEFORE auto-import,
   AD-task routes will pay the cold-load cost on every first call after
   restart (~30s) and the `<No file>: line N` error class returns.
2. **`Set-PodeTaskConcurrency`** — must remain public and accept `-Maximum N`.
   Used at `Orbital-Command/server.ps1` task-pool-sizing block.

Smoke test after rebase: restart `server.ps1`, hit `/api/users/<sam>/groups/fresh`
within the first 10 seconds of healthy. Should respond in ≤4s and emit zero new
entries in `logs/errors_*.log`. If first-call latency is >20s or the line-26
error reappears, the auto-import ordering broke.

## Not upstreamed

Deliberate, as of 2026-05-15. Observing locally first to confirm the patches
resolve the recurring task-pool errors in production before submitting a PR
to Badgerati/Pode. This document is precise enough to lift into a PR
description when we're ready.
