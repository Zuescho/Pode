function Test-PodeTasksExist {
    return (($null -ne $PodeContext.Tasks) -and (($PodeContext.Tasks.Enabled) -or ($PodeContext.Tasks.Items.Count -gt 0)))
}

function Start-PodeTaskHousekeeper {
    if (!(Test-PodeTasksExist)) {
        return
    }

    Add-PodeTimer -Name '__pode_task_housekeeper__' -Interval 20 -ScriptBlock {
        # [Orbital-Command patch] Five concurrency fixes vs. upstream 2.13.2.
        # See PATCHES.md at the repo root and plan §15d in Orbital-Command.
        try {
            # return if no task processes
            if ($PodeContext.Tasks.Processes.Count -eq 0) {
                return
            }

            # get the current time
            $now = [datetime]::UtcNow

            # [Orbital-Command patch] Keys.Clone() does not safely snapshot a
            # synchronized hashtable on PowerShell 7 — calling Remove() inside
            # the loop throws "Collection was modified". @(...) materialises
            # a real array.
            $keysSnapshot = @($PodeContext.Tasks.Processes.Keys)

            # loop through each process
            foreach ($key in $keysSnapshot) {
                try {
                    # get the process and the task
                    $process = $PodeContext.Tasks.Processes[$key]

                    # [Orbital-Command patch] $process may have been removed by
                    # Close-PodeTaskInternal between the snapshot and now.
                    if ($null -eq $process) { continue }
                    # [Orbital-Command patch] Half-constructed entry — Task
                    # name not set yet. Skip; Items[$null] would null-deref.
                    if ($null -eq $process.Task) { continue }

                    $task = $PodeContext.Tasks.Items[$process.Task]

                    # [Orbital-Command patch] Items[$name] returns $null if
                    # the task was removed (Clear-PodeTasks / Remove-PodeTask)
                    # while one of its processes was still in flight. The
                    # Failed branch below would null-deref $task.Retry.Max.
                    if ($null -eq $task) { continue }

                    # [Orbital-Command patch] $process.Runspace is $null in two
                    # cases: (a) the brief window inside Invoke-PodeTaskInternal
                    # between inserting the process and assigning its runspace
                    # (transient — skip and let the next pass see it), or
                    # (b) Add-PodeRunspace itself threw and left an orphan
                    # (permanent — sweep after 60s).
                    if ($null -eq $process.Runspace) {
                        if ($null -ne $process.CreateTime -and
                            $process.CreateTime.AddSeconds(60) -lt $now) {
                            $null = $PodeContext.Tasks.Processes.Remove($key)
                        }
                        continue
                    }

                    # if completed, and no completed time set, then set one and continue
                    if ($process.Runspace.Handler.IsCompleted -and ($null -eq $process.CompletedTime)) {
                        $process.CompletedTime = $now
                        $process.State = 'Completed'
                        continue
                    }

                    # if the process is completed, then close and remove
                    # [Orbital-Command patch] Null-check CompletedTime before
                    # AddMinutes(1) — State='Completed' without CompletedTime
                    # shouldn't normally happen but does for residual orphans.
                    if (($process.State -ieq 'Completed') -and `
                        ($null -ne $process.CompletedTime) -and `
                        ($process.CompletedTime.AddMinutes(1) -lt $now)) {
                        Close-PodeTaskInternal -Process $process
                        continue
                    }

                    # has the process failed?
                    if ($process.State -ieq 'Failed') {
                        # if we have hit the max retries, then close and remove
                        if ($process.Retry.Count -ge $task.Retry.Max) {
                            Close-PodeTaskInternal -Process $process
                            continue
                        }

                        # if we aren't auto-retrying, then continue
                        if (!$task.Retry.AutoRetry) {
                            continue
                        }

                        # if the retry delay hasn't passed, then continue
                        if (($null -eq $process.Retry.From) -or ($process.Retry.From -gt $now)) {
                            continue
                        }

                        # restart the process
                        Restart-PodeTaskInternal -ProcessId $process.ID
                        continue
                    }

                    # if the process is running, and the expire time has passed, then close and remove
                    # [Orbital-Command patch] Null-check ExpireTime symmetric
                    # to CompletedTime above.
                    if ($null -ne $process.ExpireTime -and $process.ExpireTime -lt $now) {
                        Close-PodeTaskInternal -Process $process
                        continue
                    }
                }
                catch {
                    $_ | Write-PodeErrorLog
                }
            }

            $process = $null
        }
        catch {
            $_ | Write-PodeErrorLog
        }
    }
}

function Close-PodeTaskInternal {
    param(
        [Parameter()]
        [hashtable]
        $Process,

        [switch]
        $Keep
    )

    # return if no process
    if ($null -eq $Process) {
        return
    }

    # [Orbital-Command patch #6] Real cancel + guarded teardown.
    #
    # Stock Pode only calls Close-PodeDisposable → Dispose() here. Two
    # problems with that once tasks are closed while RUNNING (timeout expiry
    # or an explicit Close-PodeTask):
    #   a) PowerShell.Dispose() on a running pipeline performs a SYNCHRONOUS
    #      Stop() — a pipeline wedged inside a blocking native call (hung
    #      LDAP/WinRM) can therefore hang the housekeeper thread, and with it
    #      every future timeout enforcement. BeginStop() never blocks; give
    #      the pipeline a short window to reach a stopped state and only then
    #      dispose. If it won't stop, abandon the object to the GC finalizer
    #      and log loudly — there is no way to abort a thread stuck in native
    #      code on .NET Core, so the runner slot is lost until the call
    #      returns either way; what we're protecting is the housekeeper.
    #   b) With Close now callable from HTTP routes, two Closes can race each
    #      other (route + housekeeper expiry) — serialise the Processes
    #      mutation via the global lockable. Hashtable tolerates concurrent
    #      readers with ONE writer; concurrent Removes are the same torn-state
    #      family the housekeeper snapshot patch (#1) exists for.
    $pipeline = $null
    if (($null -ne $Process.Runspace) -and ($null -ne $Process.Runspace.Pipeline)) {
        $pipeline = $Process.Runspace.Pipeline
    }

    if ($null -ne $pipeline) {
        $stopped = $true
        try {
            if ($pipeline.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running) {
                $stopped = $false
                try { $null = $pipeline.BeginStop($null, $null) } catch { }
                $deadline = [datetime]::UtcNow.AddSeconds(3)
                while ([datetime]::UtcNow -lt $deadline) {
                    if ($pipeline.InvocationStateInfo.State -ne [System.Management.Automation.PSInvocationState]::Running) {
                        $stopped = $true
                        break
                    }
                    Start-Sleep -Milliseconds 100
                }
            }
        }
        catch {
            # reading InvocationStateInfo on a mid-teardown pipeline can throw
            # ObjectDisposedException — another Close got here first; nothing
            # left for us to stop.
            $stopped = $true
        }

        if ($stopped) {
            Close-PodeDisposable -Disposable $pipeline
        }
        else {
            try {
                [System.Exception]::new("Task process '$($Process.ID)' ($($Process.Task)) did not stop within 3s of BeginStop - pipeline abandoned to the GC finalizer; its task-pool slot stays busy until the blocking call returns.") | Write-PodeErrorLog
            } catch { }
        }
    }

    Close-PodeDisposable -Disposable $Process.Result

    # remove the process (serialised — see header comment)
    if (!$Keep) {
        Lock-PodeObject -Object $PodeContext.Threading.Lockables.Global -ScriptBlock {
            $null = $PodeContext.Tasks.Processes.Remove($Process.ID)
        }
    }
}

function Invoke-PodeTaskInternal {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Task,

        [Parameter()]
        [hashtable]
        $ArgumentList = $null,

        [Parameter()]
        [int]
        $Timeout = -1,

        [Parameter()]
        [ValidateSet('Default', 'Create', 'Start')]
        [string]
        $TimeoutFrom = 'Default'
    )

    try {
        # generate processId for task
        $processId = New-PodeGuid

        # setup event param
        $parameters = @{
            ProcessId    = $processId
            ArgumentList = $ArgumentList
        }

        # what's the timeout values to use?
        if ($TimeoutFrom -eq 'Default') {
            $TimeoutFrom = $Task.Timeout.From
        }

        if ($Timeout -eq -1) {
            $Timeout = $Task.Timeout.Value
        }

        # what is the expire time if using "create" timeout?
        $expireTime = [datetime]::MaxValue
        $createTime = [datetime]::UtcNow

        if (($TimeoutFrom -ieq 'Create') -and ($Timeout -ge 0)) {
            $expireTime = $createTime.AddSeconds($Timeout)
        }

        # add task process
        $result = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $PodeContext.Tasks.Processes[$processId] = @{
            ID            = $processId
            Task          = $Task.Name
            Parameters    = $parameters
            Runspace      = $null
            Result        = $result
            CreateTime    = $createTime
            StartTime     = $null
            CompletedTime = $null
            ExpireTime    = $expireTime
            Exception     = $null
            Timeout       = @{
                Value = $Timeout
                From  = $TimeoutFrom
            }
            Retry         = @{
                Count = 0
                From  = $null
            }
            State         = 'Pending'
        }

        # start the task runspace
        # [Orbital-Command patch] Wrap Add-PodeRunspace + Runspace assignment
        # in a nested try so a failure here rolls back the half-constructed
        # Processes[$processId] entry. Without this, an exception leaves an
        # orphan with Runspace=$null that the housekeeper has to sweep.
        $scriptblock = Get-PodeTaskScriptBlock
        try {
            $runspace = Add-PodeRunspace -Type Tasks -Name $Task.Name -ScriptBlock $scriptblock -Parameters $parameters -OutputStream $result -PassThru

            # add runspace to process
            $PodeContext.Tasks.Processes[$processId].Runspace = $runspace
        }
        catch {
            # roll back the orphaned entry, then rethrow
            $null = $PodeContext.Tasks.Processes.Remove($processId)
            throw
        }

        # return the task process
        return $PodeContext.Tasks.Processes[$processId]
    }
    catch {
        $_ | Write-PodeErrorLog
    }
}

function Restart-PodeTaskInternal {
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ProcessId
    )

    try {
        # get the process, and return if not found or not failed
        $process = $PodeContext.Tasks.Processes[$ProcessId]
        if (($null -eq $process) -or ($process.State -ine 'Failed')) {
            return
        }

        # get the task
        $task = $PodeContext.Tasks.Items[$process.Task]

        # dispose of the old runspace
        Close-PodeTaskInternal -Process $process -Keep

        # return if we have hit the max retries
        if ($process.Retry.Count -ge $task.Retry.Max) {
            return
        }

        # what is the expire time if using "create" timeout?
        $expireTime = [datetime]::MaxValue
        $createTime = [datetime]::UtcNow

        if (($process.Timeout.From -ieq 'Create') -and ($process.Timeout.Value -ge 0)) {
            $expireTime = $createTime.AddSeconds($process.Timeout.Value)
        }

        $process.CreateTime = $createTime
        $process.ExpireTime = $expireTime
        $process.StartTime = $null
        $process.CompletedTime = $null

        # reset the process result
        $result = [System.Management.Automation.PSDataCollection[psobject]]::new()
        $process.Result = $result

        # reset the process state
        $process.State = 'Pending'
        $process.Exception = $null
        $process.Retry.Count++
        $process.Retry.From = $null

        # start the task runspace
        $scriptblock = Get-PodeTaskScriptBlock
        $runspace = Add-PodeRunspace -Type Tasks -Name $process.Task -ScriptBlock $scriptblock -Parameters $process.Parameters -OutputStream $result -PassThru

        # add runspace to process
        $process.Runspace = $runspace

        # return the task process
        return $process
    }
    catch {
        $_ | Write-PodeErrorLog
    }
}

function Get-PodeTaskScriptBlock {
    return {
        param($ProcessId, $ArgumentList)

        try {
            $process = $PodeContext.Tasks.Processes[$ProcessId]
            if ($null -eq $process) {
                # Task process does not exist: $ProcessId
                throw ($PodeLocale.taskProcessDoesNotExistExceptionMessage -f $ProcessId)
            }

            # set the start time and state
            $process.StartTime = [datetime]::UtcNow
            $process.State = 'Running'

            # set the expire time of timeout based on "start" time
            if (($process.Timeout.From -ieq 'Start') -and ($process.Timeout.Value -ge 0)) {
                $process.ExpireTime = $process.StartTime.AddSeconds($process.Timeout.Value)
            }

            # get the task, error if not found
            $task = $PodeContext.Tasks.Items[$process.Task]
            if ($null -eq $task) {
                # Task does not exist
                throw ($PodeLocale.taskDoesNotExistExceptionMessage -f $process.Task)
            }

            # build the script arguments
            $TaskEvent = @{
                Lockable  = $PodeContext.Threading.Lockables.Global
                Sender    = $task
                Timestamp = [DateTime]::UtcNow
                Count     = $process.Retry.Count
                Metadata  = @{}
            }

            $_args = @{ Event = $TaskEvent }

            if ($null -ne $task.Arguments) {
                foreach ($key in $task.Arguments.Keys) {
                    $_args[$key] = $task.Arguments[$key]
                }
            }

            if ($null -ne $ArgumentList) {
                foreach ($key in $ArgumentList.Keys) {
                    $_args[$key] = $ArgumentList[$key]
                }
            }

            # add any using variables
            if ($null -ne $task.UsingVariables) {
                foreach ($usingVar in $task.UsingVariables) {
                    $_args[$usingVar.NewName] = $usingVar.Value
                }
            }

            # invoke the script from the task
            Invoke-PodeScriptBlock -ScriptBlock $task.Script -Arguments $_args -Scoped -Splat -Return

            # set the state to completed
            $process.State = 'Completed'
        }
        catch {
            # update the state
            if ($null -ne $process) {
                $process.State = 'Failed'
                $process.ExpireTime = $null
                $process.Retry.From = [datetime]::UtcNow.AddMinutes($task.Retry.Delay)
                $process.Exception = $_
            }

            # log the error
            $_ | Write-PodeErrorLog
        }
        finally {
            $process.CompletedTime = [datetime]::UtcNow
            Reset-PodeRunspaceName
            Invoke-PodeGC
        }
    }
}

function Wait-PodeTaskNetInternal {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Threading.Tasks.Task]
        $Task,

        [Parameter()]
        [int]
        $Timeout = -1
    )

    # do we need a timeout?
    $timeoutTask = $null
    if ($Timeout -gt 0) {
        $timeoutTask = [System.Threading.Tasks.Task]::Delay($Timeout)
    }

    # set the check task
    if ($null -eq $timeoutTask) {
        $checkTask = $Task
    }
    else {
        $checkTask = [System.Threading.Tasks.Task]::WhenAny($Task, $timeoutTask)
    }

    # is there a cancel token to supply?
    if (($null -eq $PodeContext) -or ($null -eq $PodeContext.Tokens.Cancellation.Token)) {
        $checkTask.Wait()
    }
    else {
        $checkTask.Wait($PodeContext.Tokens.Cancellation.Token)
    }

    # if the main task isn't complete, it timed out
    if (($null -ne $timeoutTask) -and (!$Task.IsCompleted)) {
        # "Task has timed out after $($Timeout)ms")
        throw [System.TimeoutException]::new($PodeLocale.taskTimedOutExceptionMessage -f $Timeout)
    }

    # only return a value if the result has one
    if ($null -ne $Task.Result) {
        return $Task.Result
    }
}

function Wait-PodeTaskProcessInternal {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Process,

        [Parameter()]
        [int]
        $Timeout = -1
    )

    # timeout needs to be in milliseconds
    if ($Timeout -gt 0) {
        $Timeout *= 1000
    }

    # wait for the pipeline to finish processing
    $null = $Process.Runspace.Handler.AsyncWaitHandle.WaitOne($Timeout)

    # get the current result
    $result = $Process.Result.ReadAll()

    # close the task
    Close-PodeTask -Process $Process

    # only return a value if the result has one
    if (($null -ne $result) -and ($result.Count -gt 0)) {
        return $result
    }
}