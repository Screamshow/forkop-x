import { afterEach, describe, expect, it, vi } from 'vitest';
import { completeComponentActionJob } from '../initController';
import { markUiActionOwned } from '../../../services/uiActionNotification.service';
import { showToast } from '../../../../helpers/showToast';
import { ForkopShellMethods } from '../../../methods';
import { store } from '../../../services/store.service';

vi.hoisted(() => vi.stubGlobal('__FORKOP_RUSSIAN__', '{}'));
vi.mock('../../../../helpers/showToast', () => ({ showToast: vi.fn() }));
vi.mock('../../../services/tab.service', () => ({ TabServiceInstance: {} }));

afterEach(() => vi.unstubAllGlobals());

it('recovers from an unavailable update result and keeps the confirmed failure readable', async () => {
  const jobId = 'component-after-disconnect';
  const status = { textContent: '', hidden: true };
  vi.stubGlobal('document', { getElementById: () => status });
  const ack = vi.spyOn(ForkopShellMethods, 'uiActionAck').mockResolvedValue({
    success: true,
    data: { success: true, job_id: jobId, message: '' },
  });
  try {
    markUiActionOwned('component', jobId);
    await completeComponentActionJob('forkopInstall', jobId, {
      success: false,
      error: 'Component action job was not found',
    });
    expect(ack).not.toHaveBeenCalled();
    expect(showToast).not.toHaveBeenCalled();
    expect(status.textContent).toBe('Could not confirm completion');
    await completeComponentActionJob('forkopInstall', jobId, {
      success: true,
      data: {
        success: false,
        running: false,
        component: 'forkop',
        action: 'install',
        changed: false,
        current_version: '',
        latest_version: '',
        message: 'installation failed',
      },
    });
    expect(ack).not.toHaveBeenCalled();
    expect(status.textContent).toBe(
      'Forkop X installation failed · installation failed',
    );
    expect(showToast).toHaveBeenCalledExactlyOnceWith(
      'installation failed',
      'error',
    );
  } finally {
    ack.mockRestore();
  }
});

import {
  getLatestForkopInstall,
  shouldApplyCompletedComponentActionResult,
} from '../componentActionCompletion';
import type { Forkop } from '../../../types';

it('restores the newest Forkop installation status and ignores newer check jobs', () => {
  const previous: Forkop.ComponentActionResult = {
    component: 'forkop',
    action: 'install',
    message: '',
    current_version: '3.0.7',
    latest_version: '3.0.7',
    success: true,
    changed: true,
    running: false,
    started_at: 1,
    updated_at: 3,
  };
  const current = { ...previous, started_at: 2, running: true };
  expect(
    getLatestForkopInstall([
      current,
      { ...previous, action: 'check_update', started_at: 4 },
      previous,
    ]),
  ).toBe(current);
});

it('clears the cached release comparison after installing an older Forkop version', async () => {
  vi.stubGlobal('document', { getElementById: () => null });
  store.set({
    updatesChecks: {
      ...store.get().updatesChecks,
      forkop: { status: 'latest', latest_version: '3.0.7', release_url: '' },
    },
  });
  markUiActionOwned('component', 'forkop-downgrade');
  await completeComponentActionJob('forkopInstall', 'forkop-downgrade', {
    success: true,
    data: {
      component: 'forkop',
      action: 'install',
      running: false,
      success: true,
      changed: false,
      current_version: '3.0.6',
      latest_version: '3.0.6',
      message: 'Forkop has been installed',
    },
  });
  expect(store.get().updatesChecks.forkop.status).toBeNull();
});

describe('shouldApplyCompletedComponentActionResult', () => {
  it('does not restore completed check results that were already handled before reload', () => {
    expect(
      shouldApplyCompletedComponentActionResult(
        { action: 'check_update' },
        false,
      ),
    ).toBe(false);
  });

  it('applies completed check results when this UI still owns the pending notification', () => {
    expect(
      shouldApplyCompletedComponentActionResult(
        { action: 'check_update' },
        true,
      ),
    ).toBe(true);
  });

  it('always applies completed mutating actions because they reflect real system state', () => {
    expect(
      shouldApplyCompletedComponentActionResult({ action: 'install' }, false),
    ).toBe(true);
    expect(
      shouldApplyCompletedComponentActionResult({ action: 'remove' }, false),
    ).toBe(true);
  });
});
