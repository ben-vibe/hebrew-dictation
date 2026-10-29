#!/usr/bin/env bash
# Snapshot the live dictation install: protected file hashes, hotkeys, dictation globals,
# tap state, and (informational) the recordings listing.
# Writes "$BASELINE_DIR/<UTC-ts>/snapshot.txt" (+ init.lua.copy) and prints the snapshot path.
# Key files are hashed only; their contents are never printed or copied.
set -euo pipefail

HS_BIN="${HS_BIN:-hs}"
BASELINE_DIR="${BASELINE_DIR:-$HOME/Library/Application Support/meeting-notes/baseline}"

PROTECTED_FILES=(
  ".hammerspoon/init.lua"
  ".hammerspoon/bin/dictation-recorder"
  ".hammerspoon/bin/dictation-recorder.swift"
  ".hammerspoon/bin/compare-transcribers.sh"
  ".config/dictation-groq-key"
  ".config/dictation-elevenlabs-key"
)
GLOBALS="dictationLog lastRecording releasedAt startRecording stopRecordingAndTranscribe startPriming cancelPriming isPrimedOrRecording dictationTap"

CMD_HOTKEYS='for _,h in ipairs(hs.hotkey.getHotkeys()) do print(h.idx) end'
lua_names=$(printf '"%s",' $GLOBALS)
CMD_GLOBALS="for _,n in ipairs({${lua_names%,}}) do print(n, type(_G[n])) end"
CMD_TAP='print(tostring(_G.dictationTap ~= nil and _G.dictationTap:isEnabled()))'

hs_query() {
  local out
  if ! out=$("$HS_BIN" -c "$1" 2>/dev/null); then
    echo "Hammerspoon not reachable: is it running and is hs.ipc loaded? (HS_BIN=$HS_BIN)" >&2
    exit 2
  fi
  printf '%s\n' "$out" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

# Query Hammerspoon first so nothing is written when it is unreachable.
hotkeys=$(hs_query "$CMD_HOTKEYS")
globals=$(hs_query "$CMD_GLOBALS")
tap=$(hs_query "$CMD_TAP" | tail -n 1)

ts=$(date -u +%Y%m%dT%H%M%SZ)
out_dir="$BASELINE_DIR/$ts"
n=1
while [ -e "$out_dir" ]; do out_dir="$BASELINE_DIR/$ts-$n"; n=$((n + 1)); done
mkdir -p "$out_dir"
snap="$out_dir/snapshot.txt"

{
  for rel in "${PROTECTED_FILES[@]}"; do
    f="$HOME/$rel"
    if [ -f "$f" ]; then
      printf 'file ~/%s %s\n' "$rel" "$(shasum -a 256 "$f" | awk '{print $1}')"
    else
      printf 'file ~/%s MISSING\n' "$rel"
    fi
  done

  if [ -n "$hotkeys" ]; then
    printf '%s\n' "$hotkeys" | LC_ALL=C sort | sed 's/^/hotkey /'
  fi

  # Real hs prints "name<TAB>type"; keep only the names we asked for.
  for name in $GLOBALS; do
    t=$(printf '%s\n' "$globals" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')
    printf 'global %s %s\n' "$name" "${t:-unknown}"
  done

  printf 'tap_enabled %s\n' "$tap"

  rec_dir="$HOME/.hammerspoon/recordings"
  count=0
  recs=""
  if [ -d "$rec_dir" ]; then
    recs=$(find "$rec_dir" -maxdepth 1 -type f -name '*.wav' -exec basename {} \; | LC_ALL=C sort)
    [ -n "$recs" ] && count=$(printf '%s\n' "$recs" | wc -l | tr -d ' ')
  fi
  printf 'info recordings_count %s\n' "$count"
  if [ -n "$recs" ]; then printf '%s\n' "$recs" | sed 's/^/info recording /'; fi
} > "$snap"

if [ -f "$HOME/.hammerspoon/init.lua" ]; then
  cp -p "$HOME/.hammerspoon/init.lua" "$out_dir/init.lua.copy"
fi

echo "$snap"
