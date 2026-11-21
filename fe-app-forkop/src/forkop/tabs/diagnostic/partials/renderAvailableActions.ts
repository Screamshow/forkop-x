import { renderButton } from '../../../../partials';
import {
  renderCircleCheckBigIcon24,
  renderCirclePlayIcon24,
  renderCircleStopIcon24,
  renderCircleXIcon24,
  renderCogIcon24,
  renderDownloadIcon24,
  renderPauseIcon24,
  renderPlayIcon24,
  renderRotateCcwIcon24,
  renderSquareChartGanttIcon24,
} from '../../../../icons';
import { insertIf } from '../../../../helpers';

interface ActionProps {
  loading: boolean;
  visible: boolean;
  disabled: boolean;
  onClick: () => void;
}

interface IRenderAvailableActionsProps {
  restartBlocked: boolean;
  transitioning: boolean;
  restart: ActionProps;
  start: ActionProps;
  stop: ActionProps;
  enable: ActionProps;
  disable: ActionProps;
  globalCheck: ActionProps;
  viewLogs: ActionProps;
  showXrustConfig: ActionProps;
  supportReport: ActionProps;
}

export function renderAvailableActions({
  restartBlocked,
  transitioning,
  restart,
  start,
  stop,
  enable,
  disable,
  globalCheck,
  viewLogs,
  showXrustConfig,
  supportReport,
}: IRenderAvailableActionsProps) {
  return E('div', { class: 'fkp_diagnostic-page__right-bar__actions' }, [
    E('b', {}, _('Available actions')),
    ...insertIf(transitioning, [
      E(
        'div',
        { role: 'status' },
        _('Forkop X is applying changes. Please wait.'),
      ),
    ]),
    ...insertIf(restartBlocked, [
      E('div', { class: 'fkp_diagnostic_alert fkp_diagnostic_alert--error' }, [
        E('span', { class: 'fkp_diagnostic_alert__icon' }, [
          renderCircleXIcon24(),
        ]),
        E('div', { class: 'fkp_diagnostic_alert__content' }, [
          E(
            'b',
            { class: 'fkp_diagnostic_alert__title' },
            _('Restart temporarily unavailable'),
          ),
          E(
            'div',
            { class: 'fkp_diagnostic_alert__description' },
            _(
              'Could not confirm the Xrust process state. Check the logs before trying again.',
            ),
          ),
        ]),
      ]),
    ]),
    ...insertIf(restart.visible, [
      renderButton({
        classNames: ['cbi-button-apply'],
        onClick: restart.onClick,
        icon: renderRotateCcwIcon24,
        text: _('Restart Forkop X'),
        loading: restart.loading,
        disabled: restart.disabled,
      }),
    ]),
    ...insertIf(stop.visible, [
      renderButton({
        classNames: ['cbi-button-remove'],
        onClick: stop.onClick,
        icon: renderCircleStopIcon24,
        text: _('Stop Forkop X'),
        loading: stop.loading,
        disabled: stop.disabled,
      }),
    ]),
    ...insertIf(start.visible, [
      renderButton({
        classNames: ['cbi-button-save'],
        onClick: start.onClick,
        icon: renderCirclePlayIcon24,
        text: _('Start Forkop X'),
        loading: start.loading,
        disabled: start.disabled,
      }),
    ]),
    ...insertIf(disable.visible, [
      renderButton({
        classNames: ['cbi-button-remove'],
        onClick: disable.onClick,
        icon: renderPauseIcon24,
        text: _('Disable autostart'),
        loading: disable.loading,
        disabled: disable.disabled,
      }),
    ]),
    ...insertIf(enable.visible, [
      renderButton({
        classNames: ['cbi-button-save'],
        onClick: enable.onClick,
        icon: renderPlayIcon24,
        text: _('Enable autostart'),
        loading: enable.loading,
        disabled: enable.disabled,
      }),
    ]),
    ...insertIf(globalCheck.visible, [
      renderButton({
        onClick: globalCheck.onClick,
        icon: renderCircleCheckBigIcon24,
        text: _('Get global check'),
        loading: globalCheck.loading,
        disabled: globalCheck.disabled,
      }),
    ]),
    ...insertIf(viewLogs.visible, [
      renderButton({
        onClick: viewLogs.onClick,
        icon: renderSquareChartGanttIcon24,
        text: _('View logs'),
        loading: viewLogs.loading,
        disabled: viewLogs.disabled,
      }),
    ]),
    ...insertIf(showXrustConfig.visible, [
      renderButton({
        onClick: showXrustConfig.onClick,
        icon: renderCogIcon24,
        text: _('Show Xrust config'),
        loading: showXrustConfig.loading,
        disabled: showXrustConfig.disabled,
      }),
    ]),
    ...insertIf(supportReport.visible, [
      renderButton({
        onClick: supportReport.onClick,
        icon: renderDownloadIcon24,
        text: _('Download support report'),
        loading: supportReport.loading,
        disabled: supportReport.disabled,
      }),
    ]),
  ]);
}
