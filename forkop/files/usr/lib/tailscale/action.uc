// Experimental native LuCI access. No system Tailscale packages or support state.
let fs = require('fs');
let locks = require('core.locks');
let core_ip = require('core.ip');
let xrust = require('xrust.binary');
const DIR = '/var/run/forkop/ui-state';
const AUTH = DIR + '/tailscale-auth';
const STATUS = DIR + '/tailscale-status.json';
const START_DEADLINE = DIR + '/tailscale-start-deadline';
const CONTROL_LOCK = '/tmp/forkop-tailscale-native-action.lock';
const INIT = '/etc/init.d/forkop-tailscale';
const STATE = '/etc/forkop-tailscale';
// LuCI polls this every few seconds. The answers depend only on these files,
// so the five processes behind them run again only when one changes.
const CAPABILITIES = DIR + '/tailscale-capabilities.json';
function stamp(path) { let s = fs.stat(path); return s ? join(':', [s.inode, s.size, s.mtime, s.ctime]) : '-'; }
let capability_key = join('|', map([xrust.PATH,
    '/usr/lib/forkop/core/constants.uc', '/usr/lib/forkop/tailscale/compat.uc'], stamp));
let capabilities = null;
try { capabilities = json(fs.readfile(CAPABILITIES) || 'null'); } catch (e) {}
if (type(capabilities) != 'object' || capabilities.key != capability_key) {
    let rust = fs.stat(xrust.PATH) != null;
    let version = system('ucode /usr/lib/forkop/tailscale/compat.uc check >/dev/null 2>&1') == 0;
    let native = version && rust && system('/usr/bin/xrust tailscale-native-capability >/dev/null 2>&1') == 0;
    capabilities = {key:capability_key, rust_selected:rust, version_supported:version, available:native,
        ssh_available: native && system('/usr/bin/xrust tailscale-ssh-capability >/dev/null 2>&1') == 0,
        exit_available: native && system('/usr/bin/xrust tailscale-exit-capability >/dev/null 2>&1') == 0};
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

function mark_connecting() {
    return fs.writefile(START_DEADLINE, '' + (int(clock(true)[0]) + 20)) != null &&
        fs.writefile(STATUS, '{"state":"connecting"}') != null;
}

function start_pending() {
    try {
        return json(fs.readfile(STATUS) || '{}').state == 'connecting' &&
            int(fs.readfile(START_DEADLINE) || 0) > int(clock(true)[0]);
    } catch (e) { return false; }
}

function native_flag_write(path, contents) {
    if (contents == null) return fs.unlink(path) || fs.stat(path) == null;
    let temporary = path + '.new';
    let saved = fs.writefile(temporary, contents) != null && fs.chmod(temporary, 0600) && fs.rename(temporary, path);
    if (!saved) fs.unlink(temporary);
    return saved;
}

function change_native_setting(path, contents) {
    if (start_pending()) return 'Tailscale connection is already starting';
    fs.mkdir(STATE, 0700);
    let previous = fs.readfile(path);
    if (!fs.chmod(STATE, 0700) || (previous == null && fs.stat(path) != null))
        return 'Could not read the previous Tailscale settings';
    if (previous == contents) return '';
    if (!native_flag_write(path, contents)) return 'Could not save the Tailscale settings';
    if (fs.stat(STATE + '/enabled') == null) return '';

    if (system(INIT + ' stop >/dev/null 2>&1') != 0) {
        return native_flag_write(path, previous)
            ? 'Could not stop Tailscale. The previous setting was restored.'
            : 'Could not stop Tailscale or restore the previous setting.';
    }
    if (mark_connecting() && system(INIT + ' start >/dev/null 2>&1') == 0) return '';
    if (native_flag_write(path, previous) && mark_connecting() && system(INIT + ' start >/dev/null 2>&1') == 0)
        return 'Tailscale did not start with the new setting. The previous setting was restored.';
    fs.writefile(STATUS, '{"state":"error"}');
    return 'Tailscale did not start and could not recover the previous connection.';
}

function run_native_action(operation, failure_message) {
    let pid = match(fs.readfile('/proc/self/stat') || '', /^[1-9][0-9]*/)?.[0];
    if (!locks.acquire(CONTROL_LOCK, pid)) {
        result({state:'error', message:'Another Tailscale operation is running'});
        exit(0);
    }
    let outcome;
    try { outcome = operation(); }
    catch (e) { outcome = {state:'error', message:failure_message}; }
    locks.release(CONTROL_LOCK);
    if (outcome) { result(outcome); exit(0); }
}

function apply_native_setting(path, contents) {
    run_native_action(() => {
        let message = change_native_setting(path, contents);
        return message ? {state:'error', message} : null;
    }, 'Could not change the Tailscale settings');
}

function private_lan_routes(lan) {
    if (lan?.up !== true || !match(lan.l3_device || '', /^[A-Za-z0-9_.-]+$/))
        return null;
    let routes = [];
    for (let entry in (lan['ipv4-address'] || [])) {
        if (!core_ip.valid_ipv4(entry.address, false, true)) continue;
        let parts = map(split(entry.address, '.'), part => int(part, 10));
        let prefix = int(entry.mask);
        let minimum = parts[0] == 10 ? 8 : (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 ? 12 :
            (parts[0] == 192 && parts[1] == 168 ? 16 : 33));
        if (prefix < minimum || prefix > 30) continue;
        let network = [];
        for (let i = 0; i < 4; i++) {
            let bits = prefix - i * 8;
            push(network, bits >= 8 ? parts[i] : (bits <= 0 ? 0 : parts[i] & (256 - (1 << (8 - bits)))));
        }
        let route = join('.', network) + '/' + prefix;
        if (index(routes, route) < 0) push(routes, route);
    }
    return length(routes) ? {device:lan.l3_device, routes:sort(routes)} : null;
}

function configured_lan_routes() {
    let pipe = fs.popen('ubus -t 2 call network.interface.lan status 2>/dev/null', 'r');
    if (!pipe) return null;
    let output = pipe.read('all');
    if (pipe.close() != 0) return null;
    try { return private_lan_routes(json(output)); }
    catch (e) { return null; }
}
function connect_native(staged) {
    if (!available) return { state:'unavailable' };
    if (start_pending())
        return { state:'error', message:'Tailscale connection is already starting' };

    let key = '';
    if (staged) {
        let info = match(staged, /^\/tmp\/forkop-tailscale-connect\.[A-Za-z0-9]{6}\/input$/)
            ? fs.lstat(staged) : null;
        if (info?.type != 'file' || info.uid != 0 || (info.mode & 0777) != 0600 || info.size > 256)
            return { state:'error', message:'Invalid Tailscale auth input' };
        key = trim(fs.readfile(staged) || '');
        fs.unlink(staged);
    }
    if (length(key) && !match(key, /^tskey-auth-[A-Za-z0-9-]+$/))
        return { state:'error', message:'Некорректный ключ Tailscale' };
    if (!length(key) && !fs.stat(STATE + '/tailscale.state'))
        return { state:'error', message:'Введите ключ Tailscale' };

    fs.mkdir(STATE, 0700);
    if (!fs.chmod(STATE, 0700) || system(INIT + ' stop >/dev/null 2>&1') != 0)
        return { state:'error', message:'Could not prepare Tailscale connection' };
    if (length(key)) {
        let file = fs.open(AUTH, 'w', 0600);
        if (!file)
            return { state:'error', message:'Не удалось передать ключ' };
        let written = file.write(key);
        file.close();
        if (written != length(key) || !fs.chmod(AUTH, 0600)) {
            fs.unlink(AUTH);
            return { state:'error', message:'Не удалось передать ключ' };
        }
    }
    fs.writefile(STATE + '/enabled', '1');
    let marked = mark_connecting();
    system(INIT + ' enable >/dev/null 2>&1');
    if (!marked || system(INIT + ' start >/dev/null 2>&1')) {
        fs.unlink(AUTH);
        fs.unlink(STATE + '/enabled');
        fs.writefile(STATUS, '{"state":"error"}');
    }
    return null;
}

if (action == 'connect') {
    run_native_action(() => connect_native(ARGV[1]), 'Tailscale connection failed');
} else if (action == 'disconnect') {
    run_native_action(() => {
        let disabled = native_flag_write(STATE + '/enabled', null);
        let stopped = system(INIT + ' stop >/dev/null 2>&1') == 0;
        let boot_disabled = system(INIT + ' disable >/dev/null 2>&1') == 0;
        return disabled && stopped && boot_disabled ? null : {state:'error', message:'Could not fully disconnect Tailscale'};
    }, 'Could not disconnect Tailscale');
} else if (action == 'ssh' || action == 'exit') {
    if (!(action == 'ssh' ? ssh_available : exit_available) || (ARGV[1] != '0' && ARGV[1] != '1')) exit(1);
    let flag = action == 'ssh' ? '/ssh-enabled' : '/exit-enabled';
    apply_native_setting(STATE + flag, ARGV[1] == '1' ? '1' : null);
} else if (action == 'lan') {
    if (ARGV[1] == '0') apply_native_setting(STATE + '/lan.json', null);
    else if (ARGV[1] == '1' || ARGV[1] == 'preview') {
        let lan = configured_lan_routes();
        if (lan == null) {
            result({state:'error', message:'Не удалось определить локальную IPv4-сеть'}); exit(0);
        }
        let preview_id = lan.device + ':' + join(',', lan.routes);
        if (ARGV[1] == 'preview') {
            print(sprintf('%J\n', {lan_preview_routes:lan.routes, lan_preview_id:preview_id})); exit(0);
        }
        if (ARGV[2] && ARGV[2] != preview_id) {
            result({state:'error', message:'The LAN routes changed. Review them again before enabling access.'}); exit(0);
        }
        apply_native_setting(STATE + '/lan.json', sprintf('%J', lan));
    } else exit(1);
} else if (action != 'status') { exit(1); }
let data = {state:'disconnected'};
try { data = json(fs.readfile(STATUS) || '{}'); } catch (e) {}
if (!data.state) data.state = 'disconnected';
if (data.state == 'connected' || data.state == 'reconnecting' || data.state == 'connecting') {
    let pipe = fs.popen("ubus -t 2 call service list '{\"name\":\"forkop-tailscale\"}'", 'r');
    let running = false;
    if (pipe) {
        try {
            let services = json(pipe.read('all'));
            for (let name, instance in services['forkop-tailscale']?.instances)
                if (instance.running) running = true;
        } catch (e) {}
        pipe.close();
    }
    if (!running && !start_pending()) {
        data.state = 'error';
        data.message ||= 'Tailscale service is not running';
    }
}
data.available = available;
data.saved_identity = fs.stat(STATE + '/tailscale.state') != null;
result(data);
