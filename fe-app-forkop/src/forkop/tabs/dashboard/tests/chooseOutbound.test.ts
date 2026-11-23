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
import { handleChooseOutbound, initController } from '../initController';

const mocks = vi.hoisted(() => ({
  choose: vi.fn(),
  sections: vi.fn(),
  showToast: vi.fn(),
}));
vi.hoisted(() => vi.stubGlobal('__FORKOP_RUSSIAN__', '{}'));

vi.mock('../../../methods', () => ({
  CustomForkopMethods: { getDashboardSections: mocks.sections },
  ForkopShellMethods: { setClashApiGroupProxy: mocks.choose },
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
