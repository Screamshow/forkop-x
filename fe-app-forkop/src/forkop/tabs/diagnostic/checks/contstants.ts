import { getCheckTitle } from '../helpers/getCheckTitle';

export enum DIAGNOSTICS_CHECKS {
  DNS = 'DNS',
  XRUST = 'XRUST',
  NFT = 'NFT',
  FAKEIP = 'FAKEIP',
  OUTBOUNDS = 'OUTBOUNDS',
}

export const DIAGNOSTICS_CHECKS_MAP: Record<
  DIAGNOSTICS_CHECKS,
  { order: number; title: string; code: DIAGNOSTICS_CHECKS }
> = {
  [DIAGNOSTICS_CHECKS.DNS]: {
    order: 1,
    title: getCheckTitle('DNS'),
    code: DIAGNOSTICS_CHECKS.DNS,
  },
  [DIAGNOSTICS_CHECKS.XRUST]: {
    order: 2,
    title: getCheckTitle('Xrust'),
    code: DIAGNOSTICS_CHECKS.XRUST,
  },
  [DIAGNOSTICS_CHECKS.NFT]: {
    order: 4,
    title: getCheckTitle('Nftables'),
    code: DIAGNOSTICS_CHECKS.NFT,
  },
  [DIAGNOSTICS_CHECKS.OUTBOUNDS]: {
    order: 8,
    title: getCheckTitle('Outbounds'),
    code: DIAGNOSTICS_CHECKS.OUTBOUNDS,
  },
  [DIAGNOSTICS_CHECKS.FAKEIP]: {
    order: 9,
    title: getCheckTitle('FakeIP'),
    code: DIAGNOSTICS_CHECKS.FAKEIP,
  },
};
