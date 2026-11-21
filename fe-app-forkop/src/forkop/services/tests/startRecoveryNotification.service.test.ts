import { describe, expect, it, vi } from 'vitest';

import { StartRecoveryNotificationController } from '../startRecoveryNotification.service';

describe('StartRecoveryNotificationController', () => {
  it('passes controlled stop failures through and emits a startup failure without a retry', () => {
    vi.useFakeTimers();
    try {
      const emit = vi.fn();
      const controller = new StartRecoveryNotificationController(emit);
      expect(
        controller.handle(
          'forkop: [fatal] Controlled Xrust transition refused: ownership is ambiguous before stop',
        ),
      ).toBe(false);
      const line =
        'forkop: [fatal] Controlled Xrust transition refused: unexpected Xrust exists before start';
      expect(controller.handle(line)).toBe(true);
      expect(emit).not.toHaveBeenCalled();
      vi.runAllTimers();
      expect(emit).toHaveBeenCalledExactlyOnceWith({ kind: 'error', line });
    } finally {
      vi.useRealTimers();
    }
  });

  it('replaces the transient controlled-transition fatal with a recovery warning and success', () => {
    const emit = vi.fn();
    const controller = new StartRecoveryNotificationController(emit);

    expect(
      controller.handle(
        'forkop: [fatal] Controlled xrust transition refused: unexpected xrust exists before start',
      ),
    ).toBe(true);
    expect(
      controller.handle(
        'forkop: [fatal] xrust did not reach a stable running state after start. Aborted.',
      ),
    ).toBe(true);
    expect(
      controller.handle(
        'forkop: [warn] Forkop start failed; scheduled an automatic retry',
      ),
    ).toBe(true);
    expect(emit).toHaveBeenCalledWith({
      kind: 'start-recovery-pending',
      line: 'forkop: [warn] Forkop start failed; scheduled an automatic retry',
    });

    expect(
      controller.handle(
        'forkop: [info] Forkop recovered automatically after a failed start',
      ),
    ).toBe(true);
    expect(emit).toHaveBeenLastCalledWith({
      kind: 'start-recovery-succeeded',
      line: 'forkop: [info] Forkop recovered automatically after a failed start',
    });
  });

  it('keeps a failed automatic recovery red without replaying its transient fatal', () => {
    const emit = vi.fn();
    const controller = new StartRecoveryNotificationController(emit);

    controller.handle(
      'forkop: [fatal] Controlled xrust transition refused: unexpected xrust exists before start',
    );
    expect(
      controller.handle(
        'forkop: [error] Forkop automatic recovery attempt failed; see the preceding startup logs',
      ),
    ).toBe(false);
    expect(emit).not.toHaveBeenCalled();
  });
});
