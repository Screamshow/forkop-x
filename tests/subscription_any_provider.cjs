// node tests/subscription_any_provider.cjs (from the repo root, after yarn install in fe-app-forkop)
// The LuCI subscription URL validator accepts any HTTPS host.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const esbuild = require(require.resolve('esbuild', { paths: [path.join(root, 'fe-app-forkop')] }));
const bundle = esbuild.buildSync({
  entryPoints: [path.join(root, 'fe-app-forkop/src/validators/validateUrl.ts')],
  bundle: true, write: false, format: 'cjs', platform: 'neutral',
  define: { __FORKOP_RUSSIAN__: JSON.stringify('{}') },
}).outputFiles[0].text;
const validators = { exports: {} };
vm.runInNewContext(bundle, {
  module: validators, exports: validators.exports, URL, _: text => text,
  localStorage: { getItem: () => 'en' }, document: { documentElement: { lang: 'en' } },
});

function extract(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `find ${name}`);
  let depth = 0;
  for (let i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unterminated ${name}`);
}

const section = fs.readFileSync(path.join(root, 'luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js'), 'utf8');
const code = ['parseSubscriptionUrlEntry', 'validateSubscriptionUrlEntry'].map(n => extract(section, n)).join('\n');
const validate = vm.runInNewContext(`${code}\nvalidateSubscriptionUrlEntry`, {
  _: text => text, main: { validateUrl: validators.exports.validateUrl },
});

for (const url of [
  'https://sub.hat.onl/a/b.txt',
  'https://feed.example/sub?token=1',
  'https://SUB.Example.ORG:8443/path',
  ' https://other.provider.net/s ',
]) assert.equal(validate('s', url), true, url);

assert.equal(validate('s', ''), true);
assert.match(validate('s', 'http://feed.example/sub'), /^URL must use one of the following protocols: https:$/);
assert.equal(validate('s', 'https://feed.example/sub|Happ'), 'Invalid URL format');
assert.equal(validate('s', 'https://bad host/sub'), 'Invalid URL format');
assert.ok(!section.includes('This subscription provider is not supported'), 'no provider allowlist message left');
console.log('PASS: LuCI accepts subscription URLs from any HTTPS host and still refuses HTTP and malformed URLs');
