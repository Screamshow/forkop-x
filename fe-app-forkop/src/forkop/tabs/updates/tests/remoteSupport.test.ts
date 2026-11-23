import { afterEach, beforeEach, expect, it, vi } from 'vitest';

vi.mock('../../../../partials', () => ({
  renderButton: (props: {
    text: string;
    disabled?: boolean;
    onClick: () => void;
  }) =>
    E('button', { disabled: props.disabled, click: props.onClick }, props.text),
}));
vi.mock('../../../../helpers/copyToClipboard', () => ({
  copyToClipboard: vi.fn(),
}));

class Element {
  parent: Element | null = null;
  attached = false;
  children: Element[] = [];
  textContent = '';
  value = '';
  checked = false;
  disabled = false;
  hidden = false;
  click?: () => void;
  constructor(
    public tag: string,
    attributes: Record<string, unknown> = {},
    children: unknown = [],
  ) {
    Object.assign(this, attributes);
    this.replaceChildren(...(Array.isArray(children) ? children : [children]));
  }
  get isConnected(): boolean {
    return this.attached || !!this.parent?.isConnected;
  }
  replaceChildren(...children: unknown[]) {
    this.children.forEach((child) => {
      child.parent = null;
    });
    this.children = children.filter(
      (child) => child instanceof Element,
    ) as Element[];
    this.children.forEach((child) => {
      child.parent = this;
    });
    this.textContent = children
      .filter((child) => typeof child === 'string')
      .join('');
  }
  addEventListener() {}
}
function button(root: Element, text: string): Element {
  if (root.tag === 'button' && root.textContent === text) return root;
  for (const child of root.children) {
    try {
      return button(child, text);
    } catch {
      /* Keep searching. */
    }
  }
  throw Error(`Missing button: ${text}`);
}
let response: Record<string, unknown>;
let dialog: Element;
let show: ReturnType<typeof vi.fn>;
let operations: string[];
const storage = new Map<string, string>();
const acknowledged = new Set<string>();
beforeEach(() => {
  vi.resetModules();
  vi.useFakeTimers();
  storage.clear();
  acknowledged.clear();
  operations = [];
  response = {
    installed: true,
    active: true,
    phase: 'connected',
    address: '100.1.2.3',
    session_id: 'first',
    remaining_seconds: 1700,
  };
  vi.stubGlobal(
    'E',
    (tag: string, attributes: Record<string, unknown>, children: unknown) =>
      new Element(tag, attributes, children),
  );
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => storage.get(key) || null,
    setItem: (key: string, value: string) => storage.set(key, value),
  });
  vi.stubGlobal('window', { addEventListener: vi.fn() });
  vi.stubGlobal('document', { hidden: false, addEventListener: vi.fn() });
  vi.stubGlobal('L', { env: { token: 'fixture' }, url: () => '/fixture' });
  show = vi.fn((_title: string, node: Element) => {
    dialog = node;
    dialog.attached = true;
  });
  vi.stubGlobal('ui', {
    showModal: show,
    hideModal: () => {
      dialog.attached = false;
    },
  });
  vi.stubGlobal(
    'fetch',
    vi.fn(async (_url: string, options: { body: URLSearchParams }) => {
      const operation = options.body.get('operation') || '';
      operations.push(operation);
      let announcement_granted = false;
      if (operation === 'announce') {
        const id = options.body.get('session_id') || '';
        announcement_granted = !acknowledged.has(id);
        acknowledged.add(id);
      }
      if (operation === 'stop')
        response = {
          ...response,
          active: false,
          phase: 'stopped',
          address: '',
        };
      return {
        ok: true,
        json: async () => ({
          success: true,
          data: { ...response, announcement_granted },
        }),
      };
    }),
  );
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

function texts(root: Element): string[] {
  return [root.textContent, ...root.children.flatMap(texts)];
}

it.each([
  [true, false, '1.82.5', '', 'Tailscale 1.82.5'],
  [false, true, '', '1.98.3', 'Tailscale Lite 1.98.3'],
  [true, true, '1.82.5', '1.98.3', 'Tailscale 1.82.5; Tailscale Lite 1.98.3'],
])(
  'shows independent system/Lite versions (%s, %s)',
  async (system, lite, systemVersion, liteVersion, expected) => {
    response = {
      ...response,
      active: false,
      phase: 'stopped',
      system_installed: system,
      package_installed: system,
      lite_installed: lite,
      removable: true,
      system_version: systemVersion,
      lite_version: liteVersion,
      version: lite ? liteVersion : systemVersion,
    };
    const module = await import('../remoteSupport');
    const card = module.renderRemoteSupport() as unknown as Element;
    card.attached = true;
    await vi.advanceTimersByTimeAsync(1000);
    expect(texts(card)).toContain(expected);
    expect(texts(card).includes('Used for support: Tailscale Lite')).toBe(
      system && lite,
    );
    expect(texts(card)).not.toContain('Tailscale is not installed');
    expect(
      button(card, lite ? 'Remove Tailscale Lite' : 'Remove Tailscale')
        .disabled,
    ).toBe(false);
    expect(texts(card)).not.toContain(
      lite ? 'Remove Tailscale' : 'Remove Tailscale Lite',
    );
  },
);

it('blocks removal of a running primary Tailscale service', async () => {
  response = {
    ...response,
    active: false,
    phase: 'stopped',
    package_installed: true,
    system_installed: true,
    system_version: '1.98.3',
    lite_installed: false,
    removable: false,
    primary_running: true,
  };
  const module = await import('../remoteSupport');
  const card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(button(card, 'Remove Tailscale').disabled).toBe(true);
});

it('auto opens once; Close, polling, tab renders and reload preserve the session; manual open and new session work', async () => {
  let module = await import('../remoteSupport');
  let card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(show).toHaveBeenCalledTimes(1);
  button(dialog, 'Close').click?.();
  expect(operations).not.toContain('stop');
  await vi.advanceTimersByTimeAsync(6000);
  expect(show).toHaveBeenCalledTimes(1);
  card.attached = false;
  card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(show).toHaveBeenCalledTimes(1);
  card.attached = false;
  vi.resetModules();
  module = await import('../remoteSupport');
  card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(show).toHaveBeenCalledTimes(1);
  button(card, 'Connection details').click?.();
  expect(show).toHaveBeenCalledTimes(2);
  button(dialog, 'Close').click?.();
  response = { ...response, phase: 'recovering', address: '' };
  await vi.advanceTimersByTimeAsync(3000);
  button(card, 'Connection details').click?.();
  expect(dialog.children[0].textContent).toBe('Restoring control connection');
  expect(button(dialog, 'Disconnect now').disabled).toBe(false);
  button(dialog, 'Close').click?.();
  response = {
    ...response,
    phase: 'connected',
    address: '100.1.2.3',
    session_id: 'second',
  };
  await vi.advanceTimersByTimeAsync(3000);
  expect(show).toHaveBeenCalledTimes(4);
  button(dialog, 'Disconnect now').click?.();
  await vi.advanceTimersByTimeAsync(0);
  expect(operations.filter((op) => op === 'stop')).toHaveLength(1);
  await vi.advanceTimersByTimeAsync(3000);
  expect(show).toHaveBeenCalledTimes(4);
});

it('keeps announcement consumed across reload when browser storage is unavailable', async () => {
  vi.stubGlobal('localStorage', {
    getItem: () => {
      throw Error('disabled');
    },
    setItem: () => {
      throw Error('disabled');
    },
  });
  let module = await import('../remoteSupport');
  let card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(show).toHaveBeenCalledTimes(1);
  button(dialog, 'Close').click?.();
  card.attached = false;
  vi.resetModules();
  module = await import('../remoteSupport');
  card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(show).toHaveBeenCalledTimes(1);
});

it('retries an acknowledgement after a transient request error', async () => {
  const original = globalThis.fetch;
  let failed = false;
  vi.stubGlobal(
    'fetch',
    vi.fn(async (url: string, options: { body: URLSearchParams }) => {
      if (options.body.get('operation') === 'announce' && !failed) {
        failed = true;
        throw Error('temporary network error');
      }
      return original(url, options as unknown as RequestInit);
    }),
  );
  const module = await import('../remoteSupport');
  const card = module.renderRemoteSupport() as unknown as Element;
  card.attached = true;
  await vi.advanceTimersByTimeAsync(1000);
  expect(show).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(3000);
  expect(show).toHaveBeenCalledTimes(1);
  await vi.advanceTimersByTimeAsync(3000);
  expect(show).toHaveBeenCalledTimes(1);
});
