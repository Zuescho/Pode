[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

# [Orbital-Command patch 3] Add-PodeRunspace creates a pool on demand when the
# server scriptblock invokes a task before Pode has created its pools, and
# again after Restart-PodeServer closed them. Close-PodeRunspacePool must
# dispose those pools, because New-PodeRunspacePool replaces them.
InModuleScope -ModuleName 'Pode' {
    Describe 'Lazy runspace pools' {
        BeforeEach {
            Mock Write-PodeErrorLog {}
            $PodeContext = @{
                Threads       = @{ Tasks = 1; General = 1 }
                RunspaceState = [initialsessionstate]::CreateDefault()
                RunspacePools = @{ Tasks = $null }
                Server        = @{ Root = $TestDrive; IsServerless = $false }
                Runspaces     = @()
            }
        }

        AfterEach {
            foreach ($item in @($PodeContext.RunspacePools.Values) + @($PodeContext.Server.LazyRunspacePools)) {
                $pool = if ($item -is [hashtable]) { $item.Pool } else { $item }
                if (($null -ne $pool) -and !$pool.IsDisposed) { $pool.Dispose() }
            }
        }

        It 'creates, opens and remembers a pool when none exists' {
            Add-PodeRunspace -Type Tasks -ScriptBlock { 'x' } -Forget

            $pool = $PodeContext.RunspacePools.Tasks.Pool
            "$($pool.RunspacePoolStateInfo.State)" | Should -Be 'Opened'
            @($PodeContext.Server.LazyRunspacePools).Count | Should -Be 1
            [object]::ReferenceEquals($PodeContext.Server.LazyRunspacePools[0], $pool) | Should -BeTrue
        }

        It 'replaces a pool that a restart closed and disposed' {
            $closed = [runspacefactory]::CreateRunspacePool(1, 1, $PodeContext.RunspaceState, $Host)
            $closed.Open(); $closed.Close(); $closed.Dispose()
            $PodeContext.RunspacePools.Tasks = @{ Pool = $closed; State = 'Ready'; LastId = 7 }

            Add-PodeRunspace -Type Tasks -ScriptBlock { 'x' } -Forget

            [object]::ReferenceEquals($PodeContext.RunspacePools.Tasks.Pool, $closed) | Should -BeFalse
            "$($PodeContext.RunspacePools.Tasks.Pool.RunspacePoolStateInfo.State)" | Should -Be 'Opened'
        }

        It 'leaves a canonical pool that is not opened yet alone' {
            $canonical = [runspacefactory]::CreateRunspacePool(1, 1, $PodeContext.RunspaceState, $Host)
            $PodeContext.RunspacePools.Tasks = @{ Pool = $canonical; State = 'Waiting'; LastId = 0 }

            # BeginInvoke on a not-yet-opened pool still throws, as upstream always did
            { Add-PodeRunspace -Type Tasks -ScriptBlock { 'x' } -Forget } | Should -Throw

            [object]::ReferenceEquals($PodeContext.RunspacePools.Tasks.Pool, $canonical) | Should -BeTrue
            $PodeContext.Server.LazyRunspacePools | Should -BeNullOrEmpty
        }

        It 'Close-PodeRunspacePool disposes the lazy pools that were replaced' {
            Add-PodeRunspace -Type Tasks -ScriptBlock { 'x' } -Forget
            $lazy = $PodeContext.Server.LazyRunspacePools[0]

            # New-PodeRunspacePool replaces the wrapper with the canonical pool
            $canonical = [runspacefactory]::CreateRunspacePool(1, 1, $PodeContext.RunspaceState, $Host)
            $canonical.Open()
            $PodeContext.RunspacePools.Tasks = @{ Pool = $canonical; State = 'Ready'; LastId = 0 }

            Close-PodeRunspacePool

            $lazy.IsDisposed | Should -BeTrue
            $canonical.IsDisposed | Should -BeTrue
            @($PodeContext.Server.LazyRunspacePools).Count | Should -Be 0
        }
    }
}
