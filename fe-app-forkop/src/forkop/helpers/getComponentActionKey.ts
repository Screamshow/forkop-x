import type { StoreType } from '../services/store.service';
import type { Forkop } from '../types';

export type UpdatesActionKey = keyof StoreType['updatesActions'];

const componentActionKeyMap: Record<string, UpdatesActionKey> = {
  'forkop:check_update': 'forkopCheck',
  'forkop:install': 'forkopInstall',
  'sing_box:check_update': 'singBoxCheck',
  'sing_box:install': 'singBoxInstall',
  'sing_box:install_tiny': 'singBoxInstallTiny',
  'sing_box:install_x': 'singBoxInstallX',
  'sing_box:install_rust_x': 'singBoxInstallRustX',
  'sing_box:install_stable': 'singBoxInstallStable',
  'zapret_manager:install': 'zapretManagerInstall',
  'zapret_manager:remove': 'zapretManagerRemove',
  'packet_steering:enable': 'packetSteeringEnable',
  'packet_steering:restore': 'packetSteeringRestore',
  'direct_proxy:enable': 'directProxyEnable',
  'direct_proxy:disable': 'directProxyDisable',
  'torrserver_direct:enable': 'torrserverDirectEnable',
  'torrserver_direct:disable': 'torrserverDirectDisable',
};

export function getComponentActionKey(
  component: Forkop.ComponentName,
  action: Forkop.ComponentAction,
): UpdatesActionKey | undefined {
  return componentActionKeyMap[`${component}:${action}`];
}
