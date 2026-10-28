const LOG_NOTIFICATION_STORAGE_KEY = 'forkop:shown-log-error-notifications:v1';
const MAX_STORED_LOG_NOTIFICATIONS = 500;

export type ForkopLogNotification =
  | { kind: 'rule-set-unavailable'; line: string }
  | { kind: 'error'; line: string }
  | { kind: 'discord-cloudflare-overlap'; line: string }
  | { kind: 'start-recovery-pending'; line: string }
  | { kind: 'start-recovery-succeeded'; line: string }
  | {
      kind: 'component-update';
      line: string;
      component: string;
      version: string;
    };

function getSessionStorage(): Storage | null {
  if (typeof window === 'undefined') {
    return null;
  }

  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

function readStoredKeys(storage: Storage | null): string[] {
  if (!storage) {
    return [];
  }

  try {
    const parsed = JSON.parse(
      storage.getItem(LOG_NOTIFICATION_STORAGE_KEY) || '[]',
    );

    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === 'string')
      : [];
  } catch {
    return [];
  }
}

function writeStoredKeys(storage: Storage | null, keys: string[]) {
  if (!storage) {
    return;
  }

  try {
    storage.setItem(
      LOG_NOTIFICATION_STORAGE_KEY,
      JSON.stringify(keys.slice(-MAX_STORED_LOG_NOTIFICATIONS)),
    );
  } catch {
    // Notifications are still deduped in-memory when sessionStorage is blocked.
  }
}

export function isErrorLogLine(line: string) {
  const lower = line.toLowerCase();
  return (
    lower.includes('[error]') ||
    lower.includes('[fatal]') ||
    (lower.includes('sing-box') &&
      lower.includes('rule-set') &&
      /\b(error|fatal)\b/.test(lower))
  );
}

export function getForkopLogNotification(
  line: string,
): ForkopLogNotification | null {
  if (line.includes('[rule-set-unavailable]')) {
    return { kind: 'rule-set-unavailable', line };
  }
  if (isErrorLogLine(line)) {
    return { kind: 'error', line };
  }

  if (
    line.toLowerCase().includes('[routing-warning] discord-cloudflare-overlap')
  ) {
    return { kind: 'discord-cloudflare-overlap', line };
  }

  const update = line.match(
    /\[component-update\]\s+(forkop|sing_box|rust_x|zapret_manager)\s+(\S+)/i,
  );

  if (!update) {
    return null;
  }

  return {
    kind: 'component-update',
    line,
    component: update[1].toLowerCase(),
    version: update[2],
  };
}

export function getLogNotificationKey(line: string) {
  if (
    line.toLowerCase().includes('[routing-warning] discord-cloudflare-overlap')
  ) {
    return 'routing-warning:discord-cloudflare-overlap';
  }
  return line.trim();
}

export class LogNotificationDeduper {
  private readonly storage: Storage | null;
  private readonly seenKeys: Set<string>;

  constructor(storage: Storage | null = getSessionStorage()) {
    this.storage = storage;
    this.seenKeys = new Set(readStoredKeys(storage));
    this.trimSeenKeys();
  }

  shouldNotify(line: string) {
    if (!getForkopLogNotification(line)) {
      return false;
    }

    const key = getLogNotificationKey(line);

    if (!key || this.seenKeys.has(key)) {
      return false;
    }

    this.seenKeys.add(key);
    this.trimSeenKeys();
    writeStoredKeys(this.storage, Array.from(this.seenKeys));
    return true;
  }

  private trimSeenKeys() {
    while (this.seenKeys.size > MAX_STORED_LOG_NOTIFICATIONS) {
      const oldest = this.seenKeys.values().next().value;
      if (oldest !== undefined) this.seenKeys.delete(oldest);
    }
  }
}
