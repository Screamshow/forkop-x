// A silent or broken direct API must not prevent same-origin LuCI polling.
export function startDirectConnections(options: {
  loadSecret: () => Promise<string>;
  subscribe: (
    secret: string,
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
  arm();
  void options
    .loadSecret()
    .then((secret) => {
      if (stopped || !options.isCurrent()) return;
      const cleanup = options.subscribe(
        secret,
        (message) => {
          if (stopped || !options.isCurrent()) return;
          try {
            options.onData(message);
            arm();
          } catch (_error) {
            fallback();
          }
        },
        fallback,
      );
      // subscribe can synchronously report a construction failure.
      if (stopped) cleanup();
      else unsubscribe = cleanup;
    })
    .catch(fallback);
  return stop;
}
