const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'../luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js'),'utf8');
const start = source.indexOf('  const providerOption =');
const end = source.indexOf('  const dnsProtocol = section.option(', start);
let enabled='0';
let providerCalls=0;
const flag={formvalue:()=>enabled,cfgvalue:()=>enabled};
const create = new Function('section','form','_','E','fs','uci','UCI_PACKAGE','main',source.slice(start,end)+';return {renderProviderList,providerOption};');
const ui=create({option:()=>flag},{Flag:{}},x=>x,(tag,attrs,children)=>({tag,...attrs,children,style:{setProperty(key,value,priority){this[key]=value;this.priority=priority;}}}),
  {exec:async()=>{ providerCalls++; return {stdout:JSON.stringify({candidates:[{server:'10.1.0.1',interface:'wan'}]})}; }},
  {get:()=>enabled},'forkop',{});
const manual={saved:['https://dns.example/dns-query'],renderWidget(){return {manual:true};}};
ui.renderProviderList(manual);

const helpers = source.slice(
  source.indexOf('function optionListValues('),
  source.indexOf('function configureDnsFailoverVisibility('),
);
const fields = source.slice(
  source.indexOf('  const dnsProtocol = section.option('),
  source.indexOf('  let o = section.option('),
);
const createDnsFields = new Function('section', 'form', 'main', '_', 'uci', 'UCI_PACKAGE',
  'L', 'providerEnabled', 'renderProviderList',
  `${helpers}\n${fields}\nreturn { dnsProtocol, bootstrapOption };`);

function fixture(type, legacy, savedServers) {
  const saved = { dns_type: type, bootstrap_dns_server: savedServers };
  if (legacy !== undefined) saved.bootstrap_dns_legacy_type = legacy;
  const writes = [];
  const uci = {
    get(_package, _section, name) { return saved[name]; },
    set(_package, _section, name, value) { saved[name] = value; writes.push([name, value]); },
    unset(_package, _section, name) { delete saved[name]; writes.push([name]); },
  };
  const section = {
    option(_type, name) {
      return {
        keylist: [], vallist: [], current: saved[name], configured: saved[name], active: true,
        value(value, label) { this.keylist.push(value); this.vallist.push(label); },
        depends() {},
        isActive() { return this.active; },
        formvalue() { return this.current; },
        cfgvalue() { return this.configured; },
        write(_section, value) { saved[name] = value; writes.push([name, value]); },
        parse(id) {
          if (!this.active && this.retain) return;
          if (this.current !== this.configured) this.write(id, this.current);
        },
      };
    },
  };
  const main = {
    DNS_SERVER_OPTIONS: {}, BOOTSTRAP_DNS_SERVER_OPTIONS: {},
    validateDNS: () => ({ valid: true }),
    validateBootstrapDNS: (value) => ({
      valid: /^\d/.test(value),
      message: 'Bootstrap DNS must use an IPv4 or IPv6 address',
    }),
  };
  const state = { provider: false };
  const L = { toArray: (value) => Array.isArray(value) ? value : value == null ? [] : [value] };
  const { dnsProtocol, bootstrapOption } = createDnsFields(section, {}, main, (value) => value,
    uci, 'forkop', L, () => state.provider, () => {});
  dnsProtocol.configured = dnsProtocol.load('settings');
  dnsProtocol.current = dnsProtocol.configured;
  return { saved, writes, dnsProtocol, bootstrapOption, state };
}

async function testLegacyProtocolSelection() {
  const choices = ['doh', 'dot', 'udp', 'legacy-doh', 'legacy-dot'];
  for (const type of ['doh', 'dot']) {
    const { saved, writes, dnsProtocol, bootstrapOption, state } =
      fixture(type, type, ['resolver.lan', '1.1.1.1:53']);
    assert.equal(dnsProtocol.current, `legacy-${type}`);
    assert.deepEqual(dnsProtocol.keylist, choices);
    assert.match(dnsProtocol.vallist[choices.indexOf(`legacy-${type}`)], /UDP for Bootstrap DNS/);
    await dnsProtocol.parse('settings');
    assert.deepEqual(writes, []);
    assert.equal(saved.bootstrap_dns_legacy_type, type);
    assert.equal(bootstrapOption.validate('settings', 'resolver.lan'), true);
    assert.notEqual(bootstrapOption.validate('settings', 'new-resolver.lan'), true);

    dnsProtocol.active = false;
    state.provider = true;
    dnsProtocol.current = type;
    await dnsProtocol.parse('settings');
    assert.deepEqual(writes, []);
    assert.equal(bootstrapOption.validate('settings', 'resolver.lan'), true);

    dnsProtocol.active = true;
    state.provider = false;
    await assert.rejects(dnsProtocol.parse('settings'), /IPv4 or IPv6 address/);
    assert.deepEqual(writes, []);
    assert.notEqual(bootstrapOption.validate('settings', 'resolver.lan'), true);
    bootstrapOption.current = ['1.1.1.1'];
    await dnsProtocol.parse('settings');
    assert.deepEqual(writes, [['dns_type', type], ['bootstrap_dns_legacy_type']]);
    assert.equal(dnsProtocol.load('settings'), type);
    assert.deepEqual(dnsProtocol.keylist, choices);
  }

  const fresh = fixture('udp', undefined, ['1.1.1.1']);
  assert.equal(fresh.dnsProtocol.current, 'udp');
  assert.deepEqual(fresh.dnsProtocol.keylist, choices);
  for (const type of ['doh', 'dot']) {
    fresh.dnsProtocol.current = `legacy-${type}`;
    await fresh.dnsProtocol.parse('settings');
    assert.equal(fresh.saved.dns_type, type);
    assert.equal(fresh.saved.bootstrap_dns_legacy_type, type);
    assert.equal(fresh.dnsProtocol.load('settings'), `legacy-${type}`);
  }
  const mismatched = fixture('dot', 'doh', ['1.1.1.1']);
  assert.equal(mismatched.dnsProtocol.current, 'dot');
  assert.deepEqual(mismatched.dnsProtocol.keylist, choices);
  console.log('Bootstrap DNS legacy selection, save and validation checks passed');
}

(async()=>{
 const widget=await manual.renderWidget('settings');
 const bootstrap={renderWidget(){return {manual:true};}};
 ui.renderProviderList(bootstrap);
 const second=await bootstrap.renderWidget('settings');
 await Promise.resolve();
 const [original,provider]=widget.children;
 assert.equal(original.hidden,false);
 assert.equal(provider.hidden,true);
 assert.equal(providerCalls,0,'manual DNS never probes WAN');
 enabled='1';ui.providerOption.onchange(null,'settings','1');
 await new Promise(resolve => setImmediate(resolve));
 assert.equal(original.hidden,true);
 assert.equal(original.style.display,'none');
 assert.equal(original.style.priority,'important');
 assert.equal(provider.hidden,false);
 assert.equal(provider.readonly,true);
 assert.equal(provider.value,'10.1.0.1 (wan)');
 assert.equal(second.children[1].value,provider.value);
 assert.equal(providerCalls,1,'main and bootstrap share the same preview request');
 enabled='0';ui.providerOption.onchange(null,'settings','0');
 assert.equal(original.hidden,false);
 assert.deepEqual(manual.saved,['https://dns.example/dns-query']);
 enabled='1';
 // Fresh section has no onchange edit; unmounted Flag.formvalue may report 0.
 flag.formvalue=()=> '0';
 const initial=await manual.renderWidget('fresh-settings');
 assert.equal(initial.children[0].style.display,'none');
 assert.equal(initial.children[1].style.display,'');
 console.log('Provider DNS UI toggle and manual preservation checks passed');
 await testLegacyProtocolSelection();
})().catch(e=>{console.error(e);process.exitCode=1;});
