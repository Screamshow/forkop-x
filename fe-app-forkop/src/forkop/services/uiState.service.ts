import { getComponentActionKey } from '../helpers/getComponentActionKey';
import { normalizeSingBoxVariantFields } from '../helpers/singBoxVariant';
import type { Forkop } from '../types';
import { getLocalActionOverlay } from './localActionOverlay.service';
import { store } from './store.service';
import type { StoreType } from './store.service';
import { observeRestartConflict } from '../helpers/restartConflict';
import type { RestartConflictObservation } from '../helpers/restartConflict';

let restartConflictObservation: RestartConflictObservation | undefined;

type UiActionMap = Partial<Forkop.UiState['actions']>;

function isRunningAction(state: { running?: boolean }) {
  return state.running === true;
}

// A service procd does not know keeps its dashboard row hidden, so the null
// the runtime reports is passed through rather than flattened to zero.
function serviceProcessState(state?: Forkop.ServiceProcessState | null) {
  return state
    ? { running: state.running, memoryBytes: state.memory_rss_bytes }
    : null;
}

function getEmptyUpdatesActions(): StoreType['updatesActions'] {
  return {
    forkopCheck: { loading: false },
    forkopInstall: { loading: false },
    singBoxCheck: { loading: false },
    singBoxInstall: { loading: false },
    singBoxInstallTiny: { loading: false },
    singBoxInstallX: { loading: false },
    singBoxInstallRustX: { loading: false },
    singBoxInstallStable: { loading: false },
    zapretManagerInstall: { loading: false },
    zapretManagerRemove: { loading: false },
    packetSteeringEnable: { loading: false },
    packetSteeringRestore: { loading: false },
    directProxyEnable: { loading: false },
    directProxyDisable: { loading: false },
    torrserverDirectEnable: { loading: false },
    torrserverDirectDisable: { loading: false },
  };
}

function getEmptyDiagnosticsActions(): StoreType['diagnosticsActions'] {
  return {
    ...store.get().diagnosticsActions,
    restart: { loading: false },
    start: { loading: false },
    stop: { loading: false },
  };
}

function normalizeLatencyProgress(
  progress?: Forkop.LatencyActionProgress,
): Forkop.LatencyActionProgress | undefined {
  const total = Math.trunc(Number(progress?.total ?? 0));

  if (!Number.isFinite(total) || total <= 0) {
    return undefined;
  }

  const completedValue = Number(progress?.completed ?? 0);
  const failedValue = Number(progress?.failed ?? 0);
  const completed = Number.isFinite(completedValue)
    ? Math.trunc(completedValue)
    : 0;
  const failed = Number.isFinite(failedValue) ? Math.trunc(failedValue) : 0;

  return {
    completed: Math.min(Math.max(0, completed), total),
    total,
    failed: Math.max(0, failed),
  };
}

function applyServiceState(uiState: Forkop.UiState) {
  const localActions = getLocalActionOverlay();
  const transitioning =
    ['starting', 'stopping', 'restarting', 'reloading'].includes(
      uiState.service.forkop.status,
    ) ||
    [
      ...(uiState.actions.service || []),
      ...(uiState.actions.component || []),
    ].some(isRunningAction) ||
    localActions.serviceActions.size > 0 ||
    localActions.componentActions.size > 0;
  restartConflictObservation = observeRestartConflict(
    restartConflictObservation,
    Boolean(uiState.service.forkop.restart_blocked),
    transitioning,
    Date.now(),
  );
  const currentSystemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = {
    ...currentSystemInfo,
    providerInfoLoaded: true,
  };

  nextSystemInfo.sing_box_extended = uiState.capabilities.sing_box_extended;
  nextSystemInfo.sing_box_xhttp =
    uiState.capabilities.sing_box_xhttp ??
    uiState.capabilities.sing_box_extended;
  nextSystemInfo.sing_box_tiny = uiState.capabilities.sing_box_tiny;
  nextSystemInfo.sing_box_compressed = uiState.capabilities.sing_box_compressed;
  nextSystemInfo.sing_box_tailscale = uiState.capabilities.sing_box_tailscale;

  store.set({
    servicesInfoWidget: {
      loading: false,
      failed: false,
      data: {
        singbox: uiState.service.sing_box.running,
        singboxMemoryBytes: uiState.service.sing_box.memory_rss_bytes,
        tailscale: serviceProcessState(uiState.service.tailscale),
        torrserverDirect: serviceProcessState(
          uiState.service.torrserver_direct,
        ),
        forkopMemoryBytes: uiState.service.forkop.memory_rss_bytes,
        forkopRunning: uiState.service.forkop.running,
        stopAvailable:
          uiState.service.forkop.stop_available ??
          uiState.service.forkop.running,
        restartBlocked: uiState.service.forkop.restart_blocked ?? 0,
        restartConflictConfirmed:
          restartConflictObservation?.confirmed ?? false,
        forkopEnabled: uiState.service.forkop.enabled,
        forkopStatus: uiState.service.forkop.status,
      },
    },
    diagnosticsSystemInfo: normalizeSingBoxVariantFields(nextSystemInfo),
  });
}

function applyActionState(actions: UiActionMap = {}) {
  const current = store.get();
  const localOverlay = getLocalActionOverlay();
  const currentLatencyProgressSections =
    current.sectionsWidget.latencyProgressSections;
  const subscriptionUpdatingSections: Record<string, boolean> = {};
  const latencyFetchingSections: Record<string, boolean> = {};
  const latencyProgressSections: Record<string, Forkop.LatencyActionProgress> =
    {};
  const updatesActions = getEmptyUpdatesActions();
  const diagnosticsActions = getEmptyDiagnosticsActions();

  for (const state of actions.subscription || []) {
    if (isRunningAction(state)) {
      subscriptionUpdatingSections[state.section || '*'] = true;
    }
  }

  for (const state of actions.latency || []) {
    if (isRunningAction(state) && state.section) {
      latencyFetchingSections[state.section] = true;
      const progress = normalizeLatencyProgress(state.progress);
      if (progress) {
        latencyProgressSections[state.section] = progress;
      } else if (currentLatencyProgressSections[state.section]) {
        latencyProgressSections[state.section] =
          currentLatencyProgressSections[state.section];
      }
    }
  }

  for (const state of actions.component || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    const key = getComponentActionKey(state.component, state.action);
    if (key) {
      updatesActions[key] = { loading: true };
    }
  }

  for (const state of actions.service || []) {
    if (!isRunningAction(state)) {
      continue;
    }

    if (state.action === 'start') {
      diagnosticsActions.start = { loading: true };
    } else if (state.action === 'stop') {
      diagnosticsActions.stop = { loading: true };
    } else if (state.action === 'restart' || state.action === 'reload') {
      diagnosticsActions.restart = { loading: true };
    }
  }

  for (const section of localOverlay.subscriptionSections) {
    subscriptionUpdatingSections[section] = true;
  }

  for (const section of localOverlay.latencySections) {
    latencyFetchingSections[section] = true;
    if (
      !latencyProgressSections[section] &&
      currentLatencyProgressSections[section]
    ) {
      latencyProgressSections[section] =
        currentLatencyProgressSections[section];
    }
  }

  for (const key of localOverlay.componentActions) {
    updatesActions[key] = { loading: true };
  }

  for (const action of localOverlay.serviceActions) {
    diagnosticsActions[action] = { loading: true };
  }

  store.set({
    sectionsWidget: {
      ...current.sectionsWidget,
      subscriptionUpdatingSections,
      latencyFetchingSections,
      latencyProgressSections,
    },
    updatesActions,
    diagnosticsActions,
  });
}

export function applyUiStateToStore(uiState: Forkop.UiState) {
  applyServiceState(uiState);
  applyActionState(uiState.actions);
}
