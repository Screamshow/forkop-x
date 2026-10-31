import { afterEach, describe, expect, it, vi } from 'vitest';
import { pollDashboardMetrics } from './metricsPolling';

const snapshot = (uploadTotal = 100, downloadTotal = 200) => ({
  success: true,
  data: { uploadTotal, downloadTotal, connections: [{}, {}], memory: 4096 },
});

afterEach(() => vi.useRealTimers());

describe('dashboard metrics through LuCI', () => {
  it('updates all cards, calculates rates, and handles core counter resets', async () => {
    vi.useFakeTimers();
    const request = vi
      .fn()
      .mockResolvedValueOnce(snapshot())
      .mockResolvedValueOnce(snapshot(3100, 6200))
      .mockResolvedValueOnce(snapshot(10, 20));
    const update = vi.fn();
    const stop = pollDashboardMetrics(request, update, vi.fn(), () => true);
    await vi.advanceTimersByTimeAsync(0);
    expect(update).toHaveBeenLastCalledWith({
      up: 0,
      down: 0,
      uploadTotal: 100,
      downloadTotal: 200,
      connections: 2,
      memory: 4096,
    });
    await vi.advanceTimersByTimeAsync(3000);
    expect(update.mock.lastCall?.[0]).toMatchObject({ up: 1000, down: 2000 });
    await vi.advanceTimersByTimeAsync(3000);
    expect(update.mock.lastCall?.[0]).toMatchObject({ up: 0, down: 0 });
    stop();
    await vi.advanceTimersByTimeAsync(9000);
    expect(request).toHaveBeenCalledTimes(3);
  });

  it('does not overlap slow requests or update an unmounted dashboard', async () => {
    vi.useFakeTimers();
    let resolve!: (value: ReturnType<typeof snapshot>) => void;
    const request = vi.fn(
      () =>
        new Promise<ReturnType<typeof snapshot>>((r) => {
          resolve = r;
        }),
    );
    const update = vi.fn();
    const stop = pollDashboardMetrics(request, update, vi.fn(), () => true);
    await vi.advanceTimersByTimeAsync(15000);
    expect(request).toHaveBeenCalledTimes(1);
    stop();
    resolve(snapshot());
    await vi.advanceTimersByTimeAsync(5000);
    expect(update).not.toHaveBeenCalled();
    expect(request).toHaveBeenCalledTimes(1);
  });

  it('retries failures and skips hidden pages', async () => {
    vi.useFakeTimers();
    const request = vi
      .fn()
      .mockResolvedValueOnce({ success: false })
      .mockResolvedValue(snapshot());
    const update = vi.fn(),
      error = vi.fn();
    let visible = true;
    const stop = pollDashboardMetrics(request, update, error, () => visible);
    await vi.advanceTimersByTimeAsync(0);
    expect(error).toHaveBeenCalledTimes(1);
    visible = false;
    await vi.advanceTimersByTimeAsync(3000);
    expect(request).toHaveBeenCalledTimes(1);
    visible = true;
    await vi.advanceTimersByTimeAsync(3000);
    expect(update.mock.lastCall?.[0]).toMatchObject({ up: 0, down: 0 });
    stop();
  });
});
