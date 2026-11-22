import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods } from '../../../methods';
import type { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getDnsCheckPresentation } from './getDnsCheckPresentation';

export async function runDnsCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.DNS;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const dnsChecks = await ForkopShellMethods.checkDNSAvailable();

  if (!dnsChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('DNS checks failed');
  }

  const data = dnsChecks.data;
  const bootstrapAddress = `${data.bootstrap_dns_server} [${data.bootstrap_dns_type ?? 'udp'}]`;
  const { state, description, dhcpItemState, dhcpItemKey } =
    getDnsCheckPresentation(data);

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      ...insertIf<IDiagnosticsChecksItem>(
        data.bootstrap_dns_required !== 0 &&
          (data.dns_type === 'doh' ||
            data.dns_type === 'dot' ||
            data.bootstrap_dns_server_count > 1 ||
            !data.bootstrap_dns_status),
        [
          {
            state: data.bootstrap_dns_status ? 'success' : 'error',
            key:
              data.bootstrap_dns_server_count > 1
                ? _('Active Bootstrap DNS')
                : _('Bootstrap DNS'),
            value:
              data.bootstrap_dns_server_count > 1
                ? `${bootstrapAddress} (${data.bootstrap_dns_server_index + 1}/${data.bootstrap_dns_server_count})`
                : bootstrapAddress,
          },
        ],
      ),
      {
        state: data.dns_status ? 'success' : 'error',
        key: data.dns_server_count > 1 ? _('Active Main DNS') : _('Main DNS'),
        value:
          data.dns_server_count > 1
            ? `${data.dns_server} [${data.dns_type}] (${data.dns_server_index + 1}/${data.dns_server_count})`
            : `${data.dns_server} [${data.dns_type}]`,
      },
      {
        state: data.dns_on_router ? 'success' : 'error',
        key: _('DNS on router'),
        value: '',
      },
      {
        state: dhcpItemState,
        key: dhcpItemKey,
        value: '',
      },
    ],
  });

  if (state === 'error') {
    throw new Error('DNS checks failed');
  }
}
