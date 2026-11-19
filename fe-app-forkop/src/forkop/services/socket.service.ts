import { logger } from './logger.service';

// eslint-disable-next-line
type Listener = (data: any) => void;
type ErrorListener = (error: Event | string) => void;

function socketLogAddress(url: string): string {
  try {
    const endpoint = new URL(url);
    return `${endpoint.origin}${endpoint.pathname}`;
  } catch {
    return 'WebSocket';
  }
}

class SocketManager {
  private static instance: SocketManager;
  private sockets = new Map<string, WebSocket>();
  private listeners = new Map<string, Set<Listener>>();
  private connected = new Map<string, boolean>();
  private errorListeners = new Map<string, Set<ErrorListener>>();

  private constructor() {}

  static getInstance(): SocketManager {
    if (!SocketManager.instance) {
      SocketManager.instance = new SocketManager();
    }
    return SocketManager.instance;
  }

  resetAll(): void {
    this.disconnectAll();
    logger.info('[SOCKET]', 'All connections and state have been reset.');
  }

  connect(url: string): void {
    if (this.sockets.has(url)) return;

    const logAddress = socketLogAddress(url);
    let ws: WebSocket;

    try {
      ws = new WebSocket(url);
    } catch {
      logger.error(
        '[SOCKET]',
        `Failed to construct WebSocket for ${logAddress}`,
      );
      this.triggerError(url, 'Failed to construct WebSocket');
      return;
    }

    this.sockets.set(url, ws);
    this.connected.set(url, false);
    if (!this.listeners.has(url)) this.listeners.set(url, new Set());
    if (!this.errorListeners.has(url)) this.errorListeners.set(url, new Set());

    ws.addEventListener('open', () => {
      if (this.sockets.get(url) !== ws) return;
      this.connected.set(url, true);
      logger.info('[SOCKET]', 'Connected to', logAddress);
    });

    ws.addEventListener('message', (event) => {
      if (this.sockets.get(url) !== ws) return;
      const handlers = this.listeners.get(url);
      if (handlers) {
        for (const handler of handlers) {
          try {
            handler(event.data);
          } catch {
            logger.error('[SOCKET]', `Handler error for ${logAddress}`);
          }
        }
      }
    });

    ws.addEventListener('close', () => {
      if (this.sockets.get(url) !== ws) return;
      this.sockets.delete(url);
      this.connected.set(url, false);
      logger.warn('[SOCKET]', `Disconnected: ${logAddress}`);
      this.triggerError(url, 'Connection closed');
    });

    ws.addEventListener('error', (err) => {
      if (this.sockets.get(url) !== ws) return;
      logger.error('[SOCKET]', `Socket error for ${logAddress}`);
      this.triggerError(url, err);
    });
  }

  subscribe(
    url: string,
    listener: Listener,
    onError?: ErrorListener,
  ): () => void {
    if (!this.errorListeners.has(url)) {
      this.errorListeners.set(url, new Set());
    }
    if (onError) {
      this.errorListeners.get(url)?.add(onError);
    }

    if (!this.listeners.has(url)) {
      this.listeners.set(url, new Set());
    }
    this.listeners.get(url)?.add(listener);
    this.connect(url);

    let subscribed = true;
    return () => {
      if (!subscribed) return;
      subscribed = false;
      this.unsubscribe(url, listener, onError);
    };
  }

  unsubscribe(url: string, listener: Listener, onError?: ErrorListener): void {
    this.listeners.get(url)?.delete(listener);
    if (onError) {
      this.errorListeners.get(url)?.delete(onError);
    }
    if (!this.listeners.get(url)?.size && !this.errorListeners.get(url)?.size) {
      this.disconnect(url);
    }
  }

  // eslint-disable-next-line
  send(url: string, data: any): void {
    const ws = this.sockets.get(url);
    if (ws && this.connected.get(url)) {
      ws.send(typeof data === 'string' ? data : JSON.stringify(data));
    } else {
      logger.warn(
        '[SOCKET]',
        `Cannot send: not connected to ${socketLogAddress(url)}`,
      );
      this.triggerError(url, 'Not connected');
    }
  }

  disconnect(url: string): void {
    const ws = this.sockets.get(url);
    // Invalidate first: delayed events from this socket must not reach a new
    // subscriber or mark a replacement connection as disconnected.
    this.sockets.delete(url);
    this.listeners.delete(url);
    this.errorListeners.delete(url);
    this.connected.delete(url);
    if (ws) {
      try {
        ws.close();
      } catch {
        logger.error(
          '[SOCKET]',
          `Failed to close socket ${socketLogAddress(url)}`,
        );
      }
    }
  }

  disconnectAll(): void {
    const urls = new Set([
      ...this.sockets.keys(),
      ...this.listeners.keys(),
      ...this.errorListeners.keys(),
    ]);
    for (const url of urls) {
      this.disconnect(url);
    }
  }

  private triggerError(url: string, err: Event | string): void {
    const handlers = this.errorListeners.get(url);
    if (handlers) {
      for (const cb of handlers) {
        try {
          cb(err);
        } catch {
          logger.error(
            '[SOCKET]',
            `Error handler threw for ${socketLogAddress(url)}`,
          );
        }
      }
    }
  }
}

export const socket = SocketManager.getInstance();
