#!/bin/sh
set -eu

SOURCE_LIB="${FORKOP_TEST_LIB:-/usr/lib/forkop}"
WORK_DIR="$(mktemp -d /tmp/forkop-worker-identity.XXXXXX)"
worker_pid=""
foreign_pid=""
cleanup() {
  [ -z "$worker_pid" ] || kill "$worker_pid" 2>/dev/null || true
  [ -z "$foreign_pid" ] || kill "$foreign_pid" 2>/dev/null || true
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$WORK_DIR/lib/core"
cp "$SOURCE_LIB/core/worker_identity.uc" "$WORK_DIR/lib/core/worker_identity.uc"
cat >"$WORK_DIR/worker.uc" <<'UCODE'
while (true) system("sleep 1");
UCODE
cat >"$WORK_DIR/check.uc" <<'UCODE'
let fs = require("fs");
let identity = require("core.worker_identity");
let base = ARGV[1];
// The pid file stays put while the library moves, so its directory is given apart.
let path = (ARGV[2] != null && ARGV[2] != "" ? ARGV[2] : base) + "/worker.pid";
let script = base + "/worker.uc";
let lib = base + "/lib";
if (ARGV[0] == "record") exit(identity.record_started(path, script, lib) ? 0 : 1);
if (ARGV[0] == "snapshot") {
    let pid = split(fs.readfile(path), "\n")[0];
    exit(identity.snapshot(pid, script, lib) != null ? 0 : 1);
}
if (ARGV[0] == "stop") exit(identity.stop(path, script, lib) ? 0 : 1);
exit(2);
UCODE
check() { ucode -L "$WORK_DIR/lib" "$WORK_DIR/check.uc" "$1" "$WORK_DIR"; }

ucode -L "$WORK_DIR/lib" "$WORK_DIR/worker.uc" worker >/dev/null 2>&1 &
worker_pid="$!"
printf '%s\n' "$worker_pid" >"$WORK_DIR/worker.pid"
check record
check snapshot

printf '%s\n%s\n' "$worker_pid" 999999 >"$WORK_DIR/worker.pid"
if check stop; then
  echo 'Worker with mismatched start time was stopped' >&2
  exit 1
fi
kill -0 "$worker_pid"
printf '%s\n' "$worker_pid" >"$WORK_DIR/worker.pid"
check stop
sleep 1
if kill -0 "$worker_pid" 2>/dev/null; then
  echo 'Owned worker was not stopped' >&2
  exit 1
fi
worker_pid=""

sleep 30 >/dev/null 2>&1 &
foreign_pid="$!"
printf '%s\n' "$foreign_pid" >"$WORK_DIR/worker.pid"
check stop
kill -0 "$foreign_pid"
kill "$foreign_pid" 2>/dev/null || true
foreign_pid=""

# The bytecode cache publishes every build under a new directory, so a worker started
# before a rebuild runs from a path the caller no longer computes. It must still be
# recognised and stopped, or it survives unreachable while a second copy is started.
mkdir -p "$WORK_DIR/moved/lib/core"
cp "$SOURCE_LIB/core/worker_identity.uc" "$WORK_DIR/moved/lib/core/worker_identity.uc"
cp "$WORK_DIR/worker.uc" "$WORK_DIR/moved/worker.uc"
cp "$WORK_DIR/check.uc" "$WORK_DIR/moved/check.uc"
ucode -L "$WORK_DIR/lib" "$WORK_DIR/worker.uc" worker >/dev/null 2>&1 &
worker_pid="$!"
printf '%s\n' "$worker_pid" >"$WORK_DIR/worker.pid"
check record
ucode -L "$WORK_DIR/moved/lib" "$WORK_DIR/moved/check.uc" stop "$WORK_DIR/moved" "$WORK_DIR"
sleep 1
if kill -0 "$worker_pid" 2>/dev/null; then
  echo 'Worker started from the previous library directory was left running' >&2
  exit 1
fi
if [ -e "$WORK_DIR/worker.pid" ]; then
  echo 'Stopped worker left its pid file behind' >&2
  exit 1
fi
worker_pid=""

# A record written before the identity was stored falls back to the caller's paths.
ucode -L "$WORK_DIR/lib" "$WORK_DIR/worker.uc" worker >/dev/null 2>&1 &
worker_pid="$!"
printf '%s\n' "$worker_pid" >"$WORK_DIR/worker.pid"
check record
head -2 "$WORK_DIR/worker.pid" >"$WORK_DIR/worker.pid.legacy"
mv "$WORK_DIR/worker.pid.legacy" "$WORK_DIR/worker.pid"
check stop
sleep 1
if kill -0 "$worker_pid" 2>/dev/null; then
  echo 'Worker with a two-line record was not stopped' >&2
  exit 1
fi
worker_pid=""

printf 'Worker identity checks passed\n'
