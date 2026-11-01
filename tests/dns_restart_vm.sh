#!/bin/sh
# Run on an existing, disposable OpenWrt VM with Forkop already running and
# example.com configured for proxy/FakeIP DNS. Does not back up or replace UCI.
set -eu
D=/tmp/forkop-dns-restart-test
mkdir -p "$D"
domain=${1:-example.com}
dns_value() { uci -q get "dhcp.@dnsmasq[0].$1" || true; }
check_restart() {
    label=$1; shift
    before_pid=$(pidof dnsmasq)
    before_tx=$(dns_value forkop_dns_transaction_id)
    [ -n "$before_tx" ]
    "$@" > "$D/$label.log" 2>&1 &
    worker=$!
    bad=0; replies=0; retries=0
    while kill -0 "$worker" 2>/dev/null; do
        [ "$(dns_value server)" = 127.0.0.42 ] || bad=1
        [ "$(dns_value noresolv)" = 1 ] || bad=1
        [ "$(dns_value forkop_dns_transaction_id)" = "$before_tx" ] || bad=1
        answer=$(dig @127.0.0.1 "$domain" A +short +time=1 +tries=1 2>/dev/null || true)
        case "$answer" in
            198.18.*|198.19.*) replies=$((replies+1));;
            ''|*'timed out'*|*'no servers could be reached'*) retries=$((retries+1));;
            *) echo "UNEXPECTED_DNS=$answer"; bad=1;;
        esac
        sleep 1
    done
    wait "$worker"
    [ "$bad" = 0 ]
    [ "$(pidof dnsmasq)" = "$before_pid" ]
    [ "$(dns_value forkop_dns_transaction_id)" = "$before_tx" ]
    dig @127.0.0.1 "$domain" A +short +time=2 +tries=1 | grep -Eq '^198\.(18|19)\.'
    /etc/init.d/forkop status
    echo "$label PASS fakeip_replies=$replies temporary_retries=$retries dnsmasq_unchanged=1"
}
check_restart cli /usr/bin/forkop restart
check_restart initd /etc/init.d/forkop restart
check_restart manual /usr/bin/forkop manual_restart
/usr/bin/forkop stop > "$D/stop.log" 2>&1
[ -z "$(dns_value forkop_dns_transaction_id)" ]
[ "$(dns_value server)" != 127.0.0.42 ]
echo 'explicit_stop PASS DNS restored'
/etc/init.d/forkop start > "$D/start.log" 2>&1
if FORKOP_SINGBOX_CONFIG_FAIL_PHASE=generate /usr/bin/forkop restart > "$D/failure.log" 2>&1; then
    echo 'FAIL injected startup error was accepted'; exit 1
fi
[ -n "$(dns_value forkop_dns_transaction_id)" ]
[ "$(dns_value server)" = 127.0.0.42 ]
echo 'failed_restart PASS previous runtime and DNS preserved'
/etc/init.d/forkop start > "$D/recovery.log" 2>&1
/etc/init.d/forkop status
dig @127.0.0.1 "$domain" A +short +time=2 +tries=1 | grep -Eq '^198\.(18|19)\.'
echo 'recovery PASS'
