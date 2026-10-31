import type { Forkop } from '../types';

export function subscriptionApplyAlert(
  error: Forkop.UiState['subscription_error'],
) {
  if (!error) return null;
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
    title:
      error.state === 'recovery_failed'
        ? _('Subscription update: recovery failed')
        : _('Subscription update failed'),
    message: [
      error.section ? _('Section: %s').replace('%s', error.section) : '',
      states[error.state] || states.unknown,
      error.reason === 'rollback_failed'
        ? ''
        : reasons[error.reason] || reasons.apply_failed,
    ]
      .filter(Boolean)
      .join(' '),
  };
}
