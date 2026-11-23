let fs = require("fs");

function parse_stat(stat) {
    if (type(stat) != "string")
        return null;
    // The parenthesized name can contain spaces and closing parentheses.
    let marker = rindex(stat, ") ");
    if (marker < 0)
        return null;
    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    if (length(fields) < 20 || !match(fields[0], /^[A-Za-z]$/) ||
        !match(fields[1], /^[0-9]+$/) || !match(fields[19], /^[0-9]+$/))
        return null;
    return { state: fields[0], parent: fields[1], ticks: fields[19] };
}

function start_ticks(pid, proc_root) {
    if (!match("" + pid, /^[1-9][0-9]*$/))
        return null;
    return parse_stat(fs.readfile((proc_root || "/proc") + "/" + pid + "/stat"))?.ticks;
}

return { parse_stat, start_ticks };
