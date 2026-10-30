#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${FORKOP_ACTION_SOURCE:-$ROOT/forkop/files/usr/lib/components/action.uc}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for name in ipk_provides installed_dependency_name staged_package_by_name stage_repository_package; do
    sed -n "/^function $name(/,/^}/p" "$SOURCE" >> "$work/test.uc"
done
cat >> "$work/test.uc" <<'UCODE'
function as_string(v) { return v == null ? "" : "" + v; }
function is_apk() { return false; }
function pkg_is_installed(name) { return name == "libc" || name == "libgcc1"; }
let status = "Package: libgcc1\nVersion: 13.3\nProvides: libgcc\nStatus: install ok installed\n\n";
let fs = { readfile: function(path) { return status; } };
function check(ok, label) { if (!ok) { warn(label + "\n"); exit(1); } }
check(ipk_provides("other, libgcc (= 13.3)", "libgcc"), "versioned provides");
check(!ipk_provides("libgcc1", "libgcc"), "no prefix match");
check(installed_dependency_name("libgcc") == "libgcc1", "installed provider");
check(installed_dependency_name("libc") == "libc", "direct dependency");
status = replace(status, "install ok installed", "deinstall ok not-installed");
check(installed_dependency_name("libgcc") == "libgcc", "removed provider rejected");
let tmp_dir = "/tmp/fixture";
let actual = "libgcc1", provides = "libgcc";
function staged_package_field(path, field) { return field == "name" ? actual : provides; }
function staged_package_info(path, name, version) { return name == actual && version == "" ? { name, path } : null; }
function ensure_repository_indexes() { return true; }
function command_from_args(args) { return join(" ", args); }
function shell_quote(s) { return s; }
function limited_download_command(s) { return s; }
function run_logged(label, command) { return true; }
function command_output(command) {
    check(index(command, "*.ipk") >= 0, "search real archive names");
    return "/tmp/fixture/libgcc1_13.3.ipk";
}
function stage_archived_sing_box_package(name, version) { return null; }
check(stage_repository_package("libgcc", "").name == "libgcc1", "downloaded provider accepted");
check(stage_repository_package("libgcc", "13.3") == null, "exact rollback identity preserved");
provides = "unrelated";
check(stage_repository_package("libgcc", "") == null, "unrelated package rejected");
actual = "libgcc";
check(stage_repository_package("libgcc", "").name == "libgcc", "ordinary package accepted");
provides = "libgcc"; actual = "libgcc1";
check(staged_package_by_name([{name: actual, path: "test"}], "libgcc") != null, "staged provider reused");
print("PASS: IPK virtual dependencies, installed providers and exact rollback identity\n");
UCODE
# Define fixture dependencies before loading the functions under test (ucode lexical scope).
sed '/^check(/d; /^status = replace/d; /^provides = /d; /^actual = /d; /^print(/d' "$work/test.uc" | sed '/^function ipk_provides(/,/^}/d; /^function installed_dependency_name(/,/^}/d; /^function staged_package_by_name(/,/^}/d; /^function stage_repository_package(/,/^}/d' > "$work/ordered.uc"
for name in ipk_provides installed_dependency_name staged_package_by_name stage_repository_package; do
    sed -n "/^function $name(/,/^}/p" "$SOURCE" >> "$work/ordered.uc"
done
sed -n '/^check(/p; /^status = replace/p; /^provides = /p; /^actual = /p; /^print(/p' "$work/test.uc" >> "$work/ordered.uc"
ucode "$work/ordered.uc"
