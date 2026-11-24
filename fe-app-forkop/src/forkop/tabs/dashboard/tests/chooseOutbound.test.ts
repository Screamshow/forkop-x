import {
  afterAll,
  afterEach,
  beforeAll,
  beforeEach,
  expect,
  it,
  vi,
} from 'vitest';
import type { Forkop } from '../../../types';
import { store } from '../../../services/store.service';
import {
  handleChooseOutbound,
  initController,
  followSubscriptionUpdateState,
  followLatencyTestState,
  renderUrlTestEditorModal,
} from '../initController';
import { markUiActionOwned } from '../../../services/uiActionNotification.service';
import {
  setLocalSubscriptionAction,
  getLocalActionOverlay,
} from '../../../services/localActionOverlay.service';

const mocks = vi.hoisted(() => ({
  choose: vi.fn(),
  sections: vi.fn(),
  showToast: vi.fn(),
  waitJob: vi.fn(),
  ack: vi.fn(),
  serviceStart: vi.fn(),
  save: vi.fn(),
}));
vi.hoisted(() => vi.stubGlobal('__FORKOP_RUSSIAN__', '{}'));

vi.mock('../../../methods', () => ({
  CustomForkopMethods: { getDashboardSections: mocks.sections },
  ForkopShellMethods: {
    setClashApiGroupProxy: mocks.choose,
    waitSubscriptionUpdateJob: mocks.waitJob,
    waitLatencyTestJob: mocks.waitJob,
    uiActionAck: mocks.ack,
    serviceActionStart: mocks.serviceStart,
    waitServiceActionJob: mocks.waitJob,
    saveUrlTestOverride: mocks.save,
    resetUrlTestOverride: mocks.save,
  },
}));
vi.mock('../../../../helpers/onMount', () => ({
  onMount: async () => {},
}));
vi.mock('../../../../helpers/showToast', () => ({
  showToast: mocks.showToast,
}));
vi.mock('../../../services/systemInfo.service', () => ({
  ensureSystemInfo: vi.fn(),
}));
vi.mock('../../../services/tab.service', () => ({ TabServiceInstance: {} }));
vi.mock('../../../services/runtimeUiState.service', () => ({
  getCachedRuntimeUiState: () => ({}),
  refreshRuntimeUiState: vi.fn(),
  subscribeRuntimeUiState: () => () => {},
}));

function group(selected: string): Forkop.OutboundGroup {
  return {
    code: 'proxy-group',
    sectionName: 'proxy-section',
    displayName: 'Proxy',
    withTagSelect: true,
    outbounds: ['first', 'second', 'third'].map((code) => ({
      code,
      displayName: code,
      latency: 0,
      type: 'proxy',
      selected: code === selected,
    })),
  };
}

beforeAll(async () => {
  vi.stubGlobal('document', {
    getElementById: () => null,
    querySelector: () => true,
  });
  await initController();
});

beforeEach(() => {
  vi.resetAllMocks();
  store.set({
    sectionsWidget: { ...store.get().sectionsWidget, data: [group('first')] },
  });
});

afterEach(() => {
  expect(store.get().sectionsWidget.selectorSwitchingSections).toEqual({});
});
afterAll(() => vi.unstubAllGlobals());

it('releases the local subscription action after a lost RPC and notifies on the terminal snapshot', async () => {
  const job_id = 'subscription-disconnect';
  setLocalSubscriptionAction('*', true);
  markUiActionOwned('subscription', job_id);
  mocks.waitJob.mockResolvedValue({
    success: false,
    error: 'No related RPC reply',
  });
  await followSubscriptionUpdateState({ job_id, success: true, running: true });
  expect(getLocalActionOverlay().subscriptionSections.size).toBe(0);
  expect(mocks.ack).not.toHaveBeenCalled();
  await followSubscriptionUpdateState({
    job_id,
    success: false,
    running: false,
    message: 'provider failed',
  });
  expect(mocks.ack).toHaveBeenCalledWith('subscription', job_id);
  expect(mocks.showToast).toHaveBeenCalledWith(
    'Failed to update subscriptions: provider failed',
    'error',
  );
});

it('preserves a latency job after polling fails and handles its terminal error once', async () => {
  const state: Forkop.LatencyActionState = {
    kind: 'latency',
    job_id: 'latency-disconnect',
    latency_type: 'proxy',
    tag: 'proxy',
    section: 'main',
    running: true,
    success: true,
  };
  markUiActionOwned('latency', state.job_id!);
  mocks.waitJob.mockResolvedValue({
    success: false,
    error: 'No related RPC reply',
  });
  await followLatencyTestState(state);
  expect(mocks.ack).not.toHaveBeenCalled();
  await followLatencyTestState({
    ...state,
    running: false,
    success: false,
    message: 'probe failed',
  });
  await followLatencyTestState({
    ...state,
    running: false,
    success: false,
    message: 'probe failed',
  });
  expect(mocks.ack).toHaveBeenCalledOnce();
  expect(mocks.showToast).toHaveBeenCalledExactlyOnceWith(
    'probe failed',
    'error',
  );
});

it.each(['Save', 'Use source values'])(
  'keeps the URLTest editor open when %s fails to reload',
  async (label) => {
    const buttons = new Map<string, (event: unknown) => Promise<void>>();
    vi.stubGlobal(
      'E',
      (tag: string, attrs: Record<string, unknown>, text: string) => {
        if (tag === 'button')
          buttons.set(text, attrs.click as (event: unknown) => Promise<void>);
        return { value: attrs.value || '', style: {} };
      },
    );
    const hideModal = vi.fn();
    vi.stubGlobal('ui', { showModal: vi.fn(), hideModal });
    mocks.save.mockResolvedValue({ code: 0 });
    mocks.serviceStart.mockResolvedValue({
      success: true,
      data: { job_id: 'reload' },
    });
    mocks.waitJob.mockResolvedValue({
      success: true,
      data: { success: false, message: 'Failed to apply configuration' },
    });
    renderUrlTestEditorModal({
      urlTestInfo: { code: 'group', sectionName: 'main' },
    } as Forkop.Outbound);
    await buttons.get(label)!({ currentTarget: { textContent: label } });
    expect(hideModal).not.toHaveBeenCalled();
    expect(mocks.showToast).toHaveBeenCalledExactlyOnceWith(
      'Failed to apply configuration',
      'error',
    );
  },
);

it.each([
  { success: false, error: 'router offline' },
  {
    success: true,
    data: { success: false, message: 'core refused selection' },
  },
])('shows a refusal and refreshes the actual selection', async (response) => {
  mocks.choose.mockResolvedValue(response);
  mocks.sections.mockResolvedValue({ success: true, data: [group('first')] });
  await handleChooseOutbound('proxy-section', 'proxy-group', 'second');
  expect(mocks.choose).toHaveBeenCalledWith('proxy-group', 'second');
  expect(mocks.showToast).toHaveBeenCalledWith(
    'Failed to select server',
    'error',
  );
  expect(mocks.sections).toHaveBeenCalledOnce();
  expect(
    store.get().sectionsWidget.data[0].outbounds.find((o) => o.selected)?.code,
  ).toBe('first');
});

it('uses the core snapshot as selection after a successful change', async () => {
  mocks.choose.mockResolvedValue({ success: true, data: { success: true } });
  mocks.sections.mockResolvedValue({ success: true, data: [group('third')] });
  await handleChooseOutbound('proxy-section', 'proxy-group', 'second');
  expect(mocks.showToast).not.toHaveBeenCalled();
  expect(
    store.get().sectionsWidget.data[0].outbounds.find((o) => o.selected)?.code,
  ).toBe('third');
});
