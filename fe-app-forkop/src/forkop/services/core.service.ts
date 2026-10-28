import { TabServiceInstance } from './tab.service';
import { store } from './store.service';
import { logger } from './logger.service';
import { ForkopLogWatcher } from './forkopLogWatcher.service';
import {
  getForkopLogNotification,
  LogNotificationDeduper,
  ForkopLogNotification,
} from './logNotificationDeduper.service';
import { StartRecoveryNotificationController } from './startRecoveryNotification.service';
import { getLogErrorMessage } from './logErrorMessage.service';
import { ForkopShellMethods } from '../methods';
import {
  registerRuntimeStateResumeRefresh,
  startRuntimeUiStatePolling,
  subscribeRuntimeUiState,
} from './runtimeUiState.service';
import { subscriptionApplyAlert } from './subscriptionApplyAlert.service';

type CoreServiceOptions = {
  waitForLogWatcherStart?: () => Promise<unknown>;
  logWatcherStartDelayMs?: number;
};

const LOG_WATCHER_INTERVAL_MS = 10000;
const LOG_WATCHER_START_DELAY_MS = 5000;

function componentDisplayName(component: string) {
  const names: Record<string, string> = {
    forkop: 'Forkop X',
    sing_box: 'sing-box',
    rust_x: 'Xrust',
    zapret_manager: 'Zapret-Manager',
  };

  return names[component] || component;
}

function showLogNotification(notification: ForkopLogNotification) {
  if (notification.kind === 'rule-set-unavailable') {
    ui.addNotification(
      _('List changes were not applied'),
      E(
        'div',
        {},
        _(
          'A required list could not be downloaded or validated. The previous working configuration is still active. Check the list source and apply the settings again.',
        ),
      ),
      'warning',
      'fkp-rule-set-unavailable-notification',
    );
    return;
  }
  if (notification.kind === 'discord-cloudflare-overlap') {
    ui.addNotification(
      _('Discord and Cloudflare lists overlap'),
      E(
        'div',
        {},
        _(
          'Both built-in lists are enabled. Broad Cloudflare ranges may route unrelated traffic, including torrents, through a proxy or VPN depending on section order.',
        ),
      ),
      'warning',
      'fkp-discord-cloudflare-overlap-notification',
    );
    return;
  }

  if (notification.kind === 'component-update') {
    const message = _('New version %s is available for %s')
      .replace('%s', notification.version)
      .replace('%s', componentDisplayName(notification.component));

    ui.addNotification(
      _('Component update available'),
      E('div', {}, message),
      'warning',
      'fkp-component-update-notification',
    );
    return;
  }

  if (notification.kind === 'start-recovery-pending') {
    ui.addNotification(
      _('Forkop is restarting automatically'),
      E(
        'div',
        {},
        _(
          'A startup attempt was interrupted. Forkop will retry automatically; no action is needed yet.',
        ),
      ),
      'warning',
      'fkp-start-recovery-notification',
    );
    return;
  }

  if (notification.kind === 'start-recovery-succeeded') {
    ui.addNotification(
      _('Forkop recovered automatically'),
      E(
        'div',
        {},
        _('Forkop restarted successfully after a temporary startup failure.'),
      ),
      'success',
      'fkp-start-recovery-notification',
    );
    return;
  }

  const errorMessage = getLogErrorMessage(notification.line);
  ui.addNotification(
    _('Forkop Error'),
    errorMessage
      ? E('div', {}, [
          E('div', {}, errorMessage),
          E('details', {}, [
            E('summary', {}, _('Technical details')),
            E(
              'pre',
              { style: 'white-space: pre-wrap; overflow-wrap: anywhere;' },
              notification.line,
            ),
          ]),
        ])
      : E('div', {}, notification.line),
    'error',
    'fkp-log-error-notification',
  );
}

export function coreService(options: CoreServiceOptions = {}) {
  let lastSubscriptionError = '';
  subscribeRuntimeUiState((state) => {
    const key = state.subscription_error
      ? JSON.stringify(state.subscription_error)
      : '';
    if (key === lastSubscriptionError) return;
    lastSubscriptionError = key;
    if (typeof document !== 'undefined') {
      document.querySelector('.fkp-subscription-apply-error')?.remove();
    }
    const alert = subscriptionApplyAlert(state.subscription_error);
    if (alert) {
      ui.addNotification(
        alert.title,
        E('div', {}, alert.message),
        'error',
        'fkp-subscription-apply-error',
      );
    }
  });
  TabServiceInstance.onChange((activeId, tabs) => {
    logger.info('[TAB]', activeId);
    store.set({
      tabService: {
        current: activeId || '',
        all: tabs.map((tab) => tab.id),
      },
    });
  });

  const watcher = ForkopLogWatcher.getInstance();
  const logNotificationDeduper = new LogNotificationDeduper();
  const startRecoveryNotifications = new StartRecoveryNotificationController(
    showLogNotification,
  );

  watcher.init(
    async () => {
      const logs = await ForkopShellMethods.checkLogs();

      if (logs.success) {
        return logs.data as string;
      }

      return '';
    },
    {
      intervalMs: LOG_WATCHER_INTERVAL_MS,
      onNewLog: (line) => {
        if (startRecoveryNotifications.handle(line)) {
          return;
        }
        if (logNotificationDeduper.shouldNotify(line)) {
          const notification = getForkopLogNotification(line);
          if (notification) {
            showLogNotification(notification);
          }
        }
      },
    },
  );

  const startWatcher = async () => {
    if (options.waitForLogWatcherStart) {
      await Promise.resolve()
        .then(() => options.waitForLogWatcherStart?.())
        .catch(() => null);
    }

    watcher.start();
  };
  const scheduleStartWatcher = () =>
    window.setTimeout(() => {
      void startWatcher();
    }, options.logWatcherStartDelayMs ?? LOG_WATCHER_START_DELAY_MS);

  if (typeof window !== 'undefined') {
    scheduleStartWatcher();
  } else {
    void startWatcher();
  }

  registerRuntimeStateResumeRefresh();
  startRuntimeUiStatePolling();
}
