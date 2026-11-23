import { logger } from './logger.service';

type LogFetcher = () => Promise<string | undefined> | string | undefined;

interface ForkopLogWatcherOptions {
  intervalMs?: number;
  onNewLog?: (line: string) => void;
  maxTrackedLines?: number;
}

export class ForkopLogWatcher {
  private static instance: ForkopLogWatcher;
  private fetcher?: LogFetcher;
  private onNewLog?: (line: string) => void;
  private intervalMs = 5000;
  private lastLines = new Set<string>();
  private maxTrackedLines = 500;
  private timer?: ReturnType<typeof setInterval>;
  private running = false;
  private paused = false;
  private inFlight?: Promise<string | undefined>;
  private lastFetchAt = -Infinity;
  private text?: string;

  private constructor() {
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) this.pause();
        else this.resume();
      });
    }
  }

  static getInstance(): ForkopLogWatcher {
    if (!ForkopLogWatcher.instance) {
      ForkopLogWatcher.instance = new ForkopLogWatcher();
    }
    return ForkopLogWatcher.instance;
  }

  init(fetcher: LogFetcher, options?: ForkopLogWatcherOptions): void {
    this.fetcher = fetcher;
    this.onNewLog = options?.onNewLog;
    this.intervalMs = options?.intervalMs ?? 5000;
    this.maxTrackedLines = options?.maxTrackedLines ?? 500;
    this.lastLines = new Set();
    this.text = undefined;
    this.lastFetchAt = -Infinity;
    logger.info(
      '[ForkopLogWatcher]',
      `initialized (interval: ${this.intervalMs}ms)`,
    );
  }

  private normalizeLines(raw: string): string[] {
    return raw.split('\n').filter(Boolean).slice(-this.maxTrackedLines);
  }

  async checkOnce(minIntervalMs = 0): Promise<string | undefined> {
    if (this.inFlight) return this.inFlight;
    if (
      !this.fetcher ||
      this.paused ||
      (typeof document !== 'undefined' && document.hidden)
    )
      return this.text;

    const now = Date.now();
    if (now - this.lastFetchAt < minIntervalMs) return this.text;
    this.lastFetchAt = now;

    this.inFlight = Promise.resolve()
      .then(this.fetcher)
      .then((raw) => {
        if (raw === undefined) return this.text;
        const lines = this.normalizeLines(raw);
        this.text = lines.join('\n');

        for (const line of lines) {
          if (this.lastLines.has(line)) continue;
          this.lastLines.add(line);
          this.onNewLog?.(line);
        }
        if (this.lastLines.size > this.maxTrackedLines)
          this.lastLines = new Set(
            [...this.lastLines].slice(-this.maxTrackedLines),
          );
        return this.text;
      })
      .catch((error) => {
        logger.error('[ForkopLogWatcher]', 'failed to read logs:', error);
        return this.text;
      })
      .finally(() => {
        this.inFlight = undefined;
      });
    return this.inFlight;
  }

  start(): void {
    if (this.running) return;
    if (!this.fetcher) {
      logger.warn('[ForkopLogWatcher]', 'attempted to start without fetcher');
      return;
    }

    this.running = true;
    void this.readRecentLogs();
    this.timer = setInterval(() => void this.readRecentLogs(), this.intervalMs);
    logger.info(
      '[ForkopLogWatcher]',
      `started (interval: ${this.intervalMs}ms)`,
    );
  }

  stop(): void {
    if (!this.running) return;
    this.running = false;
    if (this.timer) clearInterval(this.timer);
    logger.info('[ForkopLogWatcher]', 'stopped');
  }

  pause(): void {
    if (!this.running || this.paused) return;
    this.paused = true;
    logger.info('[ForkopLogWatcher]', 'paused (tab not visible)');
  }

  resume(): void {
    if (!this.running || !this.paused) return;
    this.paused = false;
    logger.info('[ForkopLogWatcher]', 'resumed (tab active)');
    void this.readRecentLogs();
  }

  reset(): void {
    this.lastLines = new Set();
    this.text = undefined;
    this.lastFetchAt = -Infinity;
    logger.info('[ForkopLogWatcher]', 'log history reset');
  }

  readRecentLogs(): Promise<string | undefined> {
    return this.checkOnce(1000);
  }
}
