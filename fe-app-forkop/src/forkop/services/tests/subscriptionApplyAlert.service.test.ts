import { afterEach, describe, expect, it, vi } from 'vitest';
import { subscriptionApplyAlert } from '../subscriptionApplyAlert.service';

afterEach(() => vi.unstubAllGlobals());

describe('subscription apply alert', () => {
  it('distinguishes a working rollback from failed recovery without an intervention instruction', () => {
    vi.stubGlobal('_', (value: string) => value);
    expect(subscriptionApplyAlert(null)).toBeNull();
    const previous = subscriptionApplyAlert({
      state: 'previous',
      section: 'Proxy',
      reason: 'hot_apply_failed',
    });
    expect(previous?.message).toContain(
      'previous working configuration is still active',
    );
    expect(previous?.message).toContain('Proxy');
    const failed = subscriptionApplyAlert({
      state: 'recovery_failed',
      section: 'Proxy',
      reason: 'rollback_failed',
    });
    expect(failed?.title).toContain('recovery failed');
    expect(failed?.message).not.toContain('still active');
    expect(failed?.message).not.toMatch(/intervention|required action/i);
  });
});
