#!/usr/bin/env ucode

let fs = require("fs");

const OWNER_WRITE_GRACE_SECONDS = 5;

// The guard serializes owner mutations, including stale takeover. Its inode
// must stay in place across release. The PID record remains readable by
// callers using the previous directory layout.
const MUTATE_OWNER = '
    lock_dir=$1
    operation=$2
    pid=$3
    grace=$4
    exec 9>>"$lock_dir.guard" || exit 1
    if command -v flock >/dev/null 2>&1; then
        flock -x 9 || exit 1
    else
        busybox flock -x 9 || exit 1
    fi
    if [ "$operation" = release ]; then
        [ -d "$lock_dir" ] || exit 0
        rm -f "$lock_dir/pid" && rmdir "$lock_dir"
        exit $?
    fi
    created=0
    if mkdir "$lock_dir" 2>/dev/null; then
        created=1
    elif [ -d "$lock_dir" ]; then
        owner=
        if [ -f "$lock_dir/pid" ]; then
            read -r owner <"$lock_dir/pid"
        fi
        case "$owner" in
            "") ucode -e \'let mtime = require("fs").stat(ARGV[0])?.mtime;
                let now = int(clock()[0]);
                exit(mtime > 0 && now - mtime >= int(ARGV[1]) ? 0 : 1);\' "$lock_dir" "$grace" || exit 1 ;;
            0*|*[!0-9]*) ;;
            *) kill -0 "$owner" 2>/dev/null && exit 1 ;;
        esac
    else
        exit 1
    fi
    pending="$lock_dir.guard.pid"
    if printf "%s\\n" "$pid" >"$pending" && mv -f "$pending" "$lock_dir/pid"; then
        exit 0
    fi
    rm -f "$pending"
    [ "$created" -eq 0 ] || rmdir "$lock_dir"
    exit 1
';

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

function mutate_owner(lock_dir, operation, owner_pid) {
    return command_success([ "sh", "-c", MUTATE_OWNER, "lock",
        lock_dir, operation, owner_pid, OWNER_WRITE_GRACE_SECONDS ]);
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

    mutate_owner(lock_dir, "release", "");
}

function acquire(lock_dir, owner_pid) {
    lock_dir = as_string(lock_dir);
    owner_pid = as_string(owner_pid);
    if (lock_dir == "" || match(owner_pid, /^[1-9][0-9]*$/) == null)
        return false;

    return mutate_owner(lock_dir, "acquire", owner_pid);
}

return {
    OWNER_WRITE_GRACE_SECONDS,
    held,
    acquire,
    release
};
