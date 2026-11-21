import { describe, expect, it } from 'vitest';
import {
  formatMaskedXrustConfig,
  maskGlobalCheckText,
  maskXrustConfigValue,
  maskSupportReportText,
} from '../helpers/maskDiagnostics';

describe('diagnostic masking', () => {
  it('masks sensitive Xrust keys without mutating the original config', () => {
    const config = {
      outbounds: [
        {
          type: 'vless',
          tag: 'proxy',
          server: 'example.com',
          server_port: 443,
          uuid: 'client-id',
          tls: {
            enabled: true,
            server_name: 'example.com',
          },
        },
      ],
      route: {
        rules: [{ domain_suffix: ['example.org'], outbound: 'proxy' }],
      },
    };

    expect(maskXrustConfigValue(config)).toEqual({
      outbounds: [
        {
          type: 'vless',
          tag: 'proxy',
          server: 'MASKED',
          server_port: 'MASKED',
          uuid: 'MASKED',
          tls: {
            enabled: true,
            server_name: 'MASKED',
          },
        },
      ],
      route: {
        rules: [{ domain_suffix: 'MASKED', outbound: 'proxy' }],
      },
    });
    expect(config.outbounds[0].server).toBe('example.com');
  });

  it('formats masked Xrust config from a raw JSON string', () => {
    const masked = formatMaskedXrustConfig(
      '{"inbounds":[{"listen":"127.0.0.1","listen_port":2080}]}',
    );

    expect(masked).toContain('"listen": "MASKED"');
    expect(masked).toContain('"listen_port": "MASKED"');
  });

  it('masks case-insensitive transport credentials and withholds unparseable configs', () => {
    const masked = formatMaskedXrustConfig({
      headers: {
        Authorization: 'synthetic credentials',
        'pRoXy-AuThOrIzAtIoN': ['synthetic credentials'],
        COOKIE: 'synthetic cookie',
        'Set-Cookie': 'synthetic cookie',
        'Content-Type': 'application/json',
      },
    });
    expect(JSON.parse(masked).headers).toEqual({
      Authorization: 'MASKED',
      'pRoXy-AuThOrIzAtIoN': 'MASKED',
      COOKIE: 'MASKED',
      'Set-Cookie': 'MASKED',
      'Content-Type': 'application/json',
    });
    expect(formatMaskedXrustConfig('{"password":"secret"')).toBe('MASKED');
    expect(formatMaskedXrustConfig('"secret"')).toBe('MASKED');
  });

  it('masks sensitive global check UCI values while keeping visible structure stable', () => {
    const raw = [
      "config section 'main'",
      "\toption proxy_string 'vless://secret@example.com:443'",
      "\toption hwid 'device-secret'",
      "\tlist domain 'example.com'",
      "\toption outbound_json '{",
      '  "server": "example.com",',
      "}'",
      "config interface 'lan'",
      "\toption ipaddr '192.168.1.1'",
      "\toption netmask '255.255.255.0'",
      "config interface 'wan'",
      "\toption username 'provider-user'",
      "\toption password 'provider-password'",
      "config subscription_url 'sub1'",
      "\toption url 'https://user:password@example.com/subscription?token=secret'",
      "config interface 'wireguard_wan'",
      "\toption private_key 'wireguard-private-secret'",
      '',
    ].join('\n');

    const masked = maskGlobalCheckText(raw);

    expect(masked.split('\n')).toHaveLength(raw.split('\n').length);
    expect(masked).not.toContain('vless://secret');
    expect(masked).not.toContain('device-secret');
    expect(masked).not.toContain('example.com",');
    expect(masked).not.toContain('192.168.1.1');
    expect(masked).not.toContain('provider-password');
    expect(masked).not.toContain('token=secret');
    expect(masked).not.toContain('wireguard-private-secret');
    expect(masked).toContain("option proxy_string 'MASKED'");
    expect(masked).toContain("option ipaddr 'MASKED'");
    expect(masked).toContain("option url 'MASKED'");
    expect(masked).toContain("option private_key 'MASKED'");
  });

  it('masks proxy URIs and credential-bearing URLs from support-report logs', () => {
    const masked = maskSupportReportText(
      'retry vless://client-id@example.com:443#node\n' +
        'request https://example.com/sub?token=secret-value',
    );

    expect(masked).not.toContain('client-id');
    expect(masked).not.toContain('secret-value');
    expect(masked).toContain('MASKED');
  });
});
