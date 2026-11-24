[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop')][string] $Action = 'Start',
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime'),
    [ValidateRange(1024, 65535)][int] $HttpPort = 18080,
    [ValidateRange(1024, 65535)][int] $DbPort = 13306
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'packaging-common.ps1')
$context = Get-PackagingContext $RuntimeRoot $HttpPort $DbPort
Set-PackagingEnvironment $context
$context.Reports = Join-Path $context.Instance 'logs'
$statePath = Join-Path $context.Instance 'messenger-state.json'
$stopPath = Join-Path $context.Instance 'messenger-stop-requested'
if ($Action -eq 'Stop') {
    if ((Get-MessengerStatus $context) -eq 'Stopped') { exit 0 }
    [IO.File]::WriteAllText($stopPath, 'stop')
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        if ((Get-MessengerStatus $context) -eq 'Stopped') { exit 0 }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Messenger stop timed out; web/database were not stopped.'
}
$null = New-Item -ItemType Directory -Path $context.Reports -Force
$lock = $null
try { $lock = [IO.File]::Open((Join-Path $context.Instance 'messenger.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] { Write-Host 'Messenger supervisor already running.'; exit 0 }
$worker = $null
function Write-WorkerState([int] $WorkerId) {
    $stateLock = Open-MessengerStateLock $context
    try { [IO.File]::WriteAllText($statePath, (@{MonitorPid=$PID;WorkerPid=$WorkerId} | ConvertTo-Json)) }
    finally { $stateLock.Dispose() }
}
function Write-WorkerLog([string] $Text) {
    [IO.File]::AppendAllText((Join-Path $context.Reports 'messenger-supervisor.log'), "$(Get-Date -Format o) $Text`r`n")
}
try {
    if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath }
    Write-WorkerState 0
    $deadline = [DateTime]::UtcNow.AddSeconds(120)
    do {
        if (Test-Path -LiteralPath $stopPath) { return }
        if ((Get-InstanceStatus $context).State -eq 'Running') { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Web/database did not become ready for Messenger.' }
        Start-Sleep -Seconds 1
    } while ($true)
    $console = Join-Path $context.Repo 'bin\console'
    $cycle = 0
    while (-not (Test-Path -LiteralPath $stopPath)) {
        $cycle++
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $line = (@($console, 'messenger:consume', 'internal-async', '--time-limit=300', '--memory-limit=256M', '--no-interaction', '--no-ansi') | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
        $worker = Start-Process -FilePath $context.Php -ArgumentList $line -WorkingDirectory $context.Repo -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $context.Reports "messenger-$stamp-$cycle.stdout.log") -RedirectStandardError (Join-Path $context.Reports "messenger-$stamp-$cycle.stderr.log")
        Write-WorkerState $worker.Id
        Write-WorkerLog "Started worker $($worker.Id), bounded to300s/256M."
        while (-not $worker.WaitForExit(1000)) {
            if (Test-Path -LiteralPath $stopPath) { break }
        }
        if (Test-Path -LiteralPath $stopPath) { break }
        Write-WorkerLog "Worker exited $($worker.ExitCode); restart in5s."
        Write-WorkerState 0
        for ($i=0; $i -lt 5 -and -not (Test-Path -LiteralPath $stopPath); $i++) { Start-Sleep -Seconds 1 }
    }
} finally {
    if ($worker -and -not $worker.HasExited) {
        $null = Get-MessengerStatus $context
        $result = Invoke-PackagingCommand $context 'messenger-stop' $context.Php @((Join-Path $context.Repo 'bin\console'), 'messenger:stop-workers', '--no-interaction', '--no-ansi')
        if (-not $worker.WaitForExit(30000)) {
            Write-WorkerLog 'Graceful stop exceeded30s; terminating owned worker, transport redelivery policy applies.'
            $null = Get-MessengerStatus $context
            Stop-Process -InputObject $worker
            $null = $worker.WaitForExit(10000)
        }
    }
    $stateLock = Open-MessengerStateLock $context
    try { if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath } }
    finally { $stateLock.Dispose() }
    $lock.Dispose()
    Write-WorkerLog 'Supervisor stopped.'
}
