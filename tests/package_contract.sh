#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_MAKEFILE="$ROOT_DIR/forkop/Makefile"
FORKOP_CONFIG="$ROOT_DIR/forkop/files/etc/config/forkop"
BUILD_SCRIPT="$ROOT_DIR/build.sh"
BUILD_WORKFLOW="$ROOT_DIR/.github/workflows/build.yml"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_file() {
  local file="$1"

  [ -r "$file" ] || fail "required file is missing: $file"
}

require_make_dep() {
  local package="$1"

  grep -Eq "DEPENDS:=.*(^|[[:space:]])\\+$package([[:space:]]|$)" "$FORKOP_MAKEFILE" ||
    fail "forkop/Makefile DEPENDS is missing +$package"
}

require_build_dep() {
  local variable="$1"
  local package="$2"

  grep -Eq "^${variable}=.*(^|[[:space:],])${package}([[:space:],\"]|$)" "$BUILD_SCRIPT" ||
    fail "build.sh ${variable} is missing $package"
}

require_package_dependency() {
  local package="$1"

  require_make_dep "$package"
  require_build_dep "BACKEND_DEPENDS_IPK" "$package"
  require_build_dep "BACKEND_DEPENDS_APK" "$package"
}

require_file "$FORKOP_MAKEFILE"
require_file "$FORKOP_CONFIG"
require_file "$BUILD_SCRIPT"
require_file "$BUILD_WORKFLOW"
require_file "$FORKOP_LIB"

bash "$BUILD_SCRIPT" --help >/dev/null ||
  fail "build.sh must provide command-line usage"
if bash "$BUILD_SCRIPT" 1.2 >/dev/null 2>&1; then
  fail "build.sh must reject invalid release versions before building"
fi
if grep -Eq 'WSL_|WINDOWS_ARTIFACTS_DIR|SOURCE_ROOT_DIR|\.wsl-build|apt-get|sudo' "$BUILD_SCRIPT"; then
  fail "build.sh must remain a portable unprivileged Linux build entrypoint"
fi
grep -Fq 'SDK_DIR="${SDK_DIR:-$SDK_CACHE_DIR/extracted}"' "$BUILD_SCRIPT" ||
  fail "build.sh must reuse the prepared SDK cache independently of BUILD_DIR"
grep -Fq 'flock -n 9' "$BUILD_SCRIPT" ||
  fail "build.sh must reject concurrent package builds"
grep -Fq '[[ ! -f "$luci_src_dir/po2lmo.c" ]]' "$BUILD_SCRIPT" ||
  fail "build.sh must recover from an interrupted LuCI feed checkout"
[ "$(grep -Fc 'fakeroot sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use fakeroot for IPK ownership"
[ "$(grep -Fc 'unshare -r sh -c' "$BUILD_SCRIPT")" -eq 1 ] ||
  fail "build.sh must use a user namespace for APK ownership"
grep -Fq 'sudo apt-get install -y' "$BUILD_WORKFLOW" ||
  fail "build workflow must own host dependency installation"
grep -Fq 'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0' "$BUILD_WORKFLOW" ||
  fail "Ubuntu 24.04 build workflow must allow unprivileged user namespaces"
grep -Fq './build.sh "$VERSION"' "$BUILD_WORKFLOW" ||
  fail "build workflow must invoke the public build entrypoint"
grep -Fq "replace('\\\\n', '\\n')" "$BUILD_WORKFLOW" ||
  fail "build workflow must normalize escaped release-note line breaks"
grep -Fq 'body: ${{ needs.preparation.outputs.release_notes }}' "$BUILD_WORKFLOW" ||
  fail "release action must receive normalized Markdown notes"

for conflict in https-dns-proxy nextdns luci-app-passwall luci-app-passwall2; do
  grep -E 'CONFLICTS:=' "$FORKOP_MAKEFILE" | grep -Fq "$conflict" ||
    fail "forkop/Makefile conflicts are missing $conflict"
  grep -E '^BACKEND_CONFLICTS_IPK=' "$BUILD_SCRIPT" | grep -Fq "$conflict" ||
    fail "manual IPK conflicts are missing $conflict"
  grep -E '^BACKEND_DEPENDS_APK=' "$BUILD_SCRIPT" | grep -Fq "!$conflict" ||
    fail "manual APK conflicts are missing $conflict"
done

if grep -Fq 'coreutils-sort' "$FORKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "unused coreutils-sort runtime dependency must not be packaged"
fi

if grep -Fq 'kmod-netlink-diag' "$FORKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "unused and firmware-specific kmod-netlink-diag dependency must not be packaged"
fi

require_package_dependency "nftables-json"
# OpenWrt BusyBox ships the flock applet. A separate flock package made
# upgrades from releases without it download a dependency mid-upgrade.
if grep -Eq '(^|[[:space:],+])flock([[:space:],"]|$)' "$FORKOP_MAKEFILE" ||
  grep -E '^BACKEND_DEPENDS_(IPK|APK)=' "$BUILD_SCRIPT" | grep -Eq '(^|[[:space:],"])flock([[:space:],"]|$)'; then
  fail "flock is provided by BusyBox and must not be a package dependency"
fi
if grep -Eq '(^|[[:space:],+])nftables([[:space:],]|$)' "$FORKOP_MAKEFILE" "$BUILD_SCRIPT"; then
  fail "Forkop must depend on the concrete nftables-json provider, not the nftables virtual package"
fi
grep -Fq "command_exists(\"nft\")" "$ROOT_DIR/forkop/files/usr/lib/config/validator.uc" ||
  fail "runtime validation must reject a missing nft executable before applying rules"

grep -Fq "x.y.z or x.y.z-canary.N format" "$FORKOP_MAKEFILE" ||
  fail "forkop/Makefile must enforce stable and canary release version formats"
grep -Fq 'APK_INTERNAL_VERSION="${BASH_REMATCH[1]}_rc${BASH_REMATCH[2]}"' "$BUILD_SCRIPT" ||
  fail "build.sh must normalize canary APK versions to an APK-compatible revision"
grep -Fq "option component_update_check_enabled '1'" "$FORKOP_CONFIG" ||
  fail "new installations must enable component update checks by default"
grep -Fq "option config_version '1.0.5'" "$FORKOP_CONFIG" ||
  fail "new installations must start at the current configuration schema version"
grep -Fq "list applied_migrations 'interface_sections'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the interface section migration as applied"
grep -Fq "list applied_migrations 'enable_component_checks'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the component check migration as applied"
grep -Fq "list applied_migrations 'http_connection_urls'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the HTTP connection URL migration as applied"
grep -Fq "list applied_migrations 'flintnet_urltest_default'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the Flintnet URLTest migration as applied"
grep -Fq "list applied_migrations 'retired_secondary_rulesets'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the retired secondary rule set migration as applied"
grep -Fq "list applied_migrations 'secondary_rulesets_mirror_v1'" "$FORKOP_CONFIG" ||
  fail "new installations must mark the secondary rule set mirror migration as applied"
grep -Fq '/usr/lib/forkop/config/migration.uc migrate' "$FORKOP_MAKEFILE" ||
  fail "OpenWrt package postinst must run configuration migrations"
[ "$(grep -Fc '/usr/lib/forkop/config/migration.uc migrate' "$BUILD_SCRIPT")" -ge 3 ] ||
  fail "manual IPK/APK package scripts must run configuration migrations after install and upgrade"

(
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  source <(sed -n '/^write_backend_preinst() {/,/^}/p' "$BUILD_SCRIPT")
  write_backend_preinst | sed "s@/usr/bin/xrust@$work/xrust@g; s@/etc/rc.d/S98forkop-upgrade-recovery@$work/recover@g" > "$work/preinst"
  if sh "$work/preinst" > "$work/log" 2>&1; then
    fail "native Forkop package must refuse uncoordinated installation on a legacy core"
  fi
  grep -Fq 'Run the official Forkop installer' "$work/log" || fail "missing installer guidance"
  IPKG_INSTROOT="$work/offline" sh "$work/preinst"
  ln -s "$work/journal" "$work/recover"
  sh "$work/preinst"
  rm "$work/recover"
  printf '#!/bin/sh\nprintf "xrust version 0.0.45\\nFeatures: fixture\\n"\n' > "$work/xrust"
  chmod 700 "$work/xrust"
  sh "$work/preinst"
)

if grep -Rqs 'require("uci")' "$FORKOP_LIB"; then
  require_package_dependency "ucode-mod-uci"
fi

if grep -Rqs 'require("fs")' "$FORKOP_LIB"; then
  require_package_dependency "ucode-mod-fs"
fi

if grep -Rqs 'forkop_dnsmasq_failsafe_restore_raw' \
  "$ROOT_DIR/forkop/files/usr/bin" \
  "$ROOT_DIR/forkop/files/usr/lib" \
  "$ROOT_DIR/forkop/files/etc/init.d"; then
  fail "duplicated raw dnsmasq failsafe restore shell owner is present"
fi

printf 'package contract checks passed\n'
