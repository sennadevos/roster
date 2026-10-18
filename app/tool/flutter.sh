#!/bin/sh
# Runs a command in the build container with this directory mounted at /app,
# building the image from ./Containerfile first if it is not there yet.
# Pub and Gradle caches live in named podman volumes, so builds after the
# first are quick, and so does ~/.android, so the debug key that signs the
# APK stays the same from build to build. Examples:
#   tool/flutter.sh flutter build apk --release
#   tool/flutter.sh flutter test
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
image=localhost/roster-app-build:3.47.7
podman image exists "$image" || podman build -t "$image" -f "$here/Containerfile" "$here"
exec podman run --rm \
  -v "$here:/app:z" \
  -v roster-app-pub:/root/.pub-cache \
  -v roster-app-gradle:/root/.gradle \
  -v roster-app-android:/root/.android \
  -w /app "$image" "$@"
