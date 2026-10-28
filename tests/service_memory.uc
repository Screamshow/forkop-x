let fs = require("fs");
let memory = require("core.process_memory");
let root = ARGV[0];

function check(actual, expected, label) {
    if (actual !== expected)
        die(label + ": " + sprintf("%J != %J\n", actual, expected));
}

fs.mkdir(root);
fs.mkdir(root + "/42");
let stat = "42 (core with spaces) S";
for (let i = 0; i < 18; i++)
    stat += " 0";
stat += " 123";
fs.writefile(root + "/42/stat", stat);
fs.writefile(root + "/42/status", "VmRSS:\t2048 kB\n");
fs.writefile(root + "/42/cmdline", "/usr/bin/sing-box\x00run\x00-c\x00/etc/sing-box/config.json\x00");
let instance = { running: true, pid: 42, command: [ "/usr/bin/sing-box", "run", "-c", "/etc/sing-box/config.json" ] };
let services = { "sing-box": { instances: { main: instance, duplicate: instance } } };
check(memory.services_rss_bytes(services, "sing-box", root), 2097152, "RSS and deduplication");
instance.command[3] = "/tmp/foreign.json";
check(memory.services_rss_bytes(services, "sing-box", root), null, "Foreign process rejected");
instance.running = false;
check(memory.services_rss_bytes(services, "sing-box", root), 0, "Stopped process excluded");
instance.running = true;
instance.command[3] = "/etc/sing-box/config.json";
fs.unlink(root + "/42/status");
check(memory.services_rss_bytes(services, "sing-box", root), null, "Missing RSS stays unavailable");
fs.unlink(root + "/42/stat");
check(memory.services_rss_bytes(services, "sing-box", root), null, "Stale PID rejected");
// Restore the fixture and add a second service running the same core binary under
// a name of its own, which is what the native Tailscale does on a router.
fs.writefile(root + "/42/stat", stat);
fs.writefile(root + "/42/status", "VmRSS:\t2048 kB\n");
fs.writefile(root + "/42/cmdline", "/usr/bin/sing-box\x00run\x00-c\x00/etc/sing-box/config.json\x00");

fs.mkdir(root + "/99");
let tailscale_stat = "99 (sing-box) S";
for (let i = 0; i < 18; i++)
    tailscale_stat += " 0";
tailscale_stat += " 456";
fs.writefile(root + "/99/stat", tailscale_stat);
fs.writefile(root + "/99/status", "VmRSS:\t6448 kB\n");
fs.writefile(root + "/99/cmdline", "/usr/lib/rust-x/sing-box\x00tailscale-luci\x00");
let tailscale = { running: true, pid: 99, command: [ "/usr/lib/rust-x/sing-box", "tailscale-luci" ] };
services["forkop-tailscale"] = { instances: { instance1: tailscale } };

let core_names = [ "sing-box", "forkop-tailscale" ];
check(memory.services_group_rss_bytes(services, core_names, root), 8699904,
    "Both services of the core are summed");
check(memory.services_group_rss_bytes(services, [ "sing-box", "forkop-tailscale",
    "forkop-torrserver-direct" ], root), 8699904,
    "A component procd does not know adds nothing");
check(memory.services_group_rss_bytes(services, [ "absent-a", "absent-b" ], root), null,
    "No known service leaves the figure unavailable rather than zero");

// The same process reached through two names is one process.
services["forkop-tailscale-alias"] = services["forkop-tailscale"];
check(memory.services_group_rss_bytes(services,
    [ "sing-box", "forkop-tailscale", "forkop-tailscale-alias" ], root), 8699904,
    "One process counted once across names");
delete services["forkop-tailscale-alias"];

// A service that is registered but stopped contributes nothing and must not make
// the figure unavailable: the rest of the group is still measurable.
tailscale.running = false;
check(memory.services_group_rss_bytes(services, core_names, root), 2097152,
    "A stopped service contributes nothing");
tailscale.running = true;

// A live instance that cannot be proven to be the registered one makes the whole
// figure unavailable: a number known to be short must never be shown.
tailscale.command[1] = "something-else";
check(memory.services_group_rss_bytes(services, core_names, root), null,
    "An unverifiable service makes the whole figure unavailable");
tailscale.command[1] = "tailscale-luci";

check(memory.services_group_rss_bytes(services, "sing-box", root), null,
    "A group needs a list of names");
check(memory.services_group_rss_bytes(null, core_names, root), null,
    "No listing leaves the figure unavailable");

fs.unlink(root + "/99/stat");
fs.unlink(root + "/99/status");
fs.unlink(root + "/99/cmdline");
fs.rmdir(root + "/99");
fs.unlink(root + "/42/stat");
fs.unlink(root + "/42/status");
fs.unlink(root + "/42/cmdline");
fs.rmdir(root + "/42");
fs.rmdir(root);
print("Service memory tests passed\n");
