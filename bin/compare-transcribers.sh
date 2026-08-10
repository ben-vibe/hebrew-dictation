#!/bin/bash
# Replay one real recording through every transcription option, to settle "which is actually
# better" with evidence instead of impressions. Usage: compare-transcribers.sh [file.wav]
# With no argument, uses the most recent archived dictation.
set -uo pipefail
WAV="${1:-$(ls -1t "$HOME/.hammerspoon/recordings"/*.wav 2>/dev/null | head -1)}"
[ -f "$WAV" ] || { echo "no recording found"; exit 1; }

GROQ_KEY=$(cat "$HOME/.config/dictation-groq-key" 2>/dev/null)
EL_KEY=$(cat "$HOME/.config/dictation-elevenlabs-key" 2>/dev/null)
GLOSS=$(python3 -c "
import re, os, glob
home = os.path.expanduser('~')
text = ''
for cand in [home+'/.hammerspoon/dictation.lua', home+'/.hammerspoon/init.lua']:
    try: text = open(cand).read()
    except OSError: continue
    m = re.search(r'local VOCAB_PROMPT = (.*?)\nlocal REC_FILE', text, re.S)
    if m:
        print(''.join(re.findall(r'\"(.*?)\"', m.group(1)))); break
else:
    print('')")

dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WAV" 2>/dev/null)
lvl=$(ffmpeg -i "$WAV" -af volumedetect -f null - 2>&1 | grep mean_volume | grep -oE '\-[0-9.]+ dB')
echo "file: $(basename "$WAV")   duration: ${dur}s   level: $lvl"
echo "────────────────────────────────────────────────"

groq () { # $1=model  $2=prompt-or-empty
  local args=(-s -X POST https://api.groq.com/openai/v1/audio/transcriptions
    -H "Authorization: Bearer $GROQ_KEY" -F "file=@$WAV" -F "model=$1"
    -F language=he -F response_format=json)
  [ -n "$2" ] && args+=(-F "prompt=$2")
  curl "${args[@]}" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("text","").strip())
except Exception as e: print("ERR", e)'
}

printf "%-26s %s\n" "groq v3 + מילון:"   "$(groq whisper-large-v3 "$GLOSS")"
printf "%-26s %s\n" "groq v3 בלי מילון:" "$(groq whisper-large-v3 "")"
printf "%-26s %s\n" "groq turbo:"        "$(groq whisper-large-v3-turbo "")"

if [ -n "$EL_KEY" ]; then
  el=$(curl -s -X POST https://api.elevenlabs.io/v1/speech-to-text \
    -H "xi-api-key: $EL_KEY" -F "file=@$WAV" -F model_id=scribe_v1 -F language_code=heb \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("text","").strip())
except Exception as e: print("ERR", e)')
  printf "%-26s %s\n" "elevenlabs scribe:" "$el"
fi
