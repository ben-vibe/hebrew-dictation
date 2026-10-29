# Meeting Notetaker — Design

Date: 2026-10-29 · Status: **awaiting Ben's approval** · Repo: `hebrew-dictation`

Labels: **[Ben]** = decided by Ben. **[call]** = Claude's call, open to override.
Unlabeled statements are facts about the existing project or external services, checked on 2026-10-29.

---

## 1. Intent

Ben wants his Zoom and Google Meet meetings captured automatically and transcribed in Hebrew,
English, and mixed speech. Each meeting becomes a structured record: summary, decisions, and
action items with owners and deadlines. All of it is stored in the cloud and browsable in a
simple web dashboard. The MVP costs **nothing**. **[Ben]**

The MVP records **on Ben's Mac**: nothing joins the call. Later, an **independent meeting bot**
will join meetings Ben isn't in. The bot must plug into the same pipeline without rebuilding
transcription, AI processing, storage, or the dashboard. **[Ben]**

REA (`morluto/rea`, a reverse-engineering MCP) is a later research aid for studying how existing
notetakers solve specific problems. It is not a dependency. **[Ben]**

## 2. Goals, non-goals, anti-goals

**Goals (MVP)** **[Ben]**
- Auto-detect Zoom and Google Meet meetings and start recording. Show a visible indicator, with
  easy start / pause / stop / disable controls.
- Capture Ben's mic and the other participants clearly, as separate tracks.
- Transcribe Hebrew, English, and mixed meetings, preserving meaning and reusing the existing
  vocabulary prompt.
- Summary, key decisions, and action items. Owners and deadlines **only when explicitly said**.
  Every item links to transcript evidence.
- Survive long meetings, API limits, interrupted uploads, and processing failures.
- Dashboard: meeting history, searchable transcripts, summaries, actionable tasks, and
  processing status.
- As simple as possible, reusing existing code. Automated tests wherever practical.

**Non-goals (MVP)**
- The meeting bot itself. Only its seam is built now.
- Telling individual remote speakers apart. Labels are "Ben" and "Others", from the two tracks. **[call]**
- Calendar, sharing, and integrations (Slack, Notion…). **[call]**
- Meet in Safari, Arc, or Firefox. Chrome only, because that's what's installed. **[call]**
- Live captions during the meeting.

**Anti-goals: failure even if it "works"**
- **Invented content**: a task, owner, deadline, or decision nobody said. Project history shows
  an LLM cleanup pass silently changed "צ׳קאאוט" into "בדיקות", which is worse than no output.
- Recording without Ben knowing, or recording while auto-record is disabled.
- Losing a meeting silently. Every failure must be visible and retryable.
- Degrading the existing fn+Shift dictation, whose release-to-paste time of about 0.6 s is measured.
- **Any charge, ever, without Ben explicitly turning on paid processing.** **[Ben]**
- Touching Ben's two existing, unrelated Supabase projects. **[Ben]**

## 3. Constraints and facts

- Mac: macOS 26.5.1, Hammerspoon and Chrome installed. The **Zoom desktop app isn't installed**,
  so we detect both Zoom desktop and the Zoom web client (`app.zoom.us/wc/…`).
- **Groq** (console.groq.com/docs):
  - `whisper-large-v3` uploads are limited to 25 MB on the free tier. `verbose_json` returns
    segment timestamps plus `no_speech_prob`. Requests under 10 s are billed as 10 s.
  - Published base limits:
    - Whisper: 20 RPM, 7,200 audio-seconds per hour, 28,800 per day.
    - `openai/gpt-oss-120b`: 30 RPM, 8K TPM, 200K TPD.
  - Ben's real free-tier numbers are read from his console in Stage 0.
  - Paid price, for later reference: $0.111 per audio-hour.
- **Supabase**: Ben's account already uses its 2 free active projects. A third free project isn't
  possible, and Ben ruled out pausing a project or upgrading. **[Ben]**
- **Cloudflare free plan** (developers.cloudflare.com, chosen in §4.1). **No payment method on file.**
  - Workers: 100K requests/day; 10 ms **CPU** per request or cron run (time spent waiting on
    `fetch` doesn't count); cron runs can last up to 15 min; 5 cron triggers.
  - D1 (SQLite): 500 MB per database, 10 databases; FTS5 is supported. Daily row read/write
    limits are **hard-enforced** (queries error, never bill) as of 2026-09-01.
  - KV: 1 GB storage, 1,000 writes/day, 100K reads/day, values up to 25 MiB.
  - **R2 is not used: activating it requires a payment method.**
- **Live install ≠ repo (baseline, checked 2026-10-29).** The running dictation is **inlined in
  `~/.hammerspoon/init.lua`**. `~/.hammerspoon/dictation.lua` doesn't exist.
  - That copy differs from the repo's `dictation.lua`: `KEEP_RECORDINGS = true`, so 20 recordings
    sit in `~/.hammerspoon/recordings`.
  - It also contains an unrelated personal launcher on Ctrl+Cmd+Y.
  - Hotkeys in use: fn, fn+Shift, Ctrl+Cmd+R, Ctrl+Cmd+Y.
  - Dictation globals in use: `_G.dictationLog`, `_G.lastRecording`, `_G.releasedAt`,
    `_G.startRecording`, `_G.stopRecordingAndTranscribe`, `_G.startPriming`, `_G.cancelPriming`,
    `_G.isPrimedOrRecording`, `_G.dictationTap`.
  - Temp file: `/tmp/hs-dictation.wav`.
  - **The repo is not the source of truth for the live product. `init.lua` is.**
- Dev tooling present: `swiftc`, Node 20. Not present: `lua`, `wrangler`.
- Existing project findings that bind this design:
  - Pinning `language=he` beat auto-detect on real Hebrew.
  - `VOCAB_PROMPT` fixes tech-Hebrew mistakes at zero cost.
  - Whisper invents text from silence ("Thank you").
  - Hammerspoon timers and callbacks must be held at module scope or they get garbage collected.

## 4. Architecture

```
 SOURCES (replaceable)                  PIPELINE (shared, source-agnostic)                 VIEW
┌───────────────────────┐   ingest    ┌─────────────────────────────────────────┐
│ Mac recorder (MVP)    │──contract──▶│ One Cloudflare Worker ("notetaker")     │
│ Hammerspoon detect +  │   (HTTPS,   │  • ingest API                           │   ┌───────────┐
│ Swift capture →       │   device    │  • job runner (cron each minute)        │──▶│ Dashboard │
│ local spool → upload  │   token)    │  • dashboard + its API (same Worker)    │   │ (served by│
├───────────────────────┤             │ KV: audio chunks   D1: everything else  │   │ the Worker)│
│ Meeting bot (later)   │──same──────▶│ Groq: Whisper + LLM (free tier)         │   └───────────┘
└───────────────────────┘  contract   └─────────────────────────────────────────┘
```

Rules that keep the bot pluggable **[Ben]**:
- A source does three things: create a meeting, upload audio chunks per track, and finalize the
  meeting. It never calls Groq and never writes transcripts.
- The pipeline knows the source only as a display label.
- A track is a labelled audio stream: `self` and `others` from the Mac, `speaker:<name>` from
  the bot later. Transcript speaker names come from the track labels.

### 4.1 Cloud platform: recommendation

**Recommendation: a new, separate Cloudflare account on the free plan, with no payment method.**
One Worker serves the ingest API, job runner, and dashboard. D1 holds data and full-text search.
KV holds audio. **[call, pending Ben's approval]**

Options compared:

| Option | Isolated from existing projects | Database + file storage + jobs + hosting | Can it ever charge? | Verdict |
|---|---|---|---|---|
| **Cloudflare free (Workers + D1 + KV)** | Fully separate account | All in one place | No: no card on file, limits hard-fail | **Recommended** |
| Reuse a Supabase project (separate `notetaker` schema + bucket) | Partial: see below | All in one place | No | Possible, not recommended |
| Neon / Turso (DB) + another vendor for files + another for hosting | Yes | Split across 2–3 vendors | Depends | More moving parts |
| Firebase Spark | Yes | Storage now needs the paid Blaze plan | Yes | Rejected |
| Cloudflare R2 for audio | Yes | Yes | Card required to activate | Rejected |

Why reusing Supabase isn't recommended, even though it could be done safely:
- **Login is shared.** Ben's notetaker login would become a user of the other
  app's auth. It would show up in that app's user list, and that app's sign-up rules would apply to it.
- **Quota is shared.** The 500 MB database and 1 GB storage are shared with the other app. A busy
  meeting month could break the other app, and the other way round.
- **Migrations interleave.** Both apps would write to one migration history.

If Ben prefers Supabase anyway, isolation would mean a dedicated `notetaker` schema not exposed to
the other app's API, a private bucket with its own policies, migrations prefixed `nt_`, and
service access only through notetaker Edge Functions. None of it is applied without Ben's approval.

Trade-offs of Cloudflare, accepted:
- **10 ms CPU per request.** Fine, because the work is mostly waiting on Groq, but measured in Stage 0.
- **SQLite instead of Postgres.**
- **KV's 1,000 writes/day.** A meeting-hour is about 24 chunk writes, so this isn't a bottleneck.
- **Ben needs a Cloudflare account.** Free, email signup.

### 4.2 Ingest contract (the seam)

Every write is idempotent, so retries are always safe. **[call]**

1. `POST /api/meetings`
   - Input: `client_meeting_id` (a UUID from the source, which makes this idempotent), `source`
     (`mac` | `bot`), `platform` (`zoom` | `meet` | `other`), `title?`, `started_at`,
     `language_hint?`, `tracks: [{track_id, label}]`.
   - Returns `meeting_id`.
2. `PUT /api/meetings/:id/chunks/:track/:seq`
   - Body: the audio. Headers: `offset_ms`, `duration_ms`, `peak_db`, `sha256`.
   - Stored in KV, registered in D1.
   - Unique on `(meeting, track, seq)`. A same-hash re-upload is a no-op; a different hash is rejected.
3. `POST /api/meetings/:id/finalize`
   - Input: `{ended_at, last_seq_per_track}`.
   - Processing finishes once every declared chunk is present.
   - If chunks are still missing after 24 h, the meeting becomes `incomplete`, is processed with
     what exists, and the dashboard shows the gaps.
4. `GET /api/meetings/:id/chunks/status` tells the source which chunks have been **transcribed**.
   The Mac deletes local copies only after that. See §4.4.

**Auth [call]:**
- **Ingest:** the installer generates a random device token and saves it to
  `~/.config/notetaker-device-token` with mode 600, the same convention as the Groq key. D1
  stores only its hash in `device_tokens`. Revoking = deleting the row. The bot gets its own row.
- **Dashboard:** a single-user passphrase, stored as a Worker secret, exchanged for an HttpOnly,
  Secure session cookie.
  - No email service and no third-party auth.
  - Simpler than magic links, and enough for one user.

### 4.3 Mac source

Two parts, split so recording never waits on the network.

**a) `meeting-recorder`**: a new Swift helper, kept separate from `dictation-recorder` so
dictation can't regress. It is modelled on `dictation-recorder.swift`: the READY line, clean
finalization on SIGTERM, and the timing env var.
- **Mic track:** AVAudioEngine input with voice processing (echo cancellation), so remote voices
  coming out of the speakers don't leak into the `self` track.
- **Others track:** a Core Audio process tap on the meeting app.
  - Zoom desktop: Zoom's process, which is meeting audio only.
  - Chrome (Meet / Zoom web): **all of Chrome's audio**, so a YouTube tab playing during a call
    gets captured too. Accepted as a known MVP limitation. The tap targets Chrome's audio helper
    process(es).
  - Fallback: a system-wide output tap. **[call]**
- **Shared clock:** both tracks run on one clock. Each chunk carries `offset_ms` from the meeting start.
- **Format:** AAC `.m4a`, 16 kHz mono, ~32 kbps. That's about 1.2 MB per 5-minute chunk, well
  under Groq's 25 MB and KV's 25 MiB. **[call]**
- **Chunking:** chunks roll about every 5 min, cut at the quietest point within ±15 s so words
  aren't split. Each chunk records its `peak_db`.
- **Control and output:** start / pause / resume / stop are sent over stdin. Chunks are written to
  `~/Library/Application Support/meeting-notes/spool/<client_meeting_id>/`.
- **Permissions risk:** a CLI helper launched by Hammerspoon may not be able to get the "System
  Audio Recording" permission. Stage 1 spikes this first. If it fails, `install.sh` builds the
  helper into a minimal `.app` with `swiftc`: fixed bundle ID, `NSAudioCaptureUsageDescription`,
  and **ad-hoc signing** (`codesign -s -`). No Apple Developer account and no notarization. **[call]**

**b) Controller: `notetaker.lua`**, loaded by Hammerspoon next to `dictation.lua`. **[Ben: reuse existing infra]**
- **Detection** polls every ~3 s. The decision logic is a pure Lua function so it can be unit
  tested outside Hammerspoon.
  - Meet: a Chrome tab URL matching `meet.google.com/xxx-xxxx-xxx` (read via AppleScript)
    **and** the mic in use. A lobby or an idle open tab therefore doesn't trigger.
  - Zoom desktop: the `CptHost` process or a "Zoom Meeting" window.
  - Zoom web: an `app.zoom.us/wc/` tab plus the mic in use.
  - End: the meeting tab or window is gone, or the mic has been idle for 60 s → stop and finalize.
- **Auto-start [call]:**
  - A 10-second banner ("Recording in 10s — Cancel") appears, then recording starts.
  - While recording, a red menubar item (`hs.menubar`) shows elapsed time plus: Pause / Stop /
    Don't record this meeting / Disable auto-record.
  - A hotkey toggles pause. A setting switches between "auto" (default) and "ask every time".
- **Consent:** a one-click "copy consent notice" (Hebrew + English) to paste into the meeting
  chat. What to tell participants, and what the law requires, is Ben's call. The tool makes it
  easy; it doesn't decide.
- **Uploader:** a separate loop that drains the spool.
  - Uses `hs.task` + `curl`, the same pattern as dictation, with timers held at module scope.
  - Exponential backoff. Survives sleep and reboot, because the spool is on disk.
- **Permissions:** Microphone, System Audio Recording, and Chrome Automation (to read tab URLs).

### 4.4 Pipeline: one Worker, D1 jobs, free-only Groq

**Jobs.**
- A `jobs` table in D1 (`kind`, `meeting_id`, `ref`, `state`, `attempts`, `not_before`, `last_error`).
- Each upload starts processing immediately (`ctx.waitUntil`). A cron trigger runs every minute
  and picks up anything pending or due, so nothing gets stuck.
- One unit of work per job keeps each run inside the CPU limit. **[call]**

**Free-only by construction [Ben].**
- A `groq_usage` ledger tracks audio-seconds, requests, and tokens per rolling hour and per day.
- Before every Groq call, the worker checks the ledger against the free limits recorded in
  `config` in Stage 0.
- When the allowance is used up, or Groq returns 429, the job gets `not_before` = the next window
  (taken from `retry-after` when present) and state `waiting_quota`. Waiting is never counted as a
  failure.
- Paid processing is a `config.paid_processing_enabled` flag, **default false**. While false, the
  ledger never lets usage go past the free limits.
- Ben's Groq account must have no billing method, checked in Stage 0. That way, even a bug can't
  create charges.
- Turning on paid processing later is a deliberate two-step action by Ben: add billing in Groq,
  then flip the flag.

**KV for audio: checked against the docs, then verified by a Stage 0 spike before we commit to it [Ben].**

| KV property (free plan) | Value | Our need | OK? |
|---|---|---|---|
| Max value size | 25 MiB | ~1.2 MB per chunk | ✅ ~20× headroom |
| Writes | 1,000/day (different keys) | ~24 per meeting-hour | ✅ ~40 meeting-hours/day |
| Deletes | 1,000/day | ~24 per meeting-hour, spread out by cron | ✅ |
| Reads | 100,000/day | ~2 per chunk | ✅ |
| Storage | 1 GB | ~28 MB per meeting-hour, held ≤7 days after processing | ✅ ~35 hours buffered |
| Over-limit behavior | That operation type fails with an error until 00:00 UTC; no charge on the free plan | Treat as `waiting_quota` | ✅ |
| **Consistency** | **Eventually consistent; read-after-write isn't guaranteed (up to ~60 s)** | The job reads the chunk right after upload | ⚠️ Handled by design |

How the design handles KV's weak spots:
- **D1 is the source of truth** for which chunks exist.
- A KV "not found" for a registered chunk is a **retry after 60 s**, never a failure.
- Keys are never rewritten (one key per chunk).
- Each chunk also gets a 30-day `expirationTtl` as a backstop. That's safe, because the Mac keeps
  its local copy until the chunk is transcribed and re-uploads anything KV has lost.

**Stage 0 spike, which must pass before KV is committed to:**
1. Write 30 chunks of ~1.2 MB.
2. Read them from a separate cron run, and measure miss rate and delay.
3. Confirm the TTL works.
4. Confirm the usage counters in the dashboard.

**Fallback if the spike fails:** store chunks as BLOB rows in a separate D1 database (`notetaker_audio`).
- A 1.2 MB chunk fits D1's 2 MB row limit, and D1 is strongly consistent.
- Costs 500 MB per database. More audio databases can be added (10 per account).

**Recordings are safe until processed [Ben].**
- **Two copies:** the Mac keeps each local chunk until the server reports that chunk
  *transcribed*, not just uploaded.
- **Cloud audio** is deleted 7 days after the meeting's processing completes. Until then it can be
  replayed and reprocessed. **[call]**
- **Storage budget:** KV's 1 GB fits about 35 meeting-hours of queued audio. The dashboard shows
  storage use and warns at 70%.

**Failures.** After 5 non-quota failures a job becomes `failed`. The dashboard shows the error
and a Retry button.

**Transcribe (one job per chunk).**
- **Silence skipping is off until proven safe [Ben].** `config.silence_skip_db` defaults to null, so every chunk goes to Whisper. A threshold is enabled only after Stage 2 shows, on Ben's real recordings, that quiet voices and Hebrew speech are never in a skipped chunk.
- Call Groq `whisper-large-v3` with `verbose_json` and `VOCAB_PROMPT`. The prompt is ported from
  `dictation.lua` into `config`, with English terms added.
- Drop segments with high `no_speech_prob` and the known silence hallucinations.
- Store segments with absolute time and the track's speaker label.
- **Language strategy is decided by measurement in Stage 2.** Candidates:
  - (A) pin `he` and add English terms to the vocab prompt;
  - (B) auto-detect per chunk;
  - (C) detect on the first 30 s, then pin.
  - Default until measured: (A), per the existing finding.
  - Per-meeting override (he / en / auto) plus "Reprocess" in the dashboard.

**Assemble.** Once every chunk is transcribed, merge both tracks by time into one transcript
with stable IDs `S1…Sn`.

**Analyze, with no invention by construction.**
- **Input:** segments formatted as `[S12 | Others | 14:03] text`.
- **Model:** Groq `openai/gpt-oss-120b`, compared with one alternative in Stage 2.
- **Long meetings: map-reduce.** Windows of about 10 minutes, sized under the TPM limit,
  extract candidates. A reduce step merges them and writes the summary.
- **Strict JSON output:**
  - `summary[] {text, evidence[]}`
  - `decisions[] {text, evidence[]}`
  - `action_items[] {task, owner|null, owner_quote|null, due|null, due_quote|null, evidence[]}`
- **Validation runs after the model, and what passes is what gets published:**
  - Drop any item with no evidence, or with an evidence ID that doesn't exist.
  - Set `owner`/`due` to null unless their quote appears in a cited segment (normalized match).
  - `due` stays the spoken phrase ("עד יום חמישי"). It becomes a date only when that's unambiguous.
  - Validation drops are logged per meeting.
- **Language:** output follows the meeting's dominant language. Quotes stay in the original.

### 4.5 Data model (D1 / SQLite)

- `meetings` (id, client_meeting_id unique, source, platform, title, started_at, ended_at,
  status, language_hint, error)
- `tracks` (meeting_id, track_id, label)
- `chunks` (meeting_id, track_id, seq, offset_ms, duration_ms, peak_db, sha256, kv_key, state)
- `segments` (meeting_id, sid, track_id, speaker, start_ms, end_ms, text, lang) + `segments_fts`
  (FTS5, trigram tokenizer so Hebrew prefixes like ה/ו/ב/ל/מ/ש still match). Fallback if trigram
  isn't available in D1: `LIKE` search, which is fine at single-user scale.
- `insights` (meeting_id, kind, text, evidence JSON)
- `tasks` (meeting_id, text, owner, owner_quote, due_text, due_date, evidence JSON, done, done_at)
- `jobs`, `groq_usage`, `config`, `device_tokens`

Migrations are plain numbered SQL files applied with `wrangler d1 migrations`.

### 4.6 Dashboard

Plain HTML + a small amount of JavaScript, served by the same Worker as static assets. No build
step and no framework. RTL-first, with mixed-direction text handled per paragraph. **[call: simplest]**

- **Meetings:** list with date, title, platform, duration, and status: processing, **waiting for
  free quota (resumes ~HH:MM)**, ready, incomplete, or failed + Retry.
- **Meeting page:**
  - Summary, decisions, and tasks with evidence chips that jump to and highlight the cited segment.
  - Audio replay of the cited moment while the audio is still kept.
  - Full transcript labelled Ben / Others.
  - Language override + Reprocess.
- **Tasks:** open tasks across all meetings, with mark-done, an owner filter, and links back to evidence.
- **Search:** across transcripts and insights.
- **Status strip:** today's Groq usage against the free limits, queue length, and KV storage use.

### 4.7 Additive integration and protecting dictation [Ben: highest priority]

The notetaker is a **new module** next to dictation. It is not a rewrite.

**Files dictation owns. The notetaker never modifies them:**
- `~/.hammerspoon/init.lua` (one exception below)
- `~/.hammerspoon/bin/dictation-recorder*`
- `~/.hammerspoon/recordings/`
- `~/.config/dictation-groq-key`
- `~/.config/dictation-elevenlabs-key`
- repo `dictation.lua`, `bin/dictation-recorder.swift`, `bin/compare-transcribers.sh`,
  `install.sh`, `README.md`'s existing sections

**The single integration point.** One line appended to the end of `init.lua`, after a timestamped backup:

```lua
pcall(require, "notetaker") -- meeting notetaker; delete this line to remove it completely
```

- Dictation's code runs first.
- `pcall` means a notetaker load error can't stop dictation from loading.
- Appending the line is a 🔐 approval step, done once.

**Isolation rules.** Each one is enforced by an automated "no-touch" test:
- Every notetaker file lives in `~/.hammerspoon/notetaker/` and `~/.hammerspoon/notetaker.lua`.
  Settings use `hs.settings` keys prefixed `notetaker.`.
- Every global goes under `_G.notetaker` only. No dictation global name is read or written.
- No `flagsChanged` eventtap, no use of fn/Shift, and none of the hotkeys above. Notetaker hotkeys
  are chosen from free combos and checked against `hs.hotkey.getHotkeys()` at load.
- Its own recorder binary (`meeting-recorder`), its own spool, and its own temp paths. It never
  touches `/tmp/hs-dictation.wav` or kills a process it didn't start.
- **Reads** the Groq key file, and only to copy it into the Worker secret, a 🔐 approval step.
  Never writes it.
- **Shared resource: the microphone.** macOS allows several readers at once, but voice
  processing (echo cancellation) can change the input device's behavior and duck other audio.
  - So echo cancellation is behind a flag, **off by default**, and is only turned on after the
    Stage 1 "dictation during meeting recording" test passes.

**Feature flags (kill switches)**, all defaulting to the safe state:

| Flag | Where | Default | Effect when off |
|---|---|---|---|
| `notetaker.enabled` | `hs.settings` (+ menubar toggle) | **off** until Ben turns it on | Module loads, shows "off" in the menubar, and does nothing else |
| `notetaker.autoRecord` | `hs.settings` | **off** at first (manual only) | No detection-triggered recording |
| `notetaker.upload` | `hs.settings` | off until Stage 3 approval | Chunks stay in the local spool |
| `notetaker.echoCancel` | `hs.settings` | off | Plain mic capture |
| `paid_processing_enabled` | Worker `config` | **false** | No Groq call beyond the free limits |
| `ingest_enabled` | Worker `config` | true | Uploads refused (the Mac keeps its spool) |

**Rollback, from lightest to heaviest:**
1. Flip `notetaker.enabled` off in the menubar.
2. Delete the `pcall(require…)` line and reload (Ctrl+Cmd+R). Dictation is byte-for-byte what it was.
3. Run `notetaker/uninstall.sh`. It lists, then removes, only notetaker files, after confirmation,
   and keeps the spool unless asked.
4. Cloud: the Worker lives in its own Cloudflare account and nothing else depends on it.
5. Git: notetaker merges as separate commits that touch no dictation file, so `git revert` is clean.

**Installer.** A new `notetaker/install.sh`; the existing `install.sh` is unchanged.
- It refuses to overwrite any existing file. It only creates files under the notetaker paths and
  `~/.config/notetaker-device-token`.
- It prints every action before it does it, and supports `--dry-run`.

### 4.8 Future bot (designed for, not built)

Another source implementing §4.2, with per-speaker tracks where the platform exposes them.
Options to research later, possibly with REA: a hosted bot API (paid per hour), self-hosted
headless Chrome for Meet, or the Zoom Meeting SDK. The pipeline and dashboard shouldn't change
beyond showing `source = bot`.

## 5. What we reuse

| Existing piece | Reused how |
|---|---|
| Groq key `~/.config/dictation-groq-key` | Mac side; copied once into a Worker secret |
| `whisper-large-v3` + `VOCAB_PROMPT` | Same model; prompt moved to `config`, English terms added |
| Language finding (`he` > auto) | Starting default and the Stage 2 hypothesis |
| "No LLM cleanup" finding | Basis of the evidence-validation rules |
| `dictation-recorder.swift` | Template for `meeting-recorder` (READY, SIGTERM finalize, timing) |
| Hammerspoon, `hs.task`+`curl`, module-scope timer lesson | Controller, menubar, uploader |
| `install.sh` | Extended: build the new helper, install `notetaker.lua`, create the device token |
| `compare-transcribers.sh` | Basis of the Stage 2 evaluation script |
| macOS `say` with a Hebrew voice | Generates Hebrew/English/mixed test audio for automated tests |

## 6. Costs and limits

**MVP cost: $0.** No payment method exists on Cloudflare or Groq, so nothing can be charged. **[Ben]**

| Resource | Free limit | One meeting-hour uses | When exceeded |
|---|---|---|---|
| Groq Whisper | ~2 audio-hours/hour, ~8/day (confirm in Stage 0) | Up to 2 audio-hours (two tracks), less after silence skipping | Queued; resumes next window |
| Groq LLM | ~200K tokens/day | ~30–50K tokens (Hebrew is token-heavy) | Queued; resumes next day |
| Cloudflare KV | 1 GB, 1K writes/day | ~28 MB, ~24 writes | Warn at 70%; audio auto-deleted 7 days after processing |
| Cloudflare D1 | 500 MB DB; daily row limits | <1 MB | Hard error, never a bill; retried next day |
| Workers | 100K requests/day | A few hundred | Not a realistic limit |

**Limitation Ben accepts:** on a heavy meeting day, notes may finish the next day. The dashboard
always shows why something is waiting and when it will resume.

## 7. Main risks and trade-offs

1. **System-audio permission for a Hammerspoon-launched helper.** Might force a small `.app`.
   Spiked first in Stage 1.
2. **Mixed Hebrew/English accuracy.** Whisper transcribes one language per request, and
   auto-detect hurt Hebrew before. Mitigation: measure on Ben's real meetings (Stage 2), plus a
   per-meeting override and Reprocess.
3. **Echo without headphones** can duplicate lines. Mitigation: voice processing; measured with
   and without headphones; a dedup pass if needed.
4. **Free LLM tokens vs long Hebrew meetings.** Mitigation: map-reduce plus the queue.
   Worst case is delay, not cost.
5. **Workers' 10 ms CPU limit.** Mitigation: one unit of work per job; measured in Stage 0.
   If exceeded, the heaviest step moves to a cron run.
6. **Detection mistakes** (lobby, open tab, another Chrome profile). Mitigation: require the mic
   to be in use, plus the 10-second cancellable countdown.
7. **Trade-off: cloud vs on-Mac processing.** On-Mac would be simpler today, but the bot needs
   the cloud pipeline. Chosen: cloud. **[Ben: sources separate from processing]**
8. **Trade-off: Hammerspoon vs a native menubar app.** Hammerspoon reuses what exists. Risk 1 may
   force part of it native.

## 8. Implementation plan

### 8.1 How work is run and verified [Ben]

- **Orchestration:** work runs as tasks through `superset:orchestrate`, each in its own workspace.
- **Builder and verifier:** every task has a **builder** worker and a separate **verifier** worker
  that didn't write the code. The verifier:
  1. Checks out the branch fresh and runs all automated tests itself; it never trusts the
     builder's report.
  2. Reads the diff against this document and the stage's acceptance criteria.
  3. Actively tries to break it: edge cases, retries, idempotency.
  4. Reports pass/fail with command output. A failure goes back to the builder.
- **Merging:** the coordinator (Claude) merges only after the verifier passes.
- **Parallel lanes** once Stage 0 is done and §4.2 + §4.5 are frozen:
  - **Mac lane:** 1 → 5
  - **Cloud lane:** 3 → 4
  - **Dashboard lane:** 6, built against fixture data

  Stage 2 waits for Ben's recordings. Stage 7 waits for everything.
- **Test reports keep two separate sections,** never mixed:
  - **🤖 Automated:** checks run by workers and re-run by a verifier, with the command and output.
  - **👤 Ben gate:** exact steps for Ben, what to look for, and a pass/fail box for him to tick.

  A stage counts as done only when both sections pass. Automated parts of later stages may proceed
  while a Ben gate is pending, but nothing ships to daily use until its Ben gates pass.
- **Test tools [call]:**
  - **Worker:** Vitest with Cloudflare's Workers test pool (local D1 + KV), with Groq mocked by
    recorded fixtures plus one opt-in live smoke test.
  - **Lua detection logic:** plain `lua` unit tests.
  - **Swift recorder:** scripted tests that play generated `say` audio through `afplay` and tap
    that process.
- **Changes:** each stage is one PR-sized branch, merged to `main` after verification.

### 8.2 Stages and acceptance criteria

The task-level execution plan, with dependencies, parallel lanes, approval points and
regression checks, is in `docs/superpowers/plans/2026-10-29-meeting-notetaker.md`.

**Stage 0: Set up and verify assumptions**
- Ben creates a free Cloudflare account (no payment method) and reads his Groq free-tier limits.
  The Worker skeleton is deployed.
- 🤖 The skeleton deploys and `GET /api/health` responds.
- 🤖 D1 accepts an FTS5 trigram table, or the `LIKE` fallback is recorded.
- 🤖 A synthetic Groq call through the Worker stays under 10 ms CPU.
- 👤 Ben gate: Cloudflare has no payment method. The Groq account has no billing method. Real
  free limits are entered in `config` and §6.

**Stage 1: Mac capture**
- `meeting-recorder` (both tracks, chunking, spool, controls), a manual hotkey, and the menubar
  indicator. No detection and no cloud yet.
- 🤖 The permission spike resolves (CLI helper or `.app`), and the outcome is recorded.
- 🤖 A scripted test plays known `say` audio through `afplay` and taps it. The `others` chunks
  contain it, every chunk is <25 MB, offsets are continuous, and pause leaves a gap.
- 🤖 Chunk boundaries don't fall inside speech in the test audio.
- 🤖 Dictation latency is measured before and after, and is unchanged.
- 👤 Ben gate: a 30-minute real Meet call, once with headphones and once without. Both tracks are
  clear, there's no remote voice in `self` with headphones, and the indicator is visible
  throughout.

**Stage 2: Transcription and model evaluation**
- A local script runs language strategies A/B/C, plus 2 LLMs on the analysis prompt.
- 🤖 The script runs on generated Hebrew/English/mixed audio and produces a comparison table.
- 👤 Ben gate: Ben supplies one real Hebrew, one English, and one mixed meeting, reads the table,
  and picks the strategy and model. The decision is recorded in `docs/`.

**Stage 3: Cloud backbone**
- D1 schema, ingest API, KV audio, jobs, free-quota ledger, transcribe + assemble, and the Mac uploader.
- 🤖 A fixture meeting uploaded by the real uploader becomes a merged Ben/Others transcript with
  no manual steps.
- 🤖 The network is cut mid-upload, then restored. All chunks arrive, with no duplicate segments.
- 🤖 Re-uploading a chunk or rerunning a job never duplicates content. A different hash on the
  same seq is rejected.
- 🤖 A simulated quota exhaustion or 429 → `waiting_quota` → resumes after the window. With
  `paid_processing_enabled=false`, the ledger never allows a call above the limits.
- 🤖 Local chunks are deleted only after the server reports them *transcribed*.
- 🤖 5 non-quota failures → `failed`. Retry recovers.
- 🤖 A 2-hour fixture meeting completes, using simulated quota windows.
- 👤 Ben gate: one real meeting flows from his Mac to a stored transcript.

**Stage 4: AI analysis**
- Map-reduce analysis, strict JSON, evidence validation, publishing to `insights`/`tasks`.
- 🤖 Every published item cites at least one existing segment.
- 🤖 Every non-null owner/due has its quote in a cited segment.
- 🤖 Planted fixtures pass: a task with no owner → `owner=null`; an invented deadline is
  stripped; malformed model JSON is retried, never published.
- 👤 Ben gate: Ben reviews the notes from 3 real meetings and finds no invented or
  meaning-changed items.

**Stage 5: Auto-detection and consent**
- Meet, Zoom desktop, and Zoom web detection; countdown; menubar controls; disable; "ask every
  time"; consent copy.
- 🤖 Unit tests of the detection function cover in-call, lobby (mic idle), tab closed, mic idle
  60 s, disabled, and "don't record this meeting".
- 🤖 Cancel during the countdown → the spool stays empty and nothing is uploaded.
- 👤 Ben gate:
  - Join a real Meet → the countdown appears within 10 s, then recording starts.
  - Leave → it stops within 60 s.
  - A lobby doesn't record.
  - Disabled doesn't record.

**Stage 6: Dashboard**
- Login, meetings with status, meeting page with evidence links, tasks, search, status strip.
- 🤖 Without a session cookie, every API route returns 401.
- 🤖 A Hebrew search finds words with and without a prefix ("דיפלוי" finds "הדיפלוי").
- 🤖 Marking a task done persists. Retry on a failed meeting requeues it. The waiting status
  shows the resume time.
- 👤 Ben gate: Ben uses it on his real meetings and checks that RTL and mixed text read correctly.

**Stage 7: Hardening and real use**
- 🤖 Simulated sleep mid-meeting → clean stop, meeting marked `incomplete`. Restart with a
  pending spool → uploads resume.
- 👤 Ben gate: a week of real use with no lost meetings and no unexpected recordings, and quota
  status always understandable.

## 9. Left to the builder

Exact columns and indexes, endpoint details within §4.2, the chunk-boundary algorithm, the
silence threshold, dedup heuristics, prompt wording, dashboard markup, and repo layout
(suggested: `notetaker/mac`, `notetaker/worker`, `notetaker/dashboard`).
