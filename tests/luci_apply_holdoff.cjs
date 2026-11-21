const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js', 'utf8');
const helper = source.slice(source.indexOf('function configureForkopApplyHoldoff()'), source.indexOf('\n}', source.indexOf('function configureForkopApplyHoldoff()')) + 2);
const native = fs.readFileSync(process.argv[2], 'utf8');
const confirm = native.slice(native.indexOf('confirm(checked,deadline,override_token){'), native.indexOf(',apply(checked){', native.indexOf('confirm(checked,deadline,override_token){')));
assert.ok(confirm.length > 100, 'VM native LuCI confirm found');

(async () => {
  let pending, failure, scheduled = [], calls = [], throwConfirm = false;
  const env = { apply_holdoff: 4, apply_display: 1.5, apply_timeout: 5 };
  const changes = {
    displayStatus() {},
    apply(...args) { calls.push(args); },
  };
  const context = vm.createContext({
    document: { addEventListener() {}, dispatchEvent() {} },
    ui: { changes }, uci: { changes: () => failure ? Promise.reject(Error('RPC')) : Promise.resolve(pending) },
    main: { FORKOP_UCI_PACKAGE: 'forkop' }, L: { env },
    UI: { prototype: { changes } }, E() {}, _: value => ({format() { return value; }}),
    window: { setTimeout(fn, delay) { scheduled.push(delay); }, clearTimeout() {} },
  });
  const nativeConfirm = vm.runInContext(`({${confirm}}).confirm`, context);
  changes.confirm = function (...args) {
    if (throwConfirm) throw Error('confirm failure');
    return nativeConfirm.apply(this, args);
  };
  vm.runInContext(helper + '\nconfigureForkopApplyHoldoff(); configureForkopApplyHoldoff();', context);
  for (const [name, value, expected] of [
    ['Forkop only', {forkop: [['set']]}, 0],
    ['mixed', {forkop: [['set']], network: [['set']]}, 4000],
    ['other only', {network: [['set']]}, 4000],
    ['empty', {}, 4000],
    ['malformed mixed', {forkop: [['set']], network: {}}, 4000],
    ['RPC failure', null, 4000],
  ]) {
    pending = value; failure = value === null; scheduled = [];
    await changes.apply(true);
    changes.confirm(true, Date.now() + 90000, 'token');
    assert.equal(scheduled.at(-1), expected, name);
    assert.equal(env.apply_holdoff, 4, 'shared holdoff restored');
    assert.equal(calls.at(-1)[0], true, 'checked apply preserved');
    console.log(`${name}: first confirmation scheduled after ${expected} ms`);
  }
  failure = false; pending = {forkop: [['set']]};
  await changes.apply(false); throwConfirm = true;
  assert.throws(() => changes.confirm(false, Date.now() + 90000));
  assert.equal(env.apply_holdoff, 4);
  throwConfirm = false; scheduled = [];
  changes.confirm(false, Date.now() + 90000);
  assert.equal(scheduled.at(-1), 4000, 'one-use flag cleared after failure');
  console.log('Exception recovery, unchecked forwarding and idempotent installation: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
