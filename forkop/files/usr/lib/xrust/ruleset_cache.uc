#!/usr/bin/env ucode

let fs = require("fs");
let xrust = require("xrust.binary");
let common = require("core.common");
let duration = require("core.duration");
let constants = require("core.constants");
let rulesets = require("xrust.rulesets");
let uci_core = require("core.uci");
let core_ip = require("core.ip");
let bootstrap_dns = require("dns.bootstrap");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
const BIN_PATH = getenv("FORKOP_BIN") || "/usr/bin/forkop";
const CACHE_DIR = getenv("FORKOP_RULESET_CACHE_DIR") || "/etc/forkop/ruleset-cache";
const MANIFEST_PATH = getenv("FORKOP_RULESET_CACHE_MANIFEST") || CACHE_DIR + "/manifest.json";
const LIST_CACHE_DIR = getenv("FORKOP_PERSISTENT_LIST_CACHE_DIR") || "/etc/forkop/list-cache";
const RUNTIME_CACHE_DIR = getenv("FORKOP_RULESET_RUNTIME_CACHE_DIR") || "/tmp/xrust/ruleset-cache";
const RUNTIME_MANIFEST_PATH = getenv("FORKOP_RULESET_RUNTIME_MANIFEST") || "/var/run/forkop/ruleset-cache-runtime.json";
const SERVICE_INIT = getenv("FORKOP_SERVICE_INIT") || "/etc/init.d/forkop";
const SING_BOX_CONFIG_PATH = getenv("FORKOP_SING_BOX_CONFIG_PATH") ||
    uci_core.get(CONFIG_NAME + ".settings.config_path") || "/etc/xrust/config.json";
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
    if (list_bytes < 0 || ruleset_bytes < 0 || old_bytes < 0 || new_bytes < 0)
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

let cache_dirs_ready = false;

function with_cache_lock(operation, failure) {
    if (!cache_dirs_ready) {
        if (!ensure_cache_dir())
            return failure;
        cache_dirs_ready = true;
    }
    let lock = fs.open(RUNTIME_CACHE_DIR + "/.lock", "a");
    if (!lock)
        return failure;
    let result = lock.lock("x") ? operation() : failure;
    lock.close();
    return result;
}

function cleanup_stale_temporary_file(path, base, now, max_age) {
    let name = substr(path, length(base) + 1);
    let download = match(name, /^[0-9a-f]{12}(-[0-9a-f]{64})?\.(srs|json)\.download\.[0-9]+\.[0-9]+(\.([0-9]+))?(\.validated)?$/);
    if (download?.[4] && fs.stat("/proc/" + download[4]) != null)
        return;
    let managed = download != null ||
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

function generation_path(base, digest) {
    return replace(base, /\.(srs|json)$/, "-" + digest + ".$1");
}

function matches_generation(path, base) {
    let digest = match(path, /-([0-9a-f]{64})\.(srs|json)$/);
    return path == base || (digest != null && path == generation_path(base, digest[1]));
}

function persistent_entry_path(entry, format) {
    let base = cache_path(entry.url, format);
    let path = as_string(entry.path);
    return matches_generation(path, base) ? path : base;
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

function cache_file_digest(path) {
    let signature = binary_stat_signature(path);
    let digest = signature != "" ? binary_digest(path) : "";
    return digest != "" && binary_stat_signature(path) == signature ? { path, signature, digest } : null;
}

function write_validation(file) {
    if (file != null && binary_stat_signature(file.path) == file.signature)
        fs.writefile(binary_validation_path(file.path), file.signature + "\n" + file.digest + "\n");
}

function publish_cache_file(file, path) {
    if (binary_stat_signature(file.path) != file.signature || !fs.rename(file.path, path))
        return false;
    command_success([ "chmod", "0600", path ]);
    write_validation({ ...file, path, signature: binary_stat_signature(path) });
    return true;
}

function parse_binary(path) {
    return command_success([
        xrust.PATH, "rule-set", "match", "--format", "binary", path,
        "forkop-validation.invalid"
    ]);
}

function parse_source(path) {
    let value = common.read_json_file(path);
    if (type(value) != "object" || type(value.rules) != "array")
        return false;

    let config = trim(command_output([ "mktemp" ]));
    if (config == "")
        return false;
    // The core's match-source command accepts invalid rule values. Check the
    // same local rule-set loader the final configuration uses instead.
    let ok = common.write_private_json_file(config, {
        outbounds: [ { type: "direct", tag: "direct" } ],
        route: {
            rule_set: [ { type: "local", tag: "validation", format: "source", path } ],
            rules: [ { rule_set: [ "validation" ], outbound: "direct" } ],
            final: "direct"
        }
    }) && command_success([ xrust.PATH, "check", "-c", config ]);
    fs.unlink(config);
    return !!ok;
}

function validate_cache(path, format, previous) {
    let file = cache_file_digest(path);
    let marker_path = binary_validation_path(path);
    let expected = match(path, /-([0-9a-f]{64})\.(srs|json)$/)?.[1];
    if (file == null || (expected != null && file.digest != expected)) {
        fs.unlink(marker_path);
        return null;
    }
    let marker = split(trim(as_string(fs.readfile(marker_path))), "\n");
    if (length(marker) == 2 && marker[0] == file.signature && marker[1] == file.digest)
        return file;
    // A validated digest identifies the exact bytes even when copied to a
    // different inode. New bytes still go through the core's parser and a
    // second digest check to detect replacement during validation.
    if (file.digest == previous?.digest ||
        ((format == "source" ? parse_source(path) : parse_binary(path)) &&
         binary_stat_signature(path) == file.signature && binary_digest(path) == file.digest)) {
        write_validation(file);
        return file;
    }
    fs.unlink(marker_path);
    return null;
}

function valid_runtime_entry(runtime_manifest, url, format) {
    let entry = common.object_or_empty(common.object_or_empty(runtime_manifest)[cache_key(url)]);
    let path = as_string(entry.path);
    if (as_string(entry.url) != as_string(url) || as_string(entry.format) != format ||
        !(matches_generation(path, runtime_cache_path(url, format)) ||
          matches_generation(path, cache_path(url, format))))
        return null;
    let file = validate_cache(path, format);
    return file != null ? { ...file, last_success: entry.last_success } : null;
}

function active_cache_file(runtime_manifest, entry, format) {
    let runtime = valid_runtime_entry(runtime_manifest, entry.url, format);
    if (runtime != null)
        return runtime;
    let path = persistent_entry_path(entry, format);
    let legacy = cache_path(entry.url, format);
    let file = validate_cache(path, format) ?? (path != legacy ? validate_cache(legacy, format) : null);
    return file != null ? { ...file, last_success: entry.last_success } : null;
}

function duration_seconds(value) {
    return duration.ceil_seconds(value, 86400);
}

function entry_is_due(entry, current) {
    if (current == null)
        return true;
    let last = int(current.last_success || "0");
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
        let resolved = bootstrap_dns.resolve_url(url, bootstrap_dns.configured());
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
    let copied = command_success([ "cp", source.path, staged ]) ? validate_cache(staged, format, source) : null;
    if (copied == null || copied.digest != source.digest || !publish_cache_file(copied, target)) {
        fs.unlink(staged);
        fs.unlink(binary_validation_path(staged));
        return false;
    }
    fs.unlink(binary_validation_path(staged));
    return true;
}

function remember_candidate(entry, runtime_manifest, path, persisted, changed) {
    let last_success = int(clock()[0]);
    runtime_manifest[cache_key(entry.url)] = { ...entry, path, last_success };
    if (persisted) {
        entry.path = path;
        entry.last_success = last_success;
    }
    return { changed, persisted, path };
}

function discard_download(path) {
    fs.unlink(path);
    fs.unlink(binary_validation_path(path));
}

function download_ruleset(url, format, proxy_address, current) {
    let stamp = clock();
    let temporary = runtime_cache_path(url, format) + ".download." +
        as_string(stamp[0]) + "." + as_string(stamp[1]) + "." + fs.readlink("/proc/self");

    for (let candidate in candidate_urls(url)) {
        discard_download(temporary);
        if (download_candidate_with_bootstrap(candidate, temporary, proxy_address)) {
            let downloaded = validate_cache(temporary, format, current);
            if (downloaded != null)
                return downloaded;
            warn("rule-set download returned an invalid ", format, " payload for ", candidate, "\n");
        }
    }
    discard_download(temporary);
    return null;
}

function publish_download(entry, format, runtime_manifest, current, downloaded) {
    if (downloaded == null || binary_stat_signature(downloaded.path) != downloaded.signature)
        return null;

    let digest = downloaded.digest;
    let changed = digest != current?.digest;
    let persistent_base = cache_path(entry.url, format);
    if (!changed && matches_generation(current.path, persistent_base))
        return remember_candidate(entry, runtime_manifest, current.path, true, false);

    // A generation name identifies the expected bytes. Replace damaged bytes
    // atomically with that same verified content, even if the path is in use.
    let target = generation_path(persistent_base, digest);
    if (binary_digest(target) == digest ||
        (persistent_cache_can_store(target, allocated_bytes(downloaded.path)) &&
         commit_persistent_candidate(downloaded, target, format)))
        return remember_candidate(entry, runtime_manifest, target, true, changed);

    if (!changed)
        return remember_candidate(entry, runtime_manifest, current.path, false, false);
    target = generation_path(runtime_cache_path(entry.url, format), digest);
    if (binary_digest(target) == digest || publish_cache_file(downloaded, target))
        return remember_candidate(entry, runtime_manifest, target, false, true);
    return null;
}

function empty_ruleset_path(url) {
    let path = RUNTIME_CACHE_DIR + "/empty-" + cache_key(url) + ".json";
    let contents = common.read_json_file(path);
    if (contents?.version != 1 || type(contents?.rules) != "array" || length(contents.rules) != 0)
        common.write_json_file(path, { version: 1, rules: [] });
    command_success([ "chmod", "0600", path ]);
    return path;
}

function local_rule_set(rule_set, manifest, previous_manifest, runtime_manifest, downloads, allow_download, required) {
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
    if (as_string(previous.url) == url && as_string(previous.format) == format) {
        entry.last_success = int(previous.last_success || "0");
        entry.path = persistent_entry_path(previous, format);
    }
    manifest[key] = entry;

    let cached = active_cache_file(runtime_manifest, entry, format);
    if (cached == null) {
        if (allow_download)
            return { missing: { url, format } };
        cached = publish_download(entry, format, runtime_manifest, null, downloads[format][url]?.file);
    }

    let local_format = format;
    let path = cached?.path;
    if (cached == null) {
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

function publish_declarations(manifest, runtime_manifest) {
    for (let key, entry in runtime_manifest)
        if (manifest[key] == null)
            delete runtime_manifest[key];
    for (let key, entry in manifest) {
        if (as_string(runtime_manifest[key]?.path) == "")
            runtime_manifest[key] = entry;
    }
    // Establish a complete boot-local fallback before making the persistent
    // schedule visible. A failing first write has changed neither schedule.
    if (!write_runtime_manifest(runtime_manifest))
        return false;
    if (write_manifest(manifest)) {
        for (let key, entry in manifest)
            if (as_string(runtime_manifest[key]?.path) == "" || runtime_manifest[key].path == entry.path)
                delete runtime_manifest[key];
        write_runtime_manifest(runtime_manifest);
    }
    return true;
}

function materialize_config_locked(config_path, allow_download, required, stage_only, downloads) {
    cleanup_stale_temporary_files();
    let config = common.read_json_file(config_path);
    if (type(config) != "object")
        return false;
    let route = common.object_or_empty(config.route);
    let values = common.array_or_empty(route.rule_set);
    let previous_manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let runtime_manifest = read_runtime_manifest();
    let manifest = {};
    let missing = [];
    for (let i = 0; i < length(values); i++) {
        if (type(values[i]) == "object" && values[i].type == "remote") {
            let local = local_rule_set(values[i], manifest, previous_manifest, runtime_manifest,
                downloads, allow_download, required);
            if (local == null)
                return false;
            if (local.missing)
                push(missing, local.missing);
            else
                values[i] = local;
        }
    }
    if (length(missing))
        return { missing };
    route.rule_set = values;
    config.route = route;
    if (!common.write_private_json_file(config_path, config))
        return false;
    if (stage_only)
        return common.write_private_json_file(config_path + ".rulesets", { manifest, runtime_manifest }) != null;
    return publish_declarations(manifest, runtime_manifest);
}

function materialize_config(config_path, allow_download, required, stage_only) {
    let downloads = { source: {}, binary: {} };
    let result = with_cache_lock(() =>
        materialize_config_locked(config_path, allow_download, required, stage_only, downloads), false);
    if (type(result) != "object")
        return result;

    let proxy = required && uci_core.get(CONFIG_NAME + ".settings.download_lists_via_proxy") == "1"
        ? constants.SB_SERVICE_MIXED_INBOUND_ADDRESS + ":" + as_string(constants.SB_SERVICE_MIXED_INBOUND_PORT) : "";
    for (let entry in result.missing) {
        let files = downloads[entry.format];
        if (files[entry.url] == null)
            files[entry.url] = { file: download_ruleset(entry.url, entry.format, proxy) };
    }
    result = with_cache_lock(() =>
        materialize_config_locked(config_path, false, required, stage_only, downloads), false);
    for (let files in values(downloads))
        for (let download in values(files))
            if (download.file != null)
                discard_download(download.file.path);
    return result;
}

function commit_staged_config(config_path) {
    let path = config_path + ".rulesets";
    if (fs.stat(path) == null)
        return true;
    let staged = common.read_json_file(path);
    if (type(staged?.manifest) != "object" || type(staged?.runtime_manifest) != "object")
        return false;
    // A concurrent periodic refresh may have a newer validated copy for a
    // retained declaration. Keep its freshness but apply this config's set
    // of declarations and its update intervals.
    let persistent = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let runtime = read_runtime_manifest();
    for (let key, entry in staged.manifest) {
        let current = persistent[key];
        if (current?.url == entry.url && current?.format == entry.format &&
            int(current.last_success) > int(entry.last_success)) {
            entry.path = current.path;
            entry.last_success = current.last_success;
        }
        current = runtime[key];
        if (current?.url == entry.url && current?.format == entry.format &&
            int(current.last_success) > int(staged.runtime_manifest[key]?.last_success))
            staged.runtime_manifest[key] = { ...current, update_interval: entry.update_interval };
    }
    if (!publish_declarations(staged.manifest, staged.runtime_manifest))
        return false;
    fs.unlink(path);
    return true;
}

function applied_config_needs_refresh(validated_paths) {
    let config = common.read_json_file(SING_BOX_CONFIG_PATH);
    for (let rule_set in common.array_or_empty(config?.route?.rule_set)) {
        let path = as_string(rule_set?.path);
        let dir = parent_dir(path);
        if (dir != CACHE_DIR && dir != RUNTIME_CACHE_DIR)
            continue;
        let name = substr(path, length(dir) + 1);
        let key = match(name, /^(empty-)?([0-9a-f]{12})(-[0-9a-f]{64})?\.(srs|json)$/)?.[2];
        if (validated_paths[key] != null && validated_paths[key] != path)
            return true;
    }
    return false;
}

function refresh_manifests() {
    let manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    let runtime_manifest = read_runtime_manifest();
    // A manifest that could not safely be written to flash is retained in
    // /var/run. Merge its declarations for this boot.
    for (let key, entry in runtime_manifest)
        if (manifest[key] == null && as_string(common.object_or_empty(entry).url) != "")
            manifest[key] = { ...entry, path: "", last_success: 0 };
    return { manifest, runtime_manifest };
}

function refresh_plan(due_only) {
    cleanup_stale_temporary_files();
    let state = refresh_manifests();
    let entries = [];
    for (let key, entry in state.manifest) {
        let format = as_string(entry.format) == "source" ? "source" : "binary";
        let current = active_cache_file(state.runtime_manifest, entry, format);
        push(entries, { key, url: entry.url, format, current, due: !due_only || entry_is_due(entry, current) });
    }
    return entries;
}

function publish_refresh(plan, downloaded, due_only, for_restart) {
    let state = refresh_manifests();
    let entry = state.manifest[plan.key];
    let format = as_string(entry?.format) == "source" ? "source" : "binary";
    if (entry == null || entry.url != plan.url || format != plan.format)
        return {};

    let current = active_cache_file(state.runtime_manifest, entry, format);
    // A declaration may have been removed or another download published
    // while the network request was running. Keep any newer generation.
    if (current?.path != plan.current?.path || current?.digest != plan.current?.digest ||
        current?.last_success != plan.current?.last_success || (due_only && !entry_is_due(entry, current)))
        return { path: current?.path };

    let result = publish_download(entry, format, state.runtime_manifest, current, downloaded);
    if (result != null)
        return write_runtime_manifest(state.runtime_manifest) ? result : { failed: true, path: current?.path };
    if (for_restart && current != null)
        command_success([ "logger", "-t", "forkop",
            "[warn] Remote rule-set refresh failed; retaining validated cache " + plan.key ]);
    return { failed: !for_restart || current == null, path: current?.path };
}

function persist_refresh(entries) {
    let state = refresh_manifests();
    let stored = [];
    for (let key, path in entries) {
        let runtime = state.runtime_manifest[key];
        let entry = state.manifest[key];
        if (runtime?.path != path || runtime.url != entry?.url || runtime.format != entry.format)
            continue;
        entry.path = path;
        entry.last_success = runtime.last_success;
        push(stored, key);
    }
    if (!length(stored))
        return true;
    if (!write_manifest(state.manifest))
        return false;
    for (let key in stored)
        delete state.runtime_manifest[key];
    return write_runtime_manifest(state.runtime_manifest);
}

function refresh_manifest(proxy_address, due_only, for_restart) {
    let plan = with_cache_lock(() => refresh_plan(due_only), null);
    if (plan == null)
        return 2;
    let changed = false;
    let failed = false;
    let persisted = {};
    let validated_paths = {};
    for (let entry in plan) {
        if (!entry.due) {
            validated_paths[entry.key] = entry.current?.path;
            continue;
        }

        let downloaded = download_ruleset(entry.url, entry.format, proxy_address, entry.current);
        let result = with_cache_lock(() => publish_refresh(entry, downloaded, due_only, for_restart), null);
        if (downloaded != null)
            discard_download(downloaded.path);
        if (result == null)
            return 2;
        if (result.persisted)
            persisted[entry.key] = result.path;
        validated_paths[entry.key] = result.path;
        changed = changed || !!result.changed;
        failed = failed || !!result.failed;
    }
    // Publish the durable schedule once per batch. Until then the runtime
    // manifest holds the new generations alongside the flash fallback.
    if (length(keys(persisted)) && !with_cache_lock(() => persist_refresh(persisted), false))
        failed = true;
    // Retry applying a validated generation after a rejected/pending reload
    // even if no network request was due or its bytes didn't change again.
    changed = changed || applied_config_needs_refresh(validated_paths);
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
    // Keep a newer staged generation and the persistent fallback for RAM
    // entries. The live config alone may still reference the older snapshot.
    let manifest = common.object_or_empty(common.read_json_file(MANIFEST_PATH));
    for (let key, entry in manifest) {
        let format = as_string(entry.format) == "source" ? "source" : "binary";
        let path = persistent_entry_path(entry, format);
        keep[path] = true;
        keep[binary_validation_path(path)] = true;
    }
    for (let key, entry in read_runtime_manifest()) {
        let path = as_string(entry?.path);
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
            if ((match(name, /^[0-9a-f]{12}(-[0-9a-f]{64})?\.(srs|json)(\.validated)?$/) ||
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
    exit(materialize_config(ARGV[1], as_string(ARGV[2]) != "cache-only",
        as_string(ARGV[2]) == "required", ARGV[3] == "stage") ? 0 : 1);
else if (mode == "commit-staged")
    exit(with_cache_lock(() => commit_staged_config(ARGV[1]), false) ? 0 : 1);
else if (mode == "refresh")
    exit(refresh_manifest(ARGV[1], false));
else if (mode == "refresh-for-restart")
    exit(refresh_manifest(ARGV[1], false, true));
else if (mode == "prune-applied")
    exit(with_cache_lock(prune_applied_config, false) ? 0 : 1);
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
    warn("Usage: xrust/ruleset_cache.uc <materialize-config|refresh|refresh-for-restart|refresh-and-reload|fallback-urls> ...\n");
    exit(1);
}
