#!/usr/bin/env bash
# Compare a fresh snapshot with a baseline snapshot directory.
# Usage: verify.sh <snapshot-dir | snapshot.txt>
# Exit: 0 all PASS, 1 any FAIL, 2 cannot run (bad args, Hammerspoon unreachable).
# Allowed differences: the notetaker pcall line appended to init.lua, and one extra
# Ctrl+Alt+Cmd hotkey (M, or צ under the Hebrew layout). "info" lines never fail.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if [ $# -ne 1 ]; then
  echo "usage: verify.sh <snapshot-dir>" >&2
  exit 2
fi
base_dir="$1"
[ -f "$base_dir" ] && base_dir="$(dirname "$base_dir")"
if [ ! -f "$base_dir/snapshot.txt" ]; then
  echo "no snapshot.txt in: $base_dir" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

set +e
fresh="$(BASELINE_DIR="$tmp" bash "$here/snapshot.sh")"
rc=$?
set -e
[ $rc -eq 0 ] || exit "$rc"

python3 - "$base_dir/snapshot.txt" "$fresh" "$base_dir/init.lua.copy" "$HOME/.hammerspoon/init.lua" <<'PY'
import sys

PCALL = b'pcall(require, "notetaker") -- meeting notetaker; delete this line to remove it completely'
MODS = {"⌘", "⌃", "⌥"}
NOTETAKER_KEYS = {"M", "m", "צ"}

base_path, fresh_path, copy_path, init_path = sys.argv[1:5]

def parse(path):
    files, hotkeys, other, info = {}, [], {}, {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line:
                continue
            kind, _, rest = line.partition(" ")
            if kind == "file":
                p, _, h = rest.rpartition(" ")
                files[p] = h
            elif kind == "hotkey":
                hotkeys.append(rest)
            elif kind == "info":
                k, _, v = rest.partition(" ")
                info.setdefault(k, []).append(v)
            elif kind == "global":
                n, _, t = rest.partition(" ")
                other["global " + n] = t
            else:
                other[kind] = rest
    return files, sorted(hotkeys), other, info

def init_only_pcall_appended():
    try:
        with open(copy_path, "rb") as f:
            orig = f.read()
        with open(init_path, "rb") as f:
            cur = f.read()
    except OSError:
        return False
    sep = b"" if (orig == b"" or orig.endswith(b"\n")) else b"\n"
    return cur in (orig + sep + PCALL, orig + sep + PCALL + b"\n")

def is_notetaker_hotkey(idx):
    # Modifier glyph order depends on hs/layout; require exactly {⌘,⌃,⌥} plus one key.
    if len(idx) != 4:
        return False
    return set(idx[:3]) == MODS and idx[3] in NOTETAKER_KEYS

bf, bh, bo, bi = parse(base_path)
ff, fh, fo, fi = parse(fresh_path)
fails = 0

def report(ok, label, note=""):
    global fails
    if not ok:
        fails += 1
    print(("PASS " if ok else "FAIL ") + label + (f" ({note})" if note else ""))

# Hashes are never printed: some of these are key files.
for path in sorted(set(bf) | set(ff)):
    b, f = bf.get(path), ff.get(path)
    if b == f:
        report(True, f"file {path}")
    elif path == "~/.hammerspoon/init.lua" and b != "MISSING" and f not in (None, "MISSING") \
            and init_only_pcall_appended():
        report(True, f"file {path}", "only the notetaker pcall line was appended")
    elif b is None:
        report(False, f"file {path}", "not in baseline")
    elif f is None:
        report(False, f"file {path}", "missing from fresh snapshot")
    elif f == "MISSING":
        report(False, f"file {path}", "file was removed")
    elif b == "MISSING":
        report(False, f"file {path}", "file appeared")
    else:
        report(False, f"file {path}", "content changed")

def multiset_diff(a, b):
    rest = list(b)
    for x in a:
        if x in rest:
            rest.remove(x)
        else:
            return None
    return rest

if fh == bh:
    report(True, "hotkeys", f"{len(bh)} unchanged")
else:
    extra = multiset_diff(bh, fh)
    if extra is not None and len(extra) == 1 and is_notetaker_hotkey(extra[0]):
        report(True, "hotkeys", f"{len(bh)} unchanged + notetaker {extra[0]}")
    else:
        removed = [h for h in bh if h not in fh]
        added = [h for h in fh if h not in bh]
        report(False, "hotkeys", f"added: {' '.join(added) or '-'}; removed: {' '.join(removed) or '-'}")

for key in sorted(set(bo) | set(fo)):
    b, f = bo.get(key), fo.get(key)
    if b == f:
        report(True, f"{key} {b}")
    else:
        report(False, key, f"was {b}, now {f}")

bn = bi.get("recordings_count", ["0"])[0]
fn = fi.get("recordings_count", ["0"])[0]
brec, frec = set(bi.get("recording", [])), set(fi.get("recording", []))
print(f"INFO recordings_count {bn} -> {fn} "
      f"(+{len(frec - brec)} -{len(brec - frec)}; informational, never fails)")

print("RESULT: " + ("PASS" if fails == 0 else f"FAIL ({fails} line(s))"))
sys.exit(0 if fails == 0 else 1)
PY
