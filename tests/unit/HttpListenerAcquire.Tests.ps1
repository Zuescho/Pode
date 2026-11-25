# The starvation control changes CLR pool limits only in a throwaway process.
Describe 'HTTP worker context acquisition does not starve socket tasks' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
    BeforeAll {
        $repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $fixture = Join-Path $PSScriptRoot 'fixtures/HttpListenerAcquire.ps1'
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['DOTNET_PROCESSOR_COUNT'] = '2'
        foreach ($argument in @('-NoProfile','-File',$fixture,'-Repository',$repository)) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'HTTP acquisition fixture exceeded 30 seconds' }
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            if ($process.ExitCode -ne 0) { throw "HTTP acquisition fixture failed: $stderr" }
            $script:acquisition = $stdout | ConvertFrom-Json
        }
        finally { $process.Dispose() }
    }
    It 'lets a queued producer deliver to sixteen idle workers with only two CLR pool slots' {
        $script:acquisition.producerCompleted | Should -BeTrue
        $script:acquisition.received | Should -Be 1
    }
    It 'cancels every other pending worker through the existing OperationCanceledException catch' {
        $script:acquisition.cancelled | Should -Be 15
    }
    It 'preserves processing bookkeeping and the disposed queue result' {
        $script:acquisition.processing | Should -Be 1
        $script:acquisition.remainingProcessing | Should -Be 0
        $script:acquisition.disposedResult | Should -Be 0
    }
}

# The fixture above runs only the GetContext statement. This runs the shipped branch around it, with
# its predicate, so a worker on the wrong arm fails here: PowerShell 7 must not acquire on the pool.
Describe 'HTTP worker context acquisition arm' {
    BeforeAll {
        $repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'src/Private/PodeServer.ps1'), [ref]$null, [ref]$null)
        $acquire = @($ast.FindAll({ param($n)
                    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left.Extent.Text -eq '$context' -and $n.Right.Extent.Text -match '\$Listener\.GetContext'
                }, $true))
        if ($acquire.Count -ne 1) { throw 'Expected one HTTP context acquisition' }

        $branch = $acquire[0].Parent
        while (($null -ne $branch) -and ($branch -isnot [Management.Automation.Language.IfStatementAst])) { $branch = $branch.Parent }
        if ($null -eq $branch) { throw 'Expected the HTTP context acquisition inside a branch' }

        $listenScript = $branch.Parent
        while ($listenScript -isnot [Management.Automation.Language.ScriptBlockAst]) { $listenScript = $listenScript.Parent }
        $names = @($branch.Clauses | ForEach-Object { $_.Item1.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true) } | ForEach-Object { $_.VariablePath.UserPath } | Select-Object -Unique)
        $predicates = @($listenScript.FindAll({ param($n)
                    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                    ($names -contains $n.Left.VariablePath.UserPath) -and
                    !$branch.Extent.Text.Contains($n.Extent.Text)
                }, $true))
        if ($predicates.Count -ne $names.Count) { throw "Expected one assignment for each of: $($names -join ', ')" }

        $branchScript = [scriptblock]::Create("param(`$Listener, `$PodeContext)`n" + (($predicates | ForEach-Object { $_.Extent.Text }) -join "`n") + "`n" + $branch.Extent.Text + "`n`$context")

        function Invoke-AcquisitionBranch {
            $listener = [pscustomobject]@{ Calls = [System.Collections.Generic.List[string]]::new() }
            $listener | Add-Member -MemberType ScriptMethod -Name GetContext -Value { param($token) $this.Calls.Add('GetContext'); 'sync-context' }
            $listener | Add-Member -MemberType ScriptMethod -Name GetContextAsync -Value { param($token) $this.Calls.Add('GetContextAsync'); [System.Threading.Tasks.Task]::FromResult([object]'pool-context') }
            $cancel = [System.Threading.CancellationTokenSource]::new()
            try {
                $context = & $branchScript $listener @{ Tokens = @{ Cancellation = $cancel } }
            }
            finally {
                $cancel.Dispose()
            }
            return @{ Calls = @($listener.Calls); Context = $context }
        }
    }

    It 'blocks in GetContext on the worker thread on PowerShell 7' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $result = Invoke-AcquisitionBranch
        $result.Calls | Should -Be @('GetContext')
        $result.Context | Should -Be 'sync-context'
    }

    It 'waits on GetContextAsync on Windows PowerShell' -Skip:($PSVersionTable.PSEdition -ne 'Desktop') {
        $result = Invoke-AcquisitionBranch
        $result.Calls | Should -Be @('GetContextAsync')
        $result.Context | Should -Be 'pool-context'
    }
}
