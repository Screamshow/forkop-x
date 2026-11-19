#!/usr/bin/env ucode

// Keep this worker outside sing-box.  procd can respawn a crashed sing-box,
// but an explicit stop or a permanently failing runtime otherwise leaves
// dnsmasq forwarding to an unavailable local DNS listener indefinitely.
let fs = require("fs");
let uci = require("core.uci");
let locks = require("core.locks");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const STATE_UC = LIB_DIR + "/service/state.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const INTERVAL_SECONDS = int(getenv("FORKOP_WATCHDOG_INTERVAL_SECONDS") || "5");
const GRACE_SECONDS = int(getenv("FORKOP_WATCHDOG_GRACE_SECONDS") || "90");
const FAILURE_SECONDS = int(getenv("FORKOP_WATCHDOG_FAILURE_SECONDS") || "60");
const WATCHDOG_READY_FILE = getenv("FORKOP_WATCHDOG_READY_FILE") ||
    (getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop") + "/watchdog.ready";

function quote(value) {
    return "'" + replace(value == null ? "" : "" + value, /'/g, "'\\''") + "'";
}

function status(args) {
    let command = [ "ucode", "-L", LIB_DIR, STATE_UC ];
    for (let arg in args)
        push(command, quote(arg));
    return system(join(" ", command) + " >/dev/null 2>&1") == 0;
}

function active() {
    return fs.stat(WATCHDOG_READY_FILE) != null &&
        uci.get(CONFIG_NAME + ".settings.shutdown_correctly") == "0";
}

function transitioning() {
    return locks.held(RELOAD_LOCK_DIR) ||
        system("ucode -L " + quote(LIB_DIR) + " " + quote(UI_UC) +
            " package-upgrade-transition-active >/dev/null 2>&1") == 0;
}

function singbox_healthy() {
    // This verifies the exact procd-owned runtime rather than accepting an
    // unrelated sing-box process with the same executable name.
    return status([ "sing-box-current-owned-service-runtime" ]);
}

function singbox_deleted_owned() {
    return status([ "sing-box-deleted-owned-service-runtime" ]);
}

function log(message, level) {
    system("logger -t forkop " + quote("[" + level + "] " + message) + " >/dev/null 2>&1");
}

function sleep_seconds(seconds) {
    system("sleep " + quote("" + seconds));
}

function main() {
    let started = int(clock()[0]);
    let failed_since = 0;
    let replacement_attempted = false;

    while (true) {
        let now = int(clock()[0]);

        // Forkop is intentionally stopped, or its own lifecycle currently
        // owns a transition.  Neither case is an outage for this watchdog.
        if (!active() || transitioning() || now - started < GRACE_SECONDS) {
            failed_since = 0;
        }
        else if (singbox_deleted_owned()) {
            failed_since = 0;
            if (!replacement_attempted) {
                replacement_attempted = true;
                log("replacing the verified procd-owned deleted sing-box runtime", "warn");
                if (system(quote(BIN_PATH) + " restart >/dev/null 2>&1") == 0 && singbox_healthy())
                    replacement_attempted = false;
            }
        }
        else if (singbox_healthy()) {
            failed_since = 0;
            replacement_attempted = false;
        }
        else {
            if (failed_since == 0) {
                failed_since = now;
                log("sing-box became unavailable; waiting " + FAILURE_SECONDS + " seconds before DNS rollback", "warn");
            }
            else if (now - failed_since >= FAILURE_SECONDS) {
                log("sing-box remained unavailable; stopping Forkop and restoring dnsmasq DNS", "fatal");
                system(quote(BIN_PATH) + " stop >/dev/null 2>&1");
                failed_since = 0;
            }
        }

        sleep_seconds(INTERVAL_SECONDS > 0 ? INTERVAL_SECONDS : 5);
    }
}

main();
