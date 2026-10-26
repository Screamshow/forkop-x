#!/bin/sh
# shellcheck shell=dash

MIRROR_BASE_URL="${FORKOP_MIRROR_BASE_URL:-https://mirror.51343.ru}"

APK_WORLD_FILE="${FORKOP_APK_WORLD_FILE:-/etc/apk/world}"
OPKG_DISTFEEDS_FILE="${FORKOP_OPKG_DISTFEEDS_FILE:-/etc/opkg/distfeeds.conf}"
APK_REPOSITORIES_FILE="${FORKOP_APK_REPOSITORIES_FILE:-/etc/apk/repositories}"
APK_DISTFEEDS_FILE="${FORKOP_APK_DISTFEEDS_FILE:-/etc/apk/repositories.d/distfeeds.list}"
CONNECT_TIMEOUT_SECONDS=15
METADATA_TIMEOUT_SECONDS=60
DOWNLOAD_TIMEOUT_SECONDS=600

PKG_IS_APK=0
MIRROR_SUPPORTED=0
REPOSITORY_MODE="native-feeds"
MIRROR_TRANSACTION_ACTIVE=0
MIRROR_BACKUP_COUNT=0
MIRROR_BACKUP_MANIFEST=""
FETCHER=""
TMP_DIR=""
FORKOP_WAS_ENABLED=0
FORKOP_WAS_RUNNING=0
FORKOP_LEGACY_DETECTED=0
LEGACY_CLEANUP_DONE=0
LEGACY_CLEANUP_STARTED=0
INSTALLER_LANG="en"
SING_BOX_INSTALL_VARIANT=""
CORE_PACKAGE_SPACE_KB=0

FORKOP_RELEASE_JSON=""
FORKOP_RELEASE_TAG=""
FORKOP_BACKEND_URL=""
FORKOP_BACKEND_SHA256=""
FORKOP_BACKEND_NAME=""
FORKOP_BACKEND_FILE=""
FORKOP_APP_URL=""
FORKOP_APP_SHA256=""
FORKOP_APP_NAME=""
FORKOP_APP_FILE=""
FORKOP_I18N_URL=""
FORKOP_I18N_SHA256=""
FORKOP_I18N_NAME=""
FORKOP_I18N_FILE=""
FORKOP_PACKAGE_VERSION=""
FORKOP_CONFIG_READY=1
FORKOP_CONFIG_VALIDATION_ERROR=""
INSTALL_MODE="clean"
FORKOP_CHANNEL="${FORKOP_CHANNEL:-stable}"
LEGACY_BRAND="$(printf '\160\157\144\153\157\160')"
LEGACY_BACKEND_PACKAGE="${LEGACY_BRAND}-plus"
LEGACY_CONFIG_PACKAGE_ALT="${LEGACY_BRAND}_plus"
LEGACY_CONFIG_BACKUP=""
LEGACY_CONFIG_PATH=""
UPDATE_TRANSACTION_ACTIVE=0
UPDATE_ROLLBACK_ATTEMPTED=0
UPDATE_ROLLBACK_FAILED=0
UPDATE_ROLLBACK_MANIFEST=""
UPDATE_HAD_I18N=0

command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

msg() {
    printf '\033[32;1m%s\033[0m\n' "$1"
}

warn() {
    printf '\033[33;1m%s\033[0m\n' "$1"
}

fail() {
    rollback_legacy_config_on_failure
    rollback_current_update
    [ "$UPDATE_ROLLBACK_ATTEMPTED" -ne 0 ] || restore_current_forkop_on_failure
    printf '\033[31;1m%s\033[0m\n' "$1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 [options]

Installs or updates Forkop packages:
  - forkop
  - luci-app-forkop
  - luci-i18n-forkop-ru (available when Russian is selected in LuCI)

Proxy core policy:
  - preserve the currently installed core (Xrust or a sing-box variant)
  - install Xrust from the Forkop mirror when no core is installed
  - run without interactive questions; stop if storage is insufficient

Options:
  --channel stable|canary      Release channel (stable is the default)
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --allow-low-space-tiny|--confirm-legacy-migration)
                warn "Obsolete option ignored: $1; installation is non-interactive"
                ;;
            --channel)
                shift
                [ "$#" -gt 0 ] || fail "--channel requires stable or canary"
                FORKOP_CHANNEL="$1"
                ;;
            --channel=*)
                FORKOP_CHANNEL="${1#--channel=}"
                ;;
            *)
                fail "Unknown installer option: $1"
                ;;
        esac
        shift
    done

    case "$FORKOP_CHANNEL" in
        stable|canary) ;;
        *) fail "Unsupported Forkop release channel: $FORKOP_CHANNEL" ;;
    esac
}

cleanup() {
    rollback_current_update
    rollback_package_mirror
    if [ "$UPDATE_ROLLBACK_FAILED" -eq 1 ]; then
        warn "Rollback files retained for recovery: $TMP_DIR"
        return
    fi
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

read_openwrt_release_value() {
    key="$1"

    [ -f /etc/openwrt_release ] || return 0
    sed -n "s/^${key}='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

init_tmp_dir() {
    TMP_DIR="$(mktemp -d /tmp/forkop.XXXXXX 2>/dev/null || true)"

    if [ -z "$TMP_DIR" ]; then
        TMP_DIR="/tmp/forkop.$$"
        mkdir -p "$TMP_DIR" || fail "Failed to create temporary directory: $TMP_DIR"
    fi
}

detect_fetcher() {
    if command_exists wget; then
        FETCHER="wget"
        return 0
    fi

    if command_exists curl; then
        FETCHER="curl"
        return 0
    fi

    fail "wget or curl is required to download Forkop"
}

run_with_deadline() {
    forkop_deadline_seconds="$1"
    shift

    forkop_deadline_helper="${FORKOP_DEADLINE_HELPER_PATH:-}"
    if [ -z "$forkop_deadline_helper" ]; then
        forkop_deadline_helper="$(install_deadline_helper_path)" || return 1
    fi

    forkop_deadline_result="$TMP_DIR/deadline-result.$$"
    "$forkop_deadline_helper" run "$forkop_deadline_seconds" "$forkop_deadline_result" "$@"
    forkop_deadline_status=$?
    rm -f "$forkop_deadline_result.output" "$forkop_deadline_result.error" \
        "$forkop_deadline_result.status" "$forkop_deadline_result.timeout"
    return "$forkop_deadline_status"
}

install_deadline_helper_path() {
    deadline_helper_path="$TMP_DIR/install-deadline.sh"

    if [ ! -s "$deadline_helper_path" ]; then
        cat > "$deadline_helper_path" <<'EOF'
#!/bin/sh

process_starttime() {
    local pid="$1"
    local stat rest

    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r stat < "/proc/$pid/stat" || return 1
    rest="${stat##*) }"
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf '%s\n' "$1"
}

child_pids() {
    local parent="$1"
    local status key value pid ppid

    for status in /proc/[0-9]*/status; do
        [ -r "$status" ] || continue
        pid=""
        ppid=""
        while IFS=: read -r key value; do
            case "$key" in
                Pid)
                    set -- $value
                    pid="${1:-}"
                    ;;
                PPid)
                    set -- $value
                    ppid="${1:-}"
                    ;;
            esac
        done < "$status"
        [ "$ppid" = "$parent" ] && [ -n "$pid" ] && printf '%s\n' "$pid"
    done
}

kill_descendants() {
    local parent="$1"
    local signal="$2"
    local child

    for child in $(child_pids "$parent"); do
        kill_descendants "$child" "$signal"
        kill "-$signal" "$child" 2>/dev/null || true
    done
}

kill_process_tree() {
    local root="$1"
    local expected_starttime="$2"
    local current_starttime

    current_starttime="$(process_starttime "$root" 2>/dev/null || true)"
    [ -n "$current_starttime" ] && [ "$current_starttime" = "$expected_starttime" ] || return 0

    kill -STOP "$root" 2>/dev/null || return 0
    kill_descendants "$root" TERM
    sleep 1
    kill_descendants "$root" KILL
    kill -KILL "$root" 2>/dev/null || true
}

run_command() {
    local seconds="$1"
    local result="$2"
    local command_pid command_starttime watchdog_pid status
    shift 2

    rm -f "$result.output" "$result.error" "$result.status" "$result.timeout"
    umask 077
    "$@" >"$result.output" 2>"$result.error" &
    command_pid=$!
    command_starttime="$(process_starttime "$command_pid" 2>/dev/null || true)"

    (
        local sleep_pid current_starttime
        trap 'kill "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
        sleep "$seconds" &
        sleep_pid=$!
        wait "$sleep_pid" || exit 0
        current_starttime="$(process_starttime "$command_pid" 2>/dev/null || true)"
        [ -n "$command_starttime" ] && [ "$current_starttime" = "$command_starttime" ] || exit 0
        : > "$result.timeout"
        kill_process_tree "$command_pid" "$command_starttime"
    ) >/dev/null 2>&1 &
    watchdog_pid=$!

    wait "$command_pid"
    status=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    [ ! -e "$result.timeout" ] || status=124
    printf '%s\n' "$status" > "$result.status"
    cat "$result.output"
    cat "$result.error" >&2
    return "$status"
}

case "${1:-}" in
    run)
        shift
        run_command "$@"
        ;;
    kill-tree)
        shift
        kill_process_tree "$1" "$2"
        ;;
    *)
        exit 2
        ;;
esac
EOF
        chmod 0700 "$deadline_helper_path" || return 1
    fi

    printf '%s\n' "$deadline_helper_path"
}

http_get() {
    case "$FETCHER" in
        wget)
            run_with_deadline "$METADATA_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -qO- "$1"
            ;;
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$METADATA_TIMEOUT_SECONDS" -fsSL "$1"
            ;;
        *)
            return 1
            ;;
    esac
}

install_json_helper_path() {
    helper_path="$TMP_DIR/install-json.uc"

    if [ ! -s "$helper_path" ]; then
        cat > "$helper_path" <<'EOF'
#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function read_stdin_json() {
    try {
        return json(read_stdin());
    }
    catch (e) {
        return null;
    }
}

function command_output(args) {
    let parts = [];
    for (let arg in args)
        push(parts, "'" + replace(as_string(arg), /'/g, "'\\''") + "'");
    let pipe = fs.popen(join(" ", parts) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function process_start_ticks(pid) {
    let stat = fs.readfile("/proc/" + as_string(pid) + "/stat");
    let marker = index(as_string(stat), ") ");
    if (marker < 0)
        return null;
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    return length(fields) >= 20 && match(as_string(fields[19]), /^[0-9]+$/) != null ? int(fields[19]) : null;
}

function sing_box_exe_path(path) {
    let basename = replace(replace(as_string(path), /[\r\n]+$/g, ""), /^.*\//, "");
    return basename == "sing-box" || basename == "sing-box (deleted)";
}

// Rust X also runs the independent Tailscale service from the same binary.
// Match LuCI's upgrade process selection; only the proxy runtime must stop.
function installer_sing_box_process(exe) {
    if (!sing_box_exe_path(command_output([ "readlink", exe ])))
        return false;
    let pid = split(exe, "/")[2];
    let args = split(fs.readfile("/proc/" + pid + "/cmdline") || "", chr(0));
    return args[1] != "tailscale-luci";
}

function managed_upgrade_sing_box_service_pid() {
    let data = command_output([ "ubus", "call", "service", "list", "{\"name\":\"sing-box\"}" ]);
    let service;
    try { service = json(data)["sing-box"]; } catch (e) { return 0; }
    let instances = service && type(service.instances) == "object" ? service.instances : {};
    for (let _, instance in instances) {
        if (type(instance) == "object" && instance.running === true && int(instance.pid || 0) > 0)
            return int(instance.pid);
    }
    return 0;
}

function managed_upgrade_sing_box_marker(path) {
    let pid = managed_upgrade_sing_box_service_pid();
    let ticks = process_start_ticks(pid);
    if (pid <= 0 || !installer_sing_box_process("/proc/" + pid + "/exe"))
        return;
    let count = 0;
    for (let exe in fs.glob("/proc/[0-9]*/exe")) {
        if (installer_sing_box_process(exe))
            count++;
    }
    if (count != 1 || ticks == null || managed_upgrade_sing_box_service_pid() != pid ||
        process_start_ticks(pid) != ticks ||
        !installer_sing_box_process("/proc/" + pid + "/exe"))
        return;
    let stamp = clock();
    let temporary = as_string(path) + ".new." + stamp[0] + "." + stamp[1];
    let body = "format=1\npid=" + pid + "\nstart_ticks=" + ticks + "\ncreated_at=" + stamp[0] + "\n";
    if (fs.writefile(temporary, body) != null && fs.rename(temporary, path))
        print("captured\n");
    else
        fs.unlink(temporary);
}

function starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function ends_with(value, suffix) {
    value = as_string(value);
    suffix = as_string(suffix);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

let uci_cursor_state = false;

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function truthy(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function uci_cursor() {
    if (uci_cursor_state !== false)
        return uci_cursor_state;

    try {
        uci_cursor_state = require("uci").cursor();
    }
    catch (e) {
        uci_cursor_state = null;
    }

    return uci_cursor_state;
}

function uci_available() {
    return uci_cursor() != null;
}

function uci_load(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        c.load(as_string(package_name));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function uci_value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function uci_get(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!uci_load(parts.package))
        return "";

    return uci_value_to_string(c.get(parts.package, parts.section, parts.option));
}

function uci_exists(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;
    if (!uci_load(parts.package))
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function uci_delete(path) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null)
        return false;

    try {
        if (parts.option == "")
            c.delete(parts.package, parts.section);
        else
            c.delete(parts.package, parts.section, parts.option);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_set(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value));
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_add_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    try {
        let values = uci_value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_del_list(path, value) {
    let parts = path_parts(path);
    let c = uci_cursor();
    if (c == null || parts == null || parts.option == "")
        return false;

    let values = [];
    let removed = false;
    for (let item in uci_value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            c.delete(parts.package, parts.section, parts.option);
        else
            c.set(parts.package, parts.section, parts.option, values);
        return true;
    }
    catch (e) {
        return false;
    }
}

function uci_commit(package_name) {
    let c = uci_cursor();
    if (c == null)
        return false;

    try {
        return c.commit(package_name) != false;
    }
    catch (e) {
        return false;
    }
}

function run(command) {
    return system(command) == 0;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function run_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : data;
}

function read_text_file(path) {
    let handle = fs.open(as_string(path), "r");
    if (!handle)
        return "";

    let data = handle.read("all");
    handle.close();
    return data == null ? "" : data;
}

function unlink_file(path) {
    try {
        fs.unlink(as_string(path));
    }
    catch (e) {
    }
}

function env(name, fallback) {
    let value = getenv(name);
    if (value == null || value == "")
        return as_string(fallback);
    return as_string(value);
}

const INSTALLER_FORKOP_INIT = env("FORKOP_INSTALLER_INIT", "/etc/init.d/forkop");
const INSTALLER_FORKOP_BIN = env("FORKOP_INSTALLER_BIN", "/usr/bin/forkop");
const INSTALLER_FORKOP_LIB = env("FORKOP_INSTALLER_LIB", "/usr/lib/forkop");
const INSTALLER_FORKOP_PERSISTENT_DIR = env("FORKOP_INSTALLER_PERSISTENT_DIR", "/etc/forkop");
const INSTALLER_FORKOP_UCI_DEFAULTS = env("FORKOP_INSTALLER_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-forkop");
const INSTALLER_FORKOP_LUCI_VIEW = env("FORKOP_INSTALLER_LUCI_VIEW", "/www/luci-static/resources/view/forkop");
const INSTALLER_MENU_JSON = env("FORKOP_INSTALLER_MENU_JSON", "/usr/share/luci/menu.d/luci-app-forkop.json");
const INSTALLER_ACL_JSON = env("FORKOP_INSTALLER_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-forkop.json");
const INSTALLER_RU_LMO = env("FORKOP_INSTALLER_RU_LMO", "/usr/lib/lua/luci/i18n/forkop.ru.lmo");
const INSTALLER_EN_LMO = env("FORKOP_INSTALLER_EN_LMO", "/usr/lib/lua/luci/i18n/forkop.en.lmo");
const INSTALLER_RU_LUA = env("FORKOP_INSTALLER_RU_LUA", "/usr/lib/lua/luci/i18n/forkop.ru.lua");
const INSTALLER_EN_LUA = env("FORKOP_INSTALLER_EN_LUA", "/usr/lib/lua/luci/i18n/forkop.en.lua");
const INSTALLER_RPCD_INIT = env("FORKOP_INSTALLER_RPCD_INIT", "/etc/init.d/rpcd");
const LEGACY_BRAND = env("FORKOP_INSTALLER_LEGACY_BRAND", "");
const LEGACY_BACKEND_PACKAGE = env("FORKOP_INSTALLER_LEGACY_BACKEND", LEGACY_BRAND + "-plus");
const LEGACY_CONFIG_PACKAGE_ALT = env("FORKOP_INSTALLER_LEGACY_CONFIG_ALT", LEGACY_BRAND + "_plus");
const INSTALLER_LEGACY_INIT = env("FORKOP_INSTALLER_LEGACY_INIT", "/etc/init.d/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_BASE_INIT = env("FORKOP_INSTALLER_LEGACY_BASE_INIT", "/etc/init.d/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_BIN = env("FORKOP_INSTALLER_LEGACY_BASE_BIN", "/usr/bin/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_LIB = env("FORKOP_INSTALLER_LEGACY_BASE_LIB", "/usr/lib/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_UCI_DEFAULTS = env("FORKOP_INSTALLER_LEGACY_BASE_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_LUCI_VIEW = env("FORKOP_INSTALLER_LEGACY_BASE_LUCI_VIEW", "/www/luci-static/resources/view/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_MENU_JSON = env("FORKOP_INSTALLER_LEGACY_BASE_MENU_JSON", "/usr/share/luci/menu.d/luci-app-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_ACL_JSON = env("FORKOP_INSTALLER_LEGACY_BASE_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_I18N = env("FORKOP_INSTALLER_LEGACY_BASE_I18N", "/usr/lib/lua/luci/i18n/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_CONFIG = env("FORKOP_INSTALLER_LEGACY_BASE_CONFIG", "/etc/config/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_PERSISTENT_DIR = env("FORKOP_INSTALLER_LEGACY_BASE_PERSISTENT_DIR", "/etc/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_RUNTIME_DIR = env("FORKOP_INSTALLER_LEGACY_BASE_RUNTIME_DIR", "/var/run/" + LEGACY_BRAND);
const INSTALLER_LEGACY_BASE_TMP_DIR = env("FORKOP_INSTALLER_LEGACY_BASE_TMP_DIR", "/tmp/" + LEGACY_BRAND);
const INSTALLER_LEGACY_TMP_PACKAGE_GLOB = env("FORKOP_INSTALLER_LEGACY_TMP_PACKAGE_GLOB", "/tmp/*" + LEGACY_BRAND + "*");
const INSTALLER_LEGACY_SCAN_ROOTS = env("FORKOP_INSTALLER_LEGACY_SCAN_ROOTS", "/tmp /var/run /etc /usr/lib /usr/share/luci /usr/share/rpcd /www/luci-static/resources/view");
const INSTALLER_LEGACY_BIN = env("FORKOP_INSTALLER_LEGACY_BIN", "/usr/bin/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_LIB = env("FORKOP_INSTALLER_LEGACY_LIB", "/usr/lib/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_UCI_DEFAULTS = env("FORKOP_INSTALLER_LEGACY_UCI_DEFAULTS", "/etc/uci-defaults/50_luci-" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_LUCI_VIEW = env("FORKOP_INSTALLER_LEGACY_LUCI_VIEW", "/www/luci-static/resources/view/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_LEGACY_MENU_JSON = env("FORKOP_INSTALLER_LEGACY_MENU_JSON", "/usr/share/luci/menu.d/luci-app-" + LEGACY_BACKEND_PACKAGE + ".json");
const INSTALLER_LEGACY_ACL_JSON = env("FORKOP_INSTALLER_LEGACY_ACL_JSON", "/usr/share/rpcd/acl.d/luci-app-" + LEGACY_BACKEND_PACKAGE + ".json");
const INSTALLER_LEGACY_CONFIG = env("FORKOP_INSTALLER_LEGACY_CONFIG", "/etc/config/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_CONFIG_ALT = env("FORKOP_INSTALLER_LEGACY_CONFIG_FILE_ALT", "/etc/config/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_LEGACY_PERSISTENT_DIR = env("FORKOP_INSTALLER_LEGACY_PERSISTENT_DIR", "/etc/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_RUNTIME_DIR = env("FORKOP_INSTALLER_LEGACY_RUNTIME_DIR", "/var/run/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_TMP_DIR = env("FORKOP_INSTALLER_LEGACY_TMP_DIR", "/tmp/" + LEGACY_BACKEND_PACKAGE);
const INSTALLER_LEGACY_TMP_ALT_DIR = env("FORKOP_INSTALLER_LEGACY_TMP_ALT_DIR", "/tmp/" + LEGACY_CONFIG_PACKAGE_ALT);
const INSTALLER_DEADLINE_HELPER = env("FORKOP_INSTALLER_DEADLINE_HELPER", "");
const INSTALLER_COMMAND_RESULT = env("FORKOP_INSTALLER_COMMAND_RESULT", "/tmp/forkop-installer-command");
const INSTALLER_RC_DIR = env("FORKOP_INSTALLER_RC_DIR", "/etc/rc.d");
const INSTALLER_START_RETRY_FILE = env("FORKOP_INSTALLER_START_RETRY_FILE", "/var/run/forkop/start.retry");
const INSTALLER_START_RETRY_PID_FILE = env("FORKOP_INSTALLER_START_RETRY_PID_FILE", "/var/run/forkop/start-retry.pid");
const INSTALLER_ORPHAN_PPID = env("FORKOP_INSTALLER_ORPHAN_PPID", "1");
const INSTALLER_SERVICE_PROBE_TIMEOUT = int(env("FORKOP_INSTALLER_SERVICE_PROBE_TIMEOUT", "6")) || 6;
const INSTALLER_SERVICE_ACTION_TIMEOUT = int(env("FORKOP_INSTALLER_SERVICE_ACTION_TIMEOUT", "60")) || 60;

let installer_command_sequence = 0;

function installer_command_result(args, timeout_seconds) {
    installer_command_sequence++;
    let result = INSTALLER_COMMAND_RESULT + "." + installer_command_sequence;
    let helper_args = [
        INSTALLER_DEADLINE_HELPER,
        "run",
        as_string(timeout_seconds),
        result
    ];
    for (let arg in args)
        push(helper_args, arg);

    let shell_status = normalize_status(system(command_from_args(helper_args) + " >/dev/null 2>&1"));
    let status_text = trim(read_text_file(result + ".status"));
    let complete = match(status_text, /^[0-9]+$/) != null;
    let status = complete ? int(status_text) : shell_status;
    let output = read_text_file(result + ".output");
    for (let suffix in [ ".output", ".error", ".status", ".timeout" ])
        unlink_file(result + suffix);

    return {
        status,
        output,
        complete,
        timed_out: status == 124
    };
}

let dns_owner_config = "forkop";
let dns_owner_section = "forkop";
let dns_owner_option_prefix = "forkop_";

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function path_executable(path) {
    return run_args([ "test", "-x", path ]);
}

function remove_path(path) {
    if (as_string(path) == "" || !path_exists(path))
        return true;
    return run_args([ "rm", "-rf", path ]);
}

function remove_glob(pattern) {
    pattern = as_string(pattern);
    if (pattern == "")
        return true;
    let removed = true;
    for (let path in fs.glob(pattern))
        if (!remove_path(path))
            removed = false;
    return removed;
}

function remove_globs(patterns) {
    let removed = true;
    for (let pattern in words(patterns))
        if (!remove_glob(pattern))
            removed = false;
    return removed;
}

function remove_legacy_named_children(root) {
    root = as_string(root);
    if (root == "" || LEGACY_BRAND == "")
        return true;

    let entries = fs.lsdir(root);
    if (type(entries) != "array")
        return true;

    let removed = true;
    let brand = lc(LEGACY_BRAND);
    for (let entry in entries) {
        entry = as_string(entry);
        let path = root + "/" + entry;
        if (index(lc(entry), brand) >= 0) {
            if (!remove_path(path))
                removed = false;
            continue;
        }

        let stat = fs.stat(path);
        if (stat != null && stat.type == "directory" && !remove_legacy_named_children(path))
            removed = false;
    }
    return removed;
}

function restart_dnsmasq() {
    return run("[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart");
}

function installer_package_manager() {
    return run_args([ "apk", "--version" ]) ? "apk" : "opkg";
}

function installer_installed_package_names() {
    let manager = installer_package_manager();
    let output = manager == "apk" ?
        command_output([ "apk", "info" ]) :
        command_output([ "opkg", "list-installed" ]);
    let names = [];

    for (let line in split(output, "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        if (manager == "opkg") {
            let parts = split(line, /[ \t]+/);
            line = parts[0] || "";
        }
        if (line != "")
            push(names, line);
    }

    return names;
}

function installer_package_installed(name) {
    name = as_string(name);
    if (name == "")
        return false;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "info", "-e", name ]);

    for (let installed in installer_installed_package_names())
        if (installed == name)
            return true;
    return false;
}

function installer_remove_package(name) {
    name = as_string(name);
    if (name == "" || !installer_package_installed(name))
        return true;

    if (installer_package_manager() == "apk")
        return run_args([ "apk", "del", name ]);
    return run_args([ "opkg", "remove", "--force-depends", name ]);
}

function installer_remove_package_prefix(prefix) {
    prefix = as_string(prefix);
    if (prefix == "")
        return true;

    let removed = true;
    for (let name in installer_installed_package_names())
        if (starts_with(name, prefix) && !installer_remove_package(name))
            removed = false;
    return removed;
}

function installer_confirm_remove_https_dns_proxy() {
    if (installer_package_installed("https-dns-proxy"))
        warn("Removing conflicting https-dns-proxy during installation\n");
    return true;
}

function path_basename(path) {
    let parts = split(as_string(path), "/");
    return length(parts) > 0 ? parts[length(parts) - 1] : "";
}

function installer_process_starttime(pid) {
    let stat = read_text_file("/proc/" + as_string(pid) + "/stat");
    let matched = match(stat, /^[0-9]+ \(.*\) [^ ]+ (.*)$/);
    if (!matched)
        return "";

    let fields = words(matched[1]);
    return length(fields) > 18 ? as_string(fields[18]) : "";
}

function installer_process_ppid(pid) {
    let matched = match(read_text_file("/proc/" + as_string(pid) + "/status"), /(^|\n)PPid:[ \t]*([0-9]+)/);
    return matched ? as_string(matched[2]) : "";
}

function installer_process_args(pid) {
    let args = [];
    for (let arg in split(read_text_file("/proc/" + as_string(pid) + "/cmdline"), "\0"))
        if (arg != "")
            push(args, arg);
    return args;
}

function installer_args_have_exact(args, value) {
    for (let arg in args)
        if (arg == value)
            return true;
    return false;
}

function installer_args_contain(args, value) {
    for (let arg in args)
        if (index(arg, value) >= 0)
            return true;
    return false;
}

function installer_kill_process_tree(pid) {
    let starttime = installer_process_starttime(pid);
    if (starttime == "" || INSTALLER_DEADLINE_HELPER == "")
        return false;
    return normalize_status(system(command_from_args([
        INSTALLER_DEADLINE_HELPER,
        "kill-tree",
        as_string(pid),
        starttime
    ]) + " >/dev/null 2>&1")) == 0;
}

function installer_cancel_stale_start_retry() {
    let pid = trim(read_text_file(INSTALLER_START_RETRY_PID_FILE));
    if (match(pid, /^[0-9]+$/)) {
        let args = installer_process_args(pid);
        if (installer_args_contain(args, INSTALLER_FORKOP_INIT) &&
            installer_args_contain(args, "retry_start_on_wan_up"))
            installer_kill_process_tree(pid);
    }
    unlink_file(INSTALLER_START_RETRY_PID_FILE);
    unlink_file(INSTALLER_START_RETRY_FILE);
}

function installer_recover_interrupted_cleanup(init_scripts) {
    installer_cancel_stale_start_retry();

    for (let status_path in fs.glob("/proc/[0-9]*/status")) {
        let parts = split(status_path, "/");
        let pid = length(parts) > 2 ? parts[2] : "";
        if (pid == "" || installer_process_ppid(pid) != INSTALLER_ORPHAN_PPID)
            continue;

        let args = installer_process_args(pid);
        if (length(args) == 0)
            continue;
        let action = args[length(args) - 1];
        let stale = false;

        if (action == "installer-cleanup-legacy") {
            for (let arg in args)
                if (ends_with(arg, "/install-json.uc") || arg == "install-json.uc")
                    stale = true;
        }
        else if (action == "enabled" || action == "status" || action == "running") {
            for (let init_script in init_scripts)
                if (init_script != "" && installer_args_have_exact(args, init_script))
                    stale = true;
        }

        if (stale)
            installer_kill_process_tree(pid);
    }
}

function installer_service_enabled_state(init_script) {
    if (!path_executable(init_script))
        return { known: true, value: false };

    let result = installer_command_result([ init_script, "enabled" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (result.complete && !result.timed_out)
        return { known: true, value: result.status == 0 };

    let service_name = path_basename(init_script);
    if (service_name != "" && length(fs.glob(INSTALLER_RC_DIR + "/S??" + service_name)) > 0)
        return { known: true, value: true };

    return { known: false, value: false };
}

function installer_service_running_state(init_script) {
    if (!path_executable(init_script))
        return { known: true, value: false };

    let status = installer_command_result([ init_script, "status" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (status.complete && !status.timed_out && trim(status.output) == "running")
        return { known: true, value: true };

    let running = installer_command_result([ init_script, "running" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (running.complete && !running.timed_out)
        return { known: true, value: running.status == 0 };

    return { known: false, value: false };
}

function installer_backend_status_running_state(bin_path) {
    if (!path_executable(bin_path))
        return { known: true, value: false };

    let result = installer_command_result([ bin_path, "get_status" ], INSTALLER_SERVICE_PROBE_TIMEOUT);
    if (!result.complete || result.timed_out)
        return { known: false, value: false };
    return { known: true, value: index(result.output, "\"running\":1") >= 0 };
}

function installer_service_action(init_script, action) {
    let result = installer_command_result([ init_script, action ], INSTALLER_SERVICE_ACTION_TIMEOUT);
    if (!result.complete || result.timed_out) {
        warn("Timed out while running " + init_script + " " + action + ".\n");
        return false;
    }
    return true;
}

function installer_sing_box_process_count() {
    let count = 0;
    for (let exe in fs.glob("/proc/[0-9]*/exe"))
        if (installer_sing_box_process(exe))
            count++;
    return count;
}

// An old Forkop stop may leave procd's sing-box service alive. Only
// recover instances whose exact processes are still registered with procd.
function installer_recover_stale_forkop_runtime() {
    let data = command_output([ "ubus", "call", "service", "list" ]);
    let service;
    try { service = json(data)["sing-box"]; } catch (e) { return false; }
    let instances = service && type(service.instances) == "object" ? service.instances : {};
    let owned = {};
    let count = 0;
    for (let _, instance in instances) {
        if (type(instance) != "object" || instance.running !== true)
            continue;
        let pid = int(instance.pid || 0);
        let ticks = process_start_ticks(pid);
        let command = instance.command;
        if (pid <= 0 || ticks == null || type(command) != "array" ||
            length(command) < 4 || command[0] != "/usr/bin/sing-box" ||
            command[1] != "run" || command[2] != "-c" ||
            command[3] != "/etc/sing-box/config.json" ||
            !installer_sing_box_process("/proc/" + pid + "/exe"))
            return false;
        owned[as_string(pid)] = ticks;
        count++;
    }
    // A second or orphaned process is not authority to signal it, even if its
    // executable and command line happen to match Forkop's.
    let seen = 0;
    for (let exe in fs.glob("/proc/[0-9]*/exe")) {
        if (!installer_sing_box_process(exe))
            continue;
        let parts = split(exe, "/");
        let pid = parts[2];
        if (owned[pid] == null || process_start_ticks(pid) != owned[pid])
            return false;
        seen++;
    }
    if (seen != count)
        return false;
    // procd unregisters the service before the package transaction. Recheck
    // identity immediately before the action; a reused PID fails closed.
    for (let pid, ticks in owned)
        if (process_start_ticks(pid) != ticks ||
            !installer_sing_box_process("/proc/" + pid + "/exe"))
            return false;
    let current = command_output([ "ubus", "call", "service", "list" ]);
    let current_service;
    try { current_service = json(current)["sing-box"]; } catch (e) { return false; }
    let current_instances = current_service && type(current_service.instances) == "object" ? current_service.instances : {};
    let current_count = 0;
    for (let _, instance in current_instances) {
        if (type(instance) != "object" || instance.running !== true)
            continue;
        let pid = as_string(instance.pid || 0);
        if (owned[pid] == null || process_start_ticks(pid) != owned[pid])
            return false;
        current_count++;
    }
    if (current_count != count)
        return false;
    installer_command_result([ "/etc/init.d/sing-box", "stop" ], INSTALLER_SERVICE_ACTION_TIMEOUT);
    let quiet = 0;
    for (let attempt = 0; attempt < 6; attempt++) {
        let after = command_output([ "ubus", "call", "service", "list" ]);
        let after_services;
        try { after_services = json(after); } catch (e) { return false; }
        let after_service = after_services["sing-box"];
        let after_instances = after_service && type(after_service.instances) == "object" ? after_service.instances : {};
        let active = installer_sing_box_process_count() > 0;
        for (let _, instance in after_instances)
            if (type(instance) == "object" && instance.running === true)
                active = true;
        quiet = active ? 0 : quiet + 1;
        if (quiet >= 2)
            break;
        run_args([ "sleep", "1" ]);
    }
    if (quiet < 2)
        return false;
    return true;
}

function installer_stop_old_forkop(init_script) {
    let stop = installer_command_result([ init_script, "stop" ], INSTALLER_SERVICE_ACTION_TIMEOUT);
    if (!stop.complete || stop.timed_out)
        warn("Timed out while running " + init_script + " stop.\n");

    if (installer_sing_box_process_count() > 0) {
        if (!installer_recover_stale_forkop_runtime()) {
            warn("Forkop stop left ambiguous sing-box ownership; preserving the runtime.\n");
            return false;
        }
        warn("Stopped the verified procd-owned sing-box runtime.\n");
    }
    if (installer_sing_box_process_count() > 0)
        return false;
    installer_cancel_stale_start_retry();
    unlink_file(env("FORKOP_INSTALLER_RELOAD_STATE_FILE", "/var/run/forkop/reload-state"));
    return installer_sing_box_process_count() == 0;
}

function select_dns_owner(legacy) {
    if (legacy) {
        dns_owner_config = LEGACY_BACKEND_PACKAGE;
        dns_owner_section = LEGACY_CONFIG_PACKAGE_ALT;
        dns_owner_option_prefix = LEGACY_BRAND + "_";
    }
    else {
        dns_owner_config = "forkop";
        dns_owner_section = "forkop";
        dns_owner_option_prefix = "forkop_";
    }
}

let dnsmasq_failsafe_restore;

function installer_restore_dnsmasq(bin_path, legacy) {
    if (path_executable(bin_path) && run_args([ bin_path, "restore_dnsmasq" ]))
        return true;

    select_dns_owner(legacy);
    return dnsmasq_failsafe_restore();
}

function installer_deactivate_legacy_base() {
    if (!path_executable(INSTALLER_LEGACY_BASE_INIT))
        return true;

    let running = installer_service_running_state(INSTALLER_LEGACY_BASE_INIT);
    let enabled = installer_service_enabled_state(INSTALLER_LEGACY_BASE_INIT);
    if (!running.known || !enabled.known) {
        warn("Unable to determine the legacy service state before installation.\n");
        return false;
    }

    if (running.value) {
        warn("Detected a running legacy service. Stopping it before installing Forkop.\n");
        if (!installer_service_action(INSTALLER_LEGACY_BASE_INIT, "stop"))
            return false;
    }

    if (enabled.value) {
        warn("Detected an enabled legacy autostart. Disabling it before installing Forkop.\n");
        if (!installer_service_action(INSTALLER_LEGACY_BASE_INIT, "disable"))
            return false;
    }
    return true;
}

function installer_cleanup_legacy() {
    let forkop_installed = installer_package_installed("forkop");
    let legacy_installed = LEGACY_BRAND != "" && installer_package_installed(LEGACY_BACKEND_PACKAGE);
    let active_init = legacy_installed ? INSTALLER_LEGACY_INIT : INSTALLER_FORKOP_INIT;
    let active_bin = legacy_installed ? INSTALLER_LEGACY_BIN : INSTALLER_FORKOP_BIN;

    installer_recover_interrupted_cleanup([
        active_init,
        INSTALLER_FORKOP_INIT,
        INSTALLER_LEGACY_INIT,
        INSTALLER_LEGACY_BASE_INIT
    ]);

    let enabled = installer_service_enabled_state(active_init);
    let running = installer_service_running_state(active_init);
    let backend_running = running.known && running.value ?
        { known: true, value: false } :
        installer_backend_status_running_state(active_bin);
    if (!enabled.known || (!running.known && !backend_running.known)) {
        warn("Unable to determine the Forkop service state before installation.\n");
        return false;
    }
    let was_enabled = enabled.value;
    let was_running = running.value || backend_running.value;

    if (!installer_confirm_remove_https_dns_proxy())
        return false;

    if (legacy_installed && !installer_deactivate_legacy_base())
        return false;

    if (path_executable(active_init)) {
        if (legacy_installed ? !installer_service_action(active_init, "stop") :
            !installer_stop_old_forkop(active_init))
            return false;
        installer_restore_dnsmasq(active_bin, legacy_installed);
        if (!installer_service_action(active_init, "disable"))
            return false;
    }

    let packages_removed = true;
    for (let package_name in [ "luci-app-https-dns-proxy", "https-dns-proxy" ])
        if (!installer_remove_package(package_name))
            packages_removed = false;
    if (!installer_remove_package_prefix("luci-i18n-https-dns-proxy"))
        packages_removed = false;

    if (legacy_installed) {
        if (!installer_remove_package_prefix("luci-i18n-" + LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
        if (!installer_remove_package("luci-app-" + LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
        if (!installer_remove_package(LEGACY_BACKEND_PACKAGE))
            packages_removed = false;
    }

    if (!forkop_installed) {
        if (!installer_remove_package_prefix("luci-i18n-forkop"))
            packages_removed = false;
        if (!installer_remove_package("luci-app-forkop"))
            packages_removed = false;
    }

    if (!packages_removed) {
        warn("Failed to remove one or more conflicting or legacy packages.\n");
        return false;
    }

    if (legacy_installed) {
        remove_path(INSTALLER_LEGACY_LIB);
        remove_path(INSTALLER_LEGACY_INIT);
        remove_path(INSTALLER_LEGACY_BIN);
        for (let path in [
            INSTALLER_LEGACY_LUCI_VIEW,
            INSTALLER_LEGACY_MENU_JSON,
            INSTALLER_LEGACY_ACL_JSON,
            INSTALLER_LEGACY_UCI_DEFAULTS
        ])
            remove_path(path);
    }

    if (!forkop_installed) {
        remove_path(INSTALLER_FORKOP_LIB);
        remove_path(INSTALLER_FORKOP_INIT);
        remove_path(INSTALLER_FORKOP_BIN);
        for (let path in [
            INSTALLER_FORKOP_LUCI_VIEW,
            INSTALLER_MENU_JSON,
            INSTALLER_ACL_JSON,
            INSTALLER_FORKOP_UCI_DEFAULTS,
            INSTALLER_RU_LMO,
            INSTALLER_EN_LMO,
            INSTALLER_RU_LUA,
            INSTALLER_EN_LUA
        ])
            remove_path(path);
    }

    print("FORKOP_WAS_ENABLED=", was_enabled ? "1" : "0", "\n");
    print("FORKOP_WAS_RUNNING=", was_running ? "1" : "0", "\n");
    print("FORKOP_LEGACY_DETECTED=", legacy_installed ? "1" : "0", "\n");
    return true;
}

function installer_finalize_legacy() {
    if (LEGACY_BRAND == "")
        return false;

    let legacy_tailscale_dir = INSTALLER_LEGACY_PERSISTENT_DIR + "/tailscale";
    if (path_exists(legacy_tailscale_dir)) {
        let entries = fs.lsdir(legacy_tailscale_dir);
        let forkop_tailscale_dir = INSTALLER_FORKOP_PERSISTENT_DIR + "/tailscale";
        if (type(entries) != "array" || !run_args([ "mkdir", "-p", forkop_tailscale_dir ])) {
            warn("Failed to prepare legacy Tailscale state migration; the legacy directory was preserved.\n");
            return false;
        }

        for (let entry in entries) {
            entry = as_string(entry);
            let source = legacy_tailscale_dir + "/" + entry;
            let target = forkop_tailscale_dir + "/" + entry;
            if (path_exists(target))
                continue;

            let temporary = forkop_tailscale_dir + "/." + entry + ".forkop-migrate";
            if (!remove_path(temporary) ||
                !run_args([ "cp", "-a", source, temporary ]) ||
                !run_args([ "mv", temporary, target ])) {
                remove_path(temporary);
                warn("Failed to migrate legacy Tailscale state; the legacy directory was preserved.\n");
                return false;
            }
        }
    }

    let cleaned = true;
    for (let path in [
        INSTALLER_LEGACY_CONFIG,
        INSTALLER_LEGACY_CONFIG_ALT,
        INSTALLER_LEGACY_PERSISTENT_DIR,
        INSTALLER_LEGACY_RUNTIME_DIR,
        INSTALLER_LEGACY_TMP_DIR,
        INSTALLER_LEGACY_TMP_ALT_DIR
    ])
        if (!remove_path(path))
            cleaned = false;

    for (let prefix in [
        INSTALLER_LEGACY_CONFIG,
        INSTALLER_LEGACY_CONFIG_ALT,
        INSTALLER_LEGACY_PERSISTENT_DIR,
        INSTALLER_LEGACY_RUNTIME_DIR,
        INSTALLER_LEGACY_TMP_DIR,
        INSTALLER_LEGACY_TMP_ALT_DIR,
        INSTALLER_LEGACY_INIT,
        INSTALLER_LEGACY_BIN,
        INSTALLER_LEGACY_LIB,
        INSTALLER_LEGACY_UCI_DEFAULTS,
        INSTALLER_LEGACY_LUCI_VIEW,
        INSTALLER_LEGACY_MENU_JSON,
        INSTALLER_LEGACY_ACL_JSON,
        INSTALLER_LEGACY_BASE_CONFIG,
        INSTALLER_LEGACY_BASE_PERSISTENT_DIR,
        INSTALLER_LEGACY_BASE_RUNTIME_DIR,
        INSTALLER_LEGACY_BASE_TMP_DIR,
        INSTALLER_LEGACY_BASE_INIT,
        INSTALLER_LEGACY_BASE_BIN,
        INSTALLER_LEGACY_BASE_LIB,
        INSTALLER_LEGACY_BASE_UCI_DEFAULTS,
        INSTALLER_LEGACY_BASE_LUCI_VIEW,
        INSTALLER_LEGACY_BASE_MENU_JSON,
        INSTALLER_LEGACY_BASE_ACL_JSON,
        INSTALLER_LEGACY_BASE_I18N
    ])
        if (!remove_glob(prefix + "*"))
            cleaned = false;

    if (!remove_glob(INSTALLER_LEGACY_TMP_PACKAGE_GLOB))
        cleaned = false;

    for (let root in words(INSTALLER_LEGACY_SCAN_ROOTS))
        if (!remove_legacy_named_children(root))
            cleaned = false;

    return cleaned;
}

function installer_post_install() {
    remove_globs(env("FORKOP_INSTALLER_LUCI_CACHE_GLOBS", "/var/luci-indexcache* /tmp/luci-indexcache*"));
    for (let path in [
        env("FORKOP_INSTALLER_LATEST_VERSION_CACHE", "/tmp/forkop.latest-version.cache"),
        env("FORKOP_INSTALLER_SYSTEM_INFO_CACHE", "/var/run/forkop/system-info.json"),
        env("FORKOP_INSTALLER_SERVER_COUNTRY_CACHE", "/var/run/forkop/server-country-cache.json"),
        env("FORKOP_INSTALLER_SING_BOX_VERSION_CACHE", "/var/run/forkop/ui-state/sing-box-version"),
        env("FORKOP_INSTALLER_TMP_SYSTEM_INFO_CACHE", "/tmp/forkop/system-info.json")
    ])
        remove_path(path);

    if (path_executable(INSTALLER_RPCD_INIT))
        run_args([ INSTALLER_RPCD_INIT, "reload" ]);

    let config_ready = env("FORKOP_CONFIG_READY", "1") == "1";

    let updating = env("FORKOP_INSTALL_MODE", "") == "update";
    if (config_ready && path_executable(INSTALLER_FORKOP_INIT) &&
        (updating || env("FORKOP_WAS_ENABLED", "0") == "1") &&
        !run_args([ INSTALLER_FORKOP_INIT, env("FORKOP_WAS_ENABLED", "0") == "1" ? "enable" : "disable" ]))
        return false;

    if (config_ready && env("FORKOP_WAS_RUNNING", "0") == "1" && path_executable(INSTALLER_FORKOP_INIT)) {
        if (!run_args([ INSTALLER_FORKOP_INIT, "start" ]) &&
            !run_args([ INSTALLER_FORKOP_INIT, "restart" ])) {
            warn("Failed to start Forkop after upgrade.\n");
            return false;
        }
    }

    if (config_ready && updating && env("FORKOP_WAS_RUNNING", "0") != "1")
        return installer_stop_old_forkop(INSTALLER_FORKOP_INIT);
    return true;
}

function installer_restore_previous_service() {
    if (!path_executable(INSTALLER_FORKOP_INIT))
        return false;
    if (!run_args([ INSTALLER_FORKOP_INIT, env("FORKOP_WAS_ENABLED", "0") == "1" ? "enable" : "disable" ]))
        return false;

    if (env("FORKOP_WAS_RUNNING", "0") == "1" && path_executable(INSTALLER_FORKOP_INIT))
        return run_args([ INSTALLER_FORKOP_INIT, "start" ]) ||
            run_args([ INSTALLER_FORKOP_INIT, "restart" ]);

    return installer_stop_old_forkop(INSTALLER_FORKOP_INIT);
}

function list_has(values, needle) {
    for (let value in words(values))
        if (value == needle)
            return true;
    return false;
}

function dnsmasq_managed_instance_exists() {
    return uci_exists("dhcp." + dns_owner_section);
}

function dnsmasq_default_servers() {
    return uci_get("dhcp.@dnsmasq[0].server");
}

function dnsmasq_default_has_managed_dns() {
    return list_has(dnsmasq_default_servers(), "127.0.0.42");
}

function dnsmasq_has_managed_dns() {
    return dnsmasq_default_has_managed_dns() || dnsmasq_managed_instance_exists();
}

function dnsmasq_has_managed_state() {
    // Forkop 1.3.11 snapshots are transaction-versioned. A bare
    // 127.0.0.42 server is not ownership proof and must never trigger this
    // legacy fallback's destructive restore path.
    if (dns_owner_option_prefix == "forkop_")
        return uci_get("dhcp.@dnsmasq[0].forkop_dns_version") == "1" ||
            dnsmasq_managed_instance_exists();

    return uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "server") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "noresolv") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "cachesize") != "" ||
        uci_get("dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "notinterface") != "" ||
        dnsmasq_managed_instance_exists();
}

function dnsmasq_management_disabled() {
    return truthy(uci_get(dns_owner_config + ".settings.dont_touch_dhcp"));
}

function dnsmasq_managed_interfaces() {
    let interfaces = uci_get("dhcp." + dns_owner_section + ".interface");
    if (interfaces == "")
        interfaces = uci_get(dns_owner_config + ".settings.source_network_interfaces");
    if (interfaces == "")
        interfaces = "br-lan";

    return interfaces;
}

function dnsmasq_cleanup_managed_instance() {
    let managed_instance_present = dnsmasq_managed_instance_exists();
    let managed_interfaces = managed_instance_present ? dnsmasq_managed_interfaces() : "";

    uci_delete("dhcp." + dns_owner_section);

    let backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "notinterface";
    let backup_notinterfaces = uci_get(backup_option);
    if (backup_notinterfaces != "") {
        uci_delete("dhcp.@dnsmasq[0].notinterface");
        for (let value in words(backup_notinterfaces))
            uci_add_list("dhcp.@dnsmasq[0].notinterface", value);
        uci_delete(backup_option);
        return;
    }

    if (managed_instance_present) {
        for (let value in words(managed_interfaces))
            uci_del_list("dhcp.@dnsmasq[0].notinterface", value);
    }

    uci_delete(backup_option);
}

function dnsmasq_restore_default_instance() {
    let server_list = dnsmasq_default_servers();
    let server_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "server";
    let backup_servers = uci_get(server_backup_option);
    let managed_global_dns = list_has(server_list, "127.0.0.42");

    uci_delete("dhcp.@dnsmasq[0].server");
    if (backup_servers != "") {
        for (let value in words(backup_servers))
            uci_add_list("dhcp.@dnsmasq[0].server", value);
        uci_delete(server_backup_option);
    }
    else {
        for (let value in words(server_list)) {
            if (value != "127.0.0.42")
                uci_add_list("dhcp.@dnsmasq[0].server", value);
        }
    }
    uci_delete(server_backup_option);

    let noresolv_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "noresolv";
    let noresolv = uci_get(noresolv_backup_option);
    if (noresolv != "") {
        uci_set("dhcp.@dnsmasq[0].noresolv", noresolv);
        uci_delete(noresolv_backup_option);
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].noresolv", "0");
    }

    let cachesize_backup_option = "dhcp.@dnsmasq[0]." + dns_owner_option_prefix + "cachesize";
    let cachesize = uci_get(cachesize_backup_option);
    if (cachesize != "") {
        uci_set("dhcp.@dnsmasq[0].cachesize", cachesize);
        uci_delete(cachesize_backup_option);
    }
    else if (managed_global_dns) {
        uci_set("dhcp.@dnsmasq[0].cachesize", "150");
    }
}

dnsmasq_failsafe_restore = function() {
    if (!uci_available())
        return true;

    // Delegate current Forkop state to the single transaction owner when it
    // is installed. The embedded helper intentionally has no interpretation
    // of the versioned snapshot and therefore cannot safely restore it.
    if (dns_owner_option_prefix == "forkop_") {
        if (path_executable("/usr/bin/ucode") && path_exists("/usr/lib/forkop/dns/apply.uc"))
            return run_args([ "/usr/bin/ucode", "/usr/lib/forkop/dns/apply.uc", "failsafe-restore" ]);
        return true;
    }

    if (dnsmasq_management_disabled() && !dnsmasq_has_managed_state())
        return true;

    if (!dnsmasq_has_managed_dns() && !dnsmasq_has_managed_state())
        return true;

    dnsmasq_cleanup_managed_instance();
    dnsmasq_restore_default_instance();
    uci_commit("dhcp");
    restart_dnsmasq();
    return true;
};

function release_version_valid(value) {
    return match(as_string(value), /^[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/) != null;
}

function asset_matches(name, kind, ext, version) {
    if (!release_version_valid(version))
        return false;

    if (kind == "backend")
        return name == "forkop_" + version + "." + ext;
    if (kind == "app")
        return name == "luci-app-forkop_" + version + "." + ext;
    if (kind == "i18n")
        return name == "luci-i18n-forkop-ru_" + version + "." + ext;
    return false;
}

// Mirror catalog of a core package (rust-x or sing-box-x) -> download plan.
function core_package_plan(name, arch, format, base) {
    if (name != "rust-x" && name != "sing-box-x")
        exit(1);
    let catalog = read_stdin_json();
    if (catalog?.schema != 1 || catalog?.name != name ||
        match(as_string(catalog.version), /^[0-9]+[.][0-9]+[.][0-9]+$/) == null)
        exit(1);
    for (let asset in catalog.assets || []) {
        if (asset.package != name || asset.format != format ||
            (asset.architecture != arch && !(format == "apk" && (arch == "aarch64" || arch == "aarch64_cortex-a73") && asset.architecture == "aarch64_cortex-a53")))
            continue;
        if (index(as_string(asset.name), name + "_") != 0 ||
            match(as_string(asset.name), /^[a-z-]+_[A-Za-z0-9_.+-]+[.](apk|ipk)$/) == null ||
            asset.url != base + "/forkop/" + name + "/releases/" + catalog.version + "/" + asset.name ||
            match(as_string(asset.sha256), /^[a-f0-9]{64}$/) == null || int(asset.installed_size) <= 0 || int(asset.size) <= 0)
            exit(1);
        print(asset.url, "\t", asset.sha256, "\t", asset.size, "\t", asset.installed_size, "\n");
        return;
    }
    exit(1);
}

function release_tag() {
    let release = read_stdin_json();
    if (type(release) == "object" && release.tag_name != null)
        print(as_string(release.tag_name), "\n");
}

function release_asset_url(kind, ext) {
    let release = read_stdin_json();
    if (type(release) != "object" || type(release.assets) != "array")
        return;
    let version = as_string(release.tag_name || "");
    if (!release_version_valid(version))
        return;
    for (let asset in release.assets) {
        if (type(asset) == "object" && asset_matches(asset.name, kind, ext, version)) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

function release_asset_sha256(kind, ext) {
    let release = read_stdin_json();
    if (type(release) != "object" || type(release.assets) != "array")
        return;
    let version = as_string(release.tag_name || "");
    if (!release_version_valid(version))
        return;
    for (let asset in release.assets) {
        if (type(asset) != "object" || !asset_matches(asset.name, kind, ext, version))
            continue;
        let digest = lc(as_string(asset.sha256 || ""));
        if (match(digest, /^[0-9a-f]{64}$/) != null)
            print(digest, "\n");
        return;
    }
}

let mode = ARGV[0] || "";

if (mode == "release-tag")
    release_tag();
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1], ARGV[2]);
else if (mode == "release-asset-sha256")
    release_asset_sha256(ARGV[1], ARGV[2]);
else if (mode == "release-catalog-entry") {
    let catalog = read_stdin_json();
    for (let release in catalog?.releases || [])
        if (release.tag_name == ARGV[1] && release_version_valid(release.tag_name)) {
            print(sprintf("%J", release));
            exit(0);
        }
    exit(1);
}
else if (mode == "installer-capture-service") {
    let enabled = installer_service_enabled_state(INSTALLER_FORKOP_INIT);
    let running = installer_service_running_state(INSTALLER_FORKOP_INIT);
    if (!enabled.known || !running.known) exit(1);
    print("FORKOP_WAS_ENABLED=", enabled.value ? "1" : "0", "\n",
        "FORKOP_WAS_RUNNING=", running.value ? "1" : "0", "\n");
}
else if (mode == "uci-get") {
    let value = uci_get(ARGV[1]);
    if (value != "")
        print(value, "\n");
}
else if (mode == "installer-dhcp-forkop-absent") {
    // The standalone helper remains available while old package hooks run.
    // Missing UCI evidence must not permit skipping service stop.
    let cursor = uci_cursor();
    if (cursor == null || cursor.load("dhcp") !== true)
        exit(1);
    exit(cursor.get("dhcp", "forkop") == null ? 0 : 1);
}
else if (mode == "dnsmasq-failsafe-restore")
    exit(dnsmasq_failsafe_restore() ? 0 : 1);
else if (mode == "installer-cleanup-legacy")
    exit(installer_cleanup_legacy() ? 0 : 1);
else if (mode == "installer-finalize-legacy")
    exit(installer_finalize_legacy() ? 0 : 1);
else if (mode == "installer-post-install")
    exit(installer_post_install() ? 0 : 1);
else if (mode == "installer-restore-previous-service")
    exit(installer_restore_previous_service() ? 0 : 1);
else if (mode == "installer-stop-current")
    exit(installer_stop_old_forkop(INSTALLER_FORKOP_INIT) ? 0 : 1);
else if (mode == "managed-upgrade-sing-box-marker")
    managed_upgrade_sing_box_marker(ARGV[1]);
else if (mode == "core-package-plan")
    core_package_plan(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else if (mode == "sing-box-exe-path-fixture")
    exit(sing_box_exe_path(ARGV[1]) ? 0 : 1);
else
    exit(1);
EOF
    fi

    printf '%s\n' "$helper_path"
}

install_json_ucode() {
    FORKOP_INSTALLER_LEGACY_BRAND="$LEGACY_BRAND" \
    FORKOP_INSTALLER_LEGACY_BACKEND="$LEGACY_BACKEND_PACKAGE" \
    FORKOP_INSTALLER_LEGACY_CONFIG_ALT="$LEGACY_CONFIG_PACKAGE_ALT" \
    FORKOP_INSTALLER_DEADLINE_HELPER="$(install_deadline_helper_path)" \
    FORKOP_INSTALLER_COMMAND_RESULT="$TMP_DIR/installer-command" \
    FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER="${FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER:-/tmp/forkop-managed-upgrade-sing-box}" \
        ucode "$(install_json_helper_path)" "$@"
}

download_file_once() (
    download_budget_kb="$(temporary_available_space_kb)" || return 1
    download_budget_kb=$((download_budget_kb - 8192))
    [ "$download_budget_kb" -gt 0 ] || { warn "Not enough temporary memory for download"; return 1; }
    # BusyBox sh uses 512-byte units. The limit applies only to this download.
    ulimit -f "$((download_budget_kb * 2))" || return 1
    case "$FETCHER" in
        wget)
            run_with_deadline "$DOWNLOAD_TIMEOUT_SECONDS" wget -T "$CONNECT_TIMEOUT_SECONDS" -q -O "$2" "$1"
            ;;
        curl)
            curl --connect-timeout "$CONNECT_TIMEOUT_SECONDS" --max-time "$DOWNLOAD_TIMEOUT_SECONDS" -fsSL "$1" -o "$2"
            ;;
        *)
            return 1
            ;;
    esac
)

download_with_retry() {
    url="$1"
    output_path="$2"
    label="$3"
    attempt=1
    max_attempts=3

    while [ "$attempt" -le "$max_attempts" ]; do
        msg "Downloading $label ($attempt/$max_attempts)"

        if download_file_once "$url" "$output_path" && [ -s "$output_path" ]; then
            return 0
        fi

        rm -f "$output_path"
        warn "Retrying $label"
        attempt=$((attempt + 1))
    done

    return 1
}

verify_download_sha256() {
    file_path="$1"
    expected="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
    label="$3"

    case "$expected" in
        *[!0-9a-f]*|'') fail "Release metadata has no valid SHA-256 for $label" ;;
    esac
    [ "${#expected}" -eq 64 ] || fail "Release metadata has no valid SHA-256 for $label"
    command_exists sha256sum || fail "sha256sum is required to verify $label"
    actual="$(sha256sum "$file_path" | awk '{print $1}')"
    [ "$actual" = "$expected" ] || fail "SHA-256 verification failed for $label"
}

pkg_is_installed() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -e "$pkg_name" 2>/dev/null | grep -Fxq "$pkg_name"
    else
        opkg list-installed 2>/dev/null | awk -v pkg="$pkg_name" '$1 == pkg { found = 1 } END { exit(found ? 0 : 1) }'
    fi
}

opkg_with_lock_retry() (
    # A lock acquisition failure happens before opkg changes any packages.
    # Do not retry dependency, download or package lifecycle failures.
    opkg_retry_output="$(mktemp /tmp/forkop-opkg-retry.XXXXXX)" || return 1
    trap 'rm -f "$opkg_retry_output"' EXIT
    trap 'exit 1' HUP INT TERM
    opkg_retry_attempt=0
    while :; do
        opkg_retry_status=0
        opkg "$@" </dev/null >"$opkg_retry_output" 2>&1 || opkg_retry_status=$?
        cat "$opkg_retry_output"
        [ "$opkg_retry_status" -ne 0 ] || return 0
        if ! grep -Fq 'opkg_conf_load: Could not lock ' "$opkg_retry_output" ||
            ! grep -Fq 'Resource temporarily unavailable' "$opkg_retry_output" ||
            [ "$opkg_retry_attempt" -ge 15 ]; then
            return "$opkg_retry_status"
        fi
        opkg_retry_attempt=$((opkg_retry_attempt + 1))
        printf '%s\n' "opkg is busy; retrying in 2 seconds ($opkg_retry_attempt/15)" >&2
        sleep 2 || return 1
    done
)

pkg_list_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update </dev/null
    else
        opkg_with_lock_retry update
    fi
}

repository_file_uses_forkop_mirror() {
    repository_file="$1"
    [ -r "$repository_file" ] || return 1
    grep -Fq 'https://mirror.51343.ru/' "$repository_file"
}

restore_native_repository_file() {
    repository_file="$1"
    backup="${repository_file}.pre-forkop-mirror"
    [ -f "$backup" ] || return 0
    # A persistent backup is authority only while the live repository remains
    # Forkop-owned. Never overwrite a vendor or user edit made afterwards.
    repository_file_uses_forkop_mirror "$repository_file" || return 0
    temporary="${repository_file}.forkop-restore"
    cp "$backup" "$temporary" || fail "Failed to restore $repository_file"
    chmod 0644 "$temporary" 2>/dev/null || true
    mv "$temporary" "$repository_file" || fail "Failed to activate restored $repository_file"
    rm -f "$backup"
}

remove_owned_apk_mirror_artifacts() {
    feed="/etc/apk/repositories.d/forkop.list"
    [ -f "$feed" ] || return 0
    grep -Fqx \
        -e 'https://mirror.51343.ru/forkop/mirror/current/packages.adb' \
        -e 'https://mirror.51343.ru/forkop/mirror/current/aarch64_cortex-a53/packages.adb' \
        -e 'https://mirror.51343.ru/forkop/mirror/current/x86_64/packages.adb' "$feed" || return 0
    rm -f "$feed" /etc/apk/keys/forkop-mirror.pem
}

restore_native_package_repositories() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        restore_native_repository_file "$APK_REPOSITORIES_FILE"
        restore_native_repository_file "$APK_DISTFEEDS_FILE"
        remove_owned_apk_mirror_artifacts
    else
        restore_native_repository_file "$OPKG_DISTFEEDS_FILE"
    fi
}

rollback_package_mirror() {
    [ "$MIRROR_TRANSACTION_ACTIVE" -eq 1 ] || return 0
    [ -n "$MIRROR_BACKUP_MANIFEST" ] && [ -f "$MIRROR_BACKUP_MANIFEST" ] || return 0

    while IFS='|' read -r repository_file backup_file; do
        [ -n "$repository_file" ] && [ -f "$backup_file" ] || continue
        cp "$backup_file" "$repository_file" 2>/dev/null || true
    done < "$MIRROR_BACKUP_MANIFEST"
    MIRROR_TRANSACTION_ACTIVE=0
    [ "${1:-}" = quiet ] || warn "Package feed configuration was restored after an installation error"
}

begin_package_mirror_transaction() {
    MIRROR_BACKUP_MANIFEST="$TMP_DIR/package-mirror-backups"
    : > "$MIRROR_BACKUP_MANIFEST"
    MIRROR_BACKUP_COUNT=0
    MIRROR_TRANSACTION_ACTIVE=1
}

rewrite_package_repository_file() {
    repository_file="$1"
    [ -e "$repository_file" ] || return 0

    rewritten="$TMP_DIR/repository.$MIRROR_BACKUP_COUNT.rewritten"
    # A release feed is recognised by what follows releases/ (a version with
    # targets/ or packages/, or the vNN.x vendor layout), so any mirror path
    # before it works: /releases, /openwrt/releases,
    # /downloads.openwrt.org/releases and so on.
    sed -E \
        -e "s#https?://[^/[:space:]]+/([^[:space:]]*/)?releases/(v[0-9]+\\.x/)#${MIRROR_BASE_URL}/openwrt/releases/\\2#" \
        -e "s#https?://[^/[:space:]]+/([^[:space:]]*/)?releases/([0-9]+\\.[0-9]+[^/[:space:]]*/(targets|packages)/)#${MIRROR_BASE_URL}/openwrt/releases/\\2#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v?([0-9]+\\.[0-9]+\\.[0-9]+)/mediatek/filogic/?([[:space:]]|$)#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/mediatek/filogic/packages\\2#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/targets/\\2/\\3/packages/packages.adb#" \
        -e "s#${MIRROR_BASE_URL}/openwrt/releases/v[0-9]+\\.x/v([0-9]+\\.[0-9]+\\.[0-9]+)/([^/]+)/([^/]+)/packages\\.adb#${MIRROR_BASE_URL}/openwrt/releases/\\1/packages/\\2/\\3/packages.adb#" \
        "$repository_file" > "$rewritten" || fail "Failed to prepare $repository_file"

    # Feeds of an unknown layout must not end up half redirected; the caller
    # keeps the native feeds instead (status 2).
    if grep -E 'https?://[^[:space:]]*/releases/' "$rewritten" |
        grep -Fv "$MIRROR_BASE_URL/openwrt/releases/" >/dev/null; then
        return 2
    fi

    if cmp -s "$repository_file" "$rewritten"; then
        return 0
    fi

    backup_file="$TMP_DIR/repository.$MIRROR_BACKUP_COUNT.original"
    cp "$repository_file" "$backup_file" || fail "Failed to back up $repository_file"
    printf '%s|%s\n' "$repository_file" "$backup_file" >> "$MIRROR_BACKUP_MANIFEST"
    persistent_backup="${repository_file}.pre-forkop-mirror"
    [ -e "$persistent_backup" ] || cp "$repository_file" "$persistent_backup" ||
        fail "Failed to preserve the original $repository_file"
    cp "$rewritten" "$repository_file" || fail "Failed to update $repository_file"
    MIRROR_BACKUP_COUNT=$((MIRROR_BACKUP_COUNT + 1))
}

commit_package_mirror_transaction() {
    MIRROR_TRANSACTION_ACTIVE=0
}

# Undo this run's feed rewrite and continue with the device's own feeds.
keep_native_feeds_for_unknown_layout() {
    rollback_package_mirror quiet
    REPOSITORY_MODE="native-feeds"
    warn "Package feeds in $1 use a layout the Forkop mirror cannot replace; keeping the native OpenWrt feeds"
}

normalize_mirror_base_url() {
    case "$MIRROR_BASE_URL" in
        https://*|http://*) ;;
        *) fail "Invalid Forkop mirror URL: $MIRROR_BASE_URL" ;;
    esac
    MIRROR_BASE_URL="${MIRROR_BASE_URL%/}"
}

configure_apk_mirror() {
    distfeeds="$APK_DISTFEEDS_FILE"
    mirror_key="/etc/apk/keys/forkop-mirror.pem"

    [ "$PKG_IS_APK" -eq 1 ] || return 0
    [ -s "$distfeeds" ] || fail "$distfeeds is missing or empty"

    normalize_mirror_base_url

    begin_package_mirror_transaction
    for repository_file in "$APK_REPOSITORIES_FILE" "$distfeeds"; do
        if ! rewrite_package_repository_file "$repository_file"; then
            keep_native_feeds_for_unknown_layout "$repository_file"
            return 0
        fi
    done
    if ! grep -Fq "$MIRROR_BASE_URL/openwrt/releases/" "$distfeeds"; then
        keep_native_feeds_for_unknown_layout "$distfeeds"
        return 0
    fi

    # The key is needed only once the feeds point at the mirror.
    mirror_key_tmp="$TMP_DIR/forkop-mirror.pem"
    if ! mkdir -p /etc/apk/keys ||
        ! download_with_retry "$MIRROR_BASE_URL/forkop/forkop-apk.pem" "$mirror_key_tmp" "Forkop mirror APK key" ||
        ! grep -Fq 'BEGIN PUBLIC KEY' "$mirror_key_tmp" ||
        ! cp "$mirror_key_tmp" "$mirror_key" || ! chmod 0644 "$mirror_key"; then
        rollback_package_mirror
        fail "Unable to install the Forkop mirror APK key; original feeds were restored"
    fi
    pkg_list_update || {
        rollback_package_mirror
        fail "Failed to update APK package lists from $MIRROR_BASE_URL; original feeds were restored"
    }
    commit_package_mirror_transaction
    msg "OpenWrt package feeds now use $MIRROR_BASE_URL"
}

configure_opkg_mirror() {
    distfeeds="$OPKG_DISTFEEDS_FILE"

    [ "$PKG_IS_APK" -eq 0 ] || return 0
    command_exists opkg || fail "OpenWrt opkg package manager is required"
    [ -s "$distfeeds" ] || fail "$distfeeds is missing or empty"

    normalize_mirror_base_url

    begin_package_mirror_transaction
    if ! rewrite_package_repository_file "$distfeeds" ||
        ! grep -Fq "$MIRROR_BASE_URL/openwrt/releases/" "$distfeeds"; then
        keep_native_feeds_for_unknown_layout "$distfeeds"
        return 0
    fi
    pkg_list_update || {
        rollback_package_mirror
        fail "Failed to update OPKG package lists from $MIRROR_BASE_URL; original feeds were restored"
    }
    commit_package_mirror_transaction
    msg "OpenWrt package feeds now use $MIRROR_BASE_URL"
}

repository_file_has_vendor_origin() {
    repository_file="$1"
    [ -r "$repository_file" ] || return 1
    # A vendor feed is not evidence that our mirror publishes a compatible
    # system repository. Routerich and GL.iNet therefore stay native.
    grep -Eqi 'https?://[^/]*(packages\.routerich\.ru|[^/]*gl[-.]?inet[^/]*)/' "$repository_file"
}

resolve_repository_mode() {
    REPOSITORY_MODE="native-feeds"
    [ "$MIRROR_SUPPORTED" -eq 1 ] || return 0

    if [ "$PKG_IS_APK" -eq 1 ]; then
        repository_file_has_vendor_origin "$APK_REPOSITORIES_FILE" && return 0
        repository_file_has_vendor_origin "$APK_DISTFEEDS_FILE" && return 0
    else
        repository_file_has_vendor_origin "$OPKG_DISTFEEDS_FILE" && return 0
    fi

    REPOSITORY_MODE="full-mirror"
}

configure_package_mirror() {
    resolve_repository_mode
    if [ "$REPOSITORY_MODE" != "full-mirror" ]; then
        restore_native_package_repositories
        msg "Forkop mirror does not provide system feeds for this platform; keeping native OpenWrt feeds"
        return 0
    fi

    if [ "$PKG_IS_APK" -eq 1 ]; then
        configure_apk_mirror
    else
        configure_opkg_mirror
    fi
}

pkg_install_name() {
    pkg_name="$1"

    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add "$pkg_name" </dev/null
    else
        opkg_with_lock_retry install "$pkg_name"
    fi
}

pkg_install_files() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        if [ -n "${FORKOP_INIT:-}" ]; then
            apk --preserve-env add --allow-untrusted --force-reinstall "$@" </dev/null
        else
            apk add --allow-untrusted --force-reinstall "$@" </dev/null
        fi
    else
        opkg_with_lock_retry install --force-overwrite --force-downgrade "$@"
    fi
}

ensure_bootstrap_tool() {
    tool_name="$1"
    package_name="$2"

    if command_exists "$tool_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_package() {
    package_name="$1"

    if pkg_is_installed "$package_name"; then
        return 0
    fi

    msg "Installing bootstrap dependency: $package_name"
    pkg_install_name "$package_name" || fail "Failed to install $package_name"
}

ensure_bootstrap_ucode_runtime() {
    ensure_bootstrap_tool "ucode" "ucode"
    ensure_bootstrap_package "ucode-mod-fs"
    ensure_bootstrap_package "ucode-mod-uci"
}

sync_time() {
    current_year=""

    if ! command_exists ntpd; then
        return 0
    fi

    current_year="$(date +%Y 2>/dev/null || true)"
    case "$current_year" in
        ''|*[!0-9]*) current_year=0 ;;
    esac

    if [ "$current_year" -ge 2024 ]; then
        return 0
    fi

    ntpd -q \
        -p 194.190.168.1 \
        -p 216.239.35.0 \
        -p 216.239.35.4 \
        -p 162.159.200.1 \
        -p 162.159.200.123 >/dev/null 2>&1 || true
}

check_root() {
    if command_exists id && [ "$(id -u)" != "0" ]; then
        fail "Please run this installer as root"
    fi
}

check_system() {
    release=""
    major=""
    model=""
    target=""
    architecture=""

    [ -f /etc/openwrt_release ] || fail "This installer supports OpenWrt only"

    model="$(cat /tmp/sysinfo/model 2>/dev/null || true)"
    [ -n "$model" ] && msg "Router model: $model"

    release="$(read_openwrt_release_value "DISTRIB_RELEASE")"
    target="$(read_openwrt_release_value "DISTRIB_TARGET")"
    architecture="$(read_openwrt_release_value "DISTRIB_ARCH")"
    MIRROR_SUPPORTED=0
    major="$(printf '%s' "$release" | sed 's/[^0-9].*$//' | cut -d. -f1)"

    [ -n "$release" ] || fail "Unable to detect the OpenWrt release"
    # Beam uses its own release number, unrelated to the OpenWrt version.
    # Keep this opt-in scoped to the verified main-based firmware and canary.
    if [ "$(read_openwrt_release_value "DISTRIB_ID")" = "Beam WRT" ] &&
        [ "$FORKOP_CHANNEL" = "canary" ] &&
        [ "$release" = "1.5.0" ] &&
        [ "$(read_openwrt_release_value "DISTRIB_REVISION")" = "r20260929-d958caf" ] &&
        [ "$target" = "qualcommbe/ipq95xx" ] &&
        [ "$architecture" = "aarch64_cortex-a73" ]; then
        [ "$PKG_IS_APK" -eq 1 ] || fail "Beam WRT 1.5.0 requires apk packages"
        warn "Beam WRT canary support is experimental; dependencies and kernel modules use Beam firmware feeds"
        msg "Beam WRT $release, target $target, architecture $architecture"
        return 0
    fi
    if [ -n "$major" ] && [ "$major" -lt 24 ]; then
        fail "Forkop requires OpenWrt 24.10 or newer"
    fi
    case "$release" in
        *SNAPSHOT*)
            warn "OpenWrt SNAPSHOT support is conditional: system dependencies use native firmware feeds"
            warn "Required kernel modules must match this firmware build and remain available in its feeds"
            ;;
        24.10.*)
            [ "$PKG_IS_APK" -eq 0 ] || fail "OpenWrt $release must use opkg/IPK packages"
            ;;
        24.*)
            fail "The mirror supports OpenWrt 24.10.x, but not $release"
            ;;
        *)
            [ "$PKG_IS_APK" -eq 1 ] || fail "OpenWrt $release is expected to use apk packages"
            ;;
    esac
    case "$release" in
        *SNAPSHOT*) ;;
        *)
            if [ "$target" = "mediatek/filogic" ] && [ "$architecture" = "aarch64_cortex-a53" ]; then
                MIRROR_SUPPORTED=1
            fi
            ;;
    esac

    msg "OpenWrt $release, target $target, architecture $architecture"

}

available_flash_space_kb() {
    available_space="$(df /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
    [ -n "$available_space" ] || available_space="$(df / 2>/dev/null | awk 'NR==2 {print $4}')"

    case "$available_space" in
        ''|*[!0-9]*) return 1 ;;
    esac

    printf '%s\n' "$available_space"
}

temporary_available_space_kb() {
    tmp_free="$(df -Pk "$TMP_DIR" | tail -n 1 | awk '{print $4}')"
    ram_free="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"
    case "$tmp_free:$ram_free" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "$tmp_free" -le "$ram_free" ] || tmp_free="$ram_free"
    printf '%s\n' "$tmp_free"
}

forkop_install_required_space_kb() {
    target_kb=0
    for package_file in "$FORKOP_BACKEND_FILE" "$FORKOP_APP_FILE" "$FORKOP_I18N_FILE"; do
        [ -n "$package_file" ] || continue
        package_kb="$(package_payload_size_kb "$package_file")" || return 1
        target_kb=$((target_kb + package_kb))
    done
    [ "$target_kb" -gt 0 ] || return 1
    rollback_kb=0
    if [ -n "$UPDATE_ROLLBACK_MANIFEST" ] && [ -r "$UPDATE_ROLLBACK_MANIFEST" ]; then
        while IFS="$(printf '\t')" read -r rollback_name rollback_version rollback_file; do
            package_kb="$(package_payload_size_kb "$rollback_file")" || return 1
            rollback_kb=$((rollback_kb + package_kb))
        done < "$UPDATE_ROLLBACK_MANIFEST"
    fi
    [ "$target_kb" -ge "$rollback_kb" ] || target_kb="$rollback_kb"
    printf '%s\n' "$((target_kb + 256 + ${CORE_PACKAGE_SPACE_KB:-0}))"
}

package_payload_size_kb() {
    payload_package="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        payload_bytes="$(apk --allow-untrusted adbdump "$payload_package" 2>/dev/null |
            awk '/^        size: [0-9]+$/ {sum += $2} END {printf "%.0f", sum}')"
    else
        # IPK Installed-Size has inconsistent units; measure data.tar.gz.
        payload_data="$(mktemp "$TMP_DIR/package-payload.XXXXXX")" || return 1
        if ! tar -xzOf "$payload_package" ./data.tar.gz > "$payload_data" 2>/dev/null &&
            ! tar -xzOf "$payload_package" data.tar.gz > "$payload_data" 2>/dev/null; then
            rm -f "$payload_data"
            return 1
        fi
        payload_listing="$(tar -tvzf "$payload_data" 2>/dev/null)" || {
            rm -f "$payload_data"
            return 1
        }
        rm -f "$payload_data"
        payload_bytes="$(printf '%s\n' "$payload_listing" | awk '{sum += $3} END {printf "%.0f", sum}')"
    fi
    case "$payload_bytes" in ''|*[!0-9]*|0) return 1 ;; esac
    printf '%s\n' "$(((payload_bytes + 1023) / 1024))"
}

pkg_remove_name() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del --force-broken-world "$1" </dev/null
    else
        opkg_with_lock_retry remove --force-depends "$1"
    fi
}

restore_current_forkop_on_failure() {
    [ "$INSTALL_MODE" = "update" ] || return 0
    [ "$LEGACY_CLEANUP_DONE" -eq 1 ] || return 0

    if FORKOP_WAS_ENABLED="$FORKOP_WAS_ENABLED" FORKOP_WAS_RUNNING="$FORKOP_WAS_RUNNING" \
        install_json_ucode installer-restore-previous-service; then
        warn "The previous Forkop service state was restored after the installation failure"
    else
        warn "Failed to restore the previous Forkop service state automatically"
    fi
}

installed_forkop_package_version() {
    ucode -L /usr/lib/forkop /usr/lib/forkop/core/packages.uc version "$1"
}

prepare_current_update_rollback() {
    [ "$INSTALL_MODE" = "update" ] || return 0
    rollback_original_catalog=""
    rollback_catalog="$(http_get "$MIRROR_BASE_URL/forkop/updates/releases.json")" ||
        fail "Cannot obtain exact previous Forkop packages for rollback"
    mkdir -p "$TMP_DIR/rollback" || fail "Cannot prepare update rollback"
    UPDATE_ROLLBACK_MANIFEST="$TMP_DIR/rollback/packages.tsv"
    : > "$UPDATE_ROLLBACK_MANIFEST"
    rollback_ext=ipk
    [ "$PKG_IS_APK" -eq 0 ] || rollback_ext=apk
    for rollback_name in luci-app-forkop luci-i18n-forkop-ru forkop; do
        rollback_version="$(installed_forkop_package_version "$rollback_name")" ||
            fail "Cannot determine installed $rollback_name version"
        if [ -z "$rollback_version" ]; then
            [ "$rollback_name" = luci-i18n-forkop-ru ] && continue
            fail "Cannot cache missing $rollback_name for rollback"
        fi
        [ "$rollback_name" != luci-i18n-forkop-ru ] || UPDATE_HAD_I18N=1
        rollback_tag="$(printf '%s' "$rollback_version" | sed 's/_rc\([0-9][0-9]*\)$/-canary.\1/')"
        if ! rollback_release="$(printf '%s' "$rollback_catalog" | install_json_ucode release-catalog-entry "$rollback_tag")"; then
            # Original Forkop uses the same package names. Its immutable
            # archives have a separate catalog so mirror sync cannot replace
            # them with Forkop X packages carrying the same version number.
            if [ -z "${rollback_original_catalog:-}" ]; then
                rollback_original_catalog="$(http_get "$MIRROR_BASE_URL/forkop/updates/original/releases.json")" ||
                    fail "Cannot obtain original Forkop packages for safe rollback"
            fi
            rollback_release="$(printf '%s' "$rollback_original_catalog" | install_json_ucode release-catalog-entry "$rollback_tag")" ||
                fail "Previous $rollback_name release is not available for safe rollback"
            msg "Caching original Forkop $rollback_version $rollback_name for rollback"
        fi
        case "$rollback_name" in
            forkop) rollback_kind=backend ;;
            luci-app-forkop) rollback_kind=app ;;
            *) rollback_kind=i18n ;;
        esac
        rollback_url="$(printf '%s' "$rollback_release" | install_json_ucode release-asset-url "$rollback_kind" "$rollback_ext")"
        rollback_hash="$(printf '%s' "$rollback_release" | install_json_ucode release-asset-sha256 "$rollback_kind" "$rollback_ext")"
        [ -n "$rollback_url" ] && [ -n "$rollback_hash" ] || fail "Incomplete rollback metadata for $rollback_name"
        rollback_file="$TMP_DIR/rollback/$rollback_name.$rollback_ext"
        download_with_retry "$(mirror_asset_url "$rollback_url")" "$rollback_file" "$rollback_name rollback" ||
            fail "Cannot download previous $rollback_name package"
        verify_download_sha256 "$rollback_file" "$rollback_hash" "$rollback_name rollback"
        printf '%s\t%s\t%s\n' "$rollback_name" "$rollback_version" "$rollback_file" >> "$UPDATE_ROLLBACK_MANIFEST"
    done
    cp "${FORKOP_INSTALLER_BACKUP_DIR:-/etc/forkop-backups}/configuration.tar.gz" "$TMP_DIR/rollback/configuration.tar.gz" ||
        fail "Cannot preserve configuration for update rollback"
    install_json_ucode installer-capture-service > "$TMP_DIR/rollback/service.env" ||
        fail "Cannot capture service state for update rollback"
    # shellcheck disable=SC1091
    . "$TMP_DIR/rollback/service.env"
    prepare_package_init_adapter || fail "Cannot prepare package lifecycle adapter"
    msg "Previous Forkop packages, configuration and service state cached for rollback"
}

prepare_package_init_adapter() {
    FORKOP_INSTALLER_JSON_HELPER="$(install_json_helper_path)" || return 1
    export FORKOP_INSTALLER_JSON_HELPER
    cat > "$TMP_DIR/package-init" <<'EOF'
#!/bin/sh
if [ "${1:-}" = stop ]; then
    active=0
    for exe in /proc/[0-9]*/exe; do
        target="$(readlink "$exe" 2>/dev/null || true)"
        case "$target" in /usr/bin/sing-box|'/usr/bin/sing-box (deleted)') active=1; break ;; esac
    done
    if [ "$active" = 0 ] &&
        ! nft list table inet "${NFT_TABLE_NAME:-ForkopTable}" >/dev/null 2>&1 &&
        [ -r "${FORKOP_INSTALLER_JSON_HELPER:-}" ] &&
        ucode "$FORKOP_INSTALLER_JSON_HELPER" installer-dhcp-forkop-absent; then
        exit 0
    fi
fi
exec /etc/init.d/forkop "$@"
EOF
    chmod 0700 "$TMP_DIR/package-init" || return 1
    FORKOP_INIT="$TMP_DIR/package-init"
    export FORKOP_INIT
}

rollback_current_update() {
    [ "$UPDATE_TRANSACTION_ACTIVE" -eq 1 ] || return 0
    [ "$UPDATE_ROLLBACK_ATTEMPTED" -eq 0 ] || return 0
    UPDATE_ROLLBACK_ATTEMPTED=1
    UPDATE_TRANSACTION_ACTIVE=0
    # An interrupt during rollback must retain recovery files as well.
    UPDATE_ROLLBACK_FAILED=1
    warn "Restoring previous Forkop configuration and packages"
    rollback_ok=1
    # Stop through the existing ownership-aware installer adapter. Never signal
    # arbitrary sing-box processes, and do not overwrite files if stop fails.
    if ! install_json_ucode installer-stop-current; then
        UPDATE_ROLLBACK_FAILED=1
        return 0
    fi
    rollback_config_dir="${FORKOP_INSTALLER_CONFIG_DIR:-/etc/config}"
    rollback_config_tmp="$(mktemp "$rollback_config_dir/.forkop-restore.XXXXXX")" || rollback_ok=0
    if [ "$rollback_ok" -eq 1 ]; then
        if ! tar -xOzf "$TMP_DIR/rollback/configuration.tar.gz" forkop > "$rollback_config_tmp" ||
            ! chmod 0600 "$rollback_config_tmp" || ! mv -f "$rollback_config_tmp" "$rollback_config_dir/forkop"; then
            rm -f "$rollback_config_tmp"
            rollback_ok=0
        fi
    fi
    # APK needs the complete matching package set in one transaction. No global
    # world-file overwrite: unrelated package-manager changes are preserved.
    if [ "$rollback_ok" -eq 1 ]; then
        set --
        while IFS="$(printf '\t')" read -r rollback_name rollback_version rollback_file; do
            set -- "$@" "$rollback_file"
        done < "$UPDATE_ROLLBACK_MANIFEST"
        if [ "$PKG_IS_APK" -eq 1 ]; then
            apk --preserve-env add --no-network --allow-untrusted --force-reinstall "$@" </dev/null || rollback_ok=0
        else
            opkg_with_lock_retry install --force-overwrite --force-reinstall --force-downgrade "$@" || rollback_ok=0
        fi
        if [ "$UPDATE_HAD_I18N" -eq 0 ] && pkg_is_installed luci-i18n-forkop-ru; then
            pkg_remove_name luci-i18n-forkop-ru || rollback_ok=0
        fi
        while IFS="$(printf '\t')" read -r rollback_name rollback_version rollback_file; do
            [ "$(installed_forkop_package_version "$rollback_name")" = "$rollback_version" ] || rollback_ok=0
        done < "$UPDATE_ROLLBACK_MANIFEST"
    fi
    # The old package's postinst may migrate options using the update's
    # environment. Reapply the snapshot after all old packages are installed.
    if [ "$rollback_ok" -eq 1 ]; then
        rollback_config_tmp="$(mktemp "$rollback_config_dir/.forkop-restore.XXXXXX")" || rollback_ok=0
        if [ "$rollback_ok" -eq 1 ] &&
            { ! tar -xOzf "$TMP_DIR/rollback/configuration.tar.gz" forkop > "$rollback_config_tmp" ||
              ! chmod 0600 "$rollback_config_tmp" || ! mv -f "$rollback_config_tmp" "$rollback_config_dir/forkop"; }; then
            rm -f "$rollback_config_tmp"
            rollback_ok=0
        fi
    fi
    if [ "$rollback_ok" -eq 1 ]; then
        FORKOP_WAS_ENABLED="$FORKOP_WAS_ENABLED" FORKOP_WAS_RUNNING="$FORKOP_WAS_RUNNING" \
            install_json_ucode installer-restore-previous-service || rollback_ok=0
    fi
    if [ "$rollback_ok" -eq 0 ]; then
        UPDATE_ROLLBACK_FAILED=1
        warn "Forkop rollback incomplete; recovery files will be retained"
    else
        UPDATE_ROLLBACK_FAILED=0
        warn "Previous Forkop configuration, packages and service state restored"
    fi
}

ensure_flash_space() {
    required_space="$(forkop_install_required_space_kb)" ||
        fail "Failed to measure Forkop package payloads"
    available_space="$(available_flash_space_kb)" || fail "Unable to determine free flash space"
    [ "$available_space" -ge "$required_space" ] ||
        fail "Not enough flash space: need ${required_space} KiB free, have ${available_space} KiB"
    tmp_space="$(temporary_available_space_kb)" || fail "Unable to determine temporary memory"
    # Package managers unpack to flash; downloaded archives already occupy RAM.
    tmp_need=8192
    if [ "${INSTALL_MODE:-}" = update ] &&
        [ "$(cat /etc/forkop/sing-box-variant 2>/dev/null)" = extended-compressed ]; then
        for backup_file in /usr/bin/sing-box /usr/lib/libcronet.so; do
            [ -f "$backup_file" ] || continue
            backup_bytes="$(wc -c < "$backup_file")" || fail "Cannot measure compressed sing-box backup"
            tmp_need=$((tmp_need + (backup_bytes + 1023) / 1024))
        done
    fi
    [ "$tmp_space" -ge "$tmp_need" ] ||
        fail "Not enough temporary memory: need ${tmp_need} KiB free, have ${tmp_space} KiB"
    msg "Storage preflight passed: flash ${required_space} KiB, temporary workspace ${tmp_need} KiB"
}

installer_is_ru() {
    [ "$INSTALLER_LANG" = "ru" ]
}

installer_text() {
    key="$1"

    if installer_is_ru; then
        case "$key" in
            i18n_installed) printf '%s\n' "Русский пакет интерфейса уже установлен и будет обновлен." ;;
            i18n_default) printf '%s\n' "Устанавливаю русский пакет интерфейса; язык LuCI не изменится." ;;
            sing_box_skip_msg) printf '%s\n' "Прокси-ядро уже установлено; оставляю его." ;;
            legacy_backup_ready) printf '%s\n' "Резервная копия legacy-конфигурации создана" ;;
            legacy_cleanup_start) printf '%s\n' "Удаляю legacy-пакеты и начинаю миграцию конфигурации" ;;
            *) printf '%s\n' "$key" ;;
        esac
        return 0
    fi

    case "$key" in
        i18n_installed) printf '%s\n' "The Russian interface package is already installed and will be updated." ;;
        i18n_default) printf '%s\n' "Installing the Russian interface package; the LuCI language will not change." ;;
        sing_box_skip_msg) printf '%s\n' "A proxy core is already installed; keeping it." ;;
        legacy_backup_ready) printf '%s\n' "Legacy configuration backup created" ;;
        legacy_cleanup_start) printf '%s\n' "Removing legacy packages and starting configuration migration" ;;
        *) printf '%s\n' "$key" ;;
    esac
}

detect_installer_language() {
    luci_lang="$(get_luci_main_lang)"

    INSTALLER_LANG="en"
    if pkg_is_installed "luci-i18n-forkop-ru"; then
        INSTALLER_LANG="ru"
        return 0
    fi

    case "$luci_lang" in
        ru|ru_*|ru-*) INSTALLER_LANG="ru" ;;
    esac
}

get_luci_main_lang() {
    command_exists ucode || return 0
    ucode -e 'require("fs"); require("uci");' >/dev/null 2>&1 || return 0
    install_json_ucode uci-get luci.main.lang 2>/dev/null || true
}

fetch_forkop_latest_release_json() {
    response="$(http_get "$MIRROR_BASE_URL/forkop/updates/${FORKOP_CHANNEL}.json" 2>/dev/null || true)"
    [ -n "$response" ] || fail "Failed to query Forkop release metadata from $MIRROR_BASE_URL"
    printf '%s' "$response"
}

persist_release_channel() {
    command_exists uci || return 0
    uci -q set "forkop.settings.update_channel=$FORKOP_CHANNEL" ||
        fail "Failed to save Forkop release channel"
    uci -q commit forkop || fail "Failed to save Forkop release channel"
}

mirror_asset_url() {
    case "$1" in
        http://*|https://*) printf '%s\n' "$1" ;;
        /*) printf '%s%s\n' "$MIRROR_BASE_URL" "$1" ;;
        *) printf '%s/%s\n' "$MIRROR_BASE_URL" "$1" ;;
    esac
}

# Sets RELEASE_ASSET_URL and RELEASE_ASSET_SHA256 for one package of the
# resolved release; the release must contain it.
resolve_release_asset() {
    RELEASE_ASSET_URL="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-asset-url "$1" "$asset_ext" 2>/dev/null)"
    [ -n "$RELEASE_ASSET_URL" ] || fail "The Forkop release does not contain a $2 .$asset_ext package"
    RELEASE_ASSET_URL="$(mirror_asset_url "$RELEASE_ASSET_URL")"
    RELEASE_ASSET_SHA256="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-asset-sha256 "$1" "$asset_ext" 2>/dev/null)"
}

resolve_forkop_release() {
    asset_ext="ipk"

    [ "$PKG_IS_APK" -eq 1 ] && asset_ext="apk"

    FORKOP_RELEASE_JSON="$(fetch_forkop_latest_release_json)"
    FORKOP_RELEASE_TAG="$(printf '%s' "$FORKOP_RELEASE_JSON" | install_json_ucode release-tag 2>/dev/null)"
    [ -n "$FORKOP_RELEASE_TAG" ] || fail "Failed to detect the Forkop release tag"

    resolve_release_asset backend forkop
    FORKOP_BACKEND_URL="$RELEASE_ASSET_URL"
    FORKOP_BACKEND_SHA256="$RELEASE_ASSET_SHA256"
    FORKOP_BACKEND_NAME="$(basename "$FORKOP_BACKEND_URL")"

    resolve_release_asset app luci-app-forkop
    FORKOP_APP_URL="$RELEASE_ASSET_URL"
    FORKOP_APP_SHA256="$RELEASE_ASSET_SHA256"
    FORKOP_APP_NAME="$(basename "$FORKOP_APP_URL")"

    # The Russian package is always installed; LuCI keeps its own language.
    resolve_release_asset i18n luci-i18n-forkop-ru
    FORKOP_I18N_URL="$RELEASE_ASSET_URL"
    FORKOP_I18N_SHA256="$RELEASE_ASSET_SHA256"
    FORKOP_I18N_NAME="$(basename "$FORKOP_I18N_URL")"

    FORKOP_PACKAGE_VERSION="$(printf '%s\n' "$FORKOP_BACKEND_NAME" | sed 's/^forkop_//;s/\.ipk$//;s/\.apk$//')"
}

sing_box_is_present() {
    command_exists sing-box ||
        pkg_is_installed "sing-box" ||
        pkg_is_installed "sing-box-tiny" ||
        pkg_is_installed "sing-box-extended" ||
        pkg_is_installed "sing-box-x" ||
        pkg_is_installed "rust-x"
}

select_sing_box_installation() {
    # Any installed core is kept. This includes a sing-box-extended binary
    # without a package (manual or from a legacy installation): Forkop no
    # longer installs those builds, and its backend adopts that binary.
    if sing_box_is_present; then
        SING_BOX_INSTALL_VARIANT=""
        return 0
    fi

    SING_BOX_INSTALL_VARIANT="rust-x"
    msg "No proxy core is installed; Xrust will be installed from the Forkop mirror"
}

# Check the mirror catalog of the core package the backend will install and
# reserve its flash space. The backend downloads the package itself and
# verifies its hash and size against the same catalog.
prepare_core_package_plan() {
    case "$SING_BOX_INSTALL_VARIANT" in
        rust-x) core_package=rust-x; core_label=Xrust ;;
        x) core_package=sing-box-x; core_label="sing-box X" ;;
        *) return 0 ;;
    esac
    format=ipk
    [ "$PKG_IS_APK" -eq 0 ] || format=apk
    http_get "$MIRROR_BASE_URL/forkop/$core_package/latest.json" > "$TMP_DIR/core-catalog.json" ||
        fail "Cannot read the $core_label mirror catalog"
    install_json_ucode core-package-plan "$core_package" "$(read_openwrt_release_value DISTRIB_ARCH)" "$format" "$MIRROR_BASE_URL" \
        < "$TMP_DIR/core-catalog.json" > "$TMP_DIR/core-plan.tsv" ||
        fail "$core_label is unavailable for this architecture in the Forkop mirror"
    IFS="$(printf '\t')" read -r core_url core_hash core_archive_bytes core_installed_bytes < "$TMP_DIR/core-plan.tsv"
    CORE_PACKAGE_SPACE_KB=$(((core_installed_bytes + 1023) / 1024 + 256))
    core_tmp_free="$(temporary_available_space_kb)" || fail "Unable to determine temporary memory"
    # The backend downloads the archive into tmpfs and needs workspace too.
    core_tmp_need=$(((core_archive_bytes + 1023) / 1024 + 8192))
    [ "$core_tmp_free" -ge "$core_tmp_need" ] ||
        fail "Not enough temporary memory for $core_label installation: need ${core_tmp_need} KiB, have ${core_tmp_free} KiB"
}

select_sing_box_for_release() {
    case "$SING_BOX_INSTALL_VARIANT" in rust-x|x) ;; *) return 0 ;; esac
    release_version="${FORKOP_RELEASE_TAG%%-*}"
    release_major="${release_version%%.*}"
    release_minor="${release_version#*.}"
    release_minor="${release_minor%%.*}"
    case "$release_major:$release_minor" in *[!0-9:]*|:*|*:) fail "Invalid Forkop release version" ;; esac
    # The shared installer also serves older releases: install_rust_x exists
    # since 2.2.0 and install_x since 2.0.0. Use the newest action they have.
    if [ "$release_major" -lt 2 ]; then
        SING_BOX_INSTALL_VARIANT=tiny
        msg "Selected Forkop release predates X integration; using its supported Tiny component action"
    elif [ "$SING_BOX_INSTALL_VARIANT" = rust-x ] && [ "$release_major" -eq 2 ] && [ "$release_minor" -lt 2 ]; then
        SING_BOX_INSTALL_VARIANT=x
        msg "Selected Forkop release predates Xrust integration; installing sing-box X instead"
    fi
}

install_selected_sing_box() {
    action=""
    output_file="$TMP_DIR/sing-box-component-action.json"

    case "$SING_BOX_INSTALL_VARIANT" in
        rust-x)
            action="install_rust_x"
            ;;
        x)
            action="install_x"
            ;;
        "")
            msg "$(installer_text sing_box_skip_msg)"
            return 0
            ;;
        stable)
            action="install_stable"
            ;;
        tiny)
            action="install_tiny"
            ;;
        *)
            fail "Unknown sing-box installation variant: $SING_BOX_INSTALL_VARIANT"
            ;;
    esac

    [ -x /usr/bin/forkop ] || fail "forkop backend must be installed before sing-box component action"
    msg "Installing the selected proxy core through the Forkop backend"
    if ! /usr/bin/forkop component_action sing_box "$action" >"$output_file" 2>&1; then
        cat "$output_file" >&2 2>/dev/null || true
        fail "Failed to install the selected proxy core"
    fi
}

cleanup_legacy_installation() {
    [ "$LEGACY_CLEANUP_DONE" -eq 0 ] || return 0

    state_file="$TMP_DIR/install-state.env"

    install_json_ucode installer-cleanup-legacy >"$state_file" ||
        fail "Failed to prepare the system before Forkop package installation"

    # shellcheck disable=SC1090
    . "$state_file"
    LEGACY_CLEANUP_DONE=1
}

detect_legacy_installation() {
    FORKOP_LEGACY_DETECTED=0
    LEGACY_CONFIG_BACKUP=""
    LEGACY_CONFIG_PATH=""

    if ! pkg_is_installed "$LEGACY_BACKEND_PACKAGE"; then
        legacy_config_present=0
        for legacy_config_path in \
            "/etc/config/$LEGACY_BACKEND_PACKAGE" \
            "/etc/config/$LEGACY_CONFIG_PACKAGE_ALT"; do
            if [ -r "$legacy_config_path" ]; then
                legacy_config_present=1
                break
            fi
        done
        [ "$legacy_config_present" -eq 1 ] || return 0
    fi

    FORKOP_LEGACY_DETECTED=1
    for legacy_config_path in \
        "/etc/config/$LEGACY_BACKEND_PACKAGE" \
        "/etc/config/$LEGACY_CONFIG_PACKAGE_ALT"; do
        if [ -r "$legacy_config_path" ]; then
            LEGACY_CONFIG_PATH="$legacy_config_path"
            break
        fi
    done

    msg "Legacy installation detected; its packages will be removed and its configuration will be upgraded"
}

detect_install_mode() {
    if [ "$FORKOP_LEGACY_DETECTED" -eq 1 ]; then
        INSTALL_MODE="legacy"
    elif pkg_is_installed "forkop"; then
        INSTALL_MODE="update"
    else
        INSTALL_MODE="clean"
    fi
    msg "Installation mode: $INSTALL_MODE"
}

prepare_legacy_config_backup() {
    [ -n "$LEGACY_CONFIG_PATH" ] || return 0

    LEGACY_CONFIG_BACKUP="/etc/.forkop-legacy-config-backup.$$"
    cp "$LEGACY_CONFIG_PATH" "$LEGACY_CONFIG_BACKUP" ||
        fail "Failed to back up the legacy configuration"
    chmod 0600 "$LEGACY_CONFIG_BACKUP" ||
        fail "Failed to secure the legacy configuration backup"
    msg "$(installer_text legacy_backup_ready): $LEGACY_CONFIG_BACKUP"
}

prepare_current_config_backup() {
    [ "$INSTALL_MODE" = "update" ] || return 0
    config_dir="${FORKOP_INSTALLER_CONFIG_DIR:-/etc/config}"
    backup_dir="${FORKOP_INSTALLER_BACKUP_DIR:-/etc/forkop-backups}"
    mkdir -p "$backup_dir" && chmod 0700 "$backup_dir" ||
        fail "Failed to prepare Forkop configuration backup directory"
    backup_tmp="$(mktemp "$backup_dir/.configuration.XXXXXX")" ||
        fail "Failed to create Forkop configuration backup"
    # Match LuCI's bounded, atomic backup policy. Keep the previous archive if
    # creating or validating the replacement fails.
    if ! tar -czf "$backup_tmp" -C "$config_dir" forkop ||
        ! tar -tzf "$backup_tmp" >/dev/null || ! chmod 0600 "$backup_tmp" ||
        ! mv -f "$backup_tmp" "$backup_dir/configuration.tar.gz"; then
        rm -f "$backup_tmp"
        fail "Failed to back up Forkop configuration"
    fi
    for old_backup in "$backup_dir"/before-*.tar.gz; do
        [ -f "$old_backup" ] || continue
        old_name="${old_backup##*/}"
        if printf '%s\n' "$old_name" | grep -Eq '^before-[0-9]+\.[0-9]+\.[0-9]+(-canary\.[0-9]+)?-[0-9]+\.tar\.gz$'; then
            rm -f "$old_backup" || fail "Failed to remove superseded Forkop configuration backup"
        fi
    done
    msg "Forkop configuration backup: $backup_dir/configuration.tar.gz"
}

rollback_legacy_config_on_failure() {
    [ -n "$LEGACY_CONFIG_BACKUP" ] && [ -r "$LEGACY_CONFIG_BACKUP" ] || return 0
    if [ "$LEGACY_CLEANUP_STARTED" -eq 0 ]; then
        rm -f "$LEGACY_CONFIG_BACKUP"
        LEGACY_CONFIG_BACKUP=""
        return 0
    fi
    [ -n "$LEGACY_CONFIG_PATH" ] || return 0

    cp "$LEGACY_CONFIG_BACKUP" "$LEGACY_CONFIG_PATH" 2>/dev/null || return 0
    chmod 0600 "$LEGACY_CONFIG_PATH" 2>/dev/null || true
    warn "Legacy configuration was restored after the failed migration. Its backup remains at $LEGACY_CONFIG_BACKUP"
}

confirm_legacy_migration() {
    [ "$FORKOP_LEGACY_DETECTED" -eq 1 ] || return 0
    msg "Preparing automatic legacy migration with configuration backup"
    prepare_legacy_config_backup
}

begin_legacy_migration() {
    [ "$FORKOP_LEGACY_DETECTED" -eq 1 ] || return 0

    msg "$(installer_text legacy_cleanup_start)"
    LEGACY_CLEANUP_STARTED=1
    cleanup_legacy_installation
}

remove_legacy_backup() {
    [ -n "$LEGACY_CONFIG_BACKUP" ] || return 0
    rm -f "$LEGACY_CONFIG_BACKUP"
    LEGACY_CONFIG_BACKUP=""
}

decide_i18n_installation() {
    detect_installer_language

    if pkg_is_installed "luci-i18n-forkop-ru"; then
        msg "$(installer_text i18n_installed)"
        return 0
    fi

    msg "$(installer_text i18n_default)"
}

download_forkop_packages() {
    FORKOP_BACKEND_FILE="$TMP_DIR/$FORKOP_BACKEND_NAME"
    FORKOP_APP_FILE="$TMP_DIR/$FORKOP_APP_NAME"
    FORKOP_I18N_FILE=""

    download_with_retry "$FORKOP_BACKEND_URL" "$FORKOP_BACKEND_FILE" "$FORKOP_BACKEND_NAME" || fail "Failed to download $FORKOP_BACKEND_NAME"
    download_with_retry "$FORKOP_APP_URL" "$FORKOP_APP_FILE" "$FORKOP_APP_NAME" || fail "Failed to download $FORKOP_APP_NAME"
    verify_download_sha256 "$FORKOP_BACKEND_FILE" "$FORKOP_BACKEND_SHA256" "$FORKOP_BACKEND_NAME"
    verify_download_sha256 "$FORKOP_APP_FILE" "$FORKOP_APP_SHA256" "$FORKOP_APP_NAME"

    if [ -n "$FORKOP_I18N_URL" ]; then
        FORKOP_I18N_FILE="$TMP_DIR/$FORKOP_I18N_NAME"
        download_with_retry "$FORKOP_I18N_URL" "$FORKOP_I18N_FILE" "$FORKOP_I18N_NAME" || fail "Failed to download $FORKOP_I18N_NAME"
        verify_download_sha256 "$FORKOP_I18N_FILE" "$FORKOP_I18N_SHA256" "$FORKOP_I18N_NAME"
    fi
}

# Install the packages the downloaded release would newly pull from the feeds
# (dependencies new to this release, flock in 2.4.1 for example) before any
# Forkop service is stopped: once it stops, the router can be offline until
# the new release starts, and a download at that point fails the update.
# A dry run lists them, nested ones included, without changing anything.
preinstall_release_dependencies() {
    set -- "$FORKOP_BACKEND_FILE" "$FORKOP_APP_FILE"
    [ -z "$FORKOP_I18N_FILE" ] || set -- "$@" "$FORKOP_I18N_FILE"
    dependency_check="$TMP_DIR/release-dependencies.log"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --simulate --allow-untrusted "$@" </dev/null >"$dependency_check" 2>&1
    else
        opkg_with_lock_retry install --noaction --force-overwrite --force-downgrade "$@" >"$dependency_check" 2>&1
    fi || {
        # For example a conflict that the update removes later.
        warn "New Forkop dependencies could not be listed in advance; the package manager installs them during the update"
        return 0
    }
    # apk: "(1/2) Installing flock (2.40-r1)"; opkg: "Installing flock (2.40-1) to root..."
    for dependency in $(sed -n -E 's/^(\([0-9]+\/[0-9]+\) )?Installing ([A-Za-z0-9][A-Za-z0-9._+-]*) \(.*/\2/p' "$dependency_check" | sort -u); do
        case "$dependency" in forkop|luci-app-forkop|luci-i18n-forkop-ru) continue ;; esac
        msg "Installing new Forkop dependency before stopping Forkop: $dependency"
        pkg_install_name "$dependency" || fail "Failed to install Forkop dependency $dependency"
    done
}

install_backend_package() {
    # This installer is a managed upgrade path. Record provenance before the
    # package manager invokes the old package prerm; a direct opkg/apk upgrade
    # has no marker and deliberately remains fail-closed after unpack.
    install_json_ucode managed-upgrade-sing-box-marker "${FORKOP_MANAGED_UPGRADE_SING_BOX_MARKER:-/tmp/forkop-managed-upgrade-sing-box}" >/dev/null 2>&1 || true
    pkg_install_files "$FORKOP_BACKEND_FILE" || fail "forkop installation failed"

    [ -x /usr/bin/forkop ] || fail "forkop executable is missing after package installation"
    /usr/bin/forkop package_postinst ||
        fail "Forkop configuration recovery or validation failed"
}

migrate_legacy_configuration() {
    [ "$FORKOP_LEGACY_DETECTED" -eq 1 ] || return 0

    if [ -n "$LEGACY_CONFIG_BACKUP" ]; then
        cp "$LEGACY_CONFIG_BACKUP" /etc/config/forkop ||
            fail "Failed to restore the legacy configuration for migration"
        chmod 0644 /etc/config/forkop ||
            fail "Failed to set permissions on the Forkop configuration"

        msg "Migrating the legacy configuration to Forkop"
        if ! FORKOP_CONFIG_NAME="forkop" \
            FORKOP_LIB="/usr/lib/forkop" \
            ucode -L /usr/lib/forkop /usr/lib/forkop/config/migration.uc migrate-podkop; then
            cp "$LEGACY_CONFIG_BACKUP" /etc/config/forkop 2>/dev/null || true
            fail "Legacy configuration migration failed; the original configuration was restored"
        fi
    else
        warn "The legacy package had no readable configuration; Forkop defaults will be used"
    fi

    install_json_ucode installer-finalize-legacy ||
        fail "Failed to remove legacy configuration and cache files after migration"
}

validate_installed_configuration() {
    validation_output="$TMP_DIR/config-validation.log"
    FORKOP_CONFIG_READY=1
    FORKOP_CONFIG_VALIDATION_ERROR=""

    if ! ucode -L /usr/lib/forkop /usr/lib/forkop/config/validator.uc check-requirements >"$validation_output" 2>&1 ||
        ! ucode -L /usr/lib/forkop /usr/lib/forkop/config/validator.uc validate-runtime >>"$validation_output" 2>&1; then
        FORKOP_CONFIG_READY=0
    fi

    [ "$FORKOP_CONFIG_READY" -eq 0 ] || return 0
    FORKOP_CONFIG_VALIDATION_ERROR="$(sed -n '1p' "$validation_output" 2>/dev/null || true)"
    [ -n "$FORKOP_CONFIG_VALIDATION_ERROR" ] || FORKOP_CONFIG_VALIDATION_ERROR="Forkop configuration validation failed"

    warn "Forkop configuration requires attention: $FORKOP_CONFIG_VALIDATION_ERROR"
    warn "Forkop will remain disabled. The configuration was preserved; fix it in LuCI before starting the service."
}

install_ui_packages() {
    pkg_install_files "$FORKOP_APP_FILE" || fail "luci-app-forkop installation failed"

    if [ -n "$FORKOP_I18N_FILE" ]; then
        pkg_install_files "$FORKOP_I18N_FILE" || fail "luci-i18n-forkop-ru installation failed"
    fi
}

post_install() {
    FORKOP_WAS_ENABLED="$FORKOP_WAS_ENABLED" FORKOP_WAS_RUNNING="$FORKOP_WAS_RUNNING" \
    FORKOP_CONFIG_READY="$FORKOP_CONFIG_READY" \
    FORKOP_INSTALL_MODE="$INSTALL_MODE" \
        install_json_ucode installer-post-install ||
        fail "Failed to complete Forkop post-install actions"
}

main() {
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    parse_args "$@"
    check_root
    init_tmp_dir
    detect_fetcher
    sync_time
    check_system
    configure_package_mirror

    detect_legacy_installation
    detect_install_mode
    decide_i18n_installation
    select_sing_box_installation

    pkg_list_update || fail "Failed to update package lists"
    ensure_bootstrap_ucode_runtime

    resolve_forkop_release
    select_sing_box_for_release
    msg "Downloading Forkop X packages before making system changes"
    download_forkop_packages
    prepare_core_package_plan

    confirm_legacy_migration
    prepare_current_config_backup
    prepare_current_update_rollback
    ensure_flash_space
    preinstall_release_dependencies

    if [ "$INSTALL_MODE" = "legacy" ]; then
        msg "Installing the Forkop X backend before removing legacy packages"
        install_backend_package
        begin_legacy_migration
        migrate_legacy_configuration
    else
        [ "$INSTALL_MODE" != "update" ] || UPDATE_TRANSACTION_ACTIVE=1
        cleanup_legacy_installation
        install_backend_package
    fi
    install_ui_packages
    persist_release_channel
    install_selected_sing_box
    validate_installed_configuration
    if [ "$INSTALL_MODE" = "update" ] && [ "$FORKOP_CONFIG_READY" -eq 0 ]; then
        fail "Updated Forkop configuration failed validation: $FORKOP_CONFIG_VALIDATION_ERROR"
    fi
    post_install
    remove_legacy_backup
    UPDATE_TRANSACTION_ACTIVE=0

    msg "Forkop $FORKOP_PACKAGE_VERSION has been installed successfully"
    msg "Source mirror: ${MIRROR_BASE_URL} (${FORKOP_RELEASE_TAG})"
    if [ "$FORKOP_CONFIG_READY" -eq 1 ]; then
        warn "Open LuCI and review your rules before enabling Forkop"
    else
        warn "Forkop was installed but not enabled because its configuration is incomplete"
        warn "Reason: $FORKOP_CONFIG_VALIDATION_ERROR"
    fi
}

main "$@"
