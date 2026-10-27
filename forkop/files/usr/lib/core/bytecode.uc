#!/usr/bin/env ucode

// The installed library is compiled once into a tmpfs bytecode cache: parsing modules from
// source dominates every short-lived Forkop process. The manifest records every source file
// and the interpreter, so an upgrade, a hand-copied module or a new ucode invalidates it.

let fs = require("fs");

function as_string(value) {
    return value == null ? "" : "" + value;
}

// The cache must be loaded by the interpreter that wrote it: an older ucode may accept a newer
// header and misread the body.
function ucode_binary() {
    let configured = getenv("FORKOP_UCODE_BIN");
    if (configured != null && configured != "")
        return configured;

    let executable = fs.readlink("/proc/self/exe");
    return executable == null ? "/usr/bin/ucode" : executable;
}

const SOURCE_DIR = getenv("FORKOP_SOURCE_LIB") || "/usr/lib/forkop";
const CACHE_DIR = getenv("FORKOP_BYTECODE_CACHE_DIR") || "/var/run/forkop/bytecode";
const UCODE_BIN = ucode_binary();
const MANIFEST_VERSION = "4";
// A leaf module, loaded through the fresh cache to prove the interpreter accepts it.
const SELF_CHECK_MODULE = "config.domain";
const BUILD_LOCK_MAX_AGE = 120;
// Revalidating the manifest costs a stat per module, so a proven manifest is trusted for a few
// seconds; an upgrade clears the stamp from postinst.
const VALIDATION_TTL_SECONDS = int(getenv("FORKOP_BYTECODE_VALIDATION_TTL") || "3");

function enabled() {
    return as_string(getenv("FORKOP_BYTECODE_CACHE") || "1") != "0";
}

function manifest_path() {
    return CACHE_DIR + "/manifest";
}

function build_lock_path() {
    return CACHE_DIR + "/build.lock";
}

function unique_suffix() {
    let now = clock();
    return as_string(now[0]) + "." + as_string(now[1]);
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash <= 0 ? "" : substr(path, 0, slash);
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_success(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return system(join(" ", parts) + " >/dev/null 2>&1") == 0;
}

// The inode catches a rename over the file; the mtime alone misses an edit in the build's second.
function file_signature(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.type != "file")
        return null;
    return as_string(stat.size) + " " + as_string(stat.mtime) + " " + as_string(stat.inode);
}

// The entries, since a directory mtime may not move visibly within the build's second.
function directory_signature(path) {
    let names = fs.lsdir(as_string(path));
    if (type(names) != "array")
        return null;
    return join("/", sort(filter(names, (name) => name != "." && name != "..")));
}

function is_directory(path) {
    let stat = fs.stat(as_string(path));
    return stat != null && stat.type == "directory";
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/")
        return true;
    if (fs.stat(path) != null)
        return is_directory(path);
    if (!ensure_dir(parent_dir(path)))
        return false;
    return fs.mkdir(path) || is_directory(path);
}

function remove_tree(path) {
    path = as_string(path);
    if (path != "")
        command_success([ "rm", "-rf", path ]);
}

function runtime_dependencies() {
    let result = [ UCODE_BIN ];
    for (let path in fs.glob("/usr/lib/libucode.so*"))
        push(result, path);
    sort(result);
    return result;
}

function is_module_file(relative_path) {
    relative_path = as_string(relative_path);
    return length(relative_path) > 3 && substr(relative_path, length(relative_path) - 3) == ".uc";
}

function collect_files(dir, prefix, result, directories) {
    let names = fs.lsdir(dir);
    if (type(names) != "array")
        return result;

    for (let name in names) {
        if (name == "." || name == "..")
            continue;

        let path = dir + "/" + name;
        let relative_path = prefix == "" ? name : prefix + "/" + name;
        let stat = fs.stat(path);
        if (stat == null)
            continue;
        if (stat.type == "directory") {
            push(directories, relative_path);
            collect_files(path, relative_path, result, directories);
        }
        else if (stat.type == "file")
            push(result, relative_path);
    }

    return result;
}

// Directory mtimes catch a module added beside unchanged siblings.
function source_directories() {
    let directories = [ "" ];
    collect_files(SOURCE_DIR, "", [], directories);
    sort(directories);
    return directories;
}

// Taken before the walk and checked after it, so an install writing during a build is noticed.
function directory_signatures() {
    let result = [];
    for (let relative_path in source_directories()) {
        let path = relative_path == "" ? SOURCE_DIR : SOURCE_DIR + "/" + relative_path;
        let signature = directory_signature(path);
        if (signature == null)
            return null;
        push(result, [ relative_path, signature ]);
    }
    return result;
}

function directory_signatures_match(snapshot) {
    if (snapshot == null)
        return false;

    let current = directory_signatures();
    if (current == null || length(current) != length(snapshot))
        return false;

    for (let i = 0; i < length(snapshot); i++)
        if (current[i][0] != snapshot[i][0] || current[i][1] != snapshot[i][1])
            return false;

    return true;
}

function source_files() {
    let result = collect_files(SOURCE_DIR, "", [], []);
    sort(result);
    return result;
}

function manifest_text(library, files, dependencies, directories) {
    let text = "version=" + MANIFEST_VERSION + "\n";
    text += "lib=" + as_string(library) + "\n";
    text += "src=" + SOURCE_DIR + "\n";
    text += "bin=" + UCODE_BIN + "\n";

    for (let path in dependencies) {
        let signature = file_signature(path);
        if (signature != null)
            text += "dep=" + path + "\t" + signature + "\n";
    }

    for (let entry in directories)
        text += "dir=" + entry[0] + "\t" + entry[1] + "\n";

    for (let relative_path in files) {
        let signature = file_signature(SOURCE_DIR + "/" + relative_path);
        if (signature == null)
            return null;
        text += "file=" + relative_path + "\t" + signature + "\n";
    }

    return text;
}

function parse_manifest(text) {
    let result = { version: "", lib: "", src: "", bin: "", deps: [], files: [], dirs: [] };

    for (let line in split(as_string(text), "\n")) {
        let separator = index(line, "=");
        if (separator <= 0)
            continue;

        let key = substr(line, 0, separator);
        let value = substr(line, separator + 1);

        if (key == "version")
            result.version = value;
        else if (key == "lib")
            result.lib = value;
        else if (key == "src")
            result.src = value;
        else if (key == "bin")
            result.bin = value;
        else if (key == "dep" || key == "file" || key == "dir") {
            let tab = index(value, "\t");
            if (tab < 0)
                continue;
            let entry = [ substr(value, 0, tab), substr(value, tab + 1) ];
            if (key == "dep")
                push(result.deps, entry);
            else if (key == "file")
                push(result.files, entry);
            else
                push(result.dirs, entry);
        }
    }

    return result;
}

function manifest_matches(manifest) {
    if (manifest.version != MANIFEST_VERSION || manifest.src != SOURCE_DIR)
        return false;
    if (manifest.bin != UCODE_BIN)
        return false;
    if (manifest.lib == "" || length(manifest.files) == 0)
        return false;
    if (!is_directory(manifest.lib))
        return false;

    for (let entry in manifest.deps)
        if (file_signature(entry[0]) != entry[1])
            return false;

    for (let entry in manifest.dirs) {
        let path = entry[0] == "" ? SOURCE_DIR : SOURCE_DIR + "/" + entry[0];
        if (directory_signature(path) != entry[1])
            return false;
    }

    for (let entry in manifest.files)
        if (file_signature(SOURCE_DIR + "/" + entry[0]) != entry[1])
            return false;

    return true;
}

function validation_stamp_path() {
    return CACHE_DIR + "/validated";
}

function now_seconds() {
    return int(clock()[0]);
}

// The stamp names the library it proved, so the fast path never reads the manifest.
function validation_stamp_library() {
    if (VALIDATION_TTL_SECONDS <= 0)
        return "";

    let text = fs.readfile(validation_stamp_path());
    if (text == null)
        return "";

    let parts = split(trim(as_string(text)), " ");
    if (length(parts) < 2 || parts[1] == "")
        return "";
    if (match(parts[0], /^[0-9]+$/) == null)
        return "";

    let age = now_seconds() - int(parts[0]);
    if (age < 0 || age >= VALIDATION_TTL_SECONDS)
        return "";

    return is_directory(parts[1]) ? parts[1] : "";
}

function write_validation_stamp(library) {
    if (VALIDATION_TTL_SECONDS <= 0)
        return;
    fs.writefile(validation_stamp_path(), now_seconds() + " " + as_string(library) + "\n");
}

function invalidate_validation_stamp() {
    try {
        fs.unlink(validation_stamp_path());
    }
    catch (e) {
    }
    return true;
}

function library_dir() {
    if (!enabled())
        return SOURCE_DIR;

    let stamped = validation_stamp_library();
    if (stamped != "")
        return stamped;

    let text = fs.readfile(manifest_path());
    if (text == null)
        return SOURCE_DIR;

    let manifest = parse_manifest(text);
    if (!manifest_matches(manifest))
        return SOURCE_DIR;

    write_validation_stamp(manifest.lib);
    return manifest.lib;
}

function compile_file(source, target) {
    // -s drops debug information; the sources stay installed for reading tracebacks.
    return command_success([ UCODE_BIN, "-c", "-s", "-o", target, source ]) &&
        fs.stat(target) != null;
}

function copy_file(source, target) {
    let data = fs.readfile(source);
    return data != null && fs.writefile(target, data) != null;
}

function self_check(library) {
    return command_success([ UCODE_BIN, "-L", library, "-e",
        "require(\"" + SELF_CHECK_MODULE + "\");" ]);
}

function publish_manifest(text) {
    let temporary = manifest_path() + ".new." + unique_suffix();
    if (fs.writefile(temporary, text) == null)
        return false;
    if (fs.rename(temporary, manifest_path()))
        return true;

    fs.unlink(temporary);
    return false;
}

// A process that finds a build running uses the sources rather than waiting.
function acquire_build_lock() {
    let path = build_lock_path();
    if (fs.mkdir(path))
        return true;

    let stat = fs.stat(path);
    if (stat == null)
        return fs.mkdir(path);
    if (clock()[0] - int(stat.mtime || 0) < BUILD_LOCK_MAX_AGE)
        return false;

    fs.rmdir(path);
    return fs.mkdir(path);
}

function release_build_lock() {
    fs.rmdir(build_lock_path());
}

function compile_library(files) {
    let library = CACHE_DIR + "/lib." + unique_suffix();
    if (!ensure_dir(library))
        return null;

    for (let relative_path in files) {
        let source = SOURCE_DIR + "/" + relative_path;
        let target = library + "/" + relative_path;

        if (!ensure_dir(parent_dir(target))) {
            remove_tree(library);
            return null;
        }

        // A module that fails to compile is copied as source, so its require still resolves.
        if (is_module_file(relative_path) && compile_file(source, target))
            continue;

        if (!copy_file(source, target)) {
            remove_tree(library);
            return null;
        }
    }

    if (!self_check(library)) {
        remove_tree(library);
        return null;
    }

    return library;
}

// The replaced library stays for workers started before the build; older ones go.
function remove_older_libraries(current, replaced) {
    for (let name in fs.lsdir(CACHE_DIR) ?? []) {
        let path = CACHE_DIR + "/" + name;
        if (substr(name, 0, 4) == "lib." && path != current && path != replaced && is_directory(path))
            remove_tree(path);
    }
}

function build() {
    if (!enabled())
        return SOURCE_DIR;

    let directories = directory_signatures();
    let files = source_files();
    if (length(files) == 0)
        return SOURCE_DIR;

    if (!ensure_dir(CACHE_DIR))
        return SOURCE_DIR;

    if (!acquire_build_lock())
        return library_dir();

    let library = compile_library(files);

    // The tree changed during the walk, so this file list may miss what landed late.
    if (library != null && !directory_signatures_match(directories)) {
        remove_tree(library);
        release_build_lock();
        return SOURCE_DIR;
    }

    let text = library == null ? null : manifest_text(library, files, runtime_dependencies(), directories);
    let replaced = parse_manifest(fs.readfile(manifest_path())).lib;

    if (text == null || !publish_manifest(text)) {
        remove_tree(library);
        release_build_lock();
        return SOURCE_DIR;
    }

    remove_older_libraries(library, replaced);
    release_build_lock();
    write_validation_stamp(library);
    return library;
}

function refresh() {
    let current = library_dir();
    return current == SOURCE_DIR ? build() : current;
}

return {
    enabled,
    invalidate_validation_stamp,
    library_dir,
    refresh,
    build
};
