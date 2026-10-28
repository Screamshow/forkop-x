#!/usr/bin/env ucode

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_json_file(path) {
    let data = fs.readfile(path);
    if (data == null)
        return null;

    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
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
    let data = read_stdin();
    try {
        return json(data);
    }
    catch (e) {
        return null;
    }
}

function stdin_first_line_last_field() {
    let data = read_stdin();
    let newline = index(data, "\n");
    let line = trim(newline >= 0 ? substr(data, 0, newline) : data);
    let fields = split(line, /[ \t\r\n]+/);

    if (length(fields) > 0)
        print(as_string(fields[length(fields) - 1]), "\n");
}

function file_first_line(path) {
    let data = fs.readfile(path);
    if (data == null)
        exit(1);

    let newline = index(data, "\n");
    print(newline >= 0 ? substr(data, 0, newline) : data, "\n");
}

function json_file_field(path, key, fallback) {
    let value = read_json_file(path);
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function object_get_default(key, fallback) {
    let value = read_stdin_json();
    if (type(value) == "object" && value[key] != null)
        print(as_string(value[key]), "\n");
    else
        print(as_string(fallback), "\n");
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function str_startswith(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function arg_bool(value) {
    return value === true || value == "true" || value == "1" || value == 1;
}

function file_json_valid(path) {
    return read_json_file(path) != null;
}

function github_response_ok() {
    let response = read_stdin_json();
    if (response == null)
        return false;

    if (type(response) == "object") {
        let message = as_string(response.message || "");
        if (match(message, /API rate limit/) || match(message, /rate limit exceeded/) || message == "Not Found")
            return false;
    }

    return true;
}

function release_asset_url(name) {
    let release = object_or_empty(read_stdin_json());
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) == "object" && as_string(asset.name || "") == name) {
            print(as_string(asset.browser_download_url || ""), "\n");
            return;
        }
    }
}

function release_asset_pair(release, expected_name) {
    for (let asset in array_or_empty(release.assets)) {
        if (type(asset) != "object")
            continue;

        let name = as_string(asset.name || "");
        let url = as_string(asset.browser_download_url || "");
        if (name == as_string(expected_name) && url != "")
            return { name, url };
    }

    return null;
}

function forkop_release_plan(latest_version, asset_ext, i18n_required) {
    let release = object_or_empty(read_stdin_json());

    if (as_string(release.tag_name || "") != as_string(latest_version))
        exit(1);

    if (match(as_string(latest_version), /^[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/) == null)
        exit(1);

    let backend = release_asset_pair(release, "forkop_" + latest_version + "." + asset_ext);
    let app = release_asset_pair(release, "luci-app-forkop_" + latest_version + "." + asset_ext);
    if (backend == null || app == null)
        exit(1);

    let i18n = { name: "", url: "" };
    if (arg_bool(i18n_required)) {
        i18n = release_asset_pair(release, "luci-i18n-forkop-ru_" + latest_version + "." + asset_ext);
        if (i18n == null)
            exit(1);
    }

    print(as_string(release.html_url || ""), "\t",
        backend.name, "\t", backend.url, "\t",
        app.name, "\t", app.url, "\t",
        i18n.name, "\t", i18n.url, "\n");
}

function release_metadata_tsv() {
    let release = object_or_empty(read_stdin_json());
    let tag = as_string(release.tag_name || "");

    if (tag == "")
        return;

    print(tag, "\t", as_string(release.html_url || ""), "\n");
}

function openwrt_release_value(path, key) {
    let data = fs.readfile(path);
    if (data == null)
        return;

    let prefix = as_string(key) + "='";
    for (let line in split(as_string(data), "\n")) {
        if (!str_startswith(line, prefix))
            continue;

        let rest = substr(line, length(prefix));
        let quote = rindex(rest, "'");
        if (quote >= 0)
            print(substr(rest, 0, quote), "\n");
        return;
    }
}

function first_version_token(value) {
    value = as_string(value);
    for (let i = 0; i < length(value); i++) {
        let chr = substr(value, i, 1);
        if (chr == " " || chr == "\t" || chr == "\r" || chr == "\n")
            return substr(value, 0, i);
    }

    return value;
}

function strip_plus_metadata(value) {
    value = as_string(value);
    let plus = index(value, "+");
    return plus >= 0 ? substr(value, 0, plus) : value;
}

function updates_normalize_sing_box_version(value) {
    value = as_string(value);
    if (str_startswith(value, "v"))
        value = substr(value, 1);

    print(first_version_token(strip_plus_metadata(value)), "\n");
}

function forkop_normalized_release_version(value) {
    return as_string(value);
}

function forkop_release_version_valid(value) {
    value = forkop_normalized_release_version(value);
    return match(value, /^[0-9]+[.][0-9]+[.][0-9]+(-canary[.][0-9]+)?$/) != null;
}

function forkop_release_version_parts(value) {
    let version = forkop_normalized_release_version(value);
    if (!forkop_release_version_valid(version))
        return null;

    let match_parts = match(version, /^([0-9]+)[.]([0-9]+)[.]([0-9]+)(-canary[.]([0-9]+))?$/);
    return [ int(match_parts[1]), int(match_parts[2]), int(match_parts[3]),
        match_parts[5] == null ? -1 : int(match_parts[5]) ];
}

function forkop_release_version_compare(lhs, rhs) {
    let lhs_parts = forkop_release_version_parts(lhs);
    let rhs_parts = forkop_release_version_parts(rhs);
    if (lhs_parts == null || rhs_parts == null)
        return false;

    for (let i = 0; i < 3; i++) {
        if (lhs_parts[i] < rhs_parts[i]) {
            print("-1\n");
            return true;
        }
        if (lhs_parts[i] > rhs_parts[i]) {
            print("1\n");
            return true;
        }
    }

    // A stable release sorts after every canary of the same base version.
    if (lhs_parts[3] < rhs_parts[3]) {
        print("-1\n");
        return true;
    }
    if (lhs_parts[3] > rhs_parts[3]) {
        print("1\n");
        return true;
    }

    print("0\n");
    return true;
}

function updates_opkg_package_version(package_name) {
    package_name = as_string(package_name);

    for (let line in split(read_stdin(), "\n")) {
        let fields = split(trim(as_string(line)), /[ \t]+/);
        if (length(fields) >= 3 && as_string(fields[0]) == package_name && as_string(fields[1]) == "-") {
            print(as_string(fields[2]), "\n");
            return;
        }
    }
}

function updates_check_result_row(component, current_version, latest_version, status) {
    component = as_string(component);
    current_version = as_string(current_version);
    latest_version = as_string(latest_version);
    status = as_string(status);

    if (status == "latest") {
        print("Latest version is installed\t", component, " is up to date (", current_version, ")\n");
        return;
    }

    if (status == "outdated") {
        print("Update is available\t", component, " update is available: ", current_version, " -> ", latest_version, "\n");
        return;
    }

    if (status == "dev") {
        print("Installed version is newer than release\t", component, " installed version is newer than upstream release: ", current_version, " -> ", latest_version, "\n");
        return;
    }

    exit(1);
}

let mode = ARGV[0] || "";

if (mode == "file-json-valid")
    exit(file_json_valid(ARGV[1]) ? 0 : 1);
else if (mode == "file-first-line")
    file_first_line(ARGV[1]);
else if (mode == "json-file-field")
    json_file_field(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "object-get-default")
    object_get_default(ARGV[1], ARGV[2]);
else if (mode == "github-response-ok")
    exit(github_response_ok() ? 0 : 1);
else if (mode == "release-asset-url")
    release_asset_url(ARGV[1]);
else if (mode == "forkop-release-plan")
    forkop_release_plan(ARGV[1], ARGV[2], ARGV[3]);
else if (mode == "release-metadata-tsv")
    release_metadata_tsv();
else if (mode == "openwrt-release-value")
    openwrt_release_value(ARGV[1], ARGV[2]);
else if (mode == "stdin-first-line-last-field")
    stdin_first_line_last_field();
else if (mode == "updates-normalize-sing-box-version")
    updates_normalize_sing_box_version(ARGV[1]);
else if (mode == "forkop-release-version-valid")
    exit(forkop_release_version_valid(ARGV[1]) ? 0 : 1);
else if (mode == "forkop-release-version-compare")
    exit(forkop_release_version_compare(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "updates-opkg-package-version")
    updates_opkg_package_version(ARGV[1]);
else if (mode == "updates-check-result-row")
    updates_check_result_row(ARGV[1], ARGV[2], ARGV[3], ARGV[4]);
else {
    warn("Usage: components/updater.uc <operation> ...\n");
    exit(1);
}
