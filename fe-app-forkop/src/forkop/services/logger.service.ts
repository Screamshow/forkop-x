type LogLevel = 'debug' | 'info' | 'warn' | 'error';

class Logger {
  private write(level: LogLevel, ...args: unknown[]): void {
    console[level === 'debug' ? 'log' : level](
      `[${level.toUpperCase()}] ${args.join(' ')}`,
    );
  }

  debug(...args: unknown[]): void {
    this.write('debug', ...args);
  }

  info(...args: unknown[]): void {
    this.write('info', ...args);
  }

  warn(...args: unknown[]): void {
    this.write('warn', ...args);
  }

  error(...args: unknown[]): void {
    this.write('error', ...args);
  }
}

export const logger = new Logger();
