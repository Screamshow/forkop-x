// Translate known Forkop messages; preserve the original log for diagnostics.
export function getLogErrorMessage(line: string): string | null {
  if (
    line.includes('WhatsApp real DNS requires downloaded Meta subnet rules')
  ) {
    return _(
      'Meta subnet lists for WhatsApp are missing. Download the Meta lists and apply again, or turn off real IPs for WhatsApp.',
    );
  }
  if (line.includes('WhatsApp real DNS requires the Meta community list')) {
    return _(
      'WhatsApp real IPs require an enabled routing section with Meta and no device or port filters. Restore Meta or turn off real IPs for WhatsApp before saving. Otherwise Forkop cannot start after a reboot.',
    );
  }
  const space = line.match(
    /Not enough (flash space|temporary memory) for (Forkop update and rollback|sing-box): (?:conservative installation reserve needs|need) (\d+) KiB free, have (\d+) KiB/,
  );
  if (space) {
    const template =
      space[1] === 'flash space'
        ? space[2] === 'sing-box'
          ? _(
              'Not enough storage for sing-box installation. Required reserve: %s KiB; available: %s KiB.',
            )
          : _(
              'Not enough storage for Forkop update and rollback. Required reserve: %s KiB; available: %s KiB.',
            )
        : _(
            'Not enough temporary memory. Required: %s KiB; available: %s KiB.',
          );
    return template.replace('%s', space[3]).replace('%s', space[4]);
  }
  if (
    line.includes(
      'Forkop startup retry suppressed because the failure requires configuration or operator action',
    )
  ) {
    return _(
      'Automatic restart is paused. Check the configuration and the startup error in the logs.',
    );
  }
  if (line.includes('Generated sing-box configuration is invalid')) {
    return _(
      'The generated sing-box configuration is invalid. See technical details for the validation error.',
    );
  }
  const phase = line.match(
    /Startup phase '([^']+)' failed with exit status (\d+)/,
  );
  if (phase) {
    return _('Startup phase %s failed (exit code %s).')
      .replace('%s', phase[1])
      .replace('%s', phase[2]);
  }
  if (line.includes('Forkop automatic recovery attempt failed')) {
    return _('Automatic recovery failed. Check the startup error in the logs.');
  }
  return null;
}
