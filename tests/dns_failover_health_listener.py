"""Local integration fixture for Forkop DNS health routing with a published Xrust."""
import json
import os
from pathlib import Path
import signal
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time


LIB = Path(__file__).resolve().parents[1] / "forkop/files/usr/lib"
XRUST = os.environ.get("XRUST_BIN", "xrust")
QUESTION = bytes.fromhex("076578616d706c6503636f6d0000010001")


class Resolver(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if data[12:29] != QUESTION:
            return
        header = data[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0)
        record = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 30, 4) + self.server.answer
        sock.sendto(header + QUESTION + record, self.client_address)


def query(source, target):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((source, 0))
        sock.settimeout(0.2)
        sock.sendto(bytes.fromhex("881101000001000000000000") + QUESTION, target)
        response, address = sock.recvfrom(512)
        assert address == target and response[:2] == b"\x88\x11"
        assert response[6:8] == b"\x00\x01", response
        return response[-4:]


def wait_answers(target, expected):
    observed = {}
    for _ in range(30):
        try:
            observed = {source: query(source, target) for source in expected}
            if observed == expected:
                return
        except TimeoutError:
            pass
        time.sleep(0.1)
    raise AssertionError(f"Expected {expected!r} at {target!r}, last complete result {observed!r}")


def render(size, port, override=None):
    env = {**os.environ, "FORKOP_DNS_HEALTH_PORT_BASE": str(port - 2000)}
    env.pop("FORKOP_DNS_HEALTH_ADDRESS", None)
    if override is not None:
        env["FORKOP_DNS_HEALTH_ADDRESS"] = override
    return json.loads(subprocess.check_output([
        "ucode", "-L", str(LIB), "-e", '''
let dns = require("xrust.dns");
let main = [], bootstrap = [];
for (let i = 0; i < int(ARGV[0]); i++) {
    push(main, "192.0.2." + (i + 1));
    push(bootstrap, "198.51.100." + (i + 1));
}
let output = dns.config({ dns_server: main, bootstrap_dns_server: bootstrap });
assert(dns.health_probe("main", 1, {}).port != dns.health_probe("active", 0, {}).port);
print(sprintf("%J", output));
''', str(size)], env=env, text=True))


def runtime_config(generated, first, second, active):
    for resolver in generated["servers"]:
        tag = resolver["tag"]
        if tag == "dns-server":
            peer = active
        elif tag == "bootstrap-dns-server":
            peer = second
        else:
            _, _, kind, index, _ = tag.split("-")
            peer = first if (int(index) % 2 == 1) == (kind == "main") else second
        resolver["server"], resolver["server_port"] = peer.server_address
    return {
        "dns": {"servers": generated["servers"], "rules": generated["rules"], "final": "dns-server"},
        "inbounds": generated["inbounds"],
        "outbounds": [{"type": "direct", "tag": "direct"}],
        "route": {"final": "direct", "default_domain_resolver": "dns-server",
                  "rules": [{"action": "hijack-dns", "inbound": generated["sniff_inbounds"]}]},
    }


def main():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.42", 0))
        target = reservation.getsockname()
    initial = render(2, target[1])
    enlarged = render(9, target[1])
    single = render(1, target[1])
    legacy = render(2, target[1], override="127.0.0.43")
    assert initial["state"]["health_probe_mode"] == "loopback-source-v1"
    assert legacy["state"]["health_probe_mode"] is None and len(legacy["inbounds"]) == 17
    assert len(initial["inbounds"]) == 1 and initial["inbounds"] == enlarged["inbounds"] == single["inbounds"]
    assert len(enlarged["rules"]) == 19
    with socketserver.UDPServer(("127.0.0.1", 0), Resolver) as first, \
            socketserver.UDPServer(("127.0.0.1", 0), Resolver) as second, \
            tempfile.TemporaryDirectory() as directory:
        first.answer = socket.inet_aton("192.0.2.1")
        second.answer = socket.inet_aton("192.0.2.2")
        for server in (first, second):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        expected = {"127.0.0.1": first.answer, "127.16.0.1": first.answer, "127.16.0.2": second.answer,
                    "127.32.0.1": second.answer, "127.32.0.2": first.answer}
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(runtime_config(initial, first, second, first)))
        subprocess.run([XRUST, "check", "-c", path], check=True)
        with (Path(directory) / "core.log").open("w+") as log:
            core = subprocess.Popen([XRUST, "run", "-c", path], stdout=log, stderr=log, cwd=directory)
            try:
                wait_answers(target, expected)
                replacement = path.with_suffix(".next")
                replacement.write_text(json.dumps(runtime_config(enlarged, first, second, second)))
                subprocess.run([XRUST, "check", "-c", replacement], check=True)
                replacement.replace(path)
                core.send_signal(signal.SIGHUP)
                expected.update({"127.0.0.1": second.answer, "127.16.0.9": first.answer, "127.32.0.9": second.answer})
                wait_answers(target, expected)
                assert core.poll() is None
            except Exception:
                log.seek(0)
                print(log.read())
                raise
            finally:
                if core.poll() is None:
                    core.terminate()
                core.wait(timeout=10)
    print("One health listener (2 sockets) instead of 17 (34 sockets), both candidate pools and hot SIGHUP verified")


if __name__ == "__main__":
    main()
