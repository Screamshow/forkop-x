const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const text = fs.readFileSync(process.argv[2] || require('node:path').join(__dirname,'../luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js'), 'utf8');
const code = text.slice(text.indexOf('const editorPreviewStates ='), text.indexOf('function normalizeDynamicListItems'));
let urls = ['https://example.com/first'];
let saved = {};
let staged = null;
let metadataReads = 0;
const pending = [];
const cache = new Map();
let status = {textContent:''};
const context = {
  Map, Set, Date, Math, JSON,
  outboundNameChoicesCache: cache, outboundNameChoicesInflight: new Map(),
  outboundNameSourceOptions: new Map([['subscription_url', {stagedChildSettings:()=>staged}]]), UCI_PACKAGE:'forkop',
  currentSourceOptionValues: () => urls,
  childItemInputValue: (_s, value) => value,
  uci: {get: (_p,id) => saved[id]}, document: {getElementById: () => status},
  getChildItemIds: () => Object.keys(saved),
  plainObject: x => x || {}, refreshDashboardFilterChoiceWidgets() {},
  readOutboundMetadataFromSectionCache: async () => { metadataReads++; return {names:{old:'Old runtime'}}; },
  fs: {write:async()=>{}, remove:async()=>{}, exec:()=>new Promise(resolve=>pending.push(resolve))},
};
vm.createContext(context);
vm.runInContext(code,context);
const deadline=setTimeout(()=>{console.error('Editor preview test timed out');process.exit(1);},10000);
(async()=>{
  const first=context.loadOutboundNameChoices('new'); await new Promise(setImmediate);
  urls=['https://example.com/second'];
  const second=context.loadOutboundNameChoices('new'); await new Promise(setImmediate);
  const detachedStatus=status;
  status={textContent:''};
  const reopeningPending=context.loadOutboundNameChoices('new');
  assert.equal(status.textContent,'Загружаем серверы подписки…');
  assert.equal(pending.length,2,'reopening does not start another request');
  pending[1]({code:0,stdout:JSON.stringify({names:{b:'New server'}})});
  await second;
  await reopeningPending;
  assert.equal(status.textContent,'Серверы подписки: 1');
  assert.equal(detachedStatus.textContent,'Загружаем серверы подписки…');
  status={textContent:''};
  await context.loadOutboundNameChoices('new');
  assert.equal(status.textContent,'Серверы подписки: 1','reopening restores cached count');
  assert.equal(pending.length,2);
  pending[0]({code:0,stdout:JSON.stringify({names:{a:'Stale server'}})});
  await first;
  assert.equal(status.textContent,'Серверы подписки: 1','stale response cannot change status');
  assert.deepEqual([...cache.get('new')],['New server']);
  urls=[];
  assert.deepEqual([...await context.loadOutboundNameChoices('new')],['Old runtime']);
  assert.equal(status.textContent,'','removing source clears count');
  urls=['https://example.com/bad'];
  const bad=context.loadOutboundNameChoices('new'); await new Promise(setImmediate);
  pending[2]({code:0,stdout:JSON.stringify({error:'Download failed'})});
  assert.deepEqual([...await bad],[]);
  const retry=context.loadOutboundNameChoices('new'); await new Promise(setImmediate);
  pending[3]({code:0,stdout:JSON.stringify({names:{a:'Recovered'}})});
  assert.deepEqual([...await retry],['Recovered']);
  // A working saved feed must remain editable even when preview would fail
  // (including proxy downloads and an offline provider).
  saved = {source1:{'.name':'source1',section:'existing',url:'https://example.com/saved',download_via_proxy_enabled:'1',download_via_proxy_section:'proxy'}};
  urls=['source1'];
  context.childItemInputValue=(_s,id)=>saved[id]?.url || id;
  const callsBefore=pending.length;
  const savedChoices=context.loadOutboundNameChoices('existing'); await new Promise(setImmediate);
  if (pending.length>callsBefore) pending.at(-1)({code:0,stdout:JSON.stringify({error:'Preview unavailable'})});
  assert.deepEqual([...await savedChoices],['Old runtime']);
  assert.equal(pending.length,callsBefore,'saved working catalogue does not require a network preview');
  assert.ok(metadataReads>0);
  staged={download_via_proxy_section:'another-proxy'};
  const changed=context.loadOutboundNameChoices('existing'); await new Promise(setImmediate);
  assert.deepEqual([...cache.get('existing')],[],'changed download settings cannot expose old catalogue');
  pending.at(-1)({code:0,stdout:JSON.stringify({error:'Selected proxy section is unavailable'})});
  assert.deepEqual([...await changed],[],'failed changed source does not fall back to unrelated saved names');
  staged=null;
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Old runtime'],'reverting settings restores saved catalogue');
  staged={download_via_proxy_section:'pending-proxy'};
  const superseded=context.loadOutboundNameChoices('existing'); await new Promise(setImmediate);
  const obsoleteReply=pending.at(-1);
  staged=null;
  await context.loadOutboundNameChoices('existing');
  obsoleteReply({code:0,stdout:JSON.stringify({names:{a:'Obsolete draft server'}})});
  await superseded;
  assert.deepEqual([...cache.get('existing')],['Old runtime'],'late draft response cannot replace restored saved catalogue');
  staged={download_via_proxy_section:'pending-proxy'};
  const requestCount=pending.length;
  const reopened=context.loadOutboundNameChoices('existing'); await new Promise(setImmediate);
  assert.equal(pending.length,requestCount+1,'returning to discarded draft starts a fresh preview');
  assert.deepEqual([...cache.get('existing')],[]);
  pending.at(-1)({code:0,stdout:JSON.stringify({names:{a:'Fresh draft server'}})});
  assert.deepEqual([...await reopened],['Fresh draft server']);
  console.log('Editor preview: reopen during/after load, request reuse, stale response, removal, failure and retry passed');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>clearTimeout(deadline));
