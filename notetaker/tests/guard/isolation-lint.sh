#!/usr/bin/env bash
# Lint notetaker Lua for anything that could reach into dictation.
# Usage: isolation-lint.sh <dir>   Exit 1 with file:line for each violation.
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: isolation-lint.sh <dir>" >&2
  exit 2
fi

python3 - "$1" <<'PY'
import os, re, sys

root = sys.argv[1]

RULES = [
    # _G.<anything but notetaker>, and _G[...] which could name any global.
    (re.compile(r"_G\.(?!notetaker(?![A-Za-z0-9_]))"), "_G access other than _G.notetaker"),
    (re.compile(r"_G\s*\["), "_G[...] access"),
    (re.compile(r"eventtap"), "eventtap"),
    (re.compile(r"flagsChanged"), "flagsChanged"),
    (re.compile(r"hs-dictation\.wav"), "hs-dictation.wav"),
    (re.compile(r"dictation-groq-key"), "dictation-groq-key"),
    (re.compile(r"dictation-recorder"), "dictation-recorder"),
    (re.compile(r"/recordings"), "/recordings"),
]

BIND = re.compile(
    r"""hs\.hotkey\.(?:bind|new)\s*\(\s*(\{[^}]*\}|"[^"]*"|'[^']*')\s*,\s*(["'])(.*?)\2""")

MOD_ALIASES = {
    "ctrl": "ctrl", "control": "ctrl", "⌃": "ctrl",
    "cmd": "cmd", "command": "cmd", "⌘": "cmd",
    "alt": "alt", "option": "alt", "⌥": "alt",
    "shift": "shift", "⇧": "shift",
    "fn": "fn",
}
MOD_TOKEN = re.compile(r"control|ctrl|command|cmd|option|alt|shift|fn|[⌃⌘⌥⇧]", re.I)

def forbidden_bind(mods_src, key):
    mods = {MOD_ALIASES[m.lower()] for m in MOD_TOKEN.findall(mods_src)}
    key = key.lower()
    if "fn" in mods:
        return "hotkey on fn"
    if mods == {"ctrl", "cmd"} and key in ("r", "y"):
        return f"hotkey ctrl+cmd+{key}"
    return None

violations = []
for dirpath, _, names in os.walk(root):
    for name in sorted(names):
        if not name.endswith(".lua"):
            continue
        path = os.path.join(dirpath, name)
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                for rx, why in RULES:
                    if rx.search(line):
                        violations.append(f"{path}:{n}: {why}")
                for m in BIND.finditer(line):
                    why = forbidden_bind(m.group(1), m.group(3))
                    if why:
                        violations.append(f"{path}:{n}: forbidden {why}")

for v in violations:
    print(v)
if violations:
    print(f"FAIL: {len(violations)} isolation violation(s)", file=sys.stderr)
    sys.exit(1)
print("PASS: isolation lint clean")
PY
