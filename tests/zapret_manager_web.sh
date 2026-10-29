#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ACTION="$ROOT/forkop/files/usr/lib/components/action.uc"
ucode -e '
let fs=require("fs"),s=fs.readfile(ARGV[0]);
let a=index(s,"function zapret_manager_launcher_owned("),t=substr(s,a);
let f=substr(t,0,index(t,"\n}")+2);
let code=f+`
assert(zapret_manager_launcher_owned("sh <(wget https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh)"),"historical upstream");
assert(zapret_manager_launcher_owned("https://raw.githubusercontent.com/Screamshow/Zapret-Manager/main/ZapretManager_LuCI.sh"),"our web launcher");
assert(zapret_manager_launcher_owned("https://mirror.test/zapret-manager/proxy/raw.githubusercontent.com/Screamshow/Zapret-Manager/main/Zapret-Manager.sh"),"mirror");
assert(!zapret_manager_launcher_owned("echo my own zms"),"foreign launcher");
assert(!zapret_manager_launcher_owned("https://raw.githubusercontent.com/other/Zapret-Manager/main/Zapret-Manager.sh"),"foreign repository");
assert(!zapret_manager_launcher_owned("https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Zapret-Manager.sh.backup"),"wrong script");
`;
let path="/tmp/forkop-zm-ownership."+fs.readlink("/proc/self")+".uc";
fs.writefile(path,code);let status=system(["ucode",path]);fs.unlink(path);exit(status);
' "$ACTION"
# Removal must reject foreign launchers before touching panel files.
awk '
/^function remove_zapret_manager\(/ { f=1 }
f && /zapret_manager_launcher_owned/ && !own { own=NR }
f && /remove_zapret_manager_web\(\)/ && !web { web=NR }
f && /remove_file\(path\)/ && !rm { rm=NR }
f && /^}/ { exit }
END { exit !(own && web>own && rm>web) }
' "$ACTION"
grep -q 'zapret-manager-migrate.sh' "$ACTION"
grep -q 'zapret-manager-upgrade.sh' "$ROOT/forkop/files/usr/lib/service/package.uc"
echo 'PASS: historical/our ownership, foreign protection, transactional installation, upgrade hook'
