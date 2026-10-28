#!/usr/bin/env ucode

let fs = require("fs");

// A directory lock is taken in two steps: the directory first, its owner
// second. Between them the directory has no owner, so a caller that reads
// "no owner" as "nobody holds this" removes a lock another worker is still
// taking. These helpers keep that window closed and hand ownership over
// through the pid file alone, so the directory a caller sees is never the
// one it destroys.
const OWNER_WRITE_GRACE_SECONDS = 5;

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_success(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return system(join(" ", parts) + " >/dev/null 2>&1") == 0;
}

function first_line_value(path) {
    let data = fs.readfile(path);
    if (data == null)
        return "";

    let newline = index(data, "\n");
    return trim(newline >= 0 ? substr(data, 0, newline) : data);
}

// Pid 0 is not a process: `kill -0 0` signals the caller's own process group and
// always succeeds, so an owner of 0 would read as alive for ever and the lock
// would never be released to anybody.
function pid_alive(pid) {
    pid = as_string(pid);
    return match(pid, /^[1-9][0-9]*$/) != null && command_success([ "kill", "-0", pid ]);
}

function current_epoch() {
    return int(clock()[0]) || 0;
}

// Only one caller may write the owner: noclobber creates the file with
// O_EXCL, so a caller that lost a race for an abandoned lock is told, instead
// of overwriting the owner that won it.
function claim_owner(lock_dir, owner_pid) {
    return command_success([ "sh", "-c", "set -C; printf '%s\\n' \"$2\" > \"$1\"",
        "lock", as_string(lock_dir) + "/pid", as_string(owner_pid) ]);
}

function held(lock_dir) {
    lock_dir = as_string(lock_dir);
    let stat = lock_dir == "" ? null : fs.stat(lock_dir);
    if (stat == null)
        return false;

    let owner_pid = first_line_value(lock_dir + "/pid");
    if (owner_pid != "")
        return pid_alive(owner_pid);

    // No owner yet: either the lock is being taken right now, or whoever
    // created it never came back. Only its age tells the two apart.
    let now = current_epoch();
    let created = int(stat.mtime || 0);
    return now <= 0 || created <= 0 || now - created < OWNER_WRITE_GRACE_SECONDS;
}

function release(lock_dir) {
    lock_dir = as_string(lock_dir);
    if (lock_dir == "")
        return;

    command_success([ "rm", "-f", lock_dir + "/pid" ]);
    command_success([ "rmdir", lock_dir ]);
}

function acquire(lock_dir, owner_pid) {
    lock_dir = as_string(lock_dir);
    owner_pid = as_string(owner_pid);
    if (lock_dir == "" || match(owner_pid, /^[1-9][0-9]*$/) == null)
        return false;

    if (command_success([ "mkdir", lock_dir ])) {
        if (claim_owner(lock_dir, owner_pid))
            return true;
        release(lock_dir);
        return false;
    }

    if (held(lock_dir))
        return false;

    // The lock was abandoned: replace it. Two callers can still reach this
    // point together, and one of them can remove the directory the other has
    // just created, so the owner file decides the outcome. Whoever loses the
    // exclusive write of the owner has not taken the lock and says so,
    // instead of working alongside the caller that did take it.
    command_success([ "rm", "-f", lock_dir + "/pid" ]);
    if (!command_success([ "rmdir", lock_dir ]))
        return false;
    if (!command_success([ "mkdir", lock_dir ]))
        return false;

    return claim_owner(lock_dir, owner_pid);
}

return {
    OWNER_WRITE_GRACE_SECONDS,
    held,
    acquire,
    release
};
