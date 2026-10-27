#!/usr/bin/env ucode

let fs = require("fs");

// The package databases answer without taking the package manager lock.
const OPKG_STATUS_PATH = getenv("FORKOP_OPKG_STATUS_PATH") || "/usr/lib/opkg/status";
const APK_DB_PATH = getenv("FORKOP_APK_DB_PATH") || "/lib/apk/db/installed";

function as_string(value) {
    return value == null ? "" : "" + value;
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

function command_success(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    if (status != 0 || data == null)
        return "";
    return as_string(data);
}

function command_result(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>&1", "r");
    if (!pipe)
        return { status: -1, output: "" };

    let data = pipe.read("all");
    let status = pipe.close();
    return { status: status == null ? -1 : status, output: as_string(data) };
}

function first_error_line(output) {
    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (line != "")
            return length(line) > 240 ? substr(line, 0, 240) : line;
    }
    return "";
}

function found_state(version) {
    return { state: "found", version: as_string(version), error: "" };
}

function missing_state() {
    return { state: "missing", version: "", error: "" };
}

function error_state(message) {
    return { state: "error", version: "", error: as_string(message) };
}

function command_exists(name) {
    return command_success([ "command", "-v", name ]);
}

function apk_installed(package_name) {
    return command_exists("apk") && command_success([ "apk", "info", "-e", as_string(package_name) ]);
}

function opkg_installed(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("opkg"))
        return false;

    let prefix = package_name + " - ";
    for (let line in split(command_output([ "opkg", "list-installed" ]), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, length(prefix)) == prefix)
            return true;
    }
    return false;
}

function installed(package_name) {
    return apk_installed(package_name) || opkg_installed(package_name);
}

function apk_manifest_version(package_name, output) {
    package_name = as_string(package_name);
    let found = false;

    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, 2) == "P:")
            found = substr(line, 2) == package_name;
        else if (found && substr(line, 0, 2) == "V:")
            return substr(line, 2);
    }
    return "";
}

function apk_info_version(package_name, output) {
    package_name = as_string(package_name);
    let prefix = package_name + "-";

    for (let line in split(as_string(output), "\n")) {
        line = trim(as_string(line));
        if (line == "")
            continue;
        if (substr(line, 0, length(prefix)) == prefix)
            return substr(line, length(prefix));
    }
    return "";
}

function apk_list_version(package_name, output) {
    package_name = as_string(package_name);
    let prefix = package_name + "-";

    for (let line in split(as_string(output), "\n")) {
        for (let field in split(trim(as_string(line)), /[ \t]+/)) {
            field = as_string(field);
            if (substr(field, 0, length(prefix)) != prefix)
                continue;

            let version = substr(field, length(prefix));
            if (version != "")
                return version;
        }
    }
    return "";
}

function apk_query_version(package_name, output) {
    package_name = as_string(package_name);
    let packages;

    try {
        packages = json(as_string(output));
    }
    catch (e) {
        return "";
    }

    if (type(packages) != "array")
        return "";

    for (let package in packages) {
        if (type(package) != "object" || as_string(package.name) != package_name)
            continue;

        let version = as_string(package.version);
        if (version != "")
            return version;
    }
    return "";
}

function apk_version(package_name) {
    package_name = as_string(package_name);
    if (!apk_installed(package_name))
        return "";

    let version = apk_list_version(package_name, command_output([ "apk", "list", "--installed", package_name ]));
    if (version != "")
        return version;

    version = apk_manifest_version(package_name, command_output([ "apk", "list", "--installed", "--manifest", package_name ]));
    if (version != "")
        return version;

    version = apk_manifest_version(package_name, command_output([ "apk", "list", "--installed", "--manifest" ]));
    if (version != "")
        return version;

    return apk_info_version(package_name, command_output([ "apk", "info", "-v", package_name ]));
}

function apk_available_version(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("apk"))
        return "";
    return apk_query_version(
        package_name,
        command_output([ "apk", "query", "--from", "repositories", "--available", "--format", "json", "--fields", "name,version", package_name ])
    );
}

function opkg_version(package_name) {
    package_name = as_string(package_name);
    if (!command_exists("opkg"))
        return "";

    let prefix = package_name + " - ";
    for (let line in split(command_output([ "opkg", "list-installed" ]), "\n")) {
        line = trim(as_string(line));
        if (substr(line, 0, length(prefix)) == prefix)
            return substr(line, length(prefix));
    }
    return "";
}

// Only a database that reads as the expected text may answer "not installed":
// a file in some other format must not stand in for an empty one.
function db_field_lines(text, prefix) {
    let count = 0;
    for (let line in split(as_string(text), "\n"))
        if (substr(trim(as_string(line)), 0, length(prefix)) == prefix)
            count++;
    return count;
}

function opkg_status_entry_state(version, status) {
    status = as_string(status);
    if (index(status, "not-installed") >= 0 || index(status, " installed") < 0)
        return missing_state();
    return as_string(version) != "" ? found_state(version) : error_state("");
}

function opkg_status_state(package_name, text) {
    package_name = as_string(package_name);
    text = as_string(text);
    if (db_field_lines(text, "Package: ") == 0 || db_field_lines(text, "Status: ") == 0)
        return error_state("");

    let name = "", version = "", status = "";
    for (let line in split(text, "\n")) {
        line = trim(as_string(line));
        if (line == "") {
            if (name == package_name)
                return opkg_status_entry_state(version, status);
            name = "";
            version = "";
            status = "";
            continue;
        }
        if (substr(line, 0, 9) == "Package: ")
            name = trim(substr(line, 9));
        else if (substr(line, 0, 9) == "Version: ")
            version = trim(substr(line, 9));
        else if (substr(line, 0, 8) == "Status: ")
            status = trim(substr(line, 8));
    }
    return name == package_name ? opkg_status_entry_state(version, status) : missing_state();
}

function apk_db_state(package_name, text) {
    text = as_string(text);
    if (db_field_lines(text, "P:") == 0 || db_field_lines(text, "V:") == 0)
        return error_state("");

    let version = apk_manifest_version(package_name, text);
    return version != "" ? found_state(version) : missing_state();
}

function opkg_installed_version_state(package_name) {
    let result = command_result([ "opkg", "list-installed" ]);
    if (result.status == 0) {
        let prefix = package_name + " - ";
        for (let line in split(result.output, "\n")) {
            line = trim(as_string(line));
            if (substr(line, 0, length(prefix)) == prefix)
                return found_state(substr(line, length(prefix)));
        }
        return missing_state();
    }

    // opkg takes its global lock for every invocation, read-only queries
    // included, and fails instead of waiting. The status database stays
    // readable, so a busy lock does not hide an installed version.
    let fallback = opkg_status_state(package_name, fs.readfile(OPKG_STATUS_PATH));
    if (fallback.state != "error")
        return fallback;

    let message = first_error_line(result.output);
    return error_state(message != "" ? message :
        "opkg list-installed failed with exit code " + result.status);
}

function apk_installed_version_state(package_name) {
    // A query that failed counts as failed even when it said nothing: apk
    // exits non-zero without a word often enough, and reading that silence as
    // "the package is not installed" is what a rollback must never do.
    let failed = false;
    let failure = "";
    for (let query in [
        [ "list", [ "apk", "list", "--installed", package_name ] ],
        [ "manifest", [ "apk", "list", "--installed", "--manifest", package_name ] ],
        [ "info", [ "apk", "info", "-v", package_name ] ]
    ]) {
        let result = command_result(query[1]);
        if (result.status != 0) {
            failed = true;
            if (failure == "")
                failure = first_error_line(result.output);
            if (failure == "")
                failure = "apk " + query[0] + " failed with exit code " + result.status;
            continue;
        }

        let version = query[0] == "list" ? apk_list_version(package_name, result.output) :
            query[0] == "manifest" ? apk_manifest_version(package_name, result.output) :
            apk_info_version(package_name, result.output);
        if (version != "")
            return found_state(version);
    }

    // Every query answered and none reported the package: it is not installed.
    if (!failed)
        return missing_state();

    let fallback = apk_db_state(package_name, fs.readfile(APK_DB_PATH));
    return fallback.state != "error" ? fallback : error_state(failure);
}

// Keeps "the package manager could not answer" apart from "the package is not
// installed", which the version modes above report as the same empty string.
function installed_version_state(package_name) {
    package_name = as_string(package_name);
    if (package_name == "")
        return error_state("no package name was given");
    if (command_exists("apk"))
        return apk_installed_version_state(package_name);
    if (command_exists("opkg"))
        return opkg_installed_version_state(package_name);
    return error_state("no supported package manager is available");
}

function version(package_name) {
    let value = apk_version(package_name);
    return value != "" ? value : opkg_version(package_name);
}

let mode = ARGV[0] || "";

if (mode == "installed")
    exit(installed(ARGV[1]) ? 0 : 1);
else if (mode == "apk-installed")
    exit(apk_installed(ARGV[1]) ? 0 : 1);
else if (mode == "opkg-installed")
    exit(opkg_installed(ARGV[1]) ? 0 : 1);
else if (mode == "version")
    print(version(ARGV[1]), "\n");
else if (mode == "apk-version")
    print(apk_version(ARGV[1]), "\n");
else if (mode == "apk-available-version")
    print(apk_available_version(ARGV[1]), "\n");
else if (mode == "opkg-version")
    print(opkg_version(ARGV[1]), "\n");
else if (mode == "installed-version") {
    let state = installed_version_state(ARGV[1]);
    if (state.state == "found")
        print("found ", state.version, "\n");
    else if (state.state == "missing") {
        print("missing\n");
        exit(3);
    }
    else {
        print("error ", state.error, "\n");
        exit(2);
    }
}
else {
    warn("Usage: core/packages.uc <installed|apk-installed|opkg-installed|version|apk-version|apk-available-version|opkg-version|installed-version> <package>\n");
    exit(1);
}
