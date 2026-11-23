import { executeShellCommand } from '../../../helpers';
import { renderXIcon24 } from '../../../icons';
import { renderButton } from '../../../partials';

let removing = false;
const REMOVAL_STATUS_TIMEOUT_MS = 180000;
const REMOVAL_STATUS_POLL_MS = 1500;

interface RemovalStatus {
  state?: string;
  phase?: string;
}

export async function waitForRemovalStatus(
  statusUrl: string,
): Promise<RemovalStatus | null> {
  const controller = new AbortController();
  const deadline = Date.now() + REMOVAL_STATUS_TIMEOUT_MS;
  const timeout = setTimeout(
    () => controller.abort(),
    REMOVAL_STATUS_TIMEOUT_MS,
  );

  try {
    while (!controller.signal.aborted) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) return null;
      await new Promise((resolve) =>
        setTimeout(resolve, Math.min(REMOVAL_STATUS_POLL_MS, remaining)),
      );
      if (controller.signal.aborted || Date.now() >= deadline) return null;

      try {
        const reply = await fetch(statusUrl, {
          cache: 'no-store',
          signal: controller.signal,
        });
        if (!reply.ok) continue;
        const status: RemovalStatus | null = await reply.json();
        if (controller.signal.aborted || Date.now() >= deadline) return null;
        if (status?.state === 'complete' || status?.state === 'failed')
          return status;
      } catch {
        // A transient HTTP or JSON error is retried within the same deadline.
      }
    }
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

function confirmRemoval() {
  if (removing) return;
  const progress = E('p', { role: 'status' });
  const cancel = renderButton({
    text: _('Cancel'),
    onClick: () => ui.hideModal(),
  });
  const confirm = renderButton({
    text: _('Remove permanently'),
    classNames: ['cbi-button-negative'],
    onClick: () => {
      removing = true;
      confirm.disabled = true;
      cancel.disabled = true;
      progress.textContent = _('Removing Forkop X…');
      void (async () => {
        try {
          const response = await executeShellCommand({
            command: '/usr/bin/forkop',
            args: ['full_uninstall'],
            timeout: 15000,
          });
          const result = JSON.parse(response.stdout || '{}');
          if (
            response.code ||
            !result.success ||
            !/^\/forkop-uninstall\.[A-Za-z0-9]+\.json$/.test(
              result.status_url || '',
            )
          ) {
            throw new Error(
              _(
                'Could not start removal. Another component action may be running.',
              ),
            );
          }
          const status = await waitForRemovalStatus(result.status_url);
          if (status?.state === 'complete') {
            progress.textContent = _(
              'Forkop X has been removed. Original repositories have been restored.',
            );
            cancel.textContent = _('Open LuCI');
            cancel.disabled = false;
            cancel.onclick = () => window.location.assign('/cgi-bin/luci/');
            return;
          }
          if (status?.state === 'failed') {
            throw new Error(
              status.phase === 'preflight'
                ? _(
                    'Original repositories could not be restored. Removal was cancelled before deleting packages.',
                  )
                : _(
                    'Removal did not finish. See the removal log in /tmp/forkop-uninstall.*/output.log.',
                  ),
            );
          }
          throw new Error(
            _(
              'Could not confirm completion. Check the removal log before retrying.',
            ),
          );
        } catch (error) {
          progress.textContent =
            error instanceof Error ? error.message : String(error);
          cancel.disabled = false;
          // Do not blindly repeat an operation whose RPC response was lost.
          cancel.onclick = () => window.location.assign('/cgi-bin/luci/');
          cancel.textContent = _('Open LuCI');
        }
      })();
    },
  });
  ui.showModal(
    _('Full removal'),
    E('div', {}, [
      E(
        'p',
        {},
        _(
          'Remove Forkop X with its settings and cache, and restore the original device repositories?',
        ),
      ),
      E(
        'p',
        {},
        _(
          'This permanently deletes saved sections and subscriptions. Other components remain installed.',
        ),
      ),
      progress,
      E('div', { class: 'right' }, [cancel, confirm]),
    ]),
  );
}

export function renderFullUninstall(disabled: boolean) {
  return E('div', { class: 'fkp_updates-page__component' }, [
    E('div', { class: 'fkp_updates-page__component__header' }, [
      E(
        'b',
        { class: 'fkp_updates-page__component__title' },
        _('Full removal'),
      ),
    ]),
    E(
      'p',
      {},
      _(
        'Remove Forkop X with its settings and restore the original device repositories.',
      ),
    ),
    renderButton({
      text: _('Remove Forkop X completely'),
      icon: renderXIcon24,
      classNames: ['cbi-button-negative'],
      disabled: disabled || removing,
      onClick: confirmRemoval,
    }),
  ]);
}
