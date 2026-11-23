import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { waitForRemovalStatus } from '../fullUninstall';

vi.mock('../../../../helpers', () => ({ executeShellCommand: vi.fn() }));
vi.mock('../../../../icons', () => ({ renderXIcon24: vi.fn() }));
vi.mock('../../../../partials', () => ({ renderButton: vi.fn() }));

const statusUrl = '/forkop-uninstall.k9.json';

beforeEach(() => vi.useFakeTimers());
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it.each(['headers', 'body'] as const)(
  'aborts a status request stalled on %s within the removal deadline',
  async (stalledPhase) => {
    let signal: AbortSignal | undefined;
    const fetch = vi.fn((url: string, options: RequestInit) => {
      expect(url).toBe(statusUrl);
      signal = options.signal ?? undefined;
      const pending = () =>
        new Promise((_, reject) => {
          signal?.addEventListener('abort', () => reject(signal?.reason));
        });
      if (stalledPhase === 'headers') return pending();
      return Promise.resolve({ ok: true, json: pending });
    });
    vi.stubGlobal('fetch', fetch);
    const status = waitForRemovalStatus(statusUrl);
    await vi.advanceTimersByTimeAsync(179999);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(signal?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await expect(status).resolves.toBeNull();
    expect(signal?.aborted).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  },
);

it('retries a transient error and returns the terminal preflight failure', async () => {
  const failure = { state: 'failed', phase: 'preflight' };
  vi.stubGlobal(
    'fetch',
    vi
      .fn()
      .mockRejectedValueOnce(new Error('restarting LuCI'))
      .mockResolvedValueOnce({ ok: true, json: async () => failure }),
  );
  const status = waitForRemovalStatus(statusUrl);
  await vi.advanceTimersByTimeAsync(3000);
  await expect(status).resolves.toEqual(failure);
  expect(vi.getTimerCount()).toBe(0);
});
