// Experimental native LuCI access. No system Tailscale packages or support state.
let fs = require('fs');
const DIR = '/var/run/forkop/ui-state';
const AUTH = DIR + '/tailscale-auth';
const STATUS = DIR + '/tailscale-status.json';
const INIT = '/etc/init.d/forkop-tailscale';
const STATE = '/etc/forkop-tailscale';
// LuCI polls this every few seconds. The answers depend only on these files,
// so the five processes behind them run again only when one changes.
const CAPABILITIES = DIR + '/tailscale-capabilities.json';
function stamp(path) { let s = fs.stat(path); return s ? join(':', [s.inode, s.size, s.mtime, s.ctime]) : '-'; }
let capability_key = join('|', map(['/etc/forkop/sing-box-variant', '/usr/lib/rust-x/sing-box',
    '/usr/lib/forkop/core/constants.uc', '/usr/lib/forkop/tailscale/compat.uc'], stamp));
let capabilities = null;
try { capabilities = json(fs.readfile(CAPABILITIES) || 'null'); } catch (e) {}
if (type(capabilities) != 'object' || capabilities.key != capability_key) {
    let rust = trim(fs.readfile('/etc/forkop/sing-box-variant') || '') == 'rust-x';
    let version = system('ucode /usr/lib/forkop/tailscale/compat.uc check >/dev/null 2>&1') == 0;
    let native = version && rust && system('/usr/lib/rust-x/sing-box tailscale-native-capability >/dev/null 2>&1') == 0;
    capabilities = {key:capability_key, rust_selected:rust, version_supported:version, available:native,
        ssh_available: native && system('/usr/lib/rust-x/sing-box tailscale-ssh-capability >/dev/null 2>&1') == 0,
        exit_available: native && system('/usr/lib/rust-x/sing-box tailscale-exit-capability >/dev/null 2>&1') == 0};
    fs.mkdir(DIR);
    if (fs.writefile(CAPABILITIES + '.new', sprintf('%J', capabilities)) != null)
        fs.rename(CAPABILITIES + '.new', CAPABILITIES);
}
let rust_selected = capabilities.rust_selected === true;
let version_supported = capabilities.version_supported === true;
let available = capabilities.available === true;
let ssh_available = capabilities.ssh_available === true;
let exit_available = capabilities.exit_available === true;
let action = ARGV[0];
const EVENTS = DIR + '/tailscale-events.json';
function connection_events(data) {
    let history = {signature:'', entries:[]};
    try { history = json(fs.readfile(EVENTS) || '{}'); } catch (e) {}
    if (type(history.entries) != 'array') history.entries = [];
    let cleaned = false;
    const waiting = '. LAN ожидает подключения или одобрения маршрута';
    for (let entry in history.entries) {
        let message = replace(entry.message || '', waiting, '');
        if (message != entry.message) { entry.message = message; cleaned = true; }
    }
    history.signature = replace(history.signature || '', waiting, '');
    let labels = {connecting:'Подключение к Tailscale', connected:'Соединение установлено', reconnecting:'Восстановление соединения', disconnected:'Соединение отключено', error:'Ошибка подключения', unavailable:'Нативный Tailscale недоступен'};
    let message = labels[data.state] || 'Состояние неизвестно';
    if (data.ip && data.state == 'connected') message += ': ' + data.ip;
    if (data.message) message += '. ' + data.message;
    if (data.lan_enabled && data.state != 'disconnected' && data.routes_approved) message += '. Доступ к LAN разрешён';
    if (data.exit_enabled && data.state == 'connected') message += data.exit_approved ? '. Exit Node одобрен' : '. Exit Node ожидает одобрения';
    let signature = message;
    if (history.signature != signature) {
        push(history.entries, {time:time(), message});
        while (length(history.entries) > 100) shift(history.entries);
        history.signature = signature;
        cleaned = true;
    }
    if (cleaned) {
        fs.writefile(EVENTS + '.new', sprintf('%J', history));
        fs.rename(EVENTS + '.new', EVENTS);
    }
    return history.entries;
}
function result(data) {
    data.available = available;
    data.rust_selected = rust_selected;
    data.version_supported = version_supported;
    data.minimum_forkop = '2.3.4';
    data.saved_identity = fs.stat(STATE + '/tailscale.state') != null;
    data.ssh_available = ssh_available;
    data.exit_available = exit_available;
    data.exit_enabled = fs.stat(STATE + '/exit-enabled') != null;
    data.ssh_enabled = fs.stat(STATE + '/ssh-enabled') != null;
    data.lan_enabled = fs.stat(STATE + '/lan.json') != null;
    if (data.lan_enabled) {
        try { data.lan_routes = json(fs.readfile(STATE + '/lan.json')).routes; } catch (e) {}
    }
    data.events = connection_events(data);
    print(sprintf('%J\n', data));
}
if (action == 'connect') {
    if (!available) { fs.unlink(AUTH); fs.unlink(DIR + '/tailscale-auth-input'); result({state:'unavailable'}); exit(0); }
    fs.mkdir(STATE, 0700);
    fs.chmod(STATE, 0700);
    // stop deletes stale auth: UI staging file is separate from worker input.
    let staged = DIR + '/tailscale-auth-input';
    let key = trim(fs.readfile(staged) || '');
    fs.unlink(staged);
    if (length(key) && (length(key) > 256 || !match(key, /^tskey-auth-[A-Za-z0-9-]+$/))) {
        result({state:'error', message:'Некорректный ключ Tailscale'}); exit(0);
    }
    if (!length(key) && !fs.stat(STATE + '/tailscale.state')) {
        result({state:'error', message:'Введите ключ Tailscale'}); exit(0);
    }
    system(INIT + ' stop >/dev/null 2>&1');
    if (length(key)) {
        let f = fs.open(AUTH, 'w', 0600);
        if (!f) { result({state:'error', message:'Не удалось передать ключ'}); exit(0); }
        f.write(key); f.close(); fs.chmod(AUTH, 0600);
    }
    fs.writefile(STATE + '/enabled', '1');
    fs.writefile(STATUS, '{"state":"connecting"}');
    system(INIT + ' enable >/dev/null 2>&1');
    let code = system(INIT + ' start >/dev/null 2>&1');
    if (code) { fs.unlink(AUTH); fs.unlink(STATE + '/enabled'); fs.writefile(STATUS, '{"state":"error"}'); }
} else if (action == 'disconnect') {
    fs.unlink(STATE + '/enabled');
    fs.unlink(DIR + '/tailscale-auth-input');
    system(INIT + ' stop >/dev/null 2>&1');
    system(INIT + ' disable >/dev/null 2>&1');
} else if (action == 'ssh' || action == 'exit') {
    if (!(action == 'ssh' ? ssh_available : exit_available) || (ARGV[1] != '0' && ARGV[1] != '1')) exit(1);
    let flag = action == 'ssh' ? '/ssh-enabled' : '/exit-enabled';
    fs.mkdir(STATE, 0700); fs.chmod(STATE, 0700);
    if (ARGV[1] == '1') {
        fs.writefile(STATE + flag, '1'); fs.chmod(STATE + flag, 0600);
    } else { fs.unlink(STATE + flag); }
    if (fs.stat(STATE + '/enabled')) {
        system(INIT + ' stop >/dev/null 2>&1');
        fs.writefile(STATUS, '{"state":"connecting"}');
        system(INIT + ' start >/dev/null 2>&1');
    }
} else if (action == 'lan') {
    if (ARGV[1] != '0' && ARGV[1] != '1') { exit(1); }
    fs.mkdir(STATE, 0700); fs.chmod(STATE, 0700);
    if (ARGV[1] == '1') {
        let p = fs.popen('ubus call network.interface.lan status', 'r');
        let lan;
        try { lan = json(p.read('all')); } catch (e) { lan = {}; }
        if (p) p.close();
        let routes = [];
        for (let entry in lan['ipv4-address']) {
            let parts = split(entry.address, '.');
            let prefix = int(entry.mask);
            if (length(parts) != 4 || prefix < 8 || prefix > 30) continue;
            let a = int(parts[0]), b = int(parts[1]);
            if (!(a == 10 || a == 192 && b == 168 || a == 172 && b >= 16 && b <= 31)) continue;
            let network = [];
            for (let i = 0; i < 4; i++) {
                let bits = prefix - i * 8;
                push(network, bits >= 8 ? int(parts[i]) : bits <= 0 ? 0 : int(parts[i]) & (256 - (1 << (8 - bits))));
            }
            push(routes, join('.', network) + '/' + prefix);
        }
        if (!lan.up || !length(routes) || !match(lan.l3_device || '', /^[A-Za-z0-9_.-]+$/)) {
            result({state:'error', message:'Не удалось определить локальную IPv4-сеть'}); exit(0);
        }
        fs.writefile(STATE + '/lan.json.new', sprintf('%J', {device:lan.l3_device, routes}));
        fs.chmod(STATE + '/lan.json.new', 0600); fs.rename(STATE + '/lan.json.new', STATE + '/lan.json');
    } else { fs.unlink(STATE + '/lan.json'); }
    if (fs.stat(STATE + '/enabled')) {
        system(INIT + ' stop >/dev/null 2>&1');
        fs.writefile(STATUS, '{"state":"connecting"}');
        system(INIT + ' start >/dev/null 2>&1');
    }
} else if (action != 'status') { exit(1); }
let data = {state:'disconnected'};
try { data = json(fs.readfile(STATUS) || '{}'); } catch (e) {}
if (!data.state) data.state = 'disconnected';
if (data.state == 'connected' || data.state == 'reconnecting' || data.state == 'connecting') {
    let pipe = fs.popen("ubus call service list '{\"name\":\"forkop-tailscale\"}'", 'r');
    let running = false;
    if (pipe) {
        try {
            let services = json(pipe.read('all'));
            for (let name, instance in services['forkop-tailscale']?.instances)
                if (instance.running) running = true;
        } catch (e) {}
        pipe.close();
    }
    // Starting procd is asynchronous; leave the initial status to the worker.
    if (!running && data.state != 'connecting') data.state = 'error';
}
data.available = available;
data.saved_identity = fs.stat(STATE + '/tailscale.state') != null;
result(data);
