#!/bin/sh
# Puts the release APK (tool/release.sh) on the hub, at /roster.apk, with
# roster.apk.json saying its version, so phones offer it as an update.
#   tool/publish-apk.sh user@hub-host
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
target=${1:?usage: publish-apk.sh user@hub-host}
apk="$here/build/app/outputs/flutter-apk/app-release.apk"
[ -f "$apk" ] || { echo "no release APK; run tool/release.sh first" >&2; exit 1; }
version=$(sed -n 's/^version: \([^+]*\)+.*$/\1/p' "$here/pubspec.yaml")
build=$(sed -n 's/^version: .*+\([0-9][0-9]*\)$/\1/p' "$here/pubspec.yaml")
scp -q "$apk" "$target:.local/share/roster/web/roster.apk.new"
ssh "$target" "cd ~/.local/share/roster/web && mv roster.apk.new roster.apk && printf '{\"version\": \"%s\", \"build\": %s}\n' '$version' '$build' > roster.apk.json.new && mv roster.apk.json.new roster.apk.json"
echo "published roster $version (build $build) on $target"
