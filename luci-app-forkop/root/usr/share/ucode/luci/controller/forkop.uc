// Copyright 2026 Forkop contributors
// Licensed to the public under the GPL-2.0-or-later.

import { popen, readfile, stat } from 'fs';
import * as fs from 'fs';

const UI_READ_COMMANDS = {
	check_dns_available: 'check_dns_available',
	check_fakeip: 'check_fakeip',
	check_nft_rules: 'check_nft_rules',
	check_xrust: 'check_xrust',
	component_update_check_cache: 'component_update_check_cache',
	get_status: 'get_status',
	get_system_info: 'get_system_info',
	get_ui_capabilities: 'get_ui_capabilities',
	get_ui_state: 'get_ui_state',
	get_xrust_status: 'get_xrust_status',
	provider_dns: 'provider_dns',
	tailscale_native_status: 'tailscale_native_status'
};
const UI_READ_MAX_BYTES = 2097152;

function ui_read_result(code, stdout, stderr) {
	http.write(sprintf('%J', { code, stdout, stderr }));
}

function ui_read_json_file(path) {
	let info = stat(path);
	if (info?.type != 'file' || info.size > UI_READ_MAX_BYTES)
		return null;

	return json(readfile(path));
}

function ui_read_fields(value, fields) {
	let output = {};
	for (let key in fields)
		if (value?.[key] != null)
			output[key] = value[key];
	return output;
}

function ui_read_scalar(value) {
	return type(value) in ['string', 'int', 'double', 'bool'];
}

function ui_read_match_fields(value, fields) {
	let output = {};
	for (let key in fields) {
		let field = value?.[key];
		if (ui_read_scalar(field))
			output[key] = field;
		else if (type(field) == 'array')
			output[key] = filter(field, ui_read_scalar);
	}
	return output;
}

function ui_read_route_rule(rule, depth) {
	let output = ui_read_match_fields(rule, [
		'type', 'mode', 'action', 'invert', 'outbound', 'inbound', 'domain',
		'domain_suffix', 'domain_keyword', 'domain_regex', 'ip_cidr', 'source_ip_cidr',
		'ip_is_private', 'source_ip_is_private', 'ip_version', 'port', 'port_range',
		'source_port', 'source_port_range', 'network', 'protocol', 'client',
		'process_name', 'process_path', 'process_path_regex', 'package_name',
		'network_type', 'network_is_expensive', 'network_is_constrained',
		'wifi_ssid', 'wifi_bssid', 'rule_set', 'rule_set_ip_cidr_match_source'
	]);
	if (depth < 16 && type(rule?.rules) == 'array')
		output.rules = map(rule.rules, child => ui_read_route_rule(child, depth + 1));
	return output;
}

function ui_runtime_config_reference() {
	let pipe = popen('/usr/bin/forkop runtime_config_reference 2>/dev/null', 'r');
	if (!pipe) return null;
	let content = pipe.read(4096);
	if (pipe.close() != 0 || !content) return null;
	return json(content);
}

function ui_read_runtime_config(revision) {
	let reference = ui_runtime_config_reference();
	if (!reference?.path || (revision != 'legacy' && revision != reference.revision))
		return null;

	let config = ui_read_json_file(reference.path);
	if (type(config) != 'object')
		return null;

	let outbounds = [], rules = [];
	let outbound_fields = [
		'type', 'tag', 'outbounds', 'interval', 'tolerance',
		'idle_timeout', 'interrupt_exist_connections'
	];
	if (dispatched?.readonly === false)
		push(outbound_fields, 'url');
	for (let outbound in config.outbounds || [])
		if (outbound.type == 'urltest')
			push(outbounds, ui_read_match_fields(outbound, outbound_fields));
	for (let rule in config.route?.rules || [])
		push(rules, ui_read_route_rule(rule, 0));
	let latest = ui_runtime_config_reference();
	if (latest?.path != reference.path || latest.revision != reference.revision)
		return null;
	return { outbounds, route: { rules } };
}

function ui_read_section_cache(section) {
	if (type(section) != 'string' || !match(section, /^[A-Za-z0-9_-]{1,128}$/))
		return null;

	let cache = ui_read_json_file('/var/run/forkop/section-cache/' + section + '.json');
	if (type(cache) != 'object')
		return null;

	let urltestGroups = {}, priorityGroups = {};
	for (let tag, group in cache.urltestGroups || {})
		urltestGroups[tag] = ui_read_match_fields(group, [
			'displayName', 'outbounds', 'interval', 'tolerance', 'idle_timeout',
			'interrupt_exist_connections'
		]);
	for (let tag, group in cache.priorityGroups || {}) {
		let levels = [];
		for (let level in group.levels || [])
			push(levels, ui_read_match_fields(level, [
				'id', 'displayName', 'order', 'direct', 'filter_mode',
				'detect_server_country', 'outbounds'
			]));
		priorityGroups[tag] = ui_read_match_fields(group, [
			'id', 'tag', 'section', 'displayName', 'active_check_interval',
			'check_timeout', 'recovery_check_interval', 'pick_fastest',
			'switch_to_faster_same_priority', 'fastest_check_interval',
			'interrupt_exist_connections', 'pin_dashboard', 'outbounds'
		]);
		priorityGroups[tag].levels = levels;
	}
	let outboundMetadata = {};
	for (let key in ['names', 'countries']) {
		outboundMetadata[key] = {};
		for (let tag, value in cache.outboundMetadata?.[key] || {})
			if (type(value) == 'string')
				outboundMetadata[key][tag] = value;
	}
	return {
		outboundMetadata,
		urltestGroups,
		priorityGroups
	};
}

function action_ui_read() {
	http.header('Cache-Control', 'no-store');
	http.prepare_content('application/json');
	if (type(dispatched?.readonly) != 'bool') {
		http.status(403, 'Forbidden');
		ui_read_result(1, '', 'Forkop read permission is required');
		return;
	}

	let operation = http.formvalue('operation');
	let subject = http.formvalue('subject');
	try {
		if (operation == 'runtime_config' || operation == 'section_cache') {
			let result = operation == 'runtime_config'
				? ui_read_runtime_config(subject)
				: ui_read_section_cache(subject);
			ui_read_result(result == null ? 1 : 0, result == null ? '' : sprintf('%J', result), '');
			return;
		}

		let command = UI_READ_COMMANDS[operation];
		if (type(command) != 'string' || subject != null) {
			http.status(400, 'Invalid Forkop read operation');
			ui_read_result(1, '', 'Invalid Forkop read operation');
			return;
		}

		let stream = popen('/usr/bin/forkop ' + command + ' 2>/dev/null', 'r');
		if (!stream) {
			ui_read_result(1, '', 'Could not start Forkop read operation');
			return;
		}
		let output = stream.read(UI_READ_MAX_BYTES) || '';
		let code = stream.close();
		if (length(output) >= UI_READ_MAX_BYTES) {
			ui_read_result(1, '', 'Forkop read response is too large');
			return;
		}

		if (code != 0) {
			ui_read_result(code, '', 'Forkop read operation failed');
			return;
		}
		if (operation == 'get_ui_state') {
			let value = ui_read_fields(json(output), ['service', 'runtime_config', 'capabilities']);
			value.actions = { service: [], latency: [], component: [], subscription: [] };
			output = sprintf('%J', value);
		}
		ui_read_result(0, output, '');
	} catch (e) {
		ui_read_result(1, '', 'Forkop read operation failed');
	}
}

function action_ui_clash() {
	http.header('Cache-Control', 'no-store');
	http.prepare_content('application/json');
	if (type(dispatched?.readonly) != 'bool') {
		http.status(403, 'Forbidden');
		return;
	}
	let operation = http.formvalue('operation');
	if (operation != 'connections' && operation != 'proxies') {
		http.status(400, 'Invalid Clash data request');
		return;
	}

	let endpoint = popen('/usr/bin/forkop clash_api_address 2>/dev/null', 'r');
	let address = endpoint ? trim(endpoint.read(128) || '') : '';
	if (!endpoint || endpoint.close() != 0 || !match(address, /^([0-9]{1,3}\.){3}[0-9]{1,3}$/)) {
		http.status(502, 'Could not locate the running Clash controller');
		return;
	}
	let stream = popen("curl --noproxy '*' --max-time 20 -fs http://" +
		address + ':9090/' + operation + ' 2>/dev/null', 'r');
	if (!stream) {
		http.status(502, 'Could not read the Clash controller');
		return;
	}
	try {
		let chunk = stream.read(16384);
		if (!length(chunk)) {
			http.status(502, 'The Clash controller returned no data');
		}
		// Stream fixed-size chunks directly from Xrust. rpcd file.exec and JSON
		// string wrapping both impose unnecessary limits on valid snapshots.
		while (length(chunk)) {
			http.write(chunk);
			chunk = stream.read(16384);
		}
	} catch (e) {}
	stream.close();
}

function validate_ui_regex(value) {
	try {
		let patterns = json(value);
		if (type(patterns) != 'array')
			return { invalid: 0 };
		for (let index, pattern in patterns) {
			if (type(pattern) != 'string')
				return { invalid: index };
			try { regexp(pattern); }
			catch (e) { return { invalid: index }; }
		}
		return {};
	} catch (e) {
		return { invalid: 0 };
	}
}

function stage_tailscale_connect(key) {
	if (type(key) != 'string' || length(key) > 256 ||
	    (key != '' && !match(key, /^tskey-auth-[A-Za-z0-9-]+$/))) {
		ui_read_result(1, '', 'Invalid Tailscale auth key');
		return;
	}

	const template = '/tmp/forkop-tailscale-connect.XXXXXX';
	let directory;
	if (type(fs.mkdtemp) == 'function') {
		directory = fs.mkdtemp(template);
	} else {
		let create = popen('/bin/mktemp -d ' + template, 'r');
		if (create) {
			directory = trim(create.read(128) || '');
			if (create.close() != 0) directory = null;
		}
	}
	if (!match(directory || '', /^\/tmp\/forkop-tailscale-connect\.[A-Za-z0-9]{6}$/)) {
		ui_read_result(1, '', 'Could not prepare Tailscale connection');
		return;
	}

	let path = directory + '/input';
	let output = '', code = 1, worker;
	try {
		let file = fs.open(path, 'w', 0600);
		if (!file) die('Could not prepare input');
		let written = file.write(key);
		file.close();
		if (written != length(key)) die('Could not write input');

		worker = popen('/usr/bin/forkop tailscale_native_connect ' + path + ' 2>/dev/null', 'r');
		if (!worker) die('Could not start connection');
		output = worker.read(UI_READ_MAX_BYTES) || '';
		code = worker.close();
		worker = null;
	} catch (e) {
		if (worker) worker.close();
	}
	fs.unlink(path);
	fs.rmdir(directory);
	ui_read_result(code, code == 0 ? output : '', code == 0 ? '' : 'Tailscale connection failed');
}

function action_ui_write() {
	http.header('Cache-Control', 'no-store');
	http.prepare_content('application/json');
	if (dispatched?.readonly !== false) {
		http.status(403, 'Forbidden');
		ui_read_result(1, '', 'Write permission is required');
		return;
	}
	if (http.formvalue('operation') == 'validate_regex') {
		ui_read_result(0, sprintf('%J', validate_ui_regex(http.formvalue('value'))), '');
		return;
	}
	if (http.formvalue('operation') == 'tailscale_connect') {
		stage_tailscale_connect(http.formvalue('value'));
		return;
	}
	http.status(400, 'Invalid Forkop operation');
	ui_read_result(1, '', 'Invalid Forkop operation');
}

function action_support_report() {
	http.header('Cache-Control', 'no-store');
	if (dispatched?.readonly !== false) {
		http.status(403, 'Forbidden');
		http.prepare_content('text/plain; charset=UTF-8');
		http.write('Write permission is required\n');
		return;
	}

	let stream = popen(
		'/usr/bin/forkop support_report 2>&1 | /bin/gzip -c',
		'r'
	);

	if (!stream) {
		http.status(500, 'Failed to create support report');
		http.prepare_content('text/plain; charset=UTF-8');
		http.write('Failed to start support report generation\n');
		return;
	}

	http.prepare_content('application/gzip');
	http.header(
		'Content-Disposition',
		'attachment; filename="forkop-support-report.txt.gz"'
	);

	while (true) {
		let chunk = stream.read(16384);

		if (chunk == null || length(chunk) == 0)
			break;

		http.write(chunk);
	}

	stream.close();
}

function action_remote_support() {
	http.header('Cache-Control', 'no-store');
	http.prepare_content('application/json');
	if (dispatched?.readonly && http.formvalue('operation') != 'status') {
		http.status(403, 'Forbidden');
		http.write('{"success":false,"error":"Write permission is required"}');
		return;
	}
	try {
		let session = loadfile('/usr/lib/forkop/support/session.uc')();
		let result = session.request({
			operation: http.formvalue('operation'),
			session_id: http.formvalue('session_id'),
			auth_key: http.formvalue('auth_key'),
			consent: http.formvalue('consent')
		});
		http.write(sprintf('%J', { success: true, data: result }));
	} catch (e) {
		// Never echo request data or exception contents containing credentials.
		http.status(400, 'Support operation failed');
		http.write(sprintf('%J', { success: false, error: 'Support operation failed. Refresh the status and check the installation and auth key.' }));
	}
}

return {
	action_ui_read,
	action_ui_clash,
	action_ui_write,
	action_support_report,
	action_remote_support
};
