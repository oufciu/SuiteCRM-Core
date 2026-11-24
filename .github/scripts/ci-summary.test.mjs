import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';

import {collectProblems} from './ci-gate.mjs';
import {
    formatDuration,
    isKnownTimezoneSpec,
    parseJUnit,
    parseKarma,
    readSteps,
    renderSummary,
    stripAnsi
} from './ci-summary.mjs';

const here = fileURLToPath(new URL('.', import.meta.url));
// Git Bash accepts drive-letter paths with forward slashes on Windows.
const stepScript = join(here, 'ci-step.sh').replaceAll('\\', '/');

test('parseKarma reads the final totals of a passing run', () => {
    const log = [
        'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 10 of 393 SUCCESS (0 secs / 2 secs)',
        '\u001b[1A\u001b[2KChrome Headless 158.0.0.0 (Linux x86_64): Executed 393 of 393 SUCCESS (1 min / 1 min)',
        'TOTAL: 393 SUCCESS'
    ].join('\n');

    assert.deepEqual(parseKarma(log), {
        executed: 393,
        total: 393,
        failed: 0,
        skipped: 0,
        passed: 393,
        error: false,
        failedSpecs: []
    });
});

test('parseKarma collects failed spec names without duplicates', () => {
    const log = [
        'Chrome Headless 158.0.0.0 (Linux x86_64) DateTimeEditFieldComponent should have formatted datetime value FAILED',
        '\tExpected ... to equal ...',
        'Chrome Headless 158.0.0.0 (Linux x86_64) DateTimeEditFieldComponent should have formatted datetime value FAILED',
        'Chrome Headless 158.0.0.0 (Linux x86_64) ListFilterComponent should have grid list FAILED',
        'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 393 of 393 (2 FAILED) (1 min / 1 min)',
        'TOTAL: 2 FAILED, 391 SUCCESS'
    ].join('\n');

    const result = parseKarma(log);
    assert.equal(result.failed, 2);
    assert.equal(result.passed, 391);
    assert.deepEqual(result.failedSpecs, [
        'DateTimeEditFieldComponent should have formatted datetime value',
        'ListFilterComponent should have grid list'
    ]);
});

test('parseKarma reports skipped specs and run errors', () => {
    const log = 'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 5 of 6 ERROR (skipped 1) (0.1 secs / 0.1 secs)';
    const result = parseKarma(log);
    assert.equal(result.skipped, 1);
    assert.equal(result.error, true);
});

test('parseKarma returns null when the log has no totals', () => {
    assert.equal(parseKarma('nothing useful here'), null);
});

test('stripAnsi removes carriage-return styling used by karma', () => {
    assert.equal(stripAnsi('\u001b[1A\u001b[2Kdone'), 'done');
});

test('parseJUnit prefers the root testsuites totals', () => {
    const xml = [
        '<?xml version="1.0"?>',
        '<testsuites tests="18" failures="2" errors="1" skipped="3">',
        '  <testsuite name="a" tests="9" failures="1" errors="0" skipped="1"/>',
        '  <testsuite name="b" tests="9" failures="1" errors="1" skipped="2"/>',
        '</testsuites>'
    ].join('\n');

    assert.deepEqual(parseJUnit(xml), {tests: 18, failures: 2, errors: 1, skipped: 3});
});

test('parseJUnit sums top-level suites and ignores nested ones', () => {
    const xml = [
        '<testsuite name="outer" tests="4" failures="1" errors="0" skipped="0">',
        '  <testsuite name="inner" tests="4" failures="1" errors="0" skipped="0"/>',
        '</testsuite>'
    ].join('\n');

    assert.deepEqual(parseJUnit(xml), {tests: 4, failures: 1, errors: 0, skipped: 0});
});

test('isKnownTimezoneSpec matches only the documented date and datetime field specs', () => {
    assert.equal(isKnownTimezoneSpec('DateTimeEditFieldComponent should have formatted datetime value'), true);
    assert.equal(isKnownTimezoneSpec('DatetimeDetailFieldComponent should create'), true);
    assert.equal(isKnownTimezoneSpec('DateFilterFieldComponent loads the date'), true);
    assert.equal(isKnownTimezoneSpec('ListFilterComponent should have grid list'), false);
    assert.equal(isKnownTimezoneSpec('RecordViewStore keeps the subscription alive'), false);
});

test('formatDuration prints seconds and minutes', () => {
    assert.equal(formatDuration(45), '45s');
    assert.equal(formatDuration(95), '1m 35s');
});

test('ci-step.sh records the exit code and keeps the command output', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-step-'));
    const steps = join(dir, 'steps.tsv');
    const log = join(dir, 'ok.log');

    execFileSync('bash', [stepScript, 'passing step', 'ok.log', '--', 'printf', 'hello\n'], {
        cwd: dir,
        env: {...process.env, CI_STEPS_FILE: 'steps.tsv'}
    });

    assert.equal(readFileSync(log, 'utf8'), 'hello\n');
    const [step] = readSteps(steps);
    assert.equal(step.label, 'passing step');
    assert.equal(step.rc, 0);
    assert.equal(step.log, 'ok.log');
    assert.equal(step.junit, '');
    assert.ok(Number.isInteger(step.seconds));
});

test('ci-step.sh propagates a failing exit code and still records it', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-step-'));
    const steps = join(dir, 'steps.tsv');
    let thrown = null;

    try {
        execFileSync('bash', [stepScript, 'failing step', 'bad.log', 'report.xml', '--', 'sh', '-c', 'echo boom; exit 3'], {
            cwd: dir,
            env: {...process.env, CI_STEPS_FILE: 'steps.tsv'}
        });
    } catch (error) {
        thrown = error;
    }

    assert.equal(thrown?.status, 3);
    const [step] = readSteps(steps);
    assert.equal(step.rc, 3);
    assert.equal(step.junit, 'report.xml');
});

test('renderSummary reports durations, JUnit counts and separates known timezone failures', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-summary-'));
    const karmaLog = join(dir, 'karma.log');
    const junit = join(dir, 'junit.xml');
    writeFileSync(karmaLog, [
        'Chrome Headless 158.0.0.0 (Linux x86_64) DateTimeEditFieldComponent should have formatted datetime value FAILED',
        'Chrome Headless 158.0.0.0 (Linux x86_64) ListFilterComponent should have grid list FAILED',
        'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 393 of 393 (2 FAILED) (1 min / 1 min)'
    ].join('\n'));
    writeFileSync(junit, '<testsuites tests="18" failures="0" errors="0" skipped="1"/>');

    const summary = renderSummary([
        {label: 'PHP unit suite', rc: 0, seconds: 95, log: join(dir, 'php.log'), junit},
        {label: 'Karma core', rc: 1, seconds: 30, log: karmaLog, junit: ''}
    ], 'CI results', {OS: 'ubuntu-latest', TZ: 'UTC'});

    assert.match(summary, /\*\*TZ:\*\* `UTC`/);
    assert.match(summary, /\| PHP unit suite \| pass \| 1m 35s \| 18 tests: 17 passed, 0 failed, 0 errors, 1 skipped \|/);
    assert.match(summary, /\| Karma core \| FAIL \(exit 1\) \| 30s \| 393 of 393 executed: 391 passed, 2 failed, 0 skipped \|/);
    assert.match(summary, /\*\*Total recorded\*\* \| \| 2m 5s/);
    assert.match(summary, /known timezone failures \(gap G7, not skipped\):\*\*\n- DateTimeEditFieldComponent should have formatted datetime value/);
    assert.match(summary, /other failures:\*\*\n- ListFilterComponent should have grid list/);
});

test('renderSummary notes a missing JUnit report instead of claiming a pass', () => {
    const summary = renderSummary([
        {label: 'PHP unit suite', rc: 2, seconds: 5, log: '', junit: join(tmpdir(), 'does-not-exist.xml')}
    ], 'CI results');

    assert.match(summary, /no JUnit report written/);
});

test('readSteps returns nothing when no step ran', () => {
    assert.deepEqual(readSteps(join(tmpdir(), 'missing-steps.tsv')), []);
});

test('collectProblems fails on a non-zero exit code', () => {
    assert.deepEqual(
        collectProblems([{label: 'yarn install --immutable', rc: 1, seconds: 3, log: '', junit: ''}]),
        ['yarn install --immutable: exit 1']
    );
});

test('collectProblems fails a Karma step that reported failures despite exiting zero', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-gate-'));
    const log = join(dir, 'karma.log');
    writeFileSync(log, 'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 393 of 393 (8 FAILED) (1 min / 1 min)');

    assert.deepEqual(
        collectProblems([{label: 'Karma core', rc: 0, seconds: 80, log, junit: ''}]),
        ['Karma core: Karma reports 8 failed of 393']
    );
});

test('collectProblems fails a Karma step that ended in a run ERROR', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-gate-'));
    const log = join(dir, 'karma.log');
    writeFileSync(log, 'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 5 of 6 ERROR (skipped 1) (0.1 secs / 0.1 secs)');

    assert.match(collectProblems([{label: 'Karma shell', rc: 0, seconds: 9, log, junit: ''}])[0], /run ERROR/);
});

test('collectProblems fails when a recorded JUnit report is missing or red', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-gate-'));
    const red = join(dir, 'red.xml');
    writeFileSync(red, '<testsuites tests="18" failures="2" errors="0" skipped="0"/>');

    assert.deepEqual(collectProblems([
        {label: 'Codeception unit suite', rc: 0, seconds: 10, log: '', junit: join(dir, 'missing.xml')},
        {label: 'Migration unit tests', rc: 0, seconds: 10, log: '', junit: red}
    ]), [
        `Codeception unit suite: no JUnit report at ${join(dir, 'missing.xml')}`,
        'Migration unit tests: JUnit reports 2 failures and 0 errors'
    ]);
});

test('collectProblems accepts a clean run and rejects an empty one', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-gate-'));
    const log = join(dir, 'karma.log');
    const junit = join(dir, 'green.xml');
    writeFileSync(log, 'Chrome Headless 158.0.0.0 (Linux x86_64): Executed 393 of 393 SUCCESS (1 min / 1 min)');
    writeFileSync(junit, '<testsuites tests="7" failures="0" errors="0" skipped="1"/>');

    assert.deepEqual(collectProblems([
        {label: 'Karma core', rc: 0, seconds: 80, log, junit: ''},
        {label: 'Migration unit tests', rc: 0, seconds: 10, log: '', junit}
    ]), []);
    assert.deepEqual(collectProblems([]), ['no steps were recorded']);
});

test('gate rejects empty JUnit and incomplete or missing Karma results', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-gate-'));
    const junit = join(dir, 'empty.xml');
    const log = join(dir, 'partial.log');
    writeFileSync(junit, 'not a report');
    writeFileSync(log, 'Chrome Headless 158 (Linux): Executed 3 of 6 SUCCESS');
    assert.deepEqual(collectProblems([
        {label: 'PHP', rc: 0, junit},
        {label: 'Karma core', rc: 0, log},
        {label: 'Karma shell', rc: 0, log: join(dir, 'missing.log')}
    ]), [
        'PHP: JUnit reports no tests',
        'Karma core: no complete Karma result',
        `Karma shell: no log at ${join(dir, 'missing.log')}`
    ]);
});

test('summary marks report failures red even if the command exits zero', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-summary-'));
    const log = join(dir, 'karma.log');
    writeFileSync(log, 'Chrome Headless 158 (Linux): Executed 6 of 6 (1 FAILED)');
    assert.match(renderSummary([{label: 'Karma shell', rc: 0, seconds: 1, log}], 'CI'),
        /\| Karma shell \| FAIL \(report\)/);
});

test('timezone helper exports and records UTC', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-timezone-'));
    const script = join(here, 'ci-timezone.sh').replaceAll('\\', '/');
    execFileSync('bash', [script, 'UTC', 'timezone.txt'], {
        cwd: dir,
        env: {...process.env, RUNNER_OS: 'Linux', TZ: 'America/New_York', GITHUB_ENV: 'env.txt', GITHUB_OUTPUT: 'output.txt'}
    });
    assert.match(readFileSync(join(dir, 'timezone.txt'), 'utf8'), /TZ=UTC/);
    assert.equal(readFileSync(join(dir, 'env.txt'), 'utf8'), 'TZ=UTC\n');
    assert.equal(readFileSync(join(dir, 'output.txt'), 'utf8'), 'timezone=UTC\n');
});

test('timezone helper sets the Windows system zone as well as TZ', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ci-timezone-'));
    const script = join(here, 'ci-timezone.sh').replaceAll('\\', '/');
    execFileSync('bash', ['-c', 'tzutil() { printf "%s\\n" "$*" >> calls.txt; }; export -f tzutil; bash "$@"',
        'test', script, 'UTC', 'timezone.txt'], {
        cwd: dir,
        env: {...process.env, RUNNER_OS: 'Windows', GITHUB_ENV: 'env.txt', GITHUB_OUTPUT: 'output.txt'}
    });
    assert.equal(readFileSync(join(dir, 'calls.txt'), 'utf8'), '//s UTC\n//g\n');
});
