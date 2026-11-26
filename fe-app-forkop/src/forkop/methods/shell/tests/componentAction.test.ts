import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  executeShellCommand: vi.fn(),
  fsRead: vi.fn(),
}));

vi.mock('../../../../helpers', () => ({
  executeShellCommand: mocks.executeShellCommand,
}));

import { ForkopShellMethods } from '../index';

describe('ForkopShellMethods.componentAction', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mocks.executeShellCommand.mockReset();
    mocks.fsRead.mockReset();
    vi.stubGlobal('fs', {
      read: mocks.fsRead,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('waits for a definitive router result when the status RPC disappears during an update', async () => {
    mocks.fsRead.mockRejectedValue(new Error('State unavailable'));
    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'get_ui_state') {
        return {
          stdout: JSON.stringify({
            service: { forkop: { running: 1, status: 'running & enabled' } },
            actions: { component: [] },
          }),
          code: 0,
        };
      }
      if (args[0] === 'show_version') {
        return { stdout: '3.0.0', code: 0 };
      }
      return { stdout: '', stderr: 'Unknown command', code: 1 };
    });

    const completed = vi.fn();
    const waiting = ForkopShellMethods.waitComponentActionJob('job-lost');
    void waiting.then(completed);

    await vi.advanceTimersByTimeAsync(33000);
    expect(completed).not.toHaveBeenCalled();
    expect(
      mocks.executeShellCommand.mock.calls.some(
        ([call]) => call.args[0] === 'show_version',
      ),
    ).toBe(false);

    await vi.advanceTimersByTimeAsync(30000);
    await expect(waiting).resolves.toEqual({
      success: false,
      error: 'Unknown command',
    });
  });

  it('reads a terminal rollback result from the router after the browser resumes', async () => {
    mocks.fsRead.mockRejectedValue(new Error('RPC unavailable'));
    const result = {
      job_id: 'job-update',
      component: 'forkop',
      action: 'install',
      running: false,
      success: false,
      message: 'Previous version restored',
    };
    mocks.executeShellCommand.mockImplementation(({ args }) => ({
      stdout:
        args[0] === 'get_ui_state'
          ? JSON.stringify({
              actions: { component: [result] },
            })
          : '',
      stderr: args[0] === 'get_ui_state' ? '' : 'No related RPC reply',
      code: args[0] === 'get_ui_state' ? 0 : 1,
    }));

    const waiting = ForkopShellMethods.waitComponentActionJob('job-update');
    vi.setSystemTime(Date.now() + 30 * 60 * 1000);
    await vi.advanceTimersByTimeAsync(1500);

    await expect(waiting).resolves.toEqual({ success: true, data: result });
  });

  it('passes an exact release to the background worker without changing default updates', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({ success: true, job_id: 'job-1' }),
      code: 0,
    });
    await ForkopShellMethods.componentActionStart(
      'forkop',
      'install',
      '1.14.6',
    );
    expect(mocks.executeShellCommand.mock.calls[0][0].args).toEqual([
      'component_action_async',
      'forkop',
      'install',
      '1.14.6',
    ]);
    await ForkopShellMethods.componentActionStart('forkop', 'install');
    expect(mocks.executeShellCommand.mock.calls[1][0].args).toEqual([
      'component_action_async',
      'forkop',
      'install',
    ]);
  });

  it('returns the backend component action start error message', async () => {
    mocks.executeShellCommand.mockResolvedValue({
      stdout: JSON.stringify({
        success: false,
        message: 'Another component action is already running',
      }),
      stderr: '',
      code: 1,
    });

    await expect(
      ForkopShellMethods.componentActionStart('forkop', 'install'),
    ).resolves.toEqual({
      success: false,
      error: 'Another component action is already running',
    });
  });

  it('keeps following a component job after the former browser-side wait timeout while the backend reports it running', async () => {
    let stateReads = 0;

    mocks.fsRead.mockImplementation(() =>
      Promise.resolve(
        JSON.stringify(
          stateReads++ < 621
            ? {
                success: true,
                running: true,
                component: 'forkop',
                action: 'check_update',
                message: 'Component action is running',
                job_id: 'job-1',
              }
            : {
                success: true,
                running: false,
                component: 'forkop',
                action: 'check_update',
                message: 'Forkop X is up to date',
                current_version: '3.0.0',
                latest_version: '3.0.0',
                changed: false,
                status: 'latest',
              },
        ),
      ),
    );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: JSON.stringify({
            success: true,
            running: true,
            component: 'forkop',
            action: 'check_update',
            message: 'Component action is running',
            job_id: 'job-1',
          }),
          stderr: '',
          code: 0,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = ForkopShellMethods.waitComponentActionJob('job-1');

    await vi.advanceTimersByTimeAsync(16 * 60 * 1000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'forkop',
        action: 'check_update',
        message: 'Forkop X is up to date',
        current_version: '3.0.0',
        latest_version: '3.0.0',
        changed: false,
        status: 'latest',
      },
    });
  });

  it('keeps waiting when status polling briefly fails but UI state still reports the job running', async () => {
    mocks.fsRead
      .mockRejectedValueOnce(new Error('State is temporarily unavailable'))
      .mockResolvedValueOnce(
        JSON.stringify({
          success: true,
          running: false,
          component: 'forkop',
          action: 'install',
          message: 'Forkop X has been installed',
          current_version: '3.0.0',
          latest_version: '3.0.0',
          changed: true,
          status: 'latest',
        }),
      );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'Component action job was not found',
          code: 1,
        });
      }

      if (args[0] === 'get_ui_state') {
        return Promise.resolve({
          stdout: JSON.stringify({
            service: {
              forkop: {
                running: 0,
                enabled: 1,
                status: 'stopped but enabled',
                dns_configured: 0,
              },
              xrust: {
                running: 0,
                enabled: 1,
                status: 'stopped but enabled',
              },
            },
            capabilities: {
              xrust_tailscale: 0,
            },
            actions: {
              service: [],
              latency: [],
              component: [
                {
                  success: true,
                  running: true,
                  component: 'forkop',
                  action: 'install',
                  message: 'Component action is running',
                  job_id: 'job-1',
                },
              ],
              subscription: [],
            },
          }),
          stderr: '',
          code: 0,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = ForkopShellMethods.waitComponentActionJob('job-1');

    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'forkop',
        action: 'install',
        message: 'Forkop X has been installed',
        current_version: '3.0.0',
        latest_version: '3.0.0',
        changed: true,
        status: 'latest',
      },
    });
    expect(mocks.executeShellCommand).toHaveBeenCalledWith({
      command: '/usr/bin/forkop',
      args: ['get_ui_state'],
      timeout: 3000,
    });
  });

  it('keeps waiting through a transient RPC reply loss until the action state settles', async () => {
    mocks.fsRead
      .mockRejectedValueOnce(new Error('State is temporarily unavailable'))
      .mockResolvedValueOnce(
        JSON.stringify({
          success: true,
          running: false,
          component: 'forkop',
          action: 'check_update',
          message: 'Forkop X is up to date',
          current_version: '70.2',
          latest_version: '70.2',
          changed: false,
          status: 'latest',
        }),
      );

    mocks.executeShellCommand.mockImplementation(({ args }) => {
      if (args[0] === 'component_action_status') {
        return Promise.resolve({
          stdout: '',
          stderr: 'No related RPC reply',
          code: 1,
        });
      }

      if (args[0] === 'get_ui_state') {
        return Promise.resolve({
          stdout: '',
          stderr: 'No related RPC reply',
          code: 1,
        });
      }

      return Promise.resolve({
        stdout: '',
        stderr: 'Unexpected command',
        code: 1,
      });
    });

    const responsePromise = ForkopShellMethods.waitComponentActionJob('job-1');

    await vi.advanceTimersByTimeAsync(3000);

    await expect(responsePromise).resolves.toEqual({
      success: true,
      data: {
        success: true,
        running: false,
        component: 'forkop',
        action: 'check_update',
        message: 'Forkop X is up to date',
        current_version: '70.2',
        latest_version: '70.2',
        changed: false,
        status: 'latest',
      },
    });
  });
});
