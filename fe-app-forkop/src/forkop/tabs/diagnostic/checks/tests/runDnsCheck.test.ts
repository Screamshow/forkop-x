import { describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkDNSAvailable: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  ForkopShellMethods: { checkDNSAvailable: mocks.checkDNSAvailable },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

vi.mock(
  '../../../../../helpers',
  async () => import('../../../../../helpers/insertIf'),
);

import { runDnsCheck } from '../runDnsCheck';

describe('runDnsCheck', () => {
  it.each([
    { bootstrapDnsType: 'doh', expectedType: 'doh' },
    { bootstrapDnsType: undefined, expectedType: 'udp' },
  ])(
    'reports Bootstrap DNS as $expectedType',
    async ({ bootstrapDnsType, expectedType }) => {
      mocks.checkDNSAvailable.mockResolvedValueOnce({
        success: true,
        data: {
          dns_type: 'doh',
          dns_server: 'dns.google',
          dns_server_count: 1,
          dns_status: 1,
          dns_on_router: 1,
          bootstrap_dns_type: bootstrapDnsType,
          bootstrap_dns_server: '1.1.1.1',
          bootstrap_dns_server_index: 1,
          bootstrap_dns_server_count: 2,
          bootstrap_dns_status: 1,
          bootstrap_dns_required: 1,
          dhcp_config_status: 1,
        },
      });

      await runDnsCheck();

      expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
        expect.objectContaining({
          items: expect.arrayContaining([
            {
              key: 'Active Bootstrap DNS',
              state: 'success',
              value: `1.1.1.1 [${expectedType}] (2/2)`,
            },
          ]),
        }),
      );
    },
  );
});
