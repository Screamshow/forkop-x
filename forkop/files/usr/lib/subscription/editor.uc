// Draft-only subscription catalogue. Never commits UCI or applies a runtime.
let fs = require('fs');
let common = require('core.common');
let root = '/var/run/forkop/ui-state';
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
if (!run(['ucode','-L','/usr/lib/forkop','/usr/lib/forkop/subscription/cache.uc','editor-request-profile'])) fail('Cannot prepare subscription request');
let profile = json(fs.readfile(dir+'/operation.log') || '{}');
for (let i = 0; i < length(sources); i++) {
    let source = sources[i];
    if (source.download_via_proxy_enabled == '1') fail('Preview via proxy is not available in this test build');
    let url = source.url;
    if (type(url) != 'string' || length(url) > 8192 || !match(url, /^https?:\/\//) || match(url, /[[:space:]]/)) fail('Invalid subscription URL');
    let prefix = dir + '/editor-subscription-' + (i + 1);
    // curl config keeps credentials out of the process command line.
    let config = 'url = ' + sprintf('%J', url) + '\n';
    let ua = profile.user_agent;
    config += 'user-agent = ' + sprintf('%J', ua) + '\n';
    config += 'header = ' + sprintf('%J', 'X-HWID: ' + profile.hwid) + '\n';
    for (let header in profile.headers || []) config += 'header = ' + sprintf('%J', header) + '\n';
    fs.writefile(dir + '/curl.conf', config); fs.chmod(dir + '/curl.conf', 0600);
    if (!run(['curl','--config',dir+'/curl.conf','--fail','--location','--proto','=http,https','--proto-redir','=http,https','--connect-timeout','5','--max-time','20','--max-filesize','4194304','--output',prefix+'.body'])) fail('Subscription download failed');
    if (!run(['ucode','-L','/usr/lib/forkop','/usr/lib/forkop/subscription/parser.uc','normalize-content-validated',prefix+'.body',prefix+'.json'])) fail('Invalid subscription response');
    fs.writefile(prefix+'.url',url+'\n'); fs.writefile(prefix+'.user_agent',ua+'\n');
    fs.writefile(prefix+'.hwid',profile.hwid+'\n');
    push(fixture.subscription_url, {...source, '.name':'source'+i, '.type':'subscription_url',section:'editor',url,user_agent:ua});
}
if (length(sources) == 0) { cleanup(); print('{"names":{},"countries":{}}\n'); exit(0); }
write(dir+'/fixture.json',fixture);
// Generator owns protocol compatibility, group visibility, aliases and deduplication.
let cmd = 'TMP_SUBSCRIPTION_FOLDER=' + q(dir) + ' ';
cmd += 'ucode -L /usr/lib/forkop /usr/lib/forkop/singbox/generator.uc generate-config-fixture ';
let version = trim(fs.readfile('/etc/forkop/sing-box-version') || '');
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
