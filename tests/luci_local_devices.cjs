const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const vm = require("node:vm");

function loadDevicePicker(assetDir, { firewallAvailable = true, malformed = false, responses = {} } = {}) {
  const addresses = (address, mask) => [{ address, mask }];
  const interfaces = [
    { interface: "lan", up: true, "ipv4-address": addresses("192.168.90.1", 24) },
    {
      interface: "guest",
      up: true,
      "ipv4-address": addresses("192.168.91.1", 25),
      "ipv6-prefix-assignment": [{ "local-address": { address: "fd00:91::1", mask: 64 } }],
    },
    { interface: "wan", up: true, "ipv4-address": addresses("46.138.245.242", 20) },
    { interface: "wanb", up: true, "ipv4-address": addresses("10.10.0.2", 24) },
    {
      interface: "uplink", up: true, "ipv4-address": addresses("10.11.0.2", 24),
      route: [{ target: "0.0.0.0", mask: 0 }],
    },
  ];
  const hints = {
    lan: { name: "PC.lan", ipaddrs: ["192.168.90.204"] },
    guest: { name: "Phone.lan", ipaddrs: ["192.168.91.30"], ip6addrs: ["fd00:91::30"] },
    wan: { name: "mail.svk.su", ipaddrs: ["46.138.240.1", "46.138.250.50"] },
    wanb: { name: "Backup gateway", ipaddrs: ["10.10.0.1"] },
    uplink: { name: "Upstream gateway", ipaddrs: ["10.11.0.1"] },
    router: { name: "Router", ipaddrs: ["192.168.90.1"], ip6addrs: ["fd00:91:0:0::1"] },
  };
  const leases = { dhcp_leases: [
    { ipaddr: "192.168.91.30", hostname: "Guest phone" },
    { ipaddr: "192.168.91.150", hostname: "Outside guest subnet" },
  ] };
  const zones = [
    { name: "lan", network: ["lan", "uplink"] },
    { name: "guest", network: ["guest"] },
    { name: "wan", network: ["wan", "wanb"], masq: "1" },
  ];
  if (malformed) {
    interfaces[0].route = {};
    interfaces[1]["ipv4-address"].unshift(null, {});
    interfaces[1]["ipv4-address"].push({ address: "192.0.2.1", mask: { toString: null } });
    interfaces[1]["ipv6-prefix-assignment"].unshift(null);
    interfaces.push(null, {
      interface: "broken",
      up: true,
      "ipv4-address": { address: "192.0.2.1", mask: 24 },
      "ipv6-address": false,
      "ipv6-prefix-assignment": {},
    }, {
      interface: "guest",
      up: true,
      "ipv4-address": {},
      "ipv6-prefix-assignment": [{ "local-address": { address: "fd00:92::1", mask: 64 } }],
    });
    zones.push(null);
    hints.broken = { name: { toString: null }, ipaddrs: [{ toString: null }, "192.168.91.20"] };
  }
  const calls = {};
  const defaults = {
    getHostHints: hints,
    getDHCPLeases: leases,
    dump: { interface: interfaces },
    get: { values: { ...zones } },
  };
  const source = fs.readFileSync(
    `luci-app-forkop/${assetDir}/luci-static/resources/view/forkop/local_devices.js`,
    "utf8",
  );

  const picker = vm.runInNewContext(`(function () { ${source}\n})()`, {
    document: { createTextNode: textContent => ({ textContent }) },
    baseclass: { extend: (entry) => entry },
    rpc: { declare: ({ method, expect }) => async (...args) => {
      const count = calls[method] = (calls[method] || 0) + 1;
      if (method === "get") {
        assert.deepEqual(args, ["firewall", "zone"]);
        if (!firewallAvailable) throw new Error("Firewall configuration unavailable");
      }
      const result = responses[method]
        ? await responses[method](count, defaults[method])
        : defaults[method];
      return expect?.interface ? result?.interface || [] : result;
    } },
    validation: {
      parseIPv4: (ip) => ip.match(/^[\d.]+$/) && net.isIPv4(ip) ? ip.split(".").map(Number) : null,
      parseIPv6(ip) {
        if (!net.isIPv6(ip)) return null;
        const [head, tail] = ip.split("::").map((part) => part ? part.split(":") : []);
        const words = tail ? [...head, ...Array(8 - head.length - tail.length).fill("0"), ...tail] : head;
        return words.map((word) => Number.parseInt(word, 16));
      },
    },
    main: { validateIP: (ip) => ({ valid: Boolean(net.isIP(ip)) }) },
    ui: { DynamicList: class {
      constructor(values, choices, options) {
        this.selected = Array.from(values, value => ({
          value,
          parentElement: { firstElementChild: { textContent: choices[value] || value } },
        }));
        this.choices = choices;
        this.suggestions = { ...choices };
        this.validate = options.validate;
        this.events = {};
      }
      render() { return this; }
      querySelectorAll() { return this.selected; }
      addEventListener(type, handler) { this.events[type] = handler; }
      interact(type, key) { this.events[type]({ target: { closest: () => true }, key }); }
      getValue() { return this.selected.map(({ value }) => value); }
      get labels() { return this.selected.map(input => input.parentElement.firstElementChild.textContent); }
      clearChoices() { this.suggestions = {}; }
      addChoices(values, labels) {
        for (const value of values) this.suggestions[value] = labels[value].textContent;
      }
    } },
  });
  return { ...picker, calls };
}

const drain = () => new Promise(resolve => setImmediate(resolve));

async function checkPicker(assetDir) {
  const picker = loadDevicePicker(assetDir);
  const expected = {
    "192.168.90.204": "PC",
    "192.168.91.30": "Guest phone",
    "fd00:91::30": "Phone",
  };
  assert.deepEqual({ ...await picker.loadLocalDeviceChoices() }, expected);
  assert.deepEqual({ ...await loadDevicePicker(assetDir, { firewallAvailable: false }).loadLocalDeviceChoices() }, {});

  const option = {
    cbid: () => "device-filter",
    map: {},
    validate: (_section, ip) => Boolean(net.isIP(ip)),
  };
  const saved = ["46.138.250.50", "192.168.90.204"];
  const widget = await picker.createLocalDeviceDynamicListWidget(option, "section", saved);
  assert.deepEqual(widget.suggestions, expected);
  assert.deepEqual(widget.getValue(), saved);
  assert.equal(widget.validate("10.25.0.10"), true);

  const malformed = loadDevicePicker(assetDir, { malformed: true });
  const mixedValues = ["192.168.90.204", "192.168.91.30/32", "fd00:91::30"];
  const main = await malformed.createLocalDeviceDynamicListWidget(option, "main", mixedValues);
  await drain();
  assert.deepEqual(main.getValue(), mixedValues);
  assert.deepEqual(main.suggestions, {
    "192.168.91.30": "Guest phone",
    "fd00:91::30": "Phone",
  });

  for (const firstDump of [{ interface: [] }, { interface: {} }, null]) {
    const retry = loadDevicePicker(assetDir, {
      responses: { dump: (count, good) => count === 1 ? firstDump : good },
    });
    const fallback = await retry.createLocalDeviceDynamicListWidget(option, "main", saved);
    await drain();
    assert.deepEqual(fallback.getValue(), saved);
    assert.deepEqual(fallback.suggestions, {});
    fallback.interact("keydown", "ArrowDown");
    await drain();
    assert.deepEqual(fallback.suggestions, expected);
    assert.equal(retry.calls.dump, 2);
  }

  const recovery = loadDevicePicker(assetDir, {
    responses: {
      getHostHints(count, good) {
        if (count === 1) throw new Error("Temporary failure");
        return good;
      },
      getDHCPLeases: (count, good) => count === 2 ? {} : good,
    },
  });
  assert.deepEqual({ ...await recovery.loadLocalDeviceChoices() }, { "192.168.91.30": "Guest phone" });
  assert.deepEqual({ ...await recovery.loadLocalDeviceChoices() }, { ...expected, "192.168.91.30": "Phone" });
  assert.deepEqual({ ...await recovery.loadLocalDeviceChoices() }, expected);
  assert.deepEqual({ ...await recovery.loadLocalDeviceChoices() }, expected);
  assert.equal(recovery.calls.dump, 3, "cache only a successful non-empty result");

  const firewallRecovery = loadDevicePicker(assetDir, {
    responses: {
      get(count, good) {
        if (count === 1) throw new Error("Temporary firewall failure");
        return good;
      },
    },
  });
  assert.deepEqual({ ...await firewallRecovery.loadLocalDeviceChoices() }, {});
  assert.deepEqual({ ...await firewallRecovery.loadLocalDeviceChoices() }, expected);
  assert.equal(firewallRecovery.calls.get, 2);

  let finishDump;
  const stalled = loadDevicePicker(assetDir, {
    responses: { dump: (_count, good) => new Promise(resolve => { finishDump = () => resolve(good); }) },
  });
  let changes = 0;
  const editable = stalled.createLocalDeviceDynamicListWidget({
    ...option,
    onDeviceListChange: () => changes++,
  }, "main", mixedValues);
  assert.equal(typeof editable?.then, "undefined", "saved IPs render without waiting for RPC");
  assert.deepEqual(editable.labels, mixedValues);
  const cidrs = stalled.createLocalDeviceDynamicListWidget(option, "other", ["192.168.90.204/32"]);
  cidrs.interact("pointerdown");
  editable.interact("focusin");
  await drain();
  assert.equal(stalled.calls.dump, 1, "concurrent widgets share a single lookup");
  const [removed, ...remaining] = editable.selected;
  editable.selected = [...remaining, { value: "192.168.91.30", parentElement: { firstElementChild: { textContent: "192.168.91.30" } } }];
  const liveValues = editable.getValue();
  finishDump();
  await drain();
  assert.deepEqual(editable.getValue(), liveValues);
  assert.deepEqual(editable.labels, ["192.168.91.30/32", "Phone", "Guest phone"]);
  assert.equal(removed.parentElement.firstElementChild.textContent, mixedValues[0]);
  assert.deepEqual(cidrs.suggestions, expected);
  assert.equal(changes, 0);

  const lazy = loadDevicePicker(assetDir);
  const empty = lazy.createLocalDeviceDynamicListWidget(option, "empty", []);
  lazy.createLocalDeviceDynamicListWidget(option, "cidr", ["192.168.90.204/32", "fd00:91::/64"]);
  await drain();
  assert.equal(lazy.calls.dump, undefined, "CIDRs and empty lists stay lazy");
  empty.interact("focusin");
  await drain();
  assert.deepEqual(empty.suggestions, expected);
}

Promise.all(["htdocs", "generated"].map(checkPicker)).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
