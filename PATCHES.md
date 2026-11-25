# Orbital-Command local patches against Pode 2.14.2

This fork is consumed by the Orbital-Command platform
(`C:\Users\d150111\Documents\Git\Orbital-Command`), imported in `server.ps1`
via `Import-Module ..\Pode\src\Pode.psd1 -Force`. Ten patches live here:
four concurrency races in the task/schedule-pool plumbing, one Int32
truncation in the IIS auth handler, a real-cancel rework of the task
teardown path (stop before dispose), HTTP listener thread-pool starvation,
a 2.14 custom-log-type regression, and the forced garbage collections after
every timer tick (9) and after every task and schedule run (10).
Supply-Depot also consumes this fork.
Everything else is unchanged upstream, apart from the build-script default
under "Build and CI".
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
    instead of the fixed 1 minute. The Failed branch gets a null check too.
    The task body sets `State = 'Failed'` in its catch, logs, and stamps
    `CompletedTime` only in its finally, so a tick can land in between.
    The housekeeper then starts the retention itself (stamps `CompletedTime`)
    instead of throwing on `AddMinutes($null)`. The first version closed
    such a process at once, which skipped the retention; an injected
    process in that state was gone after one tick then and is kept now.
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

## The ten patches

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

Bonus fix: `$PodeContext.Tasks.Processes.Keys.Clone()` is not a snapshot.
`KeyCollection` has no `Clone()`, so PowerShell's member enumeration clones
each key string while walking the live collection; a concurrent writer makes
it throw "Collection was modified" (measured on PS7: ~33,600 failures in
3.5 s against one writer thread). Upstream restored exactly this form in
#1782. Replaced with `@(...Keys)` copied while holding the table's own lock
(see patch 6).

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
2. **Concurrent table access.** Since 2.14 (#1758) both `Tasks.Processes`
   and `Schedules.Processes` are `[hashtable]::Synchronized`, so single
   adds/removes are atomic and take the table's `SyncRoot`. Every reader
   that walks a table copies it while holding that same lock
   (`Lock-PodeObject -Object $PodeContext.Tasks.Processes` /
   `...Schedules.Processes`): both housekeepers, the shutdown drain in
   `Close-PodeRunspace`, `Get-PodeTaskProcess` and `Get-PodeScheduleProcess`
   (the cancel route enumerates the task table per request). Writers need no
   extra lock. On 2.13.4 (plain hashtables) all of this went through
   `Lockables.Global`; on 2.14 that lock no longer excluded upstream's own
   writers (e.g. schedule inserts), so it was retargeted.
   `tests/unit/ProcessTableSnapshot.Tests.ps1` pins it: with a writer
   runspace adding/removing entries, an unlocked copy fails (control), and
   both getters return 0 errors. Against the Global-lock version the same
   test sees hundreds to thousands of failures.

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

### 8. `src/Private/Logging.ps1` — `Add-PodeLogTypeInternal` default `-Version 1`

New in 2.14.2, found while testing the 2.14.2 port. A custom log type added
without `-Version` (which is how `Add-PodeLogger` / `Add-PodeLogType
-ScriptBlock` is normally called, including Orbital-Command's and
Supply-Depot's `csp` logger) never receives its `Write-PodeLog` item.

`Add-PodeLogType` declares `$Version = 1` and forwards `@PSBoundParameters`
to `Add-PodeLogTypeInternal`. `PSBoundParameters` never contains defaults,
and the internal `[int]$Version` had none, so the type was stored with
Version **0**. `Start-PodeLoggingRunspace` switches on 1 / 2 to build the
scriptblock's arguments; with 0 neither branch runs, and the scriptblock is
called with whatever `$_args` held from the previous log event: `$null`, or
another log type's data (observed: a request-log `OrderedDictionary` written
into the csp log). Measured on pristine upstream 2.14.2 with both the
deprecated alias and the new `New-PodeLogFileMethod | Add-PodeLogType` API;
`-Version 2` was unaffected. 2.13.4 passed the item correctly.

Patch: `$Version = 1` on the internal parameter.
`tests/unit/Logging.Tests.ps1` (`Add-PodeLogType`) pins Version 1 for an
unset `-Version` (direct and via `Add-PodeLogger`) and an explicit 2; without
the patch the two Version-1 tests fail with "Expected 1, but got 0".
Not reported upstream yet. Worth an issue + PR.

### 9. `src/Private/Timers.ps1` — `Invoke-PodeInternalTimer` without a forced collection

Upstream ends every timer run (each tick, and `Invoke-PodeTimer`) with
`finally { Invoke-PodeGC }`, which is `[System.GC]::Collect()`: a blocking
gen2 collection that suspends every managed thread, request workers
included. Pode's own housekeepers are timers: cache (10 s), task (20 s, once
a task is defined) and schedule (30 s, once a schedule is defined). Neither
app adds a timer of its own, so these are the only timers in both. With all
three running that is about 11 forced collections a minute, idle or not.

The patch drops that `finally`; the timer body and its error logging are
unchanged. That removes the timer-tick collections and nothing else. With
patch 9 alone these stay forced; patch 10 removes all of them except the one
in `Close-PodeRunspace`:

- At the end of every schedule run (`Get-PodeScheduleScriptBlock`) and every
  task run (`Get-PodeTaskScriptBlock`), and in `Close-PodeRunspace`
  (shutdown, restart).
- Supply-Depot: a schedule tick dispatches a `run-script` task
  (`Platform-Core/11a-Schedules.ps1`, `Invoke-PlatformScheduleTrigger`), so
  one tick is two collections. `Send-Webhooks` ships with `*/5 * * * *`,
  enabled, which makes about 24 an hour; the AD syncs, nightly jobs and every
  manual script run add to that.
- Orbital-Command: `over-budget-run-reaper` (`server.ps1`, `*/5 * * * *`) is
  registered even when automation is paused, so at least 12 an hour on an idle
  server; each configured script schedule adds two per tick. Every
  `Invoke-AdReadInFreshRunspace` (`Platform-Core/09-AdComputerFields-AdReads.ps1`)
  runs one `ad-read` task. Its `finally` collects before `Wait-PodeTask`
  returns, so each interactive AD read (the user, group and computer
  `/fresh` reads, quick actions and others) pauses every request and makes
  its own caller wait for the collection.

Measured on a Supply-Depot side server with a production-sized database
(~1 GB managed heap from the start: every runspace imports the app's
modules), with `SD_SUPPRESS_SCHEDULES=1`, so no schedule ran and the cron
collections above were not measured. Under steady list reads each forced
collection paused the process 0.5-2.0 s (median 0.6-1.1 s). In 5 minutes
there were 43 induced gen2 collections, one per timer tick (28 + 15), all on
the timer runspace's thread; 37 of 38 `/api/health` stalls over 150 ms
overlapped one.

Three servers then ran side by side through two consecutive windows of 30 and
50 minutes (80 minutes), `/api/health` every 250 ms: unpatched, patched, and a
copy with no forced collection anywhere. Results:

- Stalls: unpatched 732, p99 0.7-1.2 s; patched 56, p99 30-64 ms. The 40
  forced collections left on the patched server came from the load script's
  task run every 2 minutes.
- Gen2 process counters: patched 80 (40 of them those forced ones); no-forced
  copy 55. The event probe recorded the forced ones and, on the no-forced
  copy, two others. The runtime's total-pause counter equals the recorded
  pauses within a second, so the rest of the runtime's own gen2 collections
  ran in the background.
  A blocking full collection the runtime starts itself still happens now and
  then: one of 2,537 ms (allocation-triggered) on the no-forced copy, and one
  of 2,337 ms (low-memory reason) in a separate idle run of this patch. The
  unpatched server had low-memory ones too.
- Private bytes after 80 minutes: 1,500 MB unpatched, 1,501 MB patched,
  1,511 MB with no forced collection; the patched server stayed between 1,336
  and 1,503 MB from minute 30 on.

`tests/unit/Timers.Tests.ps1` (`Invoke-PodeTimer`) ticks a timer ten times
and counts the ticks during which a full blocking collection happened
(`GC.GetGCMemoryInfo(GCKind.FullBlocking).Index`). It allows one, for a
blocking collection the runtime starts itself. The runtime's own gen2 runs in
the background, so a gen2 count would also include unrelated collections.
Upstream's code fails it with 10; a version that collects on every other tick
fails with 5. It passed 10 runs alone and 10 runs beside a thread allocating
64 MB arrays (110-210 background gen2 per run). PS7 only (`GCKind` is .NET 5+),
skipped on Windows PowerShell like patch 7's fixture. Not reported upstream
yet.

On the next upstream upgrade, check that:

- `Invoke-PodeInternalTimer` still has no `Invoke-PodeGC` and no direct
  `[System.GC]::Collect` (`Timers.Tests.ps1` pins it).
- No new internal timer has appeared (`Add-PodeTimer -Name '__pode_`).
- No new collection call site has appeared (`Invoke-PodeGC`,
  `[System.GC]::Collect`, `[GC]::Collect` under `src/`).

### 10. `src/Private/Tasks.ps1` / `src/Private/Schedules.ps1` — no forced collection after a task or schedule run

Upstream ends every task run (`Get-PodeTaskScriptBlock`) and every schedule
run (`Get-PodeScheduleScriptBlock`) with `Invoke-PodeGC` in the run's
`finally`. It is the same blocking gen2 collection as in patch 9, suspending
every request thread. Patch 10 drops both calls; `Reset-PodeRunspaceName` and
the rest of each `finally` stay. After patches 9 and 10, the only forced
collection left is in `Close-PodeRunspace`, at shutdown and restart.

How often these ran is in patch 9's "stay forced" list:

- Supply-Depot: two per schedule tick, about 24 an hour from `Send-Webhooks`
  alone.
- Orbital-Command: the 5-minute reaper; and one per interactive AD read, which
  its own caller waits for, because `Wait-PodeTask` returns only after the
  task's `finally`.

What the collection could release. When the `finally` runs, the run's
PowerShell instance, its pipeline, the `Result` collection, the process entry
and the run's parameters (`ArgumentList`, `$using:` copies) are all still
referenced from `Tasks.Processes` / `Schedules.Processes`. That collection
can free none of them, only the run's own temporaries that went out of scope,
plus whatever earlier runs had already closed. Those objects are released
explicitly and later:

- Tasks: `Close-PodeTaskInternal` disposes the pipeline and `Result` and
  removes the entry. `Wait-PodeTask` calls it, or the task housekeeper after
  the completed or failed retention (patches 1, 2, 6).
- Schedules: `Close-PodeScheduleInternal` does the same, from the schedule
  housekeeper (patch 4).
- Runspaces are pooled and reused, not freed per run.

Nothing in the task or schedule machinery depends on the collection. The only
finalizer path is patch 6's abandoned wedged pipeline, and a collection cannot
reclaim that while it is still blocked.

What the collections were for everything else. `[GC]::Collect()` collects the
whole process. With patch 9 in place, these collections were the only regular
finalization cadence left for all other garbage, request runspaces included:

- at least one every 5 minutes in each app (Orbital-Command's
  `over-budget-run-reaper`, Supply-Depot's `Send-Webhooks`);
- plus one per AD read in Orbital-Command.

Patch 10 removes that cadence. Finalizers now run when the runtime itself
collects:

- gen0/gen1 every 0.5 to 2.5 minutes in the review's idle run of patch 9
  (no load, no schedule);
- gen2 about every 1.3 minutes under load in this run, and every 2 minutes
  with only the health poll and the minute schedule;
- a gen2 is not guaranteed while a server is truly idle.

One path where "later" might matter, unmeasured and uncertain: ADSI objects
that Orbital-Command never disposes and that were promoted to gen2. They
keep ADSI's cached LDAP connection open until the next gen2, possibly past
the domain controller's idle timeout (`MaxConnIdleTime`, 900 s by default).
Whether ADSI then reconnects transparently was not tested.
`Zuescho/Orbital-Command#1181` disposes those objects; roll patch 10 out to
Orbital-Command with or after it.

If a finalization cadence is ever wanted back, a local
`[GC]::Collect(2, [GCCollectionMode]::Forced, $false)` in the two `finally`
blocks gives it as a background collection; the public `Invoke-PodeGC` would
stay as it is. The review measured it in an isolated process (713 MB heap,
20,000 finalizable objects in gen2): that call returned in 0.4-0.6 ms, paused 1.0-1.7 ms, and finalized
all 20,000 within 3 s, against 181-388 ms for `[GC]::Collect()`. It has not
been measured inside Pode under load.

Measured on three Supply-Depot side servers side by side (unpatched, patch 9,
patches 9 + 10), each on a copy of the production-sized database, for
67 minutes. `SD_SUPPRESS_SCHEDULES=1` stayed set, so no real schedule could
act. The real path was exercised two ways:

- A diagnostic schedule registered every minute through the app's own
  trigger: schedule run → `Invoke-PlatformScheduleTrigger` → `run-script`
  task → `Find-DuplicateLocations`.
- A manual `Test-AuditChain` run every 2 minutes.

List-read load ran to minute 45, then the servers idled with the schedule
still ticking. `/api/health` was polled every 250 ms for 65 minutes, and a GC
event probe and 30-second counter samples ran inside each process. Minutes in
the table count from the start of the health poll.

| | unpatched | patch 9 | patches 9 + 10 |
|---|---|---|---|
| `/api/health` stalls over 150 ms | 795 | 168 | 19 |
| p99 | 1,144 ms | 487 ms | 38 ms |
| induced gen2 collections | 835 | 152 | 0 |
| time paused by them | 700 s | 137 s | 0 |
| all GC pauses, first to last sample | 829 s | 243 s | 107 s |
| private bytes at min 45 / 55 / 65 | 1,400 / 1,652 / 1,492 MB | 1,460 / 1,474 / 1,436 MB | 1,536 / 1,534 / 1,536 MB |
| private bytes while idle (min 45 on), range | 1,400-1,758 MB | 1,424-1,488 MB | 1,533-1,536 MB |
| `GC.GetTotalMemory(false)` at min 45 / 65 | 1,121 / 1,116 MB | 1,170 / 1,130 MB | 1,141 / 1,129 MB |
| heap fragmentation at min 65 | 171 MB | 83 MB | 209 MB |
| last collection's finalization-pending count, max under load / idle | 73 / 26 | 49 / 56 | 10 / 40 |
| handles while idle | 1,259-1,288 | 1,267-1,305 | 1,262-1,305 |
| threads while idle | 44-48 | 44-47 | 45-48 |
| gen2 collections while idle | 258 | 42 | 10 |

How to read the table:

- `GC.GetTotalMemory(false)` includes garbage not yet collected. On the
  unpatched server, collected every few seconds, it is close to the live set;
  on patches 9 + 10 it is an upper bound. So the live set there is not larger
  than on the other two, and it is flat while idle.
- Private bytes on patches 9 + 10 sit 70-100 MB above patch 9 at the end
  (more fragmentation, fewer compactions). That is flat while idle, and within
  the range the unpatched server itself swings through. Private-bytes slopes
  are left out: on the sawtooth servers they depend on the window chosen.
- Fragmentation on patches 9 + 10, in 5-minute steps from the poll start: 91,
  66, 101, 176, 166, 142, 130, 147, 151, 199, 211, 211, 212, 209 MB. It
  stopped changing when the load stopped. The unpatched server swings between
  74 and 407 MB at the same steps. No run longer than 67 minutes exists, so a
  slow climb until the runtime's next compacting collection is possible and
  unmeasured.
- Handles and threads stayed flat. The finalization-pending figure is the
  last collection's snapshot, stale when collections are rare; it stayed low,
  but it does not show that the finalization queue never builds up.
- The runtime's own occasional blocking collection remains. The largest stall
  on patches 9 + 10 (1,695 ms) was one allocation-triggered blocking gen2 of
  1,659 ms at minute 5.4.

Tests:

- `tests/unit/Tasks.Tests.ps1` (`Get-PodeTaskScriptBlock`) and
  `Schedules.Tests.ps1` (`Get-PodeScheduleScriptBlock`) run the real
  end-of-run script block ten times each. Like patch 9's timer test, each
  counts the runs that saw a full blocking collection and allows one.
- With patch 9 alone both fail with 10.
- They passed ten runs per file, and ten runs of those two plus
  `Timers.Tests.ps1` in one process. The whole unit folder through
  `Invoke-Build Test -TestType Unit`: 1,980 passed, 1 NotRun.
- PS7 only, skipped on Windows PowerShell.

Not measured:

- Orbital-Command at runtime, including the per-user `ad-read` bursts of its
  `-Apply` add-ins (`Sync-SupplyDepotMobileNumbers`,
  `Sync-SupplyDepotOfficeMoves`: one AD read per target user, each until now
  followed by a collection); whether the ActiveDirectory module leaves ADWS
  channels to finalization; and the ADSI connection path above.
- Production.
- Anything longer than 67 minutes.
- No end-of-run flush was taken.

Not reported upstream yet.

On the next upstream upgrade, check that:

- `Get-PodeTaskScriptBlock` and `Get-PodeScheduleScriptBlock` still have no
  `Invoke-PodeGC` and no direct `[System.GC]::Collect` (`Tasks.Tests.ps1` and
  `Schedules.Tests.ps1` pin them).
- `Close-PodeRunspace` is the only caller of `Invoke-PodeGC` left under
  `src/`. The public `Invoke-PodeGC` itself is unchanged, for apps that call
  it.

## Build and CI

### `pode.build.ps1` — default `-Version` from the manifest

The apps load the fork straight from a checkout, so `src/Pode.psd1` pins
`ModuleVersion = '2.14.2'` where upstream keeps the `'$version$'` placeholder
until its release build stamps it. `Pode.psm1` compares a `Pode.dll` that is
already loaded in the process with that version and skips the comparison only
for the placeholder. Upstream's build defaults `-Version` to `0.0.0`, so the
`Invoke-Build Test` that every "Pode CI" workflow runs built a 0.0.0.0
listener. The compliance tests import the module first (nothing loaded yet,
so no comparison) and load that DLL; the unit suite's `Setup.ps1` then
re-imports with `-Force` in the same process and is refused with "An existing
incompatible Pode.DLL version 0.0.0.0 is loaded. Version 2.14.2.0 is
required." Discovery of 31 of the 32 unit files failed on every workflow and
platform, and the unit and integration suites never ran on this branch.

Fix: when `-Version` is not passed, the build takes `ModuleVersion` from
`src/Pode.psd1`, unless it is the placeholder. CI now builds the listener from
`src/Listener` (unchanged from upstream) as 2.14.2 and runs every suite
against it. That build's `Pode.deps.json` matches the committed one; the DLLs
are the same size and differ only as separate builds do. CI does not load the
committed `src/Libs` binaries themselves. A build that passes `-Version` (the
release workflow) is unaffected, and with the placeholder the behaviour is
upstream's.

Measured locally with `Invoke-Build Test` (pwsh 7.6, .NET SDK 10, Pester
6.0.1): before, compliance 5,394 passed and the unit run failed exactly as in
CI; after, compliance 5,394 passed, unit 1,977 passed, 0 failed, 1 NotRun
(upstream v2.14.2's CI: 1,963 passed, 1 NotRun, without the fork's tests).
Integration failed one test only on this German-locale workstation
(`WebSocket` date regex against `25.11.2026`); the build sets only the UI
culture, and the CI runners format dates in `en-US`.

Running `Invoke-Build Build` or `Test` locally replaces the committed
`src/Libs` (and the `MoveLibs` step rewrites `licenses/LICENSE.redoc.txt`):
restore them with `git checkout -- src/Libs licenses` before committing.

Upstream status: not applicable; upstream's manifest keeps the placeholder.
Re-check on the next upgrade: if `pode.build.ps1` conflicts, keep the block
right after the `param()` block; after pinning `ModuleVersion`, the "Run
Pester Tests" step must report unit totals, not "Container failed".

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
