import type { Forkop } from '../../types';

export function isForkopInstall(
  result: Pick<Forkop.ComponentActionResult, 'component' | 'action'>,
) {
  return result.component === 'forkop' && result.action === 'install';
}

export function getLatestForkopInstall(
  actions: Forkop.ComponentActionResult[],
) {
  let latest: Forkop.ComponentActionResult | undefined;
  for (const action of actions) {
    if (!isForkopInstall(action)) continue;
    const time = action.started_at ?? action.updated_at ?? 0;
    const latestTime = latest?.started_at ?? latest?.updated_at ?? 0;
    if (
      !latest ||
      time > latestTime ||
      (time === latestTime &&
        (action.job_id || '').localeCompare(latest.job_id || '', undefined, {
          numeric: true,
        }) > 0)
    ) {
      latest = action;
    }
  }
  return latest;
}

export function shouldApplyCompletedComponentActionResult(
  result: Pick<Forkop.ComponentActionResult, 'action'>,
  notify: boolean,
) {
  return result.action !== 'check_update' || notify;
}
