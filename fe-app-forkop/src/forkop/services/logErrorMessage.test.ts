import { describe, expect, it } from 'vitest';
import { getLogErrorMessage } from './logErrorMessage.service';

describe('log error messages', () => {
  it('formats storage amounts from a syslog line', () => {
    expect(
      getLogErrorMessage(
        'Wed Oct 7 user.notice forkop: [error] Updates: Not enough flash space for Forkop update and rollback: need 11609 KiB free, have 5344 KiB',
      ),
    ).toBe(
      'Not enough storage for Forkop update and rollback. Required reserve: 11609 KiB; available: 5344 KiB.',
    );
  });
  it('accepts the sing-box reserve wording', () => {
    expect(
      getLogErrorMessage(
        'Not enough flash space for sing-box: conservative installation reserve needs 10000 KiB free, have 8000 KiB',
      ),
    ).toContain('10000 KiB; available: 8000 KiB');
  });
  it('keeps phase names and exit codes', () => {
    expect(
      getLogErrorMessage(
        "[fatal] Startup phase 'sing-box-config' failed with exit status 1",
      ),
    ).toBe('Startup phase sing-box-config failed (exit code 1).');
  });
  it('recognizes validation and suppressed retry messages', () => {
    expect(
      getLogErrorMessage(
        'Generated sing-box configuration is invalid: FATAL secret technical output',
      ),
    ).toContain('configuration is invalid');
    expect(
      getLogErrorMessage(
        'Forkop startup retry suppressed because the failure requires configuration or operator action; see the fatal startup error in LuCI logs',
      ),
    ).toContain('Automatic restart is paused');
  });
  it('leaves unknown errors untouched', () => {
    expect(getLogErrorMessage('Unknown backend error')).toBeNull();
  });
  it('explains both WhatsApp prerequisite failures before generic validation errors', () => {
    expect(
      getLogErrorMessage(
        'WhatsApp real DNS requires the Meta community list in an enabled routing section without source or port filters.',
      ),
    ).toContain('Restore Meta or turn off real IPs');
    expect(
      getLogErrorMessage(
        "Generated sing-box configuration is invalid: WhatsApp real DNS requires downloaded Meta subnet rules for 'vpn'",
      ),
    ).toContain('Download the Meta lists');
  });
});
