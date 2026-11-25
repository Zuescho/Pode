[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

InModuleScope -ModuleName 'Pode' {
    Describe 'Get-PodeTaskScriptBlock' {
        It 'Runs a task without forcing a full garbage collection' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
            $PodeContext = @{
                Server    = @{ Root = $PWD.Path }
                Threading = @{ Lockables = @{ Global = [hashtable]::Synchronized(@{}) } }
                Tasks     = @{ Items = @{}; Processes = [hashtable]::Synchronized(@{}) }
            }
            Add-PodeTask -Name 'work' -ScriptBlock { param($State) $State.Runs++ }
            $state = @{ Runs = 0 }
            $taskScript = Get-PodeTaskScriptBlock

            # [GC]::Collect() is a full blocking collection; the runtime's own gen2 runs in the
            # background, and one blocking collection of its own may still land in a run
            $blockingRuns = 0
            foreach ($i in 1..10) {
                $PodeContext.Tasks.Processes["p$i"] = @{
                    ID = "p$i"; Task = 'work'; State = 'Pending'; CompletedTime = $null; ExpireTime = $null
                    Timeout = @{ Value = -1; From = 'Default' }; Retry = @{ Count = 0; From = $null }
                }
                $lastBlocking = [System.GC]::GetGCMemoryInfo([System.GCKind]::FullBlocking).Index
                $null = & $taskScript -ProcessId "p$i" -ArgumentList @{ State = $state }
                if ([System.GC]::GetGCMemoryInfo([System.GCKind]::FullBlocking).Index -ne $lastBlocking) {
                    $blockingRuns++
                }
            }

            $state.Runs | Should -Be 10
            @($PodeContext.Tasks.Processes.Values | Where-Object { $_.State -eq 'Completed' }).Count | Should -Be 10
            $blockingRuns | Should -BeLessOrEqual 1
        }
    }
}
