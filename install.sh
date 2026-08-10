#!/bin/bash
# Installer for Hebrew push-to-talk dictation.
# Compiles the recorder, installs the Hammerspoon config, and stores your Groq API key.
set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
KEYFILE="$HOME/.config/dictation-groq-key"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf "\033[1m%s\033[0m\n" "$*"; }
warn() { printf "\033[33m%s\033[0m\n" "$*"; }
die()  { printf "\033[31m%s\033[0m\n" "$*" >&2; exit 1; }

# ── prerequisites ────────────────────────────────────────────────────────────
say "==> Checking prerequisites"

[ -d /Applications/Hammerspoon.app ] || die \
  "Hammerspoon is not installed. Get it from https://www.hammerspoon.org (or: brew install --cask hammerspoon)"

command -v swiftc >/dev/null 2>&1 || die \
  "swiftc not found. Install the Xcode command line tools:  xcode-select --install"

echo "    Hammerspoon: ok"
echo "    swiftc:      $(swiftc --version 2>/dev/null | head -1)"

# ── build the recorder ───────────────────────────────────────────────────────
say "==> Building the recorder"
mkdir -p "$HS_DIR/bin"
swiftc -O -o "$HS_DIR/bin/dictation-recorder" "$SRC/bin/dictation-recorder.swift"
cp "$SRC/bin/compare-transcribers.sh" "$HS_DIR/bin/"
chmod +x "$HS_DIR/bin/compare-transcribers.sh"
echo "    built: $HS_DIR/bin/dictation-recorder"

# ── API key ──────────────────────────────────────────────────────────────────
say "==> Groq API key"
if [ -s "$KEYFILE" ]; then
    echo "    already present at $KEYFILE (leaving it alone)"
else
    echo "    Get a free key at https://console.groq.com/keys"
    printf "    Paste your Groq API key (starts with gsk_): "
    read -r KEY
    [ -n "$KEY" ] || die "No key entered. Re-run this script when you have one."
    mkdir -p "$(dirname "$KEYFILE")"
    printf '%s' "$KEY" > "$KEYFILE"
    chmod 600 "$KEYFILE"
    echo "    saved to $KEYFILE (permissions 600)"
fi

# ── Hammerspoon config ───────────────────────────────────────────────────────
say "==> Installing the Hammerspoon config"
cp "$SRC/dictation.lua" "$HS_DIR/dictation.lua"

if [ -f "$HS_DIR/init.lua" ]; then
    if grep -q 'dictation' "$HS_DIR/init.lua" 2>/dev/null; then
        echo "    init.lua already loads dictation - not touching it"
    else
        BACKUP="$HS_DIR/init.lua.bak-$(date +%Y%m%d%H%M%S)"
        cp "$HS_DIR/init.lua" "$BACKUP"
        printf '\nrequire("dictation")\n' >> "$HS_DIR/init.lua"
        warn "    You already had an init.lua. Backed it up to:"
        warn "      $BACKUP"
        echo  "    and appended require(\"dictation\") to the existing one."
    fi
else
    printf 'require("dictation")\n' > "$HS_DIR/init.lua"
    echo "    created $HS_DIR/init.lua"
fi

# ── done ─────────────────────────────────────────────────────────────────────
say "==> Installed"
cat <<'EOF'

Two permissions still need granting BY HAND (macOS will not let a script do it):

  System Settings → Privacy & Security → Accessibility  → enable Hammerspoon
  System Settings → Privacy & Security → Microphone     → enable Hammerspoon

Then launch Hammerspoon. If it is already running, reload with Ctrl+Cmd+R.

Usage:  hold fn+Shift, speak, release. The text is pasted at your cursor.
        Wait for "🎙️ מקליט" before speaking - "⏳ מתחבר" means the mic is
        still opening and anything said then is lost.
EOF
