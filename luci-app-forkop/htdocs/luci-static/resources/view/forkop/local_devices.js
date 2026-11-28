"use strict";
"require baseclass";
"require rpc";
"require ui";
"require uci";
"require validation";
"require view.forkop.main as main";

const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  expect: { "": {} },
});
const callDHCPLeases = rpc.declare({
  object: "luci-rpc",
  method: "getDHCPLeases",
  expect: { "": {} },
});
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});

let localDeviceChoicesCache = null;
let localDeviceChoicesPromise = null;

function normalizeOptionValues(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeLocalDeviceName(name) {
  return `${name || ""}`.trim().replace(/\.lan$/i, "");
}

function addLocalDeviceChoice(choices, localNetworks, routerIps, ip, name) {
  const normalizedIp = `${ip || ""}`.trim();
  const normalizedName = normalizeLocalDeviceName(name);

  if (!normalizedIp || !normalizedName) {
    return;
  }

  if (!main.validateIP(normalizedIp).valid) {
    return;
  }

  const words = parseAddress(normalizedIp);
  if (
    words &&
    !routerIps.has(words.join(":")) &&
    localNetworks.some((network) => matchesPrefix(words, network))
  ) {
    choices[normalizedIp] = normalizedName;
  }
}

function parseAddress(ip) {
  if (typeof ip !== "string") return null;
  return validation.parseIPv4(ip) || validation.parseIPv6(ip);
}

function matchesPrefix(words, { address, mask }) {
  if (words.length !== address.length) return false;
  const wordBits = words.length === 4 ? 8 : 16;
  return words.every((word, index) => {
    const bits = Math.min(wordBits, mask - index * wordBits);
    return bits <= 0 || (word ^ address[index]) >> (wordBits - bits) === 0;
  });
}

function buildLocalNetworks(networkInterfaces, zones) {
  const local = new Set();
  const uplinks = new Set();
  for (const zone of zones) {
    const networks =
      zone.name === "wan" || zone.masq === "1" || zone.masq6 === "1"
        ? uplinks
        : local;
    normalizeOptionValues(zone.network).forEach((name) => networks.add(name));
  }

  const routerIps = new Set();
  const localNetworks = [];
  for (const net of networkInterfaces) {
    const isLocal =
      net.up &&
      local.has(net.interface) &&
      !uplinks.has(net.interface) &&
      (net.route == null ||
        (Array.isArray(net.route) &&
          !net.route.some(
            (route) =>
              !route ||
              typeof route !== "object" ||
              (Number(route.mask) === 0 &&
                (route.target === "0.0.0.0" || route.target === "::")),
          )));
    const addresses = [
      ...(net["ipv4-address"] || []),
      ...(net["ipv6-address"] || []),
      ...(net["ipv6-prefix-assignment"] || [])
        .map((prefix) => prefix?.["local-address"])
        .filter(Boolean),
    ];
    for (const entry of addresses) {
      const address = parseAddress(entry?.address);
      if (!address) continue;
      routerIps.add(address.join(":"));
      const mask = Number(entry.mask);
      const maxMask = address.length === 4 ? 32 : 128;
      if (isLocal && Number.isInteger(mask) && mask > 0 && mask <= maxMask) {
        localNetworks.push({ address, mask });
      }
    }
  }
  return { localNetworks, routerIps };
}

function buildLocalDeviceChoices(
  hostHints,
  dhcpLeases,
  networkInterfaces,
  zones,
) {
  const choices = {};
  const { localNetworks, routerIps } = buildLocalNetworks(
    networkInterfaces,
    zones,
  );

  if (hostHints && typeof hostHints === "object") {
    Object.values(hostHints).forEach((hint) => {
      if (!hint || typeof hint !== "object") {
        return;
      }

      [
        ...normalizeOptionValues(hint.ipaddrs),
        ...normalizeOptionValues(hint.ipv4),
        ...normalizeOptionValues(hint.ip6addrs),
        ...normalizeOptionValues(hint.ipv6),
      ].forEach((ip) => {
        addLocalDeviceChoice(choices, localNetworks, routerIps, ip, hint.name);
      });
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      if (!lease || typeof lease !== "object") {
        return;
      }

      addLocalDeviceChoice(
        choices,
        localNetworks,
        routerIps,
        lease.ipaddr,
        lease.hostname,
      );
    });
  }

  return choices;
}

function loadLocalDeviceChoices() {
  if (localDeviceChoicesCache) {
    return Promise.resolve(localDeviceChoicesCache);
  }

  if (localDeviceChoicesPromise) {
    return localDeviceChoicesPromise;
  }

  localDeviceChoicesPromise = Promise.resolve()
    .then(() =>
      Promise.all([
        callHostHints().catch(() => ({})),
        callDHCPLeases().catch(() => ({})),
        callNetworkInterfaceDump(),
        uci.load("firewall").then(() => uci.sections("firewall", "zone")),
      ]),
    )
    .then(([hostHints, dhcpLeases, networkInterfaces, zones]) => {
      localDeviceChoicesCache = buildLocalDeviceChoices(
        hostHints,
        dhcpLeases,
        networkInterfaces,
        zones,
      );
      return localDeviceChoicesCache;
    })
    // Keep saved values editable and allow a retry when suggestions fail.
    .catch(() => ({}))
    .finally(() => {
      localDeviceChoicesPromise = null;
    });

  return localDeviceChoicesPromise;
}

function sortLocalDeviceChoiceValues(choices) {
  return Object.keys(choices).sort((a, b) => {
    const byName = `${choices[a]}`.localeCompare(`${choices[b]}`);
    return byName || a.localeCompare(b);
  });
}

function hasSingleIpValue(values) {
  return normalizeOptionValues(values).some(
    (value) => main.validateIP(value).valid,
  );
}

function preloadLocalDeviceChoicesForValues(values) {
  return hasSingleIpValue(values)
    ? loadLocalDeviceChoices()
    : Promise.resolve(null);
}

function createLocalDeviceDynamicListWidget(option, section_id, cfgvalue) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );
  const shouldResolveExistingLabels = hasSingleIpValue(values);

  return (
    shouldResolveExistingLabels ? loadLocalDeviceChoices() : Promise.resolve({})
  ).then((initialChoices) => {
    const choices = localDeviceChoicesCache || initialChoices || {};
    const widget = new ui.DynamicList(values, choices, {
      id: option.cbid(section_id),
      sort: sortLocalDeviceChoiceValues(choices),
      optional: option.optional || option.rmempty,
      datatype: option.datatype,
      placeholder: option.placeholder,
      validate: option.validate.bind(option, section_id),
      disabled: option.readonly != null ? option.readonly : option.map.readonly,
    });
    const node = widget.render();
    if (typeof option.onDeviceWidgetReady === "function") {
      option.onDeviceWidgetReady(section_id, widget);
    }
    if (typeof option.onDeviceListChange === "function") {
      node.addEventListener("cbi-dynlist-change", () => {
        option.onDeviceListChange(section_id, widget.getValue());
      });
    }
    let choicesLoaded = Boolean(localDeviceChoicesCache);
    let choicesLoading = false;

    const loadChoices = () => {
      if (choicesLoaded || choicesLoading) {
        return;
      }

      choicesLoading = true;
      loadLocalDeviceChoices()
        .then((loadedChoices) => {
          widget.clearChoices();
          widget.addChoices(
            sortLocalDeviceChoiceValues(loadedChoices),
            loadedChoices,
          );
          choicesLoaded = Boolean(localDeviceChoicesCache);
        })
        .finally(() => {
          choicesLoading = false;
        });
    };

    const maybeLoadChoices = (ev) => {
      if (
        ev.target &&
        typeof ev.target.closest === "function" &&
        ev.target.closest(".cbi-dropdown")
      ) {
        loadChoices();
      }
    };

    node.addEventListener("mousedown", maybeLoadChoices, true);
    node.addEventListener("focusin", maybeLoadChoices, true);

    return node;
  });
}

const EntryPoint = {
  createLocalDeviceDynamicListWidget,
  hasSingleIpValue,
  loadLocalDeviceChoices,
  normalizeOptionValues,
  preloadLocalDeviceChoicesForValues,
};

return baseclass.extend(EntryPoint);
