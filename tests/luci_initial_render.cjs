const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const dir = 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/';

async function checkInitialRender() {
  let calls = 0;
  const scheduled = [];
  const pending = new Promise(() => {});
  const methods = new Proxy({}, { get: () => () => { calls++; return pending; } });
  const tab = new Proxy({}, { get: () => () => {} });
  const map = {
    section: () => ({}),
    render: async () => 'rendered grid',
  };
  const context = vm.createContext({
    main: { FORKOP_UCI_PACKAGE: 'forkop', injectGlobalStyles() {},
      ForkopShellMethods: methods, coreService() {} },
    form: { Map: function () { return map; } },
    ui: { changes: { forkopHoldoffConfigured: true } },
    uci: {}, view: { extend: value => value },
    window: { setTimeout: fn => scheduled.push(fn) },
    section: tab, settings: tab, dashboard: tab, monitoring: tab,
    diagnostic: tab, updates: tab, tailscale: tab,
    _: value => value, console,
  });
  const entry = vm.runInContext(`(function () { ${fs.readFileSync(dir + 'forkop.js', 'utf8')} })()`, context);
  const rendered = await Promise.race([
    entry.render(),
    new Promise((_, reject) => setTimeout(() => reject(Error('initial render waited for RPC')), 200)),
  ]);
  assert.equal(rendered, 'rendered grid');
  assert.equal(calls, 0, 'no capability probe before rendering');
  scheduled[0]();
  assert.equal(calls, 1, 'capability probe starts in background');
}

function checkDownloadChoices() {
  const source = fs.readFileSync(dir + 'settings.js', 'utf8');
  const start = source.indexOf('function isDownloadSectionAction(');
  const end = source.indexOf('function configureDownloadViaProxyFlag(');
  const listeners = {};
  let value = 'edited-selection', choices;
  const widget = { clearChoices() {}, addChoices(keys) { choices = [...keys]; } };
  const sections = {
    proxy: { '.type': 'section', action: 'connection' },
    tunnel: { '.type': 'section', action: 'vpn' },
    direct: { '.type': 'section', action: 'bypass' },
  };
  const option = {
    map: { data: { state: { values: { forkop: sections } } } },
    value(key, label) { this.keylist.push(key); this.vallist.push(label); },
    renderWidget: () => ({ addEventListener: (event, fn) => { listeners[event] = fn; } }),
    getUIElement: () => widget,
  };
  const context = vm.createContext({ UCI_PACKAGE: 'forkop', uci: { get: () => value }, _: v => v });
  vm.runInContext(source.slice(start, end), context);
  context.configureDownloadSectionOption(option, 'download_section');
  assert.equal(option.load('settings'), value);
  assert.deepEqual([...option.keylist], ['proxy', 'tunnel'], 'only outbound-capable sections are offered');
  option.renderWidget('settings');
  sections.tunnel.enabled = '0';
  listeners.mousedown();
  assert.deepEqual(choices, ['proxy']);
  assert.equal(option.cfgvalue('settings'), 'edited-selection', 'refresh does not rewrite selection');
}

(async () => {
  await checkInitialRender();
  checkDownloadChoices();
  console.log('Initial rendering with stalled RPC and live download choices: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
