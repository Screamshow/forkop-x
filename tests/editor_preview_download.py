"""Real curl/ucode preview downloads, isolated config and loopback HTTP proxy."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "forkop/files/usr/lib"
requests = []


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, dict(self.headers)))
        if "/fail" in self.path:
            self.send_error(503)
            return
        body = json.dumps({"outbounds": [{"type": "vless", "tag": "Working server",
                                         "server": "203.0.113.9", "server_port": 443,
                                         "uuid": "12345678-1234-1234-1234-123456789abc"}]}).encode()
        self.send_response(200)
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
    state = work / "uci.state"
    state.write_text(f"forkop.settings=settings\nforkop.settings.config_path={config}\n")
    state_hash = hashlib.sha256(state.read_bytes()).hexdigest()
    env = dict(os.environ, FORKOP_LIB=str(lib), FORKOP_UCI_STATE_FILE=str(state))
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
    finally:
        server.shutdown()
        server.server_close()
