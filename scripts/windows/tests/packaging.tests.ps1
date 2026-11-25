param([string] $OutputPath = (Join-Path $PSScriptRoot '..\..\..\tests\_output\windows\packaging.xml'))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\packaging-common.ps1')
if (-not $env:SUITECRM_PACKAGING_PESTER) {
    Import-Module Pester -MinimumVersion 3.4.0 -ErrorAction Stop
    $env:SUITECRM_PACKAGING_PESTER = '1'
    try { $result = Invoke-Pester -Script $PSCommandPath -PassThru }
    finally { Remove-Item Env:SUITECRM_PACKAGING_PESTER }
    $cases = @($result.TestResult | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name; ExitCode = $(if ($_.Passed) { 0 } else { 1 })
            Seconds = $_.Time.TotalSeconds; Log = $_.FailureMessage
        }
    })
    Write-PackagingJUnit $OutputPath 'windows-packaging' $cases
    if ($result.FailedCount -or -not $result.PassedCount) { exit 1 }
    exit 0
}

Describe 'Windows packaging common functions' {
    $runtimeRoot = Join-Path $TestDrive 'runtime cache'
    $context = Get-PackagingContext $runtimeRoot 18086 13312
    It 'rejects matching HTTP and database ports' {
        { Get-PackagingContext $runtimeRoot 18086 18086 } | Should Throw
    }
    It 'rejects a runtime inside the source checkout' {
        { Get-PackagingContext (Join-Path $context.Repo 'runtime') } | Should Throw
    }
    It 'uses a stable per-checkout instance and distinct task name' {
        $again = Get-PackagingContext $runtimeRoot 18086 13312
        $again.Id | Should Be $context.Id
        $again.TaskName | Should Be ("SuiteCRM-Windows-" + $context.Id)
    }
    It 'preserves paths and ports in child runtime arguments' {
        $arguments = Get-RuntimeArguments $context 'Serve'
        ($arguments -contains $runtimeRoot) | Should Be $true
        ($arguments -contains '18086') | Should Be $true
        ($arguments -contains '13312') | Should Be $true
        ($arguments -contains 'Serve') | Should Be $true
        ($arguments -contains '-WarmupProdCache') | Should Be $true
        ((Get-RuntimeArguments $context 'Stop') -contains '-WarmupProdCache') | Should Be $false
    }
    It 'quotes spaces, embedded quotes, and trailing backslashes' {
        ConvertTo-WindowsArgument 'a b' | Should Be '"a b"'
        ConvertTo-WindowsArgument 'a"b' | Should Be '"a\"b"'
        ConvertTo-WindowsArgument 'C:\a b\' | Should Be '"C:\a b\\"'
    }
    It 'writes parseable JUnit and escapes failure messages' {
        $path = Join-Path $TestDrive 'reports\results.xml'
        Write-PackagingJUnit $path 'a&b' @(
            [pscustomobject]@{Name='pass';ExitCode=0;Seconds=1;Log=''},
            [pscustomobject]@{Name='fail<';ExitCode=23;Seconds=2;Log='a&b'}
        )
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        $xml.testsuite.tests | Should Be 2
        $xml.testsuite.failures | Should Be 1
        $xml.testsuite.testcase[1].failure.message | Should Match 'Exit 23'
    }
    It 'does not treat stderr as failure when native exit is zero' {
        $context.Reports = Join-Path $TestDrive 'native logs'
        $result = Invoke-PackagingCommand $context 'stderr' $context.PowerShell @('-NoProfile', '-Command', '[Console]::Error.WriteLine("diagnostic");exit 0')
        $result.ExitCode | Should Be 0
    }
    It 'preserves nonzero child exit codes' {
        $result = Invoke-PackagingCommand $context 'failure' $context.PowerShell @('-NoProfile', '-Command', 'exit 23')
        $result.ExitCode | Should Be 23
    }
    It 'bounds a native helper and terminates only its launched process' {
        $pidPath = Join-Path $TestDrive 'timed-child-pid.txt'
        $result = Invoke-PackagingCommand $context 'timeout' $context.PowerShell @('-NoProfile', '-Command', "`$PID | Set-Content -LiteralPath '$pidPath'; Start-Sleep -Seconds 30") -TimeoutSeconds 2
        $result.ExitCode | Should Be 1
        $result.Seconds | Should BeLessThan 10
        $childId = [int](Get-Content -LiteralPath $pidPath)
        (Get-Process -Id $childId -ErrorAction SilentlyContinue) | Should BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $context.Reports 'timeout.stderr.log') -Raw) | Should Match 'exceeded 2 seconds'
    }
    It 'preserves a bounded native helper exit code' {
        $result = Invoke-PackagingCommand $context 'bounded-failure' $context.PowerShell @('-NoProfile', '-Command', 'exit 23') -TimeoutSeconds 5
        $result.ExitCode | Should Be 23
    }
    It 'runs cmd shims with spaces without losing argument boundaries' {
        $shim = Join-Path $TestDrive 'tool with spaces.cmd'
        "@echo off`r`necho %~1`r`nexit /b %~2`r`n" | Set-Content -LiteralPath $shim -Encoding ASCII
        $result = Invoke-PackagingCommand $context 'cmd-success' $shim @('argument with spaces', '0')
        $result.ExitCode | Should Be 0
        (Get-Content -LiteralPath $result.Log -Raw).Trim() | Should Be 'argument with spaces'
    }
    It 'preserves nonzero exit codes from cmd shims' {
        $shim = Join-Path $TestDrive 'tool with spaces.cmd'
        $result = Invoke-PackagingCommand $context 'cmd-failure' $shim @('value', '19')
        $result.ExitCode | Should Be 19
    }
    It 'sends PHP CLI errors to stderr ahead of the command arguments' {
        $arguments = Get-PhpCliArguments @('vendor/bin/codecept', 'run')
        $arguments[0..3] -join ' ' | Should Be '-d display_errors=stderr -d log_errors=0'
        $arguments[4..5] -join ' ' | Should Be 'vendor/bin/codecept run'
    }
    It 'reports missing executables as failure' {
        $result = Invoke-PackagingCommand $context 'missing' (Join-Path $TestDrive 'missing.exe') @()
        $result.ExitCode | Should Be 1
    }
    It 'restores the caller environment including previously absent variables' {
        $saved = Get-PackagingEnvironmentSnapshot
        try {
            $before = $env:PHPRC
            Set-PackagingEnvironment $context
            $env:PHPRC | Should Be $context.Instance
            Restore-PackagingEnvironment $saved
            $env:PHPRC | Should Be $before
        } finally { Restore-PackagingEnvironment $saved }
    }
    It 'rejects registration port changes before touching a task' {
        $null = New-Item -ItemType Directory -Path $context.Instance -Force
        @{Repo=$context.Repo;Root=$context.Root;HttpPort=18087;DbPort=13312;Mode='Task'} | ConvertTo-Json | Set-Content -LiteralPath $context.Registration
        { Get-StartupRegistration $context } | Should Throw
    }
    It 'rejects a replaced task rather than starting or deleting it' {
        Mock Get-ScheduledTask { [pscustomobject]@{Actions=[pscustomobject]@{Execute='foreign.exe';Arguments=''}} }
        { Get-OwnedStartupTask $context } | Should Throw
    }
}

Describe 'Production startup cache warmup' {
    $context = Get-PackagingContext (Join-Path $TestDrive 'warmup runtime') 18088 13314
    $context.Repo = Join-Path $TestDrive 'installed checkout'
    $config = Join-Path $context.Repo 'public\legacy\config.php'
    BeforeEach {
        $null = New-Item -ItemType Directory (Split-Path $config) -Force
        'fixture' | Set-Content -LiteralPath $config
        Mock Invoke-PackagingCommand { [pscustomobject]@{ExitCode=0} }
    }
    It 'sets assertions to the production value in the generated PHP ini template' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\runtime.ps1'), [ref]$tokens, [ref]$errors)
        $templates = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Config' -and
            $node.CommandElements[1].Extent.Text -eq '$phpIni'
        }, $true))
        $templates.Count | Should Be 1
        $templates[0].CommandElements[2].Extent.Text | Should Match '(?m)^zend\.assertions\s*=\s*-1\s*$'
    }
    It 'uses prod no-debug warmup with a bounded native helper' {
        Invoke-ProductionCacheWarmup $context
        Assert-MockCalled Invoke-PackagingCommand -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'startup-cache-warmup' -and $Program -eq $context.Php -and $TimeoutSeconds -eq 300 -and
            ($Arguments -contains 'cache:warmup') -and ($Arguments -contains '--env=prod') -and
            ($Arguments -contains '--no-debug') -and ($Arguments -contains 'max_execution_time=0')
        }
        Assert-MockCalled Invoke-PackagingCommand -Times 1 -Exactly -Scope It -ParameterFilter {
            $Name -eq 'startup-legacy-cache-config' -and $TimeoutSeconds -eq 30 -and
            ($Arguments -contains (Join-Path $context.Repo 'scripts\windows\configure-legacy-cache.php'))
        }
    }
    It 'skips uninstalled checkouts' {
        Remove-Item -LiteralPath $config
        Invoke-ProductionCacheWarmup $context
        Assert-MockCalled Invoke-PackagingCommand -Times 0 -Exactly -Scope It
    }
    It 'fails closed and restores environment when warmup fails' {
        $before = $env:APP_ENV
        Mock Invoke-PackagingCommand { [pscustomobject]@{ExitCode=23} }
        { Invoke-ProductionCacheWarmup $context } | Should Throw 'Apache was not started'
        $env:APP_ENV | Should Be $before
    }
    It 'enables isolated production OPcache while preserving extension parity' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\runtime.ps1') -Raw
        foreach ($line in @('zend_extension = opcache','opcache.enable = 1','opcache.enable_cli = 0',
            'opcache.memory_consumption = 256','opcache.max_accelerated_files = 20000',
            'opcache.validate_timestamps = 1','opcache.revalidate_freq = 2','opcache.cache_id = "$id"',
            'extension = "$redisPath"','extension = "$amqpPath"')) {
            $source.Contains($line) | Should Be $true
        }
    }
}

Describe 'Legacy cache configuration helper with native PHP' {
    $phpCommand = Get-Command php.exe -ErrorAction SilentlyContinue
    $php = if ($env:SUITECRM_TEST_PHP) { $env:SUITECRM_TEST_PHP } elseif ($phpCommand) { $phpCommand.Source } else { $null }
    $helper = Join-Path $PSScriptRoot '..\configure-legacy-cache.php'
    $legacy = Join-Path $TestDrive 'legacy config with spaces'
    $config = Join-Path $legacy 'config.php'
    $override = Join-Path $legacy 'config_override.php'
    BeforeEach {
        $null = New-Item -ItemType Directory -Path $legacy -Force
        '<?php $sugar_config = [];' | Set-Content -LiteralPath $config -Encoding ASCII
        Remove-Item -LiteralPath $override -ErrorAction SilentlyContinue
    }
    It 'adds a guarded default once without changing existing content' -Skip:(-not $php) {
        $existing = '<?php $sugar_config["default_export_charset"] = "UTF-8";'
        [IO.File]::WriteAllText($override, $existing)
        (& $php -n $helper $legacy) | Should Be 'unconfigured-redis-disabled'
        $once = [IO.File]::ReadAllText($override)
        $once.StartsWith($existing) | Should Be $true
        (& $php -n $helper $legacy) | Should Be 'operator-value-preserved'
        [IO.File]::ReadAllText($override) | Should Be $once
    }
    It 'preserves an explicit operator false value' -Skip:(-not $php) {
        $existing = '<?php $sugar_config["external_cache_disabled_redis"] = false;'
        [IO.File]::WriteAllText($override, $existing)
        (& $php -n $helper $legacy) | Should Be 'operator-value-preserved'
        [IO.File]::ReadAllText($override) | Should Be $existing
    }
    It 'preserves an explicit operator true value' -Skip:(-not $php) {
        $existing = '<?php $sugar_config["external_cache_disabled_redis"] = true;'
        [IO.File]::WriteAllText($override, $existing)
        (& $php -n $helper $legacy) | Should Be 'operator-value-preserved'
        [IO.File]::ReadAllText($override) | Should Be $existing
    }
    It 'preserves configured Redis servers' -Skip:(-not $php) {
        $existing = '<?php $sugar_config["external_cache"]["redis"]["host"] = "127.0.0.1";'
        [IO.File]::WriteAllText($override, $existing)
        (& $php -n $helper $legacy) | Should Be 'configured-redis-preserved'
        [IO.File]::ReadAllText($override) | Should Be $existing
    }
    It 'handles a closed PHP tag and later explicit Redis configuration' -Skip:(-not $php) {
        '<?php $sugar_config["other"] = true; ?>' | Set-Content -LiteralPath $override -Encoding ASCII
        (& $php -n $helper $legacy) | Should Be 'unconfigured-redis-disabled'
        (& $php -n -r '$sugar_config=[];ob_start();require($argv[1]);echo strlen(ob_get_clean());' $override) | Should Be '0'
        '<?php $sugar_config = ["external_cache" => ["redis" => ["host" => "127.0.0.1"]]];' | Set-Content -LiteralPath $config -Encoding ASCII
        (& $php -n $helper $legacy) | Should Be 'configured-redis-preserved'
    }
    It 'skips an uninstalled checkout without creating overrides' -Skip:(-not $php) {
        Remove-Item -LiteralPath $config
        (& $php -n $helper $legacy) | Should Be 'uninstalled'
        (Test-Path -LiteralPath $override) | Should Be $false
    }
}

Describe 'Instance ownership safeguards' {
    $context = Get-PackagingContext (Join-Path $TestDrive 'runtime') 18086 13312
    It 'reports stopped when neither port is listening' {
        Mock Get-NetTCPConnection { @() }
        (Get-InstanceStatus $context).State | Should Be 'Stopped'
    }
    It 'rejects non-loopback listeners' {
        Mock Get-NetTCPConnection { [pscustomobject]@{LocalAddress='0.0.0.0';OwningProcess=123} }
        { Get-InstanceStatus $context } | Should Throw
    }
    It 'rejects another checkout using the same binaries' {
        Mock Get-NetTCPConnection { [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=123} }
        Mock Get-CimInstance { [pscustomobject]@{ExecutablePath=$context.Apache;CommandLine='httpd -f C:\other\httpd.conf'} }
        { Get-InstanceListener $context 18086 $context.Apache 'httpd.conf' } | Should Throw
    }
    It 'accepts only the expected binary and config pair' {
        Mock Get-NetTCPConnection { [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=123} }
        Mock Get-CimInstance { [pscustomobject]@{ExecutablePath=$context.Apache;CommandLine=('httpd -f "' + (Join-Path $context.Instance 'httpd.conf') + '"')} }
        Get-InstanceListener $context 18086 $context.Apache 'httpd.conf' | Should Be 123
    }
    It 'tolerates a process disappearing during shutdown' {
        Mock Get-NetTCPConnection { [pscustomobject]@{LocalAddress='127.0.0.1';OwningProcess=123} }
        Mock Get-CimInstance { $null }
        Get-InstanceListener $context 18086 $context.Apache 'httpd.conf' | Should BeNullOrEmpty
    }
}

Describe 'Messenger supervision status' {
    $context = Get-PackagingContext (Join-Path $TestDrive 'worker-runtime') 18086 13312
    $null = New-Item -ItemType Directory -Path $context.Instance -Force
    $statePath = Join-Path $context.Instance 'messenger-state.json'
    BeforeEach {
        @{MonitorPid=456;WorkerPid=789} | ConvertTo-Json | Set-Content -LiteralPath $statePath
        Remove-Item -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -ErrorAction SilentlyContinue
    }
    It 'does not restart the launcher after a requested Messenger stop' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        Get-StartupMonitorState $context ([pscustomobject]@{HasExited=$true}) | Should Be 'Stopped'
    }
    It 'still fails the launcher after an unexpected Messenger exit' {
        { Get-StartupMonitorState $context ([pscustomobject]@{HasExited=$true}) } | Should Throw 'Messenger supervisor exited'
    }
    It 'waits for a live Messenger monitor even during a requested stop' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        Get-StartupMonitorState $context ([pscustomobject]@{HasExited=$false}) | Should Be 'Running'
    }
    It 'ignores a stale state record when the supervisor is gone' {
        Mock Get-CimInstance { $null }
        Get-MessengerStatus $context | Should Be 'Stopped'
    }
    It 'rejects PID reuse by an unrelated supervisor process' {
        Mock Get-CimInstance { [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine='unrelated.ps1'} }
        { Get-MessengerStatus $context } | Should Throw
    }
    It 'recognizes only the owned supervisor and queue consumer' {
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -eq 'ProcessId=456') {
                return [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine=(Join-Path $context.Repo 'scripts\windows\messenger-worker.ps1')}
            }
            [pscustomobject]@{ExecutablePath=$context.Php;CommandLine=((Join-Path $context.Repo 'bin\console') + ' messenger:consume internal-async')}
        }
        Get-MessengerStatus $context | Should Be 'Running'
    }
    It 'reports stopping only after validating the supervisor and worker' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -eq 'ProcessId=456') {
                return [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine=(Join-Path $context.Repo 'scripts\windows\messenger-worker.ps1')}
            }
            [pscustomobject]@{ExecutablePath=$context.Php;CommandLine=((Join-Path $context.Repo 'bin\console') + ' messenger:consume internal-async')}
        }
        Get-MessengerStatus $context | Should Be 'Stopping'
    }
    It 'rechecks an exiting worker instead of throwing during forced shutdown' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        $script:workerQueries = 0
        Mock Start-Sleep {}
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -eq 'ProcessId=456') {
                return [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine=(Join-Path $context.Repo 'scripts\windows\messenger-worker.ps1')}
            }
            $script:workerQueries++
            if ($script:workerQueries -eq 1) { return [pscustomobject]@{ExecutablePath=$null;CommandLine=$null} }
            $null
        }
        Get-MessengerStatus $context | Should Be 'Stopping'
        $script:workerQueries | Should Be 2
    }
    It 'still rejects a foreign worker with a stop request after bounded rechecks' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        $script:workerQueries = 0
        Mock Start-Sleep {}
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -eq 'ProcessId=456') {
                return [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine=(Join-Path $context.Repo 'scripts\windows\messenger-worker.ps1')}
            }
            $script:workerQueries++
            [pscustomobject]@{ExecutablePath=$context.Php;CommandLine='unrelated.php'}
        }
        { Get-MessengerStatus $context } | Should Throw 'Messenger worker ownership mismatch.'
        $script:workerQueries | Should Be 11
    }
    It 'does not retry or accept a foreign worker without a stop request' {
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -eq 'ProcessId=456') {
                return [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine=(Join-Path $context.Repo 'scripts\windows\messenger-worker.ps1')}
            }
            [pscustomobject]@{ExecutablePath=$context.Php;CommandLine='unrelated.php'}
        }
        Mock Start-Sleep { throw 'Unexpected retry without a stop request' }
        { Get-MessengerStatus $context } | Should Throw 'Messenger worker ownership mismatch.'
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
    }
    It 'rereads state removal while an exiting worker is being rechecked' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        Mock Start-Sleep { Remove-Item -LiteralPath $statePath }
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -eq 'ProcessId=456') {
                return [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine=(Join-Path $context.Repo 'scripts\windows\messenger-worker.ps1')}
            }
            [pscustomobject]@{ExecutablePath=$context.Php;CommandLine=$null}
        }
        Get-MessengerStatus $context | Should Be 'Stopped'
    }
    It 'still rejects a foreign supervisor even with a stop request' {
        Set-Content -LiteralPath (Join-Path $context.Instance 'messenger-stop-requested') -Value 'stop'
        Mock Get-CimInstance { [pscustomobject]@{ExecutablePath=$context.PowerShell;CommandLine='unrelated.ps1'} }
        { Get-MessengerStatus $context } | Should Throw 'Messenger state refers to a foreign process'
    }
    It 'marks a missing required worker as partial rather than green' {
        Mock Get-MessengerStatus { 'Stopped' }
        Mock Get-InstanceStatus { [pscustomobject]@{State='Running'} }
        (Get-PackagingStatus $context ([pscustomobject]@{WithMessenger=$true})).State | Should Be 'Partial'
    }
}

Describe 'Packaging entry points in disposable fixture checkouts' {
    $fixture = Join-Path $TestDrive 'checkout with spaces'
    $scripts = Join-Path $fixture 'scripts\windows'
    $root = Join-Path $TestDrive 'packages and state'
    $null = New-Item -ItemType Directory -Path $scripts -Force
    foreach ($name in @('packaging-common.ps1', 'build.ps1', 'test.ps1', 'run.ps1', 'install-service.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\$name") -Destination (Join-Path $scripts $name)
    }
    'param($RuntimeRoot); exit 0' | Set-Content -LiteralPath (Join-Path $scripts 'prepare.ps1')
    'param($Action,$RuntimeRoot,$HttpPort,$DbPort); if ($env:SUITECRM_FIXTURE_FAIL) { exit 23 }; [Console]::Error.WriteLine("Syntax OK"); exit 0' | Set-Content -LiteralPath (Join-Path $scripts 'runtime.ps1')
    $powershell = Join-Path $PSHOME 'powershell.exe'
    It 'build succeeds for a successful backend child, including stderr' {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'build.ps1') -Target Backend -RuntimeRoot $root
        $LASTEXITCODE | Should Be 0
        [xml]$report = Get-Content -LiteralPath (Join-Path $fixture 'tests\_output\windows\build.xml') -Raw
        $report.testsuite.failures | Should Be 0
    }
    It 'build returns nonzero and writes JUnit when a runtime child fails' {
        $env:SUITECRM_FIXTURE_FAIL = '1'
        try { & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'build.ps1') -Target Backend -RuntimeRoot $root }
        finally { Remove-Item Env:SUITECRM_FIXTURE_FAIL }
        $LASTEXITCODE | Should Not Be 0
        [xml]$report = Get-Content -LiteralPath (Join-Path $fixture 'tests\_output\windows\build.xml') -Raw
        [int]$report.testsuite.failures | Should BeGreaterThan 0
    }
    It 'all tests attempt all suites and fail honestly with missing dependencies' {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'test.ps1') -Suite all -RuntimeRoot $root
        $LASTEXITCODE | Should Not Be 0
        [xml]$report = Get-Content -LiteralPath (Join-Path $fixture 'tests\_output\windows\test-all.xml') -Raw
        $report.testsuite.tests | Should Be 7
        $report.testsuite.failures | Should Be 7
    }
    It 'status of an unused fixture is stopped, with exit 2' {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'run.ps1') -Action Status -RuntimeRoot $root -HttpPort 58186 -DbPort 58312
        $LASTEXITCODE | Should Be 2
    }
    It 'unregister is harmless without owned registration' {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'install-service.ps1') -Action Unregister -RuntimeRoot $root -HttpPort 58186 -DbPort 58312
        $LASTEXITCODE | Should Be 0
    }
    It 'service mode fails closed without elevation or an approved wrapper' {
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scripts 'install-service.ps1') -StartupMode Service -NoStart -RuntimeRoot $root -HttpPort 58186 -DbPort 58312
        $LASTEXITCODE | Should Not Be 0
    }
}
