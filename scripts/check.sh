#!/usr/bin/env bash
# Every check that must pass before a commit. CI runs the same steps.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> server: ruff + pytest"
cd "$root/server"
uv sync --locked --quiet
uv run ruff check .
uv run ruff format --check .
uv run pytest -q

if command -v swift >/dev/null 2>&1; then
  echo "==> apple/CoachKit: swift test"
  cd "$root/apple/CoachKit"
  swift test --quiet
else
  echo "==> apple/CoachKit: skipped (swift not found)"
fi
