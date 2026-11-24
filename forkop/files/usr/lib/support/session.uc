// Temporary support sessions. Credentials never enter argv, UCI or status output.
let fs = require('fs');
const DIR = '/var/run/forkop/support';
const SERVICE = '/etc/init.d/forkop-support';
const LITE = '/usr/lib/forkop-support';
const CANCELLED = DIR + '/cancelled';

function lite_installed() {
    return fs.lstat(LITE)?.type == 'directory' && fs.stat(LITE + '/.forkop-lite')?.type == 'file' && fs.stat(LITE + '/tailscale')?.type == 'file' && fs.stat(LITE + '/tailscaled')?.type == 'file';
}

function output(command) {
    let p = fs.popen('(' + command + ') 2>/dev/null', 'r');
    if (!p) return '';
    let value = p.read('all');
    return p.close() == 0 ? trim(value || '') : '';
}
function read_json(path) {
    try { return json(fs.readfile(path) || '{}'); } catch (e) { return {}; }
}
function version(command, path, cache) {
    let info = fs.stat(path);
    if (!info) return '';
    let stamp = join(':', [path, info.dev, info.inode, info.size, info.mtime, info.ctime]);
    let previous = read_json(cache);
    if (previous?.stamp == stamp && previous.version) return previous.version;
    let value = trim(split(output(command + ' version'), '\n')[0] || '');
    if (value) {
        if (!fs.stat(DIR)) { fs.mkdir('/var/run/forkop'); fs.mkdir(DIR, 0700); }
        let tmp = cache + '.' + fs.readlink('/proc/self');
        if (fs.writefile(tmp, sprintf('%J', {stamp, version:value})) != null && !fs.rename(tmp, cache))
            fs.unlink(tmp);
    }
    return value;
}
function uptime() { return int(split(fs.readfile('/proc/uptime') || '0', ' ')[0]); }
function available() {
    return lite_installed() || (output('command -v tailscale') != '' && output('command -v tailscaled') != '');
}
function packaged() {
    return system('(if command -v apk >/dev/null 2>&1; then apk info -e tailscale; else opkg status tailscale | grep -q "Status: install ok installed"; fi) >/dev/null 2>&1') == 0;
}
function primary_enabled() {
    return system('/etc/init.d/tailscale enabled >/dev/null 2>&1') == 0;
}
function primary_running() {
    for (let path in fs.glob('/proc/[0-9]*/cmdline')) {
        // procfs argv is NUL-separated; regexp replacement truncates at NUL.
        let args = split(fs.readfile(path) || '', chr(0));
        if (match(args[0] || '', /(^|\/)tailscaled$/) && index(join(' ', args), DIR + '/socket') == -1)
            return true;
    }
    return false;
}
function session_service_running() {
    let running = output("ubus -t 2 call service list '{\"name\":\"forkop-support\"}'");
    try {
        let services = json(running);
        if (type(services) != 'object') return null;
        let service = services['forkop-support'];
        for (let name, instance in service?.instances || {})
            if (instance.running) return true;
    } catch (e) { return null; }
    return false;
}
function status() {
    let state = read_json(DIR + '/status.json');
    let active = session_service_running() === true;
    // A completed attempt from the old package installer is not current Lite state.
    // Never discard the status of a running operation.
    if (!active && state.schema != 2) state = {};
    let cancelled = fs.stat(CANCELLED) != null;
    let managed = packaged();
    let lite = lite_installed();
    let system_path = output('command -v tailscale');
    let system_installed = system_path != '';
    let primary = primary_running();
    let lite_version = lite ? version(LITE + '/tailscale', LITE + '/tailscale', DIR + '/lite-version.json') : '';
    let system_version = system_installed ? version('tailscale', system_path, DIR + '/system-version.json') : '';
    let result = {
        installed: lite || (system_installed && output('command -v tailscaled') != ''),
        package_installed: managed,
        lite_installed: lite,
        system_installed,
        lite_version,
        system_version,
        removable: !active && (lite || (managed && !primary && !primary_enabled())),
        version: lite ? lite_version : system_version,
        primary_running: primary,
        active,
        phase: cancelled ? 'stopped' : (active ? (state.phase || 'starting') : (state.phase == 'failed' ? 'failed' : 'stopped')),
        session_id: state.session_id || '',
        recovery_attempts: int(state.recovery_attempts || 0),
        error: state.error || '',
        free_kib: int(state.free_kib || 0),
        required_kib: int(state.required_kib || 0),
        error_detail: '',
        remaining_seconds: active && !cancelled ? max(0, int(state.deadline || 0) - uptime()) : 0,
        address: active && !cancelled && state.phase == 'connected' && match(state.address || '', /^100\.[0-9]+\.[0-9]+\.[0-9]+$/) ? state.address : ''
    };
    if (result.phase == 'failed') {
        let detail = fs.open(DIR + '/auth-detail.txt', 'r');
        if (detail) {
            result.error_detail = detail.read(4096) || '';
            detail.close();
        }
    }
    if (result.phase == 'failed' && index(['Tailscale installation failed', 'Tailscale Lite installation failed', 'Tailscale Lite download failed', 'Tailscale Lite is unavailable for this architecture'], state.error) != -1) {
        let log = fs.open(DIR + '/package.log', 'r');
        if (log) {
            result.error_detail = log.read(4096) || '';
            log.close();
        }
    }
    return result;
}
function request(data) {
    if (type(data) != 'object') die('Invalid request');
    if (data.operation == 'status') return status();
    if (data.operation == 'announce') {
        let current = status();
        let granted = false;
        if (current.active && current.phase == 'connected' && current.remaining_seconds > 0 &&
            data.session_id == current.session_id && match(current.session_id, /^[a-f0-9-]{36}$/)) {
            // Atomic, RAM-only acknowledgement shared by all browser tabs.
            // Independent of browser storage and of worker status rewrites.
            granted = fs.mkdir(DIR + '/announced.' + current.session_id, 0700);
        }
        current.announcement_granted = !!granted;
        return current;
    }
    if (index(['stop', 'start', 'install', 'remove'], data.operation) == -1) die('Invalid operation');
    if (!fs.stat(DIR)) {
        if (data.operation == 'stop') return status();
        fs.mkdir('/var/run/forkop');
        fs.mkdir(DIR, 0700);
    }
    if (!fs.chmod(DIR, 0700)) die('Cannot prepare support directory');
    // Serialize request handoff and stale-lock reclamation between LuCI tabs.
    let guard = fs.open(DIR + '/request.guard', 'a', 0600);
    if (!guard || !guard.lock('x')) die('Cannot lock support operation');
    let lock = fs.stat(DIR + '/lock');
    if (lock && int(clock()[0]) - lock.mtime >= 15 && session_service_running() === false)
        fs.rmdir(DIR + '/lock');
    if (data.operation == 'stop') {
        let current = read_json(DIR + '/status.json');
        if (index(['install', 'remove'], trim(fs.readfile(DIR + '/operation') || '')) != -1 &&
            fs.stat(DIR + '/lock') != null)
            die('Wait for the package operation to finish');
        if (fs.stat(DIR) == null)
            return status();
        if (fs.writefile(CANCELLED, '1\n') == null)
            die('Cannot revoke support authorization');
        fs.unlink(DIR + '/auth.key');
        if (system('exec ' + SERVICE + ' stop >/dev/null 2>&1', 8000) != 0)
            die('Support authorization was revoked but service stop did not complete');
        fs.rmdir(DIR + '/lock');
        if (match(current.session_id || '', /^[a-f0-9-]{36}$/))
            fs.rmdir(DIR + '/announced.' + current.session_id);
        fs.writefile(DIR + '/status.json', '{"phase":"stopped"}');
        return status();
    }
    if (fs.stat('/var/run/forkop/component-action.lock') != null ||
        fs.stat('/var/run/forkop/package-upgrade.quiesce') != null ||
        fs.stat('/tmp/forkop-full-uninstall.lock') != null)
        die('Wait for the current package operation to finish');
    if (status().active) die('A support operation is already running');
    if (data.operation == 'start') {
        if (!available()) die('Install Tailscale first');
        if (output('command -v dropbear') == '') die('Dropbear SSH is required');
        if (type(data.auth_key) != 'string' || !match(data.auth_key, /^tskey-auth-[A-Za-z0-9-]{20,200}$/))
            die('Invalid Tailscale auth key');
        if (data.consent != 'full-router-access') die('Explicit consent is required');
    } else if (data.operation == 'remove') {
        if (data.consent != 'remove-tailscale-package') die('Explicit removal consent is required');
        if (!lite_installed()) {
            if (!packaged()) die('Tailscale is not managed by the package manager');
            if (primary_running() || primary_enabled()) die('Stop and disable the existing Tailscale service before removing it');
        }
    } else if (available()) {
        return status();
    } else if (primary_running()) {
        die('An existing Tailscale process needs manual inspection');
    }
    if (!fs.mkdir(DIR + '/lock', 0700)) die('A support operation is already starting');
    try {
        let previous = read_json(DIR + '/status.json');
        if (match(previous.session_id || '', /^[a-f0-9-]{36}$/))
            fs.rmdir(DIR + '/announced.' + previous.session_id);
        fs.writefile(DIR + '/operation', data.operation);
        fs.unlink(CANCELLED);
        if (data.operation == 'start') {
            if (system(SERVICE + ' enable >/dev/null 2>&1') != 0) die('Cannot enable boot cleanup');
            let file = fs.open(DIR + '/auth.key', 'w', 0600);
            if (!file) die('Cannot create temporary credential');
            file.write(data.auth_key);
            file.close();
        }
        fs.writefile(DIR + '/status.json', sprintf('%J', {
            schema: 2,
            session_id: trim(fs.readfile('/proc/sys/kernel/random/uuid') || ''),
            phase: data.operation == 'install' ? 'installing' : (data.operation == 'remove' ? 'removing' : 'starting'),
            deadline: uptime() + 1800
        }));
        if (system(SERVICE + ' start >/dev/null 2>&1') != 0) die('Cannot start support service');
    } catch (e) {
        fs.unlink(DIR + '/auth.key');
        fs.rmdir(DIR + '/lock');
        die('Cannot start support operation');
    }
    return status();
}
return { request, status };
