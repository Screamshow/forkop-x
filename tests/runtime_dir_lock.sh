#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="${FORKOP_TEST_LIB:-$ROOT/forkop/files/usr/lib}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
state() { ucode -L "$LIB" "$LIB/service/state.uc" "$@"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
lock="$work/runtime.lock"

dead_pid=0
for candidate in 99991 99993 99997 99999; do
  if ! kill -0 "$candidate" 2>/dev/null; then
    dead_pid="$candidate"
    break
  fi
done
[ "$dead_pid" != 0 ] || fail 'no unused pid to test an abandoned lock with'

if state runtime-dir-lock-held "$lock"; then fail 'a lock that does not exist is reported as held'; fi
state acquire-runtime-dir-lock "$lock" "$$" || fail 'a free lock was not acquired'
[ "$(cat "$lock/pid")" = "$$" ] || fail 'the owner was not recorded'
state runtime-dir-lock-held "$lock" || fail 'a held lock is reported as free'

# The owner is alive, so nobody else may take the lock.
if state acquire-runtime-dir-lock "$lock" "$dead_pid"; then fail 'a live lock was taken over'; fi
[ "$(cat "$lock/pid")" = "$$" ] || fail 'a live lock lost its owner'

# The owner is gone: the lock is abandoned and may be taken over.
echo "$dead_pid" >"$lock/pid"
if state runtime-dir-lock-held "$lock"; then fail 'a lock whose owner is gone is reported as held'; fi
state acquire-runtime-dir-lock "$lock" "$$" || fail 'an abandoned lock was not taken over'
[ "$(cat "$lock/pid")" = "$$" ] || fail 'the new owner was not recorded'

# A lock is taken in two steps. A directory without an owner is one that was
# created moments ago, and taking it over would hand the same lock to two
# workers at once.
state release-runtime-dir-lock "$lock"
mkdir "$lock"
state runtime-dir-lock-held "$lock" || fail 'a lock that is still being taken is reported as free'
if state acquire-runtime-dir-lock "$lock" "$$"; then fail 'a lock that is still being taken was stolen'; fi
[ -d "$lock" ] || fail 'a lock that is still being taken was removed'
[ ! -f "$lock/pid" ] || fail 'the stolen lock recorded an owner'

# The same directory, old enough that no owner is coming, is abandoned.
touch -t 200001010000 "$lock"
if state runtime-dir-lock-held "$lock"; then fail 'an owner that never arrived keeps the lock held'; fi
state acquire-runtime-dir-lock "$lock" "$$" || fail 'a lock without an owner was never released'
[ "$(cat "$lock/pid")" = "$$" ] || fail 'the owner was not recorded after the takeover'

state release-runtime-dir-lock "$lock"
[ ! -e "$lock" ] || fail 'the released lock is still there'
leftovers="$(find "$work" -maxdepth 1 -name '*.abandoned.*' | wc -l)"
[ "$leftovers" = 0 ] || fail 'a replaced lock left its directory behind'

printf 'runtime dir lock tests passed\n'
