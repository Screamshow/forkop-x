import { describe, expect, it, vi } from 'vitest';
import { completeComponentActionJob } from '../initController';
import { markUiActionOwned } from '../../../services/uiActionNotification.service';
import { showToast } from '../../../../helpers/showToast';
import { ForkopShellMethods } from '../../../methods';

vi.hoisted(() => vi.stubGlobal('__FORKOP_RUSSIAN__', '{}'));
vi.mock('../../../../helpers/showToast', () => ({ showToast: vi.fn() }));
vi.mock('../../../services/tab.service', () => ({ TabServiceInstance: {} }));

it('notifies a terminal component failure after recovering from a dropped status request', async () => {
  const jobId = 'component-after-disconnect';
  const ack = vi
    .spyOn(ForkopShellMethods, 'uiActionAck')
    .mockResolvedValue({
      success: true,
      data: { success: true, job_id: jobId, message: '' },
    });
  try {
    markUiActionOwned('component', jobId);
    await completeComponentActionJob('forkopInstall', jobId, {
      success: false,
      error: 'No related RPC reply',
    });
    expect(ack).not.toHaveBeenCalled();
    expect(showToast).not.toHaveBeenCalled();
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
    expect(ack).toHaveBeenCalledWith('component', jobId);
    expect(showToast).toHaveBeenCalledExactlyOnceWith(
      'installation failed',
      'error',
    );
  } finally {
    ack.mockRestore();
  }
});

import { shouldApplyCompletedComponentActionResult } from '../componentActionCompletion';

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
