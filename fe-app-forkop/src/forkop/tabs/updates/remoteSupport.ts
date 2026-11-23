import { renderButton } from '../../../partials';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import { isReadOnlyForkopView } from '../../methods/shell/readForkopStatus';
import { pollLuciTab } from '../../helpers/pollLuciTab';

interface SupportStatus {
  installed: boolean;
  package_installed: boolean;
  lite_installed: boolean;
  system_installed?: boolean;
  system_version?: string;
  lite_version?: string;
  removable: boolean;
  version: string;
  primary_running: boolean;
  active: boolean;
  phase: string;
  error: string;
  error_detail: string;
  free_kib: number;
  required_kib: number;
  remaining_seconds: number;
  address: string;
  session_id: string;
  announcement_granted?: boolean;
}

export function renderRemoteSupport() {
  let status: SupportStatus | null = null;
  let busy = false;
  let requestEpoch = 0;
  let announcedSession = '';
  let announcementPending = false;
  let connectionDialog: HTMLElement | null = null;
  const key = E('input', {
    type: 'text',
    placeholder: _('One-time Tailscale auth key'),
    autocomplete: 'one-time-code',
    autocapitalize: 'off',
    spellcheck: false,
    'data-lpignore': 'true',
    'data-1p-ignore': 'true',
    style: 'width:100%;box-sizing:border-box;-webkit-text-security:disc',
  });
  const consent = E('input', { type: 'checkbox' });
  const information = E('div');
  const message = E('div', { role: 'status' });
  const actions = E('div', { class: 'fkp_updates-page__component__actions' });
  const form = E('div', {}, [
    key,
    E('label', { style: 'display:block;margin-top:10px' }, [
      consent,
      _('I allow access to local router services for 30 minutes.'),
    ]),
  ]);
  const card = E(
    'div',
    { class: 'fkp_updates-page__component', style: 'margin-top:10px' },
    [
      E(
        'div',
        { class: 'fkp_updates-page__component__header' },
        E(
          'span',
          { class: 'fkp_updates-page__component__title' },
          _('Remote support'),
        ),
      ),
      E(
        'p',
        {},
        _(
          'A separate temporary Tailscale connection. Temporarily installs the support SSH public key. No LAN routes are advertised.',
        ),
      ),
      information,
      form,
      actions,
      message,
    ],
  );

  async function request(operation: string, authKey = '', sessionId = '') {
    const body = new URLSearchParams({ operation, token: L.env.token });
    if (sessionId) body.set('session_id', sessionId);
    if (operation === 'remove') body.set('consent', 'remove-tailscale-package');
    if (authKey) {
      body.set('auth_key', authKey);
      body.set('consent', 'full-router-access');
    }
    const response = await fetch(
      L.url('admin', 'services', 'forkop', 'remote-support'),
      {
        method: 'POST',
        credentials: 'same-origin',
        cache: 'no-store',
        body,
      },
    );
    const result = await response.json();
    if (!response.ok || !result.success)
      throw new Error(
        _(
          'Support operation failed. Refresh the status and check the installation and auth key.',
        ),
      );
    return result.data as SupportStatus;
  }

  function phaseLabel(phase: string) {
    const labels: Record<string, string> = {
      stopped: _('Disconnected'),
      starting: _('Connecting'),
      installing: _('Installing'),
      removing: _('Removing'),
      connected: _('Connected'),
      degraded: _('Control connection lost'),
      recovering: _('Restoring control connection'),
      failed: _('Failed'),
    };
    return labels[phase] || phase;
  }

  function connectionDetails() {
    const connected =
      status?.active && status.phase === 'connected' && !!status.address;
    return connected && status
      ? [
          _('Forkop: remote support'),
          `IP: ${status.address}`,
          `${_('Remaining time')}: ${Math.ceil(status.remaining_seconds / 60)} ${_('minutes')}`,
        ].join('\n')
      : status?.active
        ? `${phaseLabel(status.phase)}\n${_('Remaining time')}: ${Math.ceil(status.remaining_seconds / 60)} ${_('minutes')}`
        : status
          ? _('Disconnected')
          : _('Unable to read remote support status');
  }

  function updateConnectionDialog() {
    if (!connectionDialog?.isConnected) return;
    const connected = !!(
      status?.active &&
      status.phase === 'connected' &&
      status.address
    );
    connectionDialog.replaceChildren(
      E(
        'h4',
        {},
        connected
          ? _('Support access is open')
          : phaseLabel(status?.phase || 'stopped'),
      ),
      E(
        'p',
        {},
        _('Send these details to support so they can connect to your router.'),
      ),
      E(
        'pre',
        { style: 'white-space:pre-wrap;overflow-wrap:anywhere' },
        connectionDetails(),
      ),
      E('div', { class: 'right' }, [
        renderButton({
          text: _('Copy IP'),
          disabled: !connected,
          onClick: () => {
            if (
              status?.active &&
              status.phase === 'connected' &&
              status.address
            )
              copyToClipboard(status.address);
          },
        }),
        renderButton({
          text: _('Disconnect now'),
          disabled: isReadOnlyForkopView() || busy || !status?.active,
          onClick: () => {
            void act('stop');
          },
        }),
        renderButton({
          text: _('Close'),
          onClick: () => {
            ui.hideModal();
            connectionDialog = null;
          },
        }),
      ]),
    );
  }

  function showConnectionDialog() {
    connectionDialog = E('div');
    ui.showModal(_('Connection details'), connectionDialog);
    updateConnectionDialog();
  }

  async function announceSession(sessionId: string) {
    if (announcementPending || !sessionId || announcedSession === sessionId)
      return;
    announcementPending = true;
    const epoch = requestEpoch;
    try {
      const result = await request('announce', '', sessionId);
      announcedSession = sessionId;
      if (
        result.announcement_granted &&
        epoch === requestEpoch &&
        card.isConnected &&
        status?.active &&
        status.phase === 'connected' &&
        status.session_id === sessionId &&
        !connectionDialog?.isConnected
      )
        showConnectionDialog();
    } catch {
      /* Retry a failed acknowledgement on the next status poll. */
    } finally {
      announcementPending = false;
    }
  }

  function update() {
    updateConnectionDialog();
    if (
      !isReadOnlyForkopView() &&
      card.isConnected &&
      status?.active &&
      status.phase === 'connected' &&
      status.address
    ) {
      void announceSession(status.session_id);
    }
    const versions: string[] = [];
    if (status?.system_installed)
      versions.push(`Tailscale ${status.system_version || ''}`.trim());
    if (status?.lite_installed)
      versions.push(
        `Tailscale Lite ${status.lite_version ?? status.version}`.trim(),
      );
    if (status?.installed && !versions.length)
      versions.push(`Tailscale ${status.version}`.trim());
    const details: Node[] = [
      E(
        'div',
        {},
        versions.length ? versions.join('; ') : _('Tailscale is not installed'),
      ),
      E('div', {}, status ? phaseLabel(status.phase) : _('Loading')),
    ];
    if (status?.system_installed && status.lite_installed)
      details.push(E('div', {}, `${_('Used for support')}: Tailscale Lite`));
    if (status?.primary_running)
      details.push(
        E(
          'div',
          {},
          _(
            'An existing Tailscale service is running. Its settings are preserved.',
          ),
        ),
      );
    if (status?.active && !['installing', 'removing'].includes(status.phase))
      details.push(
        E(
          'div',
          {},
          `${_('Remaining time')}: ${Math.ceil(status.remaining_seconds / 60)} ${_('minutes')}`,
        ),
      );
    if (status?.address)
      details.push(E('code', {}, `ssh root@${status.address}`));
    if (status?.error) details.push(E('div', {}, _(status.error)));
    if (status?.phase === 'failed' && status.required_kib) {
      details.push(
        E(
          'div',
          {},
          `${_('Free storage')}: ${(status.free_kib / 1024).toFixed(1)} MiB. ${_('Estimated storage required, including reserve')}: ${(status.required_kib / 1024).toFixed(1)} MiB.`,
        ),
      );
    }
    if (status?.error_detail) {
      details.push(
        E('details', {}, [
          E('summary', {}, _('Error details')),
          E(
            'pre',
            {
              style:
                'white-space:pre-wrap;overflow-wrap:anywhere;max-height:240px;overflow:auto',
            },
            status.error_detail,
          ),
        ]),
      );
    }
    information.replaceChildren(...details);
    form.hidden =
      isReadOnlyForkopView() || !status?.installed || !!status.active;
    key.disabled = busy;
    consent.disabled = busy;
    const buttons: Node[] = [];
    if (status?.active) {
      if (
        status.session_id &&
        !['installing', 'removing'].includes(status.phase)
      ) {
        buttons.push(
          renderButton({
            text: _('Connection details'),
            onClick: showConnectionDialog,
          }),
        );
      }
      buttons.push(
        renderButton({
          text: _('Disconnect now'),
          disabled:
            isReadOnlyForkopView() ||
            busy ||
            ['installing', 'removing'].includes(status.phase),
          onClick: () => {
            void act('stop');
          },
        }),
      );
    } else if (status?.installed) {
      buttons.push(
        renderButton({
          text: _('Allow for 30 minutes'),
          disabled:
            isReadOnlyForkopView() ||
            busy ||
            !consent.checked ||
            !key.value.trim(),
          onClick: () => {
            void act('start');
          },
        }),
      );
    } else {
      buttons.push(
        renderButton({
          text: _('Install Tailscale Lite'),
          disabled: isReadOnlyForkopView() || busy || !status,
          onClick: () => {
            void act('install');
          },
        }),
      );
    }
    if (
      (status?.package_installed || status?.lite_installed) &&
      !status.active
    ) {
      buttons.push(
        renderButton({
          text: status.lite_installed
            ? _('Remove Tailscale Lite')
            : _('Remove Tailscale'),
          disabled: isReadOnlyForkopView() || busy || !status.removable,
          onClick: () => {
            ui.showModal(
              _('Remove Tailscale'),
              E('div', {}, [
                E(
                  'p',
                  {},
                  _(
                    status?.lite_installed
                      ? 'Remove the separate Tailscale Lite support installation?'
                      : 'Remove the Tailscale package from this router? It will no longer be available for other applications.',
                  ),
                ),
                E('div', { class: 'right' }, [
                  renderButton({
                    text: _('Cancel'),
                    onClick: () => ui.hideModal(),
                  }),
                  renderButton({
                    text: _('Remove Tailscale'),
                    classNames: ['cbi-button-negative'],
                    onClick: () => {
                      ui.hideModal();
                      void act('remove');
                    },
                  }),
                ]),
              ]),
            );
          },
        }),
      );
      if (!status.removable)
        details.push(
          E(
            'div',
            {},
            _(
              'Removal is unavailable while the existing Tailscale service is running or enabled, or when the package is not managed by OpenWrt.',
            ),
          ),
        );
      information.replaceChildren(...details);
    }
    actions.replaceChildren(...buttons);
  }

  async function act(operation: string) {
    if (busy || isReadOnlyForkopView()) return;
    busy = true;
    requestEpoch += 1;
    const authKey = operation === 'start' ? key.value.trim() : '';
    key.value = '';
    consent.checked = false;
    message.textContent = '';
    update();
    try {
      status = await request(operation, authKey);
    } catch (error) {
      message.textContent = (error as Error).message;
    } finally {
      busy = false;
      update();
    }
  }

  async function refresh(isVisible: () => boolean) {
    if (!card.isConnected) return;
    if (!busy) {
      const epoch = requestEpoch;
      try {
        const result = await request('status');
        if (epoch === requestEpoch && isVisible()) {
          status = result;
          update();
        }
      } catch {
        if (epoch === requestEpoch && isVisible()) {
          status = null;
          updateConnectionDialog();
          message.textContent = _('Unable to read remote support status');
        }
      }
    }
  }
  key.addEventListener('input', update);
  consent.addEventListener('change', update);
  window.addEventListener(
    'pagehide',
    () => {
      key.value = '';
    },
    { once: true },
  );
  update();
  pollLuciTab(card, refresh, 3000, 1000);
  return card;
}
