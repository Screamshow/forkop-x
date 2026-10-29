#!/usr/bin/env ucode
// Run with FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR, TMP_SUBSCRIPTION_FOLDER,
// FORKOP_UCI_STATE_FILE pointing at an isolated test directory.
let fs = require("fs");
let common = require("core.common");
let selection = require("subscription.filter_selection");
let uci = require("core.uci");
let connections = require("config.connections");
let checks = 0;
function expect(value, message) {
    if (!value) die("FAIL: " + message + "\n");
    checks++;
}
function eq(actual, expected, message) {
    expect(sprintf("%J", actual) == sprintf("%J", expected), message);
}
let old = [ { name: "Moscow #1", key: "removed" }, { name: "Moscow #2", key: "keep" } ];
let next = [ { name: "Moscow #1", key: "keep" } ];
let r = selection.reconcile([ "Moscow #2" ], [], old, next);
eq(r.names, [ "Moscow #1" ], "renumber selected second server");
eq(r.records[0].keys, [ "keep" ], "preserve selected identity");
r = selection.reconcile([ "Moscow #1" ], [], old, next);
eq(r.records[0].keys, [ "removed" ], "deleted server keeps tombstone");
r = selection.reconcile([ "Moscow #1" ], r.records, next, next);
eq(r.records[0].keys, [ "removed" ], "repeated refresh must not rebind deleted server");
let swapped = [ { name: "Moscow #2", key: "removed" }, { name: "Moscow #1", key: "keep" } ];
r = selection.reconcile([ "Moscow #1", "Moscow #2" ], [], old, swapped);
eq(r.names, [ "Moscow #2", "Moscow #1" ], "simultaneous swaps do not cascade");
eq(r.records[0].keys, [ "removed" ], "first swapped identity");
let duplicates = [ { name: "Same", key: "source-a" }, { name: "Same", key: "source-b" } ];
r = selection.reconcile([ "Same" ], [], duplicates,
    [ { name: "A", key: "source-a" }, { name: "B", key: "source-b" } ]);
eq(r.names, [ "A", "B" ], "duplicate names keep both selected connections");
eq(r.records[0].keys, [ "source-a" ], "split names receive their own identity");
eq(r.records[1].keys, [ "source-b" ], "split selection remains independently editable");
r = selection.reconcile([ "Explicit new choice" ], [ { name: "Old", keys: [ "old" ] } ],
    [ { name: "Explicit new choice", key: "new" } ], [ { name: "Renamed", key: "new" } ]);
eq(r.names, [ "Renamed" ], "user selection overrides previous binding");
let a = { tag: "Old", remark: "Old", type: "vless", server: "example.test", server_port: 443, uuid: "test-user" };
let b = { ...a, tag: "New", remark: "New", __forkop_filter_names: [ "Old" ] };
expect(selection.connection("source-a", a) == selection.connection("source-a", b), "connection identity ignores names");
expect(selection.connection("source-a", a) != selection.connection("source-b", a), "source identities remain distinct");
let staged = { include: [{ name: "B", keys: ["selected"] }], _include_values: ["B"],
    _include_previous: { values: ["A"], records: [{ name: "A", keys: ["selected"] }] } };
eq(selection.bound_names(staged, "include", ["A"]), { A: ["selected"] }, "interrupted commit keeps old filter bound");
eq(selection.bound_names(staged, "include", ["B"]), { B: ["selected"] }, "committed filter uses new binding");
eq(selection.bound_names(staged, "include", ["Explicit new choice"]), {}, "user edit does not inherit stale bindings");

let dir = getenv("FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR");
let runtime = getenv("TMP_SUBSCRIPTION_FOLDER");
expect(dir && runtime && getenv("FORKOP_UCI_STATE_FILE"), "isolated paths required");
fs.mkdir(dir, 0700); fs.mkdir(runtime, 0700);
uci.set_section("forkop.test", "section");
uci.set("forkop.test.connection_type", "subscription");
uci.set_section("forkop.group", "urltest");
uci.set("forkop.group.section", "test");
uci.set("forkop.group.include_outbounds", "Moscow #2");
connections.set_item_sections_from_data({ urltest: [ { ".name": "group", ".type": "urltest", section: "test", include_outbounds: [ "Moscow #2" ] } ] });
let section = { ".name": "test", subscription_url: "https://subscription.test/feed" };
// Use the same descriptor path as a real URLTest, with synthetic feed snapshots.
let before = { section, previous: old, saved: {}, descriptors: [ {
    key: selection.urltest_key(section, "group"), side: "include", values: [ "Moscow #2" ],
    owner: "group", field: "include_outbounds", nested: "" } ] };
// No configured feed is required for this UCI/private-state test: the selected
// host is absent and must be persisted as a tombstone without exposing its key.
let result = selection.finish(before);
expect(result.ok, "persist bindings");
let saved = selection.read("test");
eq(saved[selection.urltest_key(section, "group")].include[0].keys, [ "keep" ], "persisted identity");
expect((fs.stat(dir + "/test.filter-bindings").mode & 0777) == 0600, "binding cache private");
expect(index(fs.readfile(getenv("FORKOP_UCI_STATE_FILE")), "keep") < 0, "private identity not written to UCI");

// Real cache -> UCI migration, followed by a second update. Persisted bindings
// must use the renamed value, with no stale alias capable of changing choices.
let old_node = { ...a, tag: "Moscow #2", remark: "Moscow #2" };
let new_node = { ...a, tag: "Moscow #1", remark: "Moscow #1" };
let source = "https://subscription.test/feed";
connections.set_item_sections_from_data({
    subscription_url: [ { ".name": "source", section: "test", url: source } ],
    urltest: [ { ".name": "group", section: "test", include_outbounds: [ "Moscow #2" ] } ]
});
fs.unlink(dir + "/test.filter-bindings");
common.write_private_json_file(runtime + "/test-subscription-1.json", { outbounds: [ old_node ] });
before = selection.snapshot(section);
expect(length(before.previous) == 1, "snapshot reads configured source");
common.write_private_json_file(runtime + "/test-subscription-1.json", { outbounds: [ new_node ] });
result = selection.finish(before);
expect(result.ok && result.changed, "cache rename updates UCI");
eq(uci.get_all("forkop", "group").include_outbounds, "Moscow #1", "UCI displays current name");
saved = selection.read("test");
eq(map(saved[selection.urltest_key(section, "group")].include, record => record.name), [ "Moscow #1" ], "obsolete binding names removed after commit");

connections.set_item_sections_from_data({
    subscription_url: [ { ".name": "source", section: "test", url: source } ],
    urltest: [ { ".name": "group", section: "test", include_outbounds: [ "Moscow #1" ] } ]
});
before = selection.snapshot(section);
let addressed = { ...new_node, server: "192.0.2.10" };
common.write_private_json_file(runtime + "/test-subscription-1.json", { outbounds: [ addressed ] });
result = selection.finish(before);
expect(result.ok, "domain to IP refresh succeeds");
saved = selection.read("test");
eq(saved[selection.urltest_key(section, "group")].include[0].keys,
    [ selection.connection(source, addressed) ], "domain to IP updates persisted binding");
before = selection.snapshot(section);
result = selection.finish(before);
expect(result.ok, "repeated address refresh succeeds");
let replacement = { ...new_node, server: "replacement.test", uuid: "different-user" };
common.write_private_json_file(runtime + "/test-subscription-1.json", { outbounds: [ replacement ] });
result = selection.finish(before);
expect(result.ok, "removed pinned connection can be persisted");
saved = selection.read("test");
expect(index(saved[selection.urltest_key(section, "group")].include[0].keys,
    selection.connection(source, replacement)) < 0, "reused name never rebinds after removal");

function candidate(node, src) {
    return { name: node.tag, key: selection.connection(src || source, node) };
}
let original = candidate(new_node);
let moved = candidate(addressed);
function migration(next, previous) {
    return selection.reconcile([new_node.tag], [{name:new_node.tag,keys:[original.key]}],
        previous || [original], next).records[0].keys;
}
eq(migration([moved]), [moved.key], "unique address change accepted");
eq(migration([moved], []), [moved.key], "saved old binding repairs already refreshed cache");
eq(migration([moved], [moved]), [moved.key], "recovery uses updated cache with stale saved binding");
eq(migration([candidate({...addressed, server:'192.0.2.11'}), moved]),
    [original.key], "duplicate names do not migrate");
eq(migration([candidate(addressed, 'different-source')]), [original.key], "source change rejected");
eq(migration([candidate({...addressed, server_port:8443})]), [original.key], "port change rejected");
eq(migration([candidate({...addressed, tls:{enabled:true}})]), [original.key], "TLS change rejected");
eq(migration([candidate({...addressed, transport:{type:'ws'}})]), [original.key], "transport change rejected");
eq(migration([moved, candidate({...new_node,tag:'Renamed'})]),
    [original.key], "surviving renamed identity wins over reused name");
eq(migration([moved], [original,moved]), [original.key], "existing different node cannot take over name");
let reverse = selection.reconcile([addressed.tag], [{name:addressed.tag,keys:[moved.key]}],
    [moved], [original]);
eq(reverse.records[0].keys, [original.key], "IP to domain change accepted");

let fixture = { settings: { ".name": "settings", ".type": "settings" },
    section: [{ ".name": "test", ".type": "section", enabled: "1", action: "connection", subscription_urls: [ source ] }],
    urltest: [{ ".name": "group", ".type": "urltest", section: "test", name: "Pinned", filter_mode: "include", include_outbounds: [ "Moscow #1" ] }] };
common.write_private_json_file(runtime + "/fixture.json", fixture);
common.write_private_json_file(runtime + "/test-subscription-1.json", { outbounds: [ replacement, { ...old_node, server: addressed.server } ] });
fs.writefile(runtime + "/test-subscription-1.url", source + "\n");
fs.writefile(runtime + "/test-subscription-1.user_agent", "INCY/" + require("core.constants").FORKOP_VERSION + "\n");

let legacy_settings = sprintf("%J", { urltest: { urltest_include_outbounds: [ "Moscow #2" ], urltest_exclude_outbounds: [ "Moscow #2" ] } });
let legacy_section = { ".name": "legacy", urltest_enabled: "1", urltest_settings: legacy_settings };
uci.set_section("forkop.legacy", "section");
uci.set("forkop.legacy.urltest_settings", legacy_settings);
connections.set_item_sections_from_data({ subscription_url: [{ ".name": "legacy_source", section: "legacy", url: source }] });
common.write_private_json_file(runtime + "/legacy-subscription-1.json", { outbounds: [ old_node ] });
before = selection.snapshot(legacy_section);
common.write_private_json_file(runtime + "/legacy-subscription-1.json", { outbounds: [ new_node ] });
result = selection.finish(before);
expect(result.ok && result.changed, "legacy nested filters migrated");
let migrated = json(uci.get("forkop.legacy.urltest_settings"));
eq(migrated.urltest.urltest_include_outbounds, [ "Moscow #1" ], "legacy include updated");
eq(migrated.urltest.urltest_exclude_outbounds, [ "Moscow #1" ], "legacy exclude updated without overwriting include");

uci.set_section("forkop.priority", "section");
uci.set_section("forkop.pg", "priority_group");
uci.set("forkop.pg.section", "priority");
uci.set_section("forkop.level", "priority_level");
uci.set("forkop.level.group", "pg");
uci.set("forkop.level.server_name", "Moscow #2");
connections.set_item_sections_from_data({
    subscription_url: [{ ".name": "priority_source", section: "priority", url: source }],
    priority_group: [{ ".name": "pg", section: "priority" }],
    priority_level: [{ ".name": "level", group: "pg", server_name: [ "Moscow #2" ] }]
});
common.write_private_json_file(runtime + "/priority-subscription-1.json", { outbounds: [ old_node ] });
before = selection.snapshot({ ".name": "priority" });
common.write_private_json_file(runtime + "/priority-subscription-1.json", { outbounds: [ new_node ] });
result = selection.finish(before);
expect(result.ok && result.changed, "priority filter migrated");
eq(uci.get("forkop.level.server_name"), "Moscow #1", "priority legacy server_name updated");
printf("PASS: subscription filter selection (%d checks)\n", checks);
