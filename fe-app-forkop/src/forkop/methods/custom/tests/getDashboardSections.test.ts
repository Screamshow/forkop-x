import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  getConfigSections: vi.fn(),
  getClashApiProxies: vi.fn(),
  canUseDirectClashApi: vi.fn(),
  fsRead: vi.fn(),
}));

vi.mock('../getConfigSections', () => ({
  getConfigSections: mocks.getConfigSections,
}));

vi.mock('../../shell', () => ({
  ForkopShellMethods: {
    getClashApiProxies: mocks.getClashApiProxies,
  },
}));

vi.mock('../../../../helpers', () => ({
  canUseDirectClashApi: mocks.canUseDirectClashApi,
  getClashHttpUrl: () => 'http://router.example:9090',
  getProxyUrlName: (link?: string) =>
    link?.includes('#') ? decodeURIComponent(link.split('#').pop() || '') : '',
  isCopyableProxyLink: (link?: string) => Boolean(link),
}));

import { getDashboardSections } from '../getDashboardSections';
import { ClashAPI, Forkop } from '../../../types';

function proxy(
  type: string,
  options: Partial<ClashAPI.ProxyBase> = {},
): ClashAPI.ProxyBase {
  return {
    type,
    name: options.name || '',
    udp: true,
    history: options.history || [],
    now: options.now,
    all: options.all,
  };
}

function proxySection(
  options: Partial<Forkop.ConfigSection> = {},
): Forkop.ConfigSection {
  return {
    '.name': 'main',
    '.type': 'section',
    enabled: '1',
    action: 'proxy',
    selector_proxy_links: ['vless://example#one'],
    urltests: ['urltest'],
    urltest_settings: urlTestSettings('urltest', {
      display_name: 'Fastest',
      urltest_filter_mode: 'exclude',
    }),
    ...options,
  };
}

function urlTestSettings(
  id: string,
  settings: Record<string, string> = {},
): string {
  return JSON.stringify({
    [id]: settings,
  });
}

function priorityGroup(
  id: string,
  options: Partial<Forkop.ConfigSection> = {},
): Forkop.ConfigSection {
  return {
    '.name': id,
    '.type': 'priority_group',
    section: 'main',
    name: 'Priority group',
    health_url: 'https://priority.example/204',
    active_check_interval: '5s',
    check_timeout: '2s',
    recovery_check_interval: '15s',
    pick_fastest: '0',
    switch_to_faster_same_priority: '0',
    fastest_check_interval: '3m',
    interrupt_exist_connections: '1',
    pin_dashboard: '1',
    ...options,
  };
}

function priorityLevel(
  id: string,
  options: Partial<Forkop.ConfigSection> = {},
): Forkop.ConfigSection {
  return {
    '.name': id,
    '.type': 'priority_level',
    group: 'pg_main',
    name: 'Germany',
    order: '0',
    detect_server_country: 'flag_emoji',
    regex: ['Included'],
    ...options,
  };
}

const clashProxies: Record<string, ClashAPI.ProxyBase> = {
  'main-out': proxy('Selector', {
    name: 'main-out',
    now: 'main-1-out',
    all: ['main-1-out', 'main-2-out', 'main-3-out', 'main-urltest-out'],
  }),
  'main-urltest-out': proxy('URLTest', {
    name: 'main-urltest-out',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 10 }],
    all: ['main-1-out', 'main-3-out'],
  }),
  'main-1-out': proxy('VLESS', {
    name: 'Included 1',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 100 }],
  }),
  'main-2-out': proxy('VLESS', {
    name: 'Filtered 2',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 200 }],
  }),
  'main-3-out': proxy('VLESS', {
    name: 'Included 3',
    history: [{ time: '2026-05-27T00:00:00Z', delay: 300 }],
  }),
};

describe('getDashboardSections', () => {
  it('exposes subscription recovery warnings without treating them as nodes', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        skippedSubscriptionOutbounds: [
          { tag: 'provider-node', reason: 'core-validation' },
          null,
        ],
      }),
    );
    const result = await getDashboardSections();
    expect(result.data[0].skippedSubscriptionOutbounds).toEqual([
      { tag: 'provider-node', reason: 'core-validation' },
    ]);
    expect(
      result.data[0].outbounds.some((item) => item.code === 'provider-node'),
    ).toBe(false);
  });
  beforeEach(() => {
    mocks.getConfigSections.mockReset();
    mocks.getClashApiProxies.mockReset();
    mocks.canUseDirectClashApi.mockReset();
    mocks.fsRead.mockReset();
    mocks.fsRead.mockRejectedValue(new Error('cache miss'));
    vi.stubGlobal('fs', { read: mocks.fsRead });
    vi.stubGlobal('window', undefined);
    vi.stubGlobal('fetch', undefined);

    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: { proxies: clashProxies },
    });
    mocks.canUseDirectClashApi.mockReturnValue(false);
  });

  it('shows the full selector group by default', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-out');
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
  });

  it('does not expose endpoint hostnames as fallback names for non-generic tags', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        selector_proxy_links: [],
        subscription_urls: ['https://provider.example/sub'],
        urltests: [],
        urltest_settings: undefined,
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'vless-1',
            all: ['vless-1'],
          }),
          'vless-1': proxy('VLESS', { name: 'vless-1' }),
        },
      },
    });
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        servers: { 'vless-1': 'reality-target.example' },
        outboundMetadata: { names: {}, countries: {}, descriptions: {} },
      }),
    );

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(result.data[0].outbounds[0]).toMatchObject({
      code: 'vless-1',
      displayName: 'vless-1',
    });
  });

  it('hydrates URLTest details from the section cache and Clash API', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...clashProxies,
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            now: 'main-3-out',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 10 }],
            all: ['main-1-out', 'main-3-out'],
          }),
        },
      },
    });
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {
            'main-1-out': 'First cached',
            'main-3-out': 'Third cached',
          },
          countries: {},
          descriptions: {
            'main-1-out': 'Upstream Tube',
          },
        },
        servers: {
          'main-3-out': 'edge-3.example.com',
        },
        urltestGroups: {
          'main-urltest-out': {
            displayName: 'Fastest',
            outbounds: ['main-1-out', 'main-3-out', 'main-2-out'],
            url: 'https://probe.example/204',
            interval: '3m',
            tolerance: 50,
            interrupt_exist_connections: true,
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const urltest = section.outbounds.find(
      (item) => item.code === 'main-urltest-out',
    );

    expect(result.success).toBe(true);
    expect(urltest?.urlTestInfo).toMatchObject({
      code: 'main-urltest-out',
      displayName: 'Fastest',
      url: 'https://probe.example/204',
      interval: '3m',
      tolerance: 50,
      idleTimeout: '30m',
      interruptExistConnections: true,
      selectedCode: 'main-3-out',
      selectedName: 'Third cached',
    });
    expect(urltest?.urlTestInfo?.outbounds.map((item) => item.code)).toEqual([
      'main-3-out',
      'main-1-out',
      'main-2-out',
    ]);
    expect(urltest?.urlTestInfo?.outbounds[0]).toMatchObject({
      displayName: 'Third cached',
      latency: 300,
      type: 'VLESS',
      selected: true,
    });
    expect(urltest?.urlTestInfo?.outbounds[1]).toMatchObject({
      displayName: 'one',
      latency: 100,
      selected: false,
    });
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out'),
    ).toMatchObject({ description: 'Upstream Tube' });
  });

  it('hydrates imported URLTest settings from the active sing-box config without guessing missing aliases', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        selector_proxy_links: [],
        subscription_urls: ['https://provider.example/sub'],
        urltests: [],
        urltest_settings: undefined,
      }),
      {
        '.name': 'config',
        '.type': 'settings',
        config_path: '/etc/sing-box/config.json',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'Imported',
            all: ['Imported', '🇳🇱 Amsterdam (До 05.09 ❗)'],
          }),
          Imported: proxy('URLTest', {
            name: 'Imported',
            now: 'main-1-out',
            all: ['main-1-out'],
          }),
          'main-1-out': clashProxies['main-1-out'],
          '🇳🇱 Amsterdam (До 05.09 ❗)': proxy('VLESS', {
            name: '🇳🇱 Amsterdam (До 05.09 ❗)',
          }),
        },
      },
    });
    mocks.fsRead.mockImplementation(async (path: string) => {
      if (path === '/etc/sing-box/config.json') {
        return JSON.stringify({
          outbounds: [
            {
              type: 'vless',
              tag: 'main-1-out',
              server: 'edge-7.nl.cdn-store.cloud',
            },
            {
              type: 'vless',
              tag: '🇳🇱 Amsterdam (До 05.09 ❗)',
              server: 'edge-7.nl.cdn-store.cloud',
            },
            {
              type: 'urltest',
              tag: 'Imported',
              outbounds: ['main-1-out'],
              url: 'https://www.gstatic.com/generate_204',
              interval: '70s',
              tolerance: 175,
              idle_timeout: '30m',
              interrupt_exist_connections: true,
            },
          ],
        });
      }
      return JSON.stringify({
        outboundMetadata: {
          names: {
            '🇳🇱 Amsterdam (До 05.09 ❗)': '🇳🇱 Amsterdam (До 05.09 ❗)',
          },
          countries: {
            '🇳🇱 Amsterdam (До 05.09 ❗)': 'NL',
          },
          descriptions: {
            '🇳🇱 Amsterdam (До 05.09 ❗)': 'Upstream Tube',
          },
        },
        urltestGroups: { Imported: {} },
      });
    });

    const result = await getDashboardSections();
    const details = result.data[0].outbounds[0].urlTestInfo;

    expect(details).toMatchObject({
      url: 'https://www.gstatic.com/generate_204',
      interval: '70s',
      tolerance: 175,
      idleTimeout: '30m',
      interruptExistConnections: true,
      selectedName: 'Included 1',
    });
    expect(details?.outbounds[0]).toMatchObject({
      displayName: 'Included 1',
    });
    expect(
      result.data[0].outbounds.find(
        (outbound) => outbound.code === '🇳🇱 Amsterdam (До 05.09 ❗)',
      ),
    ).toMatchObject({
      displayName: '🇳🇱 Amsterdam (До 05.09 ❗)',
      description: 'Upstream Tube',
    });
  });

  it('keeps an empty configured URLTest visible when sing-box skipped the group', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Empty URLTest',
          urltest_filter_mode: 'include',
        }),
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-1-out',
            all: ['main-1-out'],
          }),
          'main-1-out': clashProxies['main-1-out'],
        },
      },
    });
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        urltestGroups: {
          'main-urltest-out': {
            displayName: 'Empty URLTest',
            outbounds: [],
            url: 'https://probe.example/204',
            interval: '3m',
            tolerance: 50,
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const urltest = section.outbounds.find(
      (item) => item.code === 'main-urltest-out',
    );

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
    ]);
    expect(urltest).toMatchObject({
      displayName: 'Empty URLTest',
      type: 'URLTest',
      runtimeAvailable: false,
    });
    expect(urltest?.urlTestInfo?.selectedName).toBeUndefined();
    expect(urltest?.urlTestInfo?.outbounds).toEqual([]);
  });

  it('hydrates Priority dashboard details from config, cache and Clash API', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ urltests: [], urltest_settings: undefined }),
      priorityGroup('pg_main'),
      priorityLevel('pl_de', {
        name: 'Germany',
        order: '0',
        detect_server_country: 'country_is',
      }),
      priorityLevel('pl_nl', {
        name: 'Netherlands',
        order: '1',
        regex: ['Filtered'],
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...clashProxies,
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-priority-pg_main-out',
            all: ['main-1-out', 'main-2-out', 'main-priority-pg_main-out'],
          }),
          'main-priority-pg_main-out': proxy('Selector', {
            name: 'main-priority-pg_main-out',
            now: 'main-2-out',
            all: ['main-2-out', 'main-1-out'],
          }),
        },
      },
    });
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {
            'main-1-out': 'First cached',
            'main-2-out': 'Second cached',
          },
          countries: { 'main-2-out': 'DE' },
        },
        priorityGroups: {
          'main-priority-pg_main-out': {
            displayName: 'Priority group',
            health_url: 'https://priority.example/204',
            active_check_interval: '5s',
            check_timeout: '2s',
            recovery_check_interval: '15s',
            pick_fastest: false,
            switch_to_faster_same_priority: false,
            interrupt_exist_connections: true,
            outbounds: ['main-2-out', 'main-1-out'],
            levels: [
              {
                id: 'pl_de',
                displayName: 'Germany',
                order: 0,
                outbounds: ['main-2-out'],
              },
              {
                id: 'pl_nl',
                displayName: 'Netherlands',
                order: 1,
                outbounds: ['main-1-out'],
              },
            ],
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const priority = section.outbounds.find(
      (item) => item.code === 'main-priority-pg_main-out',
    );

    expect(result.success).toBe(true);
    expect(priority).toMatchObject({
      displayName: 'Priority group',
      type: 'Priority',
      selected: true,
    });
    expect(section.latencyTestCodes).toEqual(['main-2-out', 'main-1-out']);
    expect(priority?.priorityInfo).toMatchObject({
      selectedCode: 'main-2-out',
      selectedName: 'Second cached',
      healthUrl: 'https://priority.example/204',
      activeCheckInterval: '5s',
      checkTimeout: '2s',
      recoveryCheckInterval: '15s',
      pickFastest: false,
      interruptExistConnections: true,
    });
    expect(
      priority?.priorityInfo?.outbounds.map((item) => ({
        code: item.code,
        levelIndex: item.levelIndex,
        levelName: item.levelName,
        selected: item.selected,
        country: item.country,
      })),
    ).toEqual([
      {
        code: 'main-2-out',
        levelIndex: 0,
        levelName: 'Germany',
        selected: true,
        country: 'DE',
      },
      {
        code: 'main-1-out',
        levelIndex: 1,
        levelName: 'Netherlands',
        selected: false,
        country: undefined,
      },
    ]);
  });

  it.each([false, true])(
    'tests all Priority members with standalone proxy present: %s',
    async (mixed) => {
      mocks.getConfigSections.mockResolvedValue([
        proxySection({ urltests: [], urltest_settings: undefined }),
        priorityGroup('pg_main'),
      ]);
      mocks.getClashApiProxies.mockResolvedValue({
        success: true,
        data: {
          proxies: {
            ...clashProxies,
            'main-out': proxy('Selector', {
              all: mixed
                ? ['main-priority-pg_main-out', 'main-3-out']
                : ['main-priority-pg_main-out'],
              now: 'main-priority-pg_main-out',
            }),
            'main-priority-pg_main-out': proxy('Selector', {
              all: ['main-1-out', 'main-2-out'],
              now: 'main-1-out',
            }),
          },
        },
      });
      mocks.fsRead.mockResolvedValue(
        JSON.stringify({
          priorityGroups: {
            'main-priority-pg_main-out': {
              levels: [
                { id: 'first', outbounds: ['main-1-out', 'main-2-out'] },
                { id: 'second', outbounds: ['main-2-out', 'missing-out'] },
              ],
            },
          },
        }),
      );
      const {
        data: [section],
      } = await getDashboardSections();
      expect(section.latencyTestCodes).toEqual(
        mixed
          ? ['main-1-out', 'main-2-out', 'main-3-out']
          : ['main-1-out', 'main-2-out'],
      );
      expect(section.outbounds.map((item) => item.code)).toEqual(
        mixed
          ? ['main-priority-pg_main-out', 'main-3-out']
          : ['main-priority-pg_main-out'],
      );
    },
  );

  it('keeps an empty Priority group visible when sing-box skipped the selector', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        selector_proxy_links: [],
        urltests: [],
        urltest_settings: undefined,
      }),
      priorityGroup('pg_empty', { name: 'Empty Priority' }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: { proxies: {} },
    });
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        priorityGroups: {
          'main-priority-pg_empty-out': {
            displayName: 'Empty Priority',
            outbounds: [],
            levels: [],
            interrupt_exist_connections: true,
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const priority = section.outbounds.find(
      (item) => item.code === 'main-priority-pg_empty-out',
    );

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-priority-pg_empty-out',
    ]);
    expect(priority).toMatchObject({
      displayName: 'Empty Priority',
      type: 'Priority',
      runtimeAvailable: false,
      latency: 0,
    });
    expect(priority?.priorityInfo?.selectedName).toBeUndefined();
    expect(priority?.priorityInfo?.outbounds).toEqual([]);
  });

  it('keeps legacy URLTest sections compatible before migration', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltests: undefined,
        urltest_settings: undefined,
        urltest_enabled: '1',
        urltest_filter_mode: 'exclude',
      }),
    ]);

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
    expect(section.outbounds[0].displayName).toBe('Fastest');
  });

  it('supports multiple configured URLTest groups', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltests: undefined,
        urltest_settings: undefined,
      }),
      {
        '.name': 'cfg010001',
        '.type': 'urltest',
        section: 'main',
        name: 'Fast group',
      },
      {
        '.name': 'cfg010002',
        '.type': 'urltest',
        section: 'main',
        name: 'Stable group',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          ...clashProxies,
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-urltest-cfg010001-out',
            all: [
              'main-1-out',
              'main-urltest-cfg010002-out',
              'main-2-out',
              'main-urltest-cfg010001-out',
            ],
          }),
          'main-urltest-cfg010001-out': proxy('URLTest', {
            name: 'main-urltest-cfg010001-out',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 10 }],
            all: ['main-1-out'],
          }),
          'main-urltest-cfg010002-out': proxy('URLTest', {
            name: 'main-urltest-cfg010002-out',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 50 }],
            all: ['main-2-out'],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-cfg010001-out',
      'main-urltest-cfg010002-out',
      'main-1-out',
      'main-2-out',
    ]);
    expect(section.outbounds.map((item) => item.displayName)).toEqual([
      'Fast group',
      'Stable group',
      'one',
      'Filtered 2',
    ]);
  });

  it('keeps non-built-in URLTest groups in selector order when latency sorting is disabled', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-2-out',
            all: [
              'main-2-out',
              'main-provider-urltest-out',
              'main-1-out',
              'main-urltest-out',
            ],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 10 }],
            all: ['main-2-out', 'main-1-out'],
          }),
          'main-provider-urltest-out': proxy('URLTest', {
            name: 'Provider URLTest',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 150 }],
            all: ['provider-hidden-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Fast leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Slow leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-2-out',
      'main-provider-urltest-out',
      'main-1-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-2-out',
      'main-provider-urltest-out',
      'main-1-out',
    ]);
  });

  it('sorts outbounds by latency only when enabled and does not prioritize URLTest groups except Fastest', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({ sort_by_latency: '1' }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-2-out',
            all: [
              'main-2-out',
              'main-provider-urltest-out',
              'main-1-out',
              'main-urltest-out',
            ],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 10 }],
            all: ['main-2-out', 'main-1-out'],
          }),
          'main-provider-urltest-out': proxy('URLTest', {
            name: 'Provider URLTest',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 150 }],
            all: ['provider-hidden-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Fast leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Slow leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-provider-urltest-out',
      'main-2-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-provider-urltest-out',
      'main-2-out',
    ]);
  });

  it('sorts an unpinned configured URLTest group by latency', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        sort_by_latency: '1',
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          pin_dashboard: '0',
        }),
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'main-out': proxy('Selector', {
            name: 'main-out',
            now: 'main-2-out',
            all: ['main-2-out', 'main-1-out', 'main-urltest-out'],
          }),
          'main-urltest-out': proxy('URLTest', {
            name: 'main-urltest-out',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 250 }],
            all: ['main-2-out', 'main-1-out'],
          }),
          'main-1-out': proxy('VLESS', {
            name: 'Fast leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 100 }],
          }),
          'main-2-out': proxy('VLESS', {
            name: 'Slow leaf',
            history: [{ time: '2026-06-11T00:00:00Z', delay: 300 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'main-1-out',
      'main-urltest-out',
      'main-2-out',
    ]);
  });

  it('does not expose flag-emoji detected countries on dashboard outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          urltest_filter_mode: 'exclude',
          detect_server_country: 'flag_emoji',
        }),
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {},
          countries: { 'main-1-out': 'US' },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBeUndefined();
  });

  it('exposes country.is detected countries on dashboard outbounds', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          urltest_filter_mode: 'exclude',
          detect_server_country: 'country_is',
        }),
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {},
          countries: { 'main-1-out': 'US' },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBe('US');
  });

  it('ignores legacy link refs without a resolved proxy link', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        subscription_urls: ['https://subscription.example/list'],
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        links: {},
        linkRefs: {
          'main-2-out': {
            sourceSection: 'main-subscription-1',
            sourceIndex: 1,
          },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const subscriptionOutbound = section.outbounds.find(
      (item) => item.code === 'main-2-out',
    );

    expect(result.success).toBe(true);
    expect(subscriptionOutbound).not.toHaveProperty('link');
    expect(subscriptionOutbound).not.toHaveProperty('canCopyLink');
  });

  it('does not expose cached subscription links to the dashboard', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        subscription_urls: ['https://subscription.example/list'],
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: { 'main-2-out': 'Provider Subscription' },
          countries: {},
        },
        links: {
          'main-2-out':
            'vless://00000000-0000-4000-8000-000000000002@example.com:443#Subscription',
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;
    const subscriptionOutbound = section.outbounds.find(
      (item) => item.code === 'main-2-out',
    );

    expect(result.success).toBe(true);
    expect(subscriptionOutbound?.displayName).toBe('Provider Subscription');
    expect(subscriptionOutbound).not.toHaveProperty('link');
    expect(subscriptionOutbound).not.toHaveProperty('canCopyLink');
  });

  it('does not expose countries when URLTest filtering is set to all servers', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        urltest_settings: urlTestSettings('urltest', {
          display_name: 'Fastest',
          detect_server_country: 'country_is',
          urltest_filter_mode: 'disabled',
        }),
      }),
    ]);
    mocks.fsRead.mockResolvedValue(
      JSON.stringify({
        outboundMetadata: {
          names: {},
          countries: { 'main-1-out': 'US' },
        },
      }),
    );

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.latencyTestCode).toBe('main-out');
    expect(section.latencyTestCodes).toEqual([
      'main-urltest-out',
      'main-1-out',
      'main-2-out',
      'main-3-out',
    ]);
    expect(section.outbounds.map((item) => item.code)).toContain('main-2-out');
    expect(
      section.outbounds.find((item) => item.code === 'main-1-out')?.country,
    ).toBeUndefined();
  });

  it('uses allocated tags for section names that collide with system tags', async () => {
    mocks.getConfigSections.mockResolvedValue([
      proxySection({
        '.name': 'direct',
        urltests: [],
        urltest_settings: undefined,
        urltest_enabled: '0',
      }),
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'direct-out-1': proxy('Selector', {
            name: 'direct-out-1',
            now: 'direct-1-out',
            all: ['direct-1-out'],
          }),
          'direct-1-out': proxy('VLESS', {
            name: 'Direct manual',
            history: [{ time: '2026-05-27T00:00:00Z', delay: 100 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.code).toBe('direct-out-1');
    expect(section.outbounds.map((item) => item.code)).toEqual([
      'direct-1-out',
    ]);
  });

  it('shows legacy VPN interface sections as a Connection selector group', async () => {
    mocks.getConfigSections.mockResolvedValue([
      {
        '.name': 'AWG',
        '.type': 'section',
        enabled: '1',
        action: 'vpn',
        interface: 'awg1',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'AWG-out': proxy('Selector', {
            name: 'AWG-out',
            now: 'AWG-interface-1-out',
            all: ['AWG-interface-1-out'],
          }),
          'AWG-interface-1-out': proxy('Direct', {
            name: 'awg1',
            history: [{ time: '2026-06-07T00:00:00Z', delay: 445 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.action).toBe('vpn');
    expect(section.withTagSelect).toBe(true);
    expect(section.proxyConfigType).toBe('interface');
    expect(section.outbounds[0]).toMatchObject({
      code: 'AWG-interface-1-out',
      displayName: 'awg1',
      selected: true,
    });
  });

  it('hydrates migrated interface children into the Connection selector group', async () => {
    mocks.getConfigSections.mockResolvedValue([
      {
        '.name': 'AWG',
        '.type': 'section',
        enabled: '1',
        action: 'connection',
      },
      {
        '.name': 'cfg01',
        '.type': 'section_interface',
        section: 'AWG',
        name: 'awg1',
      },
    ]);
    mocks.getClashApiProxies.mockResolvedValue({
      success: true,
      data: {
        proxies: {
          'AWG-out': proxy('Selector', {
            name: 'AWG-out',
            now: 'AWG-interface-1-out',
            all: ['AWG-interface-1-out'],
          }),
          'AWG-interface-1-out': proxy('Direct', {
            name: 'awg1',
            history: [{ time: '2026-07-13T00:00:00Z', delay: 445 }],
          }),
        },
      },
    });

    const result = await getDashboardSections();
    const [section] = result.data;

    expect(result.success).toBe(true);
    expect(section.code).toBe('AWG-out');
    expect(section.withTagSelect).toBe(true);
    expect(section.proxyConfigType).toBe('interface');
    expect(section.outbounds[0]).toMatchObject({
      code: 'AWG-interface-1-out',
      displayName: 'awg1',
      selected: true,
    });
  });

  it('fetches Clash API proxies directly in the browser to avoid rpcd output limits', async () => {
    mocks.getConfigSections.mockResolvedValue([
      { '.name': 'settings', '.type': 'settings', yacd_secret_key: 'secret' },
      proxySection(),
    ]);
    mocks.canUseDirectClashApi.mockReturnValue(true);
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ proxies: clashProxies }),
    });

    vi.stubGlobal('window', { location: { hostname: 'router.example' } });
    vi.stubGlobal('fetch', fetchMock);

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      'http://router.example:9090/proxies',
      expect.objectContaining({
        headers: { Authorization: 'Bearer secret' },
        signal: expect.anything(),
      }),
    );
    expect(mocks.getClashApiProxies).not.toHaveBeenCalled();
  });

  it('uses rpcd fallback when direct Clash API access times out', async () => {
    vi.useFakeTimers();

    try {
      mocks.getConfigSections.mockResolvedValue([proxySection()]);
      mocks.canUseDirectClashApi.mockReturnValue(true);
      const fetchMock = vi.fn(
        (_url: string, options?: RequestInit) =>
          new Promise<Response>((_resolve, reject) => {
            options?.signal?.addEventListener('abort', () =>
              reject(new Error('aborted')),
            );
          }),
      );

      vi.stubGlobal('fetch', fetchMock);

      const resultPromise = getDashboardSections();
      await vi.advanceTimersByTimeAsync(5000);
      const result = await resultPromise;

      expect(result.success).toBe(true);
      expect(mocks.getClashApiProxies).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it('uses rpcd fallback when direct Clash API access is unsafe', async () => {
    mocks.getConfigSections.mockResolvedValue([proxySection()]);
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ proxies: clashProxies }),
    });

    vi.stubGlobal('window', {
      location: { hostname: 'router.example', protocol: 'https:' },
    });
    vi.stubGlobal('fetch', fetchMock);

    const result = await getDashboardSections();

    expect(result.success).toBe(true);
    expect(fetchMock).not.toHaveBeenCalled();
    expect(mocks.getClashApiProxies).toHaveBeenCalledTimes(1);
  });
});
