#!/bin/sh
# Install roster for the current user, in ~/.local only: no root, no layering,
# so it works on an atomic or CoreOS host as it comes.
#
#   curl -fsSL https://raw.githubusercontent.com/sennadevos/roster/main/install.sh | sh
#   ./install.sh --from .            # from a checkout
#   ./install.sh --ref v0.2.0        # a tag or commit of the GitHub repo
#
# Anything after the options goes to `roster install` (see `roster install -h`),
# which sets up the tmux config, the user units, the Claude Code hooks and the
# skill. What this script adds is what a bare host lacks:
#   - Python 3.11+: the system one when there is one, else a standalone build
#   - tmux: the one on PATH, else the official static build
#   - roster itself, under ~/.local/share/roster, with wrappers in ~/.local/bin
set -eu

REPO=sennadevos/roster
REF=main
FROM=
TMUX_VERSION=3.7c
PY_RELEASE=20261013
PY_VERSION=3.14.8

PREFIX="$HOME/.local/share/roster"
BIN="$HOME/.local/bin"

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM=$(cd "$2" && pwd); shift 2 ;;
        --ref) REF=$2; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done

say() { printf 'roster-install: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

case "$(uname -m)" in
    x86_64) TMUX_ARCH=x86_64; PY_ARCH=x86_64
            TMUX_SHA=cc56bd1cc873eb6089c615f0496b072385bda8a6d944069f38564a5d49c128aa
            PY_SHA=322271a761140ffb3f522431048f701831e412c8f64770103d2b881ee2bbaed0 ;;
    aarch64|arm64) TMUX_ARCH=arm64; PY_ARCH=aarch64
            TMUX_SHA=29dcb978da2a4b0cf6790f9e004865dac239a3ba03bbf776dddacce23d03831b
            PY_SHA=6c3cfb175acca2748d5a9e42208c523bfbc1099ddb928615b5f328ba7c106e83 ;;
    *) die "unsupported machine $(uname -m)" ;;
esac

fetch() {  # url sha256 dest
    curl -fsSL --retry 3 -o "$3" "$1" || die "download failed: $1"
    echo "$2  $3" | sha256sum -c --quiet - || die "checksum mismatch: $1"
}

mkdir -p "$PREFIX/versions" "$BIN"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. roster itself, into a fresh version directory, then switch `current` to it
# in one rename, so running agents never see a half-copied tree.
version="$(date +%Y%m%d%H%M%S)"
dest="$PREFIX/versions/$version"
mkdir -p "$dest"
# install.sh comes along, so `roster peer add` can install this same version elsewhere.
if [ -n "$FROM" ]; then
    cp -R "$FROM/bin" "$FROM/share" "$FROM/install.sh" "$dest/"
else
    curl -fsSL --retry 3 "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$tmp"
    cp -R "$tmp"/*/bin "$tmp"/*/share "$tmp"/*/install.sh "$dest/"
fi
chmod +x "$dest"/bin/*
ln -s "versions/$version" "$PREFIX/current.new"
mv -T "$PREFIX/current.new" "$PREFIX/current"
# Keep the previous two versions: a waiter started by the old one may still run.
ls -1d "$PREFIX"/versions/* | head -n -3 | while read -r old; do rm -rf "$old"; done

# 2. Python 3.11+ (tomllib).
PY=
for cand in /usr/bin/python3 "$(command -v python3 || true)" "$PREFIX/python/bin/python3"; do
    if [ -n "$cand" ] && [ -x "$cand" ] && "$cand" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
        PY=$cand; break
    fi
done
if [ -z "$PY" ]; then
    say "no Python 3.11+; fetching CPython $PY_VERSION (python-build-standalone $PY_RELEASE)"
    fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/cpython-$PY_VERSION+$PY_RELEASE-$PY_ARCH-unknown-linux-gnu-install_only.tar.gz" \
        "$PY_SHA" "$tmp/python.tgz"
    rm -rf "$PREFIX/python"
    tar -xzf "$tmp/python.tgz" -C "$PREFIX"
    PY="$PREFIX/python/bin/python3"
fi

# 3. tmux, when there is none on PATH.
if ! command -v tmux >/dev/null 2>&1 && [ ! -x "$PREFIX/tmux/tmux" ]; then
    say "no tmux; fetching the static tmux $TMUX_VERSION"
    fetch "https://github.com/tmux/tmux-builds/releases/download/v$TMUX_VERSION/tmux-$TMUX_VERSION-linux-$TMUX_ARCH.tar.gz" \
        "$TMUX_SHA" "$tmp/tmux.tgz"
    mkdir -p "$PREFIX/tmux"
    tar -xzf "$tmp/tmux.tgz" -C "$PREFIX/tmux"
fi

# 4. Wrappers. The tray needs the system Python for dbus-python and PyGObject.
wrapper() {  # name python
    cat > "$BIN/$1.new" <<EOF
#!/bin/sh
# Written by roster's install.sh.
exec $2 "$PREFIX/current/bin/$1" "\$@"
EOF
    chmod +x "$BIN/$1.new"
    mv -f "$BIN/$1.new" "$BIN/$1"
}
wrapper roster "$PY"
wrapper roster-pick "$PY"
wrapper roster-hub "$PY"
if [ -x /usr/bin/python3 ]; then
    wrapper roster-tray /usr/bin/python3
fi

say "roster $(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$dest/bin/roster") in $PREFIX/current, Python $PY"
exec "$BIN/roster" install "$@"
