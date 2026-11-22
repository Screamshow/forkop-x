import { afterEach, describe, expect, it, vi } from 'vitest';
import { startDirectConnections } from './connectionsTransport';

function fixture() {
  vi.useFakeTimers();
  let data!: (message: string) => void;
  let error!: () => void;
  const cleanup = vi.fn();
  const options = {
    subscribe: vi.fn((onData, onError) => {
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
  it('falls back once on error and ignores delayed direct data', () => {
    const f = fixture();
    startDirectConnections(f.options);
    f.error();
    f.error();
    f.data('{}');
    expect(f.options.onFallback).toHaveBeenCalledTimes(1);
    expect(f.cleanup).toHaveBeenCalledTimes(1);
    expect(f.options.onData).not.toHaveBeenCalled();
  });
  it('bounds a silent established stream', () => {
    const f = fixture();
    startDirectConnections(f.options);
    vi.advanceTimersByTime(4000);
    f.data('{}');
    vi.advanceTimersByTime(4000);
    expect(f.options.onFallback).not.toHaveBeenCalled();
    vi.advanceTimersByTime(1000);
    expect(f.options.onFallback).toHaveBeenCalledTimes(1);
  });
  it('falls back when the socket never delivers an initial message', () => {
    const f = fixture();
    startDirectConnections(f.options);
    vi.advanceTimersByTime(5000);
    expect(f.options.onFallback).toHaveBeenCalledOnce();
  });
  it('cleans up a synchronous socket construction failure', () => {
    const f = fixture();
    f.options.subscribe.mockImplementation((_data, error) => {
      error();
      return f.cleanup;
    });
    startDirectConnections(f.options);
    expect(f.cleanup).toHaveBeenCalledOnce();
    expect(f.options.onFallback).toHaveBeenCalledOnce();
  });
  it('cleans up the socket on unmount or service restart', () => {
    const f = fixture();
    const stop = startDirectConnections(f.options);
    stop();
    vi.advanceTimersByTime(10000);
    expect(f.cleanup).toHaveBeenCalledOnce();
    expect(f.options.onFallback).not.toHaveBeenCalled();
  });
  it('rejects malformed messages and stale generations', () => {
    const f = fixture();
    startDirectConnections(f.options);
    f.data('bad');
    expect(f.options.onFallback).toHaveBeenCalledOnce();
    const g = fixture();
    startDirectConnections(g.options);
    g.options.isCurrent.mockReturnValue(false);
    g.error();
    expect(g.options.onFallback).not.toHaveBeenCalled();
  });
});
