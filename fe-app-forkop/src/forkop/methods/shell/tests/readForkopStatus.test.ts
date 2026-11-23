import { afterEach, expect, it, vi } from 'vitest';
import {
  readForkopClashData,
  readForkopRuntimeConfig,
} from '../readForkopStatus';

afterEach(() => vi.unstubAllGlobals());

it.each([true, false])(
  'reads a large Clash snapshot through the same-origin stream (write=%s)',
  async (writable) => {
    vi.stubGlobal('L', {
      url: (...parts: string[]) => `/${parts.join('/')}`,
      hasViewPermission: () => writable,
      env: { token: 'fixture-token' },
    });
    const fixture = JSON.stringify({
      connections: Array.from({ length: 2000 }, (_, index) => ({
        id: String(index),
        metadata: { host: `${'a'.repeat(180)}.example` },
      })),
    });
    expect(fixture.length).toBeGreaterThan(262144);
    const fetch = vi.fn().mockResolvedValue(new Response(fixture));
    vi.stubGlobal('fetch', fetch);
    const response = await readForkopClashData<{ connections: unknown[] }>(
      'connections',
    );
    expect(response.success && response.data.connections).toHaveLength(2000);
    expect(fetch.mock.calls[0][0]).toBe('/admin/services/forkop/ui-clash');
    expect(String(fetch.mock.calls[0][1].body)).toBe(
      'operation=connections&token=fixture-token',
    );
  },
);

it('requests metadata by revision, without exposing a file read interface', async () => {
  vi.stubGlobal('L', {
    url: (...parts: string[]) => `/${parts.join('/')}`,
    hasViewPermission: () => true,
    env: { token: 'fixture-token' },
  });
  const read = vi.fn();
  vi.stubGlobal('fs', { read });
  const fetch = vi
    .fn()
    .mockResolvedValue(
      Response.json({ code: 0, stdout: '{"outbounds":[]}', stderr: '' }),
    );
  vi.stubGlobal('fetch', fetch);
  await expect(
    readForkopRuntimeConfig('/srv/custom/xrust.json', '100:42'),
  ).resolves.toBe('{"outbounds":[]}');
  expect(read).not.toHaveBeenCalled();
  expect(String(fetch.mock.calls[0][1].body)).toBe(
    'operation=runtime_config&subject=100%3A42&token=fixture-token',
  );
});
