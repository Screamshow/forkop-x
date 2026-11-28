const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const dir = 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/';

function loadLuciEntry(assetDir, name, context) {
  const source = fs.readFileSync(assetDir + name + '.js', 'utf8');
  return vm.runInContext(`(function () { ${source}\n})()`, context);
}

async function checkInitialRender(assetDir, { saved, supported, readonly = false }) {
  let calls = 0;
  let resolveCapabilities;
  let coreOptions;
  let bitTorrent;
  const writes = [];
  const scheduled = [];
  const pending = new Promise(resolve => { resolveCapabilities = resolve; });
  const probe = () => { calls++; return pending; };
  const tab = new Proxy({}, { get: () => () => {} });
  const map = {
    readonly,
    section: () => ({
      option(_type, name) {
        const option = {
          map,
          value() {},
          depends() {},
          cfgvalue: () => saved,
          load: () => saved,
          write(_id, value) { writes.push(value); },
          remove() { writes.push(null); },
          renderWidget(_id, _index, value) {
            return { value: value ?? this.default, readonly: this.readonly };
          },
        };
        if (name === 'bittorrent_direct') bitTorrent = option;
        return option;
      },
    }),
    async render() {
      const value = await bitTorrent.load('settings');
      return bitTorrent.renderWidget('settings', 0, value);
    },
  };
  const context = vm.createContext({
    main: { FORKOP_UCI_PACKAGE: 'forkop', translateForkop: value => value, injectGlobalStyles() {},
      DNS_SERVER_OPTIONS: {}, BOOTSTRAP_DNS_SERVER_OPTIONS: {}, getClashUIUrl: () => '',
      ForkopShellMethods: { getUiCapabilities: probe }, coreService: options => { coreOptions = options; } },
    fs: { exec: probe },
    form: { Map: function () { return map; } },
    ui: { changes: { forkopHoldoffConfigured: true } },
    uci: {}, view: { extend: value => value }, baseclass: { extend: value => value },
    widgets: {}, E: (_tag, _attrs, text) => ({ text, replaceChildren(...children) { this.children = children; } }),
    window: { setTimeout: fn => scheduled.push(fn) },
    section: tab, dashboard: tab, monitoring: tab, whatsapp: tab,
    diagnostic: tab, updates: tab, tailscale: tab,
    console,
  });
  context.settings = loadLuciEntry(assetDir, 'settings', context);
  const entry = loadLuciEntry(assetDir, 'forkop', context);
  let timeout;
  const widget = await Promise.race([
    entry.render(),
    new Promise((_, reject) => { timeout = setTimeout(() => reject(Error('initial render waited for RPC')), 200); }),
  ]).finally(() => clearTimeout(timeout));
  assert.equal(calls, 0, 'no capability probe before rendering');
  assert.deepEqual(widget.children[0], { value: saved ?? '0', readonly: true });
  scheduled[0]();
  const capabilities = coreOptions.waitForLogWatcherStart();
  assert.equal(calls, 1, 'capability probe starts in background');
  bitTorrent.write('settings', '0');
  bitTorrent.remove('settings');
  assert.deepEqual(writes, [], 'saving during capability detection preserves UCI');

  resolveCapabilities({ success: true, data: { xrust_tailscale: 1, xrust_bittorrent_direct: supported ? 1 : 0 } });
  assert.equal((await capabilities).xrustTailscale, true);
  assert.deepEqual(widget.children[0], { value: saved ?? (supported ? '1' : '0'), readonly: !supported || readonly });
  bitTorrent.write('settings', '0');
  assert.deepEqual(writes, supported && !readonly ? ['0'] : []);
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

async function checkTailscaleStatusOrder(assetDir) {
  const requests = [];
  const updates = [];
  const watchers = [];
  const option = {};
  function element(tag, attrs = {}, children = []) {
    if (!Array.isArray(children)) children = [children];
    return {
      tag, attrs, children, style: {}, isConnected: true,
      textContent: typeof children[0] === 'string' ? children[0] : '',
      addEventListener(name, handler) { this[name] = handler; },
      setAttribute(name, value) { this.attrs[name] = String(value); },
      replaceChildren(...items) { this.children = items; },
      appendChild(child) { this.children.push(child); },
    };
  }
  const context = vm.createContext({
    main: { translateForkop: value => value, isReadOnlyForkopView: () => false,
      pollLuciTab: (_root, callback) => { watchers.push(callback); void callback(); } },
    baseclass: { extend: value => value },
    form: {},
    ui: { addNotification: (_title, content) => updates.push(content.textContent) },
    E: element,
    fs: {
      exec: (_command, [operation]) => new Promise((resolve, reject) => {
        requests.push({ operation, reject, respond: (data) =>
          resolve({ code: 0, stdout: JSON.stringify({ available: true, ...data }) }) });
      }),
    },
  });
  const module = loadLuciEntry(assetDir, 'tailscale', context);
  module.createTailscaleContent({ option: () => option });
  const root = option.cfgvalue();
  const find = (node, check) => node?.tag && (check(node) ? node :
    node.children.map(child => find(child, check)).find(Boolean));
  const currentState = find(root, node => node.attrs.role === 'status').children[1];
  const disconnect = find(root, node => node.tag === 'button' && node.textContent === 'Disconnect');
  const drain = () => new Promise(resolve => setImmediate(resolve));
  const respond = (operation, state) => {
    const request = requests.shift();
    assert.equal(request?.operation, 'tailscale_native_' + operation);
    request.respond({ state });
  };

  respond('status', 'connected');
  await drain();
  assert.equal(currentState.textContent, 'Router is connected to Tailscale');
  const staleSuccess = watchers[0]();
  const staleError = watchers[0]();
  const action = disconnect.click();
  const pendingSuccess = requests.shift();
  const pendingFailure = requests.shift();
  respond('disconnect', 'disconnected');
  await drain();
  assert.equal(currentState.textContent, 'Tailscale is disconnected');
  assert.equal(requests.length, 1, 'refresh immediately after an action');
  pendingSuccess.respond({ state: 'connected' });
  pendingFailure.reject(new Error('late status failure'));
  await Promise.all([staleSuccess, staleError]);
  assert.equal(currentState.textContent, 'Tailscale is disconnected');
  respond('status', 'disconnected');
  await action;
  assert.equal(currentState.textContent, 'Tailscale is disconnected');
  assert.deepEqual(updates, []);
}

function checkRussianCatalog() {
  const catalog = fs.readFileSync('luci-app-forkop/po/ru/forkop.po', 'utf8');
  const source = fs.readFileSync('fe-app-forkop/locales/forkop.ru.po', 'utf8');
  assert.equal(catalog, source, 'the source and packaged locale catalogs must agree');
  const entries = new Map([...catalog.matchAll(/^msgid (".*")\r?\nmsgstr (".*")$/gm)]
    .map(match => match.slice(1).map(JSON.parse)));
  for (const key of [
    'Route detected BitTorrent directly',
    'Incompatible subscription nodes were skipped',
    'Closed Connections',
    'Failed to select server',
    'Previous page',
    'Next page',
    'Required connection is unavailable',
    'Rejected by the selected core',
    'Settings saved. Refreshing the page…',
    'The generated Xrust configuration is invalid. Previous configuration recovery was requested. Correct the settings and apply them again; see the system log for details.',
  ]) {
    assert.ok(entries.get(key), 'Missing Russian translation: ' + key);
  }
}

function checkEditorScroll() {
  const source = fs.readFileSync(dir + 'section.js', 'utf8');
  const from = source.indexOf('function syncAnnotatedTextareaOverlay(');
  const to = source.indexOf('function parseCommentAwareListTokens(');
  const handlers = {};
  const overlay = { style: {}, setAttribute() {} };
  const parentNode = { classList: { add() {} }, style: {}, insertBefore() {} };
  const textarea = {
    parentNode, value: 'example.com\n'.repeat(10000),
    scrollTop: 0, scrollLeft: 0,
    addEventListener(event, fn) { handlers[event] = fn; },
  };
  let analysisRuns = 0, styleReads = 0, onResize;
  const context = vm.createContext({
    document: { createElement: () => overlay },
    window: { getComputedStyle: () => { styleReads++; return {}; } },
    ResizeObserver: class {
      constructor(fn) { onResize = fn; }
      observe() {}
    },
    ensureAnnotatedTextareaStyles() {}, escapeHtml: value => value,
  });
  vm.runInContext(source.slice(from, to), context);
  context.attachAnnotatedTextarea(textarea, value => {
    analysisRuns++;
    assert.ok(value.length >= 120000);
    return { annotations: [] };
  });
  for (let i = 1; i <= 80; i++) {
    textarea.scrollTop = i * 100;
    textarea.scrollLeft = i * 2;
    handlers.scroll();
  }
  assert.equal(analysisRuns, 1, 'scroll never reparses the editor');
  assert.equal(styleReads, 1, 'scroll never asks for layout styles');
  assert.equal(overlay.scrollTop, textarea.scrollTop);
  assert.equal(overlay.scrollLeft, textarea.scrollLeft);
  onResize();
  assert.equal(analysisRuns, 1, 'layout-only resize reuses the parsed overlay');
  textarea.value += 'updated.example';
  handlers.input();
  handlers.change();
  assert.equal(analysisRuns, 2, 'input parses once, change reuses the result');
}

(async () => {
  for (const assetDir of [dir, dir.replace('/htdocs/', '/generated/')]) {
    await checkInitialRender(assetDir, { supported: true });
    await checkInitialRender(assetDir, { saved: '0', supported: true });
    await checkInitialRender(assetDir, { saved: '1', supported: false });
    await checkInitialRender(assetDir, { supported: true, readonly: true });
    await checkTailscaleStatusOrder(assetDir);
  }
  checkDownloadChoices();
  checkEditorScroll();
  checkRussianCatalog();
  console.log('Initial rendering with stalled RPC, BitTorrent Direct and live download choices: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
