# Dictation baseline (plan Task 0.1)

The reference state of the working dictation product, captured before any notetaker change.
Every later install is checked against it (regression check R in the plan).

Snapshots are stored locally under `~/Library/Application Support/meeting-notes/baseline/` and are
never committed: they contain file hashes, including hashes of credential files.

## Snapshot: 2026-10-29 10:22 UTC

| Check | Result |
|---|---|
| Protected files hashed (Hammerspoon config, recorder binary and source, compare script, 2 key files) | 6 / 6 present |
| Hotkeys bound | 2 (Ctrl+Cmd+R reload, Ctrl+Cmd+Y personal launcher); Hammerspoon shows them under the active Hebrew layout |
| Dictation globals | 9 / 9 present with expected types |
| fn+Shift event tap | enabled |
| Personal recordings | 20 (informational only: dictation rotates them) |
| `verify.sh` against the fresh snapshot | **PASS** (17 / 17) |

Observed in the live dictation log: a 9.6 s dictation took 1.77 s from release to paste. The
~0.6 s figure applies to short dictations.

## Live dictation smoke test (2026-10-29): inconclusive

Two runs of `dictation-smoke.sh --save-baseline` played synthetic Hebrew speech (`say -v Carmit`)
from the MacBook speakers into its microphone, then drove the real dictation path. Recordings were
backed up and checksum-verified first. After each run the mic was confirmed closed and dictation idle.

**Every clip that actually contained speech was transcribed and pasted correctly and quickly:**

| Run, sentence | Audio captured | CER | Release to paste |
|---|---|---|---|
| 1, s2 | 6.1 s, mean −43 dB | 0.103 | 0.68 s |
| 1, s3 | 6.9 s | 0.000 | 0.67 s |
| 2, s1 | 7.2 s, mean −33 dB | 0.025 | 0.77 s |

**The speaker-to-mic test harness was unreliable:** 4 of 6 utterances failed before reaching
dictation.
- In 3 of them, the output was cut short or inaudible: 0.5–1.8 s captured, or a full clip at
  about −53 dB. Whisper then hallucinated "תודה", a known silence artifact.
- In one, the Hammerspoon CLI stalled for 5 s during the script's log polling, which delayed that
  paste to 5.76 s.

Neither run is kept as the reference: both are marked invalid.

**Resolved (2026-10-29): guided smoke test.** `dictation-smoke.sh` was rewritten so the owner reads
the three sentences aloud using the real fn+Shift shortcut. The script only reads dictation's state and
never calls a dictation function. It:
- backs up every recording and verifies each one by SHA-256;
- refuses to run without an explicit cap (`--accept-rotation N`) on how many dictations it may cause,
  since each one rotates out the oldest personal recording;
- uses hard timeouts on every Hammerspoon query;
- checks each recording's length and level, so silent or truncated audio, or Whisper's silence
  hallucinations, is classified as invalid instead of as a transcription error;
- saves an official baseline only when all three sentences are valid.

78 offline test cases cover it, and two independent review rounds passed it.

The live guided run is pending, and needs the owner at the Mac.
