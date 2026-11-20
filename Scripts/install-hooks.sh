#!/usr/bin/env bash
# Installs this repository's git hooks into the current clone.
#
# The pre-commit hook blocks commits that stage secrets, credential files or
# personal data. It lives in .githooks/ so it can be versioned and reviewed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$ROOT/.githooks"

[[ -f "$HOOKS/pre-commit" ]] || {
    echo "error: $HOOKS/pre-commit is missing" >&2
    exit 1
}

chmod +x "$HOOKS/pre-commit"
git -C "$ROOT" config core.hooksPath .githooks

echo "Installed pre-commit hook (core.hooksPath=.githooks)."
echo "It blocks staged secrets, credential files and personal data."
if ! command -v gitleaks >/dev/null 2>&1; then
    echo
    echo "Optional: install gitleaks for an independent second-opinion scan:"
    echo "  brew install gitleaks"
fi
