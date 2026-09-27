#!/usr/bin/env bash

# Merge the Dictation row from omarchy-menu-snippet.jsonc into the user's
# Omarchy menu extension file, or remove it again with --remove.
#
# The merge only ever touches the "setup.dictation" key; every other key in the
# file is carried through untouched. Running it twice is a no-op. The shell
# watches the extension file, so the row appears without a restart.
#
# JSONC caveat: the extension file may contain comments and trailing commas.
# They are tolerated on read but not reproduced on write, so a file that had
# comments is backed up to <file>.bak before it is rewritten.
#
# Set OMARCHY_MENU_EXT_FILE to merge into a different file (used by the tests).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SNIPPET="$SCRIPT_DIR/omarchy-menu-snippet.jsonc"
TARGET="${OMARCHY_MENU_EXT_FILE:-$HOME/.config/omarchy/extensions/omarchy-menu.jsonc}"
MODE="install"

usage() {
  cat <<'USAGE'
Usage: install-menu.sh [--remove] [--help]

  (no flags)  add the Dictation row to the Omarchy menu
  --remove    take it back out

Environment:
  OMARCHY_MENU_EXT_FILE  menu extension file to edit
                         (default: ~/.config/omarchy/extensions/omarchy-menu.jsonc)
USAGE
}

while (($#)); do
  case "$1" in
    --remove) MODE="remove" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "install-menu.sh: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

command -v python3 >/dev/null || {
  echo "install-menu.sh: python3 is required" >&2
  exit 1
}

[[ -f $SNIPPET ]] || {
  echo "install-menu.sh: snippet not found: $SNIPPET" >&2
  exit 1
}

mkdir -p -- "$(dirname -- "$TARGET")"

MODE="$MODE" SNIPPET="$SNIPPET" TARGET="$TARGET" python3 - <<'PYTHON'
import json
import os
import re
import shutil
import sys

mode = os.environ["MODE"]
snippet_path = os.environ["SNIPPET"]
target_path = os.environ["TARGET"]

KEY = "setup.dictation"
HEADER = (
    "// Omarchy menu extensions. Merged by the voxtype settings plugin's\n"
    "// install-menu.sh; other keys in this file are left untouched.\n"
)


def strip_jsonc(text):
    """Drop // and /* */ comments and trailing commas, leaving strings alone."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        out.append(ch)
        i += 1
    stripped = "".join(out)
    return re.sub(r",(\s*[}\]])", r"\1", stripped)


def load_jsonc(path):
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
    if raw.strip() == "":
        return {}, raw
    return json.loads(strip_jsonc(raw)), raw


try:
    snippet, _ = load_jsonc(snippet_path)
except ValueError as error:
    sys.exit("install-menu.sh: snippet is not valid JSONC: %s" % error)

entry = snippet.get(KEY)
if not isinstance(entry, dict):
    sys.exit("install-menu.sh: snippet has no '%s' object" % KEY)

existing_raw = ""
if os.path.exists(target_path):
    try:
        existing, existing_raw = load_jsonc(target_path)
    except ValueError as error:
        sys.exit(
            "install-menu.sh: %s is not valid JSONC (%s).\n"
            "Add this entry by hand instead:\n%s"
            % (target_path, error, json.dumps({KEY: entry}, indent=2, ensure_ascii=False))
        )
    if not isinstance(existing, dict):
        sys.exit("install-menu.sh: %s must contain a JSON object" % target_path)
else:
    existing = {}

if mode == "remove":
    if KEY not in existing:
        print("Dictation row is not present in %s" % target_path)
        raise SystemExit(0)
    del existing[KEY]
    action = "Removed"
else:
    if existing.get(KEY) == entry:
        print("Dictation row is already installed in %s" % target_path)
        raise SystemExit(0)
    action = "Updated" if KEY in existing else "Added"
    existing[KEY] = entry

# Comments and formatting are not reproducible from parsed JSON, so keep a copy
# of anything that had them. A file this script wrote carries only its own
# header, which it is about to write again — no backup needed for that.
written_by_us = existing_raw.lstrip().startswith(HEADER.split("\n", 1)[0])
if existing_raw.strip() and not written_by_us and ("//" in existing_raw or "/*" in existing_raw):
    shutil.copyfile(target_path, target_path + ".bak")
    print("Backed up the previous file to %s.bak (comments are not preserved)" % target_path)

body = json.dumps(existing, indent=2, ensure_ascii=False)
with open(target_path, "w", encoding="utf-8") as handle:
    handle.write(HEADER + body + "\n")

print("%s the Dictation row in %s" % (action, target_path))
PYTHON
