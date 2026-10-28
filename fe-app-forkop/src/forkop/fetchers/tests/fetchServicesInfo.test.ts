import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
}));

vi.mock('../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { store } from '../../services/store.service';
import { fetchServicesInfo } from '../fetchServicesInfo';

describe('fetchServicesInfo', () => {
  beforeEach(() => {
    store.reset();
    mocks.executeShellCommand.mockReset();
  });

  it('returns the fast UI state after applying it to the shared store', async () => {
    const uiState = {
      service: {
        forkop: {
          running: 1,
          enabled: 1,
          status: 'restarting',
          memory_rss_bytes: 3145728,
          dns_configured: 1,
          restart_blocked: 1,
        },
        sing_box: {
          running: 1,
          enabled: 0,
          status: 'running but disabled',
          memory_rss_bytes: 41943040,
        },
      },
      capabilities: {
        sing_box_extended: 1,
        sing_box_tiny: 0,
        sing_box_tailscale: 1,
      },
      actions: {
        service: [
          {
            success: true,
            running: true,
            kind: 'service',
            action: 'restart',
            job_id: 'service-1',
          },
        ],
        latency: [],
        component: [],
        subscription: [],
      },
    };

    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify(uiState),
      stderr: '',
      code: 0,
    });

    await expect(fetchServicesInfo()).resolves.toEqual(uiState);

    const state = store.get();

    expect(state.servicesInfoWidget.data.forkopStatus).toBe('restarting');
    expect(state.servicesInfoWidget.data.restartBlocked).toBe(1);
    expect(state.servicesInfoWidget.data.forkopMemoryBytes).toBe(3145728);
    expect(state.servicesInfoWidget.data.singboxMemoryBytes).toBe(41943040);
    expect(state.diagnosticsActions.restart.loading).toBe(true);
  });

  it('keeps the previous service state when the fallback status fetch fails', async () => {
    store.set({
      servicesInfoWidget: {
        loading: false,
        failed: false,
        data: {
          singbox: 1,
          forkopRunning: 1,
          stopAvailable: 1,
          restartBlocked: 1,
          forkopEnabled: 1,
          forkopStatus: 'running & enabled',
        },
      },
    });

    mocks.executeShellCommand
      .mockResolvedValueOnce({
        stdout: '',
        stderr: 'get_ui_state failed',
        code: 1,
      })
      .mockResolvedValueOnce({
        stdout: '',
        stderr: 'get_status failed',
        code: 1,
      })
      .mockResolvedValueOnce({
        stdout: JSON.stringify({
          running: 0,
          enabled: 0,
          status: 'stopped but disabled',
        }),
        stderr: '',
        code: 0,
      });

    await fetchServicesInfo();

    const state = store.get();

    expect(state.servicesInfoWidget.failed).toBe(true);
    expect(state.servicesInfoWidget.data).toEqual({
      singbox: 0,
      forkopRunning: 1,
      stopAvailable: 1,
      restartBlocked: 1,
      forkopEnabled: 1,
      forkopStatus: 'running & enabled',
    });
  });
});
