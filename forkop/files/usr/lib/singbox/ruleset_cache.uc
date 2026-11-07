#!/usr/bin/env ucode

let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let rulesets = require("singbox.rulesets");
let uci_core = require("core.uci");
let core_ip = require("core.ip");
let core_url = require("core.url");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CACHE_DIR = getenv("FORKOP_RULESET_CACHE_DIR") || "/etc/forkop/ruleset-cache";
const MANIFEST_PATH = getenv("FORKOP_RULESET_CACHE_MANIFEST") || CACHE_DIR + "/manifest.json";
const LIST_CACHE_DIR = getenv("FORKOP_PERSISTENT_LIST_CACHE_DIR") || "/etc/forkop/list-cache";
const RUNTIME_CACHE_DIR = getenv("FORKOP_RULESET_RUNTIME_CACHE_DIR") || "/tmp/sing-box/ruleset-cache";
const RUNTIME_MANIFEST_PATH = getenv("FORKOP_RULESET_RUNTIME_MANIFEST") || "/var/run/forkop/ruleset-cache-runtime.json";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const SING_BOX_CONFIG_PATH = getenv("FORKOP_SING_BOX_CONFIG_PATH") ||
    uci_core.get(CONFIG_NAME + ".settings.config_path") || "/etc/sing-box/config.json";
const TEMPORARY_FILE_MAX_AGE = int(getenv("FORKOP_RULESET_CACHE_TEMP_MAX_AGE") || "3600");
const PERSISTENT_CACHE_MAX_BYTES = int(getenv("FORKOP_PERSISTENT_LIST_CACHE_MAX_BYTES") || "8388608");
const PERSISTENT_CACHE_MIN_FREE_BYTES = int(getenv("FORKOP_PERSISTENT_LIST_CACHE_MIN_FREE_BYTES") || "8388608");
const DOWNLOAD_MIN_FREE_BYTES = int(getenv("FORKOP_LIST_DOWNLOAD_MIN_FREE_BYTES") || "8388608");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let escaped = [];
    for (let arg in args)
        push(escaped, shell_quote(arg));
    return join(" ", escaped);
}

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>/dev/null", "r");
    if (!pipe)
        return "";
    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function file_md5(path) {
    if (fs.stat(path) == null)
        return "";
    let fields = split(trim(command_output([ "md5sum", path ])), /[ \t\r\n]+/);
    return length(fields) > 0 ? as_string(fields[0]) : "";
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, 0, slash) : ".";
}

function allocated_bytes(path) {
    if (fs.stat(path) == null)
        return 0;
    let output = trim(command_output([ "du", "-sk", path ]));
    if (output == "")
        return -1;
    let fields = split(output, /[ \t\r\n]+/);
    return length(fields) > 0 ? int(fields[0]) * 1024 : -1;
}

function available_bytes(path, persistent) {
    let override = persistent ? getenv("FORKOP_PERSISTENT_LIST_CACHE_AVAILABLE_BYTES") : null;
    if (override != null && as_string(override) != "")
        return int(override);
    let output = trim(command_output([ "df", "-Pk", path ]));
    let lines = split(output, "\n");
    let fields = length(lines) >= 2 ? split(trim(lines[length(lines) - 1]), /[ \t]+/) : [];
    return length(fields) >= 4 ? int(fields[3]) * 1024 : -1;
}

function persistent_cache_can_store(target, new_bytes) {
    let list_bytes = allocated_bytes(LIST_CACHE_DIR);
    let ruleset_bytes = allocated_bytes(CACHE_DIR);
    let old_bytes = allocated_bytes(target);
    if (list_bytes < 0 || ruleset_bytes < 0 || old_bytes < 0)
        return false;
    let final_bytes = list_bytes + ruleset_bytes - old_bytes + new_bytes;
    let free_bytes = available_bytes(CACHE_DIR, true);
    return final_bytes <= PERSISTENT_CACHE_MAX_BYTES && free_bytes >= 0 &&
        free_bytes - new_bytes >= PERSISTENT_CACHE_MIN_FREE_BYTES;
}

function ensure_cache_dir() {
    return command_success([ "mkdir", "-p", CACHE_DIR ]) &&
        command_success([ "chmod", "0700", CACHE_DIR ]) &&
        command_success([ "mkdir", "-p", RUNTIME_CACHE_DIR ]) &&
        command_success([ "chmod", "0700", RUNTIME_CACHE_DIR ]);
}

function cleanup_stale_temporary_file(path, base, now, max_age) {
    let name = substr(path, length(base) + 1);
    let managed = match(name, /^[0-9a-f]{12}\.(srs|json)\.download\.[0-9]+\.[0-9]+(\.validated)?$/) != null ||
        match(name, /^manifest\.json\.[0-9]+\.[0-9]+\.tmp$/) != null ||
        match(name, /^\.validate-[0-9a-f]{12}\.json$/) != null;
    if (!managed)
        return;

    let stat = fs.stat(path);
    let mtime = stat == null ? 0 : int(stat.mtime || 0);
    if (mtime <= 0 || now < mtime || now - mtime >= max_age)
        fs.unlink(path);
}

function cleanup_stale_temporary_files() {
    let now = int(clock()[0]);
    let max_age = TEMPORARY_FILE_MAX_AGE >= 0 ? TEMPORARY_FILE_MAX_AGE : 3600;

    for (let path in fs.glob(CACHE_DIR + "/*"))
        cleanup_stale_temporary_file(path, CACHE_DIR, now, max_age);
    // BusyBox/ucode globbing does not include dotfiles in '*'.
    for (let path in fs.glob(CACHE_DIR + "/.*"))
        cleanup_stale_temporary_file(path, CACHE_DIR, now, max_age);
    for (let path in fs.glob(RUNTIME_CACHE_DIR + "/*"))
        cleanup_stale_temporary_file(path, RUNTIME_CACHE_DIR, now, max_age);
    for (let path in fs.glob(RUNTIME_CACHE_DIR + "/.*"))
        cleanup_stale_temporary_file(path, RUNTIME_CACHE_DIR, now, max_age);
}

function append_unique(values, value) {
    value = as_string(value);
    if (value == "")
        return;
    for (let existing in values)
        if (as_string(existing) == value)
            return;
    push(values, value);
}

function fallback_urls(url) {
    url = as_string(url);
    let result = [];
    let main_prefix = as_string(constants.SRS_MAIN_URL) + "/";
    if (substr(url, 0, length(main_prefix)) == main_prefix)
        append_unique(result, as_string(constants.SRS_FALLBACK_MAIN_URL) + "/" + substr(url, length(main_prefix)));
    let mirror_base = as_string(constants.FORKOP_MIRROR_BASE_URL);
    let secondary_mirror_prefix = mirror_base != "" ? mirror_base + "/forkop/lists/b4geoip-forkop/" : "";
    let secondary_cdn_prefix = "https://cdn.jsdelivr.net/gh/Greeg0ry/b4geoip-forkop@main/";
    let secondary_raw_prefix = "https://raw.githubusercontent.com/Greeg0ry/b4geoip-forkop/main/";
    if (secondary_mirror_prefix != "" && substr(url, 0, length(secondary_mirror_prefix)) == secondary_mirror_prefix) {
        let suffix = substr(url, length(secondary_mirror_prefix));
        append_unique(result, secondary_cdn_prefix + suffix);
        append_unique(result, secondary_raw_prefix + suffix);
    }
    else if (substr(url, 0, length(secondary_cdn_prefix)) == secondary_cdn_prefix)
        append_unique(result, secondary_raw_prefix + substr(url, length(secondary_cdn_prefix)));
    if (url == as_string(constants.SRS_ADS_HAGEZI_PRO_URL))
        append_unique(result, constants.SRS_FALLBACK_ADS_HAGEZI_PRO_URL);
    if (url == as_string(constants.SRS_SUPERCELL_URL))
        append_unique(result, constants.SRS_FALLBACK_SUPERCELL_URL);
    if (url == as_string(constants.SRS_GITHUB_URL))
        append_unique(result, constants.SRS_FALLBACK_GITHUB_URL);
    return result;
}

function candidate_urls(url) {
    let result = [];
    append_unique(result, url);
    for (let fallback in fallback_urls(url))
        append_unique(result, fallback);
    return result;
}

function identity_url(url) {
    let fallbacks = fallback_urls(url);
    return length(fallbacks) > 0 ? as_string(fallbacks[0]) : as_string(url);
}

function cache_key(url) {
    return rulesets.hash12(identity_url(url));
}

function cache_path(url, format) {
    return CACHE_DIR + "/" + cache_key(url) + (format == "source" ? ".json" : ".srs");
}

function runtime_cache_path(url, format) {
    return RUNTIME_CACHE_DIR + "/" + cache_key(url) + (format == "source" ? ".json" : ".srs");
}

function read_runtime_manifest() {
    return common.object_or_empty(common.read_json_file(RUNTIME_MANIFEST_PATH));
}

function write_runtime_manifest(manifest) {
    let dir = parent_dir(RUNTIME_MANIFEST_PATH);
    if (!command_success([ "mkdir", "-p", dir ]))
        return false;
    let stamp = clock();
    let temporary = RUNTIME_MANIFEST_PATH + "." + as_string(stamp[0]) + "." + as_string(stamp[1]) + ".tmp";
    fs.unlink(temporary);
    if (common.write_private_json_file(temporary, manifest) == null) {
        fs.unlink(temporary);
        return false;
    }
    if (!fs.rename(temporary, RUNTIME_MANIFEST_PATH)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

function valid_source(path) {
    let value = common.read_json_file(path);
    return type(value) == "object" && type(value.rules) == "array";
}

function binary_validation_path(path) {
    return as_string(path) + ".validated";
}

function binary_stat_signature(path) {
    let stat = fs.stat(path);
    if (stat == null)
        return "";
    return join(":", [ stat.inode, stat.size, stat.mtime, stat.ctime ]);
}

function binary_digest(path) {
    let digest = split(trim(command_output([ "sha256sum", path ])), /[ \t\r\n]+/)[0];
    return match(as_string(digest), /^[0-9a-f]{64}$/) != null ? digest : "";
}

function mark_binary_valid(path) {
    let signature = binary_stat_signature(path);
    let digest = signature != "" ? binary_digest(path) : "";
    return digest != "" && binary_stat_signature(path) == signature &&
        fs.writefile(binary_validation_path(path), signature + "\n" + digest + "\n") != null;
}

function trusted_binary_digest(path) {
    let signature = binary_stat_signature(path);
    let marker = split(trim(as_string(fs.readfile(binary_validation_path(path)))), "\n");
    if (signature == "" || length(marker) != 2 || marker[0] != signature)
        return "";
    let digest = binary_digest(path);
    return digest != "" && digest == marker[1] && binary_stat_signature(path) == signature ? digest : "";
}

function reuse_binary_validation(source, target) {
    let digest = trusted_binary_digest(source);
    let signature = binary_stat_signature(target);
    if (digest == "" || signature == "" || binary_digest(target) != digest ||
        trusted_binary_digest(source) != digest || binary_stat_signature(target) != signature)
        return false;
    // Transfer proof of identical validated bytes, never just file metadata.
    return fs.writefile(binary_validation_path(target), signature + "\n" + digest + "\n") != null;
}

function valid_binary(path) {
    let signature = binary_stat_signature(path);
    let validation_path = binary_validation_path(path);
    if (signature == "") {
        fs.unlink(validation_path);
        return false;
    }
    if (trusted_binary_digest(path) != "")
        return true;

    // Parse once for new bytes or legacy/stale markers. Keep the digest from
    // before parsing, so a changed file cannot inherit the parser's success.
    let digest = binary_digest(path);
    let ok = digest != "" && command_success([
        "sing-box", "rule-set", "match", "--format", "binary", path,
        "forkop-validation.invalid"
    ]) && binary_stat_signature(path) == signature && binary_digest(path) == digest;
    if (ok)
        fs.writefile(validation_path, signature + "\n" + digest + "\n");
    else
        fs.unlink(validation_path);
    return ok;
}
function valid_cache(path, format) {
    return format == "source" ? valid_source(path) : valid_binary(path);
}

function valid_runtime_entry(runtime_manifest, url, format) {
    let entry = common.object_or_empty(common.object_or_empty(runtime_manifest)[cache_key(url)]);
    let path = as_string(entry.path);
    return as_string(entry.url) == as_string(url) && as_string(entry.format) == format &&
        path == runtime_cache_path(url, format) && valid_cache(path, format) ? entry : null;
}

function active_cache_path(runtime_manifest, url, format) {
    let runtime = valid_runtime_entry(runtime_manifest, url, format);
    if (runtime != null)
        return as_string(runtime.path);
    return cache_path(url, format);
}

function duration_seconds(value) {
    let rest = as_string(value);
    if (rest == "")
        return 86400;
    let total = 0;
    let multipliers = { s: 1, m: 60, h: 3600, d: 86400 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+)([smhd])(.*)$/);
        if (matched == null)
            return 86400;
        total += int(matched[1]) * multipliers[matched[2]];
        rest = matched[3];
    }
    return total > 0 ? total : 86400;
}

function entry_is_due(entry, runtime_manifest) {
    entry = common.object_or_empty(entry);
    let format = as_string(entry.format) == "source" ? "source" : "binary";
    let runtime = valid_runtime_entry(runtime_manifest, entry.url, format);
    let path = runtime != null ? as_string(runtime.path) : cache_path(entry.url, format);
    if (!valid_cache(path, format))
        return true;
    let last = runtime != null ? int(runtime.last_success || "0") : int(entry.last_success || "0");
    let now = int(clock()[0]);
    let interval = duration_seconds(entry.update_interval);
    if (last <= 0)
        return true;
    if (now < last)
        return last - now > interval;
    return now - last >= interval;
}

function write_manifest(manifest) {
    let stamp = clock();
    let temporary = MANIFEST_PATH + "." + as_string(stamp[0]) + "." + as_string(stamp[1]) + ".tmp";
    fs.unlink(temporary);
    let text = sprintf("%J\n", manifest);
    let bytes = length(text) + 4095;
    if (!persistent_cache_can_store(MANIFEST_PATH, bytes) || common.write_private_file(temporary, text) == null) {
        fs.unlink(temporary);
        return false;
    }
    if (!fs.rename(temporary, MANIFEST_PATH)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

function bootstrap_dns_servers() {
    let result = [];
    let configured = uci_core.get(CONFIG_NAME + ".settings.bootstrap_dns_server");
    if (type(configured) != "array")
        configured = split(trim(as_string(configured)), /[ \t\r\n]+/);

    for (let value in configured) {
        let server = core_url.host(value);
        if (core_ip.valid_ip(server))
            push(result, server);
    }
    return result;
}

function bootstrap_resolve(url) {
    let host = core_url.host(url);
    if (host == "" || core_ip.valid_ip(host))
        return null;

    for (let server in bootstrap_dns_servers()) {
        let output = command_output([ "nslookup", host, server ]);
        let name_seen = false;
        let ipv6_address = "";
        for (let line in split(output, "\n")) {
            line = trim(as_string(line));
            if (index(line, "Name:") == 0) {
                name_seen = true;
                continue;
            }
            if (!name_seen)
                continue;
            let matched = match(line, /^Address([ \t]+[0-9]+)?:[ \t]*(.*)$/);
            if (matched == null)
                continue;
            let address = trim(as_string(matched[2]));
            if (core_ip.ip_family(address) == 4)
                return {
                    host,
                    port: core_url.port(url) || (core_url.scheme(url) == "http" ? "80" : "443"),
                    address
                };
            if (ipv6_address == "" && core_ip.ip_family(address) == 6)
                ipv6_address = address;
        }
        if (ipv6_address != "")
            return {
                host,
                port: core_url.port(url) || (core_url.scheme(url) == "http" ? "80" : "443"),
                address: ipv6_address
            };
    }
    return null;
}

function download_candidate(url, target, proxy_address, resolve) {
    let args = [ "curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "8", "--max-time", "30",
        "--speed-time", "15", "--speed-limit", "1" ];
    if (as_string(proxy_address) != "")
        push(args, "--proxy", "http://" + as_string(proxy_address));
    if (resolve != null) {
        push(args, "--resolve");
        push(args, resolve.host + ":" + resolve.port + ":" +
            (core_ip.ip_family(resolve.address) == 6 ? "[" + resolve.address + "]" : resolve.address));
    }
    push(args, "--output", target, url);
    let free_bytes = available_bytes(parent_dir(target), false);
    if (free_bytes < 0 || free_bytes <= DOWNLOAD_MIN_FREE_BYTES)
        return 1;
    let max_blocks = int((free_bytes - DOWNLOAD_MIN_FREE_BYTES) / 512);
    let status = int(system("ulimit -f " + max_blocks + "; " + command_from_args(args) + " >/dev/null 2>&1"));
    return status > 255 ? int(status / 256) : status;
}

function download_candidate_with_bootstrap(url, target, proxy_address) {
    let status = download_candidate(url, target, proxy_address, null);
    // A configured proxy owns destination DNS. The direct Bootstrap retry is
    // intentionally limited to curl's explicit name-resolution failure.
    if (status == 6 && as_string(proxy_address) == "") {
        let resolved = bootstrap_resolve(url);
        if (resolved != null) {
            warn("rule-set download retrying with Bootstrap DNS for ", resolved.host, "\n");
            status = download_candidate(url, target, proxy_address, resolved);
        }
    }
    return status == 0;
}

function commit_persistent_candidate(source, target, format) {
    let stamp = clock();
    let staged = target + ".download." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    fs.unlink(staged);
    fs.unlink(binary_validation_path(staged));
    if (!command_success([ "cp", source, staged ]) ||
        !(format == "binary" && reuse_binary_validation(source, staged) || valid_cache(staged, format)) || !fs.rename(staged, target)) {
        fs.unlink(staged);
        fs.unlink(binary_validation_path(staged));
        return false;
    }
    fs.unlink(binary_validation_path(staged));
    if (format == "binary")
        mark_binary_valid(target);
    command_success([ "chmod", "0600", target ]);
    return true;
}

function refresh_entry(entry, proxy_address, runtime_manifest) {
    entry = common.object_or_empty(entry);
    let url = as_string(entry.url);
    let format = as_string(entry.format) == "source" ? "source" : "binary";
    let persistent_target = cache_path(url, format);
    let runtime_target = runtime_cache_path(url, format);
    let stamp = clock();
    let temporary = runtime_target + ".download." + as_string(stamp[0]) + "." + as_string(stamp[1]);
    fs.unlink(temporary);
    fs.unlink(binary_validation_path(temporary));

    for (let candidate in candidate_urls(url)) {
        if (!download_candidate_with_bootstrap(candidate, temporary, proxy_address)) {
            fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            continue;
        }
        let current = active_cache_path(runtime_manifest, url, format);
        if (!(format == "binary" && reuse_binary_validation(current, temporary) || valid_cache(temporary, format))) {
            warn("rule-set download returned an invalid ", format, " payload for ", candidate, "\n");
            fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            continue;
        }
        let old_digest = format == "binary" ? binary_digest(current) : file_md5(current);
        let new_digest = format == "binary" ? binary_digest(temporary) : file_md5(temporary);
        if (old_digest != "" && old_digest == new_digest) {
            let new_bytes = allocated_bytes(temporary);
            if (current == runtime_target && new_bytes >= 0 && persistent_cache_can_store(persistent_target, new_bytes) &&
                commit_persistent_candidate(temporary, persistent_target, format)) {
                fs.unlink(temporary);
                fs.unlink(binary_validation_path(temporary));
                fs.unlink(runtime_target);
                fs.unlink(binary_validation_path(runtime_target));
                delete runtime_manifest[cache_key(url)];
                return { ok: true, changed: false, persisted: true };
            }
            fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            if (format == "binary")
                mark_binary_valid(current);
            return { ok: true, changed: false, persisted: current == persistent_target };
        }

        let new_bytes = allocated_bytes(temporary);
        let persisted = new_bytes >= 0 && persistent_cache_can_store(persistent_target, new_bytes);
        let target = persisted ? persistent_target : runtime_target;
        let committed = persisted ? commit_persistent_candidate(temporary, target, format) : fs.rename(temporary, target);
        if (committed) {
            if (persisted)
                fs.unlink(temporary);
            fs.unlink(binary_validation_path(temporary));
            if (!persisted && format == "binary")
                mark_binary_valid(target);
            if (!persisted)
                command_success([ "chmod", "0600", target ]);
            let key = cache_key(url);
            if (persisted) {
                fs.unlink(runtime_target);
                fs.unlink(binary_validation_path(runtime_target));
                delete runtime_manifest[key];
            }
            else {
                runtime_manifest[key] = {
                    url,
                    format,
                    update_interval: as_string(entry.update_interval),
                    last_success: int(clock()[0]),
                    path: runtime_target
                };
            }
            return { ok: true, changed: true, persisted };
        }
        fs.unlink(temporary);
        fs.unlink(binary_validation_path(temporary));
        return { ok: false, changed: false };
    }
    return { ok: false, changed: false, persisted: false };
}

function empty_ruleset_path(url) {
    let path = RUNTIME_CACHE_DIR + "/empty-" + cache_key(url) + ".json";
    if (!valid_source(path))
        common.write_json_file(path, { version: 1, rules: [] });
    command_success([ "chmod", "0600", path ]);
    return path;
}

function prune_stale_cache(manifest) {
    let keep = {};
    for (let key, entry in common.object_or_empty(manifest)) {
        let format = as_string(entry.format) == "source" ? "source" : "binary";
        let path = cache_path(entry.url, format);
        keep[path] = true;
        keep[CACHE_DIR + "/empty-" + cache_key(entry.url) + ".json"] = true;
        if (format == "binary")
            keep[binary_validation_path(path)] = true;
    }

    for (let path in fs.glob(CACHE_DIR + "/*")) {
        let name = substr(path, length(CACHE_DIR) + 1);
        let managed = match(name, /^[0-9a-f]{12}\.(srs|json)(\.validated)?$/) ||
            match(name, /^empty-[0-9a-f]{12}\.json$/);
        if (managed && !keep[path])
            fs.unlink(path);
    }
}

function prune_runtime_cache(manifest, runtime_manifest) {
    let keep = {};
    for (let key, entry in common.object_or_empty(manifest))
        keep[RUNTIME_CACHE_DIR + "/empty-" + key + ".json"] = true;
    for (let key, entry in common.object_or_empty(runtime_manifest)) {
        let path = as_string(common.object_or_empty(entry).path);
        if (path != "") {
            keep[path] = true;
            keep[binary_validation_path(path)] = true;
        }
    }
    for (let path in fs.glob(RUNTIME_CACHE_DIR + "/*")) {
        let name = substr(path, length(RUNTIME_CACHE_DIR) + 1);
        let managed = match(name, /^[0-9a-f]{12}\.(srs|json)(\.validated)?$/) != null ||
            match(name, /^empty-[0-9a-f]{12}\.json$/) != null;
        if (managed && !keep[path])
            fs.unlink(path);
    }
}

function local_rule_set(rule_set, manifest, previous_manifest, runtime_manifest, allow_download, required) {
    let url = as_string(rule_set.url);
    let format = as_string(rule_set.format) == "source" ? "source" : "binary";
    let key = cache_key(url);
    let entry = {
        url,
        format,
        update_interval: as_string(rule_set.update_interval) == "" ? "1d" : as_string(rule_set.update_interval),
        last_success: 0
    };
    let previous = common.object_or_empty(common.object_or_empty(previous_manifest)[key]);
    if (as_string(previous.url) == url && as_string(previous.format) == format)
        entry.last_success = int(previous.last_success || "0");
    manifest[key] = entry;

    let path = active_cache_path(runtime_manifest, url, format);
    if (allow_download && !valid_cache(path, format)) {
        let proxy = required && uci_core.get(CONFIG_NAME + ".settings.download_lists_via_proxy") == "1"
            ? constants.SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(constants.SB_SERVICE_MIXED_INBOUND_PORT) : "";
        let result = refresh_entry(entry, proxy, runtime_manifest);
        if (result.ok && result.persisted)
            entry.last_success = int(clock()[0]);
        path = active_cache_path(runtime_manifest, url, format);
    }

    let local_format = format;
    if (!valid_cache(path, format)) {
        if (required) {
            warn("Required rule-set unavailable for tag ", as_string(rule_set.tag), "; preserving the running configuration\n");
            return null;
        }
        path = empty_ruleset_path(url);
        local_format = "source";
        warn("rule-set cache unavailable for tag ", as_string(rule_set.tag), "; starting with an empty local rule-set\n");
    }

    return {
        type: "local",
        tag: rule_set.tag,
        format: local_format,
        path
    };
}

function materialize_config(config_path, allow_download, required) {
    if (!ensure_cache_dir())
        return false;
    cleanup_stale_temporary_files();
    let config = common.read_json_file(config_path);
    if (type(config) != "object")
        return false;
    let route = common.object_or_empty(config.route);
    let values = common.array_or_empty(route.rule_set);
    let previous_manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let runtime_manifest = read_runtime_manifest();
    let manifest = {};
    for (let i = 0; i < length(values); i++) {
        if (type(values[i]) == "object" && values[i].type == "remote") {
            let local = local_rule_set(values[i], manifest, previous_manifest, runtime_manifest, allow_download, required);
            if (local == null)
                return false;
            values[i] = local;
        }
    }
    route.rule_set = values;
    config.route = route;
    if (!common.write_private_json_file(config_path, config))
        return false;
    let persistent_manifest_written = write_manifest(manifest);
    for (let key, entry in runtime_manifest)
        if (manifest[key] == null)
            delete runtime_manifest[key];
    for (let key, entry in manifest) {
        let runtime = common.object_or_empty(runtime_manifest[key]);
        if (!persistent_manifest_written) {
            if (as_string(runtime.path) == "")
                runtime_manifest[key] = entry;
        }
        else if (as_string(runtime.path) == "")
            delete runtime_manifest[key];
    }
    if (!write_runtime_manifest(runtime_manifest))
        return false;
    // Staging precedes validation/ACK. Keep files referenced by the old live
    // config until a later background refresh can safely collect them.
    if (!required)
        prune_runtime_cache(manifest, runtime_manifest);
    if (persistent_manifest_written && !required)
        prune_stale_cache(manifest);
    return true;
}

function refresh_manifest(proxy_address, due_only, for_restart) {
    if (!ensure_cache_dir())
        return for_restart ? 2 : false;
    cleanup_stale_temporary_files();
    let manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let runtime_manifest = read_runtime_manifest();
    // A manifest that could not safely be written to flash is retained in
    // /var/run. Merge its declarations for this boot.
    for (let key, entry in runtime_manifest)
        if (as_string(common.object_or_empty(entry).url) != "")
            manifest[key] = entry;
    let changed = false;
    let failed = false;
    let attempted = false;
    let persistent_changed = false;
    for (let key, entry in manifest) {
        if (due_only && !entry_is_due(entry, runtime_manifest))
            continue;
        attempted = true;
        let result = refresh_entry(entry, proxy_address, runtime_manifest);
        if (!result.ok) {
            let format = as_string(entry.format) == "source" ? "source" : "binary";
            if (for_restart && valid_cache(active_cache_path(runtime_manifest, entry.url, format), format))
                command_success([ "logger", "-t", "forkop",
                    "[warn] Remote rule-set refresh failed; retaining validated cache " + key ]);
            else
                failed = true;
            continue;
        }
        if (result.persisted) {
            delete entry.path;
            entry.last_success = int(clock()[0]);
            persistent_changed = true;
        }
        if (result.changed)
            changed = true;
    }
    if (!write_runtime_manifest(runtime_manifest))
        failed = true;
    if (attempted && persistent_changed && !write_manifest(manifest))
        failed = true;
    // Entries are independent and each refresh is atomically renamed over its
    // own last-known-good file. Apply successful changes even if another entry
    // failed; failed entries keep their old cache and remain due for retry.
    if (failed && (for_restart || !changed))
        return 2;
    return changed ? 0 : 1;
}

function refresh_and_reload(proxy_address) {
    if (refresh_manifest(proxy_address, false) != 0)
        return;
    system(command_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]) + " >/dev/null 2>&1 1000>&- &");
}

function manifest_has_entries() {
    for (let key, entry in common.object_or_empty(common.read_json_file(MANIFEST_PATH)))
        if (as_string(common.object_or_empty(entry).url) != "")
            return true;
    return false;
}

function config_uses_empty_rule_set() {
    let config = common.read_json_file(SING_BOX_CONFIG_PATH);
    if (type(config) != "object")
        return true;
    let route = common.object_or_empty(config.route);
    for (let entry in common.array_or_empty(route.rule_set)) {
        let path = as_string(common.object_or_empty(entry).path);
        if (substr(path, 0, length(RUNTIME_CACHE_DIR + "/empty-")) == RUNTIME_CACHE_DIR + "/empty-")
            return true;
    }
    return false;
}

function prune_applied_config() {
    let config = common.read_json_file(SING_BOX_CONFIG_PATH);
    if (type(config) != "object")
        return false;
    let keep = {};
    for (let entry in common.array_or_empty(common.object_or_empty(config.route).rule_set)) {
        let path = as_string(common.object_or_empty(entry).path);
        if (path != "") {
            keep[path] = true;
            keep[binary_validation_path(path)] = true;
        }
    }
    // Called only after the live configuration and firewall have committed.
    // Derive retention from that config, never from a rejected stage's manifest.
    for (let dir in [ CACHE_DIR, RUNTIME_CACHE_DIR ]) {
        for (let path in fs.glob(dir + "/*")) {
            let name = substr(path, length(dir) + 1);
            if ((match(name, /^[0-9a-f]{12}\.(srs|json)(\.validated)?$/) ||
                match(name, /^empty-[0-9a-f]{12}\.json$/)) && !keep[path])
                fs.unlink(path);
        }
    }
    return true;
}

function refresh_if_due_and_reload(proxy_address) {
    let status = refresh_manifest(proxy_address, true);
    // At cold boot the generator may have used its empty local fallback before
    // this persistent cache was materialized. A still-fresh cache then needs
    // one local reload to replace that fallback with the saved rule-set; it
    // must not trigger another network download.
    if (status != 0 && (status != 1 || !manifest_has_entries() || !config_uses_empty_rule_set())) {
        // No rule-set reload follows this post-start worker. Let lifecycle
        // release the latency barrier rather than waiting for another start.
        system(command_from_args([ BIN_PATH, "post_start_latency" ]) + " >/dev/null 2>&1 1000>&- &");
        return;
    }
    system(command_from_args([ SERVICE_INIT, "reload", "ruleset-cache" ]) + " >/dev/null 2>&1 1000>&- &");
}

let mode = ARGV[0] || "";
if (mode == "materialize-config")
    exit(materialize_config(ARGV[1], as_string(ARGV[2]) != "cache-only", as_string(ARGV[2]) == "required") ? 0 : 1);
else if (mode == "refresh")
    exit(refresh_manifest(ARGV[1], false));
else if (mode == "refresh-for-restart")
    exit(refresh_manifest(ARGV[1], false, true));
else if (mode == "prune-applied")
    exit(prune_applied_config() ? 0 : 1);
else if (mode == "refresh-if-due")
    exit(refresh_manifest(ARGV[1], true));
else if (mode == "refresh-and-reload")
    refresh_and_reload(ARGV[1]);
else if (mode == "refresh-if-due-and-reload")
    refresh_if_due_and_reload(ARGV[1]);
else if (mode == "fallback-urls")
    for (let url in fallback_urls(ARGV[1]))
        print(url, "\n");
else {
    warn("Usage: singbox/ruleset_cache.uc <materialize-config|refresh|refresh-for-restart|refresh-and-reload|fallback-urls> ...\n");
    exit(1);
}
