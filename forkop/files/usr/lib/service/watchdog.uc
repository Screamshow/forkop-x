#!/usr/bin/env ucode

// Keep this worker outside Xrust. procd can respawn a crashed core,
// but an explicit stop or a permanently failing runtime otherwise leaves
// dnsmasq forwarding to an unavailable local DNS listener indefinitely.
let fs = require("fs");
let uci = require("core.uci");
let locks = require("core.locks");

const LIB_DIR = getenv("FORKOP_LIB") || "/usr/lib/forkop";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const STATE_UC = getenv("FORKOP_SERVICE_STATE_UC") || LIB_DIR + "/service/state.uc";
const UI_UC = LIB_DIR + "/service/ui.uc";
const DIAGNOSTICS_UC = LIB_DIR + "/diagnostics/runtime.uc";
const RUNTIME_STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const RELOAD_LOCK_DIR = getenv("FORKOP_RELOAD_LOCK_DIR") || "/var/run/forkop.reload.lock";
const INTERVAL_SECONDS = int(getenv("FORKOP_WATCHDOG_INTERVAL_SECONDS") || "5");
const GRACE_SECONDS = int(getenv("FORKOP_WATCHDOG_GRACE_SECONDS") || "90");
const FAILURE_SECONDS = int(getenv("FORKOP_WATCHDOG_FAILURE_SECONDS") || "60");
const WATCHDOG_READY_FILE = getenv("FORKOP_WATCHDOG_READY_FILE") ||
    RUNTIME_STATE_DIR + "/watchdog.ready";
const PENDING_RELOAD_FILE = getenv("FORKOP_PENDING_RELOAD_FILE") || RUNTIME_STATE_DIR + "/reload.pending";
const POST_START_LATENCY_FILE = getenv("FORKOP_POST_START_LATENCY_FILE") || RUNTIME_STATE_DIR + "/post-start-latency.pending";
const AUTOMATIC_LATENCY_PENDING_FILE = getenv("FORKOP_AUTOMATIC_LATENCY_PENDING_FILE") ||
    "/etc/forkop/automatic-latency-test.pending";
const LATENCY_LOCK_DIR = getenv("FORKOP_AUTOMATIC_LATENCY_TEST_LOCK_DIR") || RUNTIME_STATE_DIR + "/automatic-latency-test.lock";

function quote(value) {
    return "'" + replace(value == null ? "" : "" + value, /'/g, "'\\''") + "'";
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

function xrust_runtime_kind() {
    let pipe = fs.popen("ucode -L " + quote(LIB_DIR) + " " + quote(STATE_UC) +
        " sing-box-owned-service-kind 2>/dev/null", "r");
    if (!pipe)
        return "other";
    let kind = trim(pipe.read("all") || "");
    return pipe.close() == 0 ? kind : "other";
}

function resume_due_latency_test(now) {
    let pending = fs.readfile(AUTOMATIC_LATENCY_PENDING_FILE);
    if (pending == null || fs.stat(PENDING_RELOAD_FILE) != null || fs.stat(POST_START_LATENCY_FILE) != null)
        return;

    let marker;
    try {
        marker = json(pending);
    }
    catch (e) {
        return;
    }
    if (type(marker) != "object" || "" + marker.format != "1" ||
        match("" + marker.signature, /^[0-9a-f]{32}$/) == null ||
        int(marker.retry_after || 0) > now ||
        locks.held(LATENCY_LOCK_DIR) || locks.held(LATENCY_LOCK_DIR + ".retry"))
        return;

    // The diagnostics worker rechecks the pending generation and takes the
    // shared latency and reload locks before sending any probes.
    system("ucode -L " + quote(LIB_DIR) + " " + quote(DIAGNOSTICS_UC) +
        " automatic-latency-test resume </dev/null >/dev/null 2>&1 &");
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
        let observing = active() && !transitioning() && now - started >= GRACE_SECONDS;
        let kind = observing ? xrust_runtime_kind() : "other";
        if (!observing) {
            failed_since = 0;
        }
        else if (kind == "deleted") {
            failed_since = 0;
            if (!replacement_attempted) {
                replacement_attempted = true;
                log("replacing the verified procd-owned deleted Xrust runtime", "warn");
                if (system(quote(BIN_PATH) + " restart >/dev/null 2>&1") == 0 && xrust_runtime_kind() == "current")
                    replacement_attempted = false;
            }
        }
        else if (kind == "current") {
            failed_since = 0;
            replacement_attempted = false;
            resume_due_latency_test(now);
        }
        else {
            if (failed_since == 0) {
                failed_since = now;
                log("Xrust became unavailable; waiting " + FAILURE_SECONDS + " seconds before DNS rollback", "warn");
            }
            else if (now - failed_since >= FAILURE_SECONDS) {
                log("Xrust remained unavailable; stopping Forkop and restoring dnsmasq DNS", "fatal");
                system(quote(BIN_PATH) + " stop >/dev/null 2>&1");
                failed_since = 0;
            }
        }

        sleep_seconds(INTERVAL_SECONDS > 0 ? INTERVAL_SECONDS : 5);
    }
}

main();
