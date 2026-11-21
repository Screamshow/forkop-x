import { describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({ get: vi.fn(), set: vi.fn() }));
vi.mock('../../../../services', () => ({ store: mocks }));
import { updateCheckStore } from '../updateCheckStore';
import { DIAGNOSTICS_CHECKS } from '../contstants';

describe('diagnostic check store', () => {
  it('keeps the supplied Xrust labels and result values', () => {
    mocks.get.mockReturnValue({ diagnosticsChecks: [] });
    const check = {
      code: DIAGNOSTICS_CHECKS.XRUST,
      order: 2,
      title: 'Xrust checks',
      description: 'Problems detected',
      state: 'error' as const,
      items: [
        {
          key: 'Процесс Xrust запущен',
          state: 'error' as const,
          value: '/usr/bin/xrust',
        },
      ],
    };
    updateCheckStore(check);
    expect(mocks.set).toHaveBeenLastCalledWith({
      diagnosticsChecks: [check],
    });
    expect(check.title).toBe('Xrust checks');
    expect(check.items[0].key).toBe('Процесс Xrust запущен');
  });
});
