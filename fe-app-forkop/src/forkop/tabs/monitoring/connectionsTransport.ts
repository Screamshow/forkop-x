// A silent or broken direct API must not prevent same-origin LuCI polling.
export function startDirectConnections(options: {
  subscribe: (
    onData: (message: string) => void,
    onError: () => void,
  ) => () => void;
  isCurrent: () => boolean;
  onData: (message: string) => void;
  onFallback: () => void;
}) {
  let stopped = false;
  let unsubscribe: (() => void) | undefined;
  let timer: ReturnType<typeof setTimeout>;
  const stop = () => {
    stopped = true;
    clearTimeout(timer);
    unsubscribe?.();
    unsubscribe = undefined;
  };
  const fallback = () => {
    if (stopped) return;
    const current = options.isCurrent();
    stop();
    if (current) options.onFallback();
  };
  const arm = () => {
    clearTimeout(timer);
    timer = setTimeout(fallback, 5000);
  };
  if (!options.isCurrent()) return stop;
  arm();
  try {
    const cleanup = options.subscribe((message) => {
      if (stopped || !options.isCurrent()) return;
      try {
        options.onData(message);
        arm();
      } catch (_error) {
        fallback();
      }
    }, fallback);
    // subscribe can synchronously report a construction failure.
    if (stopped) cleanup();
    else unsubscribe = cleanup;
  } catch (_error) {
    fallback();
  }
  return stop;
}
