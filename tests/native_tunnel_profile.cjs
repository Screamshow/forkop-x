const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const net = require('node:net');

const source = fs.readFileSync(path.join(__dirname,
  '../luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js'), 'utf8');
const start = source.indexOf('function isTunnelDnsAddress(');
const parserEnd = source.indexOf('\nfunction ', source.indexOf('function parseNativeTunnelProfile(') + 1);
const writes = [];
const context = vm.createContext({
  validation: { parseIPv4: value => net.isIP(value) === 4, parseIPv6: value => net.isIP(value) === 6 },
  _: value => value,
  mode: 'amneziawg',
  UCI_PACKAGE: 'forkop',
  uci: { set: (...args) => writes.push(args) },
});
vm.runInContext(source.slice(start, parserEnd), context);
for (const method of ['validate', 'write']) {
  const matches = [...source.matchAll(new RegExp(`o\\.${method} = function \\(section_id, value\\) \\{[\\s\\S]*?^    \\};`, 'gm'))];
  const match = matches.find(item => item[0].includes('parseNativeTunnelProfile('));
  assert.ok(match, `native tunnel ${method} callback exists`);
  vm.runInContext(`var ${method} = ${match[0].replace(`o.${method} = `, '')}`, context);
}
const fixture = `[Interface]
PrivateKey = ${Buffer.alloc(32, 1).toString('base64')}
Address = 10.0.0.2
DNS = 1.1.1.1
Jc = 4
Jmin = 10
Jmax = 50
S1 = 111
S2 = 23
S3 = 32
S4 = 12
H1 = 1
H2 = 2
H3 = 3
H4 = 4
[Peer]
PublicKey = ${Buffer.alloc(32, 2).toString('base64')}
AllowedIPs = 0.0.0.0/0
Endpoint = 192.0.2.1:51820
PersistentKeepalive = 25-35
`;
const profileText = process.argv[2] ? fs.readFileSync(process.argv[2], 'utf8') : fixture;
assert.equal(context.validate('test', profileText), true);
context.write('test', profileText);
assert.equal(writes.length, 1);
const saved = JSON.parse(writes[0][3]);
assert.equal(saved.type, 'wireguard');
assert.equal(context.validate('test', JSON.stringify(saved)), true);
assert.equal(context.validate('test', 'invalid'), 'Invalid tunnel profile');
assert.ok(source.includes('parseNativeTunnelProfile(textarea.value)'));
assert.ok(!source.includes('parseNativeTunnelProfile(mode,'));
console.log('PASS: native tunnel form validation, save, JSON reload and import call');
