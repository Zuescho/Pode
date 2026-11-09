# Orbital-Command local patches against Pode 2.14.2

This fork is consumed by the Orbital-Command platform
(`C:\Users\d150111\Documents\Git\Orbital-Command`), imported in `server.ps1`
via `Import-Module ..\Pode\src\Pode.psd1 -Force`. Seven patches live here:
four concurrency races in the task/schedule-pool plumbing, one Int32
truncation in the IIS auth handler, and a real-cancel rework of the task
teardown path (stop before dispose), and HTTP listener thread-pool starvation. Supply-Depot also consumes this fork. Everything else is unchanged upstream.
See Orbital-Command's `docs/Platform-Plan.md` §15d for the concurrency-race
diagnosis.

## Branch state

- Branched from upstream tag `v2.13.2` on `orbital-command-patches`;
  rebased onto `v2.13.4` on 2026-07-14 (clean rebase, no conflicts —
  upstream's only touch on a patched file was `Invoke-PodeAuthEvent` in
  `Authentication.ps1`, a different function than our patch 5 target).
  `src/Libs/` refreshed from the PSGallery 2.13.4 release (picks up the
  #1717 socket-close fix in `PodeRequestHandler.cs`).
- Re-applied onto `v2.14.2` on 2026-11-09 as one commit per patch (not a
  replay of the 13-commit 2.13.4 history). Conflicts and changes vs. the
  2.13.4 patch set:
  - Upstream 2.14.x added the missing-entry check (`$null -eq $process`) to
    both housekeepers; our duplicate (1a, and the same check in patch 4) is
    dropped.
  - Upstream added task retention periods (#1783). The Completed branch keeps
    our `CompletedTime` null check but uses `$task.Retention.Completed`
    instead of the fixed 1 minute; the Failed branch gets the same null
    check (a Failed process without `CompletedTime` is closed right away
    instead of throwing every tick).
  - Patch 7's test fixture follows `PodeItemQueue` to
    `src/Listener/Utilities/Structures/` (`Pode.Utilities.Structures`).
  - `src/Libs/` is the PSGallery 2.14.2 `Libs`, byte-identical to the Libs in
    the GitHub release `2.14.2-Binaries.zip` (whose SHA256 matches the release
    notes). Required: 2.14.2's `Start-PodeWebServer` calls the new
    `PodeHttpListener(IPodeLogger, CancellationToken)` constructor.
  - `Pode.Internal.psd1` is now pinned too (2.13.4 left it at 2.13.2).
- `upstream` remote points at https://github.com/Badgerati/Pode.git.
- `git log v2.14.2..HEAD` shows our delta as discrete commits. The 2.13.4
  state is kept at tag `oc-patches-2.13.4` (`3db2e6ab`).

## The seven patches

### 1. `src/Private/Tasks.ps1` — `Start-PodeTaskHousekeeper`

Five null-deref / race fixes in the recurring 20-second housekeeper timer
that empties `$PodeContext.Tasks.Processes`:

| # | Problem | Fix |
|---|---|---|
| a | `$process` can be `$null` between `Keys.Clone()` and `Processes[$key]` if another thread races `Close-PodeTaskInternal`. | Fixed upstream in 2.14.x — our copy dropped. |
| b | `$process.Task` can be `$null` on a half-constructed entry inserted by `Invoke-PodeTaskInternal` (line 199) but not yet completed (line 226). | `if ($null -eq $process.Task) { continue }` |
| c | `$task = $PodeContext.Tasks.Items[$process.Task]` can return `$null` if the task was removed mid-flight via `Clear-PodeTasks` / `Remove-PodeTask`. | No retention/retry policy is left, so close the process once it has finished, and keep enforcing its timeout while it runs. (Until the 2.14.2 port this was a bare `continue`, which kept such processes and their result buffers forever and dropped their timeout.) |
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
`Schedules`, etc.) at `Private/Server.ps1:99` — AFTER it invokes the user
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
`Server.ps1:100` later replaces the lazy pool with the canonical one for
that type, so this is genuinely a startup-window shim, not a permanent
extra pool. `.Open()` is idempotent.

Two additions from the 2.14.2 review (both bugs existed on 2.13.4 too):

- **Restart.** `Restart-PodeServer` closes and disposes the pools but keeps
  the wrappers, then re-runs the server scriptblock before
  `New-PodeRunspacePool`. The old `$null` check didn't fire, so every
  `Invoke-PodeTask` from the scriptblock failed with "runspace pool is not
  in the 'Opened' state. The current state is 'Closed'". As of 2026-11-09
  neither consumer invokes a task from its server scriptblock any more
  (Orbital-Command dropped its AD pre-warm; Supply-Depot only dispatches from
  routes and schedules), so this path is dormant in both: the fix keeps the
  patch correct for when one does. A wrapper whose pool
  is disposed / Closed / Closing / Broken is now treated as missing. A
  canonical pool that is merely not opened yet (`BeforeOpen`) is left alone.
- **Leak.** `New-PodeRunspacePool` replaces the lazy wrapper and drops the
  pool. Lazy pools are now recorded in `$PodeContext.Server.LazyRunspacePools`
  and `Close-PodeRunspacePool` disposes them (shutdown and restart). Before,
  each restart leaked one more pool. Work already queued on a lazy pool
  keeps running until then, so during the startup window the task
  concurrency limit can briefly be exceeded, and those runspaces don't have
  the modules auto-imported after the scriptblock ran (the pool clones the
  session state when it's created). Reusing the lazy pool instead would
  lose the auto-imported modules for every later task, which Orbital-Command
  relies on (§15j).

`tests/unit/LazyRunspacePool.Tests.ps1` pins: creation + record, replacing a
disposed pool, leaving a `BeforeOpen` canonical pool alone, and disposal by
`Close-PodeRunspacePool`.

### 4. `src/Private/Schedules.ps1` — `Start-PodeScheduleRunspace` housekeeper

Pode 2.13.2 ships the same race-vulnerable housekeeper for schedules as for
tasks: line 34 dereferences `$process.Runspace.Handler.IsCompleted` without
a null-check, and line 29 uses `Keys.Clone()` on a synchronized hashtable.
Mirror the task-housekeeper patch: `@(Keys)` snapshot, null-checks for
`$process` / `$process.Runspace` / `$process.ExpireTime` before
dereferencing. Same surfaced symptom (`You cannot call a method on a
null-valued expression`), same fix shape.

A record whose `Runspace` is still `$null` is swept once its `ExpireTime`
has passed or 60 s after `CreateTime` (an orphan: `Add-PodeRunspace` threw
inside `Invoke-PodeInternalSchedule`, so it never gets a runspace). Until the
2.14.2 review it was skipped forever, a leak upstream's own expiry check
didn't have. Probe: an injected orphan stays in the table on 2.13.4 and is
gone after one housekeeper tick with the fix.

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

Upstream is unchanged — v2.14.2 line 987 still parses with `[Int]`
(re-verified 2026-11-09). Worth a PR.

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

Upstream is unchanged here as of v2.14.2 (no `.Stop()`/`BeginStop` anywhere
in the task teardown path). Worth a PR together with patches 1/2.

### 7. `src/Private/PodeServer.ps1` — HTTP context acquisition without CLR pool starvation

Supply-Depot issue [#294](https://github.com/Zuescho/Supply-Depot/issues/294)
reported ten-second HTTP timeouts after the health probe had already succeeded.
Each HTTP listener already runs on a dedicated PowerShell runspace. Calling
`Wait-PodeTask -Task $Listener.GetContextAsync(token)` also schedules a CLR pool
task that blocks in `PodeItemQueue.Get` / `BlockingCollection.Take`. Sixteen idle
HTTP workers can therefore starve the socket receive tasks that must put the
next request into that same queue.

Call the existing synchronous `GetContext(token)` on the dedicated runspace.
The same cancellation token, queue dequeue, processing bookkeeping and outer
`OperationCanceledException` catch remain in use. Other consumers and the
asynchronous queue API are unchanged; no listener DLL rebuild is needed.
This does not remove the separate cold runspace initialization delay and does
not extend request timeouts or change configured HTTP worker concurrency.

Evidence on PowerShell 7 with `DOTNET_PROCESSOR_COUNT=2`:

- The actual queue implementation with sixteen pooled waiters delayed a queued
  producer 12,283 ms (pool grew from 3 to 17 threads). Dedicated waiters delivered
  in 31 ms with 3 pool threads.
- A minimal real HTTP server with sixteen workers took 7,438 / 3,512 ms for
  requests after its first successful response before the fix, versus 7 / 3 ms
  after it. In a second patched run, post-readiness calls took 3 / 5 / 2 ms,
  and 32 concurrent requests all succeeded in 88 ms.
- Four workers were a useful control: both builds answered post-readiness calls
  in 3–10 ms and all 32 concurrent requests succeeded (200 / 207 ms). The defect
  depends on pool pressure; a fast low-concurrency run cannot disprove it.
- Full Supply-Depot HTTP smoke with two logical processors passed all 1,282
  assertions against the patched fork.

`tests/unit/HttpListenerAcquire.Tests.ps1` runs the actual acquisition AST and
actual queue implementation in a throwaway process with sixteen dedicated
PowerShell workers and only two CLR pool slots. It verifies delivery, cancellation
of the fifteen remaining workers, processing removal and disposed-queue behavior.
Restoring the old acquisition makes all three pins fail: the producer never runs
within the window, all sixteen workers cancel, and no item reaches processing.
The complete Pode unit suite passes 1,949 tests with no failures; Pester reports
one existing helper test as NotRun (1,950 discovered). Changed-file PSScriptAnalyzer is clean.
Pool limits are changed only inside the test process. The fixture is PS7-only,
matching the investigated environment; normal production APIs remain PS5-compatible.

## Upgrade procedure

When Pode releases a new version:

```powershell
cd C:\Users\d150111\Documents\Git\Pode
git fetch upstream --tags
git rebase --onto v<next> v<current>   # on a copy of orbital-command-patches
```

Inspect `git log v<next>..HEAD` — that's the patch set. If upstream fixed one
of the patches, drop that commit (or hunk) during the rebase. Re-test by
restarting Orbital-Command's `server.ps1` and watching `logs/errors_*.log`.

Also refresh `src/Libs/` (it is git-ignored upstream, so `git add -f`) and pin
`ModuleVersion` in both `Pode.psd1` and `Pode.Internal.psd1`. Download from the
adm session (the desktop user's web filter blocks it) and verify the binaries
against the GitHub release zip, whose SHA256 is in the release notes:

```powershell
Save-Module Pode -RequiredVersion <next> -Path <empty-dir>
gh release download v<next> -R Badgerati/Pode -p '*Binaries.zip' -D <other-empty-dir>
# compare file hashes of <empty-dir>\Pode\<next>\Libs with the zip's Libs, then:
Remove-Item src/Libs -Recurse -Force
Copy-Item <empty-dir>\Pode\<next>\Libs -Destination src/Libs -Recurse
```

### Compatibility checks before declaring the rebase done

Orbital-Command relies on two private-API surfaces that aren't covered by Pode's
test suite. Verify both still behave as expected after each rebase — they're
the load-bearing parts of the cold-start fix (Orbital-Command plan §15j):

1. **`Import-PodeModulesIntoRunspaceState` in `src/Private/AutoImport.ps1`** —
   must enumerate `Get-Module` and call `$PodeContext.RunspaceState.ImportPSModule()`
   for each loaded module BEFORE the task runspace pool is opened (currently
   ordered at `src/Private/Server.ps1:81` for auto-import vs `:99` for pool
   creation, as of 2.14.2). Orbital-Command's `server.ps1` relies on this to preload the
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

### Known 2.14.2 log noise (not a regression from these patches)

At most one entry right after startup:

```
Message: You cannot call a method on a null-valued expression.
StackTrace: at <ScriptBlock>, <No file>: line 28
```

It's the web listener (`Start-PodeWebServer`, line 28 of its scriptblock with
patch 7's comment lines, line 26 on pristine upstream) getting a context whose
`Request.Strategy` is still `$null`. The outer `finally` disposes the context,
so nothing leaks and no client request goes unanswered. It's timing-dependent:
pristine upstream 2.14.2 produces it at startup in roughly half of the test
starts (a probe that only polls `/ping`), and the 2.13.4 fork never did in the
same runs. Connections that are opened and dropped after startup don't
trigger it (30 empty connects, 30 half requests, 30 abandoned requests: no
entries). Under IIS, ANCM's startup port probes may cause one per app-pool
start. Not worth a patch; worth an upstream issue. Not the same as the
warmup-poller variant, which repeats for every abandoned queued context.

## Not upstreamed

Deliberate, as of 2026-05-15. Observing locally first to confirm the patches
resolve the recurring task-pool errors in production before submitting a PR
to Badgerati/Pode. This document is precise enough to lift into a PR
description when we're ready.
