export interface ClashConnectionMetadata {
  destinationIP?: string;
  destinationPort?: string | number;
  host?: string;
  sniffHost?: string;
  network?: string;
  processPath?: string;
  sourceIP?: string;
  sourcePort?: string | number;
  type?: string;
}

export interface ClashConnection {
  chains?: string[];
  download?: number;
  id?: string;
  metadata?: ClashConnectionMetadata;
  rule?: string;
  rulePayload?: string;
  start?: string;
  upload?: number;
}

export interface ClashConnectionsPayload {
  connections?: ClashConnection[];
}

export interface MonitoredConnection extends ClashConnection {
  id: string;
  closedAt?: number;
  lastSeenAt: number;
}

export const activeConnections = new Map<string, MonitoredConnection>();
export const closedConnections = new Map<string, MonitoredConnection>();
export function moveConnectionToClosed(
  connection: MonitoredConnection,
  now: number,
) {
  closedConnections.set(connection.id, {
    ...connection,
    closedAt: now,
    lastSeenAt: now,
  });
}
export function trimClosedConnections() {
  const sorted = [...closedConnections.values()].sort(
    (a, b) => (b.closedAt || 0) - (a.closedAt || 0),
  );
  for (const connection of sorted.slice(300))
    closedConnections.delete(connection.id);
}
export function observeConnections(connections: unknown) {
  if (!Array.isArray(connections)) return;
  const now = Date.now();
  const incoming = new Set<string>();
  for (const raw of connections) {
    if (
      !raw ||
      typeof raw !== 'object' ||
      typeof raw.id !== 'string' ||
      !raw.id.trim()
    )
      continue;
    const id = raw.id.trim();
    incoming.add(id);
    closedConnections.delete(id);
    activeConnections.set(id, { ...raw, id, lastSeenAt: now });
  }
  for (const [id, connection] of activeConnections) {
    if (!incoming.has(id)) {
      activeConnections.delete(id);
      moveConnectionToClosed(connection, now);
    }
  }
  trimClosedConnections();
}
