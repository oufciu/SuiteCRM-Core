#!/usr/bin/env node
// Render a GitHub job summary from the steps recorded by ci-step.sh.
// Usage: node ci-summary.mjs <steps.tsv> <title> [key=value ...]
import {existsSync, readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

// Specs that failed on native Windows outside UTC; their fix or TZ policy is gap G7.
const KNOWN_TIMEZONE_SPEC = /^(Date|DateTime|Datetime)(Detail|Edit|Filter)FieldComponent\b/;

export function stripAnsi(text) {
    return text.replace(/\u001b\[[0-9;?]*[A-Za-z]/g, '');
}

export function parseKarma(text) {
    const clean = stripAnsi(text);
    const executedLines = [...clean.matchAll(/Executed (\d+) of (\d+)(.*)$/gm)];
    if (!executedLines.length) {
        return null;
    }
    const [, executed, total, rest] = executedLines[executedLines.length - 1];
    const failed = Number((rest.match(/\((\d+) FAILED\)/) ?? [])[1] ?? 0);
    const skipped = Number((rest.match(/\(skipped (\d+)\)/) ?? [])[1] ?? 0);
    const error = /\bERROR\b/.test(rest);

    const failedSpecs = new Set();
    for (const [, spec] of clean.matchAll(/^\s*(?:Chrome Headless|HeadlessChrome)[^()\n]*\([^)\n]*\) (.+) FAILED\s*$/gm)) {
        failedSpecs.add(spec.trim());
    }

    return {
        executed: Number(executed),
        total: Number(total),
        failed,
        skipped,
        passed: Number(executed) - failed,
        error,
        failedSpecs: [...failedSpecs]
    };
}

export function parseJUnit(xml) {
    const totals = {tests: 0, failures: 0, errors: 0, skipped: 0};
    let depth = 0;
    let rootTotals = null;
    let rootIsSuites = false;
    for (const [, closing, tag, attrs, selfClosing] of xml.matchAll(/<(\/?)(testsuites|testsuite)\b([^>]*?)(\/?)>/g)) {
        if (closing) {
            depth--;
            continue;
        }
        const values = {};
        for (const key of Object.keys(totals)) {
            const match = attrs.match(new RegExp(`\\b${key}="(\\d+)"`));
            if (match) {
                values[key] = Number(match[1]);
            }
        }
        if (tag === 'testsuites' && depth === 0) {
            rootIsSuites = true;
            if ('tests' in values) {
                rootTotals = {...totals, ...values};
            }
        }
        // Count only the outermost suites; nested suites repeat their parents' totals.
        const topLevelSuite = tag === 'testsuite' && (depth === 0 || (depth === 1 && rootIsSuites));
        if (topLevelSuite) {
            for (const key of Object.keys(totals)) {
                totals[key] += values[key] ?? 0;
            }
        }
        if (!selfClosing) {
            depth++;
        }
    }
    return rootTotals ?? totals;
}

export function formatDuration(seconds) {
    const value = Number(seconds);
    if (value < 60) {
        return `${value}s`;
    }
    return `${Math.floor(value / 60)}m ${value % 60}s`;
}

export function isKnownTimezoneSpec(spec) {
    return KNOWN_TIMEZONE_SPEC.test(spec);
}

export function readSteps(stepsFile) {
    if (!existsSync(stepsFile)) {
        return [];
    }
    return readFileSync(stepsFile, 'utf8').split(/\r?\n/).filter(Boolean).map(line => {
        const [label, rc, seconds, log, junit] = line.split('\t');
        return {label, rc: Number(rc), seconds: Number(seconds), log, junit: junit || ''};
    });
}

function describeResults(step) {
    if (step.junit) {
        if (!existsSync(step.junit)) {
            return {text: 'no JUnit report written', failed: true};
        }
        const r = parseJUnit(readFileSync(step.junit, 'utf8'));
        const passed = r.tests - r.failures - r.errors - r.skipped;
        return {text: `${r.tests} tests: ${passed} passed, ${r.failures} failed, ${r.errors} errors, ${r.skipped} skipped`, failed: !r.tests || r.failures > 0 || r.errors > 0};
    }
    if (step.log && existsSync(step.log)) {
        const karma = parseKarma(readFileSync(step.log, 'utf8'));
        if (karma) {
            const known = karma.failedSpecs.filter(isKnownTimezoneSpec);
            const other = karma.failedSpecs.filter(spec => !isKnownTimezoneSpec(spec));
            return {
                text: `${karma.executed} of ${karma.total} executed: ${karma.passed} passed, ${karma.failed} failed, ${karma.skipped} skipped${karma.error ? ', run ERROR' : ''}`,
                known,
                other,
                failed: karma.failed > 0 || karma.error || !karma.executed || karma.executed + karma.skipped !== karma.total
            };
        }
    }
    return {text: /^Karma\b/.test(step.label) ? 'no complete Karma result' : '', failed: /^Karma\b/.test(step.label)};
}

export function renderSummary(steps, title, meta = {}) {
    const lines = [`## ${title}`, ''];
    const metaEntries = Object.entries(meta);
    if (metaEntries.length) {
        lines.push(metaEntries.map(([key, value]) => `**${key}:** \`${value}\``).join(' · '), '');
    }
    lines.push('| Step | Result | Duration | Tests |', '|---|---|---|---|');
    const notes = [];
    let totalSeconds = 0;
    for (const step of steps) {
        totalSeconds += step.seconds;
        const results = describeResults(step);
        const status = step.rc !== 0 ? `FAIL (exit ${step.rc})` : results.failed ? 'FAIL (report)' : 'pass';
        lines.push(`| ${step.label} | ${status} | ${formatDuration(step.seconds)} | ${results.text} |`);
        if (results.known?.length) {
            notes.push(`**${step.label}: known timezone failures (gap G7, not skipped):**`, ...results.known.map(spec => `- ${spec}`), '');
        }
        if (results.other?.length) {
            notes.push(`**${step.label}: other failures:**`, ...results.other.map(spec => `- ${spec}`), '');
        }
    }
    lines.push(`| **Total recorded** | | ${formatDuration(totalSeconds)} | |`, '');
    return [...lines, ...notes].join('\n');
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    const [stepsFile, title = 'CI results', ...pairs] = process.argv.slice(2);
    const meta = Object.fromEntries(pairs.map(pair => {
        const index = pair.indexOf('=');
        return [pair.slice(0, index), pair.slice(index + 1)];
    }));
    process.stdout.write(renderSummary(readSteps(stepsFile), title, meta) + '\n');
}
