#!/usr/bin/env bash
# LIVE dictation smoke test. Uses the mic, speakers, TextEdit and the clipboard, so it is run
# only with Ben present and never from run-all.sh.
# Usage: dictation-smoke.sh [--save-baseline | --baseline <results.json>]
#        dictation-smoke.sh --helper-self-test     (offline: pure helper tests only)
# Exit: 0 PASS, 1 FAIL, 2 precondition missing, 3 recordings backup failed.
set -euo pipefail

HS_BIN="${HS_BIN:-hs}"
BASELINE_DIR="${BASELINE_DIR:-$HOME/Library/Application Support/meeting-notes/baseline}"

SENTENCES=(
  "הבאג בצ׳קאאוט תוקן לפני הדיפלוי לפרודקשן"
  "צריך לעשות מרג׳ לברנץ׳ ולהריץ את הטסטים"
  "שלחתי פול ריקווסט עם הריפקטור של הקומפוננטה"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
helper="$tmp/smoke_helper.py"

# Pure logic: normalization, CER, log parsing, results, pass/fail. Testable offline.
cat > "$helper" <<'PY'
import json, re, statistics, sys, unicodedata

GERESH = "׳"
TEXT_RE = re.compile(r"TEXT \((\d+(?:\.\d+)?)s from release to paste\): (.*)$")
CER_MAX = 0.15
LATENCY_SLACK_S = 0.2
EPS = 1e-9

def normalize(s):
    s = unicodedata.normalize("NFC", s)
    s = s.replace("'", GERESH).replace("’", GERESH)
    s = re.sub(r"[.,!?]", "", s)
    return " ".join(s.split())

def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]

def cer(ref, hyp):
    ref, hyp = normalize(ref), normalize(hyp)
    if not ref:
        return 0.0 if not hyp else 1.0
    return levenshtein(ref, hyp) / len(ref)

def parse_text_line(line):
    """Return (latency_s, text) from a dictationLog TEXT line, or None."""
    m = TEXT_RE.search(line)
    return (float(m.group(1)), m.group(2)) if m else None

def new_entries(before, after):
    """Entries in `after` that were not in `before`. The log is capped at 200 and rotates,
    so anchor on the last entry we saw instead of on the length."""
    if not before:
        return after
    last = before[-1]
    for i in range(len(after) - 1, -1, -1):
        if after[i] == last:
            return after[i + 1:]
    return after

def build_results(ts, rows):
    lat = [r["latency_s"] for r in rows if r["latency_s"] is not None]
    return {"ts": ts, "sentences": rows,
            "median_latency_s": statistics.median(lat) if lat else None}

def decide(results, baseline):
    """Return (ok, reasons)."""
    reasons = []
    for i, s in enumerate(results["sentences"], 1):
        if s["cer"] is None or s["cer"] > CER_MAX + EPS:
            reasons.append(f"sentence {i}: cer {s['cer']} > {CER_MAX}")
    med, bmed = results.get("median_latency_s"), baseline.get("median_latency_s")
    if med is None or bmed is None:
        reasons.append("median latency missing")
    elif med > bmed + LATENCY_SLACK_S + EPS:
        reasons.append(f"median latency {med:.2f}s > baseline {bmed:.2f}s + {LATENCY_SLACK_S}s")
    return (not reasons, reasons)

def read_lines(path):
    with open(path, encoding="utf-8") as f:
        return [l.rstrip("\n") for l in f if l.strip()]

def self_test():
    checks = []
    def eq(name, got, want):
        ok = got == want if not isinstance(want, float) else abs(got - want) < 1e-9
        checks.append(ok)
        print(("ok   " if ok else "FAIL ") + f"{name}: got {got!r}, want {want!r}")
    s = "הבאג בצ׳קאאוט תוקן לפני הדיפלוי לפרודקשן"
    eq("cer identical", cer(s, s), 0.0)
    eq("cer final mem", cer("שלום", "שלומ"), 0.25)
    eq("cer apostrophe->geresh", cer("צ'קאאוט", "צ׳קאאוט"), 0.0)
    eq("cer right quote->geresh", cer("צ’קאאוט", "צ׳קאאוט"), 0.0)
    eq("cer punctuation+spaces", cer("שלום  עולם.", " שלום עולם!"), 0.0)
    eq("cer empty hyp", cer("שלום", ""), 1.0)
    eq("parse text line",
       parse_text_line("12:00:01 TEXT (1.23s from release to paste): שלום עולם"),
       (1.23, "שלום עולם"))
    eq("parse other line", parse_text_line("12:00:01 mic READY - audio is now flowing"), None)
    eq("new entries anchor", new_entries(["a", "b"], ["b", "c", "d"]), ["c", "d"])
    eq("new entries empty before", new_entries([], ["x"]), ["x"])
    eq("new entries none", new_entries(["a", "b"], ["a", "b"]), [])
    rows = [{"ref": "a", "hyp": "a", "cer": 0.0, "latency_s": x} for x in (1.0, 3.0, 2.0)]
    res = build_results("t", rows)
    eq("median latency", res["median_latency_s"], 2.0)
    eq("decide pass", decide(res, {"median_latency_s": 1.8})[0], True)
    eq("decide pass at slack edge", decide(res, {"median_latency_s": 1.8000000001})[0], True)
    eq("decide fail latency", decide(res, {"median_latency_s": 1.7})[0], False)
    bad = build_results("t", rows[:2] + [{"ref": "a", "hyp": "b", "cer": 0.16, "latency_s": 2.0}])
    eq("decide fail cer", decide(bad, {"median_latency_s": 5.0})[0], False)
    edge = build_results("t", [{"ref": "a", "hyp": "a", "cer": 0.15, "latency_s": 1.0}])
    eq("decide cer at limit", decide(edge, {"median_latency_s": 1.0})[0], True)
    none = build_results("t", [{"ref": "a", "hyp": "", "cer": 1.0, "latency_s": None}])
    eq("decide no latency", decide(none, {"median_latency_s": 1.0})[0], False)
    print("helper self-test: " + ("PASS" if all(checks) else "FAIL"))
    return 0 if all(checks) else 1

def main(argv):
    cmd = argv[1]
    if cmd == "self-test":
        return self_test()
    if cmd == "find-new":  # find-new <before> <after> <substring>: print newest new match
        hits = [e for e in new_entries(read_lines(argv[2]), read_lines(argv[3])) if argv[4] in e]
        if not hits:
            return 1
        print(hits[-1])
        return 0
    if cmd == "row":  # row <ref> <log line | ""> -> one JSON row
        parsed = parse_text_line(argv[3]) if argv[3] else None
        hyp, lat = (parsed[1], parsed[0]) if parsed else ("", None)
        print(json.dumps({"ref": argv[2], "hyp": hyp, "cer": round(cer(argv[2], hyp), 4),
                          "latency_s": lat}, ensure_ascii=False))
        return 0
    if cmd == "results":  # results <ts> <rows.jsonl> <out.json>: write results, print table
        rows = [json.loads(l) for l in read_lines(argv[3])]
        res = build_results(argv[2], rows)
        with open(argv[4], "w", encoding="utf-8") as f:
            json.dump(res, f, ensure_ascii=False, indent=2)
        print(f"{'#':<3}{'CER':>7}{'latency':>10}  transcript")
        for i, r in enumerate(rows, 1):
            lat = "-" if r["latency_s"] is None else f"{r['latency_s']:.2f}s"
            print(f"{i:<3}{r['cer']:>7.3f}{lat:>10}  {r['hyp']}")
        med = res["median_latency_s"]
        print("median latency: " + ("-" if med is None else f"{med:.2f}s"))
        return 0 if all(r["latency_s"] is not None for r in rows) else 1
    if cmd == "decide":  # decide <results.json> <baseline.json>
        with open(argv[2], encoding="utf-8") as f:
            res = json.load(f)
        with open(argv[3], encoding="utf-8") as f:
            base = json.load(f)
        ok, reasons = decide(res, base)
        for r in reasons:
            print("FAIL " + r)
        print("RESULT: " + ("PASS" if ok else "FAIL"))
        return 0 if ok else 1
    print(f"unknown helper command: {cmd}", file=sys.stderr)
    return 2

sys.exit(main(sys.argv))
PY

mode=""
baseline_file=""
case "${1:-}" in
  --helper-self-test) python3 "$helper" self-test; exit $? ;;
  --save-baseline) mode="save" ;;
  --baseline)
    mode="compare"
    baseline_file="${2:-}"
    if [ ! -f "$baseline_file" ]; then echo "--baseline needs an existing results.json" >&2; exit 2; fi
    ;;
  "") ;;
  *) echo "usage: dictation-smoke.sh [--save-baseline | --baseline <results.json>]" >&2; exit 2 ;;
esac

# a. Preconditions.
if [ "$("$HS_BIN" -c 'return type(_G.startRecording)' 2>/dev/null | tr -d '\r\n ')" != "function" ]; then
  echo "precondition: _G.startRecording is not a function. Is Hammerspoon running with hs.ipc and dictation loaded?" >&2
  exit 2
fi
if ! say -v '?' | grep -q Carmit; then
  echo "precondition: the Hebrew voice 'Carmit' is not installed (System Settings > Accessibility > Spoken Content)." >&2
  exit 2
fi
if [ ! -d /System/Applications/TextEdit.app ] && [ ! -d /Applications/TextEdit.app ]; then
  echo "precondition: TextEdit not found." >&2
  exit 2
fi

# b. Back up recordings first: each test dictation rotates out the oldest personal recording.
ts="$(date -u +%Y%m%dT%H%M%SZ)"
rec_dir="$HOME/.hammerspoon/recordings"
backup="$BASELINE_DIR/recordings-backup-$ts"
if ! mkdir -p "$backup"; then echo "could not create $backup" >&2; exit 3; fi
src_count=0
if [ -d "$rec_dir" ]; then
  src_count=$(find "$rec_dir" -type f | wc -l | tr -d ' ')
  if ! cp -Rp "$rec_dir/." "$backup/"; then
    echo "recordings backup failed; aborting before any dictation" >&2
    exit 3
  fi
fi
dst_count=$(find "$backup" -type f | wc -l | tr -d ' ')
if [ "$src_count" != "$dst_count" ]; then
  echo "recordings backup incomplete ($dst_count of $src_count files); aborting" >&2
  exit 3
fi
echo "recordings backed up: $dst_count file(s) -> $backup"

CMD_DUMP_LOG='for _,l in ipairs(_G.dictationLog or {}) do print((l:gsub("\n", "\\n"))) end'

dump_log() { "$HS_BIN" -c "$CMD_DUMP_LOG" > "$1"; }

# poll_log <before> <substring> <timeout_s>: print the newest new matching entry.
poll_log() {
  local deadline=$(( $(date +%s) + $3 + 1 )) after="$tmp/after.log"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    dump_log "$after"
    if python3 "$helper" find-new "$1" "$after" "$2"; then return 0; fi
    sleep 0.2
  done
  return 1
}

# c. One dictation per sentence.
rows="$tmp/rows.jsonl"
: > "$rows"
i=0
for sentence in "${SENTENCES[@]}"; do
  i=$((i + 1))
  echo "sentence $i: $sentence"
  osascript -e 'tell application "TextEdit"' -e 'activate' -e 'make new document' -e 'end tell' >/dev/null
  sleep 0.5

  before="$tmp/before.log"
  dump_log "$before"
  echo "  log length before: $(wc -l < "$before" | tr -d ' ')"

  "$HS_BIN" -c '_G.startRecording()' >/dev/null
  if ! poll_log "$before" "mic READY" 3 >/dev/null; then
    echo "  WARN: no 'mic READY' within 3 s; continuing"
  fi

  say -v Carmit "$sentence"
  sleep 0.4
  "$HS_BIN" -c '_G.stopRecordingAndTranscribe()' >/dev/null

  line=""
  if ! line="$(poll_log "$before" "TEXT (" 15)"; then
    echo "  no transcript within 15 s"
    line=""
  fi
  python3 "$helper" row "$sentence" "$line" >> "$rows"
done

# d. Table + results.json.
results="$tmp/results.json"
set +e
python3 "$helper" results "$ts" "$rows" "$results"
all_text=$?
set -e

# e. Save or compare.
case "$mode" in
  save)
    if [ "$all_text" -ne 0 ]; then
      echo "not saving a baseline: at least one sentence produced no transcript" >&2
      exit 1
    fi
    out_dir="$BASELINE_DIR/$ts"
    mkdir -p "$out_dir"
    cp "$results" "$out_dir/results.json"
    echo "$out_dir/results.json"
    ;;
  compare)
    python3 "$helper" decide "$results" "$baseline_file"
    ;;
  *)
    out="$BASELINE_DIR/smoke-$ts.json"
    mkdir -p "$BASELINE_DIR"
    cp "$results" "$out"
    echo "results: $out"
    [ "$all_text" -eq 0 ]
    ;;
esac
