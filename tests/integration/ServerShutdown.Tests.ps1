[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

# On .NET Framework an HTTP worker blocked on the listener's disposed queue cannot be cancelled.
Describe 'Server shutdown' -Skip:($PSVersionTable.PSEdition -ne 'Desktop') {

    BeforeAll {
        $Port = 8080
        $Endpoint = "http://127.0.0.1:$($Port)"
        $module = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\Pode.psm1'

        # only this test's own server knows the token, so a server already on the port cannot pass for it
        $token = [guid]::NewGuid().ToString()
        $serverScript = Join-Path $TestDrive 'server.ps1'
        Set-Content -LiteralPath $serverScript -Value @"
Import-Module -Name '$module'
Start-PodeServer -Quiet -ScriptBlock {
    Add-PodeEndpoint -Address localhost -Port $Port -Protocol Http
    Add-PodeRoute -Method Get -Path '/identity' -ScriptBlock { Write-PodeJsonResponse -Value @{ Token = '$token' } }
    Add-PodeRoute -Method Get -Path '/close' -ScriptBlock { Close-PodeServer }
}
"@
    }

    It 'ends its own server process cleanly after Close-PodeServer' {
        # Process.Start rather than Start-Process: Windows PowerShell's Start-Process can lose the exit code
        $start = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`"")
        $start.UseShellExecute = $false
        $server = [System.Diagnostics.Process]::Start($start)
        try {
            $ready = $false
            $deadline = [datetime]::Now.AddSeconds(60)
            while (!$ready -and !$server.HasExited -and ([datetime]::Now -lt $deadline)) {
                try {
                    $ready = ((Invoke-RestMethod -Uri "$($Endpoint)/identity" -Method Get -TimeoutSec 5).Token -eq $token)
                }
                catch {
                    Start-Sleep -Milliseconds 250
                }
            }
            $ready | Should -BeTrue -Because 'its own server must answer with its token'

            Invoke-RestMethod -Uri "$($Endpoint)/close" -Method Get -TimeoutSec 10 | Out-Null
            $server.WaitForExit(30000) | Should -BeTrue -Because 'the server must stop after Close-PodeServer'
            $server.ExitCode | Should -Be 0
        }
        finally {
            if (!$server.HasExited) {
                $server.Kill()
                $null = $server.WaitForExit(10000)
            }
            $server.Dispose()
        }
    }
}
