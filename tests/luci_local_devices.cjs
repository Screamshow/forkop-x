const assert = require("node:assert/strict");
const fs = require("node:fs");
const net = require("node:net");
const vm = require("node:vm");

function loadDevicePicker(assetDir, { firewallAvailable = true, malformed = false, failFirstDump = false } = {}) {
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
    interfaces[1]["ipv6-prefix-assignment"].unshift(null);
  }
  let dumpCalls = 0;
  const source = fs.readFileSync(
    `luci-app-forkop/${assetDir}/luci-static/resources/view/forkop/local_devices.js`,
    "utf8",
  );

  return vm.runInNewContext(`(function () { ${source}\n})()`, {
    baseclass: { extend: (entry) => entry },
    rpc: { declare: ({ method }) => async () => {
      if (method === "dump" && ++dumpCalls === 1 && failFirstDump)
        return {};
      return { getHostHints: hints, getDHCPLeases: leases, dump: interfaces }[method];
    } },
    uci: {
      async load() {
        if (!firewallAvailable) throw new Error("Firewall configuration unavailable");
      },
      sections: () => zones,
    },
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
        this.values = Array.from(values);
        this.choices = { ...choices };
        this.validate = options.validate;
      }
      render() { return this; }
      addEventListener() {}
    } },
  });
}

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
  assert.deepEqual(widget.choices, expected);
  assert.deepEqual(widget.values, saved);
  assert.equal(widget.validate("10.25.0.10"), true);

  const malformed = loadDevicePicker(assetDir, { malformed: true });
  const mixedValues = ["192.168.90.204", "192.168.91.30/32", "fd00:91::30"];
  const main = await malformed.createLocalDeviceDynamicListWidget(option, "main", mixedValues);
  assert.deepEqual(main.values, mixedValues);
  assert.deepEqual(main.choices, {
    "192.168.91.30": "Guest phone",
    "fd00:91::30": "Phone",
  });

  const retry = loadDevicePicker(assetDir, { failFirstDump: true });
  const fallback = await retry.createLocalDeviceDynamicListWidget(option, "main", saved);
  assert.deepEqual(fallback.values, saved);
  assert.deepEqual(fallback.choices, {});
  assert.deepEqual({ ...await retry.loadLocalDeviceChoices() }, expected);
}

Promise.all(["htdocs", "generated"].map(checkPicker)).catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
