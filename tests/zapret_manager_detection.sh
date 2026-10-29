#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT_DIR/forkop/files/usr/lib/diagnostics/runtime.uc"

# Exercise the production detector without touching installed launchers.
{
  cat <<'PRELUDE'
let sources = {};
let executable = {};
let fs = { readfile: function(path) { return sources[path]; } };
function as_string(value) { return value == null ? "" : "" + value; }
function file_executable(path) { return executable[path] == true; }
PRELUDE
  awk '/^function zapret_manager_launcher_installed\(/ { emit = 1 }
       /^function system_info_cache_is_valid\(/ { emit = 0 }
       emit { print }' "$RUNTIME"
  cat <<'UCODE'
let mirror = "#!/bin/sh\nexec sh <(wget -q -O - 'https://mirror.example/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh') \"$@\"\n";
let upstream = "sh <(wget -q -O - https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh)\n";
let upstream_auto = "sh <(wget -q -O - https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh) \"$@\"\n";
let legacy = replace(upstream, "StressOzz", "Screamshow");
let cases = [
    { name: "mirror", zms: mirror, auto: mirror, expected: true },
    { name: "upstream self-update", zms: upstream, auto: upstream_auto, expected: true },
    { name: "legacy upstream", zms: legacy, auto: legacy, expected: true },
    { name: "mixed launchers", zms: upstream, auto: mirror, expected: true },
    { name: "missing zms", auto: upstream_auto, expected: true },
    { name: "missing zmsA", zms: upstream, expected: true },
    { name: "missing both", expected: false },
    { name: "backend only", backend: true, expected: true },
    { name: "web launcher only", web: replace(upstream, "Zapret-Manager.sh", "ZapretManager_LuCI.sh"), expected: true },
    { name: "non-executable", zms: upstream, auto: upstream_auto, disabled: true, expected: true },
    { name: "unrelated launchers", zms: "#!/bin/sh\necho hello\n", expected: false },
    { name: "wrong repository", zms: replace(upstream, "StressOzz", "other"), expected: false },
    { name: "wrong script", zms: replace(upstream, "Manager.sh", "Manager.sh.backup"), expected: false }
];
for (let test in cases) {
    sources = { "/usr/bin/zms": test.zms, "/usr/bin/zmsA": test.auto, "/usr/bin/zmw": test.web };
    executable = {
        "/usr/bin/zms": test.zms != null && !test.disabled,
        "/usr/bin/zmsA": test.auto != null,
        "/usr/bin/zmw": test.web != null,
        "/opt/zapret-manager-luci/backend.sh": test.backend == true
    };
    if (zapret_manager_is_installed() != test.expected)
        die("FAIL: " + test.name + "\n");
    print("PASS: " + test.name + "\n");
}
UCODE
} | ucode -
