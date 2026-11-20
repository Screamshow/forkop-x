#!/bin/sh
# Run the production upgrade preflight against an isolated mirror and package fixture.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
ACTION="${1:-$ROOT/forkop/files/usr/lib/components/action.uc}"

{
    cat <<'UCODE'
const FORKOP_VERSION = "2.7.6";
const FORKOP_MIRROR_BASE_URL = "https://mirror.example.test";
let apk, installed, variant, revision, missing, bad_target, bad_rollback;
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
    for (let version in ["0.0.43", "0.0.44", "0.0.45"]) {
        let base = FORKOP_MIRROR_BASE_URL + "/forkop/rust-x/releases/" + version + "/";
        if (url != base + "manifest.json")
            continue;
        if (version == missing)
            return "";
        let format = apk ? "apk" : "ipk";
        let arch = "x86_64";
        let package_version = package_release_version(version, revision);
        let name = "rust-x_" + package_version + "_" + arch + "." + format;
        return sprintf("%J", {
            schema: 1, name: "rust-x", version, package_revision: revision,
            assets: [{
                package: "rust-x", architecture: arch, format, name, version: package_version,
                url: base + name, size: 1000,
                sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            }]
        });
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
function read_installed_package_version(name, reader) {
    let version = installed_package_version(name);
    return { state: version == "" ? "missing" : "found", version };
}
function sing_box_runtime_output(mode, args) {
    if (mode == "version")
        return variant == "rust-x" ? "1.14.2-rust-x." + split(installed, "-")[0] : "1.14.2";
    if (mode == "read-version-state")
        return "1.14.2-rust-x." + split(installed, "-")[0];
    assert(mode == "variant", mode);
    return variant;
}
function stage_sing_box_x_package(release, expected_version) {
    assert(release.version == expected_version, "stage received another revision");
    push(staged_versions, expected_version);
    if (bad_target)
        return null;
    return { name: "rust-x", path: "/tmp/target-" + release.name, version: expected_version };
}
function stage_previous_sing_box_package(previous_variant) {
    assert(previous_variant == "rust-x", previous_variant);
    push(staged_versions, installed);
    return bad_rollback ? null : { name: "rust-x", path: "/tmp/rollback-rust-x", version: installed };
}
function action_fail(component, action, message, current_version, latest_version) {
    assert(component == "forkop" && action == "install", "unexpected failure context");
    terminal = message;
    die(message);
}
UCODE
    sed -n '/^function rust_x_build_version(/,/^}/p;
        /^function resolve_sing_box_x_release(/,/^}/p;
        /^function forkop_release_requires_xrust(/,/^}/p;
        /^function check_forkop_xrust_requirement(/,/^}/p;
        /^function stage_forkop_xrust(/,/^}/p' "$ACTION"
    cat <<'UCODE'
function reset() {
    variant = "rust-x";
    installed = package_release_version("0.0.43", 1);
    revision = 2;
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
        if (forkop_release_requires_xrust(release_version)) {
            let previous = check_forkop_xrust_requirement(release_version);
            result = stage_forkop_xrust(target, previous, release_version);
        }
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
    let target = { xrust_version: "0.0.44" };
    let target_version = package_release_version("0.0.44", 2);

    for (let old_variant in ["stable", "x", "tiny", "extended", "extended-compressed", "not-installed"]) {
        reset();
        variant = old_variant;
        package_plan(target, "3.0.0", "Xrust");
        assert(length(mirror_reads) == 0 && length(staged_versions) == 0, "blocked core reached staging");
    }
    reset();
    installed = "";
    package_plan(target, "3.0.0", "Xrust");
    assert(length(mirror_reads) == 0, "unpackaged Xrust passed the gate");

    reset();
    variant = "x";
    package_plan({}, "2.7.6", "");
    assert(length(mirror_reads) == 0 && length(staged_versions) == 0, "legacy release changed the core");

    for (let current_build in ["0.0.43", "0.0.44", "0.0.45"]) {
        reset();
        installed = package_release_version(current_build, 1);
        let plan = package_plan(target, "3.0.0", "");
        assert(plan.target.version == target_version, "wrong Xrust pin for " + installed);
        assert(plan.rollback.version == installed, "previous core revision lost");
        assert(plan.rollback.version_state == "1.14.2-rust-x." + current_build, "previous core version state lost");
        assert(index(mirror_reads[0], "/releases/0.0.44/manifest.json") >= 0,
            "exact archive required instead of latest: " + join(", ", mirror_reads));
        assert(index(staged_versions, target_version) >= 0, "pin did not reach staging");
        assert(index(staged_versions, installed) >= 0, "rollback was not staged");
    }

    reset();
    installed = target_version;
    assert(package_plan(target, "3.0.0", "") == null, "exact installed core should need no package change");
    assert(length(staged_versions) == 0, "exact installed core redundantly staged");

    for (let bad_pin in [null, "", "latest", "../0.0.44", "0.0.44-r2", 44]) {
        reset();
        package_plan({ xrust_version: bad_pin }, "3.0.0", "Xrust");
        assert(length(mirror_reads) == 0 && length(staged_versions) == 0, "invalid pin reached lookup");
    }

    reset();
    missing = "0.0.44";
    package_plan(target, "3.0.0", "Xrust");
    assert(length(staged_versions) == 0, "missing pin reached staging");

    reset();
    bad_target = true;
    package_plan(target, "3.0.0", "Xrust");

    reset();
    bad_rollback = true;
    package_plan(target, "3.0.0", "rollback");
}
print("Forkop 3.x Xrust gate, exact archive/revision and rollback preflight (APK/IPK): OK\n");
UCODE
} | ucode -
