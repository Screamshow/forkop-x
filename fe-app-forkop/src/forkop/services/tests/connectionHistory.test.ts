import { beforeEach, expect, it } from 'vitest';
import {
  activeConnections,
  closedConnections,
  observeConnections,
} from '../connectionHistory';
beforeEach(() => {
  activeConnections.clear();
  closedConnections.clear();
});
it('shares closed history across snapshots and removes returning active IDs', () => {
  observeConnections([{ id: 'a' }, { id: 'b' }]);
  observeConnections([{ id: 'b' }, { id: 'c' }]);
  expect([...closedConnections.keys()]).toEqual(['a']);
  expect(activeConnections.size).toBe(2);
  observeConnections(undefined);
  expect(activeConnections.size).toBe(2);
  observeConnections([{ id: 'a' }]);
  expect([...closedConnections.keys()]).toEqual(['b', 'c']);
});
it('retains at most the same 300 closed records as monitoring', () => {
  observeConnections(
    Array.from({ length: 350 }, (_, id) => ({ id: String(id) })),
  );
  observeConnections([]);
  expect(closedConnections.size).toBe(300);
  expect(activeConnections.size).toBe(0);
});
