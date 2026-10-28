import {
  DIAGNOSTICS_CHECKS,
  DIAGNOSTICS_CHECKS_MAP,
} from './checks/contstants';
import { IDiagnosticsChecksStoreItem, StoreType } from '../../services';

function createDiagnosticCheck(
  code: DIAGNOSTICS_CHECKS,
  description: string,
): IDiagnosticsChecksStoreItem {
  const meta = DIAGNOSTICS_CHECKS_MAP[code];

  return {
    code,
    title: meta.title,
    order: meta.order,
    description,
    items: [],
    state: 'skipped',
  };
}

export function getDiagnosticsChecks(
  description: string,
): Array<IDiagnosticsChecksStoreItem> {
  const checks = [
    DIAGNOSTICS_CHECKS.DNS,
    DIAGNOSTICS_CHECKS.SINGBOX,
    DIAGNOSTICS_CHECKS.NFT,
    DIAGNOSTICS_CHECKS.OUTBOUNDS,
    DIAGNOSTICS_CHECKS.FAKEIP,
  ];

  return checks.map((code) => createDiagnosticCheck(code, description));
}

export function getLoadingDiagnosticsChecks(): Pick<
  StoreType,
  'diagnosticsChecks'
> {
  return {
    diagnosticsChecks: getDiagnosticsChecks(_('Pending')),
  };
}

export const initialDiagnosticStore: Pick<
  StoreType,
  | 'diagnosticsChecks'
  | 'diagnosticsRunAction'
  | 'diagnosticsActions'
  | 'diagnosticsSystemInfo'
  | 'updatesActions'
  | 'updatesChecks'
> = {
  diagnosticsSystemInfo: {
    loading: true,
    loaded: false,
    providerInfoLoaded: false,
    forkop_version: 'loading',
    forkop_latest_version: 'loading',
    luci_app_version: 'loading',
    sing_box_version: 'loading',
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
    openwrt_version: 'loading',
    device_model: 'loading',
  },
  diagnosticsActions: {
    restart: {
      loading: false,
    },
    start: {
      loading: false,
    },
    stop: {
      loading: false,
    },
    enable: {
      loading: false,
    },
    disable: {
      loading: false,
    },
    globalCheck: {
      loading: false,
    },
    viewLogs: {
      loading: false,
    },
    showSingBoxConfig: {
      loading: false,
    },
    supportReport: {
      loading: false,
    },
  },
  diagnosticsRunAction: { loading: false },
  diagnosticsChecks: getDiagnosticsChecks(_('Not running')),
  updatesActions: {
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
  },
  updatesChecks: {
    forkop: { status: null, latest_version: '', release_url: '' },
    sing_box: { status: null, latest_version: '', release_url: '' },
    zapret_manager: { status: null, latest_version: '', release_url: '' },
    packet_steering: { status: null, latest_version: '', release_url: '' },
    direct_proxy: { status: null, latest_version: '', release_url: '' },
    torrserver_direct: { status: null, latest_version: '', release_url: '' },
  },
};
