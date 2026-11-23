const SECONDS_PER_UNIT = { ns: 0.000000001, us: 0.000001, ms: 0.001, s: 1, m: 60, h: 3600, d: 86400 };
const MAX_EXACT_INTEGER = 9007199254740991;

// Accept a sequence of positive-number/unit pairs, e.g. 1m250ms.
// Keep fractional seconds until the consumer chooses the timer's precision.
function parse_seconds(value) {
    let rest = value == null ? "" : "" + value;
    let total = 0.0;
    while (rest != "") {
        let token = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (token == null)
            return null;
        total += (token[1] * 1) * SECONDS_PER_UNIT[token[3]];
        if (!(total <= MAX_EXACT_INTEGER))
            return null;
        rest = substr(rest, length(token[0]));
    }
    return total > 0 ? total : null;
}

function nearest_integer(value) {
    let integer = int(value);
    return value - integer >= 0.5 ? integer + 1 : integer;
}

function round_seconds(value) {
    let seconds = parse_seconds(value);
    return seconds == null ? null : nearest_integer(seconds);
}

function ceil_seconds(value, fallback) {
    let seconds = parse_seconds(value);
    if (seconds == null)
        return fallback;
    let integer = int(seconds);
    return seconds > integer ? integer + 1 : integer;
}

function round_milliseconds(value, fallback) {
    let seconds = parse_seconds(value);
    if (seconds == null || seconds * 1000 > MAX_EXACT_INTEGER)
        return fallback;
    return max(1, nearest_integer(seconds * 1000));
}

return { parse_seconds, round_seconds, ceil_seconds, round_milliseconds };
