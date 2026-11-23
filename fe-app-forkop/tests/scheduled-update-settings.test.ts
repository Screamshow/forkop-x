import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const source = readFileSync(
  new URL('../../luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js', import.meta.url),
  'utf8',
);

type IntervalOption = {
  cfgvalue(sectionId: string): string;
  validate(sectionId: string, value: string): boolean | string;
};

function intervalFields(saved: string) {
  const options = new Map<string, IntervalOption>();
  const section = {
    render() {},
    option(_type: unknown, name: string) {
      const field = { option: name, depends() {}, value() {} };
      options.set(name, field as unknown as IntervalOption);
      return field;
    },
  };
  const settings = new Function('main', 'form', 'baseclass', 'uci', 'widgets', source)(
    {
      translateForkop: (text: string) => text,
      FORKOP_UCI_PACKAGE: 'forkop',
      getClashUIUrl: () => '',
      DNS_SERVER_OPTIONS: {},
      BOOTSTRAP_DNS_SERVER_OPTIONS: {},
    },
    {},
    { extend: (value: unknown) => value },
    { get: () => saved },
    {},
  );
  settings.createSettingsContent(section);
  return options;
}

describe('scheduled update settings', () => {
  it.each(['update_interval', 'component_update_check_interval'])(
    'validates %s at the cron resolution and preserves an editable legacy value',
    (name) => {
      const option = intervalFields('100ms').get(name)!;
      expect(option.cfgvalue('settings')).toBe('1m');
      for (const interval of ['100ms', '59.9s', '0s', '1w', '9007199254740992s']) {
        expect(option.validate('settings', interval)).toContain('at least 1 minute');
      }
      for (const interval of ['1m', '30s30s', '45m', '1d', ' 5h15m ']) {
        expect(option.validate('settings', interval)).toBe(true);
      }
    },
  );
});

it('accepts only a complete uint32 DNS TTL', () => {
  const ttl = intervalFields('60').get('dns_rewrite_ttl')!;
  for (const value of ['0', '60', '4294967295'])
    expect(ttl.validate('settings', value)).toBe(true);
  for (const value of ['', '-1', '12.5', '14abc', '4294967296'])
    expect(ttl.validate('settings', value)).toContain('integer');
});
