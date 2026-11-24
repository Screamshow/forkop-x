import type { Forkop } from '../types';

export function subscriptionApplyAlert(
  error: Forkop.UiState['subscription_error'],
) {
  if (!error) return null;
  const section = error.section
    ? _('Section: %s').replace('%s', error.section)
    : '';
  if (
    error.state === 'applied' &&
    error.reason === 'cache_persistence_failed'
  ) {
    return {
      severity: 'warning',
      title: _('Subscription update processed'),
      message: [
        section,
        _(
          'The cache for offline use has not been saved yet. Forkop will retry.',
        ),
      ]
        .filter(Boolean)
        .join('. '),
    };
  }
  const reasons: Record<string, string> = {
    stage_failed: _('Could not prepare the updated configuration.'),
    plan_failed: _('The updated configuration was rejected.'),
    backup_failed: _('Could not save the previous configuration.'),
    hot_apply_failed: _('The core did not confirm the updated configuration.'),
    rollback_failed: _(
      'The previous working configuration could not be restored.',
    ),
    workers_failed: _('Could not restart the auxiliary services.'),
    apply_failed: _('The updated configuration could not be applied.'),
  };
  const states: Record<string, string> = {
    previous: _('The previous working configuration is still active.'),
    recovery_failed: _(
      'The previous working configuration could not be restored.',
    ),
    applied: _(
      'The updated core configuration is active, but auxiliary services reported an error.',
    ),
    unknown: _('The updated configuration could not be applied.'),
  };
  return {
    severity: 'error',
    title:
      error.state === 'recovery_failed'
        ? _('Subscription update: recovery failed')
        : _('Subscription update failed'),
    message: [
      section,
      states[error.state] || states.unknown,
      error.reason === 'rollback_failed'
        ? ''
        : reasons[error.reason] || reasons.apply_failed,
    ]
      .filter(Boolean)
      .join(' '),
  };
}
