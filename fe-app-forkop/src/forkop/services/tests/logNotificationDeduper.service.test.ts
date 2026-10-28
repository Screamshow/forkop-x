import { describe, expect, it } from 'vitest';

import {
  getLogNotificationKey,
  getForkopLogNotification,
  isErrorLogLine,
  LogNotificationDeduper,
} from '../logNotificationDeduper.service';

class MemoryStorage implements Storage {
  private values = new Map<string, string>();

  get length() {
    return this.values.size;
  }

  clear() {
    this.values.clear();
  }

  getItem(key: string) {
    return this.values.get(key) ?? null;
  }

  key(index: number) {
    return Array.from(this.values.keys())[index] ?? null;
  }

  removeItem(key: string) {
    this.values.delete(key);
  }

  setItem(key: string, value: string) {
    this.values.set(key, value);
  }
}

describe('LogNotificationDeduper', () => {
  it('accepts error, fatal, and component update log lines', () => {
    expect(isErrorLogLine('forkop: [info] ok')).toBe(false);
    expect(isErrorLogLine('forkop: [error] failed')).toBe(true);
    expect(isErrorLogLine('forkop: [fatal] failed')).toBe(true);
    expect(
      isErrorLogLine(
        'daemon.err sing-box[123]: FATAL[0000] start service: initialize rule-set[0]: download failed',
      ),
    ).toBe(true);
    expect(
      isErrorLogLine(
        'daemon.err sing-box[123]: ERROR[0000] connection: dial failed',
      ),
    ).toBe(false);
    expect(
      getForkopLogNotification(
        'forkop: [info] [component-update] zapret_manager v1.2.3',
      ),
    ).toEqual({
      kind: 'component-update',
      line: 'forkop: [info] [component-update] zapret_manager v1.2.3',
      component: 'zapret_manager',
      version: 'v1.2.3',
    });
    expect(getForkopLogNotification('forkop: [info] ok')).toBeNull();
    expect(
      getForkopLogNotification(
        'forkop: [warn] [routing-warning] discord-cloudflare-overlap: details',
      ),
    ).toEqual({
      kind: 'discord-cloudflare-overlap',
      line: 'forkop: [warn] [routing-warning] discord-cloudflare-overlap: details',
    });
  });

  it('dedupes already shown log lines through session storage', () => {
    const storage = new MemoryStorage();
    const first = new LogNotificationDeduper(storage);

    expect(first.shouldNotify('forkop: [error] failed')).toBe(true);
    expect(first.shouldNotify('forkop: [error] failed')).toBe(false);
    expect(first.shouldNotify('forkop: [error] another failure')).toBe(true);
    expect(
      first.shouldNotify('forkop: [info] [component-update] forkop 1.2.3'),
    ).toBe(true);
    expect(
      first.shouldNotify(
        'forkop: [warn] [routing-warning] discord-cloudflare-overlap',
      ),
    ).toBe(true);

    const afterReload = new LogNotificationDeduper(storage);

    expect(afterReload.shouldNotify('forkop: [error] failed')).toBe(false);
    expect(afterReload.shouldNotify('forkop: [fatal] fatal failure')).toBe(
      true,
    );
  });

  it('keeps the full log line as the replay key', () => {
    expect(getLogNotificationKey('  Jun 06 forkop: [error] failed  ')).toBe(
      'Jun 06 forkop: [error] failed',
    );
    expect(
      getLogNotificationKey(
        'Jun 06 forkop: [warn] [routing-warning] discord-cloudflare-overlap',
      ),
    ).toBe('routing-warning:discord-cloudflare-overlap');
  });

  it.each([true, false])(
    'bounds live notification keys with storage=%s',
    (withStorage) => {
      const storage = withStorage ? new MemoryStorage() : null;
      const deduper = new LogNotificationDeduper(storage);
      for (let i = 0; i <= 500; i++) {
        expect(deduper.shouldNotify(`forkop: [error] failure ${i}`)).toBe(true);
      }
      expect(deduper.shouldNotify('forkop: [error] failure 500')).toBe(false);
      expect(deduper.shouldNotify('forkop: [error] failure 0')).toBe(true);
      expect(deduper.shouldNotify('forkop: [error] failure 1')).toBe(true);
      if (storage) {
        expect(JSON.parse(storage.getItem(storage.key(0)!)!)).toHaveLength(500);
        const restored = new LogNotificationDeduper(storage);
        expect(restored.shouldNotify('forkop: [error] failure 500')).toBe(
          false,
        );
      }
    },
  );

  it('caps oversized legacy storage when loading a session', () => {
    const storage = new MemoryStorage();
    storage.setItem(
      'forkop:shown-log-error-notifications:v1',
      JSON.stringify(
        Array.from({ length: 600 }, (_, i) => `forkop: [error] failure ${i}`),
      ),
    );
    const deduper = new LogNotificationDeduper(storage);
    expect(deduper.shouldNotify('forkop: [error] failure 599')).toBe(false);
    expect(deduper.shouldNotify('forkop: [error] failure 0')).toBe(true);
  });
});

it('classifies a rejected list apply as a warning notification', () => {
  const line = '[error] [rule-set-unavailable] Settings were not applied';
  expect(getForkopLogNotification(line)).toEqual({
    kind: 'rule-set-unavailable',
    line,
  });
});

it('recognizes Xrust update identity separately from sing-box', () => {
  expect(
    getForkopLogNotification('forkop: [info] [component-update] rust_x 0.0.17'),
  ).toMatchObject({
    kind: 'component-update',
    component: 'rust_x',
    version: '0.0.17',
  });
});
