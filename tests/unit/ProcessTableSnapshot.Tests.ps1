[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

# [Orbital-Command patch #6] The task and schedule process tables are
# [hashtable]::Synchronized. Their writers lock the table's SyncRoot, so a
# snapshot is only consistent if it is copied under that same lock. A writer
# in another runspace adds and removes entries while the getters run.
InModuleScope -ModuleName 'Pode' {
    Describe 'Process table snapshots under concurrent writers' {
        BeforeAll {
            function Start-TableWriter {
                param([hashtable]$Table, [int]$Milliseconds)
                $ps = [powershell]::Create()
                $null = $ps.AddScript({
                        param($Table, $Milliseconds)
                        $sw = [System.Diagnostics.Stopwatch]::StartNew()
                        $i = 0
                        while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
                            $key = "writer-$($i % 50)"
                            $Table[$key] = @{ ID = $key; Task = 'writer'; Schedule = 'writer'; State = 'Running' }
                            $null = $Table.Remove($key)
                            $i++
                        }
                    }).AddArgument($Table).AddArgument($Milliseconds)
                return @{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
            }

            function Wait-TableWriter {
                param($Writer)
                $null = $Writer.PowerShell.EndInvoke($Writer.Handle)
                $Writer.PowerShell.Dispose()
            }

            function New-ProcessTable {
                $table = [hashtable]::Synchronized(@{})
                foreach ($n in 1..200) {
                    $table["p$n"] = @{ ID = "p$n"; Task = 'fixed'; Schedule = 'fixed'; State = 'Running' }
                }
                return $table
            }

            function Measure-SnapshotError {
                param([scriptblock]$Snapshot, [int]$Milliseconds)
                $errors = 0
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
                    try { $null = & $Snapshot } catch { $errors++ }
                }
                return $errors
            }

            Mock Write-PodeErrorLog {}
        }

        It 'an unlocked copy of the live table does fail (control)' {
            $table = New-ProcessTable
            $writer = Start-TableWriter -Table $table -Milliseconds 2000
            try {
                $errors = Measure-SnapshotError -Milliseconds 1500 -Snapshot { @($table.Values) }
            }
            finally {
                Wait-TableWriter -Writer $writer
            }

            $errors | Should -BeGreaterThan 0
        }

        It 'Get-PodeTaskProcess returns consistent snapshots' {
            $PodeContext = @{ Tasks = @{ Processes = New-ProcessTable }; Threading = @{ Lockables = @{ Global = [hashtable]::Synchronized(@{}) } } }
            $writer = Start-TableWriter -Table $PodeContext.Tasks.Processes -Milliseconds 2000
            try {
                $errors = Measure-SnapshotError -Milliseconds 1500 -Snapshot { Get-PodeTaskProcess -Name 'fixed' }
            }
            finally {
                Wait-TableWriter -Writer $writer
            }

            $errors | Should -Be 0
            @(Get-PodeTaskProcess -Name 'fixed').Count | Should -Be 200
        }

        It 'Get-PodeScheduleProcess returns consistent snapshots' {
            $PodeContext = @{ Schedules = @{ Processes = New-ProcessTable }; Threading = @{ Lockables = @{ Global = [hashtable]::Synchronized(@{}) } } }
            $writer = Start-TableWriter -Table $PodeContext.Schedules.Processes -Milliseconds 2000
            try {
                $errors = Measure-SnapshotError -Milliseconds 1500 -Snapshot { Get-PodeScheduleProcess -Name 'fixed' }
            }
            finally {
                Wait-TableWriter -Writer $writer
            }

            $errors | Should -Be 0
            @(Get-PodeScheduleProcess -Name 'fixed').Count | Should -Be 200
        }
    }
}
