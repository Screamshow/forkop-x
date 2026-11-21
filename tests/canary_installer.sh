#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work=$(mktemp -d /tmp/forkop-canary-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/curl" <<'EOF'
#!/bin/sh
set -eu
[ "${FAIL_DOWNLOAD:-0}" = 0 ] || exit 22
for arg in "$@"; do
    case "$arg" in
        https://test.invalid/forkop/install.sh) correct_url=1 ;;
    esac
done
[ "${correct_url:-0}" = 1 ]
while [ "$1" != -o ]; do shift; done
cp "$INSTALLER_STUB" "$2"
EOF
cat > "$work/installer" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$TEST_RESULT"
exit "${INSTALLER_STATUS:-0}"
EOF
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH" INSTALLER_STUB="$work/installer" TEST_RESULT="$work/result"
export FORKOP_MIRROR_BASE_URL=https://test.invalid
sh "$ROOT/canary-install.sh" --help
printf '%s\n' --channel canary --help > "$work/expected"
cmp "$work/expected" "$TEST_RESULT"
FORKOP_MIRROR_BASE_URL=https://test.invalid/ sh "$ROOT/canary-install.sh" --help
cmp "$work/expected" "$TEST_RESULT"
INSTALLER_STATUS=7 sh "$ROOT/canary-install.sh" --help && exit 1 || [ "$?" = 7 ]
rm "$TEST_RESULT"
FAIL_DOWNLOAD=1 sh "$ROOT/canary-install.sh" --help && exit 1 || [ "$?" = 22 ]
[ ! -e "$TEST_RESULT" ]
echo 'Canary installer channel, argument forwarding and failure handling passed'
