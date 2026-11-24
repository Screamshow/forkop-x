#!/usr/bin/env ucode

let fs = require("fs");
let uci = require("core.uci");
let dns_reload = require("dns.reload");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const SB_DNS_INBOUND_ADDRESS = getenv("SB_DNS_INBOUND_ADDRESS") || "127.0.0.42";
const DNSMASQ_INIT = getenv("DNSMASQ_INIT") || "/etc/init.d/dnsmasq";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const RESTORE_PENDING = RUNTIME_STATE_DIR + "/dnsmasq-restore.pending";
const SNAPSHOT_VERSION = "1";
const DNSMASQ_DEFAULT = "dhcp.@dnsmasq[0].";
const LEGACY_BACKUP_KEYS = [ "forkop_server", "forkop_noresolv", "forkop_cachesize" ];
const SNAPSHOT_PREFIX = "dhcp.@dnsmasq[0].forkop_dns_";
const SNAPSHOT_KEYS = [ "version", "transaction_id", "server", "server_present", "server_kind",
    "noresolv", "noresolv_present", "cachesize", "cachesize_present" ];

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function run(command) {
    return system(command) == 0;
}

function uci_available() {
    return uci.available();
}

function uci_get(path) {
    return uci.get(path);
}

function uci_exists(path) {
    return uci.exists(path);
}

function uci_delete(path) {
    uci.delete(path);
}

function uci_set(path, value) {
    uci.set(path, value);
}

function uci_add_list(path, value) {
    uci.add_list(path, value);
}

function uci_del_list(path, value) {
    return uci.del_list(path, value);
}

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function log(message, level) {
    level = as_string(level || "info");
    run("logger -t " + shell_quote("forkop") + " " + shell_quote("[" + level + "] " + as_string(message)));
}

function restart_dnsmasq() {
    return dns_reload.apply(DNSMASQ_INIT);
}

function dnsmasq_legacy_instance_exists() {
    let section = uci.get_all("dhcp", "forkop");
    if (!section || section[".type"] != "dnsmasq")
        return false;
    let primary = uci.get_all("dhcp", "@dnsmasq[0]");
    return (!primary || primary[".name"] != "forkop") &&
        uci_get("dhcp.forkop.noresolv") == "1" && uci_get("dhcp.forkop.cachesize") == "0" &&
        list_has(uci_get("dhcp.forkop.server"), SB_DNS_INBOUND_ADDRESS) &&
        list_has(uci_get("dhcp.forkop.notinterface"), "lo");
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_forkop_dns() {
    return list_has(dnsmasq_default_servers(), SB_DNS_INBOUND_ADDRESS);
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function dnsmasq_legacy_interfaces() {
    let legacy_dnsmasq_section = "forkop";
    let legacy_interfaces = uci_get("dhcp." + legacy_dnsmasq_section + ".interface");
    if (legacy_interfaces == "")
        legacy_interfaces = uci_get(CONFIG_NAME + ".settings.source_network_interfaces");
    if (legacy_interfaces == "")
        legacy_interfaces = "br-lan";

    return legacy_interfaces;
}

function snapshot_path(key) {
    return SNAPSHOT_PREFIX + key;
}

function dnsmasq_snapshot_marker_present() {
    for (let key in SNAPSHOT_KEYS) {
        if (uci_exists(snapshot_path(key)))
            return true;
    }
    return false;
}

function snapshot_presence_is_valid(key) {
    let present = uci_get(snapshot_path(key + "_present"));
    if (present != "0" && present != "1")
        return false;
    return present != "1" || uci_exists(snapshot_path(key));
}

function dnsmasq_snapshot_is_valid() {
    if (uci_get(snapshot_path("version")) != SNAPSHOT_VERSION ||
        uci_get(snapshot_path("transaction_id")) == "")
        return false;

    if (!snapshot_presence_is_valid("server") ||
        !snapshot_presence_is_valid("noresolv") ||
        !snapshot_presence_is_valid("cachesize"))
        return false;

    let server_present = uci_get(snapshot_path("server_present"));
    if (server_present == "1") {
        let kind = uci_get(snapshot_path("server_kind"));
        if (kind != "scalar" && kind != "list")
            return false;
    }
    else if (uci_exists(snapshot_path("server")) || uci_exists(snapshot_path("server_kind"))) {
        return false;
    }

    return true;
}

function dnsmasq_option_value(option) {
    let section = uci.get_all("dhcp", "@dnsmasq[0]");
    return type(section) == "object" ? section[option] : null;
}

function additional_dnsmasq_servers() {
    let current = dnsmasq_option_value("server");
    return filter(type(current) == "array" ? current : words(current),
        value => value != SB_DNS_INBOUND_ADDRESS);
}

function dnsmasq_has_legacy_defaults() {
    for (let key in LEGACY_BACKUP_KEYS)
        if (uci_get(DNSMASQ_DEFAULT + key) != "")
            return true;
    return false;
}

function dnsmasq_has_legacy_instance_state() {
    return dnsmasq_legacy_instance_exists() || uci_get(DNSMASQ_DEFAULT + "forkop_notinterface") != "";
}

function dnsmasq_has_forkop_managed_state() {
    return fs.stat(RESTORE_PENDING) != null || dnsmasq_snapshot_is_valid() ||
        dnsmasq_has_legacy_instance_state() || dnsmasq_has_legacy_defaults();
}

function dnsmasq_server_is_scoped(server) {
    let parts = split(server, "/");
    if (length(parts) < 3 || parts[0] != "")
        return false;

    // An empty selector matches unqualified names. Require a literal domain
    // character in the other selectors to exclude catch-all patterns.
    for (let i = 1; i < length(parts) - 1; i++)
        if (parts[i] != "" && !match(parts[i], /^\*?\.?[A-Za-z0-9_-][A-Za-z0-9_.-]*$/))
            return false;
    return true;
}

function dnsmasq_default_values_are_managed() {
    return dnsmasq_default_has_forkop_dns() &&
        length(filter(additional_dnsmasq_servers(), server => !dnsmasq_server_is_scoped(server))) == 0 &&
        uci_get(DNSMASQ_DEFAULT + "noresolv") == "1" &&
        uci_get(DNSMASQ_DEFAULT + "cachesize") == "0";
}

function dnsmasq_default_config_is_complete() {
    return dnsmasq_snapshot_is_valid() && dnsmasq_default_values_are_managed() &&
        !dnsmasq_has_legacy_instance_state();
}

function snapshot_dnsmasq_server() {
    let current_path = "dhcp.@dnsmasq[0].server";
    let snapshot = snapshot_path("server");
    let present = uci_exists(current_path);

    uci_set(snapshot_path("server_present"), present ? "1" : "0");
    uci_delete(snapshot);
    uci_delete(snapshot_path("server_kind"));
    if (!present)
        return;

    let value = dnsmasq_option_value("server");
    if (type(value) == "array") {
        uci_set(snapshot_path("server_kind"), "list");
        for (let entry in value)
            uci_add_list(snapshot, entry);
        return;
    }

    uci_set(snapshot_path("server_kind"), "scalar");
    uci_set(snapshot, as_string(value));
}

function snapshot_field(key) {
    let path = "dhcp.@dnsmasq[0]." + key;
    let snapshot = snapshot_path(key);
    uci_set(snapshot_path(key + "_present"), uci_exists(path) ? "1" : "0");
    if (uci_exists(path))
        uci_set(snapshot, as_string(uci_get(path)));
    else
        uci_delete(snapshot);
}

function clear_dnsmasq_snapshot() {
    for (let key in SNAPSHOT_KEYS)
        uci_delete(snapshot_path(key));
}

function snapshot_dnsmasq_default_instance() {
    if (dnsmasq_snapshot_is_valid())
        return true;

    if (dnsmasq_snapshot_marker_present()) {
        log("Refusing to replace an invalid Forkop DNS transaction snapshot", "warn");
        return false;
    }

    snapshot_dnsmasq_server();
    snapshot_field("noresolv");
    snapshot_field("cachesize");
    let stamp = clock();
    uci_set(snapshot_path("transaction_id"), sprintf("%d-%d", stamp[0], stamp[1]));
    uci_set(snapshot_path("version"), SNAPSHOT_VERSION);
    return true;
}

function current_field_matches_forkop_value(key) {
    if (key == "server")
        return uci_get("dhcp.@dnsmasq[0].server") == SB_DNS_INBOUND_ADDRESS;
    if (key == "noresolv")
        return uci_get("dhcp.@dnsmasq[0].noresolv") == "1";
    if (key == "cachesize")
        return uci_get("dhcp.@dnsmasq[0].cachesize") == "0";
    return false;
}

function restore_snapshot_server() {
    let current_path = "dhcp.@dnsmasq[0].server";
    if (!dnsmasq_default_has_forkop_dns()) {
        log("DNS rollback conflict: dnsmasq server changed outside Forkop; preserving the external value", "warn");
        return false;
    }

    let additional = additional_dnsmasq_servers();
    let kind = uci_get(snapshot_path("server_kind"));
    let value = dnsmasq_option_value("forkop_dns_server");
    uci_delete(current_path);
    if (kind == "list" || length(additional)) {
        // In fixture mode UCI list values are serialized as whitespace-separated
        // text; on OpenWrt get_all() returns the original ordered array.
        let values = type(value) == "array" ? value :
            (kind == "scalar" && as_string(value) != "" ? [ value ] : words(value));
        for (let entry in additional)
            if (index(values, entry) < 0)
                push(values, entry);
        for (let entry in values)
            uci_add_list(current_path, entry);
    }
    else if (kind == "scalar") {
        uci_set(current_path, as_string(value));
    }
    return true;
}

function restore_snapshot_field(key) {
    let current_path = "dhcp.@dnsmasq[0]." + key;
    if (!current_field_matches_forkop_value(key)) {
        log("DNS rollback conflict: dnsmasq " + key + " changed outside Forkop; preserving the external value", "warn");
        return false;
    }

    if (uci_get(snapshot_path(key + "_present")) == "1")
        uci_set(current_path, as_string(uci_get(snapshot_path(key))));
    else
        uci_delete(current_path);
    return true;
}

function dnsmasq_cleanup_legacy_instance() {
    let legacy_instance_present = dnsmasq_legacy_instance_exists();
    let legacy_interfaces = legacy_instance_present ? dnsmasq_legacy_interfaces() : "";

    if (legacy_instance_present)
        uci_delete("dhcp.forkop");

    let backup_notinterfaces = uci_get("dhcp.@dnsmasq[0].forkop_notinterface");
    if (backup_notinterfaces != "") {
        uci_delete("dhcp.@dnsmasq[0].notinterface");
        for (let value in words(backup_notinterfaces))
            uci_add_list("dhcp.@dnsmasq[0].notinterface", value);
        uci_delete("dhcp.@dnsmasq[0].forkop_notinterface");
        return;
    }

    if (legacy_instance_present) {
        for (let value in words(legacy_interfaces))
            uci_del_list("dhcp.@dnsmasq[0].notinterface", value);
    }

    uci_delete("dhcp.@dnsmasq[0].forkop_notinterface");
}

function clear_legacy_dnsmasq_defaults() {
    for (let key in LEGACY_BACKUP_KEYS)
        uci_delete(DNSMASQ_DEFAULT + key);
}

function restore_legacy_dnsmasq_defaults() {
    let managed_server = dnsmasq_default_has_forkop_dns();
    let changed = managed_server;
    if (managed_server) {
        let servers = dnsmasq_option_value("forkop_server");
        servers = type(servers) == "array" ? servers : words(servers);
        for (let entry in additional_dnsmasq_servers())
            if (index(servers, entry) < 0)
                push(servers, entry);
        uci_delete(DNSMASQ_DEFAULT + "server");
        for (let server in servers)
            if (server != SB_DNS_INBOUND_ADDRESS)
                uci_add_list(DNSMASQ_DEFAULT + "server", server);
    }

    // The old format stored only options that had a value. Use its defaults
    // for missing options while the default instance is still Forkop-owned.
    for (let key, fallback in { noresolv: "0", cachesize: "150" }) {
        let value = uci_get(DNSMASQ_DEFAULT + "forkop_" + key);
        if (current_field_matches_forkop_value(key) && (value != "" || managed_server)) {
            uci_set(DNSMASQ_DEFAULT + key, value != "" ? value : fallback);
            changed = true;
        }
    }
    clear_legacy_dnsmasq_defaults();
    return changed;
}

function dnsmasq_configure_default_instance() {
    // The caller checked that a live snapshot still owns the default DNS
    // settings. Leave domain-specific servers added during that transaction.
    if (dnsmasq_snapshot_is_valid())
        return true;

    // Normalize a legacy backup in the same UCI commit that enables
    // forwarding, so the versioned backup captures the upstream settings.
    if (dnsmasq_has_legacy_defaults())
        restore_legacy_dnsmasq_defaults();
    if (!snapshot_dnsmasq_default_instance())
        return false;

    uci_delete("dhcp.@dnsmasq[0].server");
    uci_add_list("dhcp.@dnsmasq[0].server", SB_DNS_INBOUND_ADDRESS);
    uci_set("dhcp.@dnsmasq[0].noresolv", "1");
    uci_set("dhcp.@dnsmasq[0].cachesize", "0");
    return true;
}

function dnsmasq_restore_default_instance() {
    if (!dnsmasq_snapshot_is_valid())
        return false;

    let changed = restore_snapshot_server();
    for (let key in [ "noresolv", "cachesize" ])
        if (restore_snapshot_field(key))
            changed = true;

    // Consume the transaction even when an external component won a field.
    // This makes rollback idempotent and prevents a later retry from
    // overwriting an acknowledged external change.
    clear_dnsmasq_snapshot();
    return changed;
}

function dnsmasq_reload_state() {
    let main = uci.get_all("dhcp", "@dnsmasq[0]") || {};
    let fields = {};
    for (let key in [ "server", "noresolv", "cachesize", "notinterface", "forkop_notinterface",
        ...LEGACY_BACKUP_KEYS, ...map(SNAPSHOT_KEYS, key => "forkop_dns_" + key) ])
        fields[key] = main[key];
    return { name: main[".name"] || "@dnsmasq[0]", fields, legacy: uci.get_all("dhcp", "forkop") };
}

function same_uci_value(left, right) {
    return sprintf("%J", left) == sprintf("%J", right);
}

function recover_dnsmasq_reload(before, attempted) {
    if (!uci.reload("dhcp"))
        return false;
    let current = dnsmasq_reload_state();
    let restored = current.name == before.name;
    let updated = false;
    if (restored) {
        for (let key, value in before.fields) {
            if (same_uci_value(value, attempted.fields[key]) || same_uci_value(value, current.fields[key]))
                continue;
            if (!same_uci_value(attempted.fields[key], current.fields[key])) {
                log("Preserving a concurrent change to dnsmasq " + key, "warn");
                continue;
            }
            let path = "dhcp." + before.name + "." + key;
            if (!(value == null ? uci.delete(path) : uci.set(path, value)))
                restored = false;
            updated = true;
        }
    }
    if (before.legacy && !attempted.legacy && !current.legacy) {
        restored = uci.set_section("dhcp.forkop", before.legacy[".type"]) && restored;
        for (let key, value in before.legacy)
            if (substr(key, 0, 1) != ".")
                restored = uci.set("dhcp.forkop." + key, value) && restored;
        updated = true;
    }
    let saved = !updated || uci.commit("dhcp");
    let ready = restart_dnsmasq();
    return restored && saved && ready;
}

function finish_dnsmasq_change(restart, before, restore_pending) {
    let attempted = before ? dnsmasq_reload_state() : null;
    let saved = uci.commit("dhcp");
    if (saved && (!restart || restart_dnsmasq())) {
        fs.unlink(RESTORE_PENDING);
        return true;
    }
    if (before) {
        if (recover_dnsmasq_reload(before, attempted)) {
            if (restore_pending)
                fs.unlink(RESTORE_PENDING);
            log("Restored previous dnsmasq settings after failed reload", "warn");
        }
        else
            log("Could not fully restore dnsmasq after failed reload", "error");
    }
    return false;
}

function dnsmasq_configure(force, preserve_on_failure) {
    if (!uci_available())
        return true;

    if (dnsmasq_snapshot_marker_present() && !dnsmasq_snapshot_is_valid()) {
        log("Refusing to configure dnsmasq: invalid Forkop DNS transaction snapshot", "warn");
        return false;
    }

    if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "0") {
        if (dnsmasq_default_config_is_complete() && fs.stat(RESTORE_PENDING) == null) {
            log("Previous Forkop shutdown was unclean; dnsmasq already points to sing-box", "info");
            return true;
        }
        log("Previous Forkop shutdown was unclean and dnsmasq is not ready; applying Forkop DNS settings", "info");
    }

    if (dnsmasq_snapshot_is_valid() && !dnsmasq_default_values_are_managed()) {
        log("Refusing to configure dnsmasq: a previous Forkop DNS transaction conflicts with external changes", "warn");
        return false;
    }

    let before = preserve_on_failure ? dnsmasq_reload_state() : null;
    log("Configuring dnsmasq to forward DNS to sing-box", "info");
    dnsmasq_cleanup_legacy_instance();
    if (!dnsmasq_configure_default_instance())
        return false;
    return finish_dnsmasq_change(true, before);
}

function dnsmasq_restore(force, quiet, preserve_on_failure) {
    if (!uci_available())
        return true;

    if (!quiet)
        log("Restoring DNS settings in dnsmasq", "info");
    let has_marker = dnsmasq_snapshot_marker_present();
    let has_snapshot = dnsmasq_snapshot_is_valid();
    let has_legacy_instance = dnsmasq_has_legacy_instance_state();
    let has_legacy_defaults = dnsmasq_has_legacy_defaults();
    let pending = fs.stat(RESTORE_PENDING) != null;
    if (has_marker && !has_snapshot) {
        log("DNS rollback skipped: invalid Forkop dnsmasq transaction snapshot", "warn");
        return !dnsmasq_default_has_forkop_dns() && !pending;
    }
    if (!has_snapshot && !has_legacy_instance && !has_legacy_defaults) {
        if (pending) {
            if (!restart_dnsmasq())
                return false;
            return fs.unlink(RESTORE_PENDING) || fs.stat(RESTORE_PENDING) == null;
        }
        if (!quiet)
            log("dnsmasq already uses non-Forkop DNS settings; restore is not required", "info");
        return true;
    }
    if (as_string(force) != "force" && uci_get(CONFIG_NAME + ".settings.shutdown_correctly") == "1")
        log("Forkop DNS settings are still present after a clean shutdown; restoring DNS settings in dnsmasq", "info");

    // UCI can commit successfully while the dnsmasq reload fails. Retain a
    // retry obligation after the saved Forkop settings have been consumed.
    if (!pending && (system([ "mkdir", "-p", RUNTIME_STATE_DIR ]) != 0 ||
        fs.writefile(RESTORE_PENDING, "1\n") == null)) {
        log("Could not record the pending dnsmasq recovery", "error");
        return false;
    }
    let before = preserve_on_failure ? dnsmasq_reload_state() : null;
    let changed = has_legacy_instance || pending;
    if (has_legacy_instance)
        dnsmasq_cleanup_legacy_instance();
    if (has_snapshot)
        changed = dnsmasq_restore_default_instance() || changed;
    if (has_legacy_defaults) {
        // A prior upgrade could have saved the already-managed resolver in
        // the versioned backup. Complete that rollback using the old backup.
        if (!has_snapshot || dnsmasq_default_has_forkop_dns())
            changed = restore_legacy_dnsmasq_defaults() || changed;
        else
            clear_legacy_dnsmasq_defaults();
    }
    // Snapshot consumption itself must be durable, even if every field had an
    // external conflict and therefore no dnsmasq restart is necessary.
    return finish_dnsmasq_change(changed, before, !pending);
}

function failsafe_restore() {
    if (!uci_available())
        return true;

    if (!dnsmasq_has_forkop_managed_state() && !dnsmasq_snapshot_marker_present()) {
        log("DNS rollback skipped: no valid Forkop dnsmasq transaction was found", "info");
        return true;
    }

    log(dnsmasq_management_disabled() ?
        "Rolling back previous Forkop dnsmasq changes because dont_touch_dhcp is enabled" :
        "Rolling back Forkop DNS changes in dnsmasq", "warn");

    return dnsmasq_restore("force", true);
}

let mode = ARGV[0] || "";

if (mode == "configure")
    exit(dnsmasq_configure(ARGV[1], ARGV[2] == "reload") ? 0 : 1);
else if (mode == "restore")
    exit(dnsmasq_restore(ARGV[1], false, ARGV[2] == "reload") ? 0 : 1);
else if (mode == "failsafe-restore")
    exit(failsafe_restore() ? 0 : 1);
else if (mode == "has-forkop-dns" || mode == "has-managed-state")
    exit(dnsmasq_has_forkop_managed_state() ? 0 : 1);
else if (mode == "default-config-complete")
    exit(dnsmasq_default_config_is_complete() ? 0 : 1);

warn("Usage: dns/apply.uc <configure|restore|failsafe-restore|has-forkop-dns|has-managed-state|default-config-complete>\n");
exit(1);
