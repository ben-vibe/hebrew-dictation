# Engineering decisions

Short decision records for choices this project has made. ADR-001 to ADR-007 are implemented in
the dictation tool. ADR-008 to ADR-010 are **planned design decisions** for the meeting notetaker,
which is not implemented yet.

| # | Decision | Status |
|---|---|---|
| [001](#adr-001-native-avfoundation-recorder-instead-of-ffmpeg) | Native AVFoundation recorder instead of ffmpeg | Implemented |
| [002](#adr-002-prime-the-mic-on-fn-alone-never-on-shift) | Prime the mic on fn alone, never on Shift | Implemented |
| [003](#adr-003-ready-signal-and-a-two-stage-ui-cue) | READY signal and a two-stage UI cue | Implemented |
| [004](#adr-004-pin-languagehe-instead-of-auto-detect) | Pin `language=he` instead of auto-detect | Implemented |
| [005](#adr-005-vocabulary-biasing-prompt-instead-of-an-llm-cleanup-pass) | Vocabulary-biasing prompt instead of an LLM cleanup pass | Implemented |
| [006](#adr-006-hold-timers-at-module-scope) | Hold timers at module scope | Implemented |
| [007](#adr-007-restore-the-clipboard-after-paste) | Restore the clipboard after paste | Implemented |
| [008](#adr-008-free-tier-only-cloudflare-planned) | Free-tier-only Cloudflare | Planned |
| [009](#adr-009-evidence-validated-ai-output-planned) | Evidence-validated AI output | Planned |
| [010](#adr-010-source-agnostic-ingest-contract-planned) | Source-agnostic ingest contract | Planned |

---

## ADR-001: Native AVFoundation recorder instead of ffmpeg

**Context.** The first version recorded with `ffmpeg -f avfoundation`. Dictations are typically
2–4 s long, and transcripts often looked inaccurate.

**Decision.** Replace ffmpeg with a small Swift program, `bin/dictation-recorder.swift`, that uses
`AVAudioRecorder` to write 16 kHz mono 16-bit PCM WAV and finalizes the file on SIGTERM.

**Evidence.** ffmpeg took **1.4–3.5 s** to open the input device (measured). That swallowed most
of each sentence: transcription was fine, it just received a fragment. The native recorder opens
in **about 0.5 s**, consistently.

**Consequences.** A build step (`swiftc`, so Xcode Command Line Tools are required) and a binary
installed by `install.sh`. The recorder also became the natural place to report readiness
(ADR-003). The remaining ~0.5 s is mostly hidden by priming (ADR-002).

## ADR-002: Prime the mic on fn alone, never on Shift

**Context.** Even ~0.5 s of mic-open time clips the first word if recording starts only when
the full combo is down. People naturally press the two keys a beat apart.

**Decision.** Start the recorder as soon as `fn` is pressed alone. Treat it as a dictation only
when `Shift` completes the exact `fn+Shift` combo. If the combo is not completed, kill the
recorder and delete its file; it is never transcribed or sent. Never prime on `Shift` alone.

**Evidence.** `Shift` is pressed constantly while typing (every capital letter); priming on it
would open the mic dozens of times a minute. `fn` alone is rarely pressed in normal typing.

**Consequences.** Most of the mic-open delay disappears when users press `fn` first, which the
docs recommend. The privacy statement is precise: the mic opens only while you are pressing
toward the hotkey. Cancellation must handle a recorder that is still starting up, so the file is
deleted again in the recorder's exit callback.

## ADR-003: READY signal and a two-stage UI cue

**Context.** The on-screen "recording" cue used to appear about 0.5 s before any audio landed on
disk, so the first word of a sentence was clipped, the exact failure the native recorder was built
to fix.

**Decision.** The recorder prints `READY` on stdout immediately after `record()` succeeds. The
Lua module shows "⏳ מתחבר" (connecting) until it sees `READY`, then "🎙️ מקליט" (recording).

**Evidence.** The cue now reflects reality. During implementation, `task:setStreamingCallback()`
set after construction never fired (verified); the callback must be passed as `hs.task.new`'s
third argument.

**Consequences.** Users get an honest signal of when speech is captured. Troubleshooting docs can
say plainly: if the start is cut off, you spoke during ⏳.

## ADR-004: Pin `language=he` instead of auto-detect

**Context.** Nearly all dictation is Hebrew. Whisper can auto-detect the language when none is
given.

**Decision.** Default `LANGUAGE = "he"`. `nil` (auto-detect) or any ISO-639-1 code remains
available.

**Evidence.** Auto-detect was tried and made real-world Hebrew accuracy worse: Whisper sometimes
guessed the wrong language and the output degraded. The repo history shows the change and its
reversal.

**Consequences.** Hebrew is reliable; dictating in another language needs a config change. The
notetaker design carries this finding forward as its default, while planning to measure
alternatives for mixed-language meetings.

## ADR-005: Vocabulary-biasing prompt instead of an LLM cleanup pass

**Context.** Hebrew tech jargon was mangled. Two remedies were considered: an LLM pass that
rewrites the transcript, or Whisper's `prompt` parameter, which biases vocabulary during
transcription.

**Decision.** Use `VOCAB_PROMPT`, a short Hebrew text listing common terms. No LLM cleanup.

**Evidence.**

| Without prompt | With prompt |
|---|---|
| הבואג | הבאג |
| צ'יקאות | צ׳קאאוט |
| הדיפלויל פרודקשן | הדיפלוי לפרודקשן |

With the prompt, 3/3 test sentences were transcribed exactly, at no extra latency. The LLM
alternative was tested: `llama-3.3-70b` silently changed "צ׳קאאוט" into "בדיקות", a meaning
change that is worse than a transcription error because a reader cannot spot it. `qwen3.6-27b`
entered an endless reasoning loop.

**Consequences.** Biasing the transcriber can only pick better words; it cannot invent content.
Users extend the prompt with their own recurring names and terms. The "no invented content"
principle became an anti-goal of the notetaker design (ADR-009).

## ADR-006: Hold timers at module scope

**Context.** Some dictations silently never uploaded while others worked, which looked
intermittent rather than broken.

**Decision.** Hold the post-release poll timer in a module-scope variable (`pollTimer`) instead of
only inside a closure.

**Evidence.** A Hammerspoon timer referenced only from a closure can be garbage-collected before
it fires, so the upload never happened. Holding it at module scope fixed the intermittent failure.

**Consequences.** A project rule: Hammerspoon timers and callbacks must be held at module scope.
The notetaker plan applies it to every timer and watcher.

## ADR-007: Restore the clipboard after paste

**Context.** Pasting via `⌘V` is the most reliable way to insert text into any app, but it
overwrites whatever the user had copied.

**Decision.** Save the current clipboard text, set the transcript, send `⌘V`, and restore the
saved text after 1 s.

**Evidence.** The behavior is implemented in `dictation.lua` and documented in the user guide
("the clipboard is restored after one second").

**Consequences.** Dictation does not destroy the user's clipboard. The restore covers text
contents; the 1 s delay leaves the target app time to read the clipboard.

---

## ADR-008: Free-tier-only Cloudflare (planned)

**Context.** The notetaker MVP must cost nothing, and must never charge without an explicit
decision to enable paid processing. It needs a database, audio storage, scheduled jobs and
hosting, isolated from any other project.

**Decision.** A new, separate Cloudflare account on the free plan with no payment method: one
Worker for ingest, jobs and the dashboard; D1 for data and search; KV for audio. R2 is not used,
because activating it requires a payment method. Groq usage is metered by a ledger that never
exceeds free limits while `paid_processing_enabled` is `false`.

**Evidence.** The design compares alternatives (a shared existing database project, a multi-vendor
setup, Firebase Spark, R2) on isolation, completeness and whether they can ever charge. Free-plan
limits fail hard rather than bill. KV's eventual consistency is handled by treating D1 as the
source of truth and retrying misses; a Stage 0 spike verifies this before committing, with D1 blobs
as the fallback.

**Consequences.** On heavy days processing may finish later, and the dashboard shows why and
when it resumes. Accepted trade-offs: 10 ms CPU per request, SQLite instead of Postgres, KV write
limits.

## ADR-009: Evidence-validated AI output (planned)

**Context.** An invented task, owner, deadline or decision is worse than no output (ADR-005
showed an LLM silently changing meaning).

**Decision.** The model must cite transcript segment IDs. A deterministic validator runs after the
model and only what passes is published: items with no evidence or unknown IDs are dropped, and an
owner or deadline is kept only if its quote appears in a cited segment (normalized match).
Deadlines stay as the spoken phrase unless a date is unambiguous.

**Evidence.** Planned tests cover planted cases: a task with no owner yields `owner = null`, an
invented deadline is stripped, malformed JSON is retried and never published.

**Consequences.** Some correct but uncited items are lost; this is accepted. Every published item
links back to the transcript, and drops are logged per meeting.

## ADR-010: Source-agnostic ingest contract (planned)

**Context.** The MVP records on the Mac, but a future meeting bot should join meetings without a
rebuild of transcription, analysis, storage or the dashboard.

**Decision.** Sources only create a meeting, upload audio chunks per labelled track, and finalize.
Every write is idempotent (source-generated meeting IDs, unique `(meeting, track, seq)`, hash
checks). The pipeline knows the source only as a display label.

**Evidence.** The design keeps transcription and storage out of sources entirely, and models
speakers as track labels (`self`, `others`, later `speaker:<name>`).

**Consequences.** Retries are always safe, the Mac uploader can resume after sleep or network loss,
and a bot is another implementation of the same four endpoints.
