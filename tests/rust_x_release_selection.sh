#!/bin/sh
set -eu
# LuCI can install any Xrust release published in the mirror catalog
# /forkop/rust-x/releases.json; the package is chosen by architecture and
# format from the release assets.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT/forkop/files/usr/lib"
ACTION="$LIB/components/action.uc"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

M=https://mirror.51343.ru/forkop/rust-x/releases
H=04cae7029b984e2635eb45254f4d4d69285805e8ea34609f0b352df866c86ad3
asset() { # version revision arch format [url]
    printf '{"package":"rust-x","version":"%s-%s","architecture":"%s","format":"%s","name":"rust-x_%s-%s_%s.%s","size":4893243,"sha256":"%s","url":"%s"}' \
        "$1" "$2" "$3" "$4" "$1" "$2" "$3" "$4" "$H" "${5:-$M/$1/rust-x_$1-$2_$3.$4}"
}
release() { # version assets...
    version="$1"; shift
    printf '{"version":"%s","manifest_url":"%s/%s/manifest.json","assets":[%s]}' "$version" "$M" "$version" "$(IFS=,; echo "$*")"
}
{
    printf '{"schema":1,"name":"rust-x","releases":['
    release 0.0.26 "$(asset 0.0.26 1 aarch64_cortex-a53 ipk)" "$(asset 0.0.26 r1 aarch64_cortex-a53 apk)" "$(asset 0.0.26 r1 x86_64 apk)"
    printf ','
    release 0.0.25 "$(asset 0.0.25 1 aarch64_cortex-a53 ipk)" "$(asset 0.0.25 r1 x86_64 apk)"
    printf ','
    # Off-mirror package URL.
    release 0.0.24 "$(asset 0.0.24 1 aarch64_cortex-a53 ipk https://example.com/rust-x_0.0.24-1_aarch64_cortex-a53.ipk)"
    printf ','
    # Package of another release.
    release 0.0.23 "$(asset 0.0.22 1 aarch64_cortex-a53 ipk "$M/0.0.23/rust-x_0.0.22-1_aarch64_cortex-a53.ipk")"
    printf ',{"version":"0.0.22","manifest_url":"https://example.com/manifest.json","assets":[%s]}' "$(asset 0.0.22 1 aarch64_cortex-a53 ipk)"
    printf ','
    release 0.0.21 "$(asset 0.0.21 1 x86_64 ipk)"
    printf ',{"version":"../0.0.20"}]}'
} >"$work/releases.json"

select_releases() { # arch apk expected-versions
    ucode -e '
let fs = require("fs");
let source = fs.readfile(ARGV[0]);
function extract(name) {
    let start = index(source, "function " + name + "(");
    assert(start >= 0, name + " exists");
    let tail = substr(source, start);
    return substr(tail, 0, index(tail, "\n}") + 2);
}
let code = "const FORKOP_MIRROR_BASE_URL = \"https://mirror.51343.ru\";\n" +
    "function as_string(v) { return v == null ? \"\" : \"\" + v; }\n" +
    "const fixture = " + sprintf("%J", fs.readfile(ARGV[1])) + ";\n" +
    "function http_get(url) { if (url == FORKOP_MIRROR_BASE_URL + \"/forkop/rust-x/latest.json\") { let r = json(fixture).releases[0]; return sprintf(\"%J\", { schema: 1, name: \"rust-x\", version: r.version, package_revision: 1, assets: r.assets }); } assert(url == FORKOP_MIRROR_BASE_URL + \"/forkop/rust-x/releases.json\", url); return fixture; }\n" +
    "function parse_json_object(v) { try { let o = json(v); return type(o) == \"object\" ? o : {}; } catch (e) { return {}; } }\n" +
    "function read_openwrt_release_value(key) { return " + sprintf("%J", ARGV[2]) + "; }\n" +
    "function is_apk() { return " + (ARGV[3] == "1" ? "true" : "false") + "; }\n" +
    "function cleanup_tmp_dir() {}\n" +
    join("\n", map([ "resolve_sing_box_x_release", "rust_x_catalog_asset", "rust_x_release_catalog", "rust_x_releases", "selected_rust_x_release" ], extract)) + "\n" +
    "let versions = map(rust_x_release_catalog(), r => r.build_version);\n" +
    "let latest = resolve_sing_box_x_release(\"\", true); assert((latest != null) == (index(versions, \"0.0.26\") >= 0), \"latest catalog architecture\");\n" +
    "assert(join(\",\", versions) == " + sprintf("%J", ARGV[4]) + ", \"versions: \" + join(\",\", versions));\n" +
    "if (length(versions) > 0) {\n" +
    "  let r = selected_rust_x_release(versions[0]);\n" +
    "  assert(r.format == (is_apk() ? \"apk\" : \"ipk\") && r.version == versions[0] + (is_apk() ? \"-r1\" : \"-1\"), \"selected package\");\n" +
    "  assert(r.size == 4893243 && length(r.sha256) == 64 && index(r.url, \"https://mirror.51343.ru/forkop/rust-x/releases/\") == 0, \"package metadata\");\n" +
    "}\n" +
    "assert(selected_rust_x_release(\"0.0.24\") == null, \"off-mirror release selected\");\n" +
    "rust_x_releases();\n";
let path = "/tmp/forkop-rust-x-releases." + fs.readlink("/proc/self") + ".uc";
fs.writefile(path, code);
let status = system([ "ucode", path ]);
fs.unlink(path);
exit(status);
' "$ACTION" "$work/releases.json" "$1" "$2" "$3"
}
select_releases aarch64_cortex-a53 0 0.0.26,0.0.25 >"$work/ipk.json" || fail 'opkg filogic release selection'
select_releases aarch64 1 0.0.26 >"$work/apk.json" || fail 'APK filogic release selection'
select_releases aarch64_cortex-a73 1 0.0.26 >/dev/null || fail 'APK Beam release selection'
select_releases aarch64_cortex-a73 0 '' >/dev/null || fail 'IPK must not use APK architecture fallback'
select_releases x86_64 1 0.0.26,0.0.25 >/dev/null || fail 'APK x86_64 release selection'
select_releases mipsel_24kc 0 '' >"$work/none.json" || fail 'unsupported architecture'
ucode -e '
let r = json(require("fs").readfile(ARGV[0]));
assert(r.success === true && length(r.releases) == 2 && r.releases[0].version == "0.0.26" && r.releases[0].channel == "stable", "release list");
let none = json(require("fs").readfile(ARGV[1]));
assert(none.success === false && length(none.releases) == 0, "empty list is a failure");
' "$work/ipk.json" "$work/none.json" || fail 'rust_x_releases output'

# The exact version reaches the Xrust install, and only Xrust accepts one.
grep -Fq 'install_package_sing_box(action, false, false, true, version);' "$ACTION" ||
  fail 'install_rust_x does not receive the selected version'
grep -Fq 'selected_rust_x_release(requested_version)' "$ACTION" ||
  fail 'the selected version is not taken from the release catalog'
grep -Fq 'rust_x_releases: [ "components/action.uc", "rust-x-releases", 0 ]' "$ROOT/forkop/files/usr/bin/forkop" ||
  fail 'forkop rust_x_releases command is missing'
for args in 'sing_box install_x 0.0.25' 'sing_box install_rust_x 0.0' 'sing_box install 0.0.25' 'zapret install 0.0.25'; do
    # shellcheck disable=SC2086
    if FORKOP_LIB="$LIB" ucode -L "$LIB" "$LIB/components/updates.uc" component-action-async $args >"$work/async.json" 2>&1; then
        fail "version accepted for: $args"
    fi
    grep -Fq 'Invalid release selection' "$work/async.json" || fail "unexpected rejection for $args: $(cat "$work/async.json")"
done

echo 'Xrust release selection from the mirror catalog: OK'
