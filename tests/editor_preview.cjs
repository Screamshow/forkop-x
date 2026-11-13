const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const text = fs.readFileSync(require('node:path').join(__dirname,'../luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js'), 'utf8');
const code = text.slice(text.indexOf('const editorPreviewStates ='), text.indexOf('function normalizeDynamicListItems'));
let urls = ['https://example.com/first'];
const pending = [];
const cache = new Map();
let status = {textContent:''};
const context = {
  Map, Set, Date, Math, JSON,
  outboundNameChoicesCache: cache, outboundNameChoicesInflight: new Map(),
  outboundNameSourceOptions: new Map(), UCI_PACKAGE:'forkop',
  currentSourceOptionValues: () => urls,
  childItemInputValue: (_s, value) => value,
  uci: {get: () => null}, document: {getElementById: () => status},
  plainObject: x => x || {}, refreshDashboardFilterChoiceWidgets() {},
  readOutboundMetadataFromSectionCache: async () => ({names:{old:'Old runtime'}}),
  fs: {write:async()=>{}, remove:async()=>{}, exec:()=>new Promise(resolve=>pending.push(resolve))},
};
vm.createContext(context);
vm.runInContext(code,context);
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
  console.log('Editor preview: reopen during/after load, request reuse, stale response, removal, failure and retry passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
