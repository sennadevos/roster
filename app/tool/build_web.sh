#!/bin/sh
# Builds the web app into build/web, which roster-hub serves. Every resource
# comes from the same origin: CanvasKit from build/web/canvaskit
# (--no-web-resources-cdn) and the fallback fonts from build/web/fonts
# (tool/web_fonts.sh). Extra arguments go to `flutter build web`.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
"$here/tool/flutter.sh" flutter build web --release --no-web-resources-cdn "$@"
"$here/tool/flutter.sh" sh tool/web_fonts.sh
