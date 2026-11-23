const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const text = fs.readFileSync(process.argv[2] || require('node:path').join(__dirname,'../luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js'), 'utf8');
const code = text.slice(text.indexOf('const editorPreviewStates ='), text.indexOf('function normalizeDynamicListItems'));
let urls = ['https://example.com/first'];
let saved = {};
let staged = null;
let pendingChanges = [];
let removalLookupAvailable = true;
const localChanges = {};
const localDeletes = {};
let runtimeNames = {old:'Old runtime'};
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
  uci: {
    state: {changes: {forkop: localChanges}, deletes: {forkop: localDeletes}, values: {forkop: saved}},
    get: (_p,id) => saved[id] && {...saved[id], ...localChanges[id]},
    set: (_p, id, key, val) => { (localChanges[id] ||= {})[key] = val; },
    changes: async () => ({forkop: pendingChanges}),
  },
  document: {getElementById: () => status},
  getChildItemIds: () => Object.keys(saved).filter(id => !localDeletes[id]),
  plainObject: x => x || {}, refreshDashboardFilterChoiceWidgets() {},
  currentDraftOutboundNames: () => ['Manual server'],
  normalizeDynamicListItems: values => values,
  uniqueDynamicListItems: values => [...new Set(values)],
  optionMapValue: () => ['Saved server'],
  _: value => value,
  readOutboundMetadataFromSectionCache: async () => { metadataReads++; return {names:runtimeNames}; },
  fs: {
    write:async()=>{}, remove:async()=>{},
    exec: (_path, [command, section, removed]) => {
      if (command !== 'editor_removed_subscription_sources') return new Promise(resolve=>pending.push(resolve));
      const affected = section === 'existing' && JSON.parse(removed).includes('source1');
      return Promise.resolve(removalLookupAvailable ? {code:0, stdout:JSON.stringify({affected})} : {code:1, stdout:''});
    },
  },
};
vm.createContext(context);
vm.runInContext(code,context);
vm.runInContext(text.match(/^function applyChildItemSettings\([\s\S]*?^}/m)[0], context);
vm.runInContext(text.match(/^function currentOutboundNameChoices\([\s\S]*?^}/m)[0], context);
vm.runInContext(text.match(/^function configureServerNameChoices\([\s\S]*?^}/m)[0], context);
const deadline=setTimeout(()=>{console.error('Editor preview test timed out');process.exit(1);},10000);
(async()=>{
  const option = { option: 'include_outbounds' };
  context.configureServerNameChoices(option, () => 'new', true);
  assert.deepEqual([...option.load('id')], ['Saved server']);
  assert.equal(pending.length, 0, 'modal options load before making a network preview');
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
  saved = {source1:{'.name':'source1','.type':'subscription_url',section:'existing',url:'https://example.com/saved',download_via_proxy_enabled:'1',download_via_proxy_section:'proxy'}};
  context.uci.state.values.forkop = saved;
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
  staged=null;
  await context.loadOutboundNameChoices('existing');
  const requestsBeforeScheduleChange=pending.length;
  staged={subscription_update_enabled:'0',subscription_update_interval:'8h'};
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Old runtime'],
    'draft scheduling fields keep the active catalogue');
  staged=null;
  context.applyChildItemSettings('source1', {subscription_update_interval:'8h'});
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Old runtime'],
    'editing the schedule in an existing source keeps the active catalogue');
  Object.assign(saved.source1, localChanges.source1);
  delete localChanges.source1;
  pendingChanges=[['set','source1','subscription_update_interval','8h'],
    ['remove','source1','subscription_update_enabled']];
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Old runtime'],
    'saving only scheduling changes keeps the active catalogue');
  assert.equal(pending.length,requestsBeforeScheduleChange,
    'changing the update schedule never needs another subscription download');
  pendingChanges=[];

  context.applyChildItemSettings('source1', {prefix_nodes:'1', node_prefix:'Prefix'});
  const prefixChange=context.loadOutboundNameChoices('existing');
  await new Promise(setImmediate);
  assert.deepEqual([...cache.get('existing')],[],'existing child UCI edits invalidate the runtime catalogue');
  pending.at(-1)({code:0,stdout:JSON.stringify({names:{a:'Prefix Old runtime'}})});
  assert.deepEqual([...await prefixChange],['Prefix Old runtime']);

  // A form Save promotes local values to the session's loaded values while the
  // running configuration and its catalogue still reflect the old source.
  Object.assign(saved.source1, localChanges.source1);
  delete localChanges.source1;
  pendingChanges=[['set','source1','node_prefix','Prefix']];
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Prefix Old runtime']);
  pendingChanges=[['set','settings','language','en'], ['remove','unrelated_section']];
  runtimeNames={new:'Applied catalogue'};
  const callsBeforeApply=pending.length;
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Applied catalogue'],'applied sources use runtime metadata again');
  assert.equal(pending.length,callsBeforeApply,'unrelated staged changes and removal preserve the offline catalogue');
  removalLookupAvailable=false;
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],['Applied catalogue'],
    'an unavailable ownership lookup preserves the existing subscription catalogue');
  removalLookupAvailable=true;

  urls=[];
  const callsAfterPrefix=pending.length;
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],[],'removal hides the applied subscription catalogue before Apply');
  assert.equal(pending.length,callsAfterPrefix,'a removed source is not downloaded');
  assert.deepEqual([...context.currentOutboundNameChoices('existing',['Previously selected'])].map(choice => choice.value),
    ['Manual server','Previously selected'],'manual and already selected names remain available');
  localDeletes.source1=true;
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],[],'removal remains excluded after staging it through the UCI form');
  delete localDeletes.source1;
  saved={};
  context.uci.state.values.forkop = saved;
  pendingChanges=[['remove','source1']];
  assert.deepEqual([...await context.loadOutboundNameChoices('existing')],[],'a server-staged source removal cannot restore old names');
  console.log('Editor preview: reopen during/after load, request reuse, stale response, removal, failure and retry passed');
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>clearTimeout(deadline));
