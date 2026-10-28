import { ForkopShellMethods } from '../methods';
import { normalizeSingBoxVariantFields } from '../helpers/singBoxVariant';
import { logger } from './logger.service';
import { store, StoreType } from './store.service';

const UNKNOWN_SYSTEM_INFO: StoreType['diagnosticsSystemInfo'] = {
  loading: false,
  loaded: false,
  providerInfoLoaded: false,
  forkop_version: _('unknown'),
  forkop_latest_version: _('unknown'),
  luci_app_version: _('unknown'),
  sing_box_version: _('unknown'),
  sing_box_extended: 0,
  sing_box_tiny: 0,
  sing_box_compressed: 0,
  sing_box_tailscale: 1,
  zapret_manager_installed: 0,
  packet_steering_mode: '',
  direct_proxy_enabled: 0,
  direct_proxy_address: '',
  direct_proxy_port: '2080',
  torrserver_running: 0,
  torrserver_direct_available: 0,
  torrserver_direct_enabled: 0,
  torrserver_direct_active: 0,
  openwrt_version: _('unknown'),
  device_model: _('unknown'),
};

let systemInfoPromise: Promise<StoreType['diagnosticsSystemInfo']> | null =
  null;
let latestSystemInfoRequestId = 0;

function hasLoadedSystemInfo() {
  const systemInfo = store.get().diagnosticsSystemInfo;

  return Boolean(systemInfo.loaded) && !systemInfo.loading;
}

export async function ensureSystemInfo({
  force = false,
  silent = false,
}: {
  force?: boolean;
  silent?: boolean;
} = {}) {
  if (!force && hasLoadedSystemInfo()) {
    return store.get().diagnosticsSystemInfo;
  }

  if (systemInfoPromise && !force) {
    return systemInfoPromise;
  }

  const requestId = ++latestSystemInfoRequestId;
  const currentSystemInfo = store.get().diagnosticsSystemInfo;

  if (!silent) {
    store.set({
      diagnosticsSystemInfo: {
        ...currentSystemInfo,
        loading: true,
      },
    });
  }

  const promise = (async () => {
    try {
      const systemInfo = await ForkopShellMethods.getSystemInfo();

      if (requestId !== latestSystemInfoRequestId) {
        return store.get().diagnosticsSystemInfo;
      }

      if (systemInfo.success) {
        const nextSystemInfo: StoreType['diagnosticsSystemInfo'] =
          normalizeSingBoxVariantFields({
            ...UNKNOWN_SYSTEM_INFO,
            loading: false,
            loaded: true,
            providerInfoLoaded: true,
            ...systemInfo.data,
          });

        store.set({
          diagnosticsSystemInfo: nextSystemInfo,
        });

        return nextSystemInfo;
      }
    } catch (error) {
      logger.error('[SYSTEM_INFO]', 'ensureSystemInfo failed', error);
    }

    if (requestId === latestSystemInfoRequestId && !silent) {
      const latestSystemInfo = store.get().diagnosticsSystemInfo;
      const nextSystemInfo = {
        ...UNKNOWN_SYSTEM_INFO,
        loading: false,
        loaded: false,
        providerInfoLoaded: latestSystemInfo.providerInfoLoaded,
      };

      store.set({
        diagnosticsSystemInfo: nextSystemInfo,
      });

      return nextSystemInfo;
    }

    return store.get().diagnosticsSystemInfo;
  })();

  systemInfoPromise = promise;

  try {
    return await promise;
  } finally {
    if (systemInfoPromise === promise) {
      systemInfoPromise = null;
    }
  }
}
