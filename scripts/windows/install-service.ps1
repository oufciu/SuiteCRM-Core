[CmdletBinding()]
param(
    [ValidateSet('Register', 'Unregister')][string] $Action = 'Register',
    [ValidateSet('Task', 'Service')][string] $StartupMode = 'Task',
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime'),
    [ValidateRange(1024, 65535)][int] $HttpPort = 18080,
    [ValidateRange(1024, 65535)][int] $DbPort = 13306,
    [string] $ServiceWrapperPath,
    [string] $WrapperSha256,
    [string] $ServiceAccount,
    [switch] $WithMessenger,
    [switch] $NoStart
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'packaging-common.ps1')
$context = Get-PackagingContext $RuntimeRoot $HttpPort $DbPort
$run = Join-Path $PSScriptRoot 'run.ps1'
try {
    $registration = Get-StartupRegistration $context
    if ($registration -and $registration.Mode -ne $StartupMode) { throw 'Unregister the existing startup mode before changing it.' }
    if ($Action -eq 'Register' -and $registration -and [bool]$registration.WithMessenger -ne [bool]$WithMessenger) {
        throw 'Unregister first to change Messenger supervision; instance data will be retained.'
    }
    if ($Action -eq 'Register' -and $WithMessenger -and -not (Test-Path -LiteralPath (Join-Path $context.Repo 'public\legacy\config.php'))) {
        throw 'Install the disposable application before enabling Messenger. Its queue needs the installed database.'
    }
    # Even registration must not accept another instance's occupied ports.
    $null = Get-InstanceStatus $context
    if ($StartupMode -eq 'Service') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Service mode requires an elevated PowerShell and a separately approved WinSW wrapper. Task mode needs neither.'
        }
        if ($Action -eq 'Register') {
            if ($ServiceAccount -ne 'NT AUTHORITY\LocalService') {
                throw 'Service mode requires explicit -ServiceAccount "NT AUTHORITY\LocalService" and operator-prepared least-privilege NTFS access. LocalSystem is not used.'
            }
            if (-not $ServiceWrapperPath -or -not (Test-Path -LiteralPath $ServiceWrapperPath -PathType Leaf) -or $WrapperSha256 -notmatch '^[a-fA-F0-9]{64}$') {
                throw 'Provide an approved WinSW 2.x executable with -ServiceWrapperPath and its pinned -WrapperSha256. No wrapper is downloaded.'
            }
            if ((Get-FileHash -LiteralPath $ServiceWrapperPath -Algorithm SHA256).Hash -ne $WrapperSha256) { throw 'Wrapper checksum mismatch.' }
        }
    }
    if ($Action -eq 'Unregister') {
        if (-not $registration) { Write-Host 'No owned startup registration.'; exit 0 }
        $task = $null
        if ($StartupMode -eq 'Task') { $task = Get-OwnedStartupTask $context }
        elseif ((Get-FileHash -LiteralPath $registration.Wrapper -Algorithm SHA256).Hash -ne $registration.WrapperSha256) { throw 'Installed wrapper checksum changed; refusing to execute it.' }
        & $context.PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $run -Action Stop -RuntimeRoot $context.Root -HttpPort $HttpPort -DbPort $DbPort
        if ($LASTEXITCODE -ne 0) { throw 'Stop failed; registration retained.' }
        if ($StartupMode -eq 'Task') {
            if ($task) { Unregister-ScheduledTask -TaskName $context.TaskName -Confirm:$false -ErrorAction Stop }
        } else {
            & $registration.Wrapper uninstall
            if ($LASTEXITCODE -ne 0) { throw 'WinSW uninstall failed; registration retained.' }
        }
        Remove-Item -LiteralPath $context.Registration
        Write-Host 'Startup removed; instance data, configs and logs retained.'
        exit 0
    }
    $logs = Join-Path $context.Instance 'logs'
    $null = New-Item -ItemType Directory -Path $logs -Force
    $launcher = Join-Path $context.Instance 'startup-launcher.ps1'
    $launcherBody = @'
$ErrorActionPreference = 'Stop'
$registration = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'startup-registration.json') -Raw | ConvertFrom-Json
. (Join-Path $registration.Repo 'scripts\windows\packaging-common.ps1')
$context = Get-PackagingContext $registration.Root $registration.HttpPort $registration.DbPort
$context.Reports = Join-Path $context.Instance 'logs'
$name = 'startup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$monitor = $null
$runtime = $null
$code = 1
try {
    $runtimeLine = ((Get-RuntimeArguments $context 'Serve') | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    $runtime = Start-Process -FilePath $context.PowerShell -ArgumentList $runtimeLine -WorkingDirectory $context.Repo -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $context.Reports "$name.stdout.log") -RedirectStandardError (Join-Path $context.Reports "$name.stderr.log")
    if ($registration.WithMessenger) {
        $workerScript = Join-Path $registration.Repo 'scripts\windows\messenger-worker.ps1'
        $workerArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $workerScript, '-RuntimeRoot', $context.Root, '-HttpPort', [string]$context.HttpPort, '-DbPort', [string]$context.DbPort)
        $line = ($workerArguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
        $monitor = Start-Process -FilePath $context.PowerShell -ArgumentList $line -WorkingDirectory $context.Repo -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $context.Reports "$name-worker.stdout.log") -RedirectStandardError (Join-Path $context.Reports "$name-worker.stderr.log")
    }
    while (-not $runtime.WaitForExit(1000)) {
        if ($monitor -and $monitor.HasExited) { throw 'Messenger supervisor exited; restarting the whole owned runtime.' }
    }
    $code = $runtime.ExitCode
} catch {
    [IO.File]::AppendAllText((Join-Path $context.Reports 'startup-supervisor.log'), "$(Get-Date -Format o) $($_.Exception.Message)`r`n")
} finally {
    if ($monitor -and -not $monitor.HasExited) {
        & $context.PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $workerScript -Action Stop -RuntimeRoot $context.Root -HttpPort $context.HttpPort -DbPort $context.DbPort
    }
    if ($runtime -and -not $runtime.HasExited) {
        $null = Invoke-PackagingCommand $context 'startup-stop' $context.PowerShell (Get-RuntimeArguments $context 'Stop')
        if (-not $runtime.WaitForExit(60000)) { Write-Warning 'Runtime did not finish stopping; retained for inspection.' }
    }
}
exit $code
'@
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ' + (ConvertTo-WindowsArgument $launcher)
    $record = [ordered]@{ Repo = $context.Repo; Root = $context.Root; HttpPort = $HttpPort; DbPort = $DbPort; Mode = $StartupMode; WithMessenger = [bool]$WithMessenger }
    if ($StartupMode -eq 'Task') {
        $existing = Get-ScheduledTask -TaskName $context.TaskName -ErrorAction SilentlyContinue
        if ($existing) {
            if (-not $registration -or $existing.Actions.Execute -ne $context.PowerShell -or $existing.Actions.Arguments -ne $arguments) {
                throw 'Task name already exists without matching ownership. Refusing overwrite.'
            }
            Write-Host 'Owned task already registered.'
        } else {
            [IO.File]::WriteAllText($launcher, $launcherBody, [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($context.Registration, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $taskAction = New-ScheduledTaskAction -Execute $context.PowerShell -Argument $arguments -WorkingDirectory $context.Repo
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
            $taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            $null = Register-ScheduledTask -TaskName $context.TaskName -Action $taskAction -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Description "Loopback SuiteCRM disposable instance $($context.Id); per-user logon, not a Windows service." -ErrorAction Stop
            Write-Host "Registered per-user logon task $($context.TaskName)."
        }
    } else {
        if (Get-Service -Name $context.ServiceName -ErrorAction SilentlyContinue) { throw 'Service already exists. Refusing overwrite.' }
        $serviceFolder = Join-Path $context.Instance 'service'
        $null = New-Item -ItemType Directory -Path $serviceFolder -Force
        $wrapper = Join-Path $serviceFolder "$($context.ServiceName).exe"
        Copy-Item -LiteralPath $ServiceWrapperPath -Destination $wrapper
        $record.Wrapper = $wrapper
        $record.WrapperSha256 = $WrapperSha256
        [IO.File]::WriteAllText($launcher, $launcherBody, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($context.Registration, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $xml = New-Object Xml.XmlDocument
        $service = $xml.CreateElement('service'); $null = $xml.AppendChild($service)
        $stopArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (ConvertTo-WindowsArgument $run) + ' -Action Stop -RuntimeRoot ' + (ConvertTo-WindowsArgument $context.Root) + " -HttpPort $HttpPort -DbPort $DbPort"
        foreach ($entry in ([ordered]@{
            id = $context.ServiceName; name = $context.ServiceName
            description = 'Loopback SuiteCRM disposable runtime'
            executable = $context.PowerShell; arguments = $arguments
            stopexecutable = $context.PowerShell; stoparguments = $stopArguments
            stoptimeout = '120 sec'; logpath = $logs; startmode = 'Automatic'
        }).GetEnumerator()) {
            $element = $xml.CreateElement($entry.Key); $element.InnerText = $entry.Value; $null = $service.AppendChild($element)
        }
        $onfailure = $xml.CreateElement('onfailure')
        $onfailure.SetAttribute('action', 'restart'); $onfailure.SetAttribute('delay', '1 min')
        $null = $service.AppendChild($onfailure)
        $account = $xml.CreateElement('serviceaccount')
        foreach ($entry in (@{domain='NT AUTHORITY';user='LocalService'}).GetEnumerator()) {
            $element = $xml.CreateElement($entry.Key); $element.InnerText = $entry.Value; $null = $account.AppendChild($element)
        }
        $null = $service.AppendChild($account)
        $xml.Save([IO.Path]::ChangeExtension($wrapper, '.xml'))
        & $wrapper install
        if ($LASTEXITCODE -ne 0) { throw 'WinSW install failed.' }
    }
    if (-not $NoStart) {
        & $context.PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $run -Action Start -RuntimeRoot $context.Root -HttpPort $HttpPort -DbPort $DbPort
        if ($LASTEXITCODE -ne 0) { throw 'Startup registered but runtime did not become ready. Inspect instance logs; registration retained.' }
    }
} catch { Write-Warning $_.Exception.Message; exit 1 }
