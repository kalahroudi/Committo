#!/usr/bin/env bash
# Applies .github/rulesets/main.json to the repo (needs `gh` logged in with admin rights).
# Usage: Scripts/protect-main.sh [owner/repo]
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
gh repo edit "$REPO" --default-branch main
gh api -X POST "repos/$REPO/rulesets" --input .github/rulesets/main.json
echo "main is now the default branch and protected on $REPO"
