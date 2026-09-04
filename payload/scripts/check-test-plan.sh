#!/usr/bin/env bash
set -euo pipefail
# openspec/changes/ に差分がある PR で test-plan.md とタグ付きテストの存在を検証
base="${1:-origin/main}"
ids=$(git diff --name-only "$base"...HEAD -- 'openspec/changes/**' \
  | grep -v '/archive/' | cut -d/ -f3 | sort -u)
[ -z "$ids" ] && { echo "openspec change の差分なし。skip"; exit 0; }

fail=0
for id in $ids; do
  plan="openspec/changes/$id/test-plan.md"
  if [ ! -f "$plan" ]; then
    echo "::error::$id に test-plan.md がありません"; fail=1; continue
  fi
  if ! grep -rq -- "@$id" tests/e2e/; then
    echo "::error::@$id タグ付きの E2E テストが tests/e2e/ にありません"; fail=1
  fi
done
exit $fail
