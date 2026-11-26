import { insertIf } from '../../../../helpers';
import type { IDiagnosticsChecksItem } from '../../../services';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods } from '../../../methods';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runXrustCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.XRUST;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const xrustChecks = await ForkopShellMethods.checkXrust();

  if (!xrustChecks.success) {
    updateCheckStore({
      order,
      code,
      title,
      description: _('Cannot receive checks result'),
      state: 'error',
      items: [],
    });

    throw new Error('Xrust checks failed');
  }

  const data = xrustChecks.data;

  const allGood =
    Boolean(data.xrust_installed) &&
    Boolean(data.xrust_version_ok) &&
    Boolean(data.xrust_service_exist) &&
    Boolean(data.xrust_autostart_disabled) &&
    Boolean(data.xrust_process_running) &&
    Boolean(data.xrust_ports_listening);

  const atLeastOneGood =
    Boolean(data.xrust_installed) ||
    Boolean(data.xrust_version_ok) ||
    Boolean(data.xrust_service_exist) ||
    Boolean(data.xrust_autostart_disabled) ||
    Boolean(data.xrust_process_running) ||
    Boolean(data.xrust_ports_listening);

  const { state, description } = getMeta({ atLeastOneGood, allGood });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: data.xrust_installed ? 'success' : 'error',
        key: _('Xrust installed'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(Boolean(data.xrust_installed), [
        {
          state: data.xrust_version_ok ? 'success' : 'error',
          key: _('Xrust version recognized'),
          value: '',
        },
      ]),
      {
        state: data.xrust_service_exist ? 'success' : 'error',
        key: _('Xrust service exists'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(Boolean(data.xrust_service_exist), [
        {
          state: data.xrust_autostart_disabled ? 'success' : 'error',
          key: data.xrust_autostart_disabled
            ? _('Forkop X manages Xrust startup')
            : _('Xrust is set to start independently at boot'),
          value: '',
        },
      ]),
      {
        state: data.xrust_process_running ? 'success' : 'error',
        key: _('Xrust process running'),
        value: '',
      },
      ...insertIf<IDiagnosticsChecksItem>(Boolean(data.xrust_process_running), [
        {
          state: data.xrust_ports_listening ? 'success' : 'error',
          key: _('Xrust listening ports'),
          value: '',
        },
      ]),
    ],
  });

  if (!atLeastOneGood || !data.xrust_process_running) {
    throw new Error('Xrust checks failed');
  }
}
