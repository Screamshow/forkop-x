export type DashboardMetrics = {
  up: number;
  down: number;
  uploadTotal: number;
  downloadTotal: number;
  connections: number;
  memory: number;
};

type Snapshot = {
  uploadTotal: number;
  downloadTotal: number;
  connections: unknown[];
  memory: number;
};

function isSnapshot(value: unknown): value is Snapshot {
  if (!value || typeof value !== 'object') return false;
  const data = value as Snapshot;
  return (
    Array.isArray(data.connections) &&
    [data.uploadTotal, data.downloadTotal, data.memory].every(
      (n) => typeof n === 'number' && Number.isFinite(n) && n >= 0,
    )
  );
}

// LuCI can reach the core locally even when a remote browser cannot reach 9090.
// Schedule after completion to keep slow RPC requests from overlapping.
export function pollDashboardMetrics(
  request: () => Promise<{ success: boolean; data?: unknown }>,
  onMetrics: (value: DashboardMetrics) => void,
  onError: () => void,
  isVisible: () => boolean = () => document.visibilityState !== 'hidden',
) {
  let stopped = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let previous: { up: number; down: number; at: number } | undefined;
  async function poll() {
    if (stopped) return;
    try {
      if (!isVisible()) {
        previous = undefined;
        return;
      }
      const response = await request();
      if (stopped) return;
      if (!response.success || !isSnapshot(response.data)) {
        throw new Error('Invalid core statistics');
      }
      const data = response.data;
      const now = performance.now();
      const elapsed = previous ? (now - previous.at) / 1000 : 0;
      const rate = (value: number, before?: number) =>
        elapsed > 0 && before != null && value >= before
          ? (value - before) / elapsed
          : 0;
      onMetrics({
        up: rate(data.uploadTotal, previous?.up),
        down: rate(data.downloadTotal, previous?.down),
        uploadTotal: data.uploadTotal,
        downloadTotal: data.downloadTotal,
        connections: data.connections.length,
        memory: data.memory,
      });
      previous = { up: data.uploadTotal, down: data.downloadTotal, at: now };
    } catch {
      previous = undefined;
      if (!stopped) onError();
    } finally {
      if (!stopped) timer = setTimeout(() => void poll(), 3000);
    }
  }
  void poll();
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}
