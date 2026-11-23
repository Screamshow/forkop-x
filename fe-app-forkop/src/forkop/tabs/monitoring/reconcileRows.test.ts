import { expect, it, vi } from 'vitest';
import { getConnectionPage, reconcileRows } from './reconcileRows';

it('keeps a stable 100-row window for thousands of ordered connections', () => {
  const connections = Array.from({ length: 4205 }, (_, index) => index);
  expect(getConnectionPage(connections, 20)).toMatchObject({
    page: 20,
    pages: 43,
  });
  expect(getConnectionPage(connections, 20).visible).toEqual(
    connections.slice(2000, 2100),
  );
  expect(getConnectionPage(connections, 500).visible).toEqual(
    connections.slice(4200),
  );
});

it('preserves unchanged rows and performs no repeated DOM operations', () => {
  const children: HTMLElement[] = [];
  const container = {
    ownerDocument: { activeElement: null },
    get firstElementChild() {
      return children[0] || null;
    },
    insertBefore: vi.fn((row: HTMLElement, next: HTMLElement | null) => {
      row.remove();
      children.splice(next ? children.indexOf(next) : children.length, 0, row);
    }),
  };
  const create = vi.fn((id: string) => {
    const node = {
      get nextElementSibling() {
        return children[children.indexOf(node) + 1] || null;
      },
      remove() {
        const i = children.indexOf(node);
        if (i >= 0) children.splice(i, 1);
      },
    } as unknown as HTMLElement;
    return { node, id };
  });
  const items = Array.from({ length: 100 }, (_, index) => String(index));
  const update = (id: string, old?: ReturnType<typeof create>) =>
    old || create(id);
  const getKey = (id: string) => id;
  const parent = container as unknown as HTMLElement;
  const first = reconcileRows(parent, new Map(), items, getKey, update);
  expect(create).toHaveBeenCalledTimes(100);
  expect(container.insertBefore).toHaveBeenCalledTimes(100);
  container.insertBefore.mockClear();
  const second = reconcileRows(parent, first, items, getKey, update);
  expect(create).toHaveBeenCalledTimes(100);
  expect(container.insertBefore).not.toHaveBeenCalled();
  expect(second.get('50')).toBe(first.get('50'));

  const next = [items[1], items[0], ...items.slice(2, -1), 'new'];
  const third = reconcileRows(parent, second, next, getKey, update);
  expect(container.insertBefore).toHaveBeenCalledTimes(2);
  expect(children).toEqual([...third.values()].map((row) => row.node));
});
