#!/bin/sh
# Build the release APK signed with the real key, from the owner's secrets:
#   ~/.config/secrets/roster-app-keystore           base64 of the PKCS12 keystore (alias roster)
#   ~/.config/secrets/roster-app-keystore-password  its password (store and key)
# The keystore is decoded into a private temp file only for the build.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
secrets="$HOME/.config/secrets"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"
base64 -d "$secrets/roster-app-keystore" > "$tmp/roster.jks"
ROSTER_KEYSTORE_HOST="$tmp/roster.jks"
ROSTER_KEYSTORE_PASSWORD=$(cat "$secrets/roster-app-keystore-password")
export ROSTER_KEYSTORE_HOST ROSTER_KEYSTORE_PASSWORD
# The app knows its own build number, to tell when the hub serves a newer one.
build=$(sed -n 's/^version: .*+\([0-9][0-9]*\)$/\1/p' "$here/pubspec.yaml")
"$here/tool/flutter.sh" flutter build apk --release --dart-define=ROSTER_BUILD="$build" "$@"
apk="$here/build/app/outputs/flutter-apk/app-release.apk"
echo "signed: $apk ($(du -h "$apk" | cut -f1))"
