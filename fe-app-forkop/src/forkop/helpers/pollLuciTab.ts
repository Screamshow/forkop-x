export function pollLuciTab(
  element: HTMLElement,
  refresh: (isVisible: () => boolean) => Promise<unknown>,
  intervalMs: number,
  firstDelayMs = 0,
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let polling = false;
  let observer: MutationObserver | undefined;
  let pane: Element | null | undefined;
  let stopped = false;

  const visible = () =>
    !stopped &&
    element.isConnected &&
    !document.hidden &&
    (!pane || pane.getAttribute('data-tab-active') === 'true');

  const stop = () => {
    stopped = true;
    clearTimeout(timer);
    observer?.disconnect();
    document.removeEventListener?.('visibilitychange', update);
    window.removeEventListener?.('pagehide', stop);
  };

  async function run() {
    timer = undefined;
    if (!element.isConnected) return stop();
    if (!visible()) return;
    polling = true;
    try {
      await refresh(visible);
    } finally {
      polling = false;
      if (visible()) timer = setTimeout(() => void run(), intervalMs);
    }
  }

  function update() {
    if (!element.isConnected) return stop();
    if (!visible()) {
      clearTimeout(timer);
      timer = undefined;
    } else if (!timer && !polling) {
      void run();
    }
  }

  timer = setTimeout(() => {
    timer = undefined;
    if (!element.isConnected) return stop();
    pane = element.closest?.('[data-tab]');
    if (pane && typeof MutationObserver !== 'undefined') {
      observer = new MutationObserver(update);
      observer.observe(pane, {
        attributes: true,
        attributeFilter: ['data-tab-active'],
      });
    }
    document.addEventListener?.('visibilitychange', update);
    window.addEventListener('pagehide', stop, { once: true });
    update();
  }, firstDelayMs);
  return stop;
}
