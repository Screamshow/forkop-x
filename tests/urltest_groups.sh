#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
export FORKOP_VERSION="${FORKOP_VERSION:-1.14.8-canary.2}"
PARSER_UC="$FORKOP_LIB/subscription/parser.uc"
GENERATOR_UC="$FORKOP_LIB/singbox/generator.uc"
CACHE_UC="$FORKOP_LIB/subscription/cache.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

ucode -L "$FORKOP_LIB" -e '
let urltest = require("singbox.urltest");
let members = [ "Amsterdam #1", "Amsterdam #2", "Helsinki #1", "Stockholm #1" ];
let starts = {};
for (let i = 0; i < 64; i++) {
    let seed = sprintf("router-%d", i);
    let rotated = urltest.rotate_start(members, seed, "Automatic");
    if (sprintf("%J", rotated) != sprintf("%J", urltest.rotate_start(members, seed, "Automatic")))
        die("URLTest order changed for the same generation seed\n");
    let seen = {};
    for (let member in rotated)
        seen[member] = true;
    if (length(keys(seen)) != length(members))
        die("URLTest order lost a node\n");
    starts[rotated[0]] = true;
}
if (length(keys(starts)) != length(members))
    die("URLTest starting nodes were not distributed\n");
if (urltest.rotate_start(members, "", "Automatic")[0] != members[0])
    die("URLTest order changed without a generation seed\n");
' || fail "provider URLTest startup distribution"

ucode -L "$FORKOP_LIB" -e '
let subscription = require("singbox.subscription");
let state = {
    servers: {
        proxy: "edge-7.example",
        "🇳🇱 Amsterdam": "edge-7.example"
    },
    outboundMetadata: {
        names: {
            proxy: "proxy",
            "🇳🇱 Amsterdam": "🇳🇱 Amsterdam"
        },
        countries: { "🇳🇱 Amsterdam": "NL" },
        descriptions: { "🇳🇱 Amsterdam": "Upstream Tube" }
    },
    urltestGroups: {
        Automatic: { outbounds: [ "proxy", "🇳🇱 Amsterdam" ] }
    }
};
subscription.resolve_urltest_profile_aliases(state);
if (state.outboundMetadata.names.proxy != "🇳🇱 Amsterdam")
    die("URLTest member did not inherit the matching profile name\n");
if (state.outboundMetadata.countries.proxy != "NL")
    die("URLTest member did not inherit the matching profile country\n");
if (state.outboundMetadata.descriptions.proxy != "Upstream Tube")
    die("URLTest member did not inherit the matching profile description\n");
' || fail "URLTest profile alias metadata"

normalize_subscription() {
  local input="$1"
  local output="$2"
  ucode -L "$FORKOP_LIB" "$PARSER_UC" normalize-content "$input" "$output"
}

prepare_subscription_cache() {
  local section="$1"
  local index="$2"
  local url="$3"
  local normalized_json="$4"
  local source="$WORK_DIR/subscriptions/${section}-subscription-${index}"

  mkdir -p "$WORK_DIR/subscriptions"
  cp "$normalized_json" "${source}.json"
  printf '%s\n' "$url" >"${source}.url"
  printf 'INCY/%s' "${FORKOP_VERSION%%-canary.*}" >"${source}.user_agent"
}

generate_config() {
  local fixture="$1"
  local output="$2"
  mkdir -p "${output}.section-cache"
  TMP_SUBSCRIPTION_FOLDER="$WORK_DIR/subscriptions" \
    FORKOP_SUBSCRIPTION_METADATA_DIR="$WORK_DIR/metadata" \
    FORKOP_URLTEST_START_SEED="${FORKOP_URLTEST_START_SEED:-seed-0}" \
    ucode -L "$FORKOP_LIB" "$GENERATOR_UC" generate-config-fixture \
      "$fixture" "$output" "127.0.0.1"
}

cat >"$WORK_DIR/xray.json" <<'JSON'
{
  "meta": {
    "serverDescription": "Upstream Tube"
  },
  "remarks": "Latvia group",
  "burstObservatory": {
    "pingConfig": {
      "destination": "https://www.gstatic.com/generate_204",
      "interval": "120s",
      "timeout": "3s",
      "sampling": 2
    }
  },
  "routing": {
    "balancers": [
      {
        "tag": "latvia-balancer",
        "selector": [ "lv-" ],
        "strategy": {
          "type": "leastLoad",
          "settings": {
            "tolerance": 0.7,
            "maxRTT": "1.5s"
          }
        }
      }
    ]
  },
  "outbounds": [
    {
      "protocol": "vless",
      "tag": "lv-🇱🇻 Riga A",
      "settings": {
        "vnext": [
          {
            "address": "riga-a.example",
            "port": 443,
            "users": [
              {
                "id": "00000000-0000-4000-8000-000000000001",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {
          "serverName": "riga-a.example"
        }
      }
    },
    {
      "protocol": "vless",
      "tag": "lv-🇱🇻 Riga B",
      "settings": {
        "vnext": [
          {
            "address": "riga-b.example",
            "port": 443,
            "users": [
              {
                "id": "00000000-0000-4000-8000-000000000002",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "tls",
        "tlsSettings": {
          "serverName": "riga-b.example"
        }
      }
    }
  ]
}
JSON

mkdir -p "$WORK_DIR/metadata"
: >"$WORK_DIR/xray.headers"
ucode -L "$FORKOP_LIB" "$PARSER_UC" metadata-extract-ui-file \
  "$WORK_DIR/xray.headers" "$WORK_DIR/xray.json" "$WORK_DIR/metadata/proxy.json"
ucode -e '
let fs = require("fs");
let metadata = json(fs.readfile(ARGV[0]));
if (metadata.serverDescription != "Upstream Tube")
    die("missing Xray server description\n");
' "$WORK_DIR/metadata/proxy.json" ||
  fail "Xray meta.serverDescription must be extracted into subscription metadata"

xray_normalized="$WORK_DIR/xray-normalized.json"
normalize_subscription "$WORK_DIR/xray.json" "$xray_normalized"

ucode -e '
let fs = require("fs");
let value = json(fs.readfile(ARGV[0]));
let group = null;
for (let outbound in value.outbounds || [])
    if (outbound.type == "urltest")
        group = outbound;
if (!group)
    die("missing xray urltest group\n");
if (group.url != "https://www.gstatic.com/generate_204")
    die("xray urltest url was not preserved\n");
if (group.interval != "120s")
    die("xray urltest interval was not preserved\n");
if (group.tolerance != 175)
    die("xray urltest should use sing-box latency tolerance instead of Xray failure ratio\n");
if (group.idle_timeout != "30m")
    die("xray urltest idle timeout default was not applied\n");
if (group.interrupt_exist_connections !== true)
    die("xray urltest should interrupt existing connections when selection changes\n");
for (let child in group.outbounds || [])
    if (substr(child, 0, 5) == "xray-")
        die("xray urltest child tags should preserve source names when unique\n");
' "$xray_normalized" || fail "xray normalized URLTest fields"

cat >"$WORK_DIR/xray-nodes.json" <<'JSON'
[
  {
    "remarks": "Amsterdam #1",
    "meta": { "serverDescription": "Upstream Tube" },
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": {
          "vnext": [
            {
              "address": "ams-1.example",
              "port": 443,
              "users": [ { "id": "00000000-0000-4000-8000-000000000011", "encryption": "none" } ]
            }
          ]
        }
      }
    ]
  },
  {
    "remarks": "Amsterdam #2",
    "meta": { "serverDescription": "Upstream Backbone" },
    "outbounds": [
      {
        "protocol": "vless",
        "tag": "proxy",
        "settings": {
          "vnext": [
            {
              "address": "ams-2.example",
              "port": 443,
              "users": [ { "id": "00000000-0000-4000-8000-000000000012", "encryption": "none" } ]
            }
          ]
        }
      }
    ]
  }
]
JSON

xray_nodes_normalized="$WORK_DIR/xray-nodes-normalized.json"
normalize_subscription "$WORK_DIR/xray-nodes.json" "$xray_nodes_normalized"
ucode -e '
let fs = require("fs");
let value = json(fs.readfile(ARGV[0]));
let descriptions = {};
for (let outbound in value.outbounds || [])
    descriptions[outbound.remark] = outbound.__forkop_description;
if (descriptions["Amsterdam #1"] != "Upstream Tube")
    die("first Xray node description was not retained\n");
if (descriptions["Amsterdam #2"] != "Upstream Backbone")
    die("second Xray node description was not retained\n");
' "$xray_nodes_normalized" || fail "per-node Xray server descriptions"

prepare_subscription_cache proxy 1 "https://xray.example/sub" "$xray_normalized"
cat >"$WORK_DIR/xray-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "Riga" ],
      "detect_server_country": "flag_emoji",
      "subscription_urls": [ "https://xray.example/sub" ]
    }
  ]
}
JSON

xray_config="$WORK_DIR/xray-config.json"
generate_config "$WORK_DIR/xray-fixture.json" "$xray_config"
generate_config "$WORK_DIR/xray-fixture.json" "$WORK_DIR/xray-config-again.json"
FORKOP_URLTEST_START_SEED=seed-1 generate_config "$WORK_DIR/xray-fixture.json" "$WORK_DIR/xray-config-other-start.json"
ucode -e '
let fs = require("fs");
let first = json(fs.readfile(ARGV[0] + ".section-cache/proxy.json"));
let second = json(fs.readfile(ARGV[1] + ".section-cache/proxy.json"));
let third = json(fs.readfile(ARGV[2] + ".section-cache/proxy.json"));
let a = null, b = null, c = null;
for (let _, outbound in first.urltestGroups || {})
    if (outbound.tolerance == 175)
        a = outbound.outbounds;
for (let _, outbound in second.urltestGroups || {})
    if (outbound.tolerance == 175)
        b = outbound.outbounds;
for (let _, outbound in third.urltestGroups || {})
    if (outbound.tolerance == 175)
        c = outbound.outbounds;
if (a == null || b == null || sprintf("%J", a) != sprintf("%J", b))
    die("provider URLTest startup order changed with the same seed\n");
if (c == null || sprintf("%J", a) == sprintf("%J", c))
    die("provider URLTest startup order did not change with a new seed\n");
' "$xray_config" "$WORK_DIR/xray-config-again.json" "$WORK_DIR/xray-config-other-start.json" || fail "provider URLTest startup order"

cat >"$WORK_DIR/xray-reveal-urltest-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "Riga" ],
      "detect_server_country": "flag_emoji",
      "subscription_urls": [ "https://xray.example/sub" ],
      "subscription_url_settings": "{\"https://xray.example/sub\":{\"hide_urltest_group_outbounds\":\"0\"}}"
    }
  ]
}
JSON

xray_reveal_urltest_config="$WORK_DIR/xray-reveal-urltest-config.json"
generate_config "$WORK_DIR/xray-reveal-urltest-fixture.json" "$xray_reveal_urltest_config"

cat >"$WORK_DIR/xray-group-name-filter-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_outbounds": [ "Latvia group" ],
      "detect_server_country": "flag_emoji",
      "subscription_urls": [ "https://xray.example/sub" ],
      "subscription_url_settings": "{\"https://xray.example/sub\":{\"hide_urltest_group_outbounds\":\"0\"}}"
    }
  ]
}
JSON

xray_group_name_filter_config="$WORK_DIR/xray-group-name-filter-config.json"
if generate_config "$WORK_DIR/xray-group-name-filter-fixture.json" "$xray_group_name_filter_config" \
  >"$WORK_DIR/xray-group-name-filter.stdout" 2>"$WORK_DIR/xray-group-name-filter.stderr"; then
  fail "a URLTest group with no usable leaf outbound must fail closed"
fi
grep -Fq "URLTest group" "$WORK_DIR/xray-group-name-filter.stdout" "$WORK_DIR/xray-group-name-filter.stderr" &&
  grep -Fq "has no usable proxy outbounds after filtering" "$WORK_DIR/xray-group-name-filter.stdout" "$WORK_DIR/xray-group-name-filter.stderr" ||
  fail "empty URLTest group must report its rule and fail-closed reason"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let reveal_config = json(fs.readfile(ARGV[2]));
let imported = null;
let builtin = null;
let reveal_selector = null;
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
for (let outbound in config.outbounds || []) {
    if (outbound.type == "urltest" && outbound.tag == "Latvia group")
        die("unused imported Xray URLTest must not be loaded\n");
    if (outbound.type == "urltest" && outbound.tag == "proxy-urltest-out")
        builtin = outbound;
}
for (let outbound in reveal_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_selector = outbound;
imported = object_or_empty(cache.urltestGroups)["Latvia group"];
if (!imported || imported.url != "https://www.gstatic.com/generate_204" || imported.interval != "120s")
    die("generated xray imported URLTest did not preserve subscription params\n");
if (imported.tolerance != 175 || imported.idle_timeout != "30m" || imported.interrupt_exist_connections !== true)
    die("generated xray imported URLTest is missing sing-box runtime defaults\n");
if (!builtin || length(builtin.outbounds || []) != 2)
    die("built-in URLTest should include two matched xray leaf outbounds\n");
for (let child in builtin.outbounds || [])
    if (child == "Latvia group")
        die("built-in URLTest must not use the xray group tag as a child\n");
for (let child in builtin.outbounds || [])
    if (substr(child, 0, 5) == "xray-")
        die("built-in URLTest must not use artificial xray child tag prefixes\n");
let imported_cache = object_or_empty(cache.urltestGroups)["Latvia group"] || {};
if (object_or_empty(cache.outboundMetadata).descriptions["lv-🇱🇻 Riga A"] != null)
    die("virtual Xray host description must not be assigned to injected leaf outbounds\n");
if (imported_cache.url != "https://www.gstatic.com/generate_204" || imported_cache.interval != "120s")
    die("section cache is missing imported xray URLTest params\n");
if (imported_cache.tolerance != 175 || imported_cache.idle_timeout != "30m" || imported_cache.interrupt_exist_connections !== true)
    die("section cache is missing imported xray URLTest runtime defaults\n");
if (length(object_or_empty(cache.urltestGroups)["proxy-urltest-out"].outbounds || []) != 2)
    die("section cache is missing built-in URLTest membership\n");
let candidates = cache.urltestCandidateTags || [];
if (contains(candidates, "Latvia group") || contains(candidates, "proxy-urltest-out"))
    die("section cache URLTest candidates must not include URLTest groups\n");
if (length(candidates) != length(builtin.outbounds || []))
    die("section cache URLTest candidates should include only xray leaf outbounds\n");
for (let child in builtin.outbounds || [])
    if (!contains(candidates, child))
        die("section cache URLTest candidates are missing a matched xray leaf outbound\n");
if (!reveal_selector || contains(reveal_selector.outbounds, "Latvia group") ||
    !contains(reveal_selector.outbounds, "proxy-urltest-out"))
    die("selector must expose configured URLTest without the unused imported group\n");
for (let child in [ "lv-🇱🇻 Riga A", "lv-🇱🇻 Riga B" ])
    if (!contains(reveal_selector.outbounds, child))
        die("filtered Xray child must remain selectable in its section\n");
' "$xray_config" "$xray_config.section-cache/proxy.json" "$xray_reveal_urltest_config" || fail "xray generated URLTest behavior"

xray_metadata="$WORK_DIR/xray-ui-outbound-metadata.json"
ucode -L "$FORKOP_LIB" "$CACHE_UC" get-outbound-metadata "$xray_config.section-cache" proxy "$WORK_DIR/missing-outbound-metadata.json" >"$xray_metadata"

ucode -e '
let fs = require("fs");
let metadata = json(fs.readfile(ARGV[0]));
let names = type(metadata.names) == "object" ? metadata.names : {};
if (names["Latvia group"] != null || names["proxy-urltest-out"] != null)
    die("UI outbound metadata must not include URLTest group names\n");
if (length(keys(names)) != 2)
    die("UI outbound metadata should contain only xray leaf outbound names\n");
' "$xray_metadata" || fail "xray UI outbound metadata filtering"

cat >"$WORK_DIR/singbox.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "Native Group",
      "outbounds": [ "Native A" ],
      "url": "https://native.example/ping",
      "interval": "1m",
      "tolerance": 80
    },
    {
      "type": "vless",
      "tag": "Native A",
      "server": "native-a.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000003",
      "tls": {
        "enabled": true,
        "server_name": "native-a.example"
      }
    },
    {
      "type": "vless",
      "tag": "Detour Only",
      "server": "detour.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000004",
      "tls": {
        "enabled": true,
        "server_name": "detour.example"
      }
    },
    {
      "type": "vless",
      "tag": "Uses Detour",
      "server": "uses-detour.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000005",
      "detour": "Detour Only",
      "tls": {
        "enabled": true,
        "server_name": "uses-detour.example"
      }
    }
  ]
}
JSON

singbox_normalized="$WORK_DIR/singbox-normalized.json"
normalize_subscription "$WORK_DIR/singbox.json" "$singbox_normalized"

ucode -e '
let fs = require("fs");
let value = json(fs.readfile(ARGV[0]));
let flags = {};
for (let outbound in value.outbounds || [])
    flags[outbound.tag] = {
        allow: outbound.__forkop_allow_group === true,
        hidden: outbound.__forkop_hidden === true
    };
if (!flags["Native Group"].allow)
    die("native sing-box URLTest group was not allowed\n");
if (!flags["Native A"].hidden)
    die("native sing-box URLTest child was not hidden\n");
if (!flags["Detour Only"].hidden)
    die("native sing-box detour-only outbound was not hidden\n");
if (flags["Uses Detour"].hidden)
    die("visible outbound using detour should stay visible\n");
' "$singbox_normalized" || fail "native sing-box normalized URLTest fields"

rm -rf "$WORK_DIR/subscriptions"
prepare_subscription_cache proxy 1 "https://singbox.example/sub" "$singbox_normalized"
cat >"$WORK_DIR/singbox-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Native" ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ]
    }
  ]
}
JSON

singbox_config="$WORK_DIR/singbox-config.json"
generate_config "$WORK_DIR/singbox-fixture.json" "$singbox_config"

cat >"$WORK_DIR/singbox-prefix-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Provider " ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ],
      "subscription_url_settings": "{\"https://singbox.example/sub\":{\"prefix_nodes\":\"1\",\"node_prefix\":\"Provider\"}}"
    }
  ]
}
JSON

singbox_prefix_config="$WORK_DIR/singbox-prefix-config.json"
generate_config "$WORK_DIR/singbox-prefix-fixture.json" "$singbox_prefix_config"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
function outbound_by_tag(config, tag) {
    for (let outbound in config.outbounds || [])
        if (outbound && outbound.tag == tag)
            return outbound;
    return null;
}
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let names = object_or_empty(object_or_empty(cache.outboundMetadata).names);
let groups = object_or_empty(cache.urltestGroups);
if (outbound_by_tag(config, "Provider Native Group"))
    die("unused prefixed imported group must not be loaded\n");
let imported = object_or_empty(cache.urltestGroups)["Provider Native Group"];
let native = outbound_by_tag(config, "Provider Native A");
let detour = outbound_by_tag(config, "Provider Detour Only");
let uses_detour = outbound_by_tag(config, "Provider Uses Detour");
let builtin = outbound_by_tag(config, "proxy-urltest-out");
if (!imported || !native || !detour || !uses_detour)
    die("subscription prefix was not applied to every imported outbound\n");
if (length(imported.outbounds || []) != 1 || imported.outbounds[0] != "Provider Native A")
    die("subscription prefix did not rewrite imported URLTest group membership\n");
if (uses_detour.detour != "Provider Detour Only")
    die("subscription prefix did not rewrite detour references\n");
if (!builtin || length(builtin.outbounds || []) != 3)
    die("prefixed node names did not match the configured URLTest filter\n");
for (let tag in [ "Provider Native A", "Provider Detour Only", "Provider Uses Detour" ])
    if (!contains(builtin.outbounds, tag))
        die("built-in URLTest is missing a prefixed node\n");
if (contains(cache.urltestCandidateTags || [], "Provider Native Group"))
    die("prefixed imported URLTest group must not become a URLTest candidate\n");
if (object_or_empty(groups["Provider Native Group"]).displayName != "Provider Native Group")
    die("prefixed imported URLTest group display name was not retained\n");
if (names["Provider Native A"] != "Provider Native A" ||
    names["Provider Native Group"] != "Provider Native Group")
    die("prefixed outbound metadata names were not retained\n");
if (names["Native A"] != null || names["Native Group"] != null)
    die("unprefixed outbound metadata names must not remain\n");
' "$singbox_prefix_config" "$singbox_prefix_config.section-cache/proxy.json" || fail "subscription node prefix behavior"

cat >"$WORK_DIR/singbox-reveal-urltest-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Native" ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ],
      "subscription_url_settings": "{\"https://singbox.example/sub\":{\"hide_urltest_group_outbounds\":\"0\"}}"
    }
  ]
}
JSON

cat >"$WORK_DIR/singbox-reveal-detour-fixture.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "log_level": "warn"
  },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "urltest_enabled": "1",
      "urltest_check_interval": "3m",
      "urltest_tolerance": "50",
      "urltest_filter_mode": "include",
      "urltest_include_regex": [ "^Native" ],
      "detect_server_country": "country_is",
      "subscription_urls": [ "https://singbox.example/sub" ],
      "subscription_url_settings": "{\"https://singbox.example/sub\":{\"hide_detour_outbounds\":\"0\"}}"
    }
  ]
}
JSON

singbox_reveal_urltest_config="$WORK_DIR/singbox-reveal-urltest-config.json"
singbox_reveal_detour_config="$WORK_DIR/singbox-reveal-detour-config.json"
generate_config "$WORK_DIR/singbox-reveal-urltest-fixture.json" "$singbox_reveal_urltest_config"
generate_config "$WORK_DIR/singbox-reveal-detour-fixture.json" "$singbox_reveal_detour_config"

ucode -e '
let fs = require("fs");
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
let config = json(fs.readfile(ARGV[0]));
let cache = json(fs.readfile(ARGV[1]));
let reveal_urltest_config = json(fs.readfile(ARGV[2]));
let reveal_detour_config = json(fs.readfile(ARGV[3]));
let imported = null;
let builtin = null;
let selector = null;
let reveal_urltest_selector = null;
let reveal_detour_selector = null;
for (let outbound in config.outbounds || []) {
    if (outbound.type == "urltest" && outbound.tag == "Native Group")
        die("unused imported native URLTest must not be loaded\n");
    if (outbound.type == "urltest" && outbound.tag == "proxy-urltest-out")
        builtin = outbound;
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        selector = outbound;
}
for (let outbound in reveal_urltest_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_urltest_selector = outbound;
for (let outbound in reveal_detour_config.outbounds || [])
    if (outbound.type == "selector" && outbound.tag == "proxy-out")
        reveal_detour_selector = outbound;
function contains(values, needle) {
    for (let value in values || [])
        if (value == needle)
            return true;
    return false;
}
imported = object_or_empty(cache.urltestGroups)["Native Group"];
if (!imported || imported.url != "https://native.example/ping" || imported.interval != "1m" || imported.tolerance != 80)
    die("generated native URLTest did not preserve subscription params\n");
if (!builtin || length(builtin.outbounds || []) != 1 || builtin.outbounds[0] != "Native A")
    die("built-in URLTest regex filter should expand Native Group to Native A only\n");
if (!contains(selector.outbounds, "Native A"))
    die("filtered native child must remain selectable\n");
for (let tag in selector.outbounds || [])
    if (tag == "Detour Only")
        die("detour-only outbound must not be visible in selector\n");
if (!contains(reveal_urltest_selector ? reveal_urltest_selector.outbounds : [], "Native A"))
    die("filtered native child must remain selectable with legacy settings\n");
if (contains(reveal_urltest_selector ? reveal_urltest_selector.outbounds : [], "Detour Only"))
    die("detour outbound should stay hidden when only URLTest hiding is disabled\n");
if (!contains(reveal_detour_selector ? reveal_detour_selector.outbounds : [], "Native A"))
    die("filtered native child must remain selectable with legacy detour settings\n");
if (contains(reveal_detour_selector ? reveal_detour_selector.outbounds : [], "Detour Only"))
    die("detour outbound must remain hidden even if a legacy setting disables hiding\n");
if (length(object_or_empty(cache.urltestGroups)["Native Group"].outbounds || []) != 1)
    die("section cache is missing native URLTest membership\n");
let candidates = cache.urltestCandidateTags || [];
if (contains(candidates, "Native Group") || contains(candidates, "proxy-urltest-out"))
    die("section cache native URLTest candidates must not include URLTest groups\n");
if (!contains(candidates, "Native A") || !contains(candidates, "Detour Only"))
    die("section cache native URLTest candidates should include all leaf outbounds, including hidden ones\n");
' "$singbox_config" "$singbox_config.section-cache/proxy.json" "$singbox_reveal_urltest_config" "$singbox_reveal_detour_config" || fail "native sing-box generated URLTest behavior"

singbox_metadata="$WORK_DIR/singbox-ui-outbound-metadata.json"
ucode -L "$FORKOP_LIB" "$CACHE_UC" get-outbound-metadata "$singbox_config.section-cache" proxy "$WORK_DIR/missing-outbound-metadata.json" >"$singbox_metadata"

ucode -e '
let fs = require("fs");
let metadata = json(fs.readfile(ARGV[0]));
let names = type(metadata.names) == "object" ? metadata.names : {};
if (names["Native Group"] != null || names["proxy-urltest-out"] != null)
    die("UI outbound metadata must not include native URLTest group names\n");
if (names["Native A"] == null || names["Detour Only"] == null)
    die("UI outbound metadata should include all native leaf outbound names\n");
' "$singbox_metadata" || fail "native UI outbound metadata filtering"

cat >"$WORK_DIR/aliased-urltest.json" <<'JSON'
{
  "outbounds": [
    {
      "type": "urltest",
      "tag": "Automatic",
      "outbounds": [ "proxy-2" ]
    },
    {
      "type": "vless",
      "tag": "proxy-2",
      "server": "tallinn.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000006"
    },
    {
      "type": "vless",
      "tag": "Tallinn",
      "server": "tallinn.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000006"
    },
    {
      "type": "vless",
      "tag": "Amsterdam",
      "server": "amsterdam.example",
      "server_port": 443,
      "uuid": "00000000-0000-4000-8000-000000000007"
    }
  ]
}
JSON

aliased_urltest_normalized="$WORK_DIR/aliased-urltest-normalized.json"
normalize_subscription "$WORK_DIR/aliased-urltest.json" "$aliased_urltest_normalized"
rm -rf "$WORK_DIR/subscriptions"
prepare_subscription_cache proxy 1 "https://aliased.example/sub" "$aliased_urltest_normalized"

cat >"$WORK_DIR/aliased-urltest-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "subscription_urls": [ "https://aliased.example/sub" ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_exclude_tallinn",
      ".type": "urltest",
      "section": "proxy",
      "name": "Fastest",
      "filter_mode": "exclude",
      "exclude_outbounds": [ "Tallinn" ]
    }
  ]
}
JSON

aliased_urltest_config="$WORK_DIR/aliased-urltest-config.json"
generate_config "$WORK_DIR/aliased-urltest-fixture.json" "$aliased_urltest_config"
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let group = null;
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag == "proxy-urltest-ut_exclude_tallinn-out")
        group = outbound;
if (!group)
    die("manual URLTest group is missing\n");
for (let tag in group.outbounds || [])
    if (tag == "proxy-2" || tag == "Tallinn")
        die("subscription URLTest alias bypassed the explicit Tallinn exclusion\n");
if (length(group.outbounds || []) != 1 || group.outbounds[0] != "Amsterdam")
    die("manual URLTest exclusion produced unexpected membership\n");
' "$aliased_urltest_config" || fail "manual URLTest excludes subscription profile aliases"

cat >"$WORK_DIR/country-is-fixture.json" <<'JSON'
{
  "settings": { ".name": "settings", ".type": "settings" },
  "section": [
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "proxy",
      "selector_proxy_links": [
        "vless://00000000-0000-4000-8000-000000000001@alpha.example:443?encryption=none&security=tls&sni=alpha.example#Alpha",
        "vless://00000000-0000-4000-8000-000000000002@beta.example:443?encryption=none&security=tls&sni=beta.example#Beta"
      ]
    }
  ],
  "urltest": [
    {
      ".name": "ut_country",
      ".type": "urltest",
      "section": "proxy",
      "name": "Germany",
      "filter_mode": "include",
      "detect_server_country": "country_is",
      "include_countries": [ "DE" ]
    }
  ]
}
JSON
country_is_config="$WORK_DIR/country-is-config.json"
mkdir -p "$country_is_config.section-cache"
cat >"$country_is_config.section-cache/proxy.json" <<'JSON'
{
  "servers": {
    "proxy-1-out": "alpha.example",
    "proxy-2-out": "beta.example"
  },
  "outboundMetadata": {
    "countries": {
      "proxy-1-out": "DE",
      "proxy-2-out": "NL"
    }
  }
}
JSON
generate_config "$WORK_DIR/country-is-fixture.json" "$country_is_config"
ucode -e '
let fs = require("fs");
let config = json(fs.readfile(ARGV[0]));
let urltest = null;
for (let outbound in config.outbounds || [])
    if (outbound && outbound.tag == "proxy-urltest-ut_country-out")
        urltest = outbound;
if (!urltest || length(urltest.outbounds || []) != 1 || urltest.outbounds[0] != "proxy-1-out")
    die("cached country.is metadata was not applied to URLTest filtering\n");
' "$country_is_config" || fail "URLTest country.is cached filtering"

ucode -e '
function node(tag, uuid, extra) {
    return { type: "vless", tag, server: "test.example", server_port: 443, uuid, ...extra };
}
let uuid = "00000000-0000-4000-8000-000000000001";
printf("%J\n", { version: 1, format: "sing-box-json", outbounds: [
    { type: "urltest", tag: "Automatic", outbounds: ["proxy-14", "proxy-15"], __forkop_allow_group: true },
    node("proxy-14", uuid, { __forkop_hidden: true }),
    node("proxy-15", "00000000-0000-4000-8000-000000000002", { __forkop_hidden: true }),
    node("Helsinki", uuid, {}),
    node("Uses detour", uuid, { detour: "proxy-14" })
] });
' >"$WORK_DIR/duplicate-urltest-feed.json"
prepare_subscription_cache proxy 1 https://test.example/sub "$WORK_DIR/duplicate-urltest-feed.json"

for scenario in on off legacy both; do
  ucode -e '
let url = "https://test.example/sub";
let fixture = {
    settings: { ".name": "settings", ".type": "settings" },
    section: [{ ".name": "proxy", ".type": "section", enabled: "1", action: "connection",
        subscription_urls: [url], subscription_url_settings: sprintf("%J", {
            [url]: { include_urltest_groups: ARGV[0] == "on" ? "1" : "0" }
        })
    }]
};
if (ARGV[0] == "legacy" || ARGV[0] == "both")
    fixture.urltest = [{ ".name": "local", ".type": "urltest", section: "proxy",
        name: "Local", filter_mode: "include",
        include_outbounds: ARGV[0] == "both" ? ["proxy-14", "Helsinki"] : ["proxy-14"]
    }];
printf("%J\n", fixture);
' "$scenario" >"$WORK_DIR/duplicate-urltest-fixture.json"
  output="$WORK_DIR/duplicate-urltest-$scenario.json"
  generate_config "$WORK_DIR/duplicate-urltest-fixture.json" "$output"
  ucode -e '
let config = json(require("fs").readfile(ARGV[0]));
let by_tag = {};
for (let outbound in config.outbounds)
    by_tag[outbound.tag] = outbound;
let selector = by_tag["proxy-out"].outbounds;
let scenario = ARGV[1];
if (scenario == "on") {
    if (!("Automatic" in selector) || "proxy-14" in selector ||
        !("proxy-14" in by_tag.Automatic.outbounds) || by_tag["Uses detour"].detour != "proxy-14")
        die("enabled provider URLTest changed\n");
} else {
    if (by_tag.Automatic || by_tag["proxy-14"] || !("Helsinki" in selector))
        die("duplicate provider member remained after disabling import\n");
    if (scenario == "off") {
        if (!("proxy-15" in selector) || by_tag["Uses detour"].detour != "Helsinki")
            die("distinct member or detour reference was lost\n");
    } else {
        let local = by_tag["proxy-urltest-local-out"]?.outbounds;
        if (length(local) != 1 || local[0] != "Helsinki")
            die("saved URLTest selection did not resolve to the standalone node\n");
    }
}
' "$output" "$scenario" || fail "subscription URLTest duplicate handling ($scenario)"
done

printf 'URLTest group checks passed\n'
