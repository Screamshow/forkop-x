#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=${FORKOP_LIB:-$ROOT/forkop/files/usr/lib}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for ports in 20000-50000 20000,30000-50000 443; do
    cat >"$WORK/fixture.json" <<JSON
{"settings":{".name":"settings",".type":"settings","dns_server":"1.1.1.1"},"section":[{".name":"hy2",".type":"section","enabled":"1","action":"connection","selector_proxy_links":["hy2://pw@example.com:443/?obfs=salamander&obfs-password=test&sni=example.com&mport=$ports"]}]}
JSON
    ucode -L "$LIB" "$LIB/singbox/generator.uc" generate-config-fixture "$WORK/fixture.json" "$WORK/out.json" 127.0.0.1 0 1 '' 1.14.2-rust-x.0.0.36
    ucode -e 'let c=json(require("fs").readfile(ARGV[0]));let o=filter(c.outbounds,x=>x.type=="hysteria2")[0];assert(o.obfs.password=="test" && o.tls.server_name=="example.com","HY2 options");if(ARGV[1]=="443")assert(o.server_port==443 && o.server_ports==null,"single port");else assert((ARGV[1]=="20000-50000" ? length(o.server_ports)==1 && o.server_ports[0]=="20000:50000" : length(o.server_ports)==2 && o.server_ports[0]=="20000:20000" && o.server_ports[1]=="30000:50000") && o.server_port==null,"port hopping");' "$WORK/out.json" "$ports"
done
echo 'PASS: manual HY2 single port, range and mixed list preserve TLS and Salamander'
