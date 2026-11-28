"use strict";
"require baseclass";
"require rpc";
"require ui";
"require validation";
"require view.forkop.main as main";

const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  reject: true,
});
const callDHCPLeases = rpc.declare({
  object: "luci-rpc",
  method: "getDHCPLeases",
  reject: true,
});
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  reject: true,
});
// LuCI's shared UCI cache retains failed loads for the lifetime of the page.
const callFirewallZones = rpc.declare({
  object: "uci",
  method: "get",
  params: ["config", "type"],
  reject: true,
});

let localDeviceChoicesCache = null;
let localDeviceChoicesPromise = null;

function normalizeOptionValues(value) {
  const values = typeof value === "string" ? value.split(/\s+/) : asArray(value);
  return values
    .filter((item) => typeof item === "string")
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeLocalDeviceName(name) {
  return typeof name === "string" ? name.trim().replace(/\.lan$/i, "") : "";
}

function addLocalDeviceChoice(choices, localNetworks, routerIps, ip, name) {
  const normalizedIp = typeof ip === "string" ? ip.trim() : "";
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

function parsePrefixLength(mask) {
  return typeof mask === "string" && /^\d+$/.test(mask) ? Number(mask) : mask;
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
    if (!isObject(zone)) continue;
    const networks =
      zone.name === "wan" || zone.masq === "1" || zone.masq6 === "1"
        ? uplinks
        : local;
    normalizeOptionValues(zone.network).forEach((name) => networks.add(name));
  }

  const routerIps = new Set();
  const localNetworks = [];
  for (const net of networkInterfaces) {
    if (!isObject(net)) continue;
    const isLocal =
      net.up &&
      local.has(net.interface) &&
      !uplinks.has(net.interface) &&
      (net.route == null ||
        (Array.isArray(net.route) &&
          !net.route.some(
            (route) =>
              !isObject(route) ||
              (parsePrefixLength(route.mask) === 0 &&
                (route.target === "0.0.0.0" || route.target === "::")),
          )));
    const addresses = [
      ...asArray(net["ipv4-address"]),
      ...asArray(net["ipv6-address"]),
      ...asArray(net["ipv6-prefix-assignment"]).map(
        (prefix) => prefix?.["local-address"],
      ),
    ];
    for (const entry of addresses) {
      const address = parseAddress(entry?.address);
      if (!address) continue;
      routerIps.add(address.join(":"));
      const mask = parsePrefixLength(entry.mask);
      const maxMask = address.length === 4 ? 32 : 128;
      if (isLocal && Number.isInteger(mask) && mask > 0 && mask <= maxMask) {
        localNetworks.push({ address, mask });
      }
    }
  }
  return { localNetworks, routerIps };
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function isObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
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
      Promise.allSettled([
        callHostHints(),
        callDHCPLeases(),
        callNetworkInterfaceDump(),
        callFirewallZones("firewall", "zone"),
      ]),
    )
    .then(([hintsResult, leasesResult, dumpResult, zonesResult]) => {
      const interfaces = dumpResult.value?.interface;
      const zones = zonesResult.value?.values;
      if (!Array.isArray(interfaces) || !isObject(zones)) return {};

      const hints = hintsResult.value;
      const leases = leasesResult.value;
      const validHints = isObject(hints);
      const validLeases = Array.isArray(leases?.dhcp_leases);
      const choices = buildLocalDeviceChoices(
        validHints ? hints : null,
        validLeases ? leases : null,
        interfaces,
        Object.values(zones),
      );
      // A partial or empty result can be retried on the next interaction.
      if (validHints && validLeases && Object.keys(choices).length) {
        localDeviceChoicesCache = choices;
      }
      return choices;
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
  return values.some((value) => main.validateIP(value).valid);
}

function updateSelectedDeviceLabels(node, choices) {
  // DynamicList.setValue() emits change events even for identical values.
  for (const input of node.querySelectorAll(
    ':scope > .item > input[type="hidden"]',
  )) {
    const label = input.parentElement.firstElementChild;
    const text = choices[input.value] || input.value;
    if (label.textContent !== text) label.textContent = text;
  }
}

function createLocalDeviceDynamicListWidget(option, section_id, cfgvalue) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );
  let choices = localDeviceChoicesCache || {};
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
        if (!Object.keys(loadedChoices).length) return;
        if (Object.keys(choices).length) widget.clearChoices();
        const sorted = sortLocalDeviceChoiceValues(loadedChoices);
        // LuCI treats string labels passed to addChoices() as HTML.
        const labels = Object.fromEntries(
          sorted.map((ip) => [ip, document.createTextNode(loadedChoices[ip])]),
        );
        widget.addChoices(sorted, labels);
        // DynamicList also uses its choice map for later setValue() calls.
        widget.choices = choices = loadedChoices;
        updateSelectedDeviceLabels(node, choices);
        choicesLoaded = Boolean(localDeviceChoicesCache);
      })
      .catch((error) =>
        console.warn("Failed to update local device suggestions", error),
      )
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

  node.addEventListener("pointerdown", maybeLoadChoices, true);
  node.addEventListener("focusin", maybeLoadChoices, true);
  node.addEventListener(
    "keydown",
    (ev) => {
      if (["Enter", " ", "ArrowDown"].includes(ev.key)) maybeLoadChoices(ev);
    },
    true,
  );

  if (hasSingleIpValue(values)) loadChoices();
  return node;
}

const EntryPoint = {
  createLocalDeviceDynamicListWidget,
  loadLocalDeviceChoices,
  normalizeOptionValues,
};

return baseclass.extend(EntryPoint);
