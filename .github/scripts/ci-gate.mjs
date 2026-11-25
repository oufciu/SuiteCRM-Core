#!/usr/bin/env node
// Fail the job when any recorded step failed, so collecting every step's output
// never turns a red run green. A zero exit code is not trusted on its own: a
// recorded Karma log that reports failures, or a JUnit report that is missing or
// reports failures, also fails the job.
//
// Usage: ci-gate.mjs <steps file>
import {existsSync, readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

import {parseJUnit, parseKarma, readSteps} from './ci-summary.mjs';

export function collectProblems(steps) {
    if (!steps.length) {
        return ['no steps were recorded'];
    }

    const problems = [];
    for (const step of steps) {
        if (step.rc !== 0) {
            problems.push(`${step.label}: exit ${step.rc}`);
        }

        if (step.junit) {
            if (!existsSync(step.junit)) {
                problems.push(`${step.label}: no JUnit report at ${step.junit}`);
            } else {
                const report = parseJUnit(readFileSync(step.junit, 'utf8'));
                if (!report.tests) {
                    problems.push(`${step.label}: JUnit reports no tests`);
                } else if (report.failures || report.errors) {
                    problems.push(`${step.label}: JUnit reports ${report.failures} failures and ${report.errors} errors`);
                }
            }
            continue;
        }

        if (step.log && !existsSync(step.log)) {
            problems.push(`${step.label}: no log at ${step.log}`);
        } else if (step.log) {
            const karma = parseKarma(readFileSync(step.log, 'utf8'));
            if (/^Karma\b/.test(step.label) && (!karma || !karma.executed || karma.executed + karma.skipped !== karma.total)) {
                problems.push(`${step.label}: no complete Karma result`);
            }
            if (karma && (karma.failed || karma.error)) {
                problems.push(`${step.label}: Karma reports ${karma.failed} failed of ${karma.total}${karma.error ? ' and a run ERROR' : ''}`);
            }
        }
    }
    return problems;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    const stepsFile = process.argv[2] ?? 'ci-results/steps.tsv';
    const problems = collectProblems(readSteps(stepsFile));

    if (problems.length) {
        console.error('Failed steps:');
        for (const problem of problems) {
            console.error(`  ${problem}`);
        }
        process.exit(1);
    }

    console.log('All recorded steps passed.');
}
