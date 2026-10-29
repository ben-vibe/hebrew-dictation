#!/usr/bin/env bash
# Lint notetaker code for anything that could reach into dictation.
# Usage: isolation-lint.sh <dir>   Exit 1 with file:line for each violation.
# Scans *.lua (globals, eventtaps, hotkeys, dictation paths) and *.sh/*.swift/*.ts/*.js
# (dictation paths). The guard scripts themselves (tests/guard/) are skipped: they must name
# the forbidden strings in order to test for them.
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "usage: isolation-lint.sh <dir>" >&2
  exit 2
fi

python3 - "$1" <<'PY'
import os, re, sys

root = sys.argv[1]
W = r"(?<![A-Za-z0-9_])"   # word start
E = r"(?![A-Za-z0-9_])"    # word end

DICTATION_GLOBALS = ("dictationLog lastRecording releasedAt startRecording "
                     "stopRecordingAndTranscribe startPriming cancelPriming "
                     "isPrimedOrRecording dictationTap").split()

# Dictation-owned paths/names, checked in every scanned language.
PATH_RULES = [
    (re.compile(r"hs-dictation\.wav"), "hs-dictation.wav"),
    (re.compile(r"dictation-recorder"), "dictation-recorder"),
    (re.compile(r"recordings"), "recordings"),
    (re.compile(r"dictation-groq-key"), "dictation-groq-key"),
]
LUA_RULES = [
    # Any _G use except the exact _G.notetaker (catches _G.x, _G .x, _G[..], local g = _G, ...).
    (re.compile(W + r"_G" + E + r"(?!\.notetaker" + E + ")"), "_G use other than _G.notetaker"),
    (re.compile(r"raw(?:set|get)\s*\(\s*_G" + E), "rawset/rawget on _G"),
    (re.compile(W + r"local\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*_G" + E), "_G assigned to a local"),
    (re.compile(W + r"_ENV" + E), "_ENV"),
    (re.compile(W + r"(?:setfenv|getfenv)" + E), "setfenv/getfenv"),
    (re.compile(W + "(" + "|".join(DICTATION_GLOBALS) + ")" + E), "dictation global name"),
    (re.compile(r"eventtap"), "eventtap"),
    (re.compile(r"flagsChanged"), "flagsChanged"),
]
OTHER_EXT = (".sh", ".swift", ".ts", ".js")

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

def groq_key_allowed(path):
    # The installer's secret step is the one place allowed to name the Groq key file.
    return os.path.abspath(path).endswith(os.sep + os.path.join("notetaker", "install.sh"))

violations = []
for dirpath, dirnames, names in os.walk(root):
    dirnames.sort()
    if os.sep + os.path.join("tests", "guard") + os.sep in os.path.abspath(dirpath) + os.sep:
        continue
    for name in sorted(names):
        is_lua = name.endswith(".lua")
        if not (is_lua or name.endswith(OTHER_EXT)):
            continue
        path = os.path.join(dirpath, name)
        rules = PATH_RULES + (LUA_RULES if is_lua else [])
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                for rx, why in rules:
                    if why == "dictation-groq-key" and groq_key_allowed(path):
                        continue
                    if rx.search(line):
                        violations.append(f"{path}:{n}: {why}")
                if is_lua:
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
