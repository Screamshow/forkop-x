import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { socket } from '../socket.service';

class FakeWebSocket {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  readyState = FakeWebSocket.CONNECTING;
  private listeners = new Map<string, Array<(event: Event) => void>>();

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this);
  }

  addEventListener(type: string, listener: (event: Event) => void) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  emit(type: string, data?: string) {
    const event = new Event(type);
    Object.defineProperty(event, 'data', { value: data });
    for (const listener of this.listeners.get(type) || []) {
      listener(event);
    }
  }

  close = vi.fn(() => {
    this.readyState = FakeWebSocket.CLOSED;
  });
  send = vi.fn();
}

describe('socket service', () => {
  beforeEach(() => {
    socket.resetAll();
    FakeWebSocket.instances = [];
    vi.stubGlobal('WebSocket', FakeWebSocket);
  });

  afterEach(() => {
    socket.resetAll();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('keeps socket query parameters out of logs', () => {
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});
    const error = vi.spyOn(console, 'error').mockImplementation(() => {});
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const url = 'ws://router.test/connections?token=example';
    const unsubscribe = socket.subscribe(url, vi.fn());
    const connection = FakeWebSocket.instances[0];

    expect(connection.url).toBe(url);
    connection.emit('open');
    connection.emit('error');
    connection.emit('close');
    unsubscribe();

    expect(info).toHaveBeenCalledWith(
      '[INFO] [SOCKET] Connected to ws://router.test/connections',
    );
    expect(error).toHaveBeenCalledWith(
      '[ERROR] [SOCKET] Socket error for ws://router.test/connections',
    );
    expect(warn).toHaveBeenCalledWith(
      '[WARN] [SOCKET] Disconnected: ws://router.test/connections',
    );
  });

  it('keeps the initial subscriber when the first connection fails', () => {
    const onError = vi.fn();

    socket.subscribe('ws://router.test', vi.fn(), onError);
    FakeWebSocket.instances[0].emit('error');

    expect(onError).toHaveBeenCalledOnce();
  });

  it('keeps monitoring connected when dashboard releases its own subscriptions', () => {
    const dashboard = vi.fn(),
      monitoring = vi.fn();
    const dashboardError = vi.fn(),
      monitoringError = vi.fn();
    const releaseTraffic = socket.subscribe('ws://router/traffic', vi.fn());
    const releaseDashboard = socket.subscribe(
      'ws://router/connections',
      dashboard,
      dashboardError,
    );
    const releaseMonitoring = socket.subscribe(
      'ws://router/connections',
      monitoring,
      monitoringError,
    );
    const [traffic, connections] = FakeWebSocket.instances;
    expect(FakeWebSocket.instances).toHaveLength(2);
    releaseDashboard();
    releaseTraffic();
    connections.emit('message', 'snapshot');
    connections.emit('error');
    expect(dashboard).not.toHaveBeenCalled();
    expect(dashboardError).not.toHaveBeenCalled();
    expect(monitoring).toHaveBeenCalledWith('snapshot');
    expect(monitoringError).toHaveBeenCalledOnce();
    expect(connections.close).not.toHaveBeenCalled();
    expect(traffic.close).toHaveBeenCalledOnce();
    releaseMonitoring();
    releaseMonitoring();
    expect(connections.close).toHaveBeenCalledOnce();
  });

  it('keeps dashboard subscribed when monitoring leaves and remounts', () => {
    const dashboard = vi.fn(),
      oldMonitoring = vi.fn(),
      newMonitoring = vi.fn();
    const releaseDashboard = socket.subscribe(
      'ws://router/connections',
      dashboard,
    );
    const releaseMonitoring = socket.subscribe(
      'ws://router/connections',
      oldMonitoring,
    );
    releaseMonitoring();
    socket.subscribe('ws://router/connections', newMonitoring);
    FakeWebSocket.instances[0].emit('message', 'snapshot');
    expect(FakeWebSocket.instances).toHaveLength(1);
    expect(dashboard).toHaveBeenCalledOnce();
    expect(oldMonitoring).not.toHaveBeenCalled();
    expect(newMonitoring).toHaveBeenCalledOnce();
    releaseDashboard();
    expect(FakeWebSocket.instances[0].close).not.toHaveBeenCalled();
  });

  it('ignores late events from a released socket after reconnecting the same URL', () => {
    const release = socket.subscribe('ws://router/connections', vi.fn());
    const old = FakeWebSocket.instances[0];
    release();
    const listener = vi.fn(),
      error = vi.fn();
    socket.subscribe('ws://router/connections', listener, error);
    const current = FakeWebSocket.instances[1];
    current.emit('open');
    old.emit('open');
    old.emit('message', 'old');
    old.emit('error');
    old.emit('close');
    socket.send('ws://router/connections', 'ping');
    expect(current.send).toHaveBeenCalledWith('ping');
    expect(listener).not.toHaveBeenCalled();
    expect(error).not.toHaveBeenCalled();
    current.emit('message', 'new');
    expect(listener).toHaveBeenCalledWith('new');
  });

  it('can reconnect a remotely closed URL without dropping the remaining subscribers', () => {
    const first = vi.fn(),
      error = vi.fn(),
      second = vi.fn();
    socket.subscribe('ws://router/connections', first, error);
    const old = FakeWebSocket.instances[0];
    old.emit('close');
    expect(error).toHaveBeenCalledOnce();
    socket.subscribe('ws://router/connections', second);
    expect(FakeWebSocket.instances).toHaveLength(2);
    FakeWebSocket.instances[1].emit('message', 'new');
    expect(first).toHaveBeenCalledWith('new');
    expect(second).toHaveBeenCalledWith('new');
  });
});
