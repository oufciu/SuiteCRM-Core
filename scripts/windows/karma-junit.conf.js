// Wraps a project karma.conf.js: single headless run plus a dependency-free JUnit reporter.
const fs = require('fs');
const path = require('path');

function esc(s) {
  return String(s).replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function JUnitGoldenReporter(baseReporterDecorator, config) {
  baseReporterDecorator(this);
  const out = process.env.GOLDEN_JUNIT_OUT;
  const suiteName = process.env.GOLDEN_SUITE_NAME || 'karma';
  const results = [];
  let browserErrors = [];
  this.onSpecComplete = (browser, r) => {
    results.push({
      classname: r.suite.join(' '),
      name: r.description,
      time: (r.time || 0) / 1000,
      status: r.skipped || r.pending ? 'skipped' : (r.success ? 'passed' : 'failed'),
      log: (r.log || []).join('\n'),
      browser: browser.name,
    });
  };
  this.onBrowserError = (browser, error) => { browserErrors.push(String(error && error.message || error)); };
  this.onRunComplete = () => {
    const failures = results.filter(r => r.status === 'failed').length;
    const skipped = results.filter(r => r.status === 'skipped').length;
    const total = results.reduce((a, r) => a + r.time, 0);
    const lines = ['<?xml version="1.0" encoding="UTF-8"?>',
      `<testsuites name="${esc(suiteName)}" tests="${results.length}" failures="${failures}" errors="${browserErrors.length}" skipped="${skipped}" time="${total.toFixed(3)}">`,
      `  <testsuite name="${esc(suiteName)}" tests="${results.length}" failures="${failures}" errors="${browserErrors.length}" skipped="${skipped}" time="${total.toFixed(3)}">`];
    for (const r of results) {
      lines.push(`    <testcase classname="${esc(r.classname)}" name="${esc(r.name)}" time="${r.time.toFixed(3)}">`);
      if (r.status === 'failed') lines.push(`      <failure message="failed">${esc(r.log)}</failure>`);
      if (r.status === 'skipped') lines.push('      <skipped/>');
      lines.push('    </testcase>');
    }
    for (const e of browserErrors) lines.push(`    <system-err>${esc(e)}</system-err>`);
    lines.push('  </testsuite>', '</testsuites>', '');
    if (out) { fs.mkdirSync(path.dirname(out), {recursive: true}); fs.writeFileSync(out, lines.join('\n')); }
  };
}
JUnitGoldenReporter.$inject = ['baseReporterDecorator', 'config'];

module.exports = function (config) {
  require(path.resolve(process.env.GOLDEN_KARMA_BASE))(config);
  config.set({
    plugins: [...config.plugins, {'reporter:junitgolden': ['type', JUnitGoldenReporter]}],
    customLaunchers: {
      ChromeHeadlessGolden: {base: 'ChromeHeadless', flags: ['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage']},
    },
    browsers: ['ChromeHeadlessGolden'],
    reporters: ['progress', 'junitgolden'],
    singleRun: true,
    autoWatch: false,
    restartOnFileChange: false,
    browserNoActivityTimeout: 300000,
    browserDisconnectTimeout: 60000,
    captureTimeout: 300000,
  });
};
