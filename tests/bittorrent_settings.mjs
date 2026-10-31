import fs from 'node:fs';
import assert from 'node:assert/strict';
const code = fs.readFileSync(new URL('../luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js', import.meta.url),'utf8');
let info;
let stored;
const options = new Map();
const section = { render() {}, option(_type,name) {
  const option = { load(){return stored}, write(_id,value){stored=value},
    remove(){stored=undefined}, depends(){},value(){} };
  options.set(name,option); return option;
}};
const main = {translateForkop:s=>s,FORKOP_UCI_PACKAGE:'forkop',getClashUIUrl:()=>'',DNS_SERVER_OPTIONS:[],BOOTSTRAP_DNS_SERVER_OPTIONS:[]};
const entry = new Function('main','fs','form','baseclass','uci','widgets',code)(main,
  {exec:async()=>({stdout:JSON.stringify(info)})}, {}, {extend:x=>x}, {}, {});
entry.createSettingsContent(section);
const option=options.get('bittorrent_direct');
for(const [version,support,readonly,description] of [
  ['1.14.2-x-1.0.4',1,true,'Available only for Xrust'],
  ['1.14.2-extended-2.7.2',0,true,'Available only for Xrust'],
  ['1.14.2-rust-x.0.0.30',0,true,'Update Xrust to enable this setting'],
  ['1.14.2-rust-x.0.0.31',1,false,null],
]) {
  info={sing_box_version:version,sing_box_bittorrent_direct:support};
  await option.load('settings'); assert.equal(option.readonly,readonly);
  assert.equal(option.default, readonly ? '0' : '1');
  if(description) assert.equal(option.description,description);
}
stored='0';
assert.equal(await option.load('settings'),'0','explicit off must survive loading');
stored='1';
assert.equal(await option.load('settings'),'1','explicit on must survive loading');
info={sing_box_version:'1.14.2-rust-x.0.0.30',sing_box_bittorrent_direct:0};
for(const previous of [undefined,'0','1']) {
  stored=previous;
  await option.load('settings');
  option.write('settings','0'); option.remove('settings');
  assert.equal(stored,previous,'unavailable setting must not be written or removed');
}
stored=undefined;
info={sing_box_version:'1.14.2-rust-x.0.0.31',sing_box_bittorrent_direct:1};
await option.load('settings');
assert.equal(option.default,'1','core upgrade enables absent setting');
option.write('settings','0');
assert.equal(stored,'0','manual OFF works on capable core');
console.log('PASS: BitTorrent checkbox core and capability gates');
