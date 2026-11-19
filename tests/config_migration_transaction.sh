#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
SCRIPT="$LIB/config/migration.uc"
UCI="$LIB/core/uci.uc"
FIXTURE=$(mktemp)
trap 'rm -f "$FIXTURE"' EXIT

{
    cat <<'UC'
const CONFIG_NAME = "forkop";
const UCI_CONFIG_DIR = "/unused";
let failure;
let committed;
let staged_url;
let staged_old;
let saved_url;
let saved_old;
let cached;
let commit_attempted;
function as_string(value) { return value == null ? "" : "" + value; }
function fixture_enabled() { return false; }
function load(package_name) { return failure != "load"; }
function resolve_parts(c, parts) { return parts; }
let fs = { stat: () => ({ type: "file" }) };
function cursor() {
    return {
        set: (pkg, section, option, value) => {
            if (section == "cfgImported" && option == "url") {
                if (failure == "set") return null;
                staged_url = value;
            }
            return true;
        },
        delete: (pkg, section, option) => {
            if (section == "test" && option == "subscription_urls") {
                if (failure == "delete") return null;
                staged_old = false;
            }
            return true;
        },
        commit: () => {
            commit_attempted = true;
            if (failure == "commit") return null;
            committed = true;
            saved_old = staged_old;
            saved_url = staged_url;
            return true;
        },
    };
}
function model_from_uci(cursor) {
    return {
        settings: { ".name": "settings", ".type": "settings" },
        rules: [],
        sections: [{ ".name": "test", ".type": "section", action: "connection",
            subscription_urls: [ "https://source.invalid/feed" ] }],
        subscription_url: [], urltest: [], section_interface: [],
    };
}
function migrate_model(model, source) {
    let ctx = require("config.migration").migrate_podkop_model(model, {});
    ctx.removed_caches = ["test-cache"];
    return ctx;
}
function mark_internal_config_guard() { assert(committed); }
function ensure_runtime_cache_format() { assert(committed, "cache format must follow commit"); }
function remove_legacy_server_country_cache() { assert(committed); }
function remove_retired_byedpi_state() { assert(committed); }
function remove_retired_zapret_state() { assert(committed); }
function remove_cache_path(path) { assert(committed && path == "test-cache"); cached = false; }
UC
    sed -n '/^function path_parts(/,/^}/p; /^function delete_path(/,/^}/p; /^function set_section(/,/^}/p;
            /^function set(/,/^}/p; /^function commit(/,/^}/p' "$UCI"
    cat <<'UC'
let uci_core = {
    load, add: () => failure == "add" ? "" : "cfgImported",
    set, set_section, delete: delete_path, commit,
};
UC
    sed -n '/^function apply_operations(/,/^}/p; /^function runtime_cursor(/,/^}/p;
            /^function commit_cursor(/,/^}/p; /^function migrate_runtime(/,/^}/p' "$SCRIPT"
    cat <<'UC'
for (let phase in ["load", "add", "set", "delete", "commit", ""]) {
    failure = phase;
    committed = commit_attempted = false;
    staged_old = saved_old = cached = true;
    staged_url = saved_url = "";
    if (phase != "") {
        assert(!migrate_runtime("podkop"), "failed migration reported success: " + phase);
        assert(saved_old && saved_url == "" && cached && !committed, "old state lost: " + phase);
        assert(commit_attempted == (phase == "commit"), "unexpected commit attempt: " + phase);
    } else {
        assert(migrate_runtime("podkop") && committed && !cached);
        assert(!saved_old && saved_url == "https://source.invalid/feed");
    }
}
print("PASS: failed migration preserves saved settings and cache; successful migration commits before cleanup\n");
UC
} >"$FIXTURE"
ucode -L "$LIB" "$FIXTURE"
