// Requires isolated cache, runtime and FORKOP_UCI_STATE_FILE paths.
let fs = require('fs');
let common = require('core.common');
let selection = require('subscription.filter_selection');
let connections = require('config.connections');
let uci = require('core.uci');
let checks = 0;
function eq(actual, expected, message) {
    if (sprintf('%J',actual) != sprintf('%J',expected)) die('FAIL: '+message+'\n');
    checks++;
}
let key = 'synthetic-key';
let visible = {name:'Helsinki #10',key};
let hidden = {name:'proxy-15',key,hidden:true};
let previous = [visible];
let next = [hidden,visible];
let result = selection.reconcile([visible.name],[],previous,next);
eq(result.names,[visible.name],'hidden-first duplicate never added');
eq(result.records[0].keys,[key],'identity retained');
eq(selection.reconcile([visible.name],[],previous,[visible,hidden]).names,
    [visible.name],'visible-first duplicate never added');
result = selection.reconcile([hidden.name,visible.name],[],next,next);
eq(result.names,[visible.name],'existing technical duplicate repaired');
eq(result.records[0].keys,[key],'repair retains key');
eq(selection.reconcile(result.names,result.records,next,next).names,[visible.name],'repeat stable');
eq(selection.reconcile([visible.name],[],previous,[hidden]).names,[visible.name],'hidden-only keeps label');
eq(selection.reconcile([hidden.name],[],[hidden],[hidden]).names,[hidden.name],'hidden-only explicit choice retained');
eq(selection.reconcile([visible.name],[],previous,[]).records[0].keys,[key],'removal retains tombstone');
eq(selection.reconcile([visible.name],[],previous,[{...hidden,key:'different'}]).names,
    [visible.name],'different hidden connection cannot take over');
eq(selection.reconcile(['Alternate'],[],[{name:'Alternate',key}],
    [visible,{name:'Alternate',key}]).names,['Alternate'],'explicit visible alias retained');
eq(selection.reconcile(['Same'],[],[{name:'Same',key:'one'},{name:'Same',key:'two'}],
    [{name:'A',key:'one'},{name:'B',key:'two'}]).names,['A','B'],'distinct connections never merged');

let runtime = getenv('TMP_SUBSCRIPTION_FOLDER');
let cache = getenv('FORKOP_PERSISTENT_SUBSCRIPTION_CACHE_DIR');
if (!runtime || !cache || !getenv('FORKOP_UCI_CONFIG_DIR')) die('Isolated paths required\n');
fs.mkdir(runtime,0700); fs.mkdir(cache,0700);
fs.mkdir(getenv('FORKOP_UCI_CONFIG_DIR'),0700);
fs.mkdir(getenv('FORKOP_UCI_SAVE_DIR'),0700);
fs.writefile(getenv('FORKOP_UCI_CONFIG_DIR')+'/forkop','');
let source = 'https://example.invalid/fixture';
let node = {type:'vless',tag:visible.name,server:'192.0.2.15',server_port:443,uuid:'synthetic-user'};
let technical = {...node,tag:hidden.name,__forkop_hidden:true};
common.write_private_json_file(runtime+'/test-subscription-1.json',{outbounds:[technical,node]});
for (let owner in ['test','group','pg','level']) uci.set_section('forkop.'+owner,
    owner=='test'?'section':owner=='group'?'urltest':owner=='pg'?'priority_group':'priority_level');
uci.set('forkop.group.section','test'); uci.set('forkop.pg.section','test'); uci.set('forkop.level.group','pg');
function setup(values) {
    for (let owner in ['group','level']) {
        uci.set('forkop.'+owner+'.include_outbounds',values);
        uci.set('forkop.'+owner+'.exclude_outbounds',values);
    }
    connections.set_item_sections_from_data({
        subscription_url:[{'.name':'source',section:'test',url:source}],
        urltest:[{'.name':'group',section:'test',include_outbounds:values,exclude_outbounds:values}],
        priority_group:[{'.name':'pg',section:'test'}],
        priority_level:[{'.name':'level',group:'pg',include_outbounds:values,exclude_outbounds:values}]
    });
    uci.commit('forkop');
}
setup([hidden.name,visible.name]);
let section = {'.name':'test'};
let before = selection.snapshot(section);
eq(before.previous[0].hidden,true,'real candidates carry hidden flag');
result = selection.finish(before);
eq(result.ok,true,'real URLTest and Priority repair succeeds');
eq(result.changed,true,'repair writes UCI');
for (let owner in ['group','level']) for(let side in ['include','exclude'])
    eq(uci.get_all('forkop',owner)[side+'_outbounds'],[visible.name],owner+' '+side+' repaired');
setup([visible.name]);
before=selection.snapshot(section);
result=selection.finish(before);
eq(result.ok,true,'second update succeeds'); eq(result.changed,false,'second update does not add aliases');
let saved=selection.read('test');
for(let group in [selection.urltest_key(section,'group'),selection.priority_key('level')])
    for(let side in ['include','exclude']) eq(saved[group][side][0].keys,
        [selection.connection(source,node)],'binding identity preserved');
printf('PASS: hidden subscription aliases (%d checks)\n',checks);
