#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="${FORKOP_TEST_LIB:-$ROOT/forkop/files/usr/lib}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
lock="$work/runtime.lock"

cat >"$work/lock.uc" <<'HARNESS'
let locks = require("core.locks");
let mode = ARGV[0];
if (mode == "held")
    exit(locks.held(ARGV[1]) ? 0 : 1);
else if (mode == "acquire")
    exit(locks.acquire(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "release")
    locks.release(ARGV[1]);
else
    exit(2);
HARNESS

lock_op() { ucode -L "$LIB" "$work/lock.uc" "$@"; }

dead_pid=0
for candidate in 99991 99993 99997 99999; do
  if ! kill -0 "$candidate" 2>/dev/null; then
    dead_pid="$candidate"
    break
  fi
done
[ "$dead_pid" != 0 ] || fail 'no unused pid to test an abandoned lock with'

if lock_op held "$lock"; then fail 'a lock that does not exist is reported as held'; fi

# Recording the owner is the one step of taking a lock that runs a shell, so a
# shell that refuses makes it fail with the directory already created. That path
# has to give the lock back and answer no, not abort the caller: a reload or a
# latency test that dies here leaves the directory behind for the grace window
# and reports nothing at all.
mkdir -p "$work/noshell"
printf '#!/bin/sh\nexit 1\n' >"$work/noshell/sh"
chmod +x "$work/noshell/sh"
if PATH="$work/noshell:$PATH" lock_op acquire "$work/unclaimable" "$$" 2>"$work/claim.err"; then
  fail 'a lock whose owner could not be recorded was reported as taken'
fi
[ ! -s "$work/claim.err" ] ||
  fail "recording the owner failed with an error instead of a refusal: $(cat "$work/claim.err")"
[ ! -e "$work/unclaimable" ] ||
  fail 'a lock whose owner could not be recorded was left behind'

# A pid of 0 is not a process. `kill -0 0` signals the caller's own process group
# and succeeds, so an owner of 0 must be refused outright rather than recorded as
# an owner that can never be proven gone.
if lock_op acquire "$work/zero.lock" 0; then fail 'a lock was given to owner 0'; fi
[ ! -e "$work/zero.lock" ] || fail 'the refused owner 0 left a lock behind'
mkdir "$work/zero.held"
printf '0\n' >"$work/zero.held/pid"
if lock_op held "$work/zero.held"; then fail 'a lock owned by pid 0 is reported as held'; fi
lock_op acquire "$work/zero.held" "$$" || fail 'a lock owned by pid 0 was never recoverable'
[ "$(cat "$work/zero.held/pid")" = "$$" ] || fail 'the owner was not recorded over pid 0'
lock_op release "$work/zero.held"
lock_op acquire "$lock" "$$" || fail 'a free lock was not acquired'
[ "$(cat "$lock/pid")" = "$$" ] || fail 'the owner was not recorded'
lock_op held "$lock" || fail 'a held lock is reported as free'

# The owner is alive, so nobody else may take the lock.
if lock_op acquire "$lock" "$dead_pid"; then fail 'a live lock was taken over'; fi
[ "$(cat "$lock/pid")" = "$$" ] || fail 'a live lock lost its owner'

# The owner is gone: the lock is abandoned and may be taken over.
echo "$dead_pid" >"$lock/pid"
if lock_op held "$lock"; then fail 'a lock whose owner is gone is reported as held'; fi
lock_op acquire "$lock" "$$" || fail 'an abandoned lock was not taken over'
[ "$(cat "$lock/pid")" = "$$" ] || fail 'the new owner was not recorded'

# A lock is taken in two steps. A directory without an owner is one that was
# created moments ago, and taking it over would hand the same lock to two
# workers at once.
lock_op release "$lock"
mkdir "$lock"
lock_op held "$lock" || fail 'a lock that is still being taken is reported as free'
if lock_op acquire "$lock" "$$"; then fail 'a lock that is still being taken was stolen'; fi
[ -d "$lock" ] || fail 'a lock that is still being taken was removed'
[ ! -f "$lock/pid" ] || fail 'the stolen lock recorded an owner'

# The same directory, old enough that no owner is coming, is abandoned.
touch -t 200001010000 "$lock"
if lock_op held "$lock"; then fail 'an owner that never arrived keeps the lock held'; fi
lock_op acquire "$lock" "$$" || fail 'a lock without an owner was never released'
[ "$(cat "$lock/pid")" = "$$" ] || fail 'the owner was not recorded after the takeover'

lock_op release "$lock"
[ ! -e "$lock" ] || fail 'the released lock is still there'

# However many callers reach an abandoned lock at the same moment, the lock
# may be handed to exactly one of them.
mkdir "$lock"
echo "$dead_pid" >"$lock/pid"
touch -t 200001010000 "$lock"
: >"$work/won"
i=0
while [ "$i" -lt 16 ]; do
  ( lock_op acquire "$lock" "$((1000 + i))" && echo won >>"$work/won" ) &
  i=$((i + 1))
done
wait 2>/dev/null || true
won="$(wc -l <"$work/won" | tr -d ' ')"
[ "$won" = 1 ] || fail "an abandoned lock was handed to $won callers at once"
owner="$(cat "$lock/pid")"
[ -n "$owner" ] || fail 'the winner did not record an owner'
leftovers="$(find "$lock" -name 'pid.*' | wc -l | tr -d ' ')"
[ "$leftovers" = 0 ] || fail 'a takeover left the previous owner behind'

lock_op release "$lock"
[ ! -e "$lock" ] || fail 'the released lock is still there'

printf 'runtime dir lock tests passed\n'
