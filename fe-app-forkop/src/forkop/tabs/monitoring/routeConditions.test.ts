import { describe, expect, it, vi } from 'vitest';
import {
  createRuntimeRouteRulesLoader,
  expandRouteConditions,
} from './routeConditions';
import { formatRouteReason } from './routeReason';

const reported =
  'inbound=[tproxy-in tproxy6-in] domain_suffix=[dell.com 2ip.io vencord.dev...] => route(VPN-out)';
const rule = {
  inbound: ['tproxy-in', 'tproxy6-in'],
  domain_suffix: ['dell.com', '2ip.io', 'vencord.dev', 'chatgpt.com'],
  action: 'route',
  outbound: 'VPN-out',
};

describe('full runtime route conditions', () => {
  it('recovers the omitted domain from the uniquely identified runtime rule', () => {
    const full = expandRouteConditions(reported, [rule]);
    expect(full).toContain('chatgpt.com');
    expect(
      formatRouteReason(full, '', undefined, { host: 'ws.chatgpt.com' }),
    ).toBe('domain_suffix=chatgpt.com');
  });
  it('keeps the reported rule when identification is ambiguous or impossible', () => {
    expect(
      expandRouteConditions(reported, [
        rule,
        { ...rule, domain_suffix: [...rule.domain_suffix, 'other.org'] },
      ]),
    ).toBe(reported);
    expect(
      expandRouteConditions(reported, [{ ...rule, outbound: 'other-out' }]),
    ).toBe(reported);
    expect(expandRouteConditions(reported, [])).toBe(reported);
  });
  it('checks all reported fields and recovers omitted CIDRs', () => {
    const text =
      'inbound=tproxy-in ip_cidr=[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16...] => route(VPN-out)';
    const full = expandRouteConditions(text, [
      {
        inbound: 'wrong-in',
        ip_cidr: [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '203.0.113.0/24',
        ],
        outbound: 'VPN-out',
      },
      {
        inbound: 'tproxy-in',
        ip_cidr: [
          '10.0.0.0/8',
          '172.16.0.0/12',
          '192.168.0.0/16',
          '203.0.113.0/24',
        ],
        outbound: 'VPN-out',
      },
    ]);
    expect(
      formatRouteReason(full, '', undefined, { destinationIP: '203.0.113.42' }),
    ).toBe('ip_cidr=203.0.113.0/24');
  });
});

describe('runtime route config refresh', () => {
  const flash = '/etc/sing-box/config.json';
  const ram = '/tmp/sing-box/config.json';
  const body = (name: string) =>
    JSON.stringify({ route: { rules: [{ domain: name }] } });

  it('follows the running path and reads a revision only once', async () => {
    const read = vi
      .fn()
      .mockResolvedValueOnce(body('before.test'))
      .mockResolvedValueOnce(body('after.test'));
    const update = vi.fn();
    const loader = createRuntimeRouteRulesLoader(read, update);
    await loader.load({ path: flash, revision: '1' });
    await loader.load({ path: ram, revision: '1' });
    await loader.load({ path: ram, revision: '1' });
    expect(read.mock.calls).toEqual([[flash], [ram]]);
    expect(update).toHaveBeenLastCalledWith([{ domain: 'after.test' }]);
  });

  it('ignores old reads after a same-path reload or leaving the view', async () => {
    let resolveOld!: (value: string) => void;
    let resolveAfterClear!: (value: string) => void;
    const read = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise<string>((resolve) => {
            resolveOld = resolve;
          }),
      )
      .mockResolvedValueOnce(body('new.test'))
      .mockImplementationOnce(
        () =>
          new Promise<string>((resolve) => {
            resolveAfterClear = resolve;
          }),
      );
    const update = vi.fn();
    const loader = createRuntimeRouteRulesLoader(read, update);
    const old = loader.load({ path: ram, revision: '1' });
    await loader.load({ path: ram, revision: '2' });
    resolveOld(body('old.test'));
    await old;
    expect(update).toHaveBeenLastCalledWith([{ domain: 'new.test' }]);
    const pending = loader.load({ path: ram, revision: '3' });
    loader.clear();
    resolveAfterClear(body('late.test'));
    await pending;
    expect(update).toHaveBeenLastCalledWith([]);
  });

  it('retries an unreadable revision while using the core’s original rule', async () => {
    const read = vi
      .fn()
      .mockRejectedValueOnce(new Error())
      .mockResolvedValueOnce(body('retry.test'));
    const update = vi.fn();
    const loader = createRuntimeRouteRulesLoader(read, update);
    const reference = { path: ram, revision: '1' };
    await loader.load(reference);
    expect(update).toHaveBeenLastCalledWith([]);
    await loader.load(reference);
    expect(update).toHaveBeenLastCalledWith([{ domain: 'retry.test' }]);
  });
});
