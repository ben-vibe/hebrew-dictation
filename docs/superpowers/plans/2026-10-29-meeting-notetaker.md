# Meeting Notetaker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this project, tasks are dispatched through `superset:orchestrate`: one **builder** and one separate **verifier** per task (see "How tasks are run").

**Goal:** Add a meeting notetaker module next to the existing Hebrew dictation. It captures Zoom/Meet audio on the Mac, then transcribes and analyzes it in a free Cloudflare Worker, and shows it in a dashboard, without changing dictation's behavior.

**Architecture:**
- **Mac side:** Hammerspoon module (`notetaker.lua`) plus a new Swift helper (`meeting-recorder`).
  The helper writes a local spool of 5-minute, two-track `.m4a` chunks. An uploader pushes them
  to one Cloudflare Worker.
- **Cloud side:** the Worker stores audio in KV (or D1 blobs, if the Stage 0 spike fails) and
  metadata in D1. A cron-driven job runner does transcription and evidence-checked analysis with
  Groq's free tier. The same Worker serves the dashboard.
- **Isolation:** dictation is reached only through one appended `pcall(require, "notetaker")` line.

**Tech Stack:**
- Mac: Hammerspoon Lua 5.4; Swift (`swiftc`, AVFoundation, Core Audio process taps); bash.
- Cloud: Cloudflare Workers (TypeScript), D1, KV, cron triggers; Wrangler and Vitest with
  `@cloudflare/vitest-pool-workers`, as local devDependencies.
- AI: Groq `whisper-large-v3` and `openai/gpt-oss-120b` (the model is final after Stage 2).

**Spec:** `docs/superpowers/specs/2026-10-29-meeting-notetaker-design.md`. Executors read both
documents. Section references (§) point into the spec.

## Global Constraints

**Dictation is protected (§4.7):**
- Never modify any of these:
  - `~/.hammerspoon/init.lua` (except the single appended line in Task 1.5)
  - `~/.hammerspoon/bin/dictation-recorder*`
  - `~/.hammerspoon/recordings/`
  - `~/.config/dictation-groq-key`, `~/.config/dictation-elevenlabs-key`
  - In the repo: `dictation.lua`, `bin/dictation-recorder.swift`, `bin/compare-transcribers.sh`,
    and `install.sh`. (`README.md` is rewritten in English as the portfolio README, per Ben on 2026-10-29. The original Hebrew user guide is preserved verbatim at `docs/he/README.md`.)
- The only integration line, appended once with a timestamped backup:
  `pcall(require, "notetaker") -- meeting notetaker; delete this line to remove it completely`
- Mac-side globals: only `_G.notetaker`. Never read or write `_G.dictationLog`, `_G.lastRecording`,
  `_G.releasedAt`, `_G.startRecording`, `_G.stopRecordingAndTranscribe`, `_G.startPriming`,
  `_G.cancelPriming`, `_G.isPrimedOrRecording`, `_G.dictationTap`.
- No `hs.eventtap` for `flagsChanged`. No hotkeys on fn, fn+Shift, Ctrl+Cmd+R or Ctrl+Cmd+Y. The
  notetaker hotkey is **Ctrl+Alt+Cmd+M**, refused at load if it's already bound.
- Never touch `/tmp/hs-dictation.wav`. Never kill a process the notetaker didn't start; track
  its own processes by pidfile.

**Where things live:**
- Installed files: only `~/.hammerspoon/notetaker.lua`, `~/.hammerspoon/notetaker/**`,
  `~/Library/Application Support/meeting-notes/**`, `~/.config/notetaker-device-token`.
  Settings use `hs.settings` keys prefixed `notetaker.`.
- Repo: all new code under `notetaker/`. A git-level guard fails any branch that changes a
  protected repo path.

**Defaults are always the safe state:**
- Flag defaults: `notetaker.enabled=false`, `notetaker.autoRecord=false`, `notetaker.upload=false`,
  `notetaker.echoCancel=false`; Worker `paid_processing_enabled=false`, `ingest_enabled=true`.

**Cost:**
- No payment method on Cloudflare or Groq. No R2.
- No Groq call that would exceed the free limits stored in D1 `config` while
  `paid_processing_enabled=false`.

**Audio and limits:**
- Format: AAC `.m4a`, 16 kHz mono, ~32 kbps. 300 s chunks cut at the quietest point within ±15 s.
- Every chunk is under 25 MB (Groq's free upload limit).
- Retention:
  - The Mac deletes a local chunk only after the server reports it `transcribed`.
  - Cloud audio is deleted 7 days after processing completes, with a 30-day KV `expirationTtl` backstop.
- Jobs: after 5 non-quota failures a job becomes `failed`. Quota waits (`waiting_quota`) never
  count as failures.
- Silence: drop Whisper segments with `no_speech_prob > 0.6` and the known silence hallucinations.

**AI output (§4.4):**
- Output must cite segment IDs `S1…Sn`.
- Owner/due are null unless a verbatim quote of them appears in a cited segment.

**Documentation is part of every task [Ben]:** when a task changes what works, the same branch updates `README.md` ("Implemented" vs "Planned") and `docs/`. Never claim an unimplemented feature. Never commit secrets, recordings, baselines, key hashes or private config. Pushing feature branches to `origin` is allowed; merging to `main` is 🔐; no force-push and no history rewrites.

**Nothing irreversible without Ben (🔐):** no deploy, no remote D1/KV change, no install on Ben's
Mac, no Hammerspoon reload, no `brew install`, and no merge to `main` without his explicit approval.

## Review Focus

1. **Dictating with fn+Shift while a meeting is recording.** Dictation pastes normally with
   unchanged latency, and the meeting recording has no gap. → Task 1.5, check R4.
2. **Ctrl+Cmd+R (Hammerspoon reload) or a crash mid-recording.** No orphaned mic process. On next
   load the stale recorder (found by pidfile) is stopped and its meeting is finalized as
   `incomplete`; dictation still loads. → Task 1.3 test `test_reload_recovers_stale_meeting`.
3. **Offline for days, with the spool growing.** No unuploaded chunk is ever deleted. A menubar
   warning appears when the spool exceeds 2 GB. → Task 3.8 test `test_never_deletes_unconfirmed`
   and `test_spool_size_warning`.
4. **One meeting ends and another starts within 60 s** (Meet → Zoom, or a new Meet code). These
   are two separate meetings, never one merged meeting. → Task 5.1 test `test_back_to_back_meetings_split`.
5. **Mixed Hebrew/English inside one segment, and silence hallucinations ("Thank you", "תודה
   רבה") on the quiet track.** Transcripts keep both scripts in order. Hallucinations are dropped.
   Search finds both Hebrew and English words, and the dashboard renders each paragraph with the
   right direction. → Task 3.6 `test_drops_silence_hallucinations`, Task 6.1
   `test_search_mixed_language`, Task 6.3 Ben gate (RTL check).

---

## How tasks are run (applies to every task)

- **Branches.** `main` stays the original product until a stage is approved.
  - Each task gets its own superset workspace and branch `nt/<task-id>`, cut from the integration
    branch `notetaker`.
  - The verifier merges into `notetaker`. Merging `notetaker` → `main` happens once per stage,
    after 🔐 approval from Ben.
- **Builder:** writes tests first, implements, runs `notetaker/tests/run-all.sh`, commits, and
  reports. The report includes the commands it ran and their output.
- **Verifier.** A separate worker that didn't build the task. It:
  1. Checks out the branch fresh.
  2. Runs `notetaker/tests/run-all.sh` itself.
  3. Runs `notetaker/tests/guard/repo-no-touch.sh`.
  4. Reads the diff against the spec and this task.
  5. Tries at least 3 hostile inputs of its own.

  It replies PASS (with output) or FAIL (with the reason). A FAIL goes back to the builder.
  Nothing merges without PASS.
- **Report format.** Every task report has two sections that are never mixed:
  - **🤖 Automated:** command and output, re-run by the verifier.
  - **👤 Ben gate / 🔐 Ben approval:** exact steps, what to look for, and a pass/fail box.
- **Regression check R (required after any task that changes what is installed on Ben's Mac):**
  - R1: `guard/verify.sh` matches the baseline. The only allowed difference is the single
    `pcall` line.
  - R2: `guard/dictation-smoke.sh` passes 3/3 sentences with release→paste ≤ baseline + 0.2 s.
  - R3: hotkeys and dictation globals are unchanged.
  - R4 (from Task 1.5 on): dictation smoke passes while `meeting-recorder` is running.

## Dependencies and parallel lanes

```
Phase 0  T0.1 baseline ─┬─────────────────────────────────────────────────────────┐
         T0.2 🔐 accounts/tools ─ T0.3 worker skeleton ─ T0.4 KV+CPU+FTS spike    │
                                                                                 │
Mac      T1.1 perm spike ─ T1.2 recorder ─┬─ T1.3 lua module ─┐                   │
                                          └─ T1.4 installer ──┴─ T1.5 🔐 install ─┼─ T5.1 ─ T5.2 ─ T5.3 🔐 ─ T7.1
Eval                                         T2.1 eval script ── T2.2 👤 (needs T1.5)
Cloud    T3.1 schema ─┬─ T3.2 auth ─────────┐
         (needs T0.4) ├─ T3.3 audio store ──┼─ T3.4 ingest ─ T3.5 jobs+quota ─ T3.6 transcribe ─ T3.7 assemble ─ T4.1 ─ T4.2 ─ T4.3 👤
                      │                     └──────── T3.8 uploader (needs T1.2 spool format) ─ T3.9 🔐 deploy
Dashboard             └─ T6.1 API (needs T3.1, T3.2; fixtures) ─ T6.2 UI ─ T6.3 🔐
Hardening                                                                        T7.1 ─ T7.2 👤 week
```

**Run in parallel once T0.1–T0.4 are done:** the Mac lane (T1.1→T1.5), the Cloud lane (T3.1→T3.7),
the Dashboard lane (T6.1→T6.2) and T2.1.

**Serialization points:**
- T1.5 needs T1.3 and T1.4.
- T3.8 needs T1.2 (spool format) and T3.4 (contract).
- T3.9 needs T3.7 and T3.8.
- T4.2 uses the default model until T2.2 decides, and switching is a config change.

**Ben's checkpoints, in order:** T0.2 🔐, T0.4 🔐 (spike deploy), T1.5 🔐👤, T2.2 👤, T3.9 🔐👤,
T4.3 👤, T5.3 🔐👤, T6.3 🔐👤, T7.2 👤, plus 🔐 for each stage merge to `main`.

## File structure

```
notetaker/
  README.md                         what it is, flags, rollback (§4.7), uninstall
  install.sh  uninstall.sh          installer (refuses overwrite, --dry-run, --wire-init) / remover
  tests/
    run-all.sh                      runs every automated suite below; non-zero on any failure
    guard/snapshot.sh verify.sh     baseline of protected files/hotkeys/globals (stored outside repo)
    guard/repo-no-touch.sh          fails if `git diff main...HEAD` touches a protected repo path
    guard/dictation-smoke.sh        semi-automated live dictation check (needs Ben's Mac + speakers)
    guard/isolation-lint.sh         static checks on notetaker Lua (globals, eventtaps, hotkeys, paths)
  mac/
    recorder/main.swift             meeting-recorder CLI (Info.plist + build-app.sh only if T1.1 says .app)
    recorder/test-recorder.sh       scripted capture tests using `say` + `afplay`
    notetaker.lua                   entry: loads modules, reads flags, wires hs.* — thin glue only
    notetaker/config.lua            flag defaults + typed get/set over an injected store (pure)
    notetaker/state.lua             recording state machine (pure)
    notetaker/detect.lua            meeting detection decision (pure)
    notetaker/spool.lua             spool layout, manifest read/write, size accounting (pure + io)
    notetaker/uploader_core.lua     next upload actions + backoff (pure)
    notetaker/uploader.lua          hs.task/curl glue for uploader_core
    notetaker/recorder_ctl.lua      hs.task wrapper for meeting-recorder + pidfile
    notetaker/observe.lua           gathers observations (Chrome tabs via AppleScript, mic in use, Zoom)
    notetaker/ui.lua                menubar, countdown banner, consent copy
    tests/run.lua + tests/test_*.lua  plain Lua 5.4 tests (no Hammerspoon), tiny assert runner
  worker/
    package.json wrangler.toml tsconfig.json vitest.config.ts
    migrations/0001_init.sql
    src/index.ts                    router + scheduled() handler
    src/env.ts                      Env type
    src/auth.ts  src/ingest.ts  src/audioStore.ts  src/jobs.ts  src/quota.ts
    src/groq.ts  src/transcribe.ts  src/assemble.ts  src/analyze.ts  src/validate.ts
    src/dashboardApi.ts
    public/index.html public/app.js public/style.css
    test/*.test.ts  test/fixtures/
  eval/compare-strategies.mjs       Stage 2 evaluation
docs/notetaker/stage0-results.md  stage2-decision.md
```

---

## Phase 0: Safety baseline and setup

### Task 0.1: Baseline snapshot and guards

Must be done before any other change on Ben's Mac.

**Files:**
- Create: `notetaker/tests/guard/{snapshot.sh,verify.sh,repo-no-touch.sh,dictation-smoke.sh,isolation-lint.sh}`
- Create: `notetaker/tests/run-all.sh`

**Interfaces:**
- Produces:
  - `snapshot.sh` → writes `~/Library/Application Support/meeting-notes/baseline/<ts>.txt` and
    prints that path. The file holds the sha256 of each protected file, the key files as hashes
    only, the file list of `recordings/`, the `hs -c` dump of hotkeys, and the type of each
    dictation global.
  - `verify.sh <baseline>` → exit 0 when the snapshot matches. The single allowed difference is
    `init.lua` equal to the baseline plus exactly the one `pcall` line at the end.
  - `repo-no-touch.sh [base=main]` → exit 1, listing the paths, if a protected repo path changed.
  - **Recordings caveat:** the live install has `KEEP_RECORDINGS = true` and keeps only the newest 20 files. Every dictation, the smoke test included, therefore rotates out the oldest personal recording. `dictation-smoke.sh` first copies `~/.hammerspoon/recordings/` to `~/Library/Application Support/meeting-notes/baseline/recordings-backup-<ts>/`, and refuses to run if the copy fails. `verify.sh` reports the `recordings/` listing for information only, never as pass/fail, because Ben's own dictation changes it.
  - `dictation-smoke.sh` → for 3 fixed sentences:
    1. Focuses a scratch TextEdit document.
    2. Calls `_G.startRecording()` via `hs -c`.
    3. Plays `say -v Carmit "<sentence>"` through the speakers.
    4. Calls `_G.stopRecordingAndTranscribe()`.
    5. Reads the last `TEXT (` line from `_G.dictationLog`.

    It prints the similarity (character error rate) and the release→paste time for each sentence,
    and with `--baseline <file>` compares against a stored run.
  - `isolation-lint.sh <dir>` → exit 1 on:
    - any `_G.` that isn't `_G.notetaker`;
    - `eventtap`;
    - `flagsChanged`;
    - a forbidden hotkey combo;
    - any reference to `hs-dictation.wav`, `dictation-groq-key` (except in `install.sh`'s secret
      step), `recordings`, or `dictation-recorder`.

- [ ] Step 1: Write `repo-no-touch.sh` and `isolation-lint.sh`. Add self-tests in
      `notetaker/tests/guard/selftest.sh` that build temp git repos and Lua files that should
      FAIL and PASS (e.g. a fixture with `_G.releasedAt = 1` must fail).
- [ ] Step 2: Run `bash notetaker/tests/guard/selftest.sh`. Expected: all cases report their
      expected exit codes.
- [ ] Step 3: Write `snapshot.sh` and `verify.sh`. Self-test against a fake `HOME` (temp dir
      with copies of fixture files):
  - Appending the exact `pcall` line → `verify.sh` exits 0.
  - Any other edit → exit 1.
  - A changed key file → exit 1, and the key contents are never printed.
- [ ] Step 4: Write `dictation-smoke.sh` and `run-all.sh`. `run-all.sh` runs the guard self-tests
      always, the Lua tests if `lua` is present, the Worker tests if `node_modules` is present,
      and **never** the live smoke test.
- [ ] Step 5: Commit `test(notetaker): baseline guards`.
- [ ] 🔐👤 **Ben (5 min):** with Ben at the Mac and his OK, run `snapshot.sh` and
      `dictation-smoke.sh --save-baseline`. Store both paths in `docs/notetaker/baseline.md`
      (paths and numbers only, never key contents). This is the reference for every check R.

### Task 0.2: 🔐 Accounts and tools (Ben)

- [ ] 👤 Create a Cloudflare account (email signup, **no payment method**). Run
      `npx wrangler login` from `notetaker/worker` once it exists.
- [ ] 👤 In the Groq console: confirm there's **no billing method**, and copy the free-tier limits
      for `whisper-large-v3` and `openai/gpt-oss-120b` into `docs/notetaker/stage0-results.md`.
- [ ] 🔐 Approve `brew install lua` (Lua 5.4, for the Mac tests only).
- [ ] Record each approval in `stage0-results.md`.

### Task 0.3: Worker skeleton and local test harness

**Files:**
- Create: `notetaker/worker/{package.json,wrangler.toml,tsconfig.json,vitest.config.ts}`,
  `src/index.ts`, `src/env.ts`, `test/health.test.ts`

**Interfaces:**
- Produces:
  - `interface Env { DB: D1Database; AUDIO: KVNamespace; GROQ_API_KEY: string; DASHBOARD_PASSPHRASE: string; SESSION_SECRET: string }`
  - `GET /api/health → 200 {"ok":true}`
  - `wrangler.toml`: name `notetaker`; D1 binding `DB`; KV binding `AUDIO`; cron `* * * * *`;
    assets dir `public`.
  - Scripts: `npm test` (Vitest, local Miniflare, never remote), `npm run dev` (local only).

- [ ] Step 1: Test `health returns ok`: `expect(await (await SELF.fetch("http://x/api/health")).json()).toEqual({ok:true})`.
- [ ] Step 2: `npm test`. Expected: FAIL (no handler).
- [ ] Step 3: Implement the router in `src/index.ts` with `fetch` and an empty `scheduled`.
- [ ] Step 4: `npm test`. Expected: PASS.
- [ ] Step 5: Commit `feat(notetaker): worker skeleton`.

### Task 0.4: KV / CPU / FTS spike (decides the audio store)

**Files:**
- Create: `notetaker/worker/spike/` (a separate Worker named `notetaker-kv-spike`, deleted after use)
- Create: `docs/notetaker/stage0-results.md`

- [ ] Step 1: Spike endpoints:
  - `POST /spike/write?n=30` writes 30 random 1.2 MB values with `expirationTtl: 120`, recording
    the write time.
  - The cron run reads all 30 and records miss count and time to first visibility.
  - `GET /spike/report`.
- [ ] Step 2: Spike endpoint `POST /spike/cpu`: builds a multipart body around a 1.2 MB buffer
      and sends it to a local echo URL (no Groq call). Records `performance.now()` CPU estimates.
      The verifier also checks the Cloudflare dashboard's CPU-time metric.
- [ ] Step 3: Spike D1 check: `CREATE VIRTUAL TABLE t USING fts5(x, tokenize='trigram')`, insert
      `"הדיפלוי לפרודקשן"`, then `MATCH 'דיפלוי'`.
- [ ] 🔐 **Ben approves:** deploy the spike Worker plus a temporary D1 and KV in his new account.
      Run it, then 🔐 delete them all.
- [ ] Step 4: Write the results and the **decision** into `stage0-results.md`:
  - `AUDIO_STORE=kv` if misses resolve within 60 s, the TTL worked, and usage counters show the
    expected writes. Otherwise `AUDIO_STORE=d1blob`.
  - `SEARCH=fts5_trigram` or `SEARCH=like`.
  - The measured CPU time.
- [ ] 🤖 The verifier re-reads the raw spike output and confirms the decision follows from it.

---

## Phase 1: Mac capture (Mac lane)

### Task 1.1: Permission spike for the process tap

**Files:**
- Create: `notetaker/mac/recorder/spike-tap.swift`, removed after T1.2. Record the outcome in
  `docs/notetaker/stage0-results.md`.

- [ ] Step 1: A minimal Swift program that creates a Core Audio process tap on a given PID and
      writes 10 s to a `.m4a` file.
- [ ] Step 2: 🤖 Run it from Terminal against `afplay` playing `say -v Carmit -o /tmp/nt-spike.aiff "בדיקה אחת שתיים"`.
      Expected: non-silent output (peak > −40 dB).
- [ ] 👤 **Ben (2 min):** run the same thing launched via `hs -c 'hs.task.new(...):start()'`,
      approve the System Audio Recording prompt, and report whether the output is non-silent.
- [ ] Step 3: Record the outcome as `RECORDER_PACKAGING=cli` or `=app`. If `app`, T1.2 also
      creates `Info.plist` (bundle ID `local.notetaker.meeting-recorder`,
      `NSAudioCaptureUsageDescription`, `NSMicrophoneUsageDescription`) and `build-app.sh`
      (`swiftc` → bundle → `codesign -s -`).

### Task 1.2: `meeting-recorder`

**Files:**
- Create: `notetaker/mac/recorder/main.swift`, `notetaker/mac/recorder/test-recorder.sh`
  (plus `Info.plist`/`build-app.sh` if T1.1 says `app`)

**Interfaces:**
- Consumes: `bin/dictation-recorder.swift` as a **read-only template** (READY line, signal
  handling with DispatchSource, `DICTATION_TIMING`-style timing env, here named `NOTETAKER_TIMING`).
- Produces:
  - **CLI:** `meeting-recorder --spool <dir> --meeting <uuid> --others-pid <pid[,pid…]|system> [--chunk-secs 300] [--echo-cancel] [--debug-boundaries]`
  - **stdin commands, one per line:** `pause`, `resume`, `stop`.
  - **stdout lines:**
    - `READY`
    - `CHUNK <track> <seq> <offset_ms> <duration_ms> <peak_db> <relpath>`
    - `PAUSED`, `RESUMED`, `STOPPED`
    - `ERROR <message>`
    - `BOUNDARY <offset_ms>` (debug only)
  - **Spool files:** `<dir>/<uuid>/<track>-<seq %05d>.m4a` and the matching `.json`
    `{track, seq, offset_ms, duration_ms, peak_db, sha256}`. Each is written as `.part`, then
    renamed. `track ∈ {"self","others"}`, `seq` starts at 0.
  - **Shutdown:** on SIGTERM or `stop`, finalize the open chunks, print `STOPPED`, exit 0.
  - **Pause:** no audio is written during a pause; the next chunk's `offset_ms` jumps by the
    paused time.

- [ ] Step 1: Write `test-recorder.sh` with these cases. Each case uses generated audio:
      `say -v Carmit` / `say -v Samantha` with 2 s silences, played with `afplay`, tapped by PID.
      `--chunk-secs 20` keeps the tests short.
  - `others_track_captures_audio`: every `others` chunk has `peak_db > -40`.
  - `chunks_under_limit`: every `.m4a` is < 25 MB, and the 20 s chunks are < 200 KB.
  - `offsets_continuous`: for each track, `offset_ms[n+1] − (offset_ms[n] + duration_ms[n])` is
    within ±50 ms.
  - `pause_leaves_gap`: `pause` for 5 s, then `resume` → the next offset jumps by ≥ 4,900 ms.
  - `stop_finalizes`: `stop` → `STOPPED`, exit 0, every `.json` has a sha256 matching its file,
    and no `.part` files remain.
  - `boundary_in_silence`: every `BOUNDARY` falls inside one of the known silent windows of the
    fixture (±300 ms).
  - `sigterm_finalizes`: same as `stop_finalizes`, triggered with SIGTERM.
- [ ] Step 2: Run `bash notetaker/mac/recorder/test-recorder.sh`. Expected: FAIL (no binary).
- [ ] Step 3: Implement `main.swift`:
  - Mic via AVAudioEngine; voice processing only with `--echo-cancel`.
  - Others via a process tap.
  - Encode to AAC 16 kHz mono with `AVAudioFile`.
  - Choose the cut point as the lowest 100 ms RMS window within `chunk_secs ± 15 s`. The silence
    threshold is the builder's choice; document it.
- [ ] Step 4: Run the tests. Expected: all 7 PASS.
- [ ] Step 5: Commit `feat(notetaker): meeting-recorder`.

### Task 1.3: `notetaker.lua` module: flags, state, recorder control, menubar, manual hotkey

**Files:**
- Create:
  - `notetaker/mac/notetaker.lua`
  - `notetaker/mac/notetaker/{config,state,spool,recorder_ctl,ui}.lua`
  - `notetaker/mac/tests/run.lua`, `tests/test_config.lua`, `tests/test_state.lua`, `tests/test_spool.lua`

**Interfaces:**
- Consumes: the T1.2 CLI and stdout protocol, and the spool layout.
- Produces:
  - `config.new(store) → cfg`. `store` has `get(k)`/`set(k,v)` (`hs.settings` in production, a
    table in tests). `cfg:get(name)` returns the defaults from Global Constraints.
    `cfg:set(name, v)` validates booleans. Also `workerUrl` (string, default `nil`).
  - `state.transition(s, event, now) → s2, effects`.
    - States: `idle`, `countdown`, `recording`, `paused`, `finalizing`.
    - Events: `detected{platform,key}`, `countdown_elapsed`, `cancel`, `manual_toggle`, `pause`,
      `resume`, `meeting_ended`, `recorder_stopped`, `disable`.
    - `effects` is a list such as `{"start_recorder"}`, `{"stop_recorder"}`, `{"show_countdown"}`,
      `{"hide_countdown"}`, `{"write_meeting_json"}`.
  - `spool.newMeeting(root, platform, title, now) → meeting` (creates `<root>/<uuid>/meeting.json`
    `{client_meeting_id, platform, title, started_at, tracks:[{track_id:"self",label:"Ben"},{track_id:"others",label:"Others"}]}`).
    Also `spool.finalize(meeting, now, lastSeq)`, `spool.list(root)`,
    `spool.readState(meeting)`/`writeState`, `spool.sizeBytes(root)`.
  - `recorder_ctl.start(meeting, othersPid, echoCancel) → handle` (writes
    `~/Library/Application Support/meeting-notes/recorder.pid`), `handle:pause()`,
    `handle:resume()`, `handle:stop()`, and `recorder_ctl.recoverStale(root) → n` (kills only the
    PID in the pidfile, and only if its command name is `meeting-recorder`; finalizes that
    meeting with `status="incomplete"`).
  - Globals: `_G.notetaker = { cfg, state, log }` only.

- [ ] Step 1: Tests in `test_config.lua`:
  - `test_defaults_safe`: all four flags are `false`.
  - `test_set_rejects_non_boolean`.
- [ ] Step 2: Tests in `test_state.lua`:
  - `test_manual_toggle_starts_and_stops`
  - `test_disable_while_recording_stops`: effects include `stop_recorder`.
  - `test_cancel_in_countdown_never_starts`: no `start_recorder` in any effects.
  - `test_pause_resume`
  - `test_disabled_ignores_detected`
- [ ] Step 3: Tests in `test_spool.lua`:
  - `test_new_meeting_writes_json`
  - `test_finalize_records_last_seq`
  - `test_reload_recovers_stale_meeting` (Review Focus 2): a fixture pidfile with a dead PID →
    the meeting is marked incomplete and nothing is killed. A pidfile whose command name isn't
    `meeting-recorder` → not killed.
- [ ] Step 4: Run `lua notetaker/mac/tests/run.lua`. Expected: FAIL.
- [ ] Step 5: Implement the pure modules, then `recorder_ctl.lua` and `ui.lua`.
  - `ui.lua`: menubar shows "NT off" / "NT ●" (red with elapsed time) / "NT ⏸". The menu has
    Start/Stop, Pause/Resume, "Disable notetaker", "Copy consent notice" (Hebrew + English text
    fixed in `ui.lua`), and "Open dashboard".
  - `notetaker.lua` glue:
    - Bind Ctrl+Alt+Cmd+M only if `hs.hotkey.getHotkeys()` doesn't already have it.
    - Call `recoverStale` at load.
    - Keep every timer and watcher in module-level locals.
- [ ] Step 6: `lua notetaker/mac/tests/run.lua && bash notetaker/tests/guard/isolation-lint.sh notetaker/mac`.
      Expected: PASS.
- [ ] Step 7: Commit `feat(notetaker): hammerspoon module (manual mode)`.

### Task 1.4: Installer and uninstaller

**Files:**
- Create: `notetaker/install.sh`, `notetaker/uninstall.sh`, `notetaker/tests/test-install.sh`

**Interfaces:**
- Produces:
  - `install.sh [--dry-run] [--wire-init] [--upgrade]`:
    - Builds `meeting-recorder` (or the `.app`).
    - Copies the notetaker Lua files and binary to their paths.
    - Creates `~/.config/notetaker-device-token` (mode 600, 32 random bytes hex) only if absent.
    - **Exits non-zero, writing nothing, if a destination exists with different content.**
    - Prints every action first.
    - With `--wire-init`: backs up `init.lua` to `init.lua.bak-notetaker-<ts>`, then appends the
      exact `pcall` line only if it isn't already there.
    - With `--upgrade`: replaces only files listed in `~/.hammerspoon/notetaker/MANIFEST`
      (written at install), after printing a diff.
  - `uninstall.sh [--dry-run] [--purge-spool]`:
    - Removes the `pcall` line (backup first), the notetaker files, and the token, after a `y/N` prompt.
    - Keeps the spool unless `--purge-spool` is given.
- [ ] Step 1: `test-install.sh` runs everything with `HOME=$(mktemp -d)` seeded with fixture
      `init.lua`, dictation files and key files. Cases:
  - `dry_run_writes_nothing`: a directory hash is identical before and after.
  - `install_creates_only_notetaker_paths`: a diff of the file list shows only the allowed paths.
  - `wire_init_appends_exactly_one_line`, `wire_init_idempotent`, `wire_init_makes_backup`.
  - `refuses_overwrite`: a pre-existing, different `notetaker.lua` → exit ≠ 0, and nothing changed.
  - `keys_untouched`: the sha256 of the key files is the same before and after.
  - `uninstall_restores_init`: `init.lua` is byte-identical to the original.
  - `uninstall_keeps_spool`.
  - `upgrade_replaces_only_notetaker_files`: a non-manifest file at a notetaker path → refused.
- [ ] Step 2: Run. Expected: FAIL. Step 3: implement. Step 4: run. Expected: PASS.
- [ ] Step 5: Commit `feat(notetaker): installer with rollback`.

### Task 1.5: 🔐👤 Install on Ben's Mac (manual mode, upload off)

- [ ] 🔐 Ben approves the install.
- [ ] Run `snapshot.sh`, then `install.sh --dry-run`. Ben reads the output.
- [ ] Run `install.sh --wire-init`. Ben presses Ctrl+Cmd+R.
- [ ] 🤖 Run regression checks R1–R3. `notetaker.enabled` is still false, so nothing is active
      yet: dictation must be untouched.
- [ ] 👤 Ben turns on "Enable notetaker" in the menubar.
- [ ] 👤 **Ben gate: 30-minute Meet call, with headphones.**
  - Start with Ctrl+Alt+Cmd+M.
  - The menubar is red the whole time.
  - Spot-check that both tracks are audible (the dashboard doesn't exist yet; Ben uses QuickTime
    on spool files).
  - No remote voice in `self`.
- [ ] 👤 **Ben gate: 10 minutes without headphones**, `echoCancel` off. Note any echo.
  - If there's echo: 🔐 turn on `echoCancel` and repeat 10 minutes, plus R4.
  - `echoCancel` stays on only if R4 passes.
- [ ] 🤖 **R4:** dictation smoke while recording. 3/3 pass, latency ≤ baseline + 0.2 s, and the
      meeting chunks have no gap.
- [ ] 👤 **Rollback drill:** "Disable notetaker", then Ctrl+Cmd+R → R1–R3 pass.
- [ ] 🔐 Ben approves merging the Stage 1 branch into `main`.

---

## Phase 2: Language and model evaluation

### Task 2.1: Evaluation script

**Files:**
- Create: `notetaker/eval/compare-strategies.mjs`, `notetaker/eval/fixtures/` (generated with `say`), `notetaker/eval/test.mjs`

**Interfaces:**
- Consumes: the Groq key read-only from `~/.config/dictation-groq-key`; `VOCAB_PROMPT` copied verbatim
  from `dictation.lua` (the repo copy matches the live `init.lua` prompt — verified 2026-10-29) plus
  English terms.
- Produces:
  - `node compare-strategies.mjs <dir-of-spool-meeting> [--reference ref.txt] [--mock]`
  - Writes `<dir>/eval.md`: one row per strategy A, B, C with the transcript excerpt, the
    character error rate when a reference is given, the audio-seconds used, and the detected
    languages. Plus a section comparing the LLMs `openai/gpt-oss-120b` vs `qwen/qwen3.8-27b` on the
    draft analysis prompt.
  - Strategy C = transcribe the first 30 s with `language` omitted, read `language` from
    `verbose_json`, then transcribe the full chunk pinned to it.
- [ ] Step 1: In `test.mjs` with `--mock` (recorded fixtures):
  - `cer_identical_is_zero`
  - `cer_hebrew_with_final_letters` (`"שלום"` vs `"שלומ"` → 0.25)
  - `strategy_c_pins_detected_language`
  - `report_has_three_rows`
- [ ] Step 2: run, FAIL → implement → PASS. Commit `feat(notetaker): strategy eval`.
- [ ] 🤖 Live run on the `say` fixtures, using about 5 free audio-minutes. The table is committed.

### Task 2.2: 👤 Ben's real samples and decision

- [ ] 👤 Ben records three real meetings with the T1.5 install: one Hebrew, one English, one mixed.
- [ ] 🤖 Run `compare-strategies.mjs` on each one.
- [ ] 🤖 For each real meeting, list every chunk with `peak_db` and whether Whisper found speech in it. From that list, propose the highest threshold that would have skipped **no** chunk containing speech (quiet voices included), or recommend keeping skipping off.
- [ ] 👤 Ben reads the tables and picks the language strategy and model. He also approves or rejects the silence threshold. These go into
      `docs/notetaker/stage2-decision.md` and the default values in the `0002_config.sql` seed (T3.5).

---

## Phase 3: Cloud backbone (Cloud lane)

All of these run against local Miniflare only. Nothing remote until T3.9.

### Task 3.1: D1 schema

**Files:**
- Create: `notetaker/worker/migrations/0001_init.sql`, `test/schema.test.ts`
- Tables: §4.5 plus `device_tokens(token_hash PK, label, created_at, revoked_at)`,
  `sessions(id PK, expires_at)`, `config(key PK, value)`, `groq_usage(window_start, kind, amount)`.
  - `chunks` is unique on `(meeting_id, track_id, seq)`.
  - `meetings.client_meeting_id` is unique.
  - `segments_fts` (FTS5 trigram, or omitted per T0.4).
- [ ] Tests:
  - `test_migration_applies`
  - `test_chunk_unique`: a second insert of the same key throws.
  - `test_client_meeting_id_unique`
  - `test_fts_or_like_search_finds_prefixed_hebrew`: insert `"הדיפלוי"`, query `"דיפלוי"` → 1 row.
- [ ] FAIL → implement → PASS → commit.

### Task 3.2: Auth

**Files:** `src/auth.ts`, `test/auth.test.ts`

**Interfaces:**
- `authDevice(req: Request, env: Env): Promise<{tokenHash: string} | null>`: reads `Authorization: Bearer <token>`; sha256; looks up a non-revoked row.
- `login(passphrase: string, env: Env): Promise<string | null>`: returns a `Set-Cookie` value
  `nt_session=<id>; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=2592000`.
- `requireSession(req: Request, env: Env): Promise<boolean>`

- [ ] Tests:
  - `device_valid`, `device_revoked_rejected`, `device_missing_rejected`
  - `login_wrong_passphrase_null`: compared in constant time.
  - `session_expired_rejected`
  - `session_cookie_flags`
- [ ] FAIL → implement → PASS → commit.

### Task 3.3: Audio store

**Files:** `src/audioStore.ts`, `test/audioStore.test.ts`

**Interfaces:**
- `interface AudioStore { put(key: string, data: ArrayBuffer): Promise<void>; get(key: string): Promise<ArrayBuffer | null>; delete(key: string): Promise<void> }`
- `makeAudioStore(env: Env, kind: "kv" | "d1blob"): AudioStore`
  - KV: `put` with `expirationTtl: 2592000`.
  - d1blob: table `audio_blobs(key PK, data BLOB)`, created in `0001` only if T0.4 chose it.
- Key format: `m/<meeting_id>/<track>/<seq>`.

- [ ] Tests, run against both implementations:
  - `roundtrip_bytes_identical`
  - `missing_returns_null`
  - `delete_then_null`
  - `put_rejects_over_25mb`
- [ ] FAIL → implement → PASS → commit.

### Task 3.4: Ingest API

**Files:** `src/ingest.ts`, `test/ingest.test.ts`

**Interfaces:**
- Consumes: `authDevice`, `AudioStore`, `enqueue` (stubbed here, real in T3.5).
- Produces (§4.2):
  - `POST /api/meetings` with body `{client_meeting_id, source, platform, title?, started_at, language_hint?, tracks:[{track_id,label}]}`
    → `200 {meeting_id}`. Idempotent on `client_meeting_id`.
  - `PUT /api/meetings/:id/chunks/:track/:seq` with headers `x-offset-ms`, `x-duration-ms`,
    `x-peak-db`, `x-sha256` and the audio body:
    - `201` (new), `200` (same sha256 already stored), `409` (different sha256), `413` (> 25 MB), `400` (sha mismatch with body).
    - On `201`: store the audio, insert the chunk row, `enqueue("transcribe", meetingId, "<track>/<seq>")`.
  - `POST /api/meetings/:id/finalize` with body `{ended_at, last_seq_per_track:{self:n, others:n}}` → `200`.
  - `GET /api/meetings/:id/chunks/status` → `{chunks:[{track,seq,state}]}` with `state ∈ uploaded|transcribed|skipped_silent|failed`.
  - Every route returns 401 without a valid device token, and 503 `{error:"ingest_disabled"}` when `config.ingest_enabled='false'`.

- [ ] Tests:
  - `create_idempotent`
  - `put_new_201_enqueues`
  - `put_same_hash_200_no_new_job`
  - `put_diff_hash_409`
  - `put_bad_sha_400`
  - `put_too_large_413`
  - `finalize_records_expected`
  - `status_lists_states`
  - `no_token_401`
  - `ingest_disabled_503`
- [ ] FAIL → implement → PASS → commit.

### Task 3.5: Jobs and free-quota ledger

**Files:**
- Create: `src/jobs.ts`, `src/quota.ts`, `migrations/0002_config.sql` (seeds the free limits from
  `stage0-results.md`, the model and language from `stage2-decision.md` or the spec defaults, and
  `paid_processing_enabled='false'`)
- Tests: `test/jobs.test.ts`, `test/quota.test.ts`

**Interfaces:**
- `type JobKind = "transcribe" | "assemble" | "analyze" | "cleanup_audio"`
- `enqueue(db: D1Database, kind: JobKind, meetingId: string, ref: string, notBefore?: number): Promise<void>`
  is idempotent on `(kind, meetingId, ref)`.
- `type JobResult = {status:"done"} | {status:"retry", notBefore:number, reason:"quota"|"audio_not_visible"|"error", error?:string}`
- `runDueJobs(env: Env, now: number, max: number, handlers: Record<JobKind,(env,job)=>Promise<JobResult>>): Promise<number>`
  - Claims jobs atomically: `UPDATE … SET state='running' WHERE id=? AND state IN ('pending','waiting_quota')`
    and checks `changes=1`.
  - `quota` → state `waiting_quota` and attempts unchanged.
  - `error` → attempts+1; after 5 attempts the state becomes `failed`.
  - A job stuck in `running` for more than 15 min is reset to `pending`.
- `reserve(db, kind:"audio_sec"|"llm_tokens"|"requests", amount:number, now:number): Promise<{ok:true}|{ok:false, resumeAt:number}>`
  checks the hour, day and minute windows against `config`, and records usage on success.
- **Free-only rule:** while `paid_processing_enabled='false'`, `reserve` never returns `ok:true`
  when it would exceed any limit.
- `scheduled()` in `index.ts` calls `runDueJobs(env, Date.now(), 20, handlers)`. The ingest
  handler also calls it via `ctx.waitUntil` with `max=1`.

- [ ] Tests:
  - `quota_wait_not_failure`
  - `five_errors_fail`
  - `retry_after_respected`
  - `stuck_running_reset`
  - `concurrent_claim_once`: two `runDueJobs` calls in parallel → the handler runs once.
  - `reserve_blocks_at_hour_limit_resume_next_window`
  - `reserve_blocks_at_day_limit`
  - `paid_flag_false_never_exceeds`: a property-style loop of 1,000 random reservations.
- [ ] FAIL → implement → PASS → commit.

### Task 3.6: Groq client and transcribe job

**Files:** `src/groq.ts`, `src/transcribe.ts`, `test/transcribe.test.ts`, `test/fixtures/groq/*.json`

**Interfaces:**
- `class QuotaError extends Error { retryAfterSec: number }`
- `transcribeAudio(env: Env, audio: ArrayBuffer, opts:{language?: string; prompt: string; filename: string}): Promise<WhisperSegment[]>`
  posts `model`, `response_format=verbose_json`, `timestamp_granularities[]=segment`.
  - `type WhisperSegment = {start:number; end:number; text:string; no_speech_prob:number; language?:string}`
  - A 429 throws `QuotaError(retry-after header ?? 60)`.
- `chat(env: Env, model: string, messages: {role:string;content:string}[]): Promise<{content:string; totalTokens:number}>`
  uses `response_format: {type:"json_object"}`.
- `filterSegments(segs: WhisperSegment[]): WhisperSegment[]`: drops `no_speech_prob > 0.6`, and
  drops a text that trims to one of `["Thank you.","Thank you","תודה רבה.","תודה רבה","תודה.","Thanks for watching!"]`
  when `no_speech_prob > 0.2`.
- `transcribeJob(env, job): Promise<JobResult>`:
  - Silence skip: only when `config.silence_skip_db` is set (default **null = never skip**, per Ben). Then `peak_db < silence_skip_db` → `skipped_silent` (no Groq call). Enabling a threshold is a 🔐 decision after T2.2 evidence.
  - Otherwise, a missing audio key → `retry audio_not_visible +60s`.
  - Calls `reserve("audio_sec", max(duration, 10))` before calling Groq.
  - Inserts the segments with absolute `start_ms = offset_ms + start*1000`, then marks the chunk `transcribed`.
  - Calls `enqueue("assemble")` once every expected chunk is transcribed or skipped.

- [ ] Tests (fetch mocked):
  - `silence_skip_off_by_default_calls_groq`: a peak_db of −60 with no threshold still calls Groq.
  - `silent_chunk_no_groq_call_when_threshold_set`
  - `kv_miss_retries_60s`
  - `quota_429_waits`
  - `reserve_denied_no_call`
  - `segments_absolute_time`
  - `test_drops_silence_hallucinations` (Review Focus 5)
  - `mixed_language_segment_preserved`: the fixture `"הדיפלוי to production נכשל"` is stored verbatim.
  - `rerun_no_duplicate_segments`
  - `vocab_prompt_sent`
- [ ] FAIL → implement → PASS → commit.

### Task 3.7: Assemble job and meeting status

**Files:** `src/assemble.ts`, `test/assemble.test.ts`

**Interfaces:**
- `mergeTracks(rows: {track_id:string; speaker:string; start_ms:number; end_ms:number; text:string}[]): (typeof rows[0] & {sid:string})[]`
  sorts by `start_ms`, breaks ties by track (`self` first), and assigns `S1…Sn`.
- `assembleJob(env, job): Promise<JobResult>` writes the `sid`s and the FTS rows, sets the meeting
  status to `transcribed`, and enqueues `analyze`.
- Meeting status values: `recording | uploading | processing | waiting_quota | transcribed | ready | incomplete | failed`.
  The cron marks a meeting `incomplete` 24 h after finalize when chunks are still missing, and
  assembles what exists.
- `cleanup_audio`: enqueued with `notBefore = ready_at + 7d`. Deletes the audio-store keys at a
  rate of at most 200 per run.

- [ ] Tests:
  - `merge_orders_by_time`
  - `tie_self_first`
  - `sids_stable_on_rerun`
  - `incomplete_after_24h`
  - `cleanup_after_7d_only`
  - `cleanup_rate_limited`
- [ ] FAIL → implement → PASS → commit.

### Task 3.8: Mac uploader

**Files:** `notetaker/mac/notetaker/{uploader_core,uploader}.lua`, `notetaker/mac/tests/test_uploader.lua`, `notetaker/tests/contract-test.sh`

**Interfaces:**
- Consumes: the T1.3 spool API and the T3.4 HTTP contract.
- Produces:
  - `uploader_core.nextActions(meeting, localState, serverStatus|nil) → actions`
    - Each action is one of `{kind="create"}`, `{kind="put",track,seq}`, `{kind="finalize"}`,
      `{kind="poll_status"}`, `{kind="delete_local",track,seq}`.
    - `delete_local` appears only for chunks the server reports as `transcribed` or `skipped_silent`.
  - `uploader_core.backoffSeconds(attempt) → min(5 * 2^attempt, 900)`
  - `uploader.lua` runs one action at a time with `hs.task` + `/usr/bin/curl`, from a
    module-level timer every 15 s. It runs only when `notetaker.upload` is true.
  - A spool size above 2 GB → `ui.warn("spool")`.

- [ ] Tests:
  - `test_create_first`
  - `test_put_in_seq_order`
  - `test_finalize_after_all_put`
  - `test_never_deletes_unconfirmed` (Review Focus 3: an `uploaded`-only chunk is never deleted)
  - `test_backoff_caps_900`
  - `test_spool_size_warning`
  - `test_resume_after_restart` (state is reloaded from disk)
- [ ] `contract-test.sh`:
  1. Starts `wrangler dev --local`.
  2. Replays the exact curl commands `uploader.lua` builds, on fixture chunks.
  3. Kills the server mid-way and restarts it.
  4. Checks that the final status has every chunk once.
- [ ] FAIL → implement → PASS → `isolation-lint` → commit.

### Task 3.9: 🔐 First deploy and end-to-end run

- [ ] 🔐 Ben approves each step, in this order:
  1. Create the D1 database and KV namespace in his Cloudflare account.
  2. `wrangler d1 migrations apply --remote`.
  3. `wrangler secret put GROQ_API_KEY`, read from the key file through a pipe and never printed.
     Also `DASHBOARD_PASSPHRASE` (Ben types it) and `SESSION_SECRET`.
  4. Insert the device-token hash.
  5. `wrangler deploy`.
- [ ] 🤖 Smoke: `/api/health`; ingest without a token returns 401; a fixture meeting goes through
      to `transcribed`.
- [ ] 🔐 Ben sets `notetaker.workerUrl` and turns on `notetaker.upload`.
- [ ] 👤 **Ben gate:** one real meeting goes from Mac to a stored transcript. The local chunks
      are deleted only afterwards.
- [ ] 🤖 R1–R4 pass.
- [ ] 🔐 Merge Stage 3 to `main`.

---

## Phase 4: AI analysis

### Task 4.1: Evidence validator

**Files:** `src/validate.ts`, `test/validate.test.ts`, `test/fixtures/analysis/*.json`

**Interfaces:**
- `validateInsights(raw: unknown, segments: {sid:string; text:string}[]): {insights: {kind:"summary"|"decision"; text:string; evidence:string[]}[]; tasks: {text:string; owner:string|null; owner_quote:string|null; due_text:string|null; evidence:string[]}[]; dropped: {item:unknown; reason:string}[]}`
- `normalize(s)`: NFC; remove niqqud and Hebrew punctuation (geresh/gershayim variants unified);
  lowercase Latin; collapse whitespace. A quote matches when `normalize(segmentText)` contains `normalize(quote)`.

- [ ] Tests:
  - `drops_no_evidence`
  - `drops_unknown_sid`
  - `owner_nulled_without_quote`
  - `owner_kept_with_verbatim_quote`
  - `due_nulled_when_quote_not_in_cited_segment`: the quote exists, but in an uncited segment.
  - `geresh_variants_match` (`צ׳קאאוט` vs `צ'קאאוט`)
  - `non_json_returns_all_dropped`
  - `extra_fields_ignored`
- [ ] FAIL → implement → PASS → commit.

### Task 4.2: Analyze job

**Files:** `src/analyze.ts`, `test/analyze.test.ts`

**Interfaces:**
- `estimateTokens(text: string): number` returns `ceil(chars / 2)`. Conservative for Hebrew; my call.
- `windowSegments(segs, maxTokens: number): Segment[][]` splits at segment boundaries with
  `maxTokens = 5000`, which leaves room under the 8K TPM limit for the prompt and output.
- `analyzeJob(env, job): Promise<JobResult>`:
  - Map: one `chat` per window, guarded by `reserve("llm_tokens")`. Results are persisted per
    window, so a quota wait resumes where it stopped.
  - Reduce: one `chat` merges the candidates.
  - Runs `validateInsights`, then publishes to `insights`/`tasks` in one D1 batch. A rerun
    replaces the previous output for that meeting.
  - Malformed JSON gets one retry with a "return valid JSON" message, then `retry error`.
  - Sets the meeting `ready` and enqueues `cleanup_audio`.
- The prompt text lives in `src/analyze.ts` as constants. It states: cite `[S#]` IDs; owner/due
  only when spoken, with an exact quote; output in the meeting's dominant language; quotes in the
  original language.

- [ ] Tests (mocked `chat`):
  - `windows_under_budget`
  - `map_reduce_called_expected_times`
  - `quota_mid_map_resumes_without_redoing_done_windows`
  - `malformed_json_retried_once_then_error`
  - `published_only_validated`
  - `planted_no_owner_task_has_null_owner`
  - `invented_deadline_stripped`
  - `rerun_replaces_not_duplicates`
- [ ] FAIL → implement → PASS → commit.

### Task 4.3: 👤 Ben's quality gate

- [ ] 🔐 Deploy T4.1–4.2.
- [ ] 👤 Ben reviews the notes from 3 real meetings for invented or meaning-changed items. Each
      finding becomes a fixture and a fix before passing.
- [ ] 🔐 Merge Stage 4 to `main`.

---

## Phase 5: Auto-detection

### Task 5.1: Detection decision (pure)

**Files:** `notetaker/mac/notetaker/detect.lua`, `notetaker/mac/tests/test_detect.lua`

**Interfaces:**
- `detect.decide(obs, mem, settings, now) → event|nil, mem2`
  - `obs = {chromeUrls={…}, zoomDesktopInMeeting=bool, micInUse=bool}`
  - The meeting key is the Meet code (`meet.google.com/abc-defg-hij`), the Zoom web path
    `app.zoom.us/wc/<id>`, or `"zoom-desktop"`.
  - Emits `detected{platform,key}` once a meeting key has been present **with** `micInUse` for 2
    consecutive polls.
  - Emits `meeting_ended` when the key disappears, or after `micInUse=false` for 60 s.
  - Never emits `detected` for a key in `mem.skipKeys` ("Don't record this meeting"), or when
    `settings.autoRecord` is false.

- [ ] Tests:
  - `meet_in_call_detected`
  - `lobby_mic_idle_not_detected`
  - `tab_closed_ends`
  - `mic_idle_60s_ends`, `mic_idle_59s_not_ended`
  - `skip_key_ignored`
  - `auto_off_never_detects`
  - `zoom_web_and_desktop`
  - `test_back_to_back_meetings_split` (Review Focus 4: key A ends, key B appears 20 s later →
    `meeting_ended` then a new `detected`)
  - `non_meet_google_url_ignored` (e.g. `meet.google.com/landing`)
- [ ] FAIL → implement → PASS → commit.

### Task 5.2: Observation, countdown and auto flow

**Files:** `notetaker/mac/notetaker/{observe,ui}.lua`, `notetaker.lua` (glue), `notetaker/mac/tests/test_autoflow.lua`

**Interfaces:**
- `observe.collect() → obs`:
  - Chrome URLs via `hs.osascript.applescript` (returns `{}` if Chrome isn't running; never launches it).
  - `micInUse` via `hs.audiodevice.defaultInputDevice():inUse()`.
  - Zoom desktop via `hs.application.find("zoom.us")` plus a "Zoom Meeting" window or a `CptHost` process.
  - Polls every 3 s from a module-level timer.
- Countdown: a 10 s `hs.alert`-style banner with a Cancel action via the menubar item and the
  hotkey. Modes: "auto" or "ask every time" (`notetaker.askEveryTime`, default false).
- Consent text, fixed:
  - he: `"שימו לב: הפגישה מוקלטת ומתומללת לצורך סיכום."`
  - en: `"Heads-up: this meeting is being recorded and transcribed for notes."`

- [ ] Tests (fake clock and fake `recorder_ctl`):
  - `cancel_during_countdown_recorder_never_started_spool_empty`
  - `ask_mode_waits_for_confirm`
  - `detected_then_ended_finalizes`
  - `disable_mid_countdown_cancels`
- [ ] FAIL → implement → PASS → `isolation-lint` → commit.

### Task 5.3: 🔐👤 Enable auto-record

- [ ] 🔐 Reinstall with `install.sh`. It refuses overwrite, so it uses `--upgrade`, which replaces
      only notetaker-owned files after a diff is shown.
- [ ] 🔐 Turn on `notetaker.autoRecord`.
- [ ] 👤 **Ben gate:**
  - Join a real Meet → the countdown appears within 10 s, then recording starts.
  - Leave → it stops within 60 s.
  - A lobby doesn't record.
  - Auto off → no recording (the spool is empty).
  - Zoom web works once.
- [ ] 🤖 R1–R4 pass. 🔐 Merge Stage 5.

---

## Phase 6: Dashboard (Dashboard lane)

### Task 6.1: Dashboard API

**Files:** `src/dashboardApi.ts`, `test/dashboardApi.test.ts`

**Interfaces** (all require a session; 401 otherwise):
- `POST /login {passphrase}` → `Set-Cookie`; `POST /logout`.
- `GET /api/ui/meetings?cursor=` → `{items:[{id,title,platform,started_at,duration_ms,status,resume_at|null}], next}`
- `GET /api/ui/meetings/:id` → `{meeting, insights[], tasks[], segments[], audio_available:boolean}`
- `GET /api/ui/meetings/:id/audio/:track/:seq` streams the audio (404 after cleanup).
- `POST /api/ui/meetings/:id/retry`, `POST /api/ui/meetings/:id/reprocess {language:"he"|"en"|"auto"}`
- `GET /api/ui/tasks?open=1&owner=` and `PATCH /api/ui/tasks/:id {done:boolean}`
- `GET /api/ui/search?q=` → `{hits:[{meeting_id, sid, snippet}]}` (min 2 chars)
- `GET /api/ui/status` → `{groq:{audio_sec_today, audio_sec_limit, tokens_today, tokens_limit}, queue:{pending, waiting_quota, failed}, storage:{audio_bytes, limit_bytes:1073741824}}`

- [ ] Tests (fixture DB):
  - `all_routes_401_without_session`
  - `list_shows_waiting_quota_with_resume_at`
  - `retry_requeues_failed`
  - `reprocess_sets_language_and_requeues`
  - `task_done_persists`
  - `search_prefixed_hebrew`
  - `test_search_mixed_language` (Review Focus 5: both `"דיפלוי"` and `"production"` find the
    mixed fixture segment)
  - `audio_404_after_cleanup`
  - `status_numbers_match_ledger`
- [ ] FAIL → implement → PASS → commit.

### Task 6.2: Dashboard UI (plain HTML/JS)

**Files:** `public/index.html`, `public/app.js`, `public/style.css`, `test/ui-smoke.test.ts`

- Pages are hash routes: `#/meetings`, `#/m/<id>`, `#/tasks`, `#/search?q=`, plus a login form.
- `<html lang="he" dir="rtl">`. Every transcript and insight paragraph has `dir="auto"`.
- Evidence chips (`S12`) scroll to `#S12` and highlight it. There's a ▶ for audio while it's available.
- The status strip is always visible. Meetings that are `waiting_quota` show
  "ממתין למכסה חינמית — ימשיך בערך ב-HH:MM".

- [ ] Tests: `ui-smoke.test.ts` fetches `/` and checks:
  - the HTML has `dir="rtl"`;
  - `app.js` is served;
  - each API call `app.js` makes is one of the routes in T6.1 (static scan of its `fetch("/api/ui/…")` strings).
- [ ] FAIL → implement → PASS → commit.

### Task 6.3: 🔐👤 Deploy dashboard

- [ ] 🔐 Deploy.
- [ ] 👤 **Ben gate:**
  - Log in.
  - Open real meetings.
  - Evidence chips jump to the right line.
  - Search Hebrew and English.
  - Mark a task done.
  - Check that the RTL/mixed text reads correctly.
- [ ] 🔐 Merge Stage 6.

---

## Phase 7: Hardening and real use

### Task 7.1: Sleep, restart and recovery

**Files:** `notetaker.lua` (an `hs.caffeinate.watcher` hook), `notetaker/mac/tests/test_recovery.lua`

- On `systemWillSleep`: stop the recorder and finalize with `status="incomplete"` if the meeting
  is still detected afterwards. On wake, detection may start a new meeting.
- [ ] Tests:
  - `sleep_event_stops_and_finalizes`
  - `wake_does_not_resume_old_meeting`
  - `restart_with_pending_spool_resumes_upload` (reuses `uploader_core` state from disk)
- [ ] FAIL → implement → PASS → commit.
- [ ] 🔐 Reinstall with `--upgrade`; R1–R4 pass.

### Task 7.2: 👤 One week of real use

- [ ] 👤 Ben uses it for a week.
- [ ] 🤖 A daily check (run on request, not scheduled) lists: meetings detected vs meetings in the
      dashboard, failed jobs, quota waits, and spool size.
- [ ] 👤 **Ben gate:** no lost meetings, no unexpected recordings, quota status always understandable.
- [ ] 🔐 The final merge to `main`. Update `notetaker/README.md`, and add a short "Meeting
      notetaker" section at the **end** of the root `README.md` (new section only; existing
      sections untouched).

---

## Final acceptance (Ben's five requirements → where they're proven)

| Requirement | 🤖 Proven by | 👤 Confirmed by |
|---|---|---|
| Dictation works without regression | R1–R3 after every install, `repo-no-touch.sh` on every branch | T1.5, T5.3, T7.2 |
| Meeting recording works independently of dictation | R4, test-recorder suite | T1.5 |
| Cloud can't disrupt existing workflows | Dictation code has no cloud path; `isolation-lint`; `upload=false` leaves dictation untouched (R1–R3) | T3.9 |
| Existing settings and data intact | `verify.sh` (init.lua, keys, recordings, hotkeys), installer `keys_untouched`, `refuses_overwrite` | T1.5 |
| Can be disabled or rolled back | Flags default off, `uninstall_restores_init`, `wire_init_idempotent` | Rollback drill in T1.5 |
