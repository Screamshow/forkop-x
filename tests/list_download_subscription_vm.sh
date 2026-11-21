#!/bin/sh
set -eu
peer=$1
lib=/usr/lib/forkop
# Test fixture adapter: production requires HTTPS subscription URLs, while the
# isolated VM fixture serves HTTP. Only this exact fixture URL is translated;
# real Discord HTTPS downloads and their certificate checks are unchanged.
mkdir -p /root/forkop1161-test/subscription-bin
cat > /root/forkop1161-test/subscription-bin/curl <<'CURL'
#!/bin/sh
for arg do
    shift
    case "$arg" in
        https://sub.hat.onl/forkop-vm-test/subscription.txt) arg=http://@PEER@:19091/subscription.txt;;
    esac
    set -- "$@" "$arg"
done
exec /usr/bin/curl "$@"
CURL
sed -i "s/@PEER@/$peer/g" /root/forkop1161-test/subscription-bin/curl
chmod +x /root/forkop1161-test/subscription-bin/curl
export PATH="/root/forkop1161-test/subscription-bin:$PATH"
backup=/root/forkop1161-test/subscription-config.backup
cp /etc/config/forkop "$backup"
trap 'cp "$backup" /etc/config/forkop; uci revert forkop || true' EXIT
/etc/init.d/forkop stop
cp /root/forkop1161-test/source/forkop/files/etc/config/forkop /etc/config/forkop
uci set forkop.settings.dns_server=1.1.1.1
uci set forkop.settings.bootstrap_dns_server=1.1.1.1
uci set forkop.settings.component_update_check_enabled=0
uci set forkop.settings.enable_yacd=0
uci set forkop.settings.download_lists_via_proxy=1
uci set forkop.settings.download_lists_via_proxy_section=coldsub
uci set forkop.coldsub=section
uci set forkop.coldsub.enabled=1
uci set forkop.coldsub.action=connection
uci add_list forkop.coldsub.subscription_urls='https://sub.hat.onl/forkop-vm-test/subscription.txt'
uci add_list forkop.coldsub.community_lists=discord
uci commit forkop
rm -rf /etc/forkop/list-cache /tmp/sing-box/list-generation /tmp/sing-box/rulesets
echo 'CASE: cold start, new subscription section, Discord and download through that section'
ucode -L "$lib" "$lib/service/initd.uc" start-service test "$$"
test -s /var/run/forkop/watchdog.ready
test -s /tmp/sing-box/rulesets/coldsub-community-subnets-lists-ruleset.json
test -z "$(find /var/run/forkop -maxdepth 1 -name 'list-download-transport.*')"
proxy=$(ucode -L "$lib" "$lib/xrust/runtime.uc" service-proxy-address lists)
curl -fsS --max-time 20 --proxy "$proxy" https://mirror.51343.ru/forkop/lists/allow-domains/Subnets/IPv4/discord.lst >/dev/null
test "$(uci get forkop.settings.download_lists_via_proxy)" = 1
test "$(uci get forkop.settings.download_lists_via_proxy_section)" = coldsub
echo 'PASS: subscription fetched, selected VLESS downloaded Discord, main runtime ready, settings preserved'
/etc/init.d/forkop stop
