import type { StoreType } from '../services/store.service';
import type { Forkop } from '../types';

export type UpdatesActionKey = keyof StoreType['updatesActions'];

const componentActionKeyMap: Record<string, UpdatesActionKey> = {
  'forkop:check_update': 'forkopCheck',
  'forkop:install': 'forkopInstall',
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
