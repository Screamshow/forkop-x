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
FALLBACK_USER_AGENT = "sing-box/1.14.2"
runtime_rejected = False
redirect_destination = "/redirect-final"


class Handler(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        requests.append((self.path, dict(self.headers)))
        self.send_error(503)

    def do_GET(self):
        requests.append((self.path, dict(self.headers)))
        fallback = self.headers.get("User-Agent") == FALLBACK_USER_AGENT
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", redirect_destination)
            self.end_headers()
            return
        if "/rate-limit" in self.path:
            self.send_error(429)
            return
        if "/fail" in self.path:
            self.send_error(503)
            return
        if "/fallback-rejected" in self.path and not fallback:
            self.send_error(403)
            return
        if "/fallback-empty" in self.path and not fallback:
            self.send_response(204)
            self.end_headers()
            return
        if "/invalid" in self.path or ("/fallback-invalid" in self.path and not fallback) or (
                "/fallback-runtime" in self.path and (not fallback or runtime_rejected)):
            body = (b'{"outbounds":[{"type":"direct","tag":"Provider Direct"}]}'
                    if "/fallback-runtime" in self.path else b"invalid provider response")
            self.send_response(200)
            self.send_header("profile-title", "Rejected profile")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
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
        if self.path == "/yaml-comment":
            body = (
                "proxies:\n"
                "  - {name: A, type: vless, server: a.test, port: 443, uuid: 12345678-1234-1234-1234-123456789abc}\n"
                "# This comment does not terminate the sequence.\n"
                "  - {name: B, type: vless, server: b.test, port: 443, uuid: 12345678-1234-1234-1234-123456789abc}\n"
            ).encode()
        else:
            tag = "Replacement server" if self.path == "/pending" else "Working server"
            body = json.dumps({"outbounds": [{"type": "vless", "tag": tag,
                                             "server": "203.0.113.9", "server_port": 443,
                                             "uuid": "12345678-1234-1234-1234-123456789abc"}]}).encode()
        if "/gzip" in self.path:
            body = gzip.compress(body)
        self.send_response(200)
        if fallback:
            self.send_header("profile-title", "Fallback profile")
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
        assert len(requests) == 1, requests
        assert requests[-1][0] == "http://preview.invalid/feed?token=secret"
        assert requests[-1][1]["User-Agent"].startswith("INCY/")
        assert requests[-1][1]["X-HWID"] == profile["hwid"]
        assert "Working server" in Path(str(prefix) + ".json").read_text()
        assert Path(str(prefix) + ".curl").stat().st_mode & 0o777 == 0o600
        # Exercise the real editor dispatcher and generator as well as downloader.
        preview_root = work / "ui-state"
        preview_root.mkdir()
        preview_id = "editor-integration-test"
        (preview_root / (preview_id + ".json")).write_text(json.dumps({"sources": [{}] * 17}))
        before = len(requests)
        limited = subprocess.run(["ucode", "-L", str(lib), str(LIB / "subscription/editor.uc"),
                                  "preview", preview_id], env=dict(env, FORKOP_EDITOR_STATE_DIR=str(preview_root)),
                                 capture_output=True, text=True, check=True, timeout=10)
        assert json.loads(limited.stdout)["reason"] == "preview_source_limit"
        assert json.loads(limited.stdout)["limit"] == 16 and len(requests) == before
        (preview_root / (preview_id + ".json")).write_text(json.dumps({"section": "draft", "sources": [{
            "url": "http://preview.invalid/fallback-invalid?token=secret", "download_via_proxy_enabled": "1",
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
        yaml_path, yaml_profile = download("yaml", f"http://127.0.0.1:{port}/yaml-comment")
        assert not yaml_profile.get("error"), yaml_profile
        assert [node["tag"] for node in json.loads(yaml_path.with_suffix(".json").read_text())["outbounds"]] == ["A", "B"]
        assert "error" not in compressed, compressed
        _, too_large = download("too-large", f"http://127.0.0.1:{port}/too-large")
        assert "error" in too_large
        assert requests[-1][1]["User-Agent"] == direct["user_agent"]
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

        def assert_fallback_attempts(attempts, url):
            assert [path for path, _ in attempts] == [url, url], attempts
            assert [headers["User-Agent"] for _, headers in attempts] == [
                direct["user_agent"], FALLBACK_USER_AGENT]
            assert attempts[0][1]["X-HWID"] == attempts[1][1]["X-HWID"]

        assert_fallback_attempts(requests[before:], "/invalid")
        for path in ["fallback-invalid", "fallback-empty", "fallback-rejected"]:
            before = len(requests)
            url = f"http://preview.invalid/{path}?token=secret"
            prefix, fallback_profile = download(path, url, "proxy")
            assert_fallback_attempts(requests[before:], url)
            assert fallback_profile == {"user_agent": FALLBACK_USER_AGENT, "hwid": direct["hwid"]}
            assert "Working server" in Path(str(prefix) + ".json").read_text()
        before = len(requests)
        _, rejected = download("rate-limit", f"http://127.0.0.1:{port}/rate-limit")
        assert "error" in rejected and len(requests) == before + 1
        assert requests[-1][1]["User-Agent"] == direct["user_agent"]
        before = len(requests)
        for name, target, stopped in [("missing", "missing", False), ("stopped", "proxy", True),
                                       ("empty", "", False)]:
            _, failed = download(name, f"http://127.0.0.1:{port}/must-not-download", target, stopped)
            assert "error" in failed, failed
            assert len(requests) == before, "unavailable proxy silently downloaded directly"
        _, failed = download("http-fail", f"http://127.0.0.1:{port}/fail", "proxy")
        assert "error" in failed and len(requests) == before + 1
        assert all(path.startswith("http://") for path, _ in requests[before:]), "failed request bypassed the selected HTTP proxy"
        active["route"]["rules"][0]["outbound"] = "wrong-out"
        config.write_text(json.dumps(active))
        before = len(requests)
        _, failed = download("wrong-route", f"http://127.0.0.1:{port}/wrong", "proxy")
        assert "error" in failed and len(requests) == before
        assert hashlib.sha256(state.read_bytes()).hexdigest() == state_hash, "preview mutated UCI"
        assert json.loads(config.read_text()) == active, "preview mutated active config"
        print("PASS: real preview proxy/direct download, shared headers/parser, private request, NO_PROXY, unavailable/stopped/wrong target, HTTP failure, no direct fallback or UCI/runtime mutation")

        def cache_command(*args):
            result = subprocess.run(
                ["ucode", "-L", str(lib), str(LIB / "subscription/cache.uc"), *args],
                env=env, capture_output=True, text=True, timeout=90,
            )
            assert result.returncode == 0, result.stderr
            return result.stdout.strip()

        def update_runtime(force=True, source="1", guarded=False):
            return cache_command("update-request", str(int(force)), "rule", source, str(int(guarded)))

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
            state.write_text(common_uci + "forkop.feed=subscription_url\nforkop.feed.section=rule\n"
                             f"forkop.feed.url={base}/fallback-runtime\n")
            before = len(requests)
            batch = work / "private-batch"
            batch.mkdir(mode=0o700)
            cache_command("prefetch-direct", "1", "rule", "1", str(batch))
            assert_fallback_attempts(requests[before:], "/fallback-runtime")
            fetched = len(requests)
            result = cache_command("update-request", "1", "rule", "1", "0", str(batch))
            assert len(requests) == fetched, "locked update downloaded the direct response a second time"
            assert result == "1\t0\t0\t0", (result, requests[before:])
            assert_fallback_attempts(requests[before:], "/fallback-runtime")
            persistent = work / "persistent" / "rule-subscription-1.json"
            runtime = work / "xrust" / "subscriptions" / "rule-subscription-1.json"
            cached = persistent.read_bytes()
            assert runtime.read_bytes() == cached
            assert cache_command("update-request", "1", "rule", "1", "0", str(batch)) == "0\t0\t0\t1"
            assert runtime.read_bytes() == cached and len(requests) == fetched, "stale prefetch replaced newer cache"
            profile = json.loads(cached)["__forkop_source_cache"]
            assert profile["user_agent"] == FALLBACK_USER_AGENT
            assert profile["hwid"] == direct["hwid"]
            assert "Fallback profile" in json.dumps(profile["metadata"])
            assert "Rejected profile" not in json.dumps(profile["metadata"])
            runtime.unlink()
            runtime_rejected = True
            before = len(requests)
            assert update_runtime() == "0\t1\t0\t0"
            assert_fallback_attempts(requests[before:], "/fallback-runtime")
            assert persistent.read_bytes() == runtime.read_bytes() == cached
            persistent.unlink()
            runtime.unlink()
            print("PASS: INCY stays first, sing-box fallback uses the same route and HWID, and an invalid update retains the last working cache")

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

            def source_uci(name, url, interval="4h"):
                return (f"forkop.{name}=subscription_url\nforkop.{name}.section=rule\n"
                        f"forkop.{name}.url={url}\nforkop.{name}.subscription_update_interval={interval}\n")

            state.write_text(common_uci + source_uci("feed", f"{base}/redirect"))
            before = len(requests)
            assert update_runtime() in {"1\t0\t0\t0", "0\t0\t1\t0"}
            assert [path for path, _ in requests[before:]] == ["/redirect", "/redirect-final"]
            working = persistent.read_bytes()
            redirect_destination = f"http://127.0.0.1:{port}/insecure"
            before = len(requests)
            assert update_runtime() == "0\t1\t0\t0"
            assert all(path == "/redirect" for path, _ in requests[before:])
            assert persistent.read_bytes() == runtime.read_bytes() == working
            print("PASS: runtime follows HTTPS redirects and rejects HTTPS-to-HTTP downgrade")

            redirect_destination = "/pending"
            assert update_runtime(guarded=True) == "1\t0\t0\t0"
            proposed = runtime.read_bytes()
            assert proposed != working and persistent.read_bytes() == working
            cache_command("finish-source-update", "rollback")
            assert persistent.read_bytes() == runtime.read_bytes() == working
            assert update_runtime(guarded=True) == "1\t0\t0\t0"
            flash = persistent.parent
            saved_flash = work / "offline-flash"
            flash.rename(saved_flash)
            flash.touch()  # deterministic write failure even when running as root
            try:
                cache_command("finish-source-update", "commit")
            except AssertionError:
                pass
            else:
                raise AssertionError("failed flash persistence was reported as a success")
            assert runtime.read_bytes() == proposed
            flash.unlink()
            saved_flash.rename(flash)
            # The next update begins by recovering interrupted transactions.
            cache_command("finish-source-update", "rollback")
            assert persistent.read_bytes() == runtime.read_bytes() == proposed
            state.write_text(common_uci + source_uci("feed", f"{base}/changed-source"))
            assert update_runtime(guarded=True) == "1\t0\t0\t0"
            assert runtime.read_bytes() != proposed and persistent.read_bytes() == proposed
            cache_command("finish-source-update", "rollback")
            assert persistent.read_bytes() == runtime.read_bytes() == proposed
            print("PASS: guarded runtime cache only promotes after apply and restores the prior bytes on rollback")

            state.write_text(common_uci + source_uci("fast", f"{base}/schedule-fast", "1m") +
                             source_uci("slow", f"{base}/schedule-slow", "12h"))
            timestamps = runtime_state / "subscription-update"
            initial = set(timestamps.glob("*.timestamp"))
            update_runtime(source="1")
            fast_stamp, = set(timestamps.glob("*.timestamp")) - initial
            before = len(requests)
            update_runtime(force=False, source="")
            assert [path for path, _ in requests[before:]] == ["/schedule-slow"]
            fast_stamp.write_text("1\n")
            before = len(requests)
            update_runtime(force=False, source="")
            assert [path for path, _ in requests[before:]] == ["/schedule-fast"]
            print("PASS: manually refreshed and scheduled sources use separate timestamps and intervals")
        finally:
            tls_server.shutdown()
            tls_server.server_close()
    finally:
        server.shutdown()
        server.server_close()
