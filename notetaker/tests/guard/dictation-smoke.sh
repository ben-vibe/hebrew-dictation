#!/usr/bin/env bash
# LIVE guided dictation smoke test. Ben reads 3 sentences aloud with the real fn+Shift shortcut
# while this script watches the dictation log. It is run by hand only, never from run-all.sh.
#
# The script is PASSIVE toward dictation. It only reads _G.dictationLog, _G.lastRecording and
# _G.isPrimedOrRecording() and reads files. It never calls a dictation function, never touches
# the event tap, never kills a process, and never modifies ~/.hammerspoon/recordings.
#
# Usage: dictation-smoke.sh --accept-rotation <N> (--save-baseline | --baseline <results.json>)
#                           [--attempt-timeout <s>]   (default 90)
#        dictation-smoke.sh --helper-self-test        (offline: pure helper tests only)
# Exit: 0 PASS / saved, 1 FAIL / not saved, 2 precondition missing, 3 recordings backup failed,
#       130/143 interrupted (partial results are written as invalid).
#
# Seams for selftest.sh only: HS_BIN, OSASCRIPT_BIN, PGREP_BIN, CP_BIN, BASELINE_DIR, and the
# timing overrides SMOKE_POLL_INTERVAL_S (default 1), SMOKE_HS_TIMEOUT_S (5), SMOKE_LEVEL_WAIT_S (3)
# and SMOKE_ATTEMPT_TIMEOUT_S (default: --attempt-timeout).
set -euo pipefail

BASELINE_DIR="${BASELINE_DIR:-$HOME/Library/Application Support/meeting-notes/baseline}"
MAX_ROTATION=12

SENTENCES=(
  "הבאג בצ׳קאאוט תוקן לפני הדיפלוי לפרודקשן"
  "צריך לעשות מרג׳ לברנץ׳ ולהריץ את הטסטים"
  "שלחתי פול ריקווסט עם הריפקטור של הקומפוננטה"
)

tmp="$(mktemp -d)"
helper="$tmp/smoke_helper.py"
driver=""

# The helper. Its pure part (normalization, CER, log classification, audio level, retry budget,
# results, pass/fail) is tested offline by --helper-self-test. Its live part drives the attempts
# in one process and owns the only `hs -c` and osascript calls.
cat > "$helper" <<'PY'
import hashlib, json, math, os, re, statistics, subprocess, sys, tempfile, time, unicodedata, wave
from array import array

GERESH = "׳"
CER_MAX = 0.15
LATENCY_SLACK_S = 0.2
EPS = 1e-9
MIN_AUDIO_S = 1.5
SILENT_MEAN_DB = -50.0
ACTIVE_WINDOW_DB = -45.0
MIN_ACTIVE_RATIO = 0.15
WINDOW_S = 0.05
FLOOR_DB = -120.0
# Whisper's known outputs on silence.
HALLUCINATIONS = {"תודה", "תודה רבה", "thank you", "thanks for watching"}

VALID = ("valid", "accuracy_fail")  # accuracy_fail is still a valid measurement
MAX_RETRIES = {"invalid_short": 2, "invalid_no_audio": 2, "invalid_silent": 2,
               "no_dictation_timeout": 2, "error_transcription_service": 1, "error_hs_timeout": 1}
RETRY_MSG = {
    "invalid_short": "Previous attempt was too short — hold fn+Shift for the whole sentence",
    "invalid_no_audio": "Previous attempt recorded no audio — check the mic, then try again",
    "invalid_silent": "Previous attempt was too quiet — please try again, closer to the mic",
    "no_dictation_timeout": "No dictation was detected — click in this document, then hold fn+Shift",
    "error_transcription_service": "The transcription service failed — please try again",
    "error_hs_timeout": "Hammerspoon did not respond — please try again",
}

# dictation.lua's exact log formats. Each entry is "HH:MM:SS <message>".
STAMP_RE = re.compile(r"^\d{1,2}:\d{2}:\d{2} ")
START_MSG = "start() - combo completed, isRecording=true"
STOP_RE = re.compile(r"^stop\(\) heldFor=(\d+(?:\.\d+)?)$")
SHORT_RE = re.compile(r"^held only (\d+(?:\.\d+)?)s, ignoring$")
NO_AUDIO_PREFIX = "recording missing or too small: "
SEND_RE = re.compile(r"^sending (\d+(?:\.\d+)?)s of audio \((\d+) bytes\)$")
TEXT_RE = re.compile(r"^TEXT \((\d+(?:\.\d+)?)s from release to paste\): (.*)$")
CURL_RE = re.compile(r"^curl exited code=(-?\d+)$")
SERVICE_ERRORS = ("could not parse response: ", "Groq auth error: ", "ERROR: no Groq API key")

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

def is_hallucination(hyp):
    return normalize(hyp or "").lower() in HALLUCINATIONS

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

def message(entry):
    return STAMP_RE.sub("", entry, count=1)

def classify(entries, timed_out=False):
    """Walk the new log entries of one attempt. Returns a dict whose status is "pending" (the
    sequence is not finished yet), "transcribed" (to be evaluated) or a final status."""
    a = {"status": "pending", "stage": "wait_start", "reason": "", "held_s": None,
         "audio_s": None, "latency_s": None, "hyp": None}
    def done(status, reason=""):
        a["status"], a["reason"] = status, reason[:300]
        return a
    curl_ok = False
    for e in entries:
        m = message(e)
        st = a["stage"]
        if st == "wait_start":
            if m == START_MSG:  # anything before the start of this dictation is ignored
                a["stage"] = "wait_stop"
        elif st == "wait_stop":
            mm = STOP_RE.match(m)
            if mm:
                a["held_s"], a["stage"] = float(mm.group(1)), "wait_audio"
        elif st == "wait_audio":
            mm = SHORT_RE.match(m)
            if mm:
                return done("invalid_short", f"held only {mm.group(1)} s (dictation ignores very short holds)")
            if m.startswith(NO_AUDIO_PREFIX):
                return done("invalid_no_audio", m)
            mm = SEND_RE.match(m)
            if mm:
                a["audio_s"], a["stage"] = float(mm.group(1)), "wait_text"
        else:  # wait_text
            mm = TEXT_RE.match(m)
            if mm:
                a["latency_s"], a["hyp"] = float(mm.group(1)), mm.group(2)
                return done("transcribed")
            if m.startswith(SERVICE_ERRORS):
                return done("error_transcription_service", m)
            mm = CURL_RE.match(m)
            if mm:
                if int(mm.group(1)) != 0:
                    return done("error_transcription_service", m)
                curl_ok = True
    if curl_ok:
        # The curl callback logs everything in one go, so curl OK with nothing after it means
        # Groq returned an empty text: dictation pastes nothing.
        return done("invalid_silent", "Groq returned an empty transcript")
    if timed_out:
        why = {"wait_start": ("no_dictation_timeout", "no fn+Shift dictation started"),
               "wait_stop": ("no_dictation_timeout", "dictation started but was not released"),
               "wait_audio": ("invalid_no_audio", "released, but no audio was sent"),
               "wait_text": ("error_transcription_service", "no transcription result")}
        return done(*why[a["stage"]])
    return a

def db(mean_square):
    if mean_square <= 0:
        return FLOOR_DB
    return max(FLOOR_DB, 10 * math.log10(mean_square) - 20 * math.log10(32768))

def level(path):
    """(mean_db, active_ratio) of a 16-bit PCM WAV: RMS in dBFS over the whole file, and the
    fraction of 50 ms windows above -45 dBFS. Raises on anything unreadable."""
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError(f"not 16-bit PCM (sample width {w.getsampwidth()})")
        rate, ch = w.getframerate(), w.getnchannels()
        frames = w.readframes(w.getnframes())
    samples = array("h")
    samples.frombytes(frames[:len(frames) // 2 * 2])
    if sys.byteorder == "big":
        samples.byteswap()
    if not samples:
        raise ValueError("no audio frames")
    win = max(1, int(rate * ch * WINDOW_S))
    total = active = windows = 0
    for i in range(0, len(samples), win):
        seg = samples[i:i + win]
        sq = sum(x * x for x in seg)
        total += sq
        windows += 1
        if db(sq / len(seg)) > ACTIVE_WINDOW_DB:
            active += 1
    return round(db(total / len(samples)), 2), round(active / windows, 4)

def evaluate(att, ref, lvl, lvl_error=""):
    """Final status of a transcribed attempt. lvl is (mean_db, active_ratio) or None."""
    a = dict(att, flags=[], mean_db=None, active_ratio=None)
    a["cer"] = round(cer(ref, a["hyp"] or ""), 4)
    def done(status, reason=""):
        a["status"], a["reason"] = status, reason
        return a
    if a["audio_s"] is None or a["audio_s"] < MIN_AUDIO_S:
        return done("invalid_short", f"only {a['audio_s']} s of audio (< {MIN_AUDIO_S} s)")
    if lvl is not None:
        a["mean_db"], a["active_ratio"] = lvl
    if is_hallucination(a["hyp"]):
        return done("invalid_silent", f"transcript {a['hyp']!r} is Whisper's silence artifact")
    if lvl is None:
        a["flags"].append("level_unknown")
    elif lvl[0] < SILENT_MEAN_DB or lvl[1] < MIN_ACTIVE_RATIO:
        return done("invalid_silent", f"too quiet: mean {lvl[0]} dBFS, active ratio {lvl[1]}")
    if a["cer"] > CER_MAX + EPS:
        return done("accuracy_fail", f"cer {a['cer']} > {CER_MAX}")
    return done("valid", f"level unknown: {lvl_error}" if lvl is None else "")

def new_state(ts, mode, budget, refs):
    return {"ts": ts, "mode": mode, "accept_rotation": budget, "attempts_used": 0,
            "stopped": "", "sentences": [{"ref": r, "attempts": []} for r in refs]}

def plan(state, k):
    """Next step for sentence k: ("run", retry message), ("next", "") or ("stop", "").
    Every attempt counts against the rotation budget, retries included."""
    if state["stopped"]:
        return ("stop", "")
    atts = state["sentences"][k - 1]["attempts"]
    if atts:
        last = atts[-1]["status"]
        if last in VALID:
            return ("next", "")
        if len(atts) - 1 >= MAX_RETRIES.get(last, 0):
            if last == "error_hs_timeout":
                state["stopped"] = "Hammerspoon did not respond; stopped"
                return ("stop", "")
            return ("next", "")
    if state["attempts_used"] >= state["accept_rotation"]:
        state["stopped"] = f"rotation budget used up ({state['accept_rotation']} attempts)"
        return ("stop", "")
    return ("run", RETRY_MSG.get(atts[-1]["status"], "") if atts else "")

def record(state, k, att):
    att = dict(att)
    att.pop("stage", None)
    state["attempts_used"] += 1
    att["n"] = state["attempts_used"]
    state["sentences"][k - 1]["attempts"].append(att)
    return att

def build_results(state, interrupted=False, recordings=None):
    rows = []
    for s in state["sentences"]:
        f = s["attempts"][-1] if s["attempts"] else {}
        rows.append({"ref": s["ref"], "status": f.get("status", "not_run"), "reason": f.get("reason", ""),
                     "hyp": f.get("hyp"), "cer": f.get("cer"), "latency_s": f.get("latency_s"),
                     "audio_s": f.get("audio_s"), "mean_db": f.get("mean_db"),
                     "active_ratio": f.get("active_ratio"), "flags": f.get("flags", []),
                     "attempts": s["attempts"]})
    ok = [r for r in rows if r["status"] in VALID]
    lat = [r["latency_s"] for r in ok if r["latency_s"] is not None]
    cers = [r["cer"] for r in ok if r["cer"] is not None]
    reasons = []
    if interrupted:
        reasons.append("interrupted")
    if state["stopped"]:
        reasons.append(state["stopped"])
    for k, r in enumerate(rows, 1):
        if r["status"] not in VALID:
            reasons.append(f"sentence {k}: {r['status']}" + (f" ({r['reason']})" if r["reason"] else ""))
    return {"ts": state["ts"], "mode": state["mode"], "accept_rotation": state["accept_rotation"],
            "attempts_used": state["attempts_used"],
            "valid": not interrupted and all(r["status"] in VALID for r in rows),
            "interrupted": interrupted, "invalid_reasons": reasons, "sentences": rows,
            "summary": {"median_latency_s": statistics.median(lat) if lat else None,
                        "mean_cer": round(statistics.mean(cers), 4) if cers else None,
                        "max_cer": max(cers) if cers else None,
                        "accuracy_failures": [k for k, r in enumerate(rows, 1) if r["status"] == "accuracy_fail"],
                        "invalid": [k for k, r in enumerate(rows, 1) if r["status"] not in VALID]},
            "recordings": recordings or {}}

def baseline_median(baseline):
    return (baseline.get("summary") or {}).get("median_latency_s", baseline.get("median_latency_s"))

def decide(results, baseline):
    """Return (ok, reasons). PASS = valid, every cer <= 0.15, median latency within slack."""
    reasons = []
    if not results.get("valid"):
        reasons.append("run is not valid: " + "; ".join(results.get("invalid_reasons", [])))
    for i, s in enumerate(results["sentences"], 1):
        if s["cer"] is None or s["cer"] > CER_MAX + EPS:
            reasons.append(f"sentence {i}: cer {s['cer']} > {CER_MAX}")
    med, bmed = results["summary"].get("median_latency_s"), baseline_median(baseline)
    if med is None or bmed is None:
        reasons.append("median latency missing")
    elif med > bmed + LATENCY_SLACK_S + EPS:
        reasons.append(f"median latency {med:.2f}s > baseline {bmed:.2f}s + {LATENCY_SLACK_S}s")
    return (not reasons, reasons)

def fmt(v, spec, unit=""):
    return "-" if v is None else format(v, spec) + unit

def report(res):
    print("\n== Per-sentence results")
    print(f"{'#':<3}{'status':<29}{'CER':>7}{'latency':>9}{'audio':>8}{'mean dB':>9}{'active':>8}  transcript")
    for k, r in enumerate(res["sentences"], 1):
        flags = f" [{','.join(r['flags'])}]" if r["flags"] else ""
        print(f"{k:<3}{r['status']:<29}{fmt(r['cer'], '.3f'):>7}{fmt(r['latency_s'], '.2f', 's'):>9}"
              f"{fmt(r['audio_s'], '.1f', 's'):>8}{fmt(r['mean_db'], '.1f'):>9}"
              f"{fmt(r['active_ratio'], '.2f'):>8}  {r['hyp'] or ''}{flags}")
    sm = res["summary"]
    print("\n== Median latency (release to paste, valid sentences)")
    print(fmt(sm["median_latency_s"], ".2f", "s"))
    print("\n== Accuracy")
    print(f"mean CER {fmt(sm['mean_cer'], '.3f')}, max CER {fmt(sm['max_cer'], '.3f')}, "
          f"failures (CER > {CER_MAX}): {sm['accuracy_failures'] or 'none'}")
    print("\n== Invalid or failed attempts")
    bad = [(k, a) for k, r in enumerate(res["sentences"], 1) for a in r["attempts"] if a["status"] not in VALID]
    for k, a in bad:
        print(f"sentence {k}, attempt #{a['n']}: {a['status']}" + (f": {a['reason']}" if a["reason"] else ""))
    for k in sm["invalid"]:
        if not res["sentences"][k - 1]["attempts"]:
            print(f"sentence {k}: not_run")
    if not bad and not sm["invalid"]:
        print("none")
    print(f"attempts used: {res['attempts_used']} of {res['accept_rotation']}")
    rec = res["recordings"]
    if rec:
        print("\n== Recordings")
        print(f"count before {rec.get('before')}, after {rec.get('after')}; backup: {rec.get('backup')}")

def summary_line(res):
    n = sum(1 for r in res["sentences"] if r["status"] in VALID)
    return (f"Smoke test finished: {n} of {len(res['sentences'])} sentences valid, median latency "
            f"{fmt(res['summary']['median_latency_s'], '.2f', ' s')}. Results are in the terminal. "
            "You can close this document.")

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def dump(obj, path):
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(path + ".tmp", path)

def write_wav(path, samples, rate=16000):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        data = array("h", samples)
        if sys.byteorder == "big":
            data.byteswap()
        w.writeframes(data.tobytes())

def tone(seconds, dbfs, rate=16000, hz=1000):
    amp = 32768 * 10 ** (dbfs / 20) * math.sqrt(2)  # RMS of a sine is amp / sqrt(2)
    return [int(round(amp * math.sin(2 * math.pi * hz * i / rate))) for i in range(int(seconds * rate))]

def self_test():
    checks = []
    def eq(name, got, want):
        ok = got == want if not isinstance(want, float) else got is not None and abs(got - want) < 1e-9
        checks.append(ok)
        print(("ok   " if ok else "FAIL ") + f"{name}: got {got!r}, want {want!r}")
    def near(name, got, want, tol):
        eq(name, got is not None and abs(got - want) <= tol, True)

    # normalize / CER
    s = "הבאג בצ׳קאאוט תוקן לפני הדיפלוי לפרודקשן"
    eq("cer identical", cer(s, s), 0.0)
    eq("cer final mem", cer("שלום", "שלומ"), 0.25)
    eq("cer apostrophe->geresh", cer("צ'קאאוט", "צ׳קאאוט"), 0.0)
    eq("cer right quote->geresh", cer("צ’קאאוט", "צ׳קאאוט"), 0.0)
    eq("cer punctuation+spaces", cer("שלום  עולם.", " שלום עולם!"), 0.0)
    eq("cer empty hyp", cer("שלום", ""), 1.0)
    eq("new entries anchor", new_entries(["a", "b"], ["b", "c", "d"]), ["c", "d"])
    eq("new entries empty before", new_entries([], ["x"]), ["x"])
    eq("new entries none", new_entries(["a", "b"], ["a", "b"]), [])
    eq("new entries duplicate last", new_entries(["x", "a"], ["a", "q", "a", "z"]), ["z"])

    # log-sequence classification
    T = lambda *ms: [f"10:00:{i:02d} {m}" for i, m in enumerate(ms)]
    pre = ("priming: opening mic on first modifier key", START_MSG, "mic READY - audio is now flowing")
    sent = pre + ("stop() heldFor=6.10", "recorder exited code=0", "sending 6.10s of audio (195244 bytes)")
    c = classify(T(*sent, "curl exited code=0", "TEXT (0.70s from release to paste): שלום עולם"))
    eq("classify transcribed", (c["status"], c["latency_s"], c["hyp"], c["audio_s"], c["held_s"]),
       ("transcribed", 0.70, "שלום עולם", 6.10, 6.10))
    eq("classify short hold", classify(T(*pre, "stop() heldFor=0.20", "held only 0.20s, ignoring"))["status"],
       "invalid_short")
    eq("classify no audio", classify(T(*pre, "stop() heldFor=2.00", "recording missing or too small: nil"))["status"],
       "invalid_no_audio")
    eq("classify parse error", classify(T(*sent, "curl exited code=0", "could not parse response: <html>"))["status"],
       "error_transcription_service")
    eq("classify auth error", classify(T(*sent, "curl exited code=0", 'Groq auth error: {"invalid_api_key"}'))["status"],
       "error_transcription_service")
    eq("classify no key", classify(T(*sent, "ERROR: no Groq API key at /x"))["status"], "error_transcription_service")
    c = classify(T(*sent, "curl exited code=6", "curl stderr:\\ncould not resolve host"))
    eq("classify curl nonzero", (c["status"], c["reason"]), ("error_transcription_service", "curl exited code=6"))
    eq("classify empty transcript", classify(T(*sent, "curl exited code=0"))["status"], "invalid_silent")
    eq("classify pending before start", classify(T("config loaded"))["status"], "pending")
    eq("classify pending mid-upload", classify(T(*sent))["status"], "pending")
    eq("classify pending stage", classify(T(*pre))["stage"], "wait_stop")
    eq("classify timeout no start", classify(T("priming cancelled (combo never completed)"), True)["status"],
       "no_dictation_timeout")
    eq("classify timeout still held", classify(T(*pre), True)["status"], "no_dictation_timeout")
    eq("classify timeout no result", classify(T(*sent), True)["status"], "error_transcription_service")
    eq("classify ignores lines before start",
       classify(T("TEXT (0.50s from release to paste): stale", *pre))["status"], "pending")

    # audio level on generated WAVs
    d = tempfile.mkdtemp()
    p_sil, p_tone, p_burst, p_bad = (os.path.join(d, n) for n in ("sil.wav", "tone.wav", "burst.wav", "bad.wav"))
    write_wav(p_sil, [0] * 16000 * 3)
    write_wav(p_tone, tone(3, -20))
    write_wav(p_burst, [0] * 16000 * 10 + tone(0.5, -20))
    with open(p_bad, "wb") as f:
        f.write(b"not a wav")
    eq("level silent", level(p_sil), (FLOOR_DB, 0.0))
    mdb, act = level(p_tone)
    near("level tone mean_db -20", mdb, -20.0, 0.1)
    eq("level tone active_ratio", act, 1.0)
    mdb, act = level(p_burst)
    eq("level burst mostly silent", act < MIN_ACTIVE_RATIO and mdb > SILENT_MEAN_DB, True)
    try:
        level(p_bad)
        eq("level unreadable raises", False, True)
    except Exception:
        eq("level unreadable raises", True, True)

    # evaluation: audio validity + hallucination guard + accuracy
    good = {"status": "transcribed", "reason": "", "held_s": 6.1, "audio_s": 6.1, "latency_s": 0.7, "hyp": s}
    eq("evaluate valid", evaluate(good, s, (-30.0, 0.8))["status"], "valid")
    eq("evaluate short audio", evaluate(dict(good, audio_s=1.2), s, (-30.0, 0.8))["status"], "invalid_short")
    eq("evaluate silent mean", evaluate(good, s, (-55.0, 0.5))["status"], "invalid_silent")
    eq("evaluate low active ratio", evaluate(good, s, (-30.0, 0.05))["status"], "invalid_silent")
    for h in ("תודה", "תודה רבה.", "Thank you.", "thanks for watching!"):
        eq(f"hallucination guard {h!r}", evaluate(dict(good, hyp=h), s, (-20.0, 1.0))["status"], "invalid_silent")
    eq("hallucination guard low level is silent, not accuracy_fail",
       evaluate(dict(good, hyp="תודה"), s, (-55.0, 0.02))["status"], "invalid_silent")
    eq("not hallucination", is_hallucination("תודה על הבאג"), False)
    e = evaluate(good, s, None, "no file")
    eq("evaluate level unknown stays valid", (e["status"], e["flags"]), ("valid", ["level_unknown"]))
    e = evaluate(dict(good, hyp="משהו אחר לגמרי"), s, (-30.0, 0.8))
    eq("evaluate accuracy_fail", (e["status"], e["cer"] > CER_MAX), ("accuracy_fail", True))

    # retry / rotation budget
    refs = ["a", "b", "c"]
    st = new_state("t", "save-baseline", 12, refs)
    eq("plan first attempt", plan(st, 1), ("run", ""))
    for _ in range(2):
        record(st, 1, {"status": "invalid_silent", "reason": ""})
        eq("plan retry silent", plan(st, 1), ("run", RETRY_MSG["invalid_silent"]))
    record(st, 1, {"status": "invalid_silent", "reason": ""})
    eq("plan silent gives up after 2 retries", plan(st, 1), ("next", ""))
    record(st, 2, {"status": "error_transcription_service", "reason": ""})
    eq("plan error retried once", plan(st, 2)[0], "run")
    record(st, 2, {"status": "error_transcription_service", "reason": ""})
    eq("plan error gives up after 1 retry", plan(st, 2), ("next", ""))
    record(st, 3, {"status": "accuracy_fail", "reason": ""})
    eq("plan accuracy_fail never retried", plan(st, 3), ("next", ""))
    st = new_state("t", "save-baseline", 2, refs)
    record(st, 1, {"status": "valid", "reason": ""})
    eq("plan valid moves on", plan(st, 1), ("next", ""))
    record(st, 2, {"status": "no_dictation_timeout", "reason": ""})
    eq("plan budget exhausted stops", plan(st, 2), ("stop", ""))
    eq("plan stays stopped", plan(st, 3), ("stop", ""))
    eq("plan stop reason", st["stopped"], "rotation budget used up (2 attempts)")
    st = new_state("t", "save-baseline", 12, refs)
    record(st, 1, {"status": "error_hs_timeout", "reason": ""})
    eq("plan hs timeout retried once", plan(st, 1)[0], "run")
    record(st, 1, {"status": "error_hs_timeout", "reason": ""})
    eq("plan hs timeout twice stops", plan(st, 1), ("stop", ""))
    eq("attempt numbering", [a["n"] for a in st["sentences"][0]["attempts"]], [1, 2])

    # valid flag
    def run_of(*statuses, lat=(1.0, 3.0, 2.0)):
        st = new_state("t", "save-baseline", 12, refs)
        for k, sts in enumerate(statuses, 1):
            if sts:
                record(st, k, {"status": sts, "reason": "", "cer": 0.2 if sts == "accuracy_fail" else 0.0,
                               "latency_s": lat[k - 1], "hyp": "x"})
        return st
    eq("valid all valid", build_results(run_of("valid", "valid", "valid"))["valid"], True)
    r = build_results(run_of("valid", "accuracy_fail", "valid"))
    eq("valid with accuracy_fail", (r["valid"], r["summary"]["accuracy_failures"]), (True, [2]))
    r = build_results(run_of("valid", "invalid_silent", None))
    eq("invalid with silent + not_run", (r["valid"], r["summary"]["invalid"], r["sentences"][2]["status"]),
       (False, [2, 3], "not_run"))
    eq("invalid when interrupted", build_results(run_of("valid", "valid", "valid"), interrupted=True)["valid"], False)
    r = build_results(run_of("valid", "valid", "valid"))
    eq("median latency", r["summary"]["median_latency_s"], 2.0)
    eq("median over valid only", build_results(run_of("valid", "invalid_short", "valid"))["summary"]["median_latency_s"], 1.5)

    # decide
    eq("decide pass", decide(r, {"summary": {"median_latency_s": 1.8}})[0], True)
    eq("decide pass legacy baseline", decide(r, {"median_latency_s": 1.8})[0], True)
    eq("decide pass at slack edge", decide(r, {"summary": {"median_latency_s": 1.8000000001}})[0], True)
    eq("decide fail latency", decide(r, {"summary": {"median_latency_s": 1.7}})[0], False)
    eq("decide fail accuracy", decide(build_results(run_of("valid", "accuracy_fail", "valid")),
                                      {"summary": {"median_latency_s": 5.0}})[0], False)
    eq("decide fail invalid run", decide(build_results(run_of("valid", "valid", "invalid_silent")),
                                         {"summary": {"median_latency_s": 5.0}})[0], False)
    edge = run_of("valid", "valid", "valid")
    for sn in edge["sentences"]:
        sn["attempts"][-1]["cer"] = 0.15
    eq("decide cer at limit", decide(build_results(edge), {"summary": {"median_latency_s": 5.0}})[0], True)
    eq("decide no baseline latency", decide(r, {"summary": {"median_latency_s": None}})[0], False)

    print("helper self-test: " + ("PASS" if all(checks) else "FAIL"))
    return 0 if all(checks) else 1

# --- live driver: everything below talks to hs / osascript / pgrep ------------------------
HS_BIN = os.environ.get("HS_BIN", "hs")
OSASCRIPT_BIN = os.environ.get("OSASCRIPT_BIN", "osascript")
PGREP_BIN = os.environ.get("PGREP_BIN", "pgrep")
CP_BIN = os.environ.get("CP_BIN", "cp")

def env_seconds(name, default):
    v = os.environ.get(name, "")
    return float(v) if v else default

# Timing. The production defaults are fixed here; the SMOKE_* overrides exist for selftest.sh.
HS_TIMEOUT_S = env_seconds("SMOKE_HS_TIMEOUT_S", 5.0)
POLL_INTERVAL_S = env_seconds("SMOKE_POLL_INTERVAL_S", 1.0)
LEVEL_WAIT_S = env_seconds("SMOKE_LEVEL_WAIT_S", 3.0)
START_GRACE_S = 60.0  # once a dictation has started, allow this long for it to finish

# Read-only Lua. Polling reads only the last 40 log entries, with newlines escaped.
CMD_LOGTYPE = 'print(type(_G.dictationLog))'
CMD_TAIL = ('local n=#_G.dictationLog; for i=math.max(1,n-39),n do '
            'print((_G.dictationLog[i]:gsub("\\n", "\\\\n"))) end')
CMD_STATE = 'local p, r = _G.isPrimedOrRecording(); print(tostring(p) .. " " .. tostring(r))'
CMD_LASTREC = 'print(tostring(_G.lastRecording))'

# AppleScript. Every call after the first addresses only the document it created, by name.
OSA_NEW = ['tell application "TextEdit"', 'set newDoc to make new document', 'return name of newDoc',
           'end tell']
OSA_SET = ['on run argv', 'set docName to item 1 of argv', 'tell application "TextEdit"',
           'if not (exists document docName) then error "the smoke-test document was closed"',
           'set text of document docName to item 2 of argv',
           'try', 'set size of text of document docName to 28', 'end try',
           'activate',
           'try', 'set index of (first window whose name is docName) to 1', 'end try',
           'end tell', 'end run']

class HsError(Exception):
    def __init__(self, rc):
        self.rc = rc
        super().__init__(f"hs -c timed out 3 times ({HS_TIMEOUT_S:g}s each)" if rc == 124
                         else f"hs -c failed (rc={rc})")

def hs(lua):
    """The single entry point for `hs -c`: a hard timeout via perl alarm, retried up to 2 times
    on timeout. Output goes to a file, so a hung child holding a pipe can never block us."""
    for attempt in range(1, 4):
        with tempfile.TemporaryFile() as out:
            rc = subprocess.call(["perl", "-MTime::HiRes=alarm", "-e", "alarm shift; exec @ARGV or exit 127",
                                  str(HS_TIMEOUT_S), HS_BIN, "-c", lua],
                                 stdout=out, stderr=subprocess.DEVNULL)
            out.seek(0)
            text = out.read().decode("utf-8", "replace")
        if rc == 0:
            return text
        if rc not in (-14, 142):  # killed by SIGALRM
            raise HsError(rc)
        print(f"  hs -c timed out after {HS_TIMEOUT_S:g}s (try {attempt} of 3)", file=sys.stderr, flush=True)
    raise HsError(124)

def hs_value(lua):
    return hs(lua).strip()

def osascript(lines, *args):
    cmd = [OSASCRIPT_BIN]
    for l in lines:
        cmd += ["-e", l]
    try:
        p = subprocess.run(cmd + list(args), capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as ex:
        return None, str(ex)
    if p.returncode != 0:
        return None, p.stderr.decode("utf-8", "replace").strip()
    return p.stdout.decode("utf-8", "replace").strip(), ""

def guide_text(doc, text):
    if not doc:
        return False
    return osascript(OSA_SET, doc, text)[0] is not None

def count_files(d):
    return sum(len(files) for _, _, files in os.walk(d)) if os.path.isdir(d) else 0

def precheck():
    try:
        t = hs_value(CMD_LOGTYPE)
    except HsError as ex:
        t = f"unreachable: {ex}"
    if t != "table":
        print(f"precondition: Hammerspoon not reachable or _G.dictationLog is not a table (got '{t}').\n"
              "Is Hammerspoon running with hs.ipc and dictation loaded?", file=sys.stderr)
        return False
    try:
        busy = hs_value(CMD_STATE)
    except HsError as ex:
        busy = f"unknown: {ex}"
    if busy != "false false":
        print(f"precondition: dictation is not idle (isPrimedOrRecording: '{busy}'). "
              "Release fn+Shift and retry.", file=sys.stderr)
        return False
    if not any(os.path.isdir(p) for p in ("/System/Applications/TextEdit.app", "/Applications/TextEdit.app")):
        print("precondition: TextEdit not found.", file=sys.stderr)
        return False
    return True

def end_state():
    print("\n== Dictation state at the end")
    try:
        st = hs_value(CMD_STATE)
        print(f"isPrimedOrRecording: {st}")
    except HsError as ex:
        st = None
        print(f"isPrimedOrRecording: unknown ({ex})")
    try:
        running = subprocess.call([PGREP_BIN, "-x", "dictation-recorder"], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL) == 0
        print("dictation-recorder process: " + ("running" if running else "none"))
    except OSError as ex:
        running = False
        print(f"dictation-recorder process: unknown ({ex})")
    if st != "false false" or running:
        print("NOTE: dictation is not idle. This script never stops or kills it; check it by hand.")
    sys.stdout.flush()

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def backup_recordings(rec_dir, backup):
    """Copy the recordings with `cp -p` and verify every file by sha256 against the source.
    Read-only toward rec_dir. Returns (file count, error)."""
    try:
        os.makedirs(backup, exist_ok=True)
    except OSError as ex:
        return 0, f"could not create {backup}: {ex}"
    files = sorted(os.path.relpath(os.path.join(dp, n), rec_dir)
                   for dp, _, names in os.walk(rec_dir) for n in names) if os.path.isdir(rec_dir) else []
    if not files:
        return 0, ""
    if subprocess.call([CP_BIN, "-Rp", rec_dir + "/.", backup + "/"]) != 0:
        return 0, "recordings backup failed"
    bad = [f for f in files if not os.path.isfile(os.path.join(backup, f))
           or sha256(os.path.join(backup, f)) != sha256(os.path.join(rec_dir, f))]
    if bad:
        return 0, "recordings backup checksum mismatch: " + ", ".join(bad)
    return len(files), ""

def tail_log():
    return [l for l in hs(CMD_TAIL).split("\n") if l.strip()]

def find_recording(prev):
    """The newly archived WAV: copied asynchronously, so wait up to LEVEL_WAIT_S for it."""
    deadline = time.monotonic() + LEVEL_WAIT_S
    while True:
        try:
            p = hs_value(CMD_LASTREC)
        except HsError as ex:
            return None, str(ex)
        if p and p != "nil" and p != prev and os.path.isfile(p) and os.path.getsize(p) > 0:
            return p, ""
        if time.monotonic() >= deadline:
            return None, ("_G.lastRecording did not change" if p == prev
                          else f"archived recording {p} missing or empty")
        time.sleep(min(0.2, LEVEL_WAIT_S))

def show_sentence(st, k, msg):
    text = f"Sentence {k} of {len(st['sentences'])} — click here, then hold fn+Shift, read the sentence below, release:"
    if msg:
        text = f"{msg}\n\n{text}"
    text = f"{text}\n\n{st['sentences'][k - 1]['ref']}\n\n"
    print("\n" + text, flush=True)
    if not guide_text(st.get("doc"), text):
        print("(could not update the TextEdit document; read the sentence above)", flush=True)

def run_attempt(st, k, msg, stop_path, timeout_s):
    """Wait for one dictation. Returns the attempt dict, or None when asked to stop."""
    hs_fail = lambda ex, what: {"status": "error_hs_timeout", "reason": f"{ex} while {what}", "held_s": None,
                                "audio_s": None, "latency_s": None, "hyp": None}
    try:
        anchor = tail_log()
    except HsError as ex:
        return hs_fail(ex, "reading the log")
    try:
        prev = hs_value(CMD_LASTREC)
    except HsError:
        prev = "?"
    show_sentence(st, k, msg)
    deadline = time.monotonic() + timeout_s
    extended, acc = False, []
    while True:
        if os.path.exists(stop_path):
            return None
        time.sleep(POLL_INTERVAL_S)
        now = time.monotonic()
        try:
            after = tail_log()
        except HsError as ex:
            return hs_fail(ex, "polling the log")
        acc += new_entries(anchor, after)
        anchor = after
        a = classify(acc, now >= deadline)
        if a["status"] != "pending":
            break
        if a["stage"] != "wait_start" and not extended:
            extended, deadline = True, max(deadline, now + START_GRACE_S)
    if a["status"] == "transcribed":
        time.sleep(min(1.0, POLL_INTERVAL_S))  # ~1 s after the TEXT line
        wav, err = find_recording(prev)
        lvl = None
        if wav:
            try:
                lvl = level(wav)
            except Exception as ex:
                err = f"{wav}: {ex}"
        a = evaluate(a, st["sentences"][k - 1]["ref"], lvl, err)
    return a

def attempts(st, stop_path, timeout_s):
    """Every attempt within the rotation budget. Returns False when asked to stop."""
    for k in range(1, len(st["sentences"]) + 1):
        while True:
            if os.path.exists(stop_path):
                return False
            action, msg = plan(st, k)
            if action != "run":
                break
            att = run_attempt(st, k, msg, stop_path, timeout_s)
            if att is None:
                return False
            att = record(st, k, att)
            print(f"  -> attempt #{att['n']} of {st['accept_rotation']}: {att['status']}"
                  + (f" ({att['reason']})" if att["reason"] else "")
                  + (f" cer={att['cer']}" if att.get("cer") is not None else ""), flush=True)
        if action == "stop":
            break
    return True

def write_results(out_dir, res):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "results.json")
    dump(res, path)
    return path

def run(mode, budget, timeout_s, baseline_file, baseline_dir, stop_path, refs):
    """The whole live run. Exit 0 PASS / saved, 1 FAIL / not saved, 2 precondition missing,
    3 recordings backup failed, 4 stopped by a signal (partial results written as invalid)."""
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    if not precheck():
        return 2
    rec_dir = os.path.join(os.environ["HOME"], ".hammerspoon", "recordings")
    backup = os.path.join(baseline_dir, f"recordings-backup-{ts}")
    rec_before, err = backup_recordings(rec_dir, backup)
    if err:
        print(f"{err}; aborting before any dictation", file=sys.stderr)
        return 3
    print(f"recordings backed up and sha256-verified: {rec_before} file(s) -> {backup}")
    print("Each dictation adds a recording; the live config keeps the newest 20, so up to "
          f"{budget} of the oldest will rotate out of ~/.hammerspoon/recordings (backed up at {backup}).")
    doc, err = osascript(OSA_NEW)
    if not doc:
        print(f"precondition: could not create a TextEdit document: {err}", file=sys.stderr)
        return 2
    print(f'guidance document: TextEdit "{doc}"', flush=True)
    st = dict(new_state(ts, mode, budget, refs), doc=doc)
    finished = attempts(st, stop_path, timeout_s)
    res = build_results(st, not finished,
                        {"before": rec_before, "after": count_files(rec_dir), "backup": backup})
    report(res)
    print()
    if not finished:
        print("interrupted: partial results written as invalid: "
              + write_results(os.path.join(baseline_dir, f"invalid-{ts}"), res))
        guide_text(doc, "Smoke test interrupted. You can close this document.")
        return 4
    guide_text(doc, summary_line(res))
    if mode == "save-baseline":
        if res["valid"]:
            print("saved baseline: " + write_results(os.path.join(baseline_dir, ts), res))
            return 0
        print("NOT saved as baseline: " + "; ".join(res["invalid_reasons"]))
        print("results: " + write_results(os.path.join(baseline_dir, f"invalid-{ts}"), res))
        return 1
    out_dir = os.path.join(baseline_dir, f"compare-{ts}")
    write_results(out_dir, res)
    ok, reasons = decide(res, load(baseline_file))
    decision = "".join(f"FAIL {r}\n" for r in reasons) + "RESULT: " + ("PASS" if ok else "FAIL") + "\n"
    with open(os.path.join(out_dir, "decision.txt"), "w", encoding="utf-8") as f:
        f.write(decision)
    print(decision + f"compare results: {out_dir}")
    return 0 if ok else 1

def main(argv):
    cmd = argv[1]
    if cmd == "self-test":
        return self_test()
    if cmd == "run":  # run <mode> <budget> <attempt timeout s> <baseline|-> <baseline dir> <stop file> <ref>...
        try:
            return run(argv[2], int(argv[3]), float(argv[4]), argv[5], argv[6], argv[7], argv[8:])
        finally:
            end_state()
    print(f"unknown helper command: {cmd}", file=sys.stderr)
    return 2

sys.exit(main(sys.argv))
PY
py() { python3 -I "$helper" "$@"; }

usage() {
  echo "usage: dictation-smoke.sh --accept-rotation <N> (--save-baseline | --baseline <results.json>) [--attempt-timeout <s>]" >&2
  echo "       dictation-smoke.sh --helper-self-test" >&2
  exit 2
}

# On INT/TERM the run is asked to stop through a stop file (nothing is ever killed); it then
# writes its partial results as invalid and prints the dictation state.
on_exit() {
  local rc=$?
  set +e
  trap - EXIT INT TERM
  if [ -n "$driver" ]; then
    : > "$tmp/stop"
    wait "$driver" 2>/dev/null
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- arguments ---------------------------------------------------------------
mode=""; baseline_file="-"; accept_rotation=""; attempt_timeout=90
while [ $# -gt 0 ]; do
  case "$1" in
    --helper-self-test) py self-test; exit $? ;;
    --save-baseline) [ -z "$mode" ] || usage; mode="save-baseline"; shift ;;
    --baseline) [ -z "$mode" ] && [ $# -ge 2 ] || usage; mode="compare"; baseline_file="$2"; shift 2 ;;
    --accept-rotation) [ $# -ge 2 ] || usage; accept_rotation="$2"; shift 2 ;;
    --attempt-timeout) [ $# -ge 2 ] || usage; attempt_timeout="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] || usage
if ! [[ "$accept_rotation" =~ ^[0-9]+$ ]] || [ $((10#$accept_rotation)) -lt 1 ] \
   || [ $((10#$accept_rotation)) -gt "$MAX_ROTATION" ]; then
  echo "precondition: --accept-rotation <N> is required, an integer 1..$MAX_ROTATION: the number of dictation" >&2
  echo "attempts (retries included) you accept, each rotating one old recording out of ~/.hammerspoon/recordings." >&2
  exit 2
fi
accept_rotation=$((10#$accept_rotation))
if ! [[ "$attempt_timeout" =~ ^[0-9]+$ ]] || [ "$attempt_timeout" -lt 1 ]; then
  echo "precondition: --attempt-timeout must be a positive number of seconds" >&2
  exit 2
fi
attempt_timeout="${SMOKE_ATTEMPT_TIMEOUT_S:-$attempt_timeout}"
if [ "$mode" = compare ] && [ ! -f "$baseline_file" ]; then
  echo "precondition: --baseline needs an existing results.json" >&2
  exit 2
fi

# --- the run: preconditions, recordings backup, guided attempts, report, save or compare ----
# In the background, so a signal reaches the trap at once.
py run "$mode" "$accept_rotation" "$attempt_timeout" "$baseline_file" "$BASELINE_DIR" "$tmp/stop" \
  "${SENTENCES[@]}" &
driver=$!
rc=0; wait "$driver" || rc=$?
driver=""
exit "$rc"
