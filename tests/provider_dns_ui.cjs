const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'../luci-app-forkop/htdocs/luci-static/resources/view/forkop/settings.js'),'utf8');
const start = source.indexOf('  const providerOption =');
const end = source.indexOf('  let o = section.option(', start);
let enabled='0';
const flag={formvalue:()=>enabled,cfgvalue:()=>enabled};
const create = new Function('section','form','_','E','fs','uci','UCI_PACKAGE',source.slice(start,end)+';return {renderProviderList,providerOption};');
const ui=create({option:()=>flag},{Flag:{}},x=>x,(tag,attrs,children)=>({tag,...attrs,children,style:{setProperty(key,value,priority){this[key]=value;this.priority=priority;}}}),
  {exec:async()=>({stdout:JSON.stringify({candidates:[{server:'10.1.0.1',interface:'wan'}]})})},
  {get:()=>enabled},'forkop');
const manual={saved:['https://dns.example/dns-query'],renderWidget(){return {manual:true};}};
ui.renderProviderList(manual);
(async()=>{
 const widget=await manual.renderWidget('settings');
 await Promise.resolve();
 const [original,provider]=widget.children;
 assert.equal(original.hidden,false);
 assert.equal(provider.hidden,true);
 enabled='1';ui.providerOption.onchange(null,'settings','1');
 assert.equal(original.hidden,true);
 assert.equal(original.style.display,'none');
 assert.equal(original.style.priority,'important');
 assert.equal(provider.hidden,false);
 assert.equal(provider.readonly,true);
 assert.equal(provider.value,'10.1.0.1 (wan)');
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
})().catch(e=>{console.error(e);process.exitCode=1;});
