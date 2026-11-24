[CmdletBinding()]
param(
    [ValidateSet('All', 'Backend', 'Frontend')][string] $Target = 'All',
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'packaging-common.ps1')
$context = Get-PackagingContext $RuntimeRoot
$results = @()
$savedEnvironment = Get-PackagingEnvironmentSnapshot
try {
    $results += Invoke-PackagingCommand $context 'prepare' $context.PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'prepare.ps1'), '-RuntimeRoot', $context.Root)
    if ($results[-1].ExitCode -ne 0) { throw 'prepare failed.' }
    foreach ($action in @('Backend', 'Frontend')) {
        if ($Target -ne 'All' -and $Target -ne $action) { continue }
        $results += Invoke-PackagingCommand $context "build-$action" $context.PowerShell (Get-RuntimeArguments $context $action)
        if ($results[-1].ExitCode -ne 0) { throw "$action failed." }
    }
    if ($Target -ne 'Backend') {
        Set-PackagingEnvironment $context
        $theme = Join-Path $context.Repo 'public\legacy\themes\suite8\css\Dawn'
        $results += Invoke-PackagingCommand $context 'build-Dawn' $context.Php @((Join-Path $context.Repo 'vendor\bin\pscss'), '-s', 'compressed', (Join-Path $theme 'style.scss'), (Join-Path $theme 'style.css'))
        if ($results[-1].ExitCode -ne 0) { throw 'Dawn theme compilation failed.' }
    }
} catch {
    $results += [pscustomobject]@{ Name = 'runner'; ExitCode = 1; Seconds = 0; Log = $_.Exception.Message }
    Write-Warning $_.Exception.Message
}
finally {
    Restore-PackagingEnvironment $savedEnvironment
    Write-PackagingJUnit (Join-Path $context.Reports 'build.xml') 'windows-build-commands' $results
}
if (-not $results.Count -or @($results | Where-Object ExitCode -ne 0).Count) { exit 1 }
