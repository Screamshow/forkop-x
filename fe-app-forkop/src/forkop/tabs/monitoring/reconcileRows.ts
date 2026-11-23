const PAGE_SIZE = 100;

export function getConnectionPage<T>(
  connections: readonly T[],
  requested: number,
) {
  const pages = Math.ceil(connections.length / PAGE_SIZE);
  const page = Math.max(0, Math.min(requested, pages - 1));
  const start = page * PAGE_SIZE;
  return { page, pages, visible: connections.slice(start, start + PAGE_SIZE) };
}

export function reconcileRows<Row extends { node: HTMLElement }, Item>(
  container: HTMLElement,
  previous: Map<string, Row>,
  items: readonly Item[],
  getKey: (item: Item) => string,
  update: (item: Item, previous?: Row) => Row,
): Map<string, Row> {
  const rows = new Map(
    items.map((item) => {
      const key = getKey(item);
      return [key, update(item, previous.get(key))];
    }),
  );
  for (const [key, old] of previous) {
    if (rows.get(key) !== old) old.node.remove();
  }

  const focused = container.ownerDocument.activeElement as HTMLElement | null;
  let next = container.firstElementChild;
  for (const { node } of rows.values()) {
    if (node === next) next = node.nextElementSibling;
    else container.insertBefore(node, next);
  }
  if (
    focused &&
    focused !== container.ownerDocument.activeElement &&
    container.contains(focused)
  ) {
    focused.focus({ preventScroll: true });
  }
  return rows;
}
