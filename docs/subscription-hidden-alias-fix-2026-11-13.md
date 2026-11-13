# Hidden alias expansion in URLTest and Priority

Local dev correction, installed in the existing OpenWrt 25 VMware preview at
192.168.1.1. No customer or operator router was changed and no release published.

`filter_selection.candidates()` previously retained hidden technical nodes without
their visibility flag. When a named node and a hidden `proxy-15` node shared a
connection identity, `reconcile()` expanded the selected name into both labels.
`finish()` then committed the expansion to UCI during subscription refresh or
startup cache preparation. LuCI retained and displayed those selected values.

The candidates now carry hidden status. Reconciliation chooses one visible name
per selected connection identity, preferring the existing visible selection.
Hidden records remain available for identity/tombstone evidence, but cannot
introduce technical labels. Already expanded visible/hidden duplicates collapse
back into the visible name on the next reconciliation, preserving private keys.
If only a hidden record remains, retain the old selected label and identity.
Do not drop nodes based on a `proxy-*` name pattern: that can be a legitimate
explicit name. Distinct connections/sources are never merged by label alone.

## Verification

- Before patch, synthetic named + hidden duplicates automatically expanded into
  `Helsinki #10, proxy-15`; the new regression fails on the original VM module.
- `tests/subscription_filter_aliases.uc`: 25 checks passed in a staged library
  and again against the installed module. Pure reconciliation cases plus actual
  isolated UCI include/exclude persistence for both URLTest and Priority, repair
  of existing duplicate values, repeated updates, preserved private bindings,
  hidden-only nodes, visible aliases, tombstones and distinct identities.
- Existing `tests/subscription_filter_selection.uc`: 45 checks passed against
  the staged candidate, including swaps, renames, address migrations, removal,
  legacy nested URLTest and Priority server_name.
- The persistence regression uses real UCI in an isolated configuration and save
  directory. The legacy text-state test adapter cannot represent multi-value
  UCI lists faithfully and is not used for the new list-persistence assertions.
- VM live Forkop UCI, DHCP and runtime config SHA-256 remained unchanged during
  deployment. Forkop stayed running; no core restart/reload was necessary.
- Original module, package/service state and hashes are kept privately in
  /root/forkop-filter-fix-20261113 on the VM. Only filter_selection.uc was installed.

This proves the code path, not that it was the sole cause on the customer's
screenshots. Their current private feed/bindings were not inspected in this task.
