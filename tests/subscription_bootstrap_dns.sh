#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_UC="$ROOT_DIR/forkop/files/usr/lib/subscription/cache.uc"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/usr/bin/env bash
host= server= type= port= protocol=udp tls_ca= tls_hostname=
while [ "$#" -gt 0 ]; do
  case "$1" in
    @*) server="${1#@}" ;;
    -p) port="$2"; shift ;;
    -q) host="$2"; shift ;;
    -t) type="$2"; shift ;;
    +https=*) protocol="$1" ;;
    +tls) protocol="$1" ;;
    +tls-ca=*) tls_ca="$1" ;;
    +tls-hostname=*) tls_hostname="$1" ;;
  esac
  shift
done
printf '%s %s\n' "$host" "$server" >>"${DIG_LOG:?}"
case "$host:$server:$type:$port:$protocol:$tls_hostname" in
  one.example:8.8.8.8:A:53:udp:) ip=203.0.113.11 ;;
  two.example:8.8.8.8:A:53:udp:) ip=203.0.113.12 ;;
  shared.example:8.8.8.8:A:53:udp:) ip=203.0.113.13 ;;
  ipv6.example:2001:4860:4860::8888:AAAA:53:udp:) ip=2001:db8::44 ;;
  one.example:192.0.2.54:A:8443:+https=/custom-dns:+tls-hostname=192.0.2.54) ip=203.0.113.14 ;;
  one.example:8.8.8.8:A:853:+tls:+tls-hostname=dns.google) ip=203.0.113.15 ;;
  *) exit 1 ;;
esac
if [ "$protocol" != udp ] && [ "$tls_ca" != '+tls-ca=/etc/ssl/certs/ca-certificates.crt' ]; then
  exit 1
fi
printf '%s\n' "$ip"
SH
cat >"$WORK_DIR/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_LOG:?}"
out=""
resolve=0
while [ "$#" -gt 0 ]; do
  [ "$1" = "--resolve" ] && resolve=1
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
if [ "$resolve" -ne 1 ]; then exit 6; fi
if [ "${CURL_RESOLVE_STATUS:-0}" -ne 0 ]; then exit "${CURL_RESOLVE_STATUS}"; fi
printf 'subscription\n' >"$out"
SH
cat >"$WORK_DIR/bin/logger" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LOGGER_LOG:?}"
SH
chmod 0755 "$WORK_DIR/bin/dig" "$WORK_DIR/bin/curl" "$WORK_DIR/bin/logger"

export PATH="$WORK_DIR/bin:$PATH"
export DIG_LOG="$WORK_DIR/dig.log"
export CURL_LOG="$WORK_DIR/curl.log"
export LOGGER_LOG="$WORK_DIR/logger.log"
UCI_STATE="$WORK_DIR/uci.state"

download() {
  printf 'forkop.settings=settings\nforkop.settings.bootstrap_dns_server=%s\nforkop.settings.dns_type=%s\nforkop.settings.dns_use_provider=%s\n' \
    "$1" "${4:-udp}" "${5:-0}" >"$UCI_STATE"
  CURL_RESOLVE_STATUS="${2:-0}" \
    FORKOP_UCI_STATE_FILE="$UCI_STATE" \
    ucode -L "$FORKOP_LIB" "$CACHE_UC" download-subscription-fixture "$3" "$WORK_DIR/result" "" "" "" ""
}

# One URL, ordered Bootstrap DNS fallback, and no URL secret in Forkop logs.
: >"$DIG_LOG"; : >"$CURL_LOG"; : >"$LOGGER_LOG"
download '1.1.1.1 8.8.8.8' 0 'https://one.example/sub?token=secret' || fail 'bootstrap download failed'
[ "$(head -n 1 "$DIG_LOG")" = 'one.example 1.1.1.1' ] || fail 'first Bootstrap DNS was not tried first'
grep -Fxq 'one.example 8.8.8.8' "$DIG_LOG" || fail 'second Bootstrap DNS was not tried'
grep -Fq -- '--resolve one.example:443:203.0.113.11' "$CURL_LOG" || fail 'curl did not retain hostname through --resolve'
grep -Eq -- '--max-time ([1-9]|1[0-9]|20) --max-filesize 16777216' "$CURL_LOG" || fail 'runtime fetch size or time bound is missing'
grep -Fq -- '-k' "$CURL_LOG" && fail 'bootstrap download must not disable TLS verification'
grep -Fq 'secret' "$LOGGER_LOG" && fail 'subscription token leaked to logger'

# Bootstrap resolution accepts IPv6 DNS targets and answers. --resolve must
# bracket the IPv6 answer and retain the subscription's custom HTTPS port.
: >"$DIG_LOG"; : >"$CURL_LOG"
download '2001:4860:4860::8888' 0 'https://ipv6.example:8443/sub' || fail 'IPv6 bootstrap download failed'
grep -Fxq 'ipv6.example 2001:4860:4860::8888' "$DIG_LOG" || fail 'IPv6 Bootstrap DNS was not tried'
grep -Fq -- '--resolve ipv6.example:8443:[2001:db8::44]' "$CURL_LOG" || fail 'curl IPv6 --resolve or custom HTTPS port is incorrect'

# Three sources are handled by the same downloader; same-host calls stay generic.
for url in 'https://one.example/a' 'https://two.example/b' 'https://shared.example/c' 'https://shared.example/d'; do
  download '8.8.8.8' 0 "$url" || fail "bootstrap download failed for $url"
done
grep -Fc 'shared.example 8.8.8.8' "$DIG_LOG" | grep -qx '2' || fail 'shared hostname was not handled per subscription request'

# No Bootstrap DNS preserves the existing system-resolver attempt and does not mutate DNS state.
: >"$DIG_LOG"; : >"$CURL_LOG"
if download '' 0 'https://one.example/no-bootstrap'; then fail 'broken system resolver unexpectedly succeeded'; fi
[ ! -s "$DIG_LOG" ] || fail 'empty Bootstrap DNS list must not run direct lookup'
grep -Fq -- '--resolve' "$CURL_LOG" && fail 'empty Bootstrap DNS list must not use --resolve'

# Exhausted Bootstrap DNS preserves the existing failed-system-DNS result and
# does not mutate the configured Bootstrap DNS list.
: >"$DIG_LOG"; : >"$CURL_LOG"
if download '1.1.1.1' 0 'https://one.example/bootstrap-unavailable'; then fail 'unavailable Bootstrap DNS unexpectedly succeeded'; fi
grep -Fxq 'one.example 1.1.1.1' "$DIG_LOG" || fail 'configured Bootstrap DNS was not attempted'
grep -Fxq 'forkop.settings.bootstrap_dns_server=1.1.1.1' "$UCI_STATE" || fail 'Bootstrap DNS configuration was changed'
grep -Fq -- '--resolve' "$CURL_LOG" && fail 'failed Bootstrap DNS must not use --resolve'

# IP literals do not require lookup or --resolve.
: >"$DIG_LOG"; : >"$CURL_LOG"
if download '8.8.8.8' 0 'https://203.0.113.42/sub'; then fail 'IP literal must keep the normal resolver/download path'; fi
[ ! -s "$DIG_LOG" ] || fail 'IP literal triggered Bootstrap DNS lookup'

# A TLS/certificate error after resolution remains an error and never falls back to -k.
: >"$CURL_LOG"
if download '8.8.8.8' 60 'https://one.example/invalid-cert'; then fail 'invalid TLS certificate was accepted'; fi
grep -Fq -- '-k' "$CURL_LOG" && fail 'TLS failure path used -k'

# Bootstrap inherits DoH and DoT, including endpoint overrides and strict identity.
: >"$CURL_LOG"
download '192.0.2.54:8443/custom-dns' 0 'https://one.example/doh' doh || fail 'DoH Bootstrap DNS failed'
grep -Fq -- '--resolve one.example:443:203.0.113.14' "$CURL_LOG" || fail 'DoH answer was not used'
grep -Fq -- '/custom-dns' "$LOGGER_LOG" && fail 'DoH endpoint path leaked to logger'
download '8.8.8.8' 0 'https://one.example/dot' dot || fail 'DoT Bootstrap DNS failed'
grep -Fq -- '--resolve one.example:443:203.0.113.15' "$CURL_LOG" || fail 'DoT answer was not used'
if download '8.8.8.8' 0 'https://one.example/doh-failure' doh; then
  fail 'failed DoH Bootstrap DNS fell back to UDP'
fi

# Provider mode leaves its existing direct UDP fallback independent of the hidden switch.
: >"$CURL_LOG"
download '8.8.8.8' 0 'https://one.example/provider' doh 1 || fail 'provider UDP Bootstrap DNS failed'
grep -Fq -- '--resolve one.example:443:203.0.113.11' "$CURL_LOG" || fail 'provider fallback did not use UDP'

printf 'subscription bootstrap DNS checks passed\n'
