<#
.SYNOPSIS
Compares a test run's JUnit/Karma XML results with the Linux golden baseline.

.DESCRIPTION
Each *.xml file is one suite, named by its file name without the extension. Both
directories may hold the XML files directly or in a junit\ subdirectory. A test
is identified as "<suite>::<classname>::<name>". Repeated identities get " #2",
" #3" and so on, ordered by status (failed, passed, skipped), so the numbering
does not depend on the random order in which Jasmine runs specs. A testcase containing <failure> or <error>
is failed, one containing <skipped> is skipped, any other is passed.

When both run directories contain steps.tsv (step, exit_code, seconds, command),
step exit codes are compared as "step::<name>" with category step-changed.

Categories: missing, added, newly-failing, newly-passing, status-changed,
step-changed. Every difference not matched by the accepted-differences file
makes the comparison fail.

The accepted-differences file is UTF-8 JSON:
  { "accepted": [ { "category": "newly-failing",
                    "test": "karma-core::DateTimeEditFieldComponent::*",
                    "reason": "Known TZ-dependent spec" } ] }
"category" is a category name or "*". "test" is a case-sensitive pattern over the
whole identity where * matches any text and ? matches one character; every
other character is literal. "reason" is required.

Exit codes: 0 no unaccepted differences, 1 unaccepted differences, 2 bad input.
Compatible with Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\compare-parity.ps1 -Baseline C:\golden\UTC -Candidate C:\runs\UTC -Accepted scripts\windows\parity-accepted.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Baseline,
    [Parameter(Mandatory = $true)][string]$Candidate,
    [string]$Accepted,
    [string]$JsonReport
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Exit code 1 means "differences found", so any unexpected failure must not surface as 1.
trap {
    [Console]::Error.WriteLine("compare-parity: $($_.Exception.Message)")
    exit 2
}

$StatusOrder = @('failed', 'passed', 'skipped')
$CategoryOrder = @('missing', 'added', 'newly-failing', 'newly-passing', 'status-changed', 'step-changed')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-RunRoot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Not a directory: $Path" }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Get-JUnitDir([string]$Root) {
    $j = Join-Path $Root 'junit'
    if (Test-Path -LiteralPath $j -PathType Container) { return $j }
    return $Root
}

function Read-Suites([string]$Dir) {
    $suites = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter '*.xml' | Where-Object { -not $_.PSIsContainer })) {
        $suite = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $doc = New-Object System.Xml.XmlDocument
        try { $doc.Load($f.FullName) } catch { throw "Cannot parse $($f.FullName): $($_.Exception.Message)" }
        $groups = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($tc in @($doc.SelectNodes('//testcase'))) {
            $cls = $tc.GetAttribute('classname')
            if ([string]::IsNullOrEmpty($cls)) { $cls = $tc.GetAttribute('class') }
            $id = $suite + '::' + $cls + '::' + $tc.GetAttribute('name')
            $status = 'passed'
            if ($null -ne $tc.SelectSingleNode('failure|error')) { $status = 'failed' }
            elseif ($null -ne $tc.SelectSingleNode('skipped')) { $status = 'skipped' }
            $time = 0.0
            [void][double]::TryParse($tc.GetAttribute('time'), [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$time)
            if (-not $groups.ContainsKey($id)) { $groups[$id] = New-Object System.Collections.ArrayList }
            [void]$groups[$id].Add((New-Object PSObject -Property @{ Status = $status; Time = $time }))
        }
        # Jasmine runs specs in random order, so same-named specs are numbered by status, not by position.
        $tests = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        foreach ($id in $groups.Keys) {
            $members = @($groups[$id] | Sort-Object -Property @{ Expression = { [array]::IndexOf($StatusOrder, $_.Status) } }, Time)
            for ($k = 0; $k -lt $members.Count; $k++) {
                $key = $id
                if ($k -gt 0) { $key = "$id #$($k + 1)" }
                $tests[$key] = $members[$k]
            }
        }
        $suites[$suite] = $tests
    }
    return $suites
}

function Read-Steps([string]$Root) {
    $p = Join-Path $Root 'steps.tsv'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $steps = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $lines = [IO.File]::ReadAllLines($p, $Utf8NoBom)
    for ($i = 1; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Trim() -eq '') { continue }
        $cols = $lines[$i].Split("`t")
        if ($cols.Length -lt 2) { throw "Bad steps.tsv line $($i + 1) in ${p}" }
        $steps[$cols[0]] = $cols[1]
    }
    return $steps
}

function Convert-PatternToRegex([string]$Pattern) {
    $r = [regex]::Escape($Pattern).Replace('\*', '.*').Replace('\?', '.')
    return '^' + $r + '$'
}

function Read-Accepted([string]$Path) {
    $list = @()
    if ([string]::IsNullOrEmpty($Path)) { return , $list }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Accepted-differences file not found: $Path" }
    try { $json = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, $Utf8NoBom) | ConvertFrom-Json }
    catch { throw "Cannot parse accepted-differences file ${Path}: $($_.Exception.Message)" }
    if ($null -eq $json -or -not ($json.PSObject.Properties.Name -contains 'accepted')) { throw "Accepted-differences file has no 'accepted' array: $Path" }
    $i = 0
    foreach ($e in @($json.accepted)) {
        $i++
        foreach ($field in @('category', 'test', 'reason')) {
            if (-not ($e.PSObject.Properties.Name -contains $field) -or [string]::IsNullOrEmpty([string]$e.$field)) {
                throw "Accepted entry $i is missing '$field'"
            }
        }
        if ($e.category -ne '*' -and $CategoryOrder -notcontains $e.category) { throw "Accepted entry $i has unknown category '$($e.category)'" }
        $list += New-Object PSObject -Property @{
            Category = [string]$e.category; Test = [string]$e.test; Reason = [string]$e.reason
            Regex = Convert-PatternToRegex ([string]$e.test); Used = 0
        }
    }
    return , $list
}

function Get-Counts($Tests) {
    $c = @{ passed = 0; failed = 0; skipped = 0 }
    $t = 0.0
    if ($null -ne $Tests) { foreach ($v in $Tests.Values) { $c[$v.Status]++; $t += $v.Time } }
    $total = 0
    if ($null -ne $Tests) { $total = $Tests.Count }
    return New-Object PSObject -Property @{ Tests = $total; Passed = $c.passed; Failed = $c.failed; Skipped = $c.skipped; Time = $t }
}

function Format-Counts($c) {
    if ($null -eq $c) { return 'absent' }
    return ('{0} tests ({1} passed, {2} failed, {3} skipped)' -f $c.Tests, $c.Passed, $c.Failed, $c.Skipped)
}

function Get-SortedUnique([string[]]$Items) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($i in $Items) { [void]$set.Add($i) }
    $a = New-Object string[] $set.Count
    $set.CopyTo($a)
    [Array]::Sort($a, [StringComparer]::Ordinal)
    return , $a
}

try {
    $baseRoot = Get-RunRoot $Baseline
    $candRoot = Get-RunRoot $Candidate
    $baseSuites = Read-Suites (Get-JUnitDir $baseRoot)
    $candSuites = Read-Suites (Get-JUnitDir $candRoot)
    $acceptList = Read-Accepted $Accepted
    $baseSteps = Read-Steps $baseRoot
    $candSteps = Read-Steps $candRoot
} catch {
    [Console]::Error.WriteLine("compare-parity: $($_.Exception.Message)")
    exit 2
}

$diffs = New-Object System.Collections.ArrayList
function Add-Diff([string]$Category, [string]$Id, [string]$From, [string]$To) {
    [void]$diffs.Add((New-Object PSObject -Property @{ Category = $Category; Test = $Id; Baseline = $From; Candidate = $To; Accepted = $false; Reason = '' }))
}

$suiteNames = Get-SortedUnique (@($baseSuites.Keys) + @($candSuites.Keys))
$suiteSummary = @()
foreach ($s in $suiteNames) {
    $b = $null; $c = $null
    if ($baseSuites.ContainsKey($s)) { $b = $baseSuites[$s] }
    if ($candSuites.ContainsKey($s)) { $c = $candSuites[$s] }
    $bc = $null; $cc = $null
    if ($null -ne $b) { $bc = Get-Counts $b }
    if ($null -ne $c) { $cc = Get-Counts $c }
    $suiteSummary += New-Object PSObject -Property @{ Suite = $s; Baseline = $bc; Candidate = $cc }
    $ids = @()
    if ($null -ne $b) { $ids += @($b.Keys) }
    if ($null -ne $c) { $ids += @($c.Keys) }
    foreach ($id in (Get-SortedUnique $ids)) {
        $bs = $null; $cs = $null
        if ($null -ne $b -and $b.ContainsKey($id)) { $bs = $b[$id].Status }
        if ($null -ne $c -and $c.ContainsKey($id)) { $cs = $c[$id].Status }
        if ($null -eq $cs) { Add-Diff 'missing' $id $bs 'absent'; continue }
        if ($null -eq $bs) { Add-Diff 'added' $id 'absent' $cs; continue }
        if ($bs -eq $cs) { continue }
        if ($cs -eq 'failed') { Add-Diff 'newly-failing' $id $bs $cs }
        elseif ($bs -eq 'failed' -and $cs -eq 'passed') { Add-Diff 'newly-passing' $id $bs $cs }
        else { Add-Diff 'status-changed' $id $bs $cs }
    }
}

if ($null -ne $baseSteps -and $null -ne $candSteps) {
    foreach ($st in (Get-SortedUnique (@($baseSteps.Keys) + @($candSteps.Keys)))) {
        $bv = 'absent'; $cv = 'absent'
        if ($baseSteps.ContainsKey($st)) { $bv = 'exit ' + $baseSteps[$st] }
        if ($candSteps.ContainsKey($st)) { $cv = 'exit ' + $candSteps[$st] }
        if ($bv -ne $cv) { Add-Diff 'step-changed' ('step::' + $st) $bv $cv }
    }
}

foreach ($d in $diffs) {
    foreach ($a in $acceptList) {
        if (($a.Category -eq '*' -or $a.Category -eq $d.Category) -and [regex]::IsMatch($d.Test, $a.Regex)) {
            $d.Accepted = $true; $d.Reason = $a.Reason; $a.Used++
            break
        }
    }
}

# Diffs are generated in ordinal id order per source; regroup by category so output is stable across platforms.
$final = New-Object System.Collections.ArrayList
foreach ($cat in $CategoryOrder) {
    foreach ($d in $diffs) { if ($d.Category -eq $cat) { [void]$final.Add($d) } }
}
$unaccepted = @($final | Where-Object { -not $_.Accepted }).Count
$acceptedCount = $final.Count - $unaccepted
$stale = @($acceptList | Where-Object { $_.Used -eq 0 })

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine('Parity report')
[void]$out.AppendLine("Baseline:  $baseRoot")
[void]$out.AppendLine("Candidate: $candRoot")
foreach ($s in $suiteSummary) {
    [void]$out.AppendLine(('Suite {0}: baseline {1}; candidate {2}' -f $s.Suite, (Format-Counts $s.Baseline), (Format-Counts $s.Candidate)))
}
[void]$out.AppendLine(('Differences: {0} ({1} unaccepted, {2} accepted)' -f $final.Count, $unaccepted, $acceptedCount))
foreach ($d in $final) {
    $tag = '[UNACCEPTED]'
    if ($d.Accepted) { $tag = '[accepted]' }
    $line = '{0} {1} {2} ({3} -> {4})' -f $tag, $d.Category, $d.Test, $d.Baseline, $d.Candidate
    if ($d.Accepted) { $line += ' reason: ' + $d.Reason }
    [void]$out.AppendLine($line)
}
foreach ($a in $stale) {
    [void]$out.AppendLine(('Unused accepted entry: {0} {1}' -f $a.Category, $a.Test))
}
$result = 'PASS'
if ($unaccepted -gt 0) { $result = 'FAIL' }
[void]$out.AppendLine("Result: $result")
$text = $out.ToString().Replace("`r`n", "`n")
if ([Console]::IsOutputRedirected) {
    # Redirected output is always UTF-8 so non-ASCII test names survive the console code page.
    $bytes = $Utf8NoBom.GetBytes($text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
} else {
    [Console]::Out.Write($text)
}

if (-not [string]::IsNullOrEmpty($JsonReport)) {
    $report = [ordered]@{
        baseline = $baseRoot; candidate = $candRoot; result = $result
        unaccepted = $unaccepted; accepted = $acceptedCount
        suites = @($suiteSummary | ForEach-Object {
                [ordered]@{ suite = $_.Suite
                    baseline = $(if ($null -ne $_.Baseline) { [ordered]@{ tests = $_.Baseline.Tests; passed = $_.Baseline.Passed; failed = $_.Baseline.Failed; skipped = $_.Baseline.Skipped } } else { $null })
                    candidate = $(if ($null -ne $_.Candidate) { [ordered]@{ tests = $_.Candidate.Tests; passed = $_.Candidate.Passed; failed = $_.Candidate.Failed; skipped = $_.Candidate.Skipped } } else { $null })
                } })
        differences = @($final | ForEach-Object { [ordered]@{ category = $_.Category; test = $_.Test; baseline = $_.Baseline; candidate = $_.Candidate; accepted = $_.Accepted; reason = $_.Reason } })
        unusedAccepted = @($stale | ForEach-Object { [ordered]@{ category = $_.Category; test = $_.Test } })
    }
    $jsonPath = $JsonReport
    if (-not [IO.Path]::IsPathRooted($jsonPath)) { $jsonPath = Join-Path (Get-Location).ProviderPath $jsonPath }
    [IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject $report -Depth 6), $Utf8NoBom)
}

if ($unaccepted -gt 0) { exit 1 }
exit 0
