[CmdletBinding()]
param(
    [ValidateSet('unit', 'integration', 'frontend', 'all')][string] $Suite = 'all',
    [string] $RuntimeRoot = (Join-Path $env:LOCALAPPDATA 'SuiteCRM-Windows-Runtime')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'packaging-common.ps1')
$context = Get-PackagingContext $RuntimeRoot
$savedEnvironment = Get-PackagingEnvironmentSnapshot
$results = @()
try {
    Set-PackagingEnvironment $context
    if ($Suite -in @('unit', 'all')) {
        $results += Invoke-PackagingCommand $context 'unit-build' $context.Php (Get-PhpCliArguments @('vendor/bin/codecept', 'build', '--no-colors'))
        $results += Invoke-PackagingCommand $context 'unit' $context.Php (Get-PhpCliArguments @('vendor/bin/codecept', 'run', 'unit', '--no-colors', '--xml=windows-unit.xml'))
    }
    if ($Suite -in @('integration', 'all')) {
        $results += Invoke-PackagingCommand $context 'packaging' $context.PowerShell @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'tests\packaging.tests.ps1'), '-OutputPath', (Join-Path $context.Reports 'packaging.xml'))
        $results += Invoke-PackagingCommand $context 'console-entry' $context.Php (Get-PhpCliArguments @('vendor/bin/phpunit', '--bootstrap', 'vendor/autoload.php', '--do-not-cache-result', '--log-junit', (Join-Path $context.Reports 'console-entry.xml'), 'tests/unit/core/legacy/SchedulerConsoleEntryPointTest.php'))
        $results += Invoke-PackagingCommand $context 'junit-reporter' $context.Node @('--test', '--test-reporter=junit', "--test-reporter-destination=$(Join-Path $context.Reports 'junit-reporter.xml')", (Join-Path $PSScriptRoot 'tests\karma-junit.test.cjs'))
    }
    if ($Suite -in @('frontend', 'all')) {
        if (-not $env:CHROME_BIN) {
            $chrome = @(@("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path -LiteralPath $_ })
            if ($chrome) { $env:CHROME_BIN = $chrome[0] }
        }
        foreach ($project in @('core', 'shell')) {
            $env:SUITECRM_KARMA_PROJECT = $project
            $env:SUITECRM_JUNIT_PATH = Join-Path $context.Reports "frontend-$project.xml"
            $results += Invoke-PackagingCommand $context "frontend-$project" $context.Corepack @('yarn', 'ng', 'test', $project, '--watch=false', '--browsers=PackagingHeadless', "--karma-config=$(Join-Path $PSScriptRoot 'karma-junit.cjs')")
        }
    }
} catch {
    $results += [pscustomobject]@{ Name = 'runner'; ExitCode = 1; Seconds = 0; Log = $_.Exception.Message }
    Write-Warning $_.Exception.Message
} finally {
    Restore-PackagingEnvironment $savedEnvironment
    Write-PackagingJUnit (Join-Path $context.Reports "test-$Suite.xml") 'windows-test-commands' $results
}
if (-not $results.Count -or @($results | Where-Object ExitCode -ne 0).Count) { exit 1 }
