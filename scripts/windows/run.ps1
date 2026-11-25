[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Status')][string] $Action = 'Start',
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime'),
    [ValidateRange(1024, 65535)][int] $HttpPort = 18080,
    [ValidateRange(1024, 65535)][int] $DbPort = 13306,
    [ValidateRange(1, 600)][int] $WaitSeconds = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'packaging-common.ps1')
$context = Get-PackagingContext $RuntimeRoot $HttpPort $DbPort
try {
    $registration = Get-StartupRegistration $context
    $status = Get-PackagingStatus $context $registration
    if ($Action -eq 'Status') {
        $status | Format-List | Out-Host
        if ($status.State -eq 'Running') { exit 0 }
        if ($status.State -eq 'Partial') { exit 3 }
        exit 2
    }
    if ($Action -eq 'Stop') {
        if ($status.State -eq 'Stopped') { Write-Host 'Already stopped.'; exit 0 }
        if ($status.Messenger -ne 'Stopped') {
            & $context.PowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'messenger-worker.ps1') -Action Stop -RuntimeRoot $context.Root -HttpPort $HttpPort -DbPort $DbPort
            if ($LASTEXITCODE -ne 0) { throw 'Messenger did not stop; database retained.' }
        }
        $result = Invoke-PackagingCommand $context 'stop' $context.PowerShell (Get-RuntimeArguments $context 'Stop')
        if ($result.ExitCode -ne 0) { throw 'Runtime Stop failed.' }
        $wanted = 'Stopped'
    } else {
        if ($status.State -eq 'Running') { Write-Host 'Already running.'; exit 0 }
        if ($status.State -eq 'Partial') { throw 'Partial instance; stop it before restarting.' }
        if (-not $registration) {
            Write-Host 'No startup registration: running in this terminal. Keep it open, or use install-service.ps1.'
            & $context.PowerShell @(Get-RuntimeArguments $context 'Serve')
            exit $LASTEXITCODE
        }
        if ($registration.Mode -eq 'Task') {
            if (-not (Get-OwnedStartupTask $context)) { throw 'Registered task is missing. Register it again.' }
            Start-ScheduledTask -TaskName $context.TaskName -ErrorAction Stop
        } elseif ($registration.Mode -eq 'Service') {
            Start-Service -Name $context.ServiceName -ErrorAction Stop
        } else { throw 'Unknown startup registration mode.' }
        $wanted = 'Running'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $status = Get-PackagingStatus $context $registration
        if ($status.State -eq $wanted) { $status | Format-List | Out-Host; exit 0 }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $wanted; inspect $($context.Instance)\logs."
} catch { Write-Warning $_.Exception.Message; exit 1 }
