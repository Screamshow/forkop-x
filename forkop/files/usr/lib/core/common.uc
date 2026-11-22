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

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function write_compact_string_array(values) {
    print("[");
    for (let i = 0; i < length(values); i++) {
        if (i > 0)
            print(",");
        print(sprintf("%J", as_string(values[i])));
    }
    print("]\n");
}

function csv_to_json_array(value) {
    value = as_string(value);
    write_compact_string_array(value == "" ? [] : split(value, ","));
}

function write_json_file(path, value) {
    return fs.writefile(path, sprintf("%J\n", value));
}

function open_private_file(path) {
    let handle = fs.open(path, "w", 0600);
    if (handle == null)
        return null;
    if (!fs.chmod(path, 0600)) {
        handle.close();
        return null;
    }
    return handle;
}

function write_private_file(path, value) {
    if (value == null)
        return null;
    value = as_string(value);
    let handle = open_private_file(path);
    if (handle == null)
        return null;
    let written = handle.write(value);
    handle.close();
    // stdio may report a buffered write before the filesystem accepts it.
    return written == length(value) && fs.stat(path)?.size == written ? written : null;
}

function write_private_json_file(path, value) {
    return write_private_file(path, sprintf("%J\n", value));
}

function copy_private_file_atomic(source, target) {
    if (!source || !target)
        return false;
    // The temporary file must live beside the destination so the final
    // rename cannot fall back to copying across filesystems.
    let template = "'" + replace(target + ".forkop.XXXXXX", /'/g, "'\\''") + "'";
    let pipe = fs.popen("mktemp " + template + " 2>/dev/null", "r");
    if (!pipe)
        return false;
    let temporary = trim(pipe.read("all") || "");
    if (pipe.close() != 0 || temporary == "")
        return false;

    let copied = system([ "cp", source, temporary ]) == 0 &&
        fs.chmod(temporary, 0600) && fs.rename(temporary, target);
    if (!copied)
        fs.unlink(temporary);
    return copied;
}

function restore_directory_snapshot(snapshot, target) {
    let original = fs.stat(snapshot);
    if (original?.type != "directory")
        return false;

    let parent = fs.stat(substr(target, 0, rindex(target, "/")) || "/");
    if (parent == null)
        return false;
    let stamp = clock();
    let displaced = sprintf("%s.rollback.%d.%d", target, stamp[0], stamp[1]);
    let staged = snapshot;
    if (parent.dev.major != original.dev.major || parent.dev.minor != original.dev.minor) {
        staged = displaced + ".staged";
        if (!fs.mkdir(staged, original.mode))
            return false;
        if (system([ "cp", "-R", "-p", snapshot + "/.", staged ]) != 0) {
            system([ "rm", "-rf", staged ]);
            return false;
        }
    }

    let had_target = fs.stat(target) != null;
    if ((!had_target || fs.rename(target, displaced)) && fs.rename(staged, target)) {
        if (had_target)
            system([ "rm", "-rf", displaced ]);
        if (staged != snapshot)
            system([ "rm", "-rf", snapshot ]);
        return true;
    }

    if (had_target && fs.stat(displaced) != null)
        fs.rename(displaced, target);
    if (staged != snapshot)
        system([ "rm", "-rf", staged ]);
    return false;
}

// Callers create parents separately: never narrow a shared parent such as /tmp.
function secure_private_dir(path) {
    if (path == null || path == "" || path == "/")
        return false;
    if (fs.stat(path) == null && !fs.mkdir(path, 0700))
        return false;
    if (!fs.chmod(path, 0700))
        return false;
    let entries = fs.lsdir(path);
    if (type(entries) != "array")
        return false;
    for (let entry in entries) {
        let file = path + "/" + entry;
        let stat = fs.stat(file);
        if (stat != null && stat.type == "file" && !fs.chmod(file, 0600))
            return false;
    }
    return true;
}

function strip_internal_fields(value) {
    if (type(value) == "array") {
        for (let i = 0; i < length(value); i++)
            value[i] = strip_internal_fields(value[i]);
        return value;
    }

    if (type(value) == "object") {
        for (let key in keys(value)) {
            if (substr(key, 0, 2) == "__") {
                delete value[key];
                continue;
            }
            value[key] = strip_internal_fields(value[key]);
        }
    }

    return value;
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function object_key_count(value) {
    return type(value) == "object" ? length(keys(value)) : 0;
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    let text = trim(as_string(value));
    return text == "" ? [] : split(text, " ");
}

function bool_option(section, key, fallback) {
    if (fallback == null)
        fallback = false;
    let value = option(section, key, fallback ? "1" : "0");
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

// The secret the generator writes to experimental.clash_api, and therefore
// the token every router-side controller call must send. It depends on the
// dashboard switch only: WAN exposure changes the bind address, not auth.
function clash_api_listen_address(address) {
    address = trim(as_string(address));
    if (address == "" || address == "0.0.0.0" || address == "::" || address == "[::]")
        return "127.0.0.1";
    return address;
}

function int_option(section, key, fallback) {
    let value = option(section, key, fallback);
    if (match(value, /[^0-9]/))
        return int(fallback, 10);
    return int(value, 10);
}

return {
    as_string,
    read_json_file,
    read_stdin,
    read_stdin_json,
    write_json,
    write_compact_string_array,
    csv_to_json_array,
    write_json_file,
    open_private_file,
    write_private_file,
    write_private_json_file,
    copy_private_file_atomic,
    restore_directory_snapshot,
    secure_private_dir,
    strip_internal_fields,
    array_or_empty,
    object_or_empty,
    object_key_count,
    option,
    list_option,
    bool_option,
    int_option,
    clash_api_listen_address
};
