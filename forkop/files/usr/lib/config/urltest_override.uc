#!/usr/bin/env ucode
let uci_core = require("core.uci");
let singbox_constants = require("xrust.constants");
const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";
function str(v) {
    return v == null ? "" : "" + v;
}
function find(rule, tag) {
    for (let s in uci_core.section_objects(CONFIG_NAME, "urltest_override"))
        if (str(s.rule) == str(rule) && str(s.tag) == str(tag)) return s;
    return null;
}
function get(rule, tag) {
    let s = find(rule, tag); if (type(s) != "object") return null;
    return { testing_url: str(s.testing_url), check_interval: str(s.check_interval), tolerance: str(s.tolerance), idle_timeout: str(s.idle_timeout), interrupt_exist_connections: str(s.interrupt_exist_connections || "1") };
}
function source(rule, tag) {
    for (let s in uci_core.section_objects(CONFIG_NAME, "urltest")) {
        let name = str(s[".name"]);
        if (str(s.section) != str(rule) || name == "")
            continue;
        let expected = name == "urltest"
            ? singbox_constants.outbound_tag(str(rule) + "-urltest")
            : singbox_constants.outbound_tag(str(rule) + "-urltest-" + name);
        if (expected == str(tag))
            return s;
    }
    return null;
}
function save_source(s, tag, url, interval, tolerance, idle, interrupt) {
    let name = str(s[".name"]);
    if (name == "")
        return false;
    for (let k, v in {
        testing_url: url,
        check_interval: interval,
        tolerance: "" + tolerance,
        idle_timeout: idle,
        interrupt_exist_connections: interrupt
    })
        if (!uci_core.set(CONFIG_NAME + "." + name + "." + k, v))
            return false;
    let override = find(str(s.section), tag);
    if (type(override) == "object" && !uci_core.delete(CONFIG_NAME + "." + str(override[".name"])))
        return false;
    return uci_core.commit(CONFIG_NAME);
}
function apply(outbound, rule, tag) {
    let o = get(rule, tag); if (type(outbound) != "object" || type(o) != "object") return outbound;
    outbound.url = o.testing_url; outbound.interval = o.check_interval; outbound.tolerance = int(o.tolerance, 10);
    outbound.idle_timeout = o.idle_timeout; outbound.interrupt_exist_connections = o.interrupt_exist_connections == "1"; return outbound;
}
function valid_duration(v) { return match(str(v), /^[1-9][0-9]*(ms|s|m|h|d)$/) != null; }
function save(rule, tag, url, interval, tolerance, idle, interrupt) {
    let tolerance_value = str(tolerance);
    tolerance = int(tolerance, 10);
    if (rule == "" || tag == "" || match(str(url), /^https?:\/\/[^[:space:]]+$/) == null ||
        !valid_duration(interval) || !valid_duration(idle) || match(tolerance_value, /^[0-9]+$/) == null ||
        tolerance < 0 || tolerance > 65535 || (interrupt != "0" && interrupt != "1")) return false;
    let source_section = source(rule, tag);
    if (type(source_section) == "object")
        return save_source(source_section, tag, url, interval, tolerance, idle, interrupt);
    let s = find(rule, tag), name = type(s) == "object" ? str(s[".name"]) : uci_core.add(CONFIG_NAME, "urltest_override");
    if (name == "") return false;
    for (let k, v in { rule, tag, testing_url: url, check_interval: interval, tolerance: "" + tolerance, idle_timeout: idle, interrupt_exist_connections: interrupt })
        if (!uci_core.set(CONFIG_NAME + "." + name + "." + k, v)) return false;
    return uci_core.commit(CONFIG_NAME);
}
function reset(rule, tag) {
    let s = find(rule, tag); if (type(s) != "object") return true;
    return uci_core.delete(CONFIG_NAME + "." + str(s[".name"])) && uci_core.commit(CONFIG_NAME);
}
let mode = ARGV[0] || "";
if (mode == "save") exit(save(ARGV[1] || "", ARGV[2] || "", ARGV[3] || "", ARGV[4] || "", ARGV[5] || "", ARGV[6] || "", ARGV[7] || "") ? 0 : 1);
if (mode == "reset") exit(reset(ARGV[1] || "", ARGV[2] || "") ? 0 : 1);
return { get, apply, save, reset };
