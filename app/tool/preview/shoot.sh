#!/bin/sh
# Serves build/web with the fake hub and screenshots it in headless Chromium,
# all inside the Playwright image (nothing on the host, no window). The
# screenshots land in the directory given (default screenshots/), which git
# ignores. Playwright's npm package is cached in the podman volume
# roster-app-playwright.
#   tool/build_web.sh && tool/preview/shoot.sh [out dir] [only]
# FAKE_DELAY (ms, default 150) slows every API answer, to see loading states.
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
out=${1:-screenshots}
only=${2:-}
mkdir -p "$here/$out"
exec podman run --rm --init \
  -v "$here:/app:z" \
  -v roster-app-playwright:/pw \
  -e FAKE_DELAY="${FAKE_DELAY:-150}" \
  -w /app mcr.microsoft.com/playwright:v1.64.0-noble \
  sh -c '
    set -e
    [ -d /pw/node_modules/playwright ] || (cd /pw && npm init -y >/dev/null && npm i --silent playwright@1.64.0)
    node tool/preview/fake_hub.mjs 8790 build/web &
    sleep 1
    cp tool/preview/shoot.mjs /pw/shoot.mjs
    cd /pw && node shoot.mjs http://127.0.0.1:8790/ "/app/$1" "$2"
  ' sh "$out" "$only"
