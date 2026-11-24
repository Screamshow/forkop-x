/// <reference types="vite/client" />
import { afterEach, describe, expect, it, vi } from 'vitest';
import russian from '../../../../../luci-app-forkop/po/ru/forkop.po?raw';
import { readTranslations } from '../../../../scripts/read-translations';
import { subscriptionApplyAlert } from '../subscriptionApplyAlert.service';

afterEach(() => vi.unstubAllGlobals());

describe('subscription apply alert', () => {
  it('warns about pending offline persistence in Russian until the error clears', () => {
    const translations = readTranslations(russian);
    vi.stubGlobal('_', (value: string) => translations[value] || value);
    expect(
      subscriptionApplyAlert({
        state: 'applied',
        reason: 'cache_persistence_failed',
        section: 'Proxy',
      }),
    ).toEqual({
      severity: 'warning',
      title: 'Обновление подписки обработано',
      message:
        'Раздел: Proxy. Кэш для работы без интернета пока не сохранён. Forkop повторит попытку сохранения.',
    });
    expect(subscriptionApplyAlert(null)).toBeNull();
  });
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
