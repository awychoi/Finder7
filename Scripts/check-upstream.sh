#!/usr/bin/env bash
# Reports whether a newer official 7-Zip release exists.
# Exit: 0 current, 2 update available, 1 error.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/Vendor/7zip.lock.json"
MODE="${1:-}"

if [[ ! -f "$LOCK" ]]; then
    echo "error: $LOCK is missing" >&2
    exit 1
fi

CURRENT="$(python3 - "$LOCK" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)["version"])
PY
)" || exit 1

API="https://api.github.com/repos/ip7z/7zip/releases/latest"
RESPONSE="$(curl -fsSL --retry 2 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: sevenzip-gui-update-check' \
    "$API")" || { echo "error: could not reach GitHub releases API" >&2; exit 1; }

read -r LATEST PUBLISHED URL < <(python3 - "$RESPONSE" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
print(data["tag_name"], data.get("published_at", "-"), data.get("html_url", "-"))
PY
) || exit 1

if [[ -z "${LATEST:-}" ]]; then
    echo "error: GitHub response had no tag_name" >&2
    exit 1
fi

if [[ "$MODE" == "--print-latest" ]]; then
    echo "$LATEST"
    exit 0
fi

python3 - "$CURRENT" "$LATEST" <<'PY'
import sys
def parts(v):
    try:
        return tuple(int(x) for x in v.split("."))
    except ValueError:
        return (0,)
sys.exit(0 if parts(sys.argv[1]) >= parts(sys.argv[2]) else 1)
PY
CMP=$?

if [[ "$MODE" == "--quiet" ]]; then
    if [[ $CMP -eq 0 ]]; then exit 0; else exit 2; fi
fi

echo "Installed 7-Zip: $CURRENT"
echo "Latest release:   $LATEST  ($PUBLISHED)"
echo "Release page:     $URL"

if [[ $CMP -eq 0 ]]; then
    echo "Up to date."
    exit 0
fi

echo
echo "Update available: $CURRENT -> $LATEST"
echo "Run: ./Scripts/fetch-engine.sh && ./Scripts/build-app.sh"
exit 2
