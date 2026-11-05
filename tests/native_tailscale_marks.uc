let marks = require("diagnostics.mark_rules");
let reply = "ct direction reply ct mark & 0x00ff0000 == 0x00880000 meta mark set meta mark & 0xfb88ffff | 0x00880000";
let ingress = 'iifname "forkop-tslan" ct mark set ct mark & 0xff88ffff | 0x00880000';
for (let line in [reply, ingress, "\t" + reply])
    assert(marks.is_native_tailscale_mark("inet", "forkop_native_tailscale", line), "known native rule");
for (let line in ["meta mark set 0x1234", replace(reply, "0xfb88ffff", "0xffffffff"), replace(reply, "0x00880000", "0x00990000")])
    assert(!marks.is_native_tailscale_mark("inet", "forkop_native_tailscale", line), "foreign rule in native table");
assert(!marks.is_native_tailscale_mark("ip", "forkop_native_tailscale", reply), "wrong family");
assert(!marks.is_native_tailscale_mark("inet", "foreign", reply), "wrong table");
print("PASS: native Tailscale marks; unknown rules remain visible\n");
