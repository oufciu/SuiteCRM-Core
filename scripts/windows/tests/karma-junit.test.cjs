const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');

function reporter(t) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'suitecrm-junit-'));
  t.after(() => fs.rmSync(folder, {recursive: true}));
  process.env.SUITECRM_JUNIT_PATH = path.join(folder, 'junit.xml');
  process.env.SUITECRM_KARMA_PROJECT = 'core';
  const load = Module._load;
  Module._load = function (name, ...rest) {
    if (name.replace(/\\/g, '/').endsWith('/core/app/core/karma.conf.js')) return config => config.set({plugins: []});
    return load.call(this, name, ...rest);
  };
  const config = {set(values) { Object.assign(this, values); }};
  try { require('../karma-junit.cjs')(config); }
  finally { Module._load = load; }
  const plugin = config.plugins.find(p => typeof p === 'object')['reporter:packaging-junit'][1];
  return new plugin();
}

test('JUnit retains individual passing, failing and skipped specifications', t => {
  const r = reporter(t);
  r.onSpecComplete({}, {suite: ['a&b'], description: '<pass>', success: true, time: 10});
  r.onSpecComplete({}, {suite: [], description: '"fail"', success: false, log: ['<error>']});
  r.onSpecComplete({}, {suite: [], description: 'skip', skipped: true});
  r.onRunComplete([], {});
  const xml = fs.readFileSync(process.env.SUITECRM_JUNIT_PATH, 'utf8');
  assert.match(xml, /tests="3" failures="1"/);
  assert.match(xml, /a&amp;b/);
  assert.match(xml, /&lt;error&gt;/);
  assert.match(xml, /<skipped\/>/);
});

test('browser failure without specifications is not a green empty suite', t => {
  const r = reporter(t);
  r.onRunComplete([], {error: true});
  assert.match(fs.readFileSync(process.env.SUITECRM_JUNIT_PATH, 'utf8'), /tests="1" failures="1"/);
});
