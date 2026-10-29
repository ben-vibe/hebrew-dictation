#!/usr/bin/env bash
# Offline self-tests for the guard scripts. Never touches the real HOME, Hammerspoon,
# mic, speakers or clipboard: every case runs with a fake HOME and a stub `hs` (HS_BIN).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PCALL='pcall(require, "notetaker") -- meeting notetaker; delete this line to remove it completely'
FAKE_KEY='gsk_FAKE_SELFTEST_KEY_9f8e7d6c'

# Stub hs: answers the snapshot.sh -c commands from files in $HS_STUB_DIR.
stub_bin="$work/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/hs" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = "-c" ] || { echo "stub hs: expected -c" >&2; exit 64; }
d="${HS_STUB_DIR:?}"
if [ -f "$d/down" ]; then echo "error: can't access Hammerspoon message port" >&2; exit 69; fi
case "$2" in
  *'hs.hotkey.getHotkeys()'*) cat "$d/hotkeys" ;;
  *'type(_G[n])'*) cat "$d/globals" ;;
  *'dictationTap:isEnabled()'*) cat "$d/tap" ;;
  *) echo "stub hs: unexpected command: $2" >&2; exit 65 ;;
esac
SH
chmod +x "$stub_bin/hs"

pass=0
failed=0
ok()   { echo "ok   $1"; pass=$((pass + 1)); }
fail() { echo "FAIL $1${2:+: $2}"; failed=$((failed + 1)); }

# new_env <name>: build a fake HOME + stub state; sets H, STUB, BL.
new_env() {
  local root="$work/$1"
  H="$root/home"; STUB="$root/stub"; BL="$root/baseline dir"
  mkdir -p "$H/.hammerspoon/bin" "$H/.hammerspoon/recordings" "$H/.config" "$STUB" "$BL"
  printf -- '-- fake init.lua\nprint("dictation")\n' > "$H/.hammerspoon/init.lua"
  printf 'binary' > "$H/.hammerspoon/bin/dictation-recorder"
  printf 'swift' > "$H/.hammerspoon/bin/dictation-recorder.swift"
  printf 'sh' > "$H/.hammerspoon/bin/compare-transcribers.sh"
  printf '%s\n' "$FAKE_KEY" > "$H/.config/dictation-groq-key"
  # elevenlabs key intentionally absent -> MISSING
  touch "$H/.hammerspoon/recordings/20261029-100000.wav" "$H/.hammerspoon/recordings/20261029-100100.wav"
  # Real live output: Ctrl+Cmd+R and Ctrl+Cmd+Y under the Hebrew layout.
  printf '⌘⌃ט\n⌘⌃ר\n' > "$STUB/hotkeys"
  local g
  : > "$STUB/globals"
  for g in dictationLog:table lastRecording:string releasedAt:number startRecording:function \
           stopRecordingAndTranscribe:function startPriming:function cancelPriming:function \
           isPrimedOrRecording:function dictationTap:userdata; do
    printf '%s\t%s\n' "${g%%:*}" "${g#*:}" >> "$STUB/globals"
  done
  echo true > "$STUB/tap"
}

run_snapshot() { HOME="$H" HS_BIN="$stub_bin/hs" HS_STUB_DIR="$STUB" BASELINE_DIR="$BL" bash "$here/snapshot.sh"; }
# run_verify <snapdir>: sets VOUT and VRC.
run_verify() {
  set +e
  VOUT="$(HOME="$H" HS_BIN="$stub_bin/hs" HS_STUB_DIR="$STUB" bash "$here/verify.sh" "$1" 2>&1)"
  VRC=$?
  set -e
}
baseline() { dirname "$(run_snapshot)"; }

# --- snapshot -------------------------------------------------------------
t=snapshot_lists_all_lines
new_env "$t"
snap="$(run_snapshot)"
expected="file ~/.hammerspoon/init.lua $(shasum -a 256 "$H/.hammerspoon/init.lua" | awk '{print $1}')
file ~/.hammerspoon/bin/dictation-recorder $(shasum -a 256 "$H/.hammerspoon/bin/dictation-recorder" | awk '{print $1}')
file ~/.hammerspoon/bin/dictation-recorder.swift $(shasum -a 256 "$H/.hammerspoon/bin/dictation-recorder.swift" | awk '{print $1}')
file ~/.hammerspoon/bin/compare-transcribers.sh $(shasum -a 256 "$H/.hammerspoon/bin/compare-transcribers.sh" | awk '{print $1}')
file ~/.config/dictation-groq-key $(shasum -a 256 "$H/.config/dictation-groq-key" | awk '{print $1}')
file ~/.config/dictation-elevenlabs-key MISSING
$(printf '⌘⌃ט\n⌘⌃ר\n' | LC_ALL=C sort | sed 's/^/hotkey /')
global dictationLog table
global lastRecording string
global releasedAt number
global startRecording function
global stopRecordingAndTranscribe function
global startPriming function
global cancelPriming function
global isPrimedOrRecording function
global dictationTap userdata
tap_enabled true
info recordings_count 2
info recording 20261029-100000.wav
info recording 20261029-100100.wav"
if [ "$(cat "$snap")" = "$expected" ] && [ -f "$(dirname "$snap")/init.lua.copy" ] \
   && [[ "$snap" == "$BL"/*/snapshot.txt ]]; then ok "$t"; else
  fail "$t" "$(diff <(echo "$expected") "$snap" || true)"; fi

t=snapshot_never_contains_key_contents
new_env "$t"
snap="$(run_snapshot)"
if ! grep -rqF "$FAKE_KEY" "$(dirname "$snap")"; then ok "$t"; else fail "$t" "key value found in snapshot dir"; fi

# --- verify ---------------------------------------------------------------
t=verify_identical_passes
new_env "$t"; b="$(baseline)"; run_verify "$b"
if [ $VRC -eq 0 ] && ! grep -q '^FAIL' <<< "$VOUT"; then ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=verify_pcall_line_appended_passes
new_env "$t"; b="$(baseline)"
printf '%s\n' "$PCALL" >> "$H/.hammerspoon/init.lua"
run_verify "$b"
[ $VRC -eq 0 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_pcall_line_after_missing_newline_passes
new_env "$t"; printf 'print("no trailing newline")' > "$H/.hammerspoon/init.lua"; b="$(baseline)"
printf '\n%s' "$PCALL" >> "$H/.hammerspoon/init.lua"
run_verify "$b"
[ $VRC -eq 0 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_other_init_edit_fails
new_env "$t"; b="$(baseline)"
printf '%s\n-- extra\n' "$PCALL" >> "$H/.hammerspoon/init.lua"
run_verify "$b"
if [ $VRC -eq 1 ] && grep -q '^FAIL file ~/.hammerspoon/init.lua' <<< "$VOUT"; then ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=verify_pcall_line_twice_fails
new_env "$t"; b="$(baseline)"
printf '%s\n%s\n' "$PCALL" "$PCALL" >> "$H/.hammerspoon/init.lua"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_changed_key_fails_without_printing_key
new_env "$t"; b="$(baseline)"
NEW_KEY='gsk_FAKE_ROTATED_KEY_0a1b2c'
printf '%s\n' "$NEW_KEY" > "$H/.config/dictation-groq-key"
key_hash="$(shasum -a 256 "$H/.config/dictation-groq-key" | awk '{print $1}')"
run_verify "$b"
if [ $VRC -eq 1 ] && grep -q '^FAIL file ~/.config/dictation-groq-key' <<< "$VOUT" \
   && ! grep -qF -e "$FAKE_KEY" -e "$NEW_KEY" -e "$key_hash" <<< "$VOUT"; then ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=verify_extra_notetaker_hotkey_passes
new_env "$t"; b="$(baseline)"
printf '⌃⌥⌘M\n' >> "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 0 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_extra_hotkey_hebrew_layout_passes
new_env "$t"; b="$(baseline)"
printf '⌘⌃⌥צ\n' >> "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 0 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_other_extra_hotkey_fails
new_env "$t"; b="$(baseline)"
printf '⌘⌃ק\n' >> "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_extra_ctrl_alt_cmd_other_key_fails
new_env "$t"; b="$(baseline)"
printf '⌃⌥⌘Q\n' >> "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_extra_shift_variant_fails
new_env "$t"; b="$(baseline)"
printf '⌘⌃⇧M\n' >> "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_two_extra_notetaker_hotkeys_fail
new_env "$t"; b="$(baseline)"
printf '⌃⌥⌘M\n⌘⌃⌥צ\n' >> "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_duplicate_hotkey_fails_with_clear_message
new_env "$t"; b="$(baseline)"
printf '⌘⌃ט\n' >> "$STUB/hotkeys"
run_verify "$b"
if [ $VRC -eq 1 ] && grep -q 'duplicate binding of an existing combo: ⌘⌃ט x2' <<< "$VOUT"; then
  ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=verify_removed_hotkey_fails
new_env "$t"; b="$(baseline)"
printf '⌘⌃ט\n⌃⌥⌘M\n' > "$STUB/hotkeys"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_changed_global_fails
new_env "$t"; b="$(baseline)"
sed -i '' 's/^releasedAt	number$/releasedAt	nil/' "$STUB/globals"
run_verify "$b"
if [ $VRC -eq 1 ] && grep -q '^FAIL global releasedAt' <<< "$VOUT"; then ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=verify_tap_disabled_fails
new_env "$t"; b="$(baseline)"
echo false > "$STUB/tap"
run_verify "$b"
[ $VRC -eq 1 ] && ok "$t" || fail "$t" "rc=$VRC $VOUT"

t=verify_recordings_change_is_info_only
new_env "$t"; b="$(baseline)"
rm "$H/.hammerspoon/recordings/20261029-100000.wav"
touch "$H/.hammerspoon/recordings/20261029-110000.wav" "$H/.hammerspoon/recordings/20261029-110100.wav"
run_verify "$b"
if [ $VRC -eq 0 ] && grep -q '^INFO recordings_count 2 -> 3' <<< "$VOUT"; then ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=verify_missing_hs_exit2
new_env "$t"; b="$(baseline)"
touch "$STUB/down"
run_verify "$b"
if [ $VRC -eq 2 ] && grep -q 'Hammerspoon not reachable' <<< "$VOUT"; then ok "$t"; else fail "$t" "rc=$VRC $VOUT"; fi

t=snapshot_missing_hs_binary_exit2
new_env "$t"
set +e; out="$(HOME="$H" HS_BIN="$work/no-such-hs" BASELINE_DIR="$BL" bash "$here/snapshot.sh" 2>&1)"; rc=$?; set -e
if [ $rc -eq 2 ] && [ -z "$(ls -A "$BL")" ]; then ok "$t"; else fail "$t" "rc=$rc $out"; fi

# --- repo-no-touch --------------------------------------------------------
make_repo() {
  R="$work/$1/repo"
  mkdir -p "$R/bin" "$R/docs"
  (
    cd "$R"
    git init -q -b main
    git config user.email selftest@example.invalid
    git config user.name selftest
    echo a > dictation.lua; echo a > install.sh; echo a > LICENSE; echo a > README.md
    echo a > bin/dictation-recorder.swift; echo a > docs/x.md
    git add -A; git commit -qm base
    git checkout -qb feature
  )
}
run_rnt() { set +e; ROUT="$(cd "$R" && bash "$here/repo-no-touch.sh" main 2>&1)"; RRC=$?; set -e; }

t=repo_no_touch_flags_dictation_lua
make_repo "$t"
(cd "$R" && echo b >> dictation.lua && git commit -qam change)
run_rnt
if [ $RRC -eq 1 ] && grep -q 'dictation.lua' <<< "$ROUT"; then ok "$t"; else fail "$t" "rc=$RRC $ROUT"; fi

t=repo_no_touch_flags_bin_rename
make_repo "$t"
(cd "$R" && git mv bin/dictation-recorder.swift docs/moved.swift && git commit -qm mv)
run_rnt
if [ $RRC -eq 1 ] && grep -q 'bin/dictation-recorder.swift' <<< "$ROUT"; then ok "$t"; else fail "$t" "rc=$RRC $ROUT"; fi

t=repo_no_touch_allows_docs_and_notetaker
make_repo "$t"
(cd "$R" && mkdir -p notetaker && echo n > notetaker/install.sh && echo b >> docs/x.md \
  && echo b >> README.md && echo x > .gitignore && git add -A && git commit -qm ok)
run_rnt
[ $RRC -eq 0 ] && ok "$t" || fail "$t" "rc=$RRC $ROUT"

# --- isolation-lint -------------------------------------------------------
# lint_case <name> <expected rc> <lua source>
lint_case() {
  local d="$work/$1/lua" rc
  mkdir -p "$d"
  printf '%s\n' "$3" > "$d/mod.lua"
  set +e; LOUT="$(bash "$here/isolation-lint.sh" "$d" 2>&1)"; rc=$?; set -e
  if [ "$rc" -eq "$2" ]; then ok "$1"; else fail "$1" "rc=$rc want $2: $LOUT"; fi
}
lint_case lint_flags_foreign_global 1 '_G.releasedAt = 1'
lint_case lint_allows_G_notetaker 0 '_G.notetaker = _G.notetaker or {}
_G.notetaker.state = "idle"'
lint_case lint_flags_G_notetaker_prefix 1 '_G.notetakerX = 1'
lint_case lint_flags_G_bracket 1 'local f = _G["startRecording"]'
lint_case lint_flags_eventtap 1 'local t = hs.eventtap.new({}, function() end)'
lint_case lint_flags_ctrl_cmd_r_hotkey 1 'hs.hotkey.bind({"cmd", "ctrl"}, "R", function() end)'
lint_case lint_flags_fn_shift_hotkey 1 "hs.hotkey.bind({'fn','shift'}, 'a', function() end)"
lint_case lint_allows_ctrl_alt_cmd_m 0 'hs.hotkey.bind({"ctrl","alt","cmd"}, "m", function() end)'
lint_case lint_flags_recordings_path 1 'local d = os.getenv("HOME") .. "/.hammerspoon/recordings"'
lint_case lint_flags_recordings_word 1 'local d = "recordings"'
lint_case lint_flags_recorder_name 1 'local r = "dictation-recorder"'
lint_case lint_flags_bare_dictation_global 1 'local n = #dictationLog'
lint_case lint_flags_dictation_name_as_field 1 'local f = env.stopRecordingAndTranscribe'
lint_case lint_flags_rawget_G 1 'local f = rawget(_G, "start" .. "Recording")'
lint_case lint_flags_rawset_G 1 'rawset(_G, "x", 1)'
lint_case lint_flags_ENV 1 'local f = _ENV["x"]'
lint_case lint_flags_setfenv 1 'setfenv(1, {})'
lint_case lint_flags_getfenv 1 'local e = getfenv(1)'
lint_case lint_flags_G_local_alias 1 'local g = _G'
lint_case lint_flags_G_space_dot 1 'local x = _G .releasedAt'
lint_case lint_allows_dictation_prefix_word 0 'local myDictationLogger = 1'

# lint_file_case <name> <expected rc> <relative path> <source>
lint_file_case() {
  local d="$work/$1/scan" rc
  mkdir -p "$(dirname "$d/$3")"
  printf '%s\n' "$4" > "$d/$3"
  set +e; LOUT="$(bash "$here/isolation-lint.sh" "$d" 2>&1)"; rc=$?; set -e
  if [ "$rc" -eq "$2" ]; then ok "$1"; else fail "$1" "rc=$rc want $2: $LOUT"; fi
}
lint_file_case lint_sh_flags_dictation_wav 1 mac/run.sh 'rm -f /tmp/hs-dictation.wav'
lint_file_case lint_swift_flags_recordings 1 mac/Rec.swift 'let d = "recordings"'
lint_file_case lint_ts_flags_recorder 1 worker/src/x.ts 'const r = "dictation-recorder";'
lint_file_case lint_js_flags_groq_key 1 dash/app.js 'fetch("dictation-groq-key")'
lint_file_case lint_sh_flags_groq_key_outside_installer 1 notetaker/mac/setup.sh 'cat ~/.config/dictation-groq-key'
lint_file_case lint_allows_groq_key_in_notetaker_install 0 notetaker/install.sh 'KEY_FILE="$HOME/.config/dictation-groq-key"'
lint_file_case lint_installer_still_flags_recorder 1 notetaker/install.sh 'cp dictation-recorder /tmp'
lint_file_case lint_skips_guard_scripts 0 notetaker/tests/guard/x.sh 'echo dictation-recorder recordings'

# --- dictation-smoke pure helper -------------------------------------------
t=smoke_helper_self_test
set +e; sout="$(bash "$here/dictation-smoke.sh" --helper-self-test 2>&1)"; rc=$?; set -e
if [ $rc -eq 0 ] && ! grep -q '^FAIL' <<< "$sout"; then ok "$t"; else fail "$t" "rc=$rc $sout"; fi


# --- guided dictation smoke with stubs ------------------------------------------------
# A STATEFUL hs stub simulates Ben dictating. Every log poll prints the current log (last 40)
# and then appends the next scenario step ($GS/steps/<n>, one file per poll), so the log grows
# over successive polls. "!lastrec <path>" sets _G.lastRecording. The stub uses shell builtins
# where it can: process spawns, not sleeps, dominate the suite's run time. Every hs and
# osascript call is logged. Forbidden binaries on PATH record any use. Fake HOME throughout:
# nothing here reaches the real Hammerspoon, mic, speakers, TextEdit or clipboard.
g_bin="$work/guided-bin"; g_forbid="$work/guided-forbid"; g_forbid_log="$work/forbidden-calls"
mkdir -p "$g_bin" "$g_forbid"
: > "$g_forbid_log"
for b in hs osascript say afplay; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit 99\n' "$b" "$g_forbid_log" > "$g_forbid/$b"
done
cat > "$g_bin/hs" <<'SH'
#!/usr/bin/env bash
d="${GUIDED_STUB_DIR:?}"
[ "${1:-}" = "-c" ] || { echo "stub hs: expected -c" >&2; exit 64; }
printf '%s\n' "${2//$'\n'/\\n}" >> "$d/hs_calls"
case "$2" in
  *'#_G.dictationLog'*)
    [ -f "$d/hang" ] && exec sleep 30
    tail -n 40 "$d/dictlog"
    read -r n < "$d/step"; echo $((n + 1)) > "$d/step"
    [ -f "$d/steps/$n" ] || exit 0
    read -r c < "$d/count"
    while IFS= read -r line; do
      case "$line" in
        '!lastrec '*) printf '%s\n' "${line#!lastrec }" > "$d/lastrec" ;;
        *) c=$((c + 1)); printf '10:%02d:%02d %s\n' $((c / 60)) $((c % 60)) "$line" >> "$d/dictlog" ;;
      esac
    done < "$d/steps/$n"
    echo "$c" > "$d/count" ;;
  *'type(_G.dictationLog)'*) read -r v < "$d/logtype"; echo "$v" ;;
  *'isPrimedOrRecording'*) read -r v < "$d/busy"; echo "$v" ;;
  *'_G.lastRecording'*) read -r v < "$d/lastrec"; echo "$v" ;;
  *) echo "stub hs: unexpected command: $2" >&2; exit 65 ;;
esac
SH
cat > "$g_bin/osascript" <<'SH'
#!/usr/bin/env bash
# Logs one line per call: the joined script, then DOC=<first argv item after the script>.
d="${GUIDED_STUB_DIR:?}"; script=""; doc=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-e" ]; then script="$script | $2"; shift 2; else doc="$1"; shift; break; fi
done
printf 'SCRIPT%s\tDOC=%s\tTEXT=%s\n' "$script" "$doc" "${1//$'\n'/\\n}" >> "$d/osa_calls"
case "$script" in *'make new document'*) echo "Untitled 7" ;; esac
exit 0
SH
cat > "$g_bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
# cp that copies faithfully, then corrupts one byte of the copy (never the source).
cat > "$g_bin/cp-corrupt" <<'SH'
#!/usr/bin/env bash
/bin/cp "$@" || exit $?
dest="${@: -1}"
f="$(find "$dest" -type f | sort | head -n 1)"
printf 'X' >> "$f"
SH
chmod +x "$g_bin"/* "$g_forbid"/*

G1="הבאג בצ׳קאאוט תוקן לפני הדיפלוי לפרודקשן"
G2="צריך לעשות מרג׳ לברנץ׳ ולהריץ את הטסטים"
G3="שלחתי פול ריקווסט עם הריפקטור של הקומפוננטה"
G_START="start() - combo completed, isRecording=true"

# g_wavs <dir>: tone (-20 dBFS), silent and mostly silent (short burst) 16-bit WAVs.
g_wavs() {
  python3 -I - "$1" <<'PY'
import math, os, sys, wave
from array import array
def write(name, samples):
    with wave.open(os.path.join(sys.argv[1], name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(array("h", samples).tobytes())
def tone(sec):
    amp = 32768 * 0.1 * math.sqrt(2)
    return [int(amp * math.sin(2 * math.pi * 1000 * i / 16000)) for i in range(int(sec * 16000))]
write("tone.wav", tone(3))
write("silent.wav", [0] * 48000)
write("burst.wav", [0] * 160000 + tone(0.5))
PY
}
g_wavs_dir="$work/guided-wavs"; mkdir -p "$g_wavs_dir"; g_wavs "$g_wavs_dir"

# g_env <name>: fake HOME with 3 recordings, fresh stub state. Sets GS, GH, GBL.
g_env() {
  GS="$work/$1/stub"; GH="$work/$1/home"; GBL="$work/$1/baseline dir"
  mkdir -p "$GS/wavs" "$GS/steps" "$GH/.hammerspoon/recordings"
  : > "$GS/dictlog"; : > "$GS/hs_calls"; : > "$GS/osa_calls"
  echo 0 > "$GS/step"; echo 0 > "$GS/count"; G_STEPS=0; echo table > "$GS/logtype"; echo "false false" > "$GS/busy"; echo nil > "$GS/lastrec"
  local i
  for i in 1 2 3; do printf 'personal recording %s' "$i" > "$GH/.hammerspoon/recordings/2026102$i-100000.wav"; done
  G_CP=cp; G_HS_TIMEOUT=2; G_ATTEMPT_TIMEOUT=""; G_N=0
}
g_reset_stub() { : > "$GS/dictlog"; echo 0 > "$GS/step"; echo 0 > "$GS/count"; echo nil > "$GS/lastrec"; }
g_rec_sha() { (cd "$GH/.hammerspoon/recordings" && find . -type f | LC_ALL=C sort | xargs shasum -a 256); }
g_cmd() {
  printf '%s\0' env HOME="$GH" PATH="$g_forbid:$PATH" HS_BIN="$g_bin/hs" OSASCRIPT_BIN="$g_bin/osascript" \
    PGREP_BIN="$g_bin/pgrep" CP_BIN="$G_CP" GUIDED_STUB_DIR="$GS" BASELINE_DIR="$GBL" \
    SMOKE_HS_TIMEOUT_S="$G_HS_TIMEOUT" SMOKE_POLL_INTERVAL_S=0.05 SMOKE_LEVEL_WAIT_S=0.5 \
    SMOKE_ATTEMPT_TIMEOUT_S="$G_ATTEMPT_TIMEOUT" bash "$here/dictation-smoke.sh" "$@"
}
# g_run <args...>: sets GOUT and GRC.
g_run() {
  local cmd=()
  while IFS= read -r -d '' a; do cmd+=("$a"); done < <(g_cmd "$@")
  set +e; GOUT="$("${cmd[@]}" 2>&1)"; GRC=$?; set -e
}

# Scenario builders: one attempt each, ending with an empty step so the poll that sees the
# outcome does not consume the next attempt's first step.
g_step() {  # g_step [line...]: the next poll's log lines (none = a quiet poll)
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$GS/steps/$G_STEPS"; else : > "$GS/steps/$G_STEPS"; fi
  G_STEPS=$((G_STEPS + 1))
}
g_dict() {  # g_dict <text> [wav=tone] [audio_s=6.10] [latency=0.70]
  G_N=$((G_N + 1))
  local wav="$GS/wavs/a$G_N.wav"
  cp "$g_wavs_dir/${2:-tone}.wav" "$wav"
  g_step "priming: opening mic on first modifier key" "$G_START" "mic READY - audio is now flowing"
  g_step "stop() heldFor=${3:-6.10}" "recorder exited code=0" "sending ${3:-6.10}s of audio (195244 bytes)" "!lastrec $wav"
  g_step "curl exited code=0" "TEXT (${4:-0.70}s from release to paste): $1"
  g_step
}
g_short() { g_step "$G_START"; g_step "stop() heldFor=0.20" "held only 0.20s, ignoring"; g_step; }
g_fail() {  # g_fail <lines after the upload...>
  g_step "$G_START"; g_step "stop() heldFor=5.00" "sending 5.00s of audio (160044 bytes)"; g_step "$@"; g_step
}
# g_json <results.json> <python assertion expr over r>
g_json() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }
g_one() { ls "$GBL"/$1/results.json 2>/dev/null | head -n 1; }
g_stat() { printf 'rc=%s\n%s\n' "$GRC" "$GOUT" | tail -n 40; }

t=guided_valid_run_saves_baseline
g_env "$t"; g_dict "$G1"; g_dict "$G2" tone 6.10 0.80; g_dict "$G3" tone 6.10 0.60
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
res="$(ls "$GBL"/2*/results.json 2>/dev/null | head -n 1)"
if [ $GRC -eq 0 ] && [ -n "$res" ] && grep -q 'saved baseline:' <<< "$GOUT" \
   && g_json "$res" 'r["valid"] and r["attempts_used"]==3 and r["summary"]["median_latency_s"]==0.7 and all(s["status"]=="valid" and s["cer"]==0 and abs(s["mean_db"]+20)<0.2 and s["active_ratio"]==1.0 for s in r["sentences"]) and r["recordings"]["before"]==3' \
   && [ "$(find "$GBL"/recordings-backup-* -type f | wc -l | tr -d ' ')" = 3 ] \
   && grep -q 'up to 3 of the oldest will rotate out' <<< "$GOUT" \
   && grep -q '== Dictation state at the end' <<< "$GOUT"; then
  g_reset_stub
  g_run --accept-rotation 3 --baseline "$res" --attempt-timeout 10
  if [ $GRC -eq 0 ] && grep -q 'RESULT: PASS' "$GBL"/compare-*/decision.txt; then
    printf '{"valid": true, "summary": {"median_latency_s": 0.3}}' > "$work/$t/fast-baseline.json"
    g_reset_stub; rm -rf "$GBL"/compare-*
    g_run --accept-rotation 3 --baseline "$work/$t/fast-baseline.json" --attempt-timeout 10
    if [ $GRC -eq 1 ] && grep -q 'FAIL median latency' "$GBL"/compare-*/decision.txt; then ok "$t"
    else fail "$t" "latency regression not caught: $(g_stat)"; fi
  else fail "$t" "compare: $(g_stat)"; fi
else fail "$t" "save: $(g_stat)"; fi

t=guided_silent_attempt_retried_then_valid
g_env "$t"; g_dict "$G1" burst; g_dict "$G1"; g_dict "$G2"; g_dict "$G3"
g_run --accept-rotation 4 --save-baseline --attempt-timeout 10
res="$(ls "$GBL"/2*/results.json 2>/dev/null | head -n 1)"
if [ $GRC -eq 0 ] && [ -n "$res" ] \
   && g_json "$res" 'r["valid"] and [a["status"] for a in r["sentences"][0]["attempts"]]==["invalid_silent","valid"] and r["sentences"][0]["attempts"][0]["active_ratio"]<0.15' \
   && grep -q 'Previous attempt was too quiet — please try again, closer to the mic' "$GS/osa_calls"; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_hallucination_low_level_is_invalid_not_accuracy_fail
g_env "$t"; g_dict "תודה" silent; g_dict "$G1"; g_dict "$G2"; g_dict "$G3"
g_run --accept-rotation 4 --save-baseline --attempt-timeout 10
res="$(ls "$GBL"/2*/results.json 2>/dev/null | head -n 1)"
if [ $GRC -eq 0 ] && [ -n "$res" ] \
   && g_json "$res" 'r["sentences"][0]["attempts"][0]["status"]=="invalid_silent" and r["sentences"][0]["attempts"][0]["mean_db"]<=-100 and r["summary"]["accuracy_failures"]==[] and r["sentences"][0]["status"]=="valid"'; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_accuracy_fail_is_valid_and_reported
g_env "$t"; g_dict "$G1"; g_dict "משהו אחר לגמרי שלא נאמר בכלל"; g_dict "$G3"
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
res="$(ls "$GBL"/2*/results.json 2>/dev/null | head -n 1)"
if [ $GRC -eq 0 ] && [ -n "$res" ] \
   && g_json "$res" 'r["valid"] and r["attempts_used"]==3 and r["sentences"][1]["status"]=="accuracy_fail" and len(r["sentences"][1]["attempts"])==1 and r["summary"]["accuracy_failures"]==[2] and r["summary"]["invalid"]==[] and r["summary"]["max_cer"]>0.15' \
   && grep -q 'failures (CER > 0.15): \[2\]' <<< "$GOUT"; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_short_hold_invalid_short
g_env "$t"; g_short; g_dict "$G1" tone 1.00; g_dict "$G1"; g_dict "$G2"; g_dict "$G3"
g_run --accept-rotation 5 --save-baseline --attempt-timeout 10
res="$(ls "$GBL"/2*/results.json 2>/dev/null | head -n 1)"
if [ $GRC -eq 0 ] && [ -n "$res" ] \
   && g_json "$res" '[a["status"] for a in r["sentences"][0]["attempts"]]==["invalid_short","invalid_short","valid"]' \
   && grep -q 'Previous attempt was too short' "$GS/osa_calls"; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_timeout_no_dictation
g_env "$t"; G_ATTEMPT_TIMEOUT=0.5
g_run --accept-rotation 3 --save-baseline --attempt-timeout 1
res="$(g_one 'invalid-*')"
if [ $GRC -eq 1 ] && [ -n "$res" ] && ! ls -d "$GBL"/2* >/dev/null 2>&1 \
   && g_json "$res" 'not r["valid"] and [a["status"] for a in r["sentences"][0]["attempts"]]==["no_dictation_timeout"]*3 and [s["status"] for s in r["sentences"][1:]]==["not_run","not_run"]' \
   && grep -q 'No dictation was detected' "$GS/osa_calls"; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_groq_error_classified
g_env "$t"
g_fail "curl exited code=6" "curl stderr:\\ncould not resolve host"; g_dict "$G1"
g_fail "curl exited code=0" 'Groq auth error: {"error":{"code":"invalid_api_key"}}'; g_dict "$G2"
g_fail "ERROR: no Groq API key at /fake/key"; g_fail "could not parse response: <html>"
g_run --accept-rotation 6 --save-baseline --attempt-timeout 10
res="$(g_one 'invalid-*')"
if [ $GRC -eq 1 ] && [ -n "$res" ] \
   && g_json "$res" '[[a["status"] for a in s["attempts"]] for s in r["sentences"]]==[["error_transcription_service","valid"],["error_transcription_service","valid"],["error_transcription_service","error_transcription_service"]] and r["sentences"][2]["status"]=="error_transcription_service" and r["attempts_used"]==6' \
   && grep -q 'NOT saved as baseline: sentence 3: error_transcription_service' <<< "$GOUT"; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_rotation_budget_stops_and_not_saved
g_env "$t"; g_dict "$G1" silent; g_dict "$G1" silent; g_dict "$G1"; g_dict "$G2"; g_dict "$G3"
g_run --accept-rotation 2 --save-baseline --attempt-timeout 10
res="$(g_one 'invalid-*')"
if [ $GRC -eq 1 ] && [ -n "$res" ] && ! ls -d "$GBL"/2* >/dev/null 2>&1 \
   && g_json "$res" 'r["attempts_used"]==2 and not r["valid"] and [s["status"] for s in r["sentences"]]==["invalid_silent","not_run","not_run"]' \
   && grep -q 'NOT saved as baseline: rotation budget used up (2 attempts)' <<< "$GOUT" \
   && [ "$(grep -c 'from release to paste' "$GS/dictlog")" = 2 ]; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_refuses_without_accept_rotation
g_env "$t"; g_dict "$G1"
ok_all=1
for args in "--save-baseline" "--save-baseline --accept-rotation 0" "--save-baseline --accept-rotation 13" \
            "--save-baseline --accept-rotation x" "--accept-rotation 3"; do
  # shellcheck disable=SC2086
  g_run $args
  if [ $GRC -ne 2 ]; then ok_all=0; fi
done
if [ $ok_all -eq 1 ] && [ -z "$(ls -A "$GBL" 2>/dev/null)" ] && [ ! -s "$GS/hs_calls" ] && [ ! -s "$GS/osa_calls" ]; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_refuses_when_dictation_busy
g_env "$t"; g_dict "$G1"; echo "false true" > "$GS/busy"
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
if [ $GRC -eq 2 ] && grep -q 'dictation is not idle' <<< "$GOUT" && [ -z "$(ls -A "$GBL" 2>/dev/null)" ] \
   && ! grep -q '#_G.dictationLog' "$GS/hs_calls" && [ ! -s "$GS/osa_calls" ]; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_backup_checksum_mismatch_aborts
g_env "$t"; g_dict "$G1"; G_CP="$g_bin/cp-corrupt"; before="$(g_rec_sha)"
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
if [ $GRC -eq 3 ] && grep -q 'checksum mismatch' <<< "$GOUT" && ! grep -q '#_G.dictationLog' "$GS/hs_calls" \
   && [ ! -s "$GS/osa_calls" ] && [ "$(g_rec_sha)" = "$before" ]; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_backup_copy_failure_aborts
g_env "$t"; g_dict "$G1"; mkdir -p "$GBL"; chmod 500 "$GBL"
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
chmod 700 "$GBL"
if [ $GRC -eq 3 ] && ! grep -q '#_G.dictationLog' "$GS/hs_calls" && [ ! -s "$GS/osa_calls" ]; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_hs_timeout_handled
g_env "$t"; g_dict "$G1"; touch "$GS/hang"; G_HS_TIMEOUT=0.5
start_s=$(date +%s)
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
elapsed=$(( $(date +%s) - start_s ))
res="$(g_one 'invalid-*')"
if [ $GRC -eq 1 ] && [ $elapsed -lt 10 ] && [ -n "$res" ] \
   && g_json "$res" '[a["status"] for a in r["sentences"][0]["attempts"]]==["error_hs_timeout"]*2 and [s["status"] for s in r["sentences"][1:]]==["not_run","not_run"]' \
   && grep -q 'Hammerspoon did not respond; stopped' <<< "$GOUT"; then ok "$t"
else fail "$t" "elapsed=${elapsed}s $(g_stat)"; fi

t=guided_never_calls_dictation_functions
g_env "$t"; g_short; g_dict "$G1"; g_dict "$G2" silent; g_dict "$G2"; g_dict "$G3"
g_run --accept-rotation 5 --save-baseline --attempt-timeout 10
if [ $GRC -eq 0 ] && [ -s "$GS/hs_calls" ] \
   && ! grep -qE 'startRecording|stopRecording|Priming|eventtap|dictationTap|releasedAt|=' <(sed 's/[a-z]=#_G\.dictationLog//; s/i=math\.max//; s/local p, r = //' "$GS/hs_calls") \
   && [ "$(sort -u "$GS/hs_calls" | wc -l | tr -d ' ')" = 4 ]; then ok "$t"
else fail "$t" "calls: $(sort -u "$GS/hs_calls") $(g_stat)"; fi

t=guided_never_modifies_recordings
g_env "$t"; g_dict "$G1"; g_dict "$G2"; g_dict "$G3"; before="$(g_rec_sha)"
g_run --accept-rotation 3 --save-baseline --attempt-timeout 10
bk="$(ls -d "$GBL"/recordings-backup-* | head -n 1)"
if [ $GRC -eq 0 ] && [ "$(g_rec_sha)" = "$before" ] \
   && [ "$(cd "$bk" && find . -type f | LC_ALL=C sort | xargs shasum -a 256)" = "$before" ]; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_only_new_textedit_document_touched
g_env "$t"; g_dict "$G1" silent; g_dict "$G1"; g_dict "$G2"; g_dict "$G3"
g_run --accept-rotation 4 --save-baseline --attempt-timeout 10
others="$(grep -v 'make new document' "$GS/osa_calls" || true)"
# AppleScript code only: the SCRIPT field with quoted strings removed.
code="$(cut -f1 "$GS/osa_calls" | sed 's/"[^"]*"//g')"
if [ $GRC -eq 0 ] && [ "$(grep -c 'make new document' "$GS/osa_calls")" = 1 ] \
   && [ "$(wc -l <<< "$others" | tr -d ' ')" = 5 ] \
   && ! grep -qv $'\tDOC=Untitled 7\t' <<< "$others" \
   && [ "$(grep -v 'make new document' <<< "$code" | grep -oE 'documents?( [^ |)]+)?' | sort -u)" = "document docName" ] \
   && ! grep -qiE 'close|save|delete|quit|front|window 1|every' <<< "$code" \
   && grep -q 'TEXT=Sentence 1 of 3 — click here, then hold fn+Shift, read the sentence below, release:' "$GS/osa_calls" \
   && grep -q 'TEXT=Smoke test finished: 3 of 3 sentences valid' "$GS/osa_calls"; then ok "$t"
else fail "$t" "$(cat "$GS/osa_calls") $(g_stat)"; fi

t=guided_interrupt_writes_partial_invalid
g_env "$t"; g_dict "$G1"
cmd=(); while IFS= read -r -d '' a; do cmd+=("$a"); done < <(g_cmd --accept-rotation 3 --save-baseline --attempt-timeout 30)
"${cmd[@]}" > "$work/$t/out" 2>&1 &
pid=$!
for _ in $(seq 1 600); do grep -q 'Sentence 2 of 3' "$GS/osa_calls" 2>/dev/null && break; sleep 0.1; done
sleep 0.3
kill -TERM "$pid" 2>/dev/null || true
set +e; wait "$pid"; GRC=$?; set -e
GOUT="$(cat "$work/$t/out")"
res="$(g_one 'invalid-*')"
if [ $GRC -eq 143 ] && [ -n "$res" ] && ! ls -d "$GBL"/2* >/dev/null 2>&1 \
   && g_json "$res" 'r["interrupted"] and not r["valid"] and r["sentences"][0]["status"]=="valid" and r["sentences"][1]["status"]=="not_run" and "interrupted" in r["invalid_reasons"]' \
   && grep -q '== Dictation state at the end' <<< "$GOUT" \
   && grep -q 'TEXT=Smoke test interrupted' "$GS/osa_calls"; then ok "$t"
else fail "$t" "$(g_stat)"; fi

t=guided_no_forbidden_binaries_used
if [ ! -s "$g_forbid_log" ]; then ok "$t"; else fail "$t" "$(cat "$g_forbid_log")"; fi

echo "selftest: $pass ok, $failed failed"
[ "$failed" -eq 0 ]
