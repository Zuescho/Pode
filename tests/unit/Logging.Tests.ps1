[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

InModuleScope -ModuleName 'Pode' {
    Describe 'Get-PodeLogType' {
        It 'Returns null as the logger does not exist' {
            $PodeContext = @{ 'Server' = @{ 'Logging' = @{ 'Types' = @{}; } }; }
            Get-PodeLogType -Name 'test' | Should -Be $null
        }

        It 'Returns terminal logger for name' {
            $PodeContext = @{ 'Server' = @{ 'Logging' = @{ 'Types' = @{ 'test' = $null }; } }; }
            $result = (Get-PodeLogType -Name 'test')

            $result | Should -Be $null
        }

        It 'Returns custom logger for name' {
            $PodeContext = @{ 'Server' = @{ 'Logging' = @{ 'Types' = @{ 'test' = { Write-Host 'hello' } }; } }; }
            $result = (Get-PodeLogType -Name 'test')

            $result | Should -Not -Be $null
            $result.ToString() | Should -Be ({ Write-Host 'hello' }).ToString()
        }
    }

    # [Orbital-Command patch 8] An unset -Version must be stored as 1, or the
    # logging runspace never builds the scriptblock's arguments.
    Describe 'Add-PodeLogType' {
        BeforeEach {
            Mock Test-PodeLogMethod { return $true }
            Mock Register-PodeLogTypeToMethod {}
            $logger = [pscustomobject]@{}
            $logger | Add-Member -MemberType ScriptMethod -Name RegisterType -Value { param($type) }
            $PodeContext = @{ Server = @{ Logging = @{ Types = @{}; Formatting = @{}; Logger = $logger } } }
        }

        It 'Stores Version 1 when -Version is not supplied' {
            Add-PodeLogType -Name 'custom' -Method 'method-id' -ScriptBlock { param($item) $item }
            $PodeContext.Server.Logging.Types['custom'].Version | Should -Be 1
        }

        It 'Keeps an explicit -Version 2' {
            Add-PodeLogType -Name 'custom' -Method 'method-id' -Version 2 -ScriptBlock { param($logEvent) $logEvent }
            $PodeContext.Server.Logging.Types['custom'].Version | Should -Be 2
        }

        It 'Stores Version 1 through the deprecated Add-PodeLogger alias' {
            Add-PodeLogger -Name 'custom' -Method 'method-id' -ScriptBlock { param($item) $item }
            $PodeContext.Server.Logging.Types['custom'].Version | Should -Be 1
        }
    }

    Describe 'Write-PodeLog' {
        BeforeEach {
            $PodeContext = @{
                Server = @{
                    Logging = @{
                        Logger = [Pode.Utilities.Logging.PodeLogger]::new()
                    }
                }
            }
        }

        AfterEach {
            $PodeContext.Server.Logging.Logger.Dispose()
        }

        It 'Does nothing when logging disabled' {
            $PodeContext.Server.Logging.Logger.IsEnabled = $false
            Write-PodeLog -Name 'test' -InputObject 'test'

            $PodeContext.Server.Logging.Logger.Count | Should -Be 0
        }

        It 'Adds a log item' {
            $logType = [Pode.Utilities.Logging.PodeLogType]::new('test', @('Informational'), $false)
            $PodeContext.Server.Logging.Logger.RegisterType($logType)

            Write-PodeLog -Name 'test' -InputObject 'test'

            $PodeContext.Server.Logging.Logger.Count | Should -Be 1

            $logEvent = $null
            $PodeContext.Server.Logging.Logger.TryTake([ref]$logEvent, [System.Threading.CancellationToken]::None) | Should -Be $true
            $logEvent.Type.Name | Should -Be 'test'
            $logEvent.Data | Should -Be 'test'
        }
    }

    Describe 'Write-PodeErrorLog' {
        BeforeEach {
            $PodeContext = @{
                Server = @{
                    Logging = @{
                        Logger = [Pode.Utilities.Logging.PodeLogger]::new()
                    }
                }
            }
        }

        AfterEach {
            $PodeContext.Server.Logging.Logger.Dispose()
        }

        It 'Does nothing when logging disabled' {
            $PodeContext.Server.Logging.Logger.IsEnabled = $false

            try { throw 'some error' }
            catch {
                Write-PodeErrorLog -ErrorRecord $_
            }

            $PodeContext.Server.Logging.Logger.Count | Should -Be 0
        }

        It 'Adds an error log item' {
            $logType = [Pode.Utilities.Logging.PodeLogErrorType]::new([Pode.Utilities.Logging.PodeLogger]::ERROR_LOG_TYPE_NAME, @('Error'), @('Server'), $false)
            $PodeContext.Server.Logging.Logger.RegisterType($logType)

            try { throw 'some error' }
            catch {
                Write-PodeErrorLog -ErrorRecord $_
            }

            $PodeContext.Server.Logging.Logger.Count | Should -Be 1

            $logEvent = $null
            $PodeContext.Server.Logging.Logger.TryTake([ref]$logEvent, [System.Threading.CancellationToken]::None) | Should -Be $true
            $logEvent.Data.Message | Should -Be 'some error'
        }

        It 'Adds an exception log item' {
            $logType = [Pode.Utilities.Logging.PodeLogErrorType]::new([Pode.Utilities.Logging.PodeLogger]::ERROR_LOG_TYPE_NAME, @('Error'), @('Server'), $false)
            $PodeContext.Server.Logging.Logger.RegisterType($logType)

            $exp = [exception]::new('some error')
            Write-PodeErrorLog -Exception $exp

            $logEvent = $null
            $PodeContext.Server.Logging.Logger.TryTake([ref]$logEvent, [System.Threading.CancellationToken]::None) | Should -Be $true
            $logEvent.Data.Message | Should -Be 'some error'
        }

        It 'Does not log as Verbose not allowed' {
            $logType = [Pode.Utilities.Logging.PodeLogErrorType]::new([Pode.Utilities.Logging.PodeLogger]::ERROR_LOG_TYPE_NAME, @('Error'), @('Server'), $false)
            $PodeContext.Server.Logging.Logger.RegisterType($logType)

            $exp = [exception]::new('some error')
            Write-PodeErrorLog -Exception $exp -Level Verbose

            $PodeContext.Server.Logging.Logger.Count | Should -Be 0
        }
    }

    Describe 'Protect-PodeLogItem' {
        BeforeEach {
            $item = 'Password=Hunter2, Email'
        }
        It 'Do nothing with no masks' {
            $PodeContext = @{ Server = @{ Logging = @{ Masking = @{
                            Patterns = @()
                        }
                    }
                }
            }

            Protect-PodeLogItem -Item $item | Should -Be $item
        }

        It 'Mask whole item' {
            $PodeContext = @{ Server = @{ Logging = @{ Masking = @{
                            Patterns = @('Password\=[a-z0-9]+')
                            Mask     = '********'
                        }
                    }
                }
            }

            Protect-PodeLogItem -Item $item | Should -Be '********, Email'
        }

        It 'Mask item but keep before' {
            $PodeContext = @{ Server = @{ Logging = @{ Masking = @{
                            Patterns = @('(?<keep_before>Password\=)[a-z0-9]+')
                            Mask     = '********'
                        }
                    }
                }
            }

            Protect-PodeLogItem -Item $item | Should -Be 'Password=********, Email'
        }

        It 'Mask item but keep after' {
            $PodeContext = @{ Server = @{ Logging = @{ Masking = @{
                            Patterns = @('Password\=(?<keep_after>[a-z0-9]+)')
                            Mask     = '********'
                        }
                    }
                }
            }

            Protect-PodeLogItem -Item $item | Should -Be '********Hunter2, Email'
        }

        It 'Mask item but keep before and after' {
            $PodeContext = @{ Server = @{ Logging = @{ Masking = @{
                            Patterns = @('(?<keep_before>Password\=)(?<keep_after>[a-z0-9]+)')
                            Mask     = '********'
                        }
                    }
                }
            }

            Protect-PodeLogItem -Item $item | Should -Be 'Password=********Hunter2, Email'
        }
    }

    Describe 'ConvertTo-PodeSyslog' {
        BeforeAll {
            $PodeContext = @{
                Server = @{
                    ComputerName = 'localhost'
                    AppName      = 'Pode'
                }
            }
        }

        It 'Converts a log item to RFC5424 syslog format' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffK')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now
            $msg | Should -Be "<131>1 $($strNow) localhost Pode $($processId) - - example"
        }

        It 'Converts a log item to RFC5424 syslog format, with custom AppName' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffK')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now -AppName 'CustomApp'
            $msg | Should -Be "<131>1 $($strNow) localhost CustomApp $($processId) - - example"
        }

        It 'Converts a log item to RFC5424 syslog format, with Facility' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffK')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now -Facility 19
            $msg | Should -Be "<155>1 $($strNow) localhost Pode $($processId) - - example"
        }

        It 'Converts a log item to RFC5424 syslog format, with Tags' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffK')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id
            $tags = @{ tag1 = 'value1' }

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now -Tags $tags
            $msg | Should -Be "<131>1 $($strNow) localhost Pode $($processId) - [tag1=`"value1`"] example"
        }

        It 'Converts a log item to RFC3164 syslog format' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('MMM dd HH:mm:ss')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now -Format 'RFC3164'
            $msg | Should -Be "<131>$($strNow) localhost Pode[$($processId)]: example"
        }

        It 'Converts a log item to RFC3164 syslog format, with custom AppName' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('MMM dd HH:mm:ss')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now -Format 'RFC3164' -AppName 'CustomApp'
            $msg | Should -Be "<131>$($strNow) localhost CustomApp[$($processId)]: example"
        }

        It 'Converts a log item to RFC3164 syslog format, with Facility' {
            $now = [datetime]::UtcNow
            $strNow = $now.ToString('MMM dd HH:mm:ss')
            $processId = [System.Diagnostics.Process]::GetCurrentProcess().Id

            $msg = ConvertTo-PodeSyslog -Message 'example' -Level 'Error' -Timestamp $now -Format 'RFC3164' -Facility 19
            $msg | Should -Be "<155>$($strNow) localhost Pode[$($processId)]: example"
        }
    }
}