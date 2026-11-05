import { afterEach, describe, expect, it, vi } from 'vitest';
import { startDirectConnections } from './connectionsTransport';

function fixture() {
  vi.useFakeTimers();
  let data!: (message: string) => void;
  let error!: () => void;
  const cleanup = vi.fn();
  const options = {
    loadSecret: vi.fn().mockResolvedValue('secret'),
    subscribe: vi.fn((_secret, onData, onError) => {
      data = onData;
      error = onError;
      return cleanup;
    }),
    isCurrent: vi.fn(() => true),
    onData: vi.fn((message) => JSON.parse(message)),
    onFallback: vi.fn(),
  };
  return {
    options,
    cleanup,
    data: (message: string) => data(message),
    error: () => error(),
  };
}
afterEach(() => vi.useRealTimers());
describe('direct connections fallback', () => {
  it('falls back once on error and ignores delayed direct data', async () => {
    const f = fixture();
    startDirectConnections(f.options);
    await Promise.resolve();
    f.error();
    f.error();
    f.data('{}');
    expect(f.options.onFallback).toHaveBeenCalledTimes(1);
    expect(f.cleanup).toHaveBeenCalledTimes(1);
    expect(f.options.onData).not.toHaveBeenCalled();
  });
  it('bounds both connection setup and a silent established stream', async () => {
    const f = fixture();
    startDirectConnections(f.options);
    await Promise.resolve();
    vi.advanceTimersByTime(4000);
    f.data('{}');
    vi.advanceTimersByTime(4000);
    expect(f.options.onFallback).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1000);
    expect(f.options.onFallback).toHaveBeenCalledTimes(1);
  });
  it('falls back when secret retrieval hangs', () => {
    const f = fixture();
    f.options.loadSecret.mockReturnValue(new Promise(() => {}));
    startDirectConnections(f.options);
    vi.advanceTimersByTime(5000);
    expect(f.options.onFallback).toHaveBeenCalledOnce();
  });
  it('cleans up a synchronous socket construction failure', async () => {
    const f = fixture();
    f.options.subscribe.mockImplementation((_secret, _data, error) => {
      error();
      return f.cleanup;
    });
    startDirectConnections(f.options);
    await Promise.resolve();
    expect(f.cleanup).toHaveBeenCalledOnce();
    expect(f.options.onFallback).toHaveBeenCalledOnce();
  });
  it('cancels pending setup on unmount or service restart', async () => {
    const f = fixture();
    const stop = startDirectConnections(f.options);
    stop();
    await Promise.resolve();
    vi.advanceTimersByTime(10000);
    expect(f.options.subscribe).not.toHaveBeenCalled();
    expect(f.options.onFallback).not.toHaveBeenCalled();
  });
  it('rejects malformed messages and stale generations', async () => {
    const f = fixture();
    startDirectConnections(f.options);
    await Promise.resolve();
    f.data('bad');
    expect(f.options.onFallback).toHaveBeenCalledOnce();
    const g = fixture();
    startDirectConnections(g.options);
    await Promise.resolve();
    g.options.isCurrent.mockReturnValue(false);
    g.error();
    expect(g.options.onFallback).not.toHaveBeenCalled();
  });
});
