#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
TMP_DIR="$work"
sed -n '/^install_json_helper_path() {/,/^install_json_ucode() {/ { /^install_json_ucode() {/d; p; }' "$ROOT/install.sh" > "$work/functions.sh"
. "$work/functions.sh"
helper="$(install_json_helper_path)"
cat >"$work/catalog.json" <<'EOF'
{"schema":1,"name":"sing-box-x","version":"1.0.0","assets":[{"package":"sing-box-x","format":"ipk","architecture":"x86_64","name":"sing-box-x_1.0.0-2_x86_64.ipk","url":"https://mirror.51343.ru/forkop/sing-box-x/releases/1.0.0/sing-box-x_1.0.0-2_x86_64.ipk","sha256":"77a35e3f96b74439052b71ec14b9591204138f763e770acb51c3b2e6e6f27f15","size":9685283,"installed_size":9860489,"plain_binary_bytes":31133858}]}
EOF
ucode "$helper" core-package-plan sing-box-x x86_64 ipk https://mirror.51343.ru <"$work/catalog.json" >"$work/plan"
[ "$(cut -f4 "$work/plan")" = 9860489 ] || { echo 'UPX memory size used as flash size' >&2; exit 1; }
if ucode "$helper" core-package-plan sing-box-x mipsel_24kc ipk https://mirror.51343.ru <"$work/catalog.json"; then
  echo 'Unsupported architecture accepted' >&2; exit 1
fi
if ucode "$helper" core-package-plan sing-box-x x86_64 apk https://mirror.51343.ru <"$work/catalog.json"; then
  echo 'Wrong package format accepted' >&2; exit 1
fi
sed 's@https://mirror.51343.ru/forkop/sing-box-x/releases/@https://example.com/forkop/sing-box-x/releases/@' "$work/catalog.json" >"$work/wrong-source.json"
if ucode "$helper" core-package-plan sing-box-x x86_64 ipk https://mirror.51343.ru <"$work/wrong-source.json"; then
  echo 'Off-mirror package URL accepted' >&2; exit 1
fi
cat >"$work/rust-x.json" <<'EOF'
{"schema":1,"name":"rust-x","version":"0.0.26","package_revision":1,"assets":[{"package":"rust-x","format":"apk","architecture":"aarch64_cortex-a53","name":"rust-x_0.0.26-r1_aarch64_cortex-a53.apk","url":"https://mirror.51343.ru/forkop/rust-x/releases/0.0.26/rust-x_0.0.26-r1_aarch64_cortex-a53.apk","sha256":"04cae7029b984e2635eb45254f4d4d69285805e8ea34609f0b352df866c86ad3","size":4899361,"installed_size":10222963}]}
EOF
# OpenWrt APK reports aarch64 on filogic and accepts cortex-a53 packages.
ucode "$helper" core-package-plan rust-x aarch64 apk https://mirror.51343.ru <"$work/rust-x.json" >"$work/rust-plan"
[ "$(cut -f1 "$work/rust-plan")" = https://mirror.51343.ru/forkop/rust-x/releases/0.0.26/rust-x_0.0.26-r1_aarch64_cortex-a53.apk ] &&
  [ "$(cut -f3,4 "$work/rust-plan")" = "$(printf '4899361\t10222963')" ] || {
  echo 'Xrust catalog plan is wrong' >&2; exit 1
}
if ucode "$helper" core-package-plan sing-box-x aarch64 apk https://mirror.51343.ru <"$work/rust-x.json"; then
  echo 'Catalog of another core accepted' >&2; exit 1
fi
ucode "$helper" core-package-plan rust-x aarch64_cortex-a73 apk https://mirror.51343.ru <"$work/rust-x.json" >"$work/beam-plan"
cmp "$work/rust-plan" "$work/beam-plan"
for arch in arm_cortex-a7 mipsel_24kc x86_64; do
  if ucode "$helper" core-package-plan rust-x "$arch" apk https://mirror.51343.ru <"$work/rust-x.json"; then
    echo "ARM64 package accepted for $arch" >&2; exit 1
  fi
done
if ucode "$helper" core-package-plan rust-x aarch64_cortex-a73 ipk https://mirror.51343.ru <"$work/rust-x.json"; then
  echo 'APK fallback accepted for IPK' >&2; exit 1
fi
if ucode "$helper" core-package-plan sing-box aarch64 apk https://mirror.51343.ru <"$work/rust-x.json"; then
  echo 'Unknown core package accepted' >&2; exit 1
fi
echo 'Installer core catalogs and flash plan: OK'
sed -n '/^select_sing_box_for_release() {/,/^}/p' "$ROOT/install.sh" >"$work/release-choice.sh"
. "$work/release-choice.sh"
msg() { :; }
fail() { echo "$*" >&2; exit 1; }
choice() {
  SING_BOX_INSTALL_VARIANT="$1"
  FORKOP_RELEASE_TAG="$2"
  select_sing_box_for_release
  [ "$SING_BOX_INSTALL_VARIANT" = "$3" ] || { echo "$1 on $2 chose $SING_BOX_INSTALL_VARIANT, not $3" >&2; exit 1; }
}
choice rust-x 1.16.4 tiny
choice rust-x 2.0.0-canary.1 x
choice rust-x 2.1.9 x
choice rust-x 2.2.0-canary.1 rust-x
choice rust-x 2.4.4 rust-x
choice rust-x 3.0.0 rust-x
choice x 1.16.4 tiny
choice x 2.0.0-canary.1 x
choice "" 2.4.4 ""
echo 'Installer core choice by release: OK'
