#!/usr/bin/env ucode
// Shared with ZMS: protect Connection transport without exempting Direct.
let fs = require("fs");
const GUARD = "meta mark & 0x02000000 == 0 ct mark & 0x02000000 == 0";
const TABLE = "forkop_proxy_transport";
const UPGRADE_LOCK = "/var/run/forkop-proxy-transport-upgrade";
const ZAPRET_ROOT = getenv("FORKOP_ZAPRET_ROOT") || "/opt";
function quote(s) { return "'" + replace(s, /'/g, "'\\''") + "'"; }
function capture(args) {
    let p = fs.popen(join(" ", map(args, quote)) + " 2>/dev/null", "r");
    if (!p) return { ok: false, output: "" };
    let output = p.read("all");
    return { ok: p.close() == 0, output };
}
function batch(text) {
    let p = capture(["mktemp"]); if (!p.ok) return false;
    let path = trim(p.output);
    let ok = fs.writefile(path, text) != null && capture(["nft", "-f", path]).ok;
    fs.unlink(path); return ok;
}
function file_hash(path) {
    let value = capture(["sha256sum", path]);
    let hash = split(trim(value.output), /[ \t]+/)[0];
    return value.ok && match(hash, /^[a-f0-9]{64}$/) ? hash : "";
}
function text_hash(text) {
    let allocated = capture(["mktemp"]); if (!allocated.ok) return "";
    let path = trim(allocated.output);
    if (fs.writefile(path, text) == null) { fs.unlink(path); return ""; }
    let hash = file_hash(path); fs.unlink(path); return hash;
}
function injected_rule(op) {
    return "\t# Forkop proxy transport NFQUEUE guard v1\n" +
        "\tlocal FORKOP_NFQ_GUARD=\n" +
        "\tcase \" $* \" in *\" queue \"*) FORKOP_NFQ_GUARD='" + GUARD + "' ;; esac\n" +
        "\tnft " + op + " rule inet $ZAPRET_NFT_TABLE $chain $FORKOP_NFQ_GUARD $FW_EXTRA_PRE \"$@\"";
}
function original_helper(text) {
    for (let op in ["add", "insert"])
        text = replace(text, injected_rule(op), "\tnft " + op + " rule inet $ZAPRET_NFT_TABLE $chain $FW_EXTRA_PRE \"$@\"");
    return text;
}
function managed_manager() {
    let path = ZAPRET_ROOT + "/zapret-manager-luci/backend.sh";
    if (fs.readlink(ZAPRET_ROOT + "/zapret-manager-luci") != null || fs.readlink(path) != null) return false;
    let source = fs.readfile(path) || "";
    return match(source, /(^|\n)ZM_FLAVOR="forkop-five-section-v1"(\r?\n|$)/) != null &&
        match(source, /(^|\n)ZM_SCRIPT_URL="https:\/\/raw\.githubusercontent\.com\/Screamshow\/Zapret-Manager\/(refs\/heads\/)?main\/ZapretManager_LuCI\.sh"(\r?\n|$)/) != null;
}
function managed_core(component) {
    if (!managed_manager()) return false;
    let root = ZAPRET_ROOT + "/" + component;
    let binary = root + (component == "zapret" ? "/nfq/nfqws" : "/nfq2/nfqws2");
    let helper = root + "/common/nft.sh";
    for (let path in [root, root + "/common", helper, binary])
        if (fs.readlink(path) != null) return false;
    let binary_hash = file_hash(binary), source = fs.readfile(helper);
    if (binary_hash == "" || source == null) return false;
    let base_hash = text_hash(original_helper(source));
    let receipt = null;
    try { receipt = json(fs.readfile(ZAPRET_ROOT + "/zapret-manager-luci/state/transport-ownership/" + component + ".json")); } catch(e) {}
    if (type(receipt) == "object" && receipt.schema == 1 && receipt.owner == "forkop-zms-v1" &&
        receipt.component == component && receipt.binary_sha256 == binary_hash &&
        (receipt.helper_sha256 == base_hash || receipt.helper_sha256 == text_hash(source))) return true;
    // Conservative legacy recognition: our published r100 ARM packages plus
    // exact producer/binary hashes and our manager contract. Generic upstream
    // packages, directory names and version matches alone are not ownership.
    let legacy = component == "zapret" ? {
        version:"72.20260307-r100",
        binary:"9688b545c810a942824026449b156db8eebac838e3618125f818302815245214",
        helper:"3474434485a677785efd62053e95baaadbcc32b0aaaad58c952e7dea093fb4ba"
    } : {
        version:"1.0.5.2-r100",
        binary:"36be8acaf41758f81fc213f70337c47622911711bfd047feab9b3ff659cab9e1",
        helper:"5d726b060c6d2af150c1d486d16591dcd00297a0effe56cb4aa0f73aaa9090c8"
    };
    let installed = capture(["apk", "info", "-v", component]);
    return binary_hash == legacy.binary && base_hash == legacy.helper && installed.ok &&
        index(split(trim(installed.output), "\n"), component + "-" + legacy.version) >= 0;
}
function guarded_helper(text) {
    if (index(text, "# Forkop proxy transport NFQUEUE guard v1") >= 0) {
        for (let op in ["add", "insert"])
            if (index(text, "nft " + op + " rule inet $ZAPRET_NFT_TABLE $chain $FORKOP_NFQ_GUARD $FW_EXTRA_PRE \"$@\"") < 0)
                die("Incomplete zapret transport guard; refusing unprotected startup\n");
        return text;
    }
    for (let op in ["add", "insert"]) {
        let line = "\tnft " + op + " rule inet $ZAPRET_NFT_TABLE $chain $FW_EXTRA_PRE \"$@\"";
        if (index(text, line) < 0) die("Unsupported zapret nft helper; refusing unprotected startup\n");
        text = replace(text, line, injected_rule(op));
    }
    return text;
}
function guarded_rules(text, table) {
    let chain = "", commands = "";
    for (let raw in split(text, "\n")) {
        let line = trim(raw), found = match(line, /^chain ([A-Za-z0-9_]+) \{/);
        if (found) { chain = found[1]; continue; }
        if (!match(line, /(^|[ \t])queue([ \t]|$)/) || index(replace(line, /0x00000000/g, "0"), GUARD) == 0) continue;
        let handle = match(line, / # handle ([0-9]+)$/);
        if (chain == "" || !handle) die("Cannot guard zapret queue rule\n");
        commands += "replace rule inet " + table + " " + chain + " handle " + handle[1] + " " +
            GUARD + " " + replace(line, / # handle [0-9]+$/, "") + "\n";
    }
    return commands;
}
function prepare() {
    // Patch the supported producer before it can recreate any queue rules.
    // Write atomically; never truncate the script of a concurrently starting service.
    let managed = [];
    for (let component in ["zapret", "zapret2"]) {
        if (!managed_core(component)) continue;
        push(managed, component);
        let root = ZAPRET_ROOT + "/" + component;
        let path = root + "/common/nft.sh", original = fs.readfile(path);
        if (original == null) continue;
        let updated = guarded_helper(original);
        if (updated != original) {
            let allocated = capture(["mktemp", path + ".forkop-new.XXXXXX"]);
            if (!allocated.ok) die("Cannot stage zapret transport guard\n");
            let stage = trim(allocated.output);
            if (fs.writefile(stage, updated) == null || !fs.chmod(stage, 0755) || !fs.rename(stage, path))
                die("Cannot install zapret transport guard\n");
        }
    }
    let existing = capture(["nft", "list", "table", "inet", TABLE]);
    let exists = existing.ok;
    if (exists && index(existing.output, 'comment "Forkop proxy transport guard v1"') < 0)
        die("Refusing to overwrite a foreign proxy transport table\n");
    let commands = (exists ? "" : 'add table inet ' + TABLE + ' { comment "Forkop proxy transport guard v1"; }\n') +
        (exists ? "flush chain inet " + TABLE + " output\n" :
            "add chain inet " + TABLE + " output { type filter hook output priority -151; policy accept; }\n") +
        "add rule inet " + TABLE + " output ct direction original meta mark & 0x08000000 != 0 meta mark & 0x02000000 == 0 ct mark set ct mark & 0xfdffffff\n" +
        "add rule inet " + TABLE + " output meta mark & 0x02000000 != 0 ct mark set ct mark | 0x02000000\n";
    for (let table in managed) {
        let result = capture(["nft", "-a", "list", "table", "inet", table]);
        if (result.ok) commands += guarded_rules(result.output, table);
    }
    if (!batch(commands)) die("Cannot apply proxy transport protection\n");
}
function owner_identity(pid) {
    if (!match(pid, /^[1-9][0-9]*$/)) die("Invalid upgrade owner\n");
    let stat = fs.readfile("/proc/" + pid + "/stat");
    let fields = stat == null ? null : match(stat, /^.*\) (.*)$/);
    if (!fields) die("Upgrade owner is no longer running\n");
    return pid + ":" + split(fields[1], " ")[19];
}
function hold(pid) {
    let owner = owner_identity(pid);
    if (!fs.mkdir(UPGRADE_LOCK, 0700)) {
        let previous = trim(fs.readfile(UPGRADE_LOCK + "/owner") || "");
        let previous_pid = split(previous, ":")[0];
        if (previous == "") die("Incomplete zapret upgrade guard state; protection retained\n");
        if (previous != owner && match(previous_pid, /^[1-9][0-9]*$/) &&
            fs.stat("/proc/" + previous_pid) != null && owner_identity(previous_pid) == previous)
            die("Another zapret upgrade holds the transport guard\n");
    }
    if (fs.writefile(UPGRADE_LOCK + "/owner", owner) == null)
        die("Cannot record zapret upgrade guard owner\n");
    prepare();
    let exists = capture(["nft", "list", "chain", "inet", TABLE, "upgrade"]).ok;
    let commands = (exists ? "flush chain inet " + TABLE + " upgrade\n" :
        "add chain inet " + TABLE + " upgrade { type filter hook output priority -152; policy accept; }\n") +
        'add rule inet ' + TABLE + ' upgrade meta mark & 0x02000000 != 0 counter drop comment "Forkop proxy transport upgrade hold"\n';
    if (!batch(commands)) die("Cannot hold protected transport during zapret package replacement\n");
}
function release(pid) {
    if (trim(fs.readfile(UPGRADE_LOCK + "/owner") || "") != owner_identity(pid))
        die("Zapret upgrade guard owner mismatch\n");
    // Repair the producer and its live queues before unblocking transport.
    // A failed upgrade/unknown rule format leaves the hold in place.
    prepare();
    if (!batch("flush chain inet " + TABLE + " upgrade\n")) die("Cannot release zapret upgrade guard\n");
    fs.unlink(UPGRADE_LOCK + "/owner"); fs.rmdir(UPGRADE_LOCK);
}
if (ARGV[0] == "guard-helper-fixture") print(guarded_helper(fs.readfile(ARGV[1])));
else if (ARGV[0] == "guard-rules-fixture") print(guarded_rules(fs.readfile(ARGV[1]), "zapret"));
else if (ARGV[0] == "prepare") prepare();
else if (ARGV[0] == "hold") hold(ARGV[1] || "");
else if (ARGV[0] == "release") release(ARGV[1] || "");
else die("Expected prepare, hold or release\n");
