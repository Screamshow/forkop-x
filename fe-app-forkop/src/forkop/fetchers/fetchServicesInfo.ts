import { ForkopShellMethods } from '../methods';
import { logger } from '../services/logger.service';
import { store } from '../services/store.service';
import { refreshRuntimeUiState } from '../services/runtimeUiState.service';
import { Forkop } from '../types';

let latestServicesInfoRequestId = 0;

function getSettledMethodResponse<T>(
  scope: string,
  result: PromiseSettledResult<Forkop.MethodResponse<T>>,
): Forkop.MethodResponse<T> {
  if (result.status === 'fulfilled') {
    return result.value;
  }

  logger.error('[SERVICES_INFO]', `${scope} failed`, result.reason);

  return {
    success: false,
    error: result.reason instanceof Error ? result.reason.message : '',
  };
}

export async function fetchServicesInfo() {
  const requestId = ++latestServicesInfoRequestId;
  const uiState = await refreshRuntimeUiState({ force: true });

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  if (uiState) {
    return uiState;
  }

  const [forkopResult, singboxResult] = await Promise.allSettled([
    ForkopShellMethods.getStatus(),
    ForkopShellMethods.getSingBoxStatus(),
  ]);

  if (requestId !== latestServicesInfoRequestId) {
    return;
  }

  const forkop = getSettledMethodResponse('getStatus', forkopResult);
  const singbox = getSettledMethodResponse('getSingBoxStatus', singboxResult);
  const previousData = store.get().servicesInfoWidget.data;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: !forkop.success || !singbox.success,
      data: {
        singboxMemoryBytes: singbox.success
          ? singbox.data.memory_rss_bytes
          : undefined,
        forkopMemoryBytes: forkop.success
          ? forkop.data.memory_rss_bytes
          : undefined,
        // This fallback cannot see the per-service figures, so keep whatever
        // the last runtime state reported instead of dropping their rows.
        tailscale: previousData.tailscale,
        torrserverDirect: previousData.torrserverDirect,
        singbox: singbox.success ? singbox.data.running : previousData.singbox,
        forkopRunning: forkop.success
          ? forkop.data.running
          : previousData.forkopRunning,
        stopAvailable: forkop.success
          ? (forkop.data.stop_available ?? forkop.data.running)
          : previousData.stopAvailable,
        restartBlocked: forkop.success
          ? (forkop.data.restart_blocked ?? 0)
          : previousData.restartBlocked,
        forkopEnabled: forkop.success
          ? forkop.data.enabled
          : previousData.forkopEnabled,
        forkopStatus: forkop.success
          ? forkop.data.status
          : previousData.forkopStatus,
      },
    },
  });

  return undefined;
}
