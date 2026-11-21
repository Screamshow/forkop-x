// Copyright 2026 Forkop contributors
// Licensed to the public under the GPL-2.0-or-later.

import { popen } from 'fs';

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
	action_support_report,
	action_remote_support
};
