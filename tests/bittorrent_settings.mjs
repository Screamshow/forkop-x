import fs from 'node:fs';
import assert from 'node:assert/strict';
const code = fs.readFileSync(new URL('../luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js', import.meta.url),'utf8');
let stored;
const options = new Map();
const section = { render() {}, option(_type,name) {
  const option = {
    map: {readonly: false},
    load() { return stored; },
    write(_id, value) { stored = value; },
    remove() { stored = undefined; },
    depends() {},
    value() {},
    renderWidget(_id, _index, value) { return {value: value ?? this.default, readonly: this.readonly}; },
  };
  options.set(name,option); return option;
}};
const main = {translateForkop:s=>s,FORKOP_UCI_PACKAGE:'forkop',getClashUIUrl:()=>'',DNS_SERVER_OPTIONS:[],BOOTSTRAP_DNS_SERVER_OPTIONS:[]};
const entry = new Function('main','form','baseclass','uci','widgets','E',code)(main,
  {}, {extend:x=>x}, {}, {}, (_tag, _attrs, text) => ({
    text,
    replaceChildren(...children) { this.children = children; },
  }));
const setSupported = entry.createSettingsContent(section);
const option = options.get('bittorrent_direct');
for (const previous of [undefined, '0', '1']) {
  stored = previous;
  setSupported(false);
  const field = option.renderWidget('settings', 0, option.load('settings'));
  assert.deepEqual(field.children[0], {value: previous ?? '0', readonly: true});
  assert.equal(field.children[1].text, 'Update Forkop X to enable this setting');
  option.write('settings', '0');
  option.remove('settings');
  assert.equal(stored, previous, 'unavailable setting must not be written or removed');

  setSupported(true);
  assert.deepEqual(field.children[0], {value: previous ?? '1', readonly: false});
}
option.write('settings', '0');
assert.equal(stored, '0', 'manual OFF works on capable core');
console.log('PASS: BitTorrent checkbox honors the capability, default and saved values');
