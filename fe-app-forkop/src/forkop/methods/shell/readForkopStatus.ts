import type { Forkop } from '../../types';

export function isReadOnlyForkopView() {
  return (
    typeof L !== 'undefined' &&
    typeof L.hasViewPermission === 'function' &&
    L.hasViewPermission() === false
  );
}

export async function readForkopStatus(
  operation: string,
  subject?: string,
  timeout = 15000,
) {
  const fields: Record<string, string> = { operation };
  if (subject !== undefined) fields.subject = subject;
  return callForkopUi('ui-read', fields, timeout);
}

export function writeForkopUi(
  operation: 'validate_regex' | 'tailscale_connect',
  value: string,
  timeout = 15000,
) {
  return callForkopUi('ui-write', { operation, value }, timeout);
}

async function callForkopUi(
  route: 'ui-read' | 'ui-write',
  fields: Record<string, string>,
  timeout: number,
) {
  const result = await fetchForkopUi(route, fields, timeout);
  if (
    typeof result?.stdout !== 'string' ||
    typeof result?.stderr !== 'string' ||
    !Number.isInteger(result?.code)
  )
    throw new Error(_('Unknown error'));

  return result as { code: number; stdout: string; stderr: string };
}

async function fetchForkopUi(
  route: 'ui-read' | 'ui-write' | 'ui-clash',
  fields: Record<string, string>,
  timeout: number,
) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const body = new URLSearchParams({ ...fields, token: L.env.token });

    const response = await fetch(L.url('admin', 'services', 'forkop', route), {
      method: 'POST',
      credentials: 'same-origin',
      cache: 'no-store',
      signal: controller.signal,
      body,
    });
    if (!response.ok) throw new Error(`${_('HTTP error')} ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

export async function readForkopClashData<T>(
  operation: 'connections' | 'proxies',
): Promise<Forkop.MethodResponse<T>> {
  try {
    const data: T = await fetchForkopUi('ui-clash', { operation }, 25000);
    return { success: true, data };
  } catch (error) {
    return {
      success: false,
      error: error instanceof Error ? error.message : _('Unknown error'),
    };
  }
}

export async function readForkopRuntimeConfig(_path: string, revision: string) {
  const result = await readForkopStatus('runtime_config', revision);
  if (result.code !== 0) throw new Error(result.stderr);
  return result.stdout;
}
