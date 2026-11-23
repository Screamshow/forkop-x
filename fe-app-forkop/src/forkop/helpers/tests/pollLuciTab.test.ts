import { afterEach, expect, it, vi } from 'vitest';
import { pollLuciTab } from '../pollLuciTab';

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

it('does no background work and resumes immediately when the tab returns', async () => {
  vi.useFakeTimers();
  const document = new EventTarget() as EventTarget & { hidden: boolean };
  document.hidden = false;
  vi.stubGlobal('document', document);
  vi.stubGlobal('window', new EventTarget());
  let updatePane = () => {};
  vi.stubGlobal(
    'MutationObserver',
    class {
      constructor(update: () => void) {
        updatePane = update;
      }
      observe() {}
      disconnect() {}
    },
  );
  let active = false;
  const pane = { getAttribute: () => (active ? 'true' : null) };
  const element = {
    isConnected: true,
    closest: () => pane,
  } as unknown as HTMLElement;
  const refresh = vi.fn(async () => {});
  const stop = pollLuciTab(element, refresh, 3000);
  await vi.advanceTimersByTimeAsync(12000);
  expect(refresh).not.toHaveBeenCalled();
  active = true;
  updatePane();
  expect(refresh).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(3000);
  expect(refresh).toHaveBeenCalledTimes(2);

  document.hidden = true;
  document.dispatchEvent(new Event('visibilitychange'));
  await vi.advanceTimersByTimeAsync(12000);
  expect(refresh).toHaveBeenCalledTimes(2);
  document.hidden = false;
  document.dispatchEvent(new Event('visibilitychange'));
  expect(refresh).toHaveBeenCalledTimes(3);
  stop();
});
