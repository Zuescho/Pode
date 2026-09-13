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
