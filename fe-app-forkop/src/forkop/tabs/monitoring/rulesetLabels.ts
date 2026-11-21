// Keep this identifier in sync with xrust/rulesets.uc hash12().
export function customRulesetTag(reference: string): string {
  let first = 2166136261;
  let second = 16777619;
  for (const code of new TextEncoder().encode(reference)) {
    first = (first * 33 + code) >>> 0;
    second = (second * 131 + code) >>> 0;
  }
  const hex = (value: number) =>
    (value & 0xffffff).toString(16).padStart(6, '0');
  return `inline-custom-${hex(first)}${hex(second)}-ruleset`;
}

export function customRulesetLabel(reference: string): string {
  const path = reference.split(/[?#]/)[0];
  const filename = path.split('/').pop() || '';
  const name = filename.replace(/\.(?:srs|json)$/i, '');
  return name ? name.replace(/^./, (c) => c.toUpperCase()) : reference;
}
