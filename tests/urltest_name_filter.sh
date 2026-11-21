#!/bin/sh
# Run with ucode available, or pipe this script's --emit output into ucode on OpenWrt.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
emit() {
    cat <<'UCODE'
function array_or_empty(v) { return type(v) == 'array' ? v : []; }
function object_or_empty(v) { return type(v) == 'object' ? v : {}; }
function as_string(v) { return v == null ? '' : '' + v; }
let subscription_filter_connections = { new: 'host-new', old: 'host-old' };
UCODE
    for name in array_contains tag_display_name tag_name_filter_matches; do
        sed -n "/^function $name(/,/^}/p" "$ROOT_DIR/forkop/files/usr/lib/xrust/generator.uc"
    done
    cat <<'UCODE'
let names = { new: 'Moscow #1', old: 'Moscow #2' };
let metadata = { filterNames: { old: [ 'Moscow #1' ] } };
let current = { 'Moscow #1': true, 'Moscow #2': true };
assert(tag_name_filter_matches('new', names, ['Moscow #1'], {}, metadata, current), 'current owner must match');
assert(!tag_name_filter_matches('old', names, ['Moscow #1'], {}, metadata, current), 'reused alias must not match');
assert(tag_name_filter_matches('old', names, ['Moscow #2'], {}, metadata, current), 'renamed server remains selectable');
delete current['Moscow #1'];
assert(tag_name_filter_matches('old', names, ['Moscow #1'], {}, metadata, current), 'missing name must retain rename fallback');
current['Moscow #1'] = true;
assert(tag_name_filter_matches('old', names, [], { old: true }, metadata, current), 'regex matches remain independent');
assert(!tag_name_filter_matches('old', names, ['Other'], {}, metadata, current), 'unrelated name must not match');
metadata.selectionBindings = { 'Moscow #1': [ 'host-old' ] };
assert(!tag_name_filter_matches('new', names, ['Moscow #1'], {}, metadata, current), 'binding must reject a reused name');
assert(tag_name_filter_matches('old', names, ['Moscow #1'], {}, metadata, current), 'binding follows the selected connection');
metadata.selectionBindings['Moscow #1'] = [ 'removed-host' ];
assert(!tag_name_filter_matches('new', names, ['Moscow #1'], {}, metadata, current), 'removed host must not be replaced by current name owner');
print('PASS: URLTest current names and rename fallback\n');
UCODE
}
if [ "${1:-}" = --emit ]; then
    emit
else
    emit | ucode -
fi
