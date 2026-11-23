#!/bin/sh
# Run with ucode available, or pipe this script's --emit output into ucode on OpenWrt.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
emit() {
    cat <<'UCODE'
let subscription_filter_connections = { new: "host-new", old: "host-old" };
let regex_matches = [];
let runtime_urltest = {
    normalized_country_list: values => values,
    regex_matching_tag_array: () => regex_matches
};
function array_or_empty(value) { return type(value) == "array" ? value : []; }
function object_or_empty(value) { return type(value) == "object" ? value : {}; }
function as_string(value) { return value == null ? "" : "" + value; }
function unique_string_array(values) { return uniq(values); }
UCODE
    for name in array_contains object_keys_set tag_display_name regex_match_set tag_country_filter_matches \
        name_or_country_filter_configured urltest_matching_candidate_outbounds; do
        sed -n "/^function $name(/,/^}/p" "$ROOT_DIR/forkop/files/usr/lib/xrust/generator.uc"
    done
    cat <<'UCODE'
let names = { new: "Moscow #1", old: "Moscow #2" };
let metadata = { filterNames: { old: [ "Moscow #1" ] } };
function expect(tags, selection, expected) {
    let result = urltest_matching_candidate_outbounds(tags, names, {}, selection, [], [], metadata,
        false, "and", [], [], [], []);
    assert(sprintf("%J", result) == sprintf("%J", expected), "unexpected match: " + sprintf("%J", result));
}
expect(["new", "old"], ["Moscow #1"], ["new"]);
expect(["new", "old"], ["Moscow #2"], ["old"]);
expect(["old"], ["Moscow #1"], ["old"]);
expect(["new", "old"], ["Other"], []);
regex_matches = ["old"];
expect(["new", "old"], [], ["old"]);
regex_matches = [];
metadata.selectionBindings = { "Moscow #1": ["host-old"] };
expect(["new", "old"], ["Moscow #1"], ["old"]);
metadata.selectionBindings["Moscow #1"] = ["removed-host"];
expect(["new", "old"], ["Moscow #1"], []);
print("PASS: URLTest current names, selected identities and rename fallback\n");
UCODE
}
if [ "${1:-}" = --emit ]; then
    emit
else
    emit | ucode -
fi
