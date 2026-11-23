#!/bin/sh
set -eu

package_root=$1
www_root=$2
view=luci-static/resources/view/forkop
manifest="$package_root/generated/source.sha256"

(cd "$package_root" && sha256sum -c generated/source.sha256) >/dev/null
manifest_sources=$(awk '{print $2}' "$manifest")
for source in "$package_root/htdocs/$view/"*.js; do
  name=${source##*/}
  [ "$name" != main.js ] || continue
  if ! printf '%s\n' "$manifest_sources" | grep -Fxq "htdocs/$view/$name"; then
    printf 'Missing compact LuCI asset in manifest: %s\n' "$name" >&2
    exit 1
  fi
done

while read -r digest source; do
  name=${source#"htdocs/$view/"}
  case "$name" in
    main.js|*[!A-Za-z0-9_.-]*)
      printf 'Invalid compact LuCI asset in manifest: %s\n' "$source" >&2
      exit 1 ;;
    *.js) ;;
    *) exit 1 ;;
  esac
  [ -n "$digest" ]
  cp -p "$package_root/generated/$view/$name" "$www_root/$view/$name"
done < "$manifest"
