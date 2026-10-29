import { onMount, preserveScrollForPage } from '../../../helpers';
import { normalizeCompiledVersion } from '../../../helpers/normalizeCompiledVersion';
import { showToast } from '../../../helpers/showToast';
import { copyToClipboard } from '../../../helpers/copyToClipboard';
import {
  renderDownloadIcon24,
  renderCopyIcon24,
  renderRotateCcwIcon24,
  renderSearchIcon24,
  renderXIcon24,
} from '../../../icons';
import { renderButton } from '../../../partials';
import { getComponentActionKey } from '../../helpers/getComponentActionKey';
import type { UpdatesActionKey } from '../../helpers/getComponentActionKey';
import { isTransientRpcError } from '../../helpers/isTransientRpcError';
import { isActiveLuciTab } from '../../helpers/isActiveLuciTab';
import { shouldShowLoadingForRestoredAction } from '../../helpers/restoredActionLoading';
import {
  formatSingBoxVersion,
  getSingBoxName,
  getSingBoxXVersion,
  getRustXVersion,
  normalizeSingBoxVariantFields,
} from '../../helpers/singBoxVariant';
import {
  hasLocalMutatingServiceActionLoading,
  isServiceTransitionStatus,
} from '../diagnostic/serviceTransition';
import { shouldApplyCompletedComponentActionResult } from './componentActionCompletion';
import {
  shouldPreserveCompletedCheckResultOnNextMount,
  shouldExposeCheckResults,
  shouldRefreshComponentStateBeforeRender,
  shouldResetCheckResultsOnMount,
} from './checkResultLifecycle';
import { ForkopShellMethods } from '../../methods';
import {
  logger,
  markUiActionOwned,
  setLocalComponentAction,
  shouldNotifyOwnedUiAction,
  store,
  StoreType,
} from '../../services';
import { ensureSystemInfo } from '../../services/systemInfo.service';
import {
  getCachedRuntimeUiState,
  refreshRuntimeUiState,
  subscribeRuntimeUiState,
} from '../../services/runtimeUiState.service';
import { Forkop } from '../../types';
import { renderFullUninstall } from './fullUninstall';
import { renderLanguage } from './language';
import {
  RUST_X_RELEASE_SELECTOR,
  showReleaseSelector,
} from './releaseSelector';

type UpdateStatus = StoreType['updatesChecks'][Forkop.ComponentName]['status'];

interface ComponentActionButton {
  key: UpdatesActionKey;
  text: string;
  icon: () => SVGSVGElement;
  component: Forkop.ComponentName;
  action: Forkop.ComponentAction;
  disabled?: boolean;
  version?: string;
}

interface ComponentCard {
  description?: string;
  component: Forkop.ComponentName;
  column: 0 | 1 | 2;
  title: string;
  version: string;
  latestVersion?: string;
  releaseUrl?: string;
  actions: ComponentActionButton[];
  copyValue?: string;
}

let updatesLifecycleRegistered = false;
let updatesControllerInitialized = false;
let updatesMounted = false;
let updatesMountId = 0;
let pageUnloading = false;
let preserveCheckResultsOnNextMount = false;
let componentUpdateCheckCacheResolved = false;
let componentUpdateCheckCacheSnapshot: Forkop.ComponentUpdateCheckCache | null =
  null;
let componentUpdateCheckCachePromise: Promise<Forkop.ComponentUpdateCheckCache> | null =
  null;
let componentActionStateUnsubscribe: (() => void) | null = null;
let componentActionStateRefreshPromise: Promise<void> | null = null;
const followedComponentJobs = new Set<string>();
const handledComponentJobs = new Set<string>();

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    pageUnloading = true;
  });
  window.addEventListener('pageshow', () => {
    pageUnloading = false;
  });
}

function shouldShowInstallAfterCheck(component: Forkop.ComponentName) {
  const status = getVisibleCheckResult(component)?.status;

  return status === 'outdated' || status === 'dev';
}

function getVisibleCheckResult(component: Forkop.ComponentName) {
  if (
    !shouldExposeCheckResults({
      mounted: updatesMounted,
      cacheResolved: componentUpdateCheckCacheResolved,
    })
  ) {
    return null;
  }

  return store.get().updatesChecks[component];
}

function getLatestVersion(component: Forkop.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (!checkResult || !shouldShowInstallAfterCheck(component)) {
    return undefined;
  }

  return checkResult.latest_version || undefined;
}

function getGitHubReleaseUrl(component: Forkop.ComponentName) {
  const checkResult = getVisibleCheckResult(component);

  if (
    !checkResult ||
    !shouldShowInstallAfterCheck(component) ||
    !checkResult.release_url
  ) {
    return undefined;
  }

  return checkResult.release_url;
}

function isAnyActionLoading() {
  return Object.values(store.get().updatesActions).some((item) => item.loading);
}

function isServiceRuntimeActionLoading() {
  const state = store.get();

  return (
    hasLocalMutatingServiceActionLoading(state.diagnosticsActions) ||
    isServiceTransitionStatus(state.servicesInfoWidget.data.forkopStatus)
  );
}

function isSystemInfoLoading() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return systemInfo.loading || !systemInfo.loaded;
}

function setActionLoading(
  action: UpdatesActionKey,
  loading: boolean,
  local = false,
) {
  if (local || !loading) {
    setLocalComponentAction(action, loading && local);
  }

  const updatesActions = store.get().updatesActions;

  store.set({
    updatesActions: {
      ...updatesActions,
      [action]: { loading },
    },
  });
}

function beginComponentAction(button: ComponentActionButton) {
  if (isAnyActionLoading()) {
    return false;
  }

  setActionLoading(button.key, true, true);
  return true;
}

function setCheckResult(
  component: Forkop.ComponentName,
  status: UpdateStatus,
  latestVersion: string,
  releaseUrl: string = '',
) {
  const updatesChecks = store.get().updatesChecks;

  store.set({
    updatesChecks: {
      ...updatesChecks,
      [component]: {
        status,
        latest_version: latestVersion,
        release_url: releaseUrl,
      },
    },
  });
}

function resetCheckResult(component: Forkop.ComponentName) {
  setCheckResult(component, null, '');
}

function applyCachedCheckResults(results: Forkop.ComponentActionResult[]) {
  results.forEach((result) => {
    const status = result.status || null;

    if (status === 'latest' || status === 'outdated' || status === 'dev') {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
      );
    }
  });
}

function loadComponentUpdateCheckCache({ force = false } = {}) {
  if (!force && componentUpdateCheckCacheSnapshot) {
    return Promise.resolve(componentUpdateCheckCacheSnapshot);
  }

  if (componentUpdateCheckCachePromise) {
    return componentUpdateCheckCachePromise;
  }

  const promise = ForkopShellMethods.componentUpdateCheckCache()
    .then((response) =>
      response.success
        ? response.data
        : ({
            enabled: false,
            results: [],
          } satisfies Forkop.ComponentUpdateCheckCache),
    )
    .then((cache) => {
      componentUpdateCheckCacheSnapshot = cache;
      return cache;
    })
    .finally(() => {
      if (componentUpdateCheckCachePromise === promise) {
        componentUpdateCheckCachePromise = null;
      }
    });

  componentUpdateCheckCachePromise = promise;
  return promise;
}

function getErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error && error.message ? error.message : fallback;
}

async function ackComponentActionJob(jobId: string) {
  try {
    const response = await ForkopShellMethods.uiActionAck('component', jobId);

    if (!response.success) {
      logger.debug('[UPDATES]', 'component action ack failed', response.error);
    }
  } catch (error) {
    logger.debug('[UPDATES]', 'component action ack failed', error);
  }
}

function getExpectedLatestVersionForAction(button: ComponentActionButton) {
  if (button.component !== 'forkop' || button.action !== 'install') {
    return undefined;
  }

  return (
    store.get().updatesChecks[button.component].latest_version || undefined
  );
}

function getCheckToastMessage(status: UpdateStatus) {
  if (status === 'outdated') {
    return _('Update is available');
  }

  if (status === 'dev') {
    return _('Installed version is newer than release');
  }

  return _('Latest version is installed');
}

async function refreshSystemInfoAfterMutation() {
  await ensureSystemInfo({ force: true, silent: true });
}

function reloadPageAfterForkopUpdate() {
  window.setTimeout(() => {
    window.location.reload();
  }, 1200);
}

function patchSystemInfoAfterMutation(result: Forkop.ComponentActionResult) {
  const systemInfo = store.get().diagnosticsSystemInfo;
  const nextSystemInfo = { ...systemInfo, loading: false, loaded: true };
  const version =
    result.current_version || result.latest_version || _('unknown');

  if (result.component === 'forkop' && result.action === 'install') {
    nextSystemInfo.forkop_version = version;
  }

  if (result.component === 'sing_box') {
    nextSystemInfo.sing_box_version = version;

    if (
      result.action === 'install_stable' ||
      result.action === 'install_x' ||
      result.action === 'install_rust_x'
    ) {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 0;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = result.action === 'install_x' ? 0 : 1;
    }

    if (result.action === 'install_tiny') {
      nextSystemInfo.sing_box_extended = 0;
      nextSystemInfo.sing_box_tiny = 1;
      nextSystemInfo.sing_box_compressed = 0;
      nextSystemInfo.sing_box_tailscale = 0;
    }
  }

  if (result.component === 'zapret_manager') {
    nextSystemInfo.zapret_manager_installed =
      result.action === 'remove' ? 0 : 1;
  }

  if (result.component === 'direct_proxy') {
    nextSystemInfo.direct_proxy_enabled = result.action === 'enable' ? 1 : 0;
  }
  if (result.component === 'torrserver_direct') {
    nextSystemInfo.torrserver_direct_enabled =
      result.action === 'enable' ? 1 : 0;
    nextSystemInfo.torrserver_direct_active =
      result.action === 'enable' ? 1 : 0;
  }

  store.set({
    diagnosticsSystemInfo: normalizeSingBoxVariantFields(nextSystemInfo),
  });
}

async function applyCompletedComponentAction({
  key,
  result,
  notify,
}: {
  key: UpdatesActionKey;
  result: Forkop.ComponentActionResult;
  notify: boolean;
}) {
  if (result.action === 'check_update') {
    setActionLoading(key, false);

    if (!shouldApplyCompletedComponentActionResult(result, notify)) {
      return;
    }

    if (
      shouldPreserveCompletedCheckResultOnNextMount({
        action: result.action,
        mounted: updatesMounted,
      })
    ) {
      preserveCheckResultsOnNextMount = true;
    }

    const status = result.status || null;

    if (status === 'latest' || status === 'outdated' || status === 'dev') {
      setCheckResult(
        result.component,
        status,
        result.latest_version || '',
        result.release_url || '',
      );
    }

    if (notify) {
      showToast(getCheckToastMessage(status), 'success');
    }
    return;
  }

  if (result.action === 'install' || result.action.startsWith('install_')) {
    setCheckResult(result.component, 'latest', result.latest_version || '');
  } else {
    resetCheckResult(result.component);
  }

  patchSystemInfoAfterMutation(result);
  setActionLoading(key, false);

  if (result.component === 'forkop' && result.action === 'install') {
    if (notify && result.message) {
      showToast(result.message, 'success', 1200);
    }

    if (notify && result.changed) {
      reloadPageAfterForkopUpdate();
    }
    return;
  }

  if (notify && result.message) {
    showToast(result.message, 'success');
  }

  void refreshSystemInfoAfterMutation();
}

async function completeComponentActionJob(
  key: UpdatesActionKey,
  jobId: string,
  response: Forkop.MethodResponse<Forkop.ComponentActionResult>,
) {
  if (pageUnloading) {
    setActionLoading(key, false);
    return;
  }

  const alreadyHandled = handledComponentJobs.has(jobId);

  if (alreadyHandled) {
    setActionLoading(key, false);
    return;
  }

  const shouldNotify = shouldNotifyOwnedUiAction('component', jobId);

  if (!response.success || response.data.success === false) {
    const message = response.success
      ? response.data.message || _('Failed to execute')
      : response.error || _('Failed to execute');

    if (isTransientRpcError(message)) {
      setActionLoading(key, false);
      void refreshComponentActionState();
      return;
    }

    handledComponentJobs.add(jobId);
    setActionLoading(key, false);
    if (shouldNotify) {
      showToast(message, 'error');
    }
    await ackComponentActionJob(jobId);
    return;
  }

  handledComponentJobs.add(jobId);
  await ackComponentActionJob(jobId);
  await applyCompletedComponentAction({
    key,
    result: response.data,
    notify: shouldNotify,
  });
}

async function followComponentActionState(state: Forkop.ComponentActionResult) {
  const jobId = state.job_id;
  const key = getComponentActionKey(state.component, state.action);

  if (!jobId || !key || followedComponentJobs.has(jobId)) {
    return;
  }

  if (!state.running && handledComponentJobs.has(jobId)) {
    return;
  }

  followedComponentJobs.add(jobId);
  if (shouldShowLoadingForRestoredAction(state)) {
    setActionLoading(key, true);
  }

  try {
    const response = state.running
      ? await ForkopShellMethods.waitComponentActionJob(
          jobId,
          state.component,
          state.action,
          state.latest_version || undefined,
        )
      : ({
          success: true,
          data: state,
        } as Forkop.MethodSuccessResponse<Forkop.ComponentActionResult>);

    await completeComponentActionJob(key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'followComponentActionState failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
    }
  } finally {
    followedComponentJobs.delete(jobId);
  }
}

async function followAlreadyRunningComponentAction(
  button: ComponentActionButton,
) {
  const uiState = await refreshRuntimeUiState({ force: true });

  if (!uiState) {
    return false;
  }

  const state = uiState.actions.component.find(
    (item) =>
      item.running &&
      item.component === button.component &&
      item.action === button.action,
  );

  if (!state) {
    return false;
  }

  if (state.job_id) {
    markUiActionOwned('component', state.job_id);
  }
  await followComponentActionState(state);
  return true;
}

function isComponentActionAlreadyRunningError(message: string | undefined) {
  return Boolean(
    message && message.includes('Another component action is already running'),
  );
}

function handleComponentUiState(uiState: Forkop.UiState) {
  for (const state of uiState.actions.component || []) {
    void followComponentActionState(state);
  }
}

async function refreshComponentActionState() {
  if (componentActionStateRefreshPromise) {
    return componentActionStateRefreshPromise;
  }

  componentActionStateRefreshPromise = (async () => {
    if (!updatesMounted) {
      return;
    }

    const state = await refreshRuntimeUiState({ force: true });

    if (!state) {
      return;
    }

    handleComponentUiState(state);
  })().finally(() => {
    componentActionStateRefreshPromise = null;
  });

  return componentActionStateRefreshPromise;
}

function startComponentActionStateWatcher() {
  if (componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe = subscribeRuntimeUiState((uiState) => {
    if (updatesMounted) {
      handleComponentUiState(uiState);
    }
  });
}

function stopComponentActionStateWatcher() {
  if (!componentActionStateUnsubscribe) {
    return;
  }

  componentActionStateUnsubscribe();
  componentActionStateUnsubscribe = null;
}

async function handleComponentAction(button: ComponentActionButton) {
  if (!beginComponentAction(button)) {
    return;
  }

  let jobId = '';
  let ownsJobFollow = false;

  try {
    const startResponse = await ForkopShellMethods.componentActionStart(
      button.component,
      button.action,
      button.version,
    );

    if (!startResponse.success) {
      if (isComponentActionAlreadyRunningError(startResponse.error)) {
        setActionLoading(button.key, false);
        if (!(await followAlreadyRunningComponentAction(button))) {
          await refreshComponentActionState();
        }
        return;
      }

      if (isTransientRpcError(startResponse.error)) {
        if (!(await followAlreadyRunningComponentAction(button))) {
          setActionLoading(button.key, false);
          await refreshComponentActionState();
        }
        return;
      }

      throw new Error(startResponse.error);
    }

    jobId = startResponse.data.job_id;
    markUiActionOwned('component', jobId);
    if (followedComponentJobs.has(jobId)) {
      return;
    }

    followedComponentJobs.add(jobId);
    ownsJobFollow = true;

    const response = await ForkopShellMethods.waitComponentActionJob(
      jobId,
      button.component,
      button.action,
      button.version || getExpectedLatestVersionForAction(button),
    );

    await completeComponentActionJob(button.key, jobId, response);
  } catch (error) {
    logger.error('[UPDATES]', 'handleComponentAction failed', error);
    if (!pageUnloading) {
      const message = getErrorMessage(error, _('Failed to execute'));

      setActionLoading(button.key, false);
      if (!isTransientRpcError(message)) {
        showToast(message, 'error');
      }
      void refreshComponentActionState();
    }
  } finally {
    if (ownsJobFollow) {
      followedComponentJobs.delete(jobId);
    }
  }
}

function getCheckAction(
  component: Forkop.ComponentName,
  key: UpdatesActionKey,
): ComponentActionButton {
  return {
    key,
    text: _('Check update'),
    icon: renderSearchIcon24,
    component,
    action: 'check_update',
  };
}

function getInstallAction(
  component: Forkop.ComponentName,
  key: UpdatesActionKey,
  installed: boolean,
): ComponentActionButton {
  return {
    key,
    text: installed ? _('Update') : _('Install'),
    icon: installed ? renderRotateCcwIcon24 : renderDownloadIcon24,
    component,
    action: 'install',
  };
}

function getInstalledUpdateActions(
  component: Forkop.ComponentName,
  checkKey: UpdatesActionKey,
  installKey: UpdatesActionKey,
  installed = true,
) {
  if (!installed) {
    return [];
  }

  const actions = [getCheckAction(component, checkKey)];
  if (shouldShowInstallAfterCheck(component)) {
    actions.push(getInstallAction(component, installKey, true));
  }
  return actions;
}

function getComponentCards(): ComponentCard[] {
  const systemInfo = normalizeSingBoxVariantFields(
    store.get().diagnosticsSystemInfo,
  );
  const systemInfoLoading = isSystemInfoLoading();
  const zapretManagerInstalled = Boolean(systemInfo.zapret_manager_installed);
  const packetSteeringEnabled = systemInfo.packet_steering_mode === '2';
  const directProxyEnabled = Boolean(systemInfo.direct_proxy_enabled);
  const directProxyEndpoint = systemInfo.direct_proxy_address
    ? `${systemInfo.direct_proxy_address}:${systemInfo.direct_proxy_port || '2080'}`
    : '';
  const torrserverRunning = Boolean(systemInfo.torrserver_running);
  const torrserverDirectAvailable = Boolean(
    systemInfo.torrserver_direct_available,
  );
  const torrserverDirectEnabled = Boolean(systemInfo.torrserver_direct_enabled);
  const torrserverDirectActive = Boolean(systemInfo.torrserver_direct_active);
  const singBoxTiny = Boolean(systemInfo.sing_box_tiny);
  const rustX = Boolean(getRustXVersion(systemInfo.sing_box_version));
  const singBoxX = Boolean(getSingBoxXVersion(systemInfo.sing_box_version));

  const forkopActions = getInstalledUpdateActions(
    'forkop',
    'forkopCheck',
    'forkopInstall',
  );
  // A manually installed sing-box-extended (packaged or compressed) keeps
  // working, but Forkop neither installs nor updates it.
  const singBoxActions = getInstalledUpdateActions(
    'sing_box',
    'singBoxCheck',
    'singBoxInstall',
    rustX || singBoxX || singBoxTiny,
  );

  if (!rustX) {
    singBoxActions.push({
      key: 'singBoxInstallRustX',
      text: _('Xrust (experimental)'),
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_rust_x',
    });
  }
  if (!singBoxX) {
    singBoxActions.push({
      key: 'singBoxInstallX',
      text: 'Sing-Box X',
      icon: renderDownloadIcon24,
      component: 'sing_box',
      action: 'install_x',
    });
  }

  const zapretManagerActions: ComponentActionButton[] = zapretManagerInstalled
    ? [
        {
          key: 'zapretManagerInstall',
          text: _('Update'),
          icon: renderDownloadIcon24,
          component: 'zapret_manager',
          action: 'install',
        },
        {
          key: 'zapretManagerRemove',
          text: _('Remove'),
          icon: renderXIcon24,
          component: 'zapret_manager',
          action: 'remove',
        },
      ]
    : [
        {
          key: 'zapretManagerInstall',
          text: _('Install'),
          icon: renderDownloadIcon24,
          component: 'zapret_manager',
          action: 'install',
        },
      ];

  return [
    {
      component: 'forkop',
      column: 0,
      title: 'Forkop X',
      version: systemInfoLoading
        ? _('Loading...')
        : normalizeCompiledVersion(systemInfo.forkop_version),
      latestVersion: getLatestVersion('forkop'),
      releaseUrl: getGitHubReleaseUrl('forkop'),
      actions: forkopActions,
    },
    {
      component: 'sing_box',
      column: 0,
      title: getSingBoxName(systemInfo),
      version: systemInfoLoading
        ? _('Loading...')
        : formatSingBoxVersion(systemInfo),
      latestVersion: getLatestVersion('sing_box'),
      releaseUrl: getGitHubReleaseUrl('sing_box'),
      actions: singBoxActions,
    },
    {
      component: 'zapret_manager',
      column: 2,
      title: 'Zapret Manager',
      version: zapretManagerInstalled ? _('Installed') : _('Not installed'),
      latestVersion: '',
      releaseUrl: 'https://github.com/Screamshow/Zapret-Manager',
      actions: zapretManagerActions,
    },
    {
      component: 'packet_steering',
      column: 1,
      title: 'Packet Steering',
      description:
        'Распределяет обработку сетевого трафика между ядрами процессора. Может повысить скорость на многоядерных роутерах. Эффект зависит от устройства и нагрузки.',
      version: packetSteeringEnabled ? _('Mode 2 enabled') : _('Normal mode'),
      actions: [
        packetSteeringEnabled
          ? {
              key: 'packetSteeringRestore',
              text: _('Restore normal mode'),
              icon: renderRotateCcwIcon24,
              component: 'packet_steering',
              action: 'restore',
            }
          : {
              key: 'packetSteeringEnable',
              text: _('Enable mode 2'),
              icon: renderRotateCcwIcon24,
              component: 'packet_steering',
              action: 'enable',
            },
      ],
    },
    {
      component: 'direct_proxy',
      column: 1,
      title: _('Direct Proxy'),
      description:
        'Позволяет приложениям и устройствам подключаться к прокси Forkop X по HTTP или SOCKS5 уходя в Direct. Рекомендуется для торрентов.',
      version: directProxyEnabled
        ? `HTTP/SOCKS5 · ${directProxyEndpoint || _('Enabled')}`
        : _('Disabled'),
      copyValue: directProxyEnabled ? directProxyEndpoint : undefined,
      actions: [
        directProxyEnabled
          ? {
              key: 'directProxyDisable',
              text: _('Disable'),
              icon: renderXIcon24,
              component: 'direct_proxy',
              action: 'disable',
            }
          : {
              key: 'directProxyEnable',
              text: _('Enable'),
              icon: renderRotateCcwIcon24,
              component: 'direct_proxy',
              action: 'enable',
            },
      ],
    },
    {
      component: 'torrserver_direct',
      column: 1,
      title: _('TorrServer Direct'),
      description:
        'Позволяет TorrServer обходить правила маршрутизации Forkop X.',
      version: !torrserverRunning
        ? _('TorrServer not found')
        : !torrserverDirectAvailable
          ? _('Dedicated cgroup unavailable')
          : torrserverDirectEnabled && torrserverDirectActive
            ? _('Enabled')
            : torrserverDirectEnabled
              ? _('Waiting for TorrServer')
              : _('Disabled'),
      actions: [
        torrserverDirectEnabled
          ? {
              key: 'torrserverDirectDisable',
              text: _('Disable'),
              icon: renderXIcon24,
              component: 'torrserver_direct',
              action: 'disable',
            }
          : {
              key: 'torrserverDirectEnable',
              text: _('Enable'),
              icon: renderRotateCcwIcon24,
              component: 'torrserver_direct',
              action: 'enable',
              disabled: !torrserverDirectAvailable,
            },
      ],
    },
  ];
}

function renderComponentCard(card: ComponentCard) {
  const updatesActions = store.get().updatesActions;
  const anyActionLoading = isAnyActionLoading();
  const serviceRuntimeActionLoading = isServiceRuntimeActionLoading();
  const systemInfoLoading = isSystemInfoLoading();

  // 1. Header (displays Title, Current Version, no badges)
  const headerChildren: Node[] = [
    E(
      'b',
      {
        class: 'fkp_updates-page__component__title',
        title: card.description || '',
      },
      card.title,
    ),
    E(
      'span',
      { class: 'fkp_updates-page__component__header-version' },
      card.version,
    ),
  ];
  const header = E(
    'div',
    { class: 'fkp_updates-page__component__header' },
    headerChildren,
  );

  // 2. Details (renders status messages for check results)
  const detailsChildren: Node[] = [];
  const checkResult = getVisibleCheckResult(card.component);

  if (checkResult && checkResult.status) {
    let labelText = '';
    const latestValueNodes: Node[] = [];

    if (checkResult.status === 'outdated') {
      labelText = _('Update is available:');
      const versionToShow =
        checkResult.latest_version || card.latestVersion || card.version;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'fkp_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            versionToShow || _('Open'),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    } else if (checkResult.status === 'latest') {
      labelText = _('Latest version is installed');
    } else if (checkResult.status === 'dev') {
      labelText = `${_('Installed version is newer than release')}. ${_('Latest version:')}`;
      const versionToShow = checkResult.latest_version || card.latestVersion;

      if (checkResult.release_url) {
        latestValueNodes.push(
          E(
            'a',
            {
              class: 'fkp_updates-page__component__release-version-link',
              href: checkResult.release_url,
              target: '_blank',
              rel: 'noopener noreferrer',
            },
            versionToShow || _('Open'),
          ),
        );
      } else if (versionToShow) {
        latestValueNodes.push(document.createTextNode(versionToShow));
      }
    }

    if (labelText) {
      const rowChildren: Node[] = [
        E(
          'span',
          { class: 'fkp_updates-page__component__info-label' },
          labelText,
        ),
      ];
      if (latestValueNodes.length > 0) {
        rowChildren.push(
          E(
            'span',
            {
              class:
                'fkp_updates-page__component__info-value fkp_updates-page__component__info-value--latest',
            },
            latestValueNodes,
          ),
        );
      }

      detailsChildren.push(
        E(
          'div',
          { class: 'fkp_updates-page__component__info-row' },
          rowChildren,
        ),
      );
    }
  }

  const detailsContainer =
    detailsChildren.length > 0
      ? E(
          'div',
          { class: 'fkp_updates-page__component__details' },
          detailsChildren,
        )
      : null;

  // 3. Actions classification
  const primaryActions: ComponentActionButton[] = [];
  const dangerActions: ComponentActionButton[] = [];
  const variantActions: ComponentActionButton[] = [];

  card.actions.forEach((action) => {
    if (action.action === 'remove') {
      dangerActions.push(action);
    } else if (action.action.startsWith('install_')) {
      variantActions.push(action);
    } else {
      primaryActions.push(action);
    }
  });

  const actionElements: Node[] = [];

  // Render primary and danger buttons in a main row
  const primaryButtons = primaryActions.map((action) => {
    const loading = updatesActions[action.key].loading;
    const isUpdateOrInstall = action.action === 'install';

    return renderButton({
      classNames: isUpdateOrInstall ? ['cbi-button-save'] : [],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        action.disabled ||
        systemInfoLoading ||
        serviceRuntimeActionLoading ||
        (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  if (card.component === 'forkop') {
    primaryButtons.push(
      renderButton({
        text: _('Choose version'),
        disabled:
          systemInfoLoading || serviceRuntimeActionLoading || anyActionLoading,
        onClick: () =>
          void showReleaseSelector(card.version, (version) => {
            void handleComponentAction({
              key: 'forkopInstall',
              text: _('Install'),
              icon: renderDownloadIcon24,
              component: 'forkop',
              action: 'install',
              version,
            });
          }),
      }),
    );
  }

  if (card.component === 'sing_box') {
    // Any Xrust release published on the mirror, also from another core.
    const rustXVersion =
      getRustXVersion(store.get().diagnosticsSystemInfo.sing_box_version) || '';
    primaryButtons.push(
      renderButton({
        text: _('Xrust version'),
        disabled:
          systemInfoLoading || serviceRuntimeActionLoading || anyActionLoading,
        onClick: () =>
          void showReleaseSelector(
            rustXVersion,
            (version) => {
              void handleComponentAction({
                key: 'singBoxInstallRustX',
                text: _('Xrust (experimental)'),
                icon: renderDownloadIcon24,
                component: 'sing_box',
                action: 'install_rust_x',
                version,
              });
            },
            RUST_X_RELEASE_SELECTOR,
          ),
      }),
    );
  }

  const dangerButtons = dangerActions.map((action) => {
    const loading = updatesActions[action.key].loading;

    return renderButton({
      classNames: ['cbi-button-remove'],
      text: action.text,
      icon: action.icon,
      loading,
      disabled:
        systemInfoLoading ||
        serviceRuntimeActionLoading ||
        (anyActionLoading && !loading),
      onClick: () => void handleComponentAction(action),
    });
  });

  if (primaryButtons.length > 0 || dangerButtons.length > 0) {
    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__actions-main' }, [
        ...primaryButtons,
        ...dangerButtons,
      ]),
    );
  }

  if (card.copyValue) {
    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__actions-main' }, [
        renderButton({
          text: _('Copy address'),
          icon: renderCopyIcon24,
          disabled: anyActionLoading || serviceRuntimeActionLoading,
          onClick: () => copyToClipboard(card.copyValue || ''),
        }),
      ]),
    );
  }

  // Render variant buttons if any
  if (variantActions.length > 0) {
    const variantButtons = variantActions.map((action) => {
      const loading = updatesActions[action.key].loading;
      return renderButton({
        text: action.text,
        icon: action.icon,
        loading,
        disabled:
          systemInfoLoading ||
          serviceRuntimeActionLoading ||
          (anyActionLoading && !loading),
        onClick: () => void handleComponentAction(action),
      });
    });

    actionElements.push(
      E('div', { class: 'fkp_updates-page__component__variants' }, [
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-title' },
          _('Install another build:'),
        ),
        E(
          'div',
          { class: 'fkp_updates-page__component__variants-buttons' },
          variantButtons,
        ),
      ]),
    );
  }

  const actionsContainer = E(
    'div',
    {
      class: [
        'fkp_updates-page__component__actions',
        detailsContainer
          ? 'fkp_updates-page__component__actions--with-details'
          : '',
      ]
        .filter(Boolean)
        .join(' '),
    },
    actionElements,
  );

  const cardChildren: Node[] = [header];
  if (detailsContainer) {
    cardChildren.push(detailsContainer);
  }
  cardChildren.push(actionsContainer);

  return E('div', { class: 'fkp_updates-page__component' }, cardChildren);
}

function renderUpdatesComponents() {
  const container = document.getElementById('fkp_updates-components');

  if (!container) {
    return;
  }

  const columns = [[], [], []] as Node[][];
  getComponentCards().forEach((card) => {
    columns[card.column].push(renderComponentCard(card));
  });
  columns[0].push(
    renderLanguage(isAnyActionLoading() || isServiceRuntimeActionLoading()),
  );
  columns[2].push(
    renderFullUninstall(
      isAnyActionLoading() || isServiceRuntimeActionLoading(),
    ),
  );

  return preserveScrollForPage(() => {
    container.replaceChildren(
      E('div', { class: 'fkp_updates-page__components-column' }, columns[0]),
      E('div', { class: 'fkp_updates-page__components-column' }, columns[1]),
      E('div', { class: 'fkp_updates-page__components-column' }, columns[2]),
    );
  });
}

function onStoreUpdate(
  _next: StoreType,
  _prev: StoreType,
  diff: Partial<StoreType>,
) {
  if (
    diff.diagnosticsSystemInfo ||
    diff.updatesActions ||
    diff.updatesChecks ||
    diff.diagnosticsActions ||
    diff.servicesInfoWidget
  ) {
    renderUpdatesComponents();
  }
}

function applyComponentUpdateCheckCache(
  componentUpdateCheckCache: Forkop.ComponentUpdateCheckCache,
) {
  componentUpdateCheckCacheResolved = true;

  if (componentUpdateCheckCache.enabled) {
    store.reset(['updatesChecks']);
    applyCachedCheckResults(componentUpdateCheckCache.results);
  }

  if (
    shouldResetCheckResultsOnMount({
      anyActionLoading: isAnyActionLoading(),
      preserveCheckResultsOnNextMount,
      persistentCacheEnabled: componentUpdateCheckCache.enabled,
    })
  ) {
    store.reset(['updatesChecks']);
  }
}

async function onPageMount() {
  onPageUnmount();

  updatesMounted = true;
  updatesMountId += 1;
  const mountId = updatesMountId;
  const cachedRuntimeState = getCachedRuntimeUiState();
  const hasRuntimeSnapshot = Boolean(cachedRuntimeState);
  const needsFreshStateBeforeRender =
    shouldRefreshComponentStateBeforeRender(cachedRuntimeState);
  const runtimeStateRefreshPromise =
    !hasRuntimeSnapshot || needsFreshStateBeforeRender
      ? refreshRuntimeUiState({ force: true })
      : null;
  const prefetchedComponentUpdateCheckCache = componentUpdateCheckCacheSnapshot;

  if (prefetchedComponentUpdateCheckCache) {
    applyComponentUpdateCheckCache(prefetchedComponentUpdateCheckCache);
  }

  renderUpdatesComponents();

  const componentUpdateCheckCache = await loadComponentUpdateCheckCache({
    force: Boolean(prefetchedComponentUpdateCheckCache),
  });

  if (!updatesMounted || mountId !== updatesMountId) {
    return;
  }

  applyComponentUpdateCheckCache(componentUpdateCheckCache);
  preserveCheckResultsOnNextMount = false;
  renderUpdatesComponents();

  if (runtimeStateRefreshPromise) {
    await runtimeStateRefreshPromise;

    if (!updatesMounted || mountId !== updatesMountId) {
      return;
    }
  }

  store.subscribe(onStoreUpdate);
  startComponentActionStateWatcher();
  renderUpdatesComponents();
  void ensureSystemInfo();
  if (hasRuntimeSnapshot) {
    void refreshRuntimeUiState({ force: true });
  }
}

function onPageUnmount() {
  updatesMounted = false;
  updatesMountId += 1;
  stopComponentActionStateWatcher();
  store.unsubscribe(onStoreUpdate);
}

function registerLifecycleListeners() {
  if (updatesLifecycleRegistered) {
    return;
  }

  updatesLifecycleRegistered = true;

  store.subscribe((next, prev, diff) => {
    if (
      diff.tabService &&
      next.tabService.current !== prev.tabService.current
    ) {
      const isUpdatesVisible = next.tabService.current === 'updates';

      if (isUpdatesVisible) {
        return onPageMount();
      }

      if (updatesMounted) {
        return onPageUnmount();
      }
    }
  });
}

export async function initController(): Promise<void> {
  if (updatesControllerInitialized) {
    return;
  }

  updatesControllerInitialized = true;
  void loadComponentUpdateCheckCache();

  onMount('updates-status').then(() => {
    logger.debug('[UPDATES]', 'initController', 'onMount');
    registerLifecycleListeners();
    if (
      store.get().tabService.current === 'updates' ||
      isActiveLuciTab('updates')
    ) {
      onPageMount();
    }
  });
}
