import type { Forkop } from '../../../types';
import { getMeta } from '../helpers/getMeta';

type DnsCheckState = 'error' | 'success' | 'warning';

export function getDnsCheckPresentation(data: Forkop.DnsCheckResult) {
  const dhcpManagedManually = Boolean(data.dont_touch_dhcp);
  // Keep Bootstrap DNS mandatory for an older backend that does not send this field.
  const bootstrapCheckRequired = data.bootstrap_dns_required !== 0;
  const checks = [Boolean(data.dns_on_router), Boolean(data.dns_status)];
  if (!dhcpManagedManually) checks.push(Boolean(data.dhcp_config_status));
  if (bootstrapCheckRequired) checks.push(Boolean(data.bootstrap_dns_status));

  const meta = getMeta({
    atLeastOneGood: checks.some(Boolean),
    allGood: checks.every(Boolean),
  });
  const state: DnsCheckState =
    dhcpManagedManually && meta.state === 'success' ? 'warning' : meta.state;
  const description =
    dhcpManagedManually && meta.state === 'success'
      ? _('Checks passed with manual DHCP')
      : meta.description;

  const dhcpItemState: DnsCheckState = dhcpManagedManually
    ? 'warning'
    : data.dhcp_config_status
      ? 'success'
      : 'error';
  const dhcpItemKey = dhcpManagedManually
    ? _('DHCP is managed manually')
    : _('DHCP has DNS server');

  return {
    state,
    description,
    dhcpItemState,
    dhcpItemKey,
  };
}
