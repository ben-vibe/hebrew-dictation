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

## Live dictation smoke test

**Pending. Needs the owner at the Mac.** `dictation-smoke.sh --save-baseline` speaks 3 Hebrew
sentences through the speakers into the real dictation path. It records character error rate and
release-to-paste latency per sentence, and becomes the reference for later regression runs.
