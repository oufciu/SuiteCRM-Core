<#
Self-contained tests for scripts/windows/compare-parity.ps1 (no Pester needed).
When Python 3 is on PATH, scripts/windows/compare-parity.py is run on every case too
and must give the same exit code and the same output.

  powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\compare-parity.Tests.ps1
  pwsh -NoProfile -File tests/windows/compare-parity.Tests.ps1
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
$ps1 = Join-Path (Join-Path $repo 'scripts') (Join-Path 'windows' 'compare-parity.ps1')
$py = Join-Path (Join-Path $repo 'scripts') (Join-Path 'windows' 'compare-parity.py')
$psExe = (Get-Process -Id $PID).Path
$python = $null
foreach ($name in @('python3', 'python')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) {
        & $cmd.Source -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>$null
        if ($LASTEXITCODE -eq 0) { $python = $cmd.Source; break }
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
# Built from code points so the test does not depend on how PowerShell 5.1 decodes this file.
$uni = 'za' + (-join ([char[]](0x017C, 0x00F3, 0x0142, 0x0107))) + ' ' + [char]0x0141 + [char]0x00F3 + 'd' + [char]0x017A
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('parity-tests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp)
$script:failures = 0
$script:passes = 0

function Write-File([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Invoke-Impl([string]$Impl, [string[]]$Arguments) {
    $outFile = Join-Path $tmp ('out-' + [guid]::NewGuid().ToString('N') + '.txt')
    $errFile = $outFile + '.err'
    if ($Impl -eq 'ps') {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ps1) + $Arguments
        $p = Start-Process -FilePath $psExe -ArgumentList (Join-Quoted $all) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } else {
        $map = @{ '-Baseline' = '--baseline'; '-Candidate' = '--candidate'; '-Accepted' = '--accepted'; '-JsonReport' = '--json-report' }
        $pyArgs = @($py) + @($Arguments | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
        $p = Start-Process -FilePath $python -ArgumentList (Join-Quoted $pyArgs) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    }
    $out = ''
    if (Test-Path -LiteralPath $outFile) { $out = [IO.File]::ReadAllText($outFile, $utf8) }
    return New-Object PSObject -Property @{ Code = $p.ExitCode; Out = $out.Replace("`r`n", "`n") }
}

function Join-Quoted([string[]]$Items) {
    return (($Items | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' ')
}

function Invoke-Case([string]$Name, [string[]]$Arguments, [int]$ExpectCode, [string[]]$ExpectLines, [string[]]$RejectLines) {
    $impls = @('ps')
    if ($null -ne $python) { $impls += 'py' }
    $results = @{}
    foreach ($impl in $impls) {
        $r = Invoke-Impl $impl $Arguments
        $results[$impl] = $r
        $problems = @()
        if ($r.Code -ne $ExpectCode) { $problems += "exit $($r.Code), expected $ExpectCode" }
        $lines = $r.Out -split "`n"
        foreach ($l in @($ExpectLines)) { if ($l -and -not ($lines -ccontains $l)) { $problems += "missing line: $l" } }
        foreach ($l in @($RejectLines)) { if ($l -and ($r.Out.Contains($l))) { $problems += "unexpected text: $l" } }
        Report "$Name [$impl]" $problems $r.Out
    }
    if ($results.ContainsKey('py')) {
        $same = @()
        if ($results['ps'].Code -ne $results['py'].Code) { $same += 'exit codes differ' }
        if (-not [string]::Equals($results['ps'].Out, $results['py'].Out, [StringComparison]::Ordinal)) { $same += 'outputs differ' }
        Report "$Name [ps == py]" $same ($results['ps'].Out + "---- py ----`n" + $results['py'].Out)
    }
}

function Report([string]$Name, [string[]]$Problems, [string]$Detail) {
    if (@($Problems).Count -eq 0) { $script:passes++; Write-Host "ok   $Name"; return }
    $script:failures++
    Write-Host "FAIL $Name"
    foreach ($p in $Problems) { Write-Host "     $p" }
    Write-Host ($Detail -replace '(?m)^', '     | ')
}

function Case([string]$Class, [string]$TestName, [string]$Status, [string]$ClassAttr = 'classname') {
    $body = ''
    if ($Status -eq 'failed') { $body = '<failure message="x">boom</failure>' }
    if ($Status -eq 'error') { $body = '<error type="Error">boom</error>' }
    if ($Status -eq 'skipped') { $body = '<skipped/>' }
    $n = [Security.SecurityElement]::Escape($TestName)
    return "<testcase $ClassAttr=`"$Class`" name=`"$n`" time=`"0.010`">$body</testcase>"
}

function Suite([string[]]$Cases) {
    return "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<testsuites><testsuite name=`"s`">" + ($Cases -join "`n") + "</testsuite></testsuites>`n"
}

function Steps([string[]]$Rows) {
    return "step`texit_code`tseconds`tcommand`n" + (($Rows | ForEach-Object { $_ }) -join "`n") + "`n"
}

try {
    # Baseline: Karma-style suite with classname, Codeception-style suite with class, steps.tsv, junit\ subdirectory.
    $base = Join-Path $tmp 'base'
    Write-File (Join-Path $base 'junit/karma.xml') (Suite @(
        (Case 'A' 'keeps passing' 'passed'),
        (Case 'A' 'will fail' 'passed'),
        (Case 'A' 'will error' 'passed'),
        (Case 'A' 'will pass' 'failed'),
        (Case 'A' 'will skip' 'passed'),
        (Case 'A' 'goes missing' 'passed'),
        (Case 'A' 'dup' 'passed'),
        (Case 'A' 'dup' 'passed'),
        (Case 'A' 'name [with] brackets' 'passed'),
        (Case 'A' $uni 'passed'),
        (Case 'A' 'stays failed' 'failed')))
    Write-File (Join-Path $base 'junit/php-unit.xml') (Suite @(
        (Case 'App\Tests\FooTest' 'testOk' 'passed' 'class'),
        (Case 'App\Tests\FooTest' 'testSkip' 'skipped' 'class')))
    Write-File (Join-Path $base 'junit/gone.xml') (Suite @((Case 'G' 'only in baseline' 'passed')))
    Write-File (Join-Path $base 'steps.tsv') (Steps @("build`t0`t1.0`tyarn build", "karma`t0`t2.0`tyarn ng test"))

    # Identical copy laid out flat (no junit\ subdirectory) to cover both layouts.
    $same = Join-Path $tmp 'same'
    foreach ($f in @('karma.xml', 'php-unit.xml', 'gone.xml')) {
        Write-File (Join-Path $same $f) ([IO.File]::ReadAllText((Join-Path $base "junit/$f"), $utf8))
    }
    Write-File (Join-Path $same 'steps.tsv') ([IO.File]::ReadAllText((Join-Path $base 'steps.tsv'), $utf8))

    $cand = Join-Path $tmp 'cand'
    Write-File (Join-Path $cand 'junit/karma.xml') (Suite @(
        (Case 'A' 'keeps passing' 'passed'),
        (Case 'A' 'will fail' 'failed'),
        (Case 'A' 'will error' 'error'),
        (Case 'A' 'will pass' 'passed'),
        (Case 'A' 'will skip' 'skipped'),
        (Case 'A' 'dup' 'passed'),
        (Case 'A' 'dup' 'failed'),
        (Case 'A' 'name [with] brackets' 'failed'),
        (Case 'A' $uni 'failed'),
        (Case 'A' 'stays failed' 'failed'),
        (Case 'A' 'brand new' 'passed')))
    Write-File (Join-Path $cand 'junit/php-unit.xml') (Suite @(
        (Case 'App\Tests\FooTest' 'testOk' 'passed' 'class'),
        (Case 'App\Tests\FooTest' 'testSkip' 'skipped' 'class')))
    Write-File (Join-Path $cand 'junit/extra.xml') (Suite @((Case 'E' 'only in candidate' 'passed')))
    Write-File (Join-Path $cand 'steps.tsv') (Steps @("build`t0`t1.5`tyarn build", "karma`t1`t2.0`tyarn ng test", "new-step`t0`t0.1`techo"))

    Invoke-Case 'identical runs pass, junit and flat layouts' @('-Baseline', $base, '-Candidate', $same) 0 @(
        'Suite karma: baseline 11 tests (9 passed, 2 failed, 0 skipped); candidate 11 tests (9 passed, 2 failed, 0 skipped)',
        'Suite php-unit: baseline 2 tests (1 passed, 0 failed, 1 skipped); candidate 2 tests (1 passed, 0 failed, 1 skipped)',
        'Differences: 0 (0 unaccepted, 0 accepted)', 'Result: PASS') @('[UNACCEPTED]')

    $dupA = Join-Path $tmp 'dup-a'
    $dupB = Join-Path $tmp 'dup-b'
    Write-File (Join-Path $dupA 'karma.xml') (Suite @((Case 'D' 'same name' 'failed'), (Case 'D' 'same name' 'passed'), (Case 'D' 'same name' 'skipped')))
    Write-File (Join-Path $dupB 'karma.xml') (Suite @((Case 'D' 'same name' 'skipped'), (Case 'D' 'same name' 'passed'), (Case 'D' 'same name' 'failed')))
    Invoke-Case 'same-named specs in a different order are not a difference' @('-Baseline', $dupA, '-Candidate', $dupB) 0 @(
        'Differences: 0 (0 unaccepted, 0 accepted)') @()

    $codecept = Join-Path $tmp 'codecept'
    Write-File (Join-Path $codecept 'junit/php-unit.xml') (Suite @(
        (Case 'App\Tests\FooTest' 'testOk' 'error' 'class'),
        (Case 'App\Tests\FooTest' 'testSkip' 'skipped' 'class')))
    Invoke-Case 'Codeception class attribute and error element' @('-Baseline', (Join-Path $base 'junit'), '-Candidate', $codecept) 1 @(
        '[UNACCEPTED] newly-failing php-unit::App\Tests\FooTest::testOk (passed -> failed)') @()

    $allDiffs = @(
        '[UNACCEPTED] missing gone::G::only in baseline (passed -> absent)',
        '[UNACCEPTED] missing karma::A::goes missing (passed -> absent)',
        '[UNACCEPTED] added extra::E::only in candidate (absent -> passed)',
        '[UNACCEPTED] added karma::A::brand new (absent -> passed)',
        '[UNACCEPTED] newly-failing karma::A::dup (passed -> failed)',
        '[UNACCEPTED] newly-failing karma::A::name [with] brackets (passed -> failed)',
        '[UNACCEPTED] newly-failing karma::A::will error (passed -> failed)',
        '[UNACCEPTED] newly-failing karma::A::will fail (passed -> failed)',
        "[UNACCEPTED] newly-failing karma::A::$uni (passed -> failed)",
        '[UNACCEPTED] newly-passing karma::A::will pass (failed -> passed)',
        '[UNACCEPTED] status-changed karma::A::will skip (passed -> skipped)',
        '[UNACCEPTED] step-changed step::karma (exit 0 -> exit 1)',
        '[UNACCEPTED] step-changed step::new-step (absent -> exit 0)',
        'Suite gone: baseline 1 tests (1 passed, 0 failed, 0 skipped); candidate absent',
        'Suite extra: baseline absent; candidate 1 tests (1 passed, 0 failed, 0 skipped)',
        'Differences: 13 (13 unaccepted, 0 accepted)', 'Result: FAIL')
    Invoke-Case 'every difference category is reported and fails' @('-Baseline', $base, '-Candidate', $cand) 1 $allDiffs @('keeps passing', 'stays failed', 'testOk', 'step::build')

    $acc = Join-Path $tmp 'accepted.json'
    Write-File $acc @'
{
  "accepted": [
    { "category": "missing", "test": "*", "reason": "suites moved" },
    { "category": "added", "test": "*", "reason": "new tests" },
    { "category": "newly-failing", "test": "karma::A::name [with] brackets", "reason": "brackets are literal" },
    { "category": "newly-failing", "test": "karma::A::will ?ail", "reason": "single-char wildcard" },
    { "category": "newly-failing", "test": "karma::A::WILL ERROR", "reason": "case must not match" },
    { "category": "*", "test": "karma::A::dup", "reason": "duplicate numbering" },
    { "category": "newly-failing", "test": "karma::A::za*", "reason": "unicode name" },
    { "category": "step-changed", "test": "step::*", "reason": "steps differ" },
    { "category": "newly-passing", "test": "nothing::matches::this", "reason": "stale entry" }
  ]
}
'@
    Invoke-Case 'accepted file: wildcards, literal brackets, case sensitivity, unused entries' @('-Baseline', $base, '-Candidate', $cand, '-Accepted', $acc) 1 @(
        '[accepted] missing gone::G::only in baseline (passed -> absent) reason: suites moved',
        '[accepted] newly-failing karma::A::name [with] brackets (passed -> failed) reason: brackets are literal',
        '[accepted] newly-failing karma::A::will fail (passed -> failed) reason: single-char wildcard',
        '[UNACCEPTED] newly-failing karma::A::will error (passed -> failed)',
        '[accepted] newly-failing karma::A::dup (passed -> failed) reason: duplicate numbering',
        "[accepted] newly-failing karma::A::$uni (passed -> failed) reason: unicode name",
        '[UNACCEPTED] newly-passing karma::A::will pass (failed -> passed)',
        '[UNACCEPTED] status-changed karma::A::will skip (passed -> skipped)',
        '[accepted] step-changed step::karma (exit 0 -> exit 1) reason: steps differ',
        'Unused accepted entry: newly-failing karma::A::WILL ERROR',
        'Unused accepted entry: newly-passing nothing::matches::this',
        'Differences: 13 (3 unaccepted, 10 accepted)', 'Result: FAIL') @()

    $accAll = Join-Path $tmp 'accept-all.json'
    Write-File $accAll '{ "accepted": [ { "category": "*", "test": "*", "reason": "all" } ] }'
    $json = Join-Path $tmp 'report.json'
    Invoke-Case 'fully accepted differences pass and write a JSON report' @('-Baseline', $base, '-Candidate', $cand, '-Accepted', $accAll, '-JsonReport', $json) 0 @(
        'Differences: 13 (0 unaccepted, 13 accepted)', 'Result: PASS') @('[UNACCEPTED]')
    $problems = @()
    try {
        $rep = [IO.File]::ReadAllText($json, $utf8) | ConvertFrom-Json
        if ($rep.result -ne 'PASS' -or $rep.accepted -ne 13 -or $rep.unaccepted -ne 0) { $problems += 'bad totals' }
        if (@($rep.differences).Count -ne 13) { $problems += 'expected 13 differences' }
        if (-not (@($rep.differences | ForEach-Object { $_.test }) -ccontains "karma::A::$uni")) { $problems += 'unicode test id lost' }
        $k = @($rep.suites | Where-Object { $_.suite -eq 'karma' })[0]
        if ($k.baseline.tests -ne 11 -or $k.candidate.failed -ne 6) { $problems += 'bad suite counts' }
    } catch { $problems += "JSON report unreadable: $($_.Exception.Message)" }
    Report 'JSON report content (last implementation run)' $problems ''

    Invoke-Case 'missing candidate directory is an input error' @('-Baseline', $base, '-Candidate', (Join-Path $tmp 'nope')) 2 @() @('Result:')
    $bad = Join-Path $tmp 'bad'
    Write-File (Join-Path $bad 'junit/karma.xml') '<testsuites><testsuite>'
    Invoke-Case 'malformed XML is an input error' @('-Baseline', $base, '-Candidate', $bad) 2 @() @('Result:')
    $noReason = Join-Path $tmp 'no-reason.json'
    Write-File $noReason '{ "accepted": [ { "category": "added", "test": "*" } ] }'
    Invoke-Case 'accepted entry without reason is an input error' @('-Baseline', $base, '-Candidate', $cand, '-Accepted', $noReason) 2 @() @('Result:')
    $badCat = Join-Path $tmp 'bad-cat.json'
    Write-File $badCat '{ "accepted": [ { "category": "flaky", "test": "*", "reason": "x" } ] }'
    Invoke-Case 'unknown accepted category is an input error' @('-Baseline', $base, '-Candidate', $cand, '-Accepted', $badCat) 2 @() @('Result:')
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$impl = 'PowerShell only'
if ($null -ne $python) { $impl = 'PowerShell and Python' }
Write-Host ("{0} passed, {1} failed ({2}; PowerShell {3})" -f $script:passes, $script:failures, $impl, $PSVersionTable.PSVersion)
if ($script:failures -gt 0) { exit 1 }
exit 0
