import { executeShellCommand } from '../../../helpers';
import { renderButton } from '../../../partials';

export async function showReleaseSelector(
  currentVersion: string,
  install: (version: string) => void,
) {
  const title = _('Choose Forkop X version');
  const status = E('p', { role: 'status' }, _('Loading available versions…'));
  const content = E('div', {}, [status]);
  ui.showModal(title, content);
  try {
    const response = await executeShellCommand({
      command: '/usr/bin/forkop',
      args: ['forkop_releases'],
      timeout: 75000,
    });
    const result = JSON.parse(response.stdout || '{}');
    if (response.code || !result.success || !Array.isArray(result.releases)) {
      throw new Error(_('Could not load available versions'));
    }
    const select = E('select', {
      class: 'cbi-input-select',
      'aria-label': title,
    }) as HTMLSelectElement;
    for (const release of result.releases) {
      if (!/^\d+\.\d+\.\d+(-canary\.\d+)?$/.test(release.version)) continue;
      const installed = release.version === currentVersion;
      select.appendChild(
        E(
          'option',
          { value: release.version },
          `${release.version} (${release.channel})${installed ? ` — ${_('Installed')}` : ''}`,
        ),
      );
    }
    if (!select.options.length)
      throw new Error(_('No compatible releases available'));
    const confirm = renderButton({
      text: _('Install selected version'),
      classNames: ['cbi-button-save'],
      onClick: () => {
        const version = select.value;
        ui.showModal(
          _('Confirm version change'),
          E('div', {}, [
            E('p', {}, `${currentVersion} → ${version}`),
            E(
              'p',
              {},
              _(
                'A configuration backup will be saved in /etc/forkop-backups. Older versions may not support all current settings.',
              ),
            ),
            E('div', { class: 'right' }, [
              renderButton({
                text: _('Cancel'),
                onClick: () => ui.hideModal(),
              }),
              renderButton({
                text: _('Install'),
                classNames: ['cbi-button-save'],
                onClick: () => {
                  ui.hideModal();
                  install(version);
                },
              }),
            ]),
          ]),
        );
      },
    });
    const update = () => {
      confirm.disabled = select.value === currentVersion;
    };
    select.addEventListener('change', update);
    update();
    content.replaceChildren(
      select,
      E('div', { class: 'right' }, [
        renderButton({ text: _('Cancel'), onClick: () => ui.hideModal() }),
        confirm,
      ]),
    );
  } catch (error) {
    status.textContent =
      error instanceof Error
        ? error.message
        : _('Could not load available versions');
    content.appendChild(
      renderButton({ text: _('Close'), onClick: () => ui.hideModal() }),
    );
  }
}
