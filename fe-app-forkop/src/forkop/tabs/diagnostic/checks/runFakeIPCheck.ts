import { insertIf } from '../../../../helpers';
import { DIAGNOSTICS_CHECKS_MAP } from './contstants';
import { ForkopShellMethods, RemoteFakeIPMethods } from '../../../methods';
import type { IDiagnosticsChecksItem } from '../../../services';
import { updateCheckStore } from './updateCheckStore';
import { getMeta } from '../helpers/getMeta';

export async function runFakeIPCheck() {
  const { order, title, code } = DIAGNOSTICS_CHECKS_MAP.FAKEIP;

  updateCheckStore({
    order,
    code,
    title,
    description: _('Checking, please wait'),
    state: 'loading',
    items: [],
  });

  const routerResponse = ForkopShellMethods.checkFakeIP();
  const [
    checkFakeIPResponse,
    { routerFakeIPResponse, publicIPComparisonAvailable, checkIPResponse },
  ] = await Promise.all([
    RemoteFakeIPMethods.getFakeIpCheck(),
    routerResponse.then(async (routerFakeIPResponse) => {
      const publicIPComparisonAvailable =
        !routerFakeIPResponse.success ||
        routerFakeIPResponse.data.public_ip_comparison_available !== false;
      const checkIPResponse = publicIPComparisonAvailable
        ? await RemoteFakeIPMethods.getIpCheck()
        : null;
      return {
        routerFakeIPResponse,
        publicIPComparisonAvailable,
        checkIPResponse,
      };
    }),
  ]);
  const browserFakeIPCheckUnavailable = !checkFakeIPResponse.success;
  const browserFakeIPCheckMessage = checkFakeIPResponse.success
    ? ''
    : checkFakeIPResponse.message;

  const checks = {
    xrustFakeIP:
      routerFakeIPResponse.success && routerFakeIPResponse.data.fakeip,
    browserFakeIP:
      checkFakeIPResponse.success && checkFakeIPResponse.data.fakeip,
    canComparePublicIP:
      publicIPComparisonAvailable &&
      checkFakeIPResponse.success &&
      checkIPResponse?.success === true,
    differentIP:
      publicIPComparisonAvailable &&
      checkFakeIPResponse.success &&
      checkIPResponse?.success === true &&
      checkFakeIPResponse.data.IP !== checkIPResponse.data.IP,
  };

  const fakeIPWorks = checks.xrustFakeIP && checks.browserFakeIP;
  const { state, description } = fakeIPWorks
    ? !publicIPComparisonAvailable
      ? {
          state: 'success' as const,
          description: _(
            'FakeIP works; public IP comparison was skipped because no proxy connection is configured',
          ),
        }
      : checks.differentIP
        ? { state: 'success' as const, description: _('Checks passed') }
        : {
            state: 'warning' as const,
            description: _(
              'FakeIP works; public IP comparison is inconclusive',
            ),
          }
    : browserFakeIPCheckUnavailable && checks.xrustFakeIP
      ? {
          state: 'warning' as const,
          description: _('Browser FakeIP check could not be completed'),
        }
      : getMeta({
          allGood: false,
          atLeastOneGood: checks.xrustFakeIP || checks.browserFakeIP,
        });

  updateCheckStore({
    order,
    code,
    title,
    description,
    state,
    items: [
      {
        state: checks.xrustFakeIP ? 'success' : 'error',
        key: checks.xrustFakeIP
          ? _('Xrust FakeIP DNS works')
          : _('Xrust FakeIP DNS does not work'),
        value: routerFakeIPResponse.success ? routerFakeIPResponse.data.IP : '',
      },
      {
        state: browserFakeIPCheckUnavailable
          ? 'warning'
          : checks.browserFakeIP
            ? 'success'
            : 'error',
        key: browserFakeIPCheckUnavailable
          ? _('Browser FakeIP check could not be completed')
          : checks.browserFakeIP
            ? _('Browser is using FakeIP correctly')
            : _('Browser is not using FakeIP'),
        value: browserFakeIPCheckMessage,
      },
      ...insertIf<IDiagnosticsChecksItem>(checks.browserFakeIP, [
        !publicIPComparisonAvailable
          ? {
              state: 'success',
              key: _(
                'Public IP comparison skipped because no proxy connection is configured',
              ),
              value: '',
            }
          : {
              state: checks.differentIP ? 'success' : 'warning',
              key: !checks.canComparePublicIP
                ? _('Could not compare FakeIP and control public IPs')
                : checks.differentIP
                  ? _('FakeIP and control checks use different public IPs')
                  : _('FakeIP and control checks use the same public IP'),
              value: '',
            },
      ]),
    ],
  });
}
