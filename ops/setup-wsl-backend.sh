#!/usr/bin/env bash
set -euo pipefail

UCODE_VERSION="v0.0.20250529"
LOCAL_PREFIX="${FORKOP_WSL_PREFIX:-$HOME/.local}"
export PATH="$LOCAL_PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if ! ucode -e 'require("fs");' >/dev/null 2>&1; then
  for command_name in cmake cc git pkg-config; do
    command -v "$command_name" >/dev/null 2>&1 || {
      printf 'Missing required command: %s\n' "$command_name" >&2
      exit 1
    }
  done
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  git clone --depth 1 --branch "$UCODE_VERSION" https://github.com/jow-/ucode.git "$work_dir/ucode"
  # Optional OpenWrt modules are enabled automatically when their development
  # libraries are available in the prefix or system paths.
  cmake -S "$work_dir/ucode" -B "$work_dir/ucode/build" \
    -DCMAKE_INSTALL_PREFIX="$LOCAL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$LOCAL_PREFIX"
  cmake --build "$work_dir/ucode/build" --parallel
  cmake --install "$work_dir/ucode/build"
  hash -r
fi

ucode -e 'require("fs"); print("ucode with fs: ready\n")'
for module in uci ubus; do
  if ucode -e "require(\"$module\");" >/dev/null 2>&1; then
    printf 'ucode %s module: ready\n' "$module"
  else
    printf 'ucode %s module: unavailable\n' "$module"
  fi
done

core="${FORKOP_XRUST_BIN:-$(command -v xrust || true)}"
if [[ -n "$core" ]] && core_version=$("$core" version 2>/dev/null) &&
   [[ "$core_version" == 'xrust version '* ]]; then
  printf '%s\n' "${core_version%%$'\n'*}"
else
  printf 'Native Xrust fixtures require a verified xrust binary in PATH or FORKOP_XRUST_BIN.\n'
fi
