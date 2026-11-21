import { describe, expect, it } from 'vitest';
import { matchedConditions } from './matchedConditions';
import { formatRouteReason } from './routeReason';

describe('connection matched conditions', () => {
  it('does not reconstruct Xrust logical or inverted matches', () => {
    for (const mode of ['and', 'or', '!and', '!or']) {
      expect(
        matchedConditions(
          `${mode}(inbound=tproxy-in domain_suffix=example.org)`,
          { host: 'example.org' },
        ),
      ).toBeUndefined();
    }
  });
  it('filters domain families and keeps multiple matches', () => {
    expect(
      matchedConditions(
        'inbound=tproxy-in domain_suffix=[other.org example.org] domain_keyword=example domain_regex=^api\\.example\\.org$ => route(VPN)',
        { host: 'api.example.org' },
      ),
    ).toBe(
      'domain_suffix=example.org; domain_keyword=example; domain_regex=^api\\.example\\.org$',
    );
    expect(
      matchedConditions('domain_suffix=example.org', {
        host: 'notexample.org',
      }),
    ).toBeUndefined();
    expect(
      matchedConditions('domain=example.org', { host: 'api.example.org' }),
    ).toBeUndefined();
    expect(
      matchedConditions('domain_suffix=example.org', {
        host: 'API.EXAMPLE.ORG.',
      }),
    ).toBe('domain_suffix=example.org');
  });
  it('prefers the sniffed hostname', () => {
    expect(
      matchedConditions('domain=[old.org new.org]', {
        host: 'old.org',
        sniffHost: 'new.org',
      }),
    ).toBe('domain=new.org');
  });
  it('handles character classes and groups in Xrust regex lists', () => {
    expect(
      matchedConditions(
        'domain_suffix=[other.org ...] domain_regex=[^api[0-9]+\\.example\\.org$ ^(other|else)\\.org$] ip_cidr=[1.2.3.4 ...] => route(VPN)',
        { host: 'api12.example.org' },
      ),
    ).toBe('domain_regex=^api[0-9]+\\.example\\.org$');
    expect(
      matchedConditions('domain_regex=^(a+)+$', { host: 'aaaaaaaa!' }),
    ).toBeUndefined();
  });
  it('matches IPv4 and IPv6 CIDRs, including partial bytes and exact addresses', () => {
    expect(
      matchedConditions('ip_cidr=[18.184.0.0/15 1.2.3.4]', {
        destinationIP: '18.185.209.28',
      }),
    ).toBe('ip_cidr=18.184.0.0/15');
    expect(
      matchedConditions('ip_cidr=18.184.0.0/15', {
        destinationIP: '18.186.0.1',
      }),
    ).toBeUndefined();
    expect(
      matchedConditions('ip_cidr=[2001:db8::/33 ::1]', {
        destinationIP: '2001:db8:7fff::1',
      }),
    ).toBe('ip_cidr=2001:db8::/33');
    expect(
      matchedConditions('ip_cidr=2001:db8::/33', {
        destinationIP: '2001:db8:8000::1',
      }),
    ).toBeUndefined();
    expect(
      matchedConditions('ip_cidr=::ffff:192.0.2.1', {
        destinationIP: '::ffff:c000:201',
      }),
    ).toBe('ip_cidr=::ffff:192.0.2.1');
    expect(
      matchedConditions('ip_cidr=0.0.0.0/0', { destinationIP: '192.0.2.1' }),
    ).toBe('ip_cidr=0.0.0.0/0');
  });
  it('preserves opaque, inverted, missing, invalid and truncated conditions', () => {
    for (const rule of [
      'invert=true domain=example.org',
      '(domain=example.org)',
      'rule_set=custom domain=example.org',
      'domain=[other.org example...]',
      'domain_regex=[',
      'ip_cidr=1.2.3.4/33',
    ]) {
      expect(
        matchedConditions(rule, {
          host: 'example.org',
          destinationIP: '1.2.3.4',
        }),
      ).toBeUndefined();
    }
    expect(
      formatRouteReason('domain=example.org => route(VPN)', '', undefined, {}),
    ).toBe('Exact match unavailable');
    expect(
      formatRouteReason(
        'domain=[other.org example.org] => route(VPN)',
        '',
        undefined,
        { host: 'example.org' },
      ),
    ).toBe('domain=example.org');
  });
});
