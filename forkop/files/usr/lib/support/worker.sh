#!/bin/sh
set -eu
umask 077
dir=${FORKOP_SUPPORT_DIR:-/var/run/forkop/support}
lite=${FORKOP_SUPPORT_LITE_DIR:-/usr/lib/forkop-support}
lib=${FORKOP_SUPPORT_LIB_DIR:-/usr/lib/forkop/support}
cli=tailscale
daemon=tailscaled
if [ ! -L "$lite" ] && [ -f "$lite/.forkop-lite" ] && [ -x "$lite/tailscale" ] && [ -x "$lite/tailscaled" ]; then
    cli="$lite/tailscale"
    daemon="$lite/tailscaled"
fi
daemon_pid=
auth_pid=
phase=stopped
error=
address=
free_kib=0
required_kib=0
session_id=$(cat /proc/sys/kernel/random/uuid)
attempts=0
bad_since=0
next_attempt=0
hostname="forkop-support-$(cat /proc/sys/kernel/hostname)"
uptime_seconds() { cut -d. -f1 /proc/uptime; }
deadline=$(( $(uptime_seconds) + ${FORKOP_SUPPORT_TTL:-1800} ))
# The API creates the identity/deadline before starting procd. Standalone tests
# may omit them, but recovery never regenerates either value.
if [ -s "$dir/status.json" ]; then
    existing_id=$(jsonfilter -i "$dir/status.json" -e '@.session_id' 2>/dev/null || true)
    existing_deadline=$(jsonfilter -i "$dir/status.json" -e '@.deadline' 2>/dev/null || true)
    case "$existing_id" in ????????-????-????-????-????????????) session_id=$existing_id;; esac
    case "$existing_deadline" in ''|*[!0-9]*) ;; *) deadline=$existing_deadline;; esac
fi
state() {
    printf '{"schema":2,"session_id":"%s","phase":"%s","deadline":%s,"error":"%s","free_kib":%s,"required_kib":%s,"recovery_attempts":%s,"address":"%s"}\n' "$session_id" "$phase" "$deadline" "$error" "$free_kib" "$required_kib" "$attempts" "$address" > "$dir/status.new"
    mv "$dir/status.new" "$dir/status.json"
}
# Stop parents before walking their children so a cancelled CLI cannot spawn
# a late helper. All tracked processes belong exclusively to this worker.
kill_tree() {
    kill -STOP "$1" 2>/dev/null || return 0
    for child in $(cat "/proc/$1/task/$1/children" 2>/dev/null); do kill_tree "$child"; done
    kill -KILL "$1" 2>/dev/null || true
}
event() {
    # RAM only, fixed messages without raw CLI output or credentials.
    printf '%s %s attempt=%s\n' "$(uptime_seconds)" "$1" "$attempts" >> "$dir/recovery.log"
}
within_session() {
    if [ -f "$dir/cancelled" ] || [ "$(uptime_seconds)" -ge "$deadline" ]; then phase=stopped; exit 0; fi
}
# Bound even a hung local API command, and check expiry while it runs.
run_cli() {
    within_session
    limit=$(( $(uptime_seconds) + $1 )); shift
    "$cli" --socket="$dir/socket" "$@" > "$dir/check.json" 2>/dev/null &
    auth_pid=$!
    while kill -0 "$auth_pid" 2>/dev/null; do
        within_session
        if [ "$(uptime_seconds)" -ge "$limit" ]; then
            kill_tree "$auth_pid"; wait "$auth_pid" 2>/dev/null || true
            auth_pid=; return 1
        fi
        sleep 1
    done
    rc=0; wait "$auth_pid" || rc=$?
    auth_pid=
    within_session
    return "$rc"
}
# Only an explicitly configured Tailscale IPv4 peer; never enumerate the tailnet.
load_peer() {
    peer=${FORKOP_SUPPORT_OPERATOR_IP-$(uci -q get forkop.settings.support_operator_ip 2>/dev/null || true)}
    case "$peer" in ''|*[!0-9.]*) peer=; return;; esac
    old_ifs=$IFS; IFS=.; set -- $peer; IFS=$old_ifs
    if [ "$#" -ne 4 ]; then peer=; return; fi
    if [ "$peer" != "$1.$2.$3.$4" ]; then peer=; return; fi
    for octet in "$@"; do
        case "$octet" in ''|0[0-9]*) peer=; return;; esac
        if [ "${#octet}" -gt 3 ] || [ "$octet" -gt 255 ]; then peer=; return; fi
    done
    if [ "$1" -ne 100 ] || [ "$2" -lt 64 ] || [ "$2" -gt 127 ]; then peer=; fi
}
probe_peer() {
    if run_cli 7 ping --c=1 --timeout=5s --until-direct=false "$peer"; then
        event peer-ping-ok
    else
        event peer-ping-failed
        if [ "$(uptime_seconds)" -ge "$next_netcheck" ]; then
            next_netcheck=$(( $(uptime_seconds) + 300 ))
            if run_cli 10 netcheck; then event peer-netcheck-completed; else event peer-netcheck-failed; fi
            if run_cli 7 ping --c=1 --timeout=5s --until-direct=false "$peer"; then event peer-ping-ok; else event peer-ping-failed; fi
        fi
    fi
    # A failed peer probe is not evidence that coordination or SSH has failed.
    next_peer_check=$(( $(uptime_seconds) + 60 ))
}
cleanup() {
    trap - EXIT TERM INT
    case "$phase" in starting|connected|degraded|recovering) phase=stopped;; esac
    state
    # Revoke SSH authorization before closing the support transport.
    ucode "$lib/ssh-access.uc" remove >/dev/null 2>&1 || true
    [ -z "$auth_pid" ] || kill_tree "$auth_pid"
    [ -z "$auth_pid" ] || wait "$auth_pid" 2>/dev/null || true
    [ -z "$daemon_pid" ] || kill_tree "$daemon_pid"
    [ -z "$daemon_pid" ] || wait "$daemon_pid" 2>/dev/null || true
    if [ "$phase" = failed ] && [ -n "$daemon_pid" ]; then
        FORKOP_SUPPORT_DIR="$dir" ucode "$lib/auth-diagnostic.uc" >/dev/null 2>&1 || true
    fi
    rm -f "$dir/daemon.log" "$dir/auth.log"
    rm -f "$dir/lite.download"
    if [ "${lite_installing:-0}" = 1 ]; then
        rm -f "$lite/tailscale" "$lite/tailscaled" "$lite/tailscale.combined" "$lite/.forkop-lite"
        rmdir "$lite" 2>/dev/null || true
    fi
    rm -f "$dir/auth.key" "$dir/socket" "$dir/operation"
    rm -f "$dir/check.json"
    rmdir "$dir/lock" 2>/dev/null || true
    state
}
trap cleanup EXIT
trap 'phase=stopped; exit 0' TERM INT
rm -f "$dir/auth-detail.txt"
: > "$dir/recovery.log"
if [ "$(cat "$dir/operation")" = remove ]; then
    phase=removing; state
    if [ -x "$lite/tailscale" ] && [ -x "$lite/tailscaled" ] && [ -f "$lite/.forkop-lite" ] && [ ! -L "$lite" ]; then
        rm -f "$lite/tailscale" "$lite/tailscaled" "$lite/tailscale.combined" "$lite/.forkop-lite"
        rmdir "$lite" || { phase=failed; error='Tailscale Lite removal failed'; exit 1; }
        phase=stopped; exit 0
    fi
    # Recheck immediately before the transaction; never stop another instance.
    if /etc/init.d/tailscale enabled >/dev/null 2>&1; then
        phase=failed; error='Stop and disable the existing Tailscale service before removing it'; exit 1
    fi
    for proc in /proc/[0-9]*/cmdline; do
        args=$(tr '\000' ' ' < "$proc" 2>/dev/null) || continue
        executable=${args%% *}
        case "${executable##*/}" in
            tailscaled) phase=failed; error='Stop and disable the existing Tailscale service before removing it'; exit 1;;
        esac
    done
    if command -v apk >/dev/null 2>&1; then
        apk del tailscale >/dev/null 2>&1 || { phase=failed; error='Tailscale removal failed'; exit 1; }
    else
        opkg remove tailscale >/dev/null 2>&1 || { phase=failed; error='Tailscale removal failed'; exit 1; }
    fi
    phase=stopped; exit 0
fi
if [ "$(cat "$dir/operation")" = install ]; then
    : > "$dir/package.log"
    phase=installing; state
    # Only provision an absent installation. Never upgrade or stop a user's client.
    if command -v tailscale >/dev/null 2>&1 || command -v tailscaled >/dev/null 2>&1; then
        phase=failed; error='An existing Tailscale installation needs manual repair'; exit 1
    fi
    . /usr/lib/forkop/support/lite-install.sh
    if ! install_lite; then phase=failed; exit 1; fi
    phase=stopped; exit 0
fi
[ -s "$dir/auth.key" ] || { phase=failed; error='Missing temporary auth key'; exit 1; }
phase=starting; state
"$daemon" --tun=userspace-networking --state=mem: --statedir="$dir" --socket="$dir/socket" --port=0 --no-logs-no-support >"$dir/daemon.log" 2>&1 &
daemon_pid=$!
count=0
while [ ! -S "$dir/socket" ]; do
    within_session
    kill -0 "$daemon_pid" 2>/dev/null || { phase=failed; error='Tailscale failed to start'; exit 1; }
    count=$((count + 1)); [ "$count" -lt 15 ] || { phase=failed; error='Tailscale startup timed out'; exit 1; }
    sleep 1
done
# Credentials only enter tailscale via a root-readable file, never argv.
"$cli" --socket="$dir/socket" up --hostname="$hostname" --accept-dns=false --accept-routes=false --netfilter-mode=off --auth-key="file:$dir/auth.key" --timeout=60s >"$dir/auth.log" 2>&1 &
auth_pid=$!
auth_deadline=$(( $(uptime_seconds) + 60 ))
[ "$auth_deadline" -le "$deadline" ] || auth_deadline=$deadline
while kill -0 "$auth_pid" 2>/dev/null; do
    within_session
    [ "$(wc -c < "$dir/daemon.log")" -le 262144 ] || : > "$dir/daemon.log"
    if [ "$(uptime_seconds)" -ge "$auth_deadline" ]; then
        phase=failed; error='Tailscale authorization failed or timed out'; exit 1
    fi
    sleep 1
done
if ! wait "$auth_pid"; then
    auth_pid=; phase=failed; error='Tailscale authorization failed or timed out'; exit 1
fi
auth_pid=
rm -f "$dir/auth.key"
within_session
ucode "$lib/ssh-access.uc" add >/dev/null 2>&1 || { phase=failed; error='Temporary SSH authorization failed'; exit 1; }
load_peer
next_peer_check=0
next_netcheck=0
# Successful up is not sufficient evidence of healthy coordination.
next_check=0
while [ "$(uptime_seconds)" -lt "$deadline" ]; do
    within_session
    [ "$(wc -c < "$dir/daemon.log")" -le 262144 ] || : > "$dir/daemon.log"
    kill -0 "$daemon_pid" 2>/dev/null || { phase=failed; error='Tailscale connection process exited'; exit 1; }
    now=$(uptime_seconds)
    if [ "$now" -ge "$next_check" ]; then
        if run_cli 5 status --json && ucode "$lib/health.uc" "$dir/check.json"; then
            address=$(jsonfilter -i "$dir/check.json" -e '@.Self.TailscaleIPs[*]' 2>/dev/null |
                awk -F. 'NF == 4 && $0 ~ /^100\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2 >= 64 && $2 <= 127 && $3 <= 255 && $4 <= 255 { print; exit }')
            if [ "$phase" != connected ]; then event control-healthy; fi
            phase=connected; error=; bad_since=0; state
        else
            now=$(uptime_seconds)
            if [ "$bad_since" = 0 ]; then bad_since=$now; event control-unhealthy; fi
            phase=degraded; error='Tailscale control connection is unhealthy'; state
            if [ "$((now - bad_since))" -ge "${FORKOP_SUPPORT_HEALTH_GRACE:-60}" ] && [ "$now" -ge "$next_attempt" ] && [ "$attempts" -lt 3 ]; then
                attempts=$((attempts + 1))
                next_attempt=$((now + ${FORKOP_SUPPORT_RECOVERY_INTERVAL:-120}))
                phase=recovering; error=; state; event recovery-started
                # Same daemon, same socket/preferences, no auth key, no SSH add.
                if run_cli 5 down && run_cli 22 up --timeout=20s --accept-dns=false --accept-routes=false --hostname="$hostname" --netfilter-mode=off; then
                    event recovery-command-completed
                else
                    event recovery-command-failed
                fi
                phase=degraded; error='Tailscale control connection is unhealthy'; state
                if [ "$attempts" -eq 3 ]; then event recovery-limit-reached; fi
            fi
        fi
        next_check=$(( $(uptime_seconds) + ${FORKOP_SUPPORT_HEALTH_INTERVAL:-10} ))
    fi
    # Coordination can be degraded while a peer path remains usable. Probe the
    # authorized session without granting SSH or changing its health phase.
    if { [ "$phase" = connected ] || [ "$phase" = degraded ]; } && [ -n "$peer" ] && [ "$(uptime_seconds)" -ge "$next_peer_check" ]; then
        probe_peer
    fi
    sleep 1
done
phase=stopped
