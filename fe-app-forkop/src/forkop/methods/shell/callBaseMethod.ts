import { executeShellCommand } from '../../../helpers';
import { Forkop } from '../../types';
import { isReadOnlyForkopView, readForkopStatus } from './readForkopStatus';

interface CallBaseMethodOptions {
  allowNonZeroWithStdout?: boolean;
  timeout?: number;
}

const readOnlyMethods = new Set([
  Forkop.AvailableMethods.CHECK_DNS_AVAILABLE,
  Forkop.AvailableMethods.CHECK_FAKEIP,
  Forkop.AvailableMethods.CHECK_NFT_RULES,
  Forkop.AvailableMethods.CHECK_XRUST,
  Forkop.AvailableMethods.COMPONENT_UPDATE_CHECK_CACHE,
  Forkop.AvailableMethods.GET_STATUS,
  Forkop.AvailableMethods.GET_SYSTEM_INFO,
  Forkop.AvailableMethods.GET_UI_CAPABILITIES,
  Forkop.AvailableMethods.GET_UI_STATE,
  Forkop.AvailableMethods.GET_XRUST_STATUS,
]);

export async function callBaseMethod<T>(
  method: Forkop.AvailableMethods,
  args: string[] = [],
  command: string = '/usr/bin/forkop',
  options: CallBaseMethodOptions = {},
): Promise<Forkop.MethodResponse<T>> {
  try {
    const timeout = options.timeout ?? 15000;
    const readonly = isReadOnlyForkopView();
    const operation =
      readonly &&
      command === '/usr/bin/forkop' &&
      args.length === 0 &&
      readOnlyMethods.has(method)
        ? method
        : null;
    if (readonly && !operation)
      return { success: false, error: _('Write permission is required') };
    const response = operation
      ? await readForkopStatus(operation, undefined, timeout)
      : await executeShellCommand({
          command,
          args: [method, ...args],
          timeout,
        });
    const exitCode = response.code ?? 0;

    if (
      exitCode !== 0 &&
      !(options.allowNonZeroWithStdout && response.stdout)
    ) {
      return {
        success: false,
        error: response.stderr || response.stdout || '',
      };
    }

    if (response.stdout) {
      try {
        return {
          success: true,
          data: JSON.parse(response.stdout) as T,
        };
      } catch (_e) {
        return {
          success: true,
          data: response.stdout as T,
        };
      }
    }

    return {
      success: false,
      error: response.stderr || '',
    };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : '',
    };
  }
}
