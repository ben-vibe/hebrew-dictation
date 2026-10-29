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

# --- dictation-smoke flow with stubs ----------------------------------------
# Stub hs, say and osascript on PATH; every call is appended to $SM/calls.
# Nothing here reaches the real Hammerspoon, mic, speakers, TextEdit or clipboard.
smoke_bin="$work/smoke-bin"
mkdir -p "$smoke_bin"
cat > "$smoke_bin/hs" <<'SH'
#!/usr/bin/env bash
d="${SMOKE_STUB_DIR:?}"
case "$2" in
  'return type(_G.startRecording)') echo function ;;
  *'_G.dictationLog'*) cat "$d/dictlog" 2>/dev/null || true ;;
  '_G.startRecording()')
    echo start >> "$d/calls"
    n=$(grep -c . "$d/calls")
    echo "10:00:$n mic READY - audio is now flowing" >> "$d/dictlog" ;;
  '_G.stopRecordingAndTranscribe()')
    echo stop >> "$d/calls"
    n=$(grep -c '^stop$' "$d/calls")
    printf '10:01:%s TEXT (1.%s0s from release to paste): %s\n' "$n" "$n" \
      "$(sed -n "${n}p" "$d/sentences")" >> "$d/dictlog" ;;
  *) echo "stub hs: unexpected command: $2" >&2; exit 65 ;;
esac
SH
cat > "$smoke_bin/say" <<'SH'
#!/usr/bin/env bash
d="${SMOKE_STUB_DIR:?}"
if [ "${2:-}" = "?" ]; then echo "Carmit              he_IL    # שלום"; exit 0; fi
echo say >> "$d/calls"
[ -f "$d/say_fail" ] && exit 1
[ -f "$d/say_int" ] && kill -INT "$PPID"
exit 0
SH
cat > "$smoke_bin/osascript" <<'SH'
#!/usr/bin/env bash
echo "osascript $*" >> "${SMOKE_STUB_DIR:?}/calls"
SH
chmod +x "$smoke_bin"/*

# smoke_env <name>: sets SM (stub state) and SH_HOME (fake HOME with 2 recordings).
smoke_env() {
  SM="$work/$1/stub"; SH_HOME="$work/$1/home"; SBL="$work/$1/baseline dir"
  mkdir -p "$SM" "$SH_HOME/.hammerspoon/recordings"
  : > "$SM/calls"
  touch "$SH_HOME/.hammerspoon/recordings/a.wav" "$SH_HOME/.hammerspoon/recordings/b.wav"
  printf '%s\n' "הבאג בצ׳קאאוט תוקן לפני הדיפלוי לפרודקשן" \
    "צריך לעשות מרג׳ לברנץ׳ ולהריץ את הטסטים" "שלחתי פול ריקווסט עם הריפקטור של הקומפוננטה" \
    > "$SM/sentences"
}
run_smoke() {
  set +e
  SOUT="$(HOME="$SH_HOME" PATH="$smoke_bin:$PATH" HS_BIN="$smoke_bin/hs" SMOKE_STUB_DIR="$SM" \
    BASELINE_DIR="$SBL" bash "$here/dictation-smoke.sh" "$@" 2>&1)"
  SRC=$?
  set -e
}
count_calls() { grep -c "^$1\$" "$SM/calls" || true; }

t=smoke_stub_save_and_compare_baseline
smoke_env "$t"
run_smoke --save-baseline
saved="$(tail -n 1 <<< "$SOUT")"
if [ $SRC -eq 0 ] && [ -f "$saved" ] && [ "$(count_calls start)" = 3 ] && [ "$(count_calls stop)" = 3 ] \
   && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert all(s["cer"]==0 for s in r["sentences"]); assert r["median_latency_s"]==1.2' "$saved" \
   && [ "$(find "$SBL"/recordings-backup-* -type f | wc -l | tr -d ' ')" = 2 ]; then
  : > "$SM/calls"; : > "$SM/dictlog"  # fresh stub state for the second run
  run_smoke --baseline "$saved"
  if [ $SRC -eq 0 ] && ls "$SBL"/compare-*/results.json >/dev/null 2>&1 \
     && grep -q 'RESULT: PASS' "$SBL"/compare-*/decision.txt; then ok "$t"; else fail "$t" "compare rc=$SRC $SOUT"; fi
else
  fail "$t" "save rc=$SRC $SOUT"
fi

t=smoke_failing_say_still_stops_recording
smoke_env "$t"; touch "$SM/say_fail"
run_smoke
if [ $SRC -ne 0 ] && [ "$(count_calls start)" = 1 ] && [ "$(count_calls stop)" = 1 ] \
   && [ "$(tail -n 2 "$SM/calls" | head -n 1)" = "osascript -e tell application \"TextEdit\" to activate" ] \
   && [ "$(tail -n 1 "$SM/calls")" = stop ]; then ok "$t"; else fail "$t" "rc=$SRC calls=$(tr '\n' '|' < "$SM/calls") $SOUT"; fi

t=smoke_interrupt_still_stops_recording
smoke_env "$t"; touch "$SM/say_int"
run_smoke
if [ $SRC -eq 130 ] && [ "$(count_calls start)" = 1 ] && [ "$(count_calls stop)" = 1 ] \
   && [ "$(tail -n 1 "$SM/calls")" = stop ]; then ok "$t"; else fail "$t" "rc=$SRC calls=$(tr '\n' '|' < "$SM/calls") $SOUT"; fi

t=smoke_backup_failure_aborts_before_dictation
smoke_env "$t"; mkdir -p "$SBL"; chmod 500 "$SBL"
run_smoke
chmod 700 "$SBL"
if [ $SRC -eq 3 ] && [ "$(count_calls start)" = 0 ]; then ok "$t"; else fail "$t" "rc=$SRC $SOUT"; fi

echo "selftest: $pass ok, $failed failed"
[ "$failed" -eq 0 ]
