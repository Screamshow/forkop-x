import { ForkopLogNotification } from './logNotificationDeduper.service';

type NotificationEmitter = (notification: ForkopLogNotification) => void;

export function isRecoverableStartFailureLog(line: string) {
  const lower = line.toLowerCase();
  return (
    lower.includes('xrust did not reach a stable running state after start') ||
    (lower.includes('controlled xrust transition refused:') &&
      /before start|start command failed|appeared after start|new managed runtime/.test(
        lower,
      ))
  );
}

function isRetryScheduledLog(line: string) {
  return line.includes('Forkop start failed; scheduled an automatic retry');
}

function isRecoverySucceededLog(line: string) {
  return line.includes('Forkop recovered automatically after a failed start');
}

function isRecoveryFailedLog(line: string) {
  return (
    line.includes('Forkop automatic recovery attempt failed') ||
    line.includes('Forkop startup retry suppressed')
  );
}

// Startup failures that are followed by Forkop's own retry are not final
// failures. Hold their red toast briefly: the next log line either schedules
// recovery (show a warning instead) or leaves the original fatal visible.
export class StartRecoveryNotificationController {
  private pendingFailure?: ForkopLogNotification;
  private pendingTimer?: ReturnType<typeof setTimeout>;

  constructor(private readonly emit: NotificationEmitter) {}

  private clearPending() {
    if (this.pendingTimer !== undefined) clearTimeout(this.pendingTimer);
    this.pendingTimer = undefined;
    this.pendingFailure = undefined;
  }

  handle(line: string) {
    if (isRecoverableStartFailureLog(line)) {
      if (!this.pendingFailure) {
        this.pendingFailure = { kind: 'error', line };
        this.pendingTimer = setTimeout(() => {
          const notification = this.pendingFailure;
          this.clearPending();
          if (notification) this.emit(notification);
        }, 1000);
      }
      return true;
    }

    if (isRetryScheduledLog(line)) {
      this.clearPending();
      this.emit({ kind: 'start-recovery-pending', line });
      return true;
    }

    if (isRecoverySucceededLog(line)) {
      this.clearPending();
      this.emit({ kind: 'start-recovery-succeeded', line });
      return true;
    }

    if (isRecoveryFailedLog(line)) {
      this.clearPending();
      return false;
    }

    return false;
  }
}
