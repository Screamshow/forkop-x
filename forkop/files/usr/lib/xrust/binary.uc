let common = require("core.common");

const PATH = getenv("FORKOP_XRUST_BIN") || "/usr/bin/xrust";
const LEGACY_PATH = "/usr/lib/rust-x/sing-box";
const SERVICE_NAME = "forkop-xrust";
const INIT = getenv("FORKOP_XRUST_INIT") || "/etc/init.d/" + SERVICE_NAME;
const CONFIG_PATH = "/etc/xrust/config.json";
const STATE_DIR = getenv("FORKOP_RUNTIME_STATE_DIR") || "/var/run/forkop";
const APPLIED_CONFIG_PATH_FILE = STATE_DIR + "/xrust-config-path";

function build_version(version) {
    let value = common.as_string(version);
    return match(value, /^[0-9]+[.][0-9]+[.][0-9]+$/) == null ? "" : value;
}

function version_from_output(output) {
    let first = split(common.as_string(output), "\n")[0] || "";
    let parts = match(trim(first), /^xrust version ([0-9]+[.][0-9]+[.][0-9]+)$/);
    return parts == null ? "" : parts[1];
}

function legacy_version_from_output(output) {
    let first = split(common.as_string(output), "\n")[0] || "";
    let parts = match(trim(first), /^sing-box version v?[0-9]+[.][0-9]+[.][0-9]+-rust-x[.]([0-9]+[.][0-9]+[.][0-9]+)$/);
    return parts == null ? "" : parts[1];
}

function feature_list(output, label) {
    for (let line in split(common.as_string(output), "\n"))
        if (substr(line, 0, length(label)) == label)
            return filter(split(trim(substr(line, length(label))), /[ ,\t\r]+/), item => item != "");
    return [];
}

function has_feature(output, feature) {
    return index(feature_list(output, "Features:"), feature) >= 0;
}

function tailscale_supported(output) {
    return index(feature_list(output, "Tags:"), "with_tailscale") >= 0;
}

function exe_kind(path) {
    if (path == PATH)
        return "current";
    return path == PATH + " (deleted)" ? "deleted" : "other";
}

function is_legacy_exe(path) {
    return path == LEGACY_PATH || path == LEGACY_PATH + " (deleted)" ||
        path == "/usr/bin/sing-box" || path == "/usr/bin/sing-box (deleted)";
}

function is_proxy_cmdline(cmdline) {
    let mode = split(cmdline || "", chr(0))[1];
    // Inspect only the command position. Keep counting unknown modes and
    // invocations with leading configuration flags conservatively.
    return index([
        "tailscale-luci", "tailscale-native-capability", "tailscale-ssh-capability", "tailscale-exit-capability",
        "check", "version", "-v", "--version", "help", "-h", "--help",
        "rule-set", "reload-plan", "tools", "api", "generate", "format", "merge", "netns-holder"
    ], mode) < 0;
}

return { PATH, LEGACY_PATH, SERVICE_NAME, INIT, CONFIG_PATH, APPLIED_CONFIG_PATH_FILE,
    build_version, version_from_output, legacy_version_from_output,
    feature_list, has_feature, tailscale_supported, exe_kind, is_legacy_exe, is_proxy_cmdline };
