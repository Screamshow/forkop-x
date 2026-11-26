import type { IDiagnosticsChecksItem } from '../../../services';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { RemoteFakeIPMethods, ForkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runNftCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.NFT;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  await Promise.all([
    RemoteFakeIPMethods.getFakeIpCheck(),
    RemoteFakeIPMethods.getIpCheck(),
  ]);

  const nftablesChecks = await ForkopShellMethods.checkNftRules();

  if (!nftablesChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Nftables checks failed');
  }

  const data = nftablesChecks.data;

  const rules = [
    [
      data.rules_mangle_exist,
      data.rules_mangle_counters,
      _('Rules mangle exist'),
      _('Rules mangle counters'),
    ],
    [
      data.rules_mangle_output_exist,
      data.rules_mangle_output_counters,
      _('Rules mangle output exist'),
      _('Rules mangle output counters'),
    ],
    [
      data.rules_proxy_exist,
      data.rules_proxy_counters,
      _('Rules proxy exist'),
      _('Rules proxy counters'),
    ],
  ] as const;
  const atLeastOneGood = Boolean(data.table_exist);
  const allGood =
    atLeastOneGood &&
    rules.every(([exists, counters]) => exists && counters) &&
    !data.rules_other_mark_exist;
  const { state, description } = getMeta({ atLeastOneGood, allGood });

  const items: IDiagnosticsChecksItem[] = [
    {
      state: data.table_exist ? 'success' : 'error',
      key: _('Table exist'),
      value: '',
    },
  ];
  if (data.table_exist) {
    for (const [exists, counters, ruleKey, counterKey] of rules) {
      items.push({
        state: exists ? 'success' : 'error',
        key: ruleKey,
        value: '',
      });
      if (exists) {
        items.push({
          state: counters ? 'success' : 'warning',
          key: counterKey,
          value: '',
        });
      }
    }
  }
  items.push({
    state: data.rules_other_mark_exist ? 'warning' : 'success',
    key: data.rules_other_mark_exist
      ? _('Additional marking rules found')
      : _('No other marking rules found'),
    value: '',
  });

  updateCheckStore({ order, code, title, description, state, items });

  if (!atLeastOneGood) {
    throw new Error('Nftables checks failed');
  }
}
