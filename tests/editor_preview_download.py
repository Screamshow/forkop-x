"""Real curl/ucode preview and runtime downloads using isolated configuration."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import ssl
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "forkop/files/usr/lib"
requests = []


class Handler(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        requests.append((self.path, dict(self.headers)))
        self.send_error(503)

    def do_GET(self):
        requests.append((self.path, dict(self.headers)))
        if "/fail" in self.path:
            self.send_error(503)
            return
        if "/invalid" in self.path:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"invalid provider response")
            return
        if "/too-large" in self.path:
            self.send_response(200)
            self.send_header("Content-Length", str(5 * 1024 * 1024))
            self.end_headers()
            return
        if "/superseded" in self.path:
            replacement = state.with_suffix(".new")
            replacement.write_text(reordered_sources)
            replacement.replace(state)
        body = json.dumps({"outbounds": [{"type": "vless", "tag": "Working server",
                                         "server": "203.0.113.9", "server_port": 443,
                                         "uuid": "12345678-1234-1234-1234-123456789abc"}]}).encode()
        if "/gzip" in self.path:
            body = gzip.compress(body)
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


with tempfile.TemporaryDirectory(prefix="forkop-preview-test-") as temp:
    work = Path(temp)
    lib = work / "lib"
    lib.mkdir()
    for child in LIB.iterdir():
        if child.name != "service":
            (lib / child.name).symlink_to(child, target_is_directory=child.is_dir())
    (lib / "service").mkdir()
    (lib / "service/state.uc").write_text('exit(getenv("TEST_PROXY_STOPPED") == "1" ? 1 : 0);\n')
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_port
    config = work / "active.json"
    tag = "service-subscription-proxy-in"
    active = {"inbounds": [{"type": "mixed", "tag": tag, "listen": "127.0.0.1", "listen_port": port}],
              "route": {"rules": [{"action": "route", "inbound": tag, "outbound": "proxy-out"}]}}
    config.write_text(json.dumps(active))
    inactive = work / "inactive.json"
    inactive.write_text(json.dumps({"inbounds": [], "route": {"rules": []}}))
    runtime_state = work / "runtime"
    runtime_state.mkdir()
    (runtime_state / "xrust-config-path").write_text(f"{config}\n")
    state = work / "uci.state"
    state.write_text(f"forkop.settings=settings\nforkop.settings.config_path={inactive}\n"
                     "forkop.source1=subscription_url\nforkop.source1.section=draft\n"
                     "forkop.source2=subscription_url\nforkop.source2.section=unrelated\n"
                     "forkop.unrelated=section\n")
    state_hash = hashlib.sha256(state.read_bytes()).hexdigest()
    env = dict(os.environ, FORKOP_LIB=str(lib), FORKOP_UCI_STATE_FILE=str(state),
               FORKOP_RUNTIME_STATE_DIR=str(runtime_state),
               TMP_SING_BOX_FOLDER=str(work / "xrust"),
               FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR=str(work / "persistent"),
               FORKOP_RELOAD_LOCK_DIR=str(work / "reload.lock"))
    for key in list(env):
        if key.lower() in {"http_proxy", "https_proxy", "all_proxy"}:
            env.pop(key)
    # An explicit selected proxy must work even when NO_PROXY would bypass it.
    env["NO_PROXY"] = "*"

    def download(name, url, target=None, stopped=False):
        source = {"url": url}
        if target is not None:
            source.update(download_via_proxy_enabled="1", download_via_proxy_section=target)
        request = work / "request.json"
        request.write_text(json.dumps({"source": source, "section": "draft"}))
        prefix = work / name
        result = subprocess.run(["ucode", "-L", str(lib), str(LIB / "subscription/cache.uc"),
                                 "editor-download-source", str(request), str(prefix)],
                                env=dict(env, TEST_PROXY_STOPPED="1" if stopped else "0"),
                                capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, result.stderr
        profile = json.loads(Path(str(prefix) + ".profile.json").read_text())
        assert "secret" not in result.stdout + result.stderr
        return prefix, profile

    try:
        def removed_sources(section, section_ids):
            return subprocess.run(["ucode", "-L", str(lib), str(ROOT / "forkop/files/usr/bin/forkop"),
                                   "editor_removed_subscription_sources", section, section_ids],
                                  env=env, capture_output=True, text=True, timeout=10)

        for ids, affected in [(["source1"], True), (["source2", "unrelated"], False), ([], False)]:
            result = removed_sources("draft", json.dumps(ids))
            assert result.returncode == 0, result.stderr
            assert json.loads(result.stdout) == {"affected": affected}
        for section, raw in [("../draft", '["source1"]'), ("draft", '{}'), ("draft", '[1]')]:
            assert removed_sources(section, raw).returncode != 0

        prefix, profile = download("proxy", "http://preview.invalid/feed?token=secret", "proxy")
        assert "error" not in profile, profile
        assert requests[-1][0] == "http://preview.invalid/feed?token=secret"
        assert requests[-1][1]["User-Agent"].startswith("INCY/")
        assert requests[-1][1]["X-HWID"] == profile["hwid"]
        assert "Working server" in Path(str(prefix) + ".json").read_text()
        assert Path(str(prefix) + ".curl").stat().st_mode & 0o777 == 0o600
        # Exercise the real editor dispatcher and generator as well as downloader.
        preview_root = work / "ui-state"
        preview_root.mkdir()
        preview_id = "editor-integration-test"
        (preview_root / (preview_id + ".json")).write_text(json.dumps({"section": "draft", "sources": [{
            "url": "http://preview.invalid/feed?token=secret", "download_via_proxy_enabled": "1",
            "download_via_proxy_section": "proxy"}]}))
        version = work / "version"
        version.write_text("1.14.2-rust-x.0.0.40")
        result = subprocess.run(["ucode", "-L", str(lib), str(LIB / "subscription/editor.uc"),
                                 "preview", preview_id], env=dict(env, FORKOP_EDITOR_STATE_DIR=str(preview_root),
                                                                  SB_VERSION_STATE_FILE=str(version)),
                                capture_output=True, text=True, timeout=90)
        assert result.returncode == 0, result.stderr
        catalogue = json.loads(result.stdout)
        assert "Working server" in catalogue.get("names", {}).values(), catalogue
        assert list(preview_root.iterdir()) == [], "editor left private download files behind"
        _, direct = download("direct", f"http://127.0.0.1:{port}/direct")
        assert "error" not in direct, direct
        _, compressed = download("gzip", f"http://127.0.0.1:{port}/gzip")
        assert "error" not in compressed, compressed
        _, too_large = download("too-large", f"http://127.0.0.1:{port}/too-large")
        assert "error" in too_large
        lock = work / "reload.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{os.getpid()}\n")
        before = len(requests)
        _, waiting = download("locked-preview", "http://preview.invalid/feed", "proxy")
        assert "applying settings" in waiting.get("error", "") and len(requests) == before
        (lock / "pid").unlink()
        lock.rmdir()
        before = len(requests)
        _, invalid = download("invalid", f"http://127.0.0.1:{port}/invalid")
        assert "error" in invalid, invalid
        attempts = requests[before:]
        assert len(attempts) == 1, attempts
        assert attempts[0][1]["User-Agent"] == direct["user_agent"]
        before = len(requests)
        for name, target, stopped in [("missing", "missing", False), ("stopped", "proxy", True),
                                       ("empty", "", False)]:
            _, failed = download(name, f"http://127.0.0.1:{port}/must-not-download", target, stopped)
            assert "error" in failed, failed
            assert len(requests) == before, "unavailable proxy silently downloaded directly"
        _, failed = download("http-fail", f"http://127.0.0.1:{port}/fail", "proxy")
        assert "error" in failed
        assert len(requests) > before
        assert all(path.startswith("http://") for path, _ in requests[before:]), "failed request bypassed the selected HTTP proxy"
        active["route"]["rules"][0]["outbound"] = "wrong-out"
        config.write_text(json.dumps(active))
        before = len(requests)
        _, failed = download("wrong-route", f"http://127.0.0.1:{port}/wrong", "proxy")
        assert "error" in failed and len(requests) == before
        assert hashlib.sha256(state.read_bytes()).hexdigest() == state_hash, "preview mutated UCI"
        assert json.loads(config.read_text()) == active, "preview mutated active config"
        print("PASS: real preview proxy/direct download, shared headers/parser, private request, NO_PROXY, unavailable/stopped/wrong target, HTTP failure, no direct fallback or UCI/runtime mutation")

        def update_runtime():
            result = subprocess.run(
                ["ucode", "-L", str(lib), str(LIB / "subscription/cache.uc"),
                 "update-request", "1", "rule", "1"],
                env=env, capture_output=True, text=True, timeout=90,
            )
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()

        common_uci = (
            f"forkop.settings=settings\nforkop.settings.config_path={inactive}\n"
            "forkop.rule=section\nforkop.rule.action=connection\nforkop.rule.enabled=1\n"
        )
        active["route"]["rules"][0]["outbound"] = "proxy-out"
        config.write_text(json.dumps(active))
        state.write_text(common_uci + "forkop.feed=subscription_url\nforkop.feed.section=rule\n"
                         "forkop.feed.url=https://runtime.invalid/feed\n"
                         "forkop.feed.download_via_proxy_enabled=1\n"
                         "forkop.feed.download_via_proxy_section=proxy\n")
        before = len(requests)
        assert update_runtime() == "0\t1\t0\t0"
        assert [path for path, _ in requests[before:]] == ["runtime.invalid:443"] * 3
        print("PASS: runtime uses the applied proxy, including with NO_PROXY and another path saved")

        cert, key = work / "cert.pem", work / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                        "-keyout", str(key), "-out", str(cert)],
                       check=True, capture_output=True, timeout=15)
        tls_server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
        tls_thread = threading.Thread(target=tls_server.serve_forever, daemon=True)
        tls_thread.start()
        try:
            env["CURL_CA_BUNDLE"] = str(cert)
            base = f"https://127.0.0.1:{tls_server.server_port}"
            old = f"forkop.old=subscription_url\nforkop.old.section=rule\nforkop.old.url={base}/superseded\n"
            new = f"forkop.new=subscription_url\nforkop.new.section=rule\nforkop.new.url={base}/new\n"
            reordered_sources = common_uci + new + old
            state.write_text(common_uci + old + new)
            result = update_runtime()
            assert result == "0\t0\t0\t1", ("response for moved source was not superseded", result)
            assert state.read_text() == reordered_sources
            assert not (work / "persistent" / "rule-subscription-1.json").exists()
            assert not (work / "xrust" / "subscriptions" / "rule-subscription-1.json").exists()
            assert update_runtime() == "1\t0\t0\t0"
            cached = json.loads((work / "persistent" / "rule-subscription-1.json").read_text())
            assert cached["__forkop_source_cache"]["url"] == f"{base}/new"
            print("PASS: discard a response after source relocation, then publish the current slot")
        finally:
            tls_server.shutdown()
            tls_server.server_close()
    finally:
        server.shutdown()
        server.server_close()
