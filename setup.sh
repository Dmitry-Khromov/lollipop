#!/bin/bash
# Lollipop 🍭 setup — installs and health-checks everything. Safe to re-run anytime.
set -euo pipefail

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/mac-dictation"
KEY_FILE="$CONFIG_DIR/groq_key"
HS_DIR="$HOME/.hammerspoon"
INIT="$HS_DIR/init.lua"

bold "Lollipop setup 🍭"

# 1. macOS
[ "$(uname)" = "Darwin" ] || fail "This is a macOS tool."
ok "macOS"

# 2. Homebrew
command -v brew >/dev/null 2>&1 || fail "Homebrew not found — install it from https://brew.sh and re-run."
ok "Homebrew"

# 3. ffmpeg
if [ ! -x /opt/homebrew/bin/ffmpeg ] && [ ! -x /usr/local/bin/ffmpeg ]; then
  warn "ffmpeg missing — installing (this can take a few minutes)…"
  brew install ffmpeg
fi
ok "ffmpeg"

# 4. Hammerspoon
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  warn "Hammerspoon missing — installing…"
  brew install --cask hammerspoon
fi
ok "Hammerspoon"

# 5. Groq API key (free tier is plenty: https://console.groq.com/keys)
mkdir -p "$CONFIG_DIR"
if [ ! -s "$KEY_FILE" ]; then
  echo ""
  echo "  Lollipop needs a Groq API key. Free account, no card: https://console.groq.com/keys"
  printf '  Paste your Groq API key (input hidden): '
  read -r -s GROQ_KEY
  echo ""
  [ -n "$GROQ_KEY" ] || fail "No key entered."
  printf '%s\n' "$GROQ_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer $(tr -d '[:space:]' < "$KEY_FILE")" \
  https://api.groq.com/openai/v1/models || true)
if [ "$STATUS" = "200" ]; then
  ok "Groq key valid ($KEY_FILE)"
else
  rm -f "$KEY_FILE"
  fail "Groq API rejected the key (HTTP $STATUS). Get one at https://console.groq.com/keys and re-run."
fi

# 6. Microphone input volume — quiet input makes Whisper hallucinate (ask us about lollipops)
VOL=$(osascript -e 'input volume of (get volume settings)')
if [ "$VOL" -lt 50 ]; then
  warn "Mic input volume is $VOL/100 — too quiet for reliable transcription."
  RAISE="y"
  if [ -t 0 ]; then
    printf '  Raise it to 75 now? [Y/n] '
    read -r ANSWER
    case "$ANSWER" in n|N) RAISE="n" ;; esac
  fi
  if [ "$RAISE" = "y" ]; then
    osascript -e 'set volume input volume 75'
    ok "Mic input volume raised to 75"
  else
    warn "Left at $VOL — expect mishearings."
  fi
else
  ok "Mic input volume: $VOL/100"
fi

# 7. Install the Hammerspoon module
mkdir -p "$HS_DIR"
cp "$SCRIPT_DIR/dictation.lua" "$HS_DIR/mac-dictation.lua"
ok "Installed $HS_DIR/mac-dictation.lua"

LOADLINE='dofile(os.getenv("HOME") .. "/.hammerspoon/mac-dictation.lua") -- Lollipop: hold Fn+Shift to dictate'
if [ -f "$INIT" ] && grep -qF 'mac-dictation.lua' "$INIT"; then
  ok "init.lua already loads Lollipop"
else
  printf '%s\n' "$LOADLINE" >> "$INIT"
  ok "Loader added to $INIT"
fi

# 8. (Re)start Hammerspoon
killall Hammerspoon 2>/dev/null || true
sleep 1
open -a Hammerspoon
ok "Hammerspoon (re)started"

bold "Two permissions macOS will ask for:"
echo "  1. Accessibility — System Settings → Privacy & Security → Accessibility → enable Hammerspoon"
echo "     (without it, the Fn+Shift hotkey cannot be detected; re-run this script after enabling)"
echo "  2. Microphone — a popup appears on your FIRST dictation; accept it and retry once"
echo ""
echo "  Recommended: hammer menu-bar icon → Preferences → 'Launch Hammerspoon at login'"

bold "Test: click into any text field, hold Fn+Shift, speak, release. 🍭"
