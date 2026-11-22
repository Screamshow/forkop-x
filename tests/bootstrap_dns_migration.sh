#!/bin/sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/forkop/files/usr/lib"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FORKOP_UCI_STATE_FILE="$WORK/settings.uci" FORKOP_DNS_FAILOVER_STATE_FILE="$WORK/no-applied-state.json"

cat > "$WORK/test.uc" <<'UC'
    let migration = require("config.migration");
    let dns = require("xrust.dns");
    let bootstrap = require("dns.bootstrap");
    let fs = require("fs");

    function model(settings) {
        return {
            settings: { ".name": "settings", ".type": "settings", config_version: "1.0.5", ...settings },
            rules: [], sections: [], subscription_url: [], section_interface: [], urltest: []
        };
    }

    function resolver(settings) {
        return dns.bootstrap_config(settings);
    }

    function saved(settings) {
        let lines = [ "forkop.settings=settings" ];
        for (let name in [ "dns_type", "bootstrap_dns_legacy_type", "bootstrap_dns_server", "dns_use_provider" ]) {
            let value = settings[name];
            if (value != null)
                push(lines, "forkop.settings." + name + "=" + join(" ", type(value) == "array" ? value : [ value ]));
        }
        fs.writefile(getenv("FORKOP_UCI_STATE_FILE"), join("\n", lines) + "\n");
        return bootstrap.configured();
    }

    for (let protocol in [ "doh", "dot" ]) {
        let old = model({dns_type: protocol, dns_server: "dns.google", bootstrap_dns_server: ["1.1.1.1:53", "192.168.1.53"]});
        let migrated = migration.migrate_forkop_model(old).model;
        let settings = migrated.settings;
        assert(settings.dns_type == protocol && settings.bootstrap_dns_legacy_type == protocol);
        assert(dns.server_config(settings).type == (protocol == "doh" ? "https" : "tls"));
        let applied = dns.state_template(settings);
        assert(applied.dns_type == protocol && applied.bootstrap_dns_type == "udp");
        assert(resolver(settings).type == "udp" && resolver(settings).server_port == 53);
        assert(saved(settings).protocol == "udp" && saved(settings).servers[0] == "1.1.1.1:53");
        let mixed_version = { ...applied, bootstrap_index: 1 };
        delete mixed_version.bootstrap_dns_type;
        assert(dns.normalize_state(settings, mixed_version).bootstrap_index == 1);
        let fresh = { ...settings, bootstrap_dns_server: ["1.1.1.1", "192.168.1.53"] };
        delete fresh.bootstrap_dns_legacy_type;
        assert(dns.normalize_state(fresh, mixed_version).bootstrap_index == 0);
        assert(dns.failover_selection(dns.state_template(fresh), mixed_version) == null);
        assert(resolver(fresh).server_port == (protocol == "doh" ? 443 : 853));
        assert(saved(fresh).protocol == protocol);
        assert(saved({...fresh, dns_use_provider: "1"}).protocol == "udp");
        delete settings.bootstrap_dns_legacy_type;
        let repeated = migration.migrate_forkop_model(migrated).model;
        assert(repeated.settings.bootstrap_dns_legacy_type == null, "migration re-enabled compatibility after explicit selection");
    }

    let fresh = migration.migrate_forkop_model(model({dns_type: "doh", bootstrap_dns_server: "1.1.1.1",
        applied_migrations: [ "bootstrap_dns_protocol_v1" ] })).model.settings;
    assert(fresh.bootstrap_dns_legacy_type == null && resolver(fresh).type == "https");

    let legacy = migration.migrate_podkop_model(model({dns_type: "doh", bootstrap_dns_server: "resolver.lan:5300"}), {}).model.settings;
    let plain = resolver(legacy);
    assert(plain.type == "udp" && plain.server == "resolver.lan" && plain.server_port == 5300);
    assert(length(saved(legacy).servers) == 0, "pre-start fallback must preserve the literal IP requirement");
    delete legacy.bootstrap_dns_legacy_type;
    assert(resolver(legacy).unsupported != null, "encrypted Bootstrap must reject a hostname dial target");
    print("Bootstrap migrations, effective transport, direct lookups and failover state verified\n");
UC
ucode -L "$LIB" "$WORK/test.uc"
grep -Fq "list applied_migrations 'bootstrap_dns_protocol_v1'" "$ROOT/forkop/files/etc/config/forkop"
