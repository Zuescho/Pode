[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

# On .NET Framework an HTTP worker blocked on the listener's disposed queue cannot be cancelled.
Describe 'Server shutdown' -Skip:($PSVersionTable.PSEdition -ne 'Desktop') {

    BeforeAll {
        $Port = 8080
        $Endpoint = "http://127.0.0.1:$($Port)"
        $module = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src\Pode.psm1'
        $serverScript = Join-Path $TestDrive 'server.ps1'
        Set-Content -LiteralPath $serverScript -Value @"
Import-Module -Name '$module'
Start-PodeServer -Quiet -ScriptBlock {
    Add-PodeEndpoint -Address localhost -Port $Port -Protocol Http
    Add-PodeRoute -Method Get -Path '/ping' -ScriptBlock { Write-PodeJsonResponse -Value @{ Result = 'Pong' } }
    Add-PodeRoute -Method Get -Path '/close' -ScriptBlock { Close-PodeServer }
}
"@
    }

    It 'ends the server process after Close-PodeServer' {
        $server = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$serverScript`"" -NoNewWindow -PassThru
        try {
            $ready = $false
            $deadline = [datetime]::Now.AddSeconds(60)
            while (!$ready -and !$server.HasExited -and ([datetime]::Now -lt $deadline)) {
                try {
                    $ready = ((Invoke-RestMethod -Uri "$($Endpoint)/ping" -Method Get -TimeoutSec 5).Result -eq 'Pong')
                }
                catch {
                    Start-Sleep -Milliseconds 250
                }
            }
            $ready | Should -BeTrue

            Invoke-RestMethod -Uri "$($Endpoint)/close" -Method Get | Out-Null
            $server.WaitForExit(30000) | Should -BeTrue
        }
        finally {
            if (!$server.HasExited) {
                $server.Kill()
                $null = $server.WaitForExit(10000)
            }
        }
    }
}
