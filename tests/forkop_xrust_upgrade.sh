#!/bin/sh
# Run the production upgrade preflight against an isolated mirror and package fixture.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="${1:-$ROOT/forkop/files/usr/lib/components/action.uc}"
LIB="${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}"

{
    cat <<'UCODE'
const FORKOP_VERSION = "3.0.0";
const FORKOP_MIRROR_BASE_URL = "https://mirror.example.test";
const XRUST_BINARY = "/usr/bin/xrust", LEGACY_XRUST_RELEASE = "0.0.44";
let xrust = require("xrust.binary");
let apk, installed, binary_version, revision, missing, bad_target, bad_rollback;
let mirror_reads, staged_versions, terminal;

function as_string(value) { return value == null ? "" : "" + value; }
function is_apk() { return apk; }
function read_openwrt_release_value(key) {
    assert(key == "DISTRIB_ARCH", key);
    return "x86_64";
}
function package_release_version(version, rev) {
    return version + (apk ? "-r" : "-") + rev;
}
function http_get(url) {
    push(mirror_reads, url);
    for (let version in ["0.0.44", "0.0.45", "0.0.46"]) {
        let base = FORKOP_MIRROR_BASE_URL + "/forkop/rust-x/releases/" + version + "/";
        if (url != base + "manifest.json")
            continue;
        if (version == missing)
            return "";
        let format = apk ? "apk" : "ipk";
        let arch = "x86_64";
        let package_version = package_release_version(version, revision);
        let name = "rust-x_" + package_version + "_" + arch + "." + format;
        let catalog = {
            schema: 1, name: "rust-x", version, package_revision: revision,
            assets: [{
                package: "rust-x", architecture: arch, format, name, version: package_version,
                url: base + name, size: 1000,
                sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }]
        };
        if (version != LEGACY_XRUST_RELEASE)
            catalog.minimum_forkop_major = 3;
        return sprintf("%J", catalog);
    }
    die("Unexpected Xrust mirror request: " + url);
}
function parse_json_object(value) {
    try { return json(value); } catch (e) { return {}; }
}
function installed_package_version(name) {
    assert(name == "rust-x", name);
    return installed;
}
function file_exists(path) { return path == XRUST_BINARY; }
function command_output_from_args(args) {
    assert(args[0] == XRUST_BINARY && args[1] == "version", "unexpected version probe");
    return binary_version;
}
function stage_xrust_package(release, expected_version) {
    if (release == null || release.version != expected_version)
        return null;
    push(staged_versions, expected_version);
    if ((expected_version == installed && bad_rollback) || (expected_version != installed && bad_target))
        return null;
    return { name: "rust-x", path: "/tmp/" + release.name, version: expected_version };
}
function action_fail(component, action, message, current_version, latest_version) {
    assert(component == "forkop" && action == "install", "unexpected failure context");
    terminal = message;
    die(message);
}
UCODE
    sed -n '/^function installed_xrust_build(/,/^}/p;
        /^function resolve_xrust_release(/,/^}/p;
        /^function forkop_release_requires_xrust(/,/^}/p;
        /^function valid_xrust_pin(/,/^}/p;
        /^function check_forkop_xrust_requirement(/,/^}/p;
        /^function stage_forkop_xrust(/,/^}/p' "$ACTION"
    cat <<'UCODE'
function reset(build) {
    build = build || "0.0.46";
    revision = 2;
    installed = package_release_version(build, revision);
    binary_version = "xrust version " + build + "\n";
    missing = "";
    bad_target = false;
    bad_rollback = false;
    mirror_reads = [];
    staged_versions = [];
    terminal = "";
}

function package_plan(target, release_version, expected) {
    let result;
    try {
        let previous = check_forkop_xrust_requirement(release_version);
        result = stage_forkop_xrust(target, previous, release_version);
    }
    catch (e) {
        assert(terminal != "", e.message);
    }
    if (expected == "")
        assert(terminal == "", terminal);
    else
        assert(index(lc(terminal), lc(expected)) >= 0, "Unexpected rejection: " + terminal);
    return result;
}

assert(!forkop_release_requires_xrust("2.7.6"), "2.x stays on its existing installer");
assert(!forkop_release_requires_xrust("2.7.6-canary.1"), "2.x canary stays on its existing installer");
assert(forkop_release_requires_xrust("3.0.0"), "3.x requires Xrust");
assert(forkop_release_requires_xrust("3.0.0-canary.1"), "3.x canary requires Xrust");

for (apk in [false, true]) {
    let target = { xrust_version: "0.0.45" };
    let target_version = package_release_version("0.0.45", 2);

    for (let invalid_banner in ["", "sing-box version 1.14.2", "sing-box version 1.14.2-rust-x.0.0.46", "xrust version 0.0.99"]) {
        reset();
        binary_version = invalid_banner;
        package_plan(target, "3.0.0", "Xrust");
        assert(length(mirror_reads) == 0 && length(staged_versions) == 0, "blocked core reached staging");
    }
    reset();
    installed = "";
    package_plan(target, "3.0.0", "Xrust");
    assert(length(mirror_reads) == 0, "unpackaged Xrust passed the gate");

    reset();
    let legacy = package_plan({}, "2.7.6", "");
    assert(legacy.legacy && legacy.target.version == package_release_version(LEGACY_XRUST_RELEASE, revision),
        "rollback to 2.7.6 must install the legacy archive");
    assert(legacy.rollback.version == installed, "downgrade must stage native recovery");

    reset();
    let plan = package_plan(target, "3.0.0", "");
    assert(!plan.legacy && plan.target.version == target_version, "wrong native pin");
    assert(plan.rollback.version == installed, "previous core revision lost");
    assert(index(mirror_reads[0], "/releases/0.0.45/manifest.json") >= 0,
        "exact archive required instead of latest: " + join(", ", mirror_reads));

    reset("0.0.45");
    assert(package_plan(target, "3.0.0", "") == null, "exact installed core should need no package change");
    assert(length(staged_versions) == 0, "exact installed core redundantly staged");

    for (let bad_pin in [null, "", "latest", "0.0.45-r2", 45]) {
        reset();
        package_plan({ xrust_version: bad_pin }, "3.0.0", "Xrust");
        assert(length(mirror_reads) == 0 && length(staged_versions) == 0, "invalid pin reached lookup");
    }

    reset();
    missing = "0.0.45";
    package_plan(target, "3.0.0", "Xrust");
    assert(length(staged_versions) == 0, "missing pin reached staging");

    reset();
    bad_target = true;
    package_plan(target, "3.0.0", "Xrust");

    reset();
    bad_rollback = true;
    package_plan(target, "3.0.0", "rollback");

    reset();
    installed = package_release_version("0.0.46", 1);
    package_plan(target, "3.0.0", "rollback");

    reset();
    package_plan({ xrust_version: LEGACY_XRUST_RELEASE }, "3.0.0", "incompatible");
    assert(length(staged_versions) == 0, "legacy pin reached package staging");
}
print("Forkop 3.x Xrust gate, exact archive/revision and rollback preflight (APK/IPK): OK\n");
UCODE
} | ucode -L "$LIB" -
