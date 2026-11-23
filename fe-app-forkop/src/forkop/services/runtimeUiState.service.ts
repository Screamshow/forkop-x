import { ForkopShellMethods } from '../methods/shell';
import { isReadOnlyForkopView } from '../methods/shell/readForkopStatus';
import { Forkop } from '../types';
import { logger } from './logger.service';
import { applyUiStateToStore } from './uiState.service';

const RUNTIME_UI_STATE_REFRESH_MIN_INTERVAL_MS = 500;
const RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS = 1000;
const RUNTIME_UI_STATE_ACTIVE_POLL_INTERVAL_MS = 500;
const RUNTIME_UI_HEALTH_POLL_INTERVAL_MS = 5000;
type RuntimeUiStateListener = (uiState: Forkop.UiState) => void;

let runtimeUiStateRefreshPromise: Promise<Forkop.UiState | undefined> | null =
  null;
let lastRuntimeUiStateRefreshAt = 0;
let lastRuntimeUiHealthRefreshAt = 0;
let runtimeUiStateRefreshesHealth = false;
let lastRuntimeUiState: Forkop.UiState | undefined;
let runtimeStateResumeRefreshRegistered = false;
let runtimeStatePollTimer: ReturnType<typeof setTimeout> | null = null;
let runtimeStatePollingStarted = false;
let runtimeStateHasRunningAction = false;
const runtimeUiStateListeners = new Set<RuntimeUiStateListener>();

function isDocumentVisible() {
  return (
    typeof document === 'undefined' ||
    !document.visibilityState ||
    document.visibilityState === 'visible'
  );
}

function hasRunningAction(uiState: Forkop.UiState) {
  return Object.values(uiState.actions).some((actions) =>
    actions.some((action) => action.running),
  );
}

function getNextPollDelay() {
  if (isReadOnlyForkopView()) return RUNTIME_UI_HEALTH_POLL_INTERVAL_MS;
  return runtimeStateHasRunningAction
    ? RUNTIME_UI_STATE_ACTIVE_POLL_INTERVAL_MS
    : RUNTIME_UI_STATE_IDLE_POLL_INTERVAL_MS;
}

function scheduleRuntimeUiStatePoll(delay = getNextPollDelay()) {
  if (
    !runtimeStatePollingStarted ||
    runtimeStatePollTimer ||
    typeof window === 'undefined'
  ) {
    return;
  }

  runtimeStatePollTimer = window.setTimeout(() => {
    runtimeStatePollTimer = null;
    void refreshRuntimeUiState({
      actionsOnly:
        !isReadOnlyForkopView() &&
        Date.now() - lastRuntimeUiHealthRefreshAt <
          RUNTIME_UI_HEALTH_POLL_INTERVAL_MS,
    })
      .catch(() => undefined)
      .finally(() => {
        scheduleRuntimeUiStatePoll();
      });
  }, delay);
}

function notifyRuntimeUiStateListeners(uiState: Forkop.UiState) {
  for (const listener of runtimeUiStateListeners) {
    try {
      listener(uiState);
    } catch (error) {
      logger.error('[RUNTIME_UI_STATE]', 'listener failed', error);
    }
  }
}

export async function refreshRuntimeUiState({
  force = false,
  actionsOnly = false,
}: { force?: boolean; actionsOnly?: boolean } = {}): Promise<
  Forkop.UiState | undefined
> {
  if (!isDocumentVisible()) {
    return undefined;
  }

  if (runtimeUiStateRefreshPromise) {
    if (force && !actionsOnly && !runtimeUiStateRefreshesHealth) {
      await runtimeUiStateRefreshPromise;
      return refreshRuntimeUiState({ force });
    }
    return runtimeUiStateRefreshPromise;
  }

  const now = Date.now();
  if (
    !force &&
    now - lastRuntimeUiStateRefreshAt < RUNTIME_UI_STATE_REFRESH_MIN_INTERVAL_MS
  ) {
    return undefined;
  }

  lastRuntimeUiStateRefreshAt = now;
  const baseline = actionsOnly ? lastRuntimeUiState : undefined;
  runtimeUiStateRefreshesHealth = !baseline;
  if (!baseline) lastRuntimeUiHealthRefreshAt = now;
  const state = baseline
    ? ForkopShellMethods.getUiActionState().then((response) =>
        response.success ? { ...baseline, actions: response.data } : undefined,
      )
    : ForkopShellMethods.getUiState().then((response) =>
        response.success ? response.data : undefined,
      );
  const promise = state
    .then((next) => {
      if (!next) return undefined;
      applyUiStateToStore(next);
      lastRuntimeUiState = next;
      runtimeStateHasRunningAction = hasRunningAction(next);
      notifyRuntimeUiStateListeners(next);
      return next;
    })
    .catch((error) => {
      logger.error('[RUNTIME_UI_STATE]', 'refresh failed', error);
      return undefined;
    })
    .finally(() => {
      if (runtimeUiStateRefreshPromise === promise) {
        runtimeUiStateRefreshPromise = null;
      }
    });

  runtimeUiStateRefreshPromise = promise;
  return runtimeUiStateRefreshPromise;
}

export function subscribeRuntimeUiState(listener: RuntimeUiStateListener) {
  runtimeUiStateListeners.add(listener);

  if (lastRuntimeUiState) {
    try {
      listener(lastRuntimeUiState);
    } catch (error) {
      logger.error('[RUNTIME_UI_STATE]', 'listener failed', error);
    }
  }

  return () => {
    runtimeUiStateListeners.delete(listener);
  };
}

export function getCachedRuntimeUiState() {
  return lastRuntimeUiState;
}

export function registerRuntimeStateResumeRefresh() {
  if (runtimeStateResumeRefreshRegistered || typeof window === 'undefined') {
    return;
  }

  runtimeStateResumeRefreshRegistered = true;

  const refreshOnResume = () => {
    if (!isDocumentVisible()) {
      return;
    }

    void refreshRuntimeUiState({ force: true });
  };

  document.addEventListener('visibilitychange', refreshOnResume);
  window.addEventListener('pageshow', refreshOnResume);
  window.addEventListener('focus', refreshOnResume);
}

export function startRuntimeUiStatePolling() {
  if (runtimeStatePollingStarted || typeof window === 'undefined') {
    return;
  }

  runtimeStatePollingStarted = true;
  void refreshRuntimeUiState({ force: true }).finally(() => {
    scheduleRuntimeUiStatePoll();
  });
}
