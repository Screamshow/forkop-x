import { describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  checkNftRules: vi.fn(),
  updateCheckStore: vi.fn(),
}));

vi.mock('../../../../methods', () => ({
  ForkopShellMethods: { checkNftRules: mocks.checkNftRules },
  RemoteFakeIPMethods: {
    getFakeIpCheck: vi.fn(),
    getIpCheck: vi.fn(),
  },
}));

vi.mock('../updateCheckStore', () => ({
  updateCheckStore: mocks.updateCheckStore,
}));

import { runNftCheck } from '../runNftCheck';

describe('runNftCheck', () => {
  it('reports a missing table without dependent chain errors', async () => {
    mocks.checkNftRules.mockResolvedValueOnce({
      success: true,
      data: { table_exist: 0, rules_other_mark_exist: 0 },
    });

    await expect(runNftCheck()).rejects.toThrow('Nftables checks failed');
    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'error',
        items: [
          { state: 'error', key: 'Table exist', value: '' },
          { state: 'success', key: 'No other marking rules found', value: '' },
        ],
      }),
    );
  });

  it('warns about an idle counter only when its chain exists', async () => {
    mocks.checkNftRules.mockResolvedValueOnce({
      success: true,
      data: {
        table_exist: 1,
        rules_mangle_exist: 0,
        rules_mangle_counters: 0,
        rules_mangle_output_exist: 1,
        rules_mangle_output_counters: 0,
        rules_proxy_exist: 1,
        rules_proxy_counters: 1,
        rules_other_mark_exist: 0,
      },
    });

    await runNftCheck();
    expect(mocks.updateCheckStore).toHaveBeenLastCalledWith(
      expect.objectContaining({
        state: 'warning',
        items: expect.arrayContaining([
          { state: 'error', key: 'Rules mangle exist', value: '' },
          { state: 'warning', key: 'Rules mangle output counters', value: '' },
        ]),
      }),
    );
  });
});
