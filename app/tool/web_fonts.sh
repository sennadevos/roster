#!/bin/sh
# Runs in the build container after `flutter build web` (see build_web.sh).
# The web engine fetches Roboto and its fallback fonts (Noto: symbols, emoji,
# CJK, other scripts) from fonts.gstatic.com unless fontFallbackBaseUrl points
# elsewhere. This copies every font this build's engine can ask for, by the
# paths listed in main.dart.js, into build/web/fonts/, so they are served by
# the hub like the rest of the app. Downloads are cached in $FONT_CACHE (a
# podman volume); the paths are versioned, so a cached file never goes stale.
set -eu
out=build/web
cache=${FONT_CACHE:-/root/.cache/roster-webfonts}
list=$(grep -oE '[a-z0-9]+/v[0-9]+/[A-Za-z0-9_.-]+\.(woff2|ttf|otf)' "$out/main.dart.js" | sort -u)
[ -n "$list" ] || { echo "web_fonts: no font paths found in $out/main.dart.js" >&2; exit 1; }
mkdir -p "$cache"
fetched=0
for p in $list; do
  if [ ! -s "$cache/$p" ]; then
    mkdir -p "$cache/$(dirname "$p")"
    curl -fsSLo "$cache/$p.part" "https://fonts.gstatic.com/s/$p"
    mv "$cache/$p.part" "$cache/$p"
    fetched=$((fetched + 1))
  fi
  mkdir -p "$out/fonts/$(dirname "$p")"
  cp "$cache/$p" "$out/fonts/$p"
done
echo "web_fonts: $(echo "$list" | wc -l) fonts in $out/fonts ($fetched downloaded, the rest cached), $(du -sh "$out/fonts" | cut -f1)"
