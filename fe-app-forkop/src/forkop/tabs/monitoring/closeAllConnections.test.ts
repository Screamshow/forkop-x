import { afterEach, expect, it, vi } from 'vitest';
import {
  activeConnections,
  closedConnections,
  observeConnections,
} from '../../services/connectionHistory';
import { closeAllConnections } from './initController';

const closeAll = vi.hoisted(() => {
  vi.stubGlobal('__FORKOP_RUSSIAN__', '{}');
  return vi.fn();
});
vi.mock('../../methods', () => ({
  CustomForkopMethods: {},
  ForkopShellMethods: { closeAllClashApiConnections: closeAll },
}));
vi.mock('../../services/tab.service', () => ({ TabServiceInstance: {} }));

afterEach(() => {
  activeConnections.clear();
  closedConnections.clear();
  vi.unstubAllGlobals();
});

it('preserves connections opened while close-all was in flight', async () => {
  vi.stubGlobal('document', {
    getElementById: () => null,
    querySelector: () => null,
  });
  let confirmClose!: () => void;
  closeAll.mockImplementation(
    () =>
      new Promise((resolve) => {
        confirmClose = () => resolve({ success: true });
      }),
  );

  observeConnections([{ id: 'closed-by-core' }]);
  const closing = closeAllConnections();
  observeConnections([{ id: 'closed-by-core' }, { id: 'new-connection' }]);
  confirmClose();
  await closing;
  expect([...closedConnections.keys()]).toEqual([]);
  expect([...activeConnections.keys()]).toContain('new-connection');

  observeConnections([{ id: 'new-connection' }]);
  expect([...closedConnections.keys()]).toEqual(['closed-by-core']);
  expect([...activeConnections.keys()]).toEqual(['new-connection']);
});
