const fs = require('node:fs');
const path = require('node:path');

const escape = value => String(value ?? '').replace(/[<>&"']/g, c =>
  ({'<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;'}[c]));

function JUnitReporter() {
  const cases = [];
  this.onSpecComplete = (browser, result) => {
    const failure = result.success || result.skipped ? '' :
      `<failure message="Jasmine failure">${escape((result.log || []).join('\n'))}</failure>`;
    cases.push({
      failed: !!failure,
      xml: `<testcase classname="${escape((result.suite || []).join('.'))}" name="${escape(result.description)}" time="${(result.time || 0) / 1000}">${result.skipped ? '<skipped/>' : failure}</testcase>`
    });
  };
  this.onRunComplete = (browsers, result) => {
    if (result.error || result.disconnected || !cases.length) {
      cases.push({failed: true, xml: '<testcase name="browser-run"><failure message="Browser error, disconnect or no tests"/></testcase>'});
    }
    const output = process.env.SUITECRM_JUNIT_PATH;
    fs.mkdirSync(path.dirname(output), {recursive: true});
    fs.writeFileSync(output, `<?xml version="1.0" encoding="UTF-8"?><testsuite name="frontend-${escape(process.env.SUITECRM_KARMA_PROJECT)}" tests="${cases.length}" failures="${cases.filter(c => c.failed).length}">${cases.map(c => c.xml).join('')}</testsuite>`);
  };
}
JUnitReporter.$inject = [];

module.exports = config => {
  const project = process.env.SUITECRM_KARMA_PROJECT;
  if (!['core', 'shell'].includes(project)) throw new Error('Unknown Karma project');
  require(path.resolve(__dirname, `../../core/app/${project}/karma.conf.js`))(config);
  config.set({
    plugins: [...config.plugins, {'reporter:packaging-junit': ['type', JUnitReporter]}],
    reporters: ['progress', 'packaging-junit'],
    customLaunchers: {PackagingHeadless: {base: 'ChromeHeadless', flags: ['--remote-debugging-port=0']}},
    singleRun: true,
    autoWatch: false,
    colors: false,
  });
};
