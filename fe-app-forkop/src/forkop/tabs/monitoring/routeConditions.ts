import type { Forkop } from '../../types';

export type RuntimeRouteRule = Record<string, unknown>;

export function createRuntimeRouteRulesLoader(
  read: (path: string) => Promise<string>,
  update: (rules: RuntimeRouteRule[]) => void,
) {
  let requested: Forkop.RuntimeConfigReference | undefined;
  return {
    clear() {
      if (!requested) return;
      requested = undefined;
      update([]);
    },
    async load(reference: Forkop.RuntimeConfigReference) {
      if (
        requested?.path === reference.path &&
        requested.revision === reference.revision
      ) {
        return;
      }

      const request = { ...reference };
      requested = request;
      update([]);
      try {
        const config = JSON.parse(await read(request.path));
        if (requested === request) {
          update(Array.isArray(config?.route?.rules) ? config.route.rules : []);
        }
      } catch {
        // Retry on the next state refresh, displaying the core's original rule.
        if (requested === request) requested = undefined;
      }
    },
  };
}

export function expandRouteConditions(
  reported: string,
  rules: RuntimeRouteRule[],
): string {
  if (!reported.includes('...') && !reported.includes('…')) return reported;
  const outbound = reported.match(/=>\s*route\(([^)]+)\)\s*$/)?.[1];
  if (!outbound) return reported;
  const conditions = reported.replace(/\s*=>.*$/, '');
  if (/^\s*\(|\b(?:invert|rule_set)=/.test(conditions)) return reported;
  const fields = [...conditions.matchAll(/(?:^|\s)([a-z_]+)=/g)];
  if (!fields.length) return reported;
  const candidates = rules.filter((rule) => {
    if (rule.outbound !== outbound || rule.type === 'logical' || rule.invert)
      return false;
    return fields.every((field, index) => {
      const value = rule[field[1]];
      if (value === undefined || value === null) return false;
      const raw = conditions
        .slice(
          field.index! + field[0].length,
          fields[index + 1]?.index ?? conditions.length,
        )
        .trim();
      const preview =
        raw.startsWith('[') && raw.endsWith(']') ? raw.slice(1, -1) : raw;
      const full = Array.isArray(value) ? value.join(' ') : String(value);
      const truncated = /(?:\.\.\.|…)$/u.test(preview);
      return truncated
        ? full.startsWith(preview.replace(/(?:\.\.\.|…)$/u, ''))
        : full === preview;
    });
  });
  // Two rules can share the same truncated prefix. Never pick one by order.
  if (candidates.length !== 1) return reported;
  const rule = candidates[0];
  return (
    fields
      .map((field) => {
        const value = rule[field[1]];
        return `${field[1]}=${Array.isArray(value) ? `[${value.join(' ')}]` : String(value)}`;
      })
      .join(' ') + ` => route(${outbound})`
  );
}
