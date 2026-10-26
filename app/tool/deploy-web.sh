#!/bin/sh
# Put the web build (app/build/web) where roster-hub serves it, on the hub's
# machine: ~/.local/share/roster/web there, swapped in in one rename so the
# hub never serves a half-copied app. Build first:
#   tool/flutter.sh flutter build web --release ...   (see README)
#   tool/deploy-web.sh sjdevos@10.137.42.3
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
target=${1:?usage: deploy-web.sh user@hub-host}
[ -f "$here/build/web/index.html" ] || { echo "no web build in $here/build/web" >&2; exit 1; }
tar -C "$here/build/web" -czf - . | ssh "$target" '
    set -e
    d=~/.local/share/roster
    mkdir -p "$d"
    rm -rf "$d/web.new"; mkdir "$d/web.new"
    tar -xzf - -C "$d/web.new"
    # The Android APK sits beside the web app (roster.apk); keep it.
    [ -f "$d/web/roster.apk" ] && cp -p "$d/web/roster.apk" "$d/web.new/"
    rm -rf "$d/web.old"
    [ -d "$d/web" ] && mv "$d/web" "$d/web.old"
    mv "$d/web.new" "$d/web"
    rm -rf "$d/web.old"
    echo "web app in $d/web ($(du -sh "$d/web" | cut -f1))"'
