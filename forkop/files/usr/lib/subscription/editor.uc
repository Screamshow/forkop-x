// Draft-only subscription catalogue. Never commits UCI or applies a runtime.
let fs = require('fs');
let common = require('core.common');
let root = getenv('FORKOP_EDITOR_STATE_DIR') || '/var/run/forkop/ui-state';
let lib = getenv('FORKOP_LIB') || '/usr/lib/forkop';
let id = ARGV[1] || '';
if (ARGV[0] != 'preview' || !match(id, /^editor-[a-z0-9-]{8,80}$/)) exit(1);
let request = root + '/' + id + '.json';
let raw = fs.readfile(request);
fs.unlink(request);
let input;
try { input = json(raw || ''); } catch (e) { exit(1); }
let sources = input.sources;
if (type(sources) != 'array' || length(sources) > 16) exit(1);
let dir = root + '/' + id;
if (!common.secure_private_dir(dir)) exit(1);
function q(value) { return "'" + replace(value, /'/g, "'\\''") + "'"; }
let last_status = 0;
function run(args) {
    let cmd = '';
    for (let a in args) cmd += (cmd == '' ? '' : ' ') + q('' + a);
    last_status = system(cmd + ' >' + q(dir + '/operation.log') + ' 2>&1');
    return last_status == 0;
}
function write(path, value) { return common.write_private_json_file(path, value); }
function cleanup() {
    // Only our generated tree; no caller-controlled paths.
    system('rm -rf ' + q(dir));
}
function fail(message) { cleanup(); print(sprintf('%J\n', {error:message, status:last_status})); exit(0); }
let fixture = {settings:{}, section:[{'.name':'editor', '.type':'section', enabled:'1', action:'connection'}], subscription_url:[]};
for (let i = 0; i < length(sources); i++) {
    let source = sources[i];
    let url = source.url;
    if (type(url) != 'string' || length(url) > 8192 || !match(url, /^https?:\/\//) || match(url, /[[:space:]]/)) fail('Invalid subscription URL');
    let prefix = dir + '/editor-subscription-' + (i + 1);
    if (!write(dir + '/download.json', {source, section: input.section})) fail('Cannot prepare subscription request');
    if (!run(['ucode','-L',lib,lib+'/subscription/cache.uc','editor-download-source',dir+'/download.json',prefix])) fail('Cannot download subscription');
    let profile = json(fs.readfile(prefix+'.profile.json') || '{}');
    if (profile.error) fail(profile.error);
    let ua = profile.user_agent;
    fs.writefile(prefix+'.url',url+'\n'); fs.writefile(prefix+'.user_agent',ua+'\n');
    fs.writefile(prefix+'.hwid',profile.hwid+'\n');
    // Download detours belong to the live core, not this catalogue-only fixture.
    push(fixture.subscription_url, {...source, '.name':'source'+i, '.type':'subscription_url',section:'editor',url,user_agent:ua,
        download_via_proxy_enabled:'0',download_via_proxy_section:''});
}
if (length(sources) == 0) { cleanup(); print('{"names":{},"countries":{}}\n'); exit(0); }
write(dir+'/fixture.json',fixture);
// Generator owns protocol compatibility, group visibility, aliases and deduplication.
let cmd = 'TMP_SUBSCRIPTION_FOLDER=' + q(dir) + ' ';
cmd += 'ucode -L '+q(lib)+' '+q(lib+'/singbox/generator.uc')+' generate-config-fixture ';
let version = trim(fs.readfile(getenv('SB_VERSION_STATE_FILE') || '/etc/forkop/sing-box-version') || '');
cmd += q(dir+'/fixture.json')+' '+q(dir+'/candidate.json')+' 127.0.0.1 0 1 '+q('')+' '+q(version)+' 1 1 1';
if (system(cmd+' >'+q(dir+'/generate.log')+' 2>&1') != 0) fail('Cannot build subscription catalogue');
let state = json(fs.readfile(dir+'/candidate.json.section-cache/editor.json') || '{}');
let metadata = state.outboundMetadata || {};
let result = {names:{},countries:{}};
for (let tag in state.urltestCandidateTags || []) {
    if (metadata.names[tag] != null) result.names[tag] = metadata.names[tag];
    if (metadata.countries[tag] != null) result.countries[tag] = metadata.countries[tag];
}
cleanup();
print(sprintf('%J\n',result));
