#!/usr/bin/env bash
# openspec-e2e-kit セルフテスト。npm test から呼ばれる。
# 破壊的操作はサンドボックス(/tmp 配下)に限定する。
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${SANDBOX:-/tmp/kit-sandbox}"
REPORT_WORK="/tmp/kit-report-work"

pass_count=0
fail_count=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass_count=$((pass_count + 1)); }
ng()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail_count=$((fail_count + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_file() {
  if [ -f "$1" ]; then ok "$2"; else ng "$2 (missing: $1)"; fi
}
assert_grep() {
  # assert_grep <pattern> <file> <label>
  if grep -qF -- "$1" "$2" 2>/dev/null; then ok "$3"; else ng "$3 (pattern not found: $1)"; fi
}
assert_contains() {
  # assert_contains <pattern> <text> <label>
  if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else ng "$3 (missing: $1)"; fi
}

# ------------------------------------------------------------------ (a)
step "(a) サンドボックスに最小の openspec プロジェクトを用意する"
case "$SANDBOX" in
  /tmp/*|/private/tmp/*) ;;
  *) echo "SANDBOX は /tmp 配下でなければなりません: $SANDBOX" >&2; exit 1 ;;
esac
rm -rf "$SANDBOX" "$REPORT_WORK"
mkdir -p "$SANDBOX/openspec/specs" "$SANDBOX/openspec/changes/archive"
touch "$SANDBOX/openspec/specs/.gitkeep" "$SANDBOX/openspec/changes/archive/.gitkeep"
cat > "$SANDBOX/openspec/config.yaml" <<'EOF'
schema: spec-driven

# Project context (optional)
# Example:
#   context: |
#     Tech stack: TypeScript
EOF
git -C "$SANDBOX" init -q
ok "sandbox 作成: $SANDBOX (openspec/config.yaml は schema: spec-driven)"

# ------------------------------------------------------------------ (b)
step "(b) install を実行する"
install_out="$(node "$KIT_ROOT/install.mjs" install --target "$SANDBOX" 2>&1)"
install_rc=$?
printf '%s\n' "$install_out" | sed 's/^/    | /'
if [ "$install_rc" -eq 0 ]; then ok "install が exit 0 で終了"; else ng "install が exit $install_rc で終了"; fi

# ------------------------------------------------------------------ (c)
step "(c) 配置とマージを検証する"
assert_file "$SANDBOX/openspec/schemas/spec-driven-e2e/schema.yaml" "スキーマ schema.yaml が配置された"
assert_file "$SANDBOX/openspec/schemas/spec-driven-e2e/templates/test-plan.md" "テンプレート test-plan.md が配置された"
assert_grep "E2Eテスト実装タスク" "$SANDBOX/openspec/schemas/spec-driven-e2e/templates/tasks.md" "tasks.md に E2E 実装タスク指示が入っている"
assert_grep "id: test-plan" "$SANDBOX/openspec/schemas/spec-driven-e2e/schema.yaml" "schema.yaml に test-plan アーティファクトがある"
assert_file "$SANDBOX/.claude/skills/e2e-conventions/SKILL.md" "スキル SKILL.md が配置された"
assert_file "$SANDBOX/scripts/e2e-report.mjs" "scripts/e2e-report.mjs が配置された"
assert_file "$SANDBOX/scripts/check-test-plan.sh" "scripts/check-test-plan.sh が配置された"
if [ -x "$SANDBOX/scripts/check-test-plan.sh" ]; then ok "check-test-plan.sh に実行権限がある"; else ng "check-test-plan.sh に実行権限がない"; fi
assert_file "$SANDBOX/tests/e2e/fixtures/README.md" "tests/e2e/fixtures/README.md が配置された"
assert_file "$SANDBOX/playwright.config.ts" "playwright.config.ts として設置された (.example が外れた)"
if [ -f "$SANDBOX/playwright.config.example.ts" ]; then
  ng "playwright.config.example.ts が残っている"
else
  ok "playwright.config.example.ts は設置されていない"
fi
assert_grep "# --- openspec-e2e-kit ---" "$SANDBOX/openspec/config.yaml" "config.yaml にマーカーブロックが追記された"
assert_grep ".claude/skills/e2e-conventions/SKILL.md" "$SANDBOX/openspec/config.yaml" "config.yaml に context 追記内容が入っている"
assert_contains "schema が 'spec-driven'" "$install_out" "既存 schema: spec-driven を書き換えず警告した"
assert_file "$SANDBOX/.openspec-e2e-kit.json" ".openspec-e2e-kit.json が書かれた"
if node -e "const j=require('$SANDBOX/.openspec-e2e-kit.json'); process.exit(j.version && j.installedAt ? 0 : 1)"; then
  ok ".openspec-e2e-kit.json に version と installedAt がある"
else
  ng ".openspec-e2e-kit.json の内容が不正"
fi

# ------------------------------------------------------------------ (d)
step "(d) 2回目の install が冪等であることを検証する"
before_hash="$(find "$SANDBOX" -type f -not -path '*/.git/*' -not -name '.openspec-e2e-kit.json' -exec shasum {} \; | sort | shasum)"
second_out="$(node "$KIT_ROOT/install.mjs" install --target "$SANDBOX" 2>&1)"
second_rc=$?
printf '%s\n' "$second_out" | sed 's/^/    | /'
after_hash="$(find "$SANDBOX" -type f -not -path '*/.git/*' -not -name '.openspec-e2e-kit.json' -exec shasum {} \; | sort | shasum)"
if [ "$second_rc" -eq 0 ]; then ok "2回目の install が exit 0"; else ng "2回目の install が exit $second_rc"; fi
if [ "$before_hash" = "$after_hash" ]; then
  ok "2回目の install でファイル内容が一切変化しない(冪等)"
else
  ng "2回目の install でファイルが変化した(冪等でない)"
fi
assert_contains "変更はありません" "$second_out" "2回目は「変更はありません」と報告する"

# ------------------------------------------------------------------ (e)
step "(e) sandbox 内でスキーマを validate する"
if command -v openspec >/dev/null 2>&1; then
  validate_out="$(cd "$SANDBOX" && openspec schema validate spec-driven-e2e 2>&1)"
  validate_rc=$?
  printf '%s\n' "$validate_out" | sed 's/^/    | /'
  if [ "$validate_rc" -eq 0 ]; then
    ok "openspec schema validate spec-driven-e2e が通る"
  else
    ng "openspec schema validate spec-driven-e2e が失敗 (exit $validate_rc)"
  fi
else
  skip "openspec CLI が無いため schema validate を省略"
fi

# ------------------------------------------------------------------ (f)
step "(f) e2e-report.mjs をフィクスチャで検証する"
mkdir -p "$REPORT_WORK/openspec/changes/demo-change"
cat > "$REPORT_WORK/openspec/changes/demo-change/test-plan.md" <<'EOF'
# Test Plan
| TP-ID | 対応シナリオ |
|-------|-------------|
| TP-001 | 注文できる |
| TP-002 | 在庫切れは注文できない |
| TP-003 | カート件数が増える |
| TP-004 | 未実装の観点(欠落検知用) |
EOF
report_out="$(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" demo-change "$KIT_ROOT/test/fixtures/sample-results.json" 2>&1)"
report_rc=$?
printf '%s\n' "$report_out" | sed 's/^/    | /'
assert_contains "| TP-001 |" "$report_out" "TP-001 の行が出力される"
assert_contains "| pass |" "$report_out" "pass のテストが結果表に出る"
assert_contains "| fail |" "$report_out" "fail のテストが結果表に出る"
assert_contains "⚠ |" "$report_out" "フレークがマークされる"
assert_contains "TP-004" "$report_out" "欠落 TP-ID が警告に出る"
assert_contains "カバレッジ欠落" "$report_out" "カバレッジ欠落の警告文が出る"
if [ "$report_rc" -ne 0 ]; then ok "カバレッジ欠落があるとき exit が非0 ($report_rc)"; else ng "カバレッジ欠落があるのに exit 0"; fi

# 真の失敗(retries により results が2件ある)をフレーク扱いしないこと
flaky_marks="$(printf '%s' "$report_out" | grep -c '⚠ |')"
if [ "$flaky_marks" -eq 1 ]; then
  ok "フレークは1件だけ(失敗テストをフレーク扱いしない)"
else
  ng "フレークマークが $flaky_marks 件ある(期待: 1件)"
fi

# ------------------------------------------------------------------ dry-run
step "(g) --dry-run が書き込みゼロで動作一覧を出す"
dry_target="/tmp/kit-dryrun-target"
rm -rf "$dry_target"
dry_out="$(node "$KIT_ROOT/install.mjs" --dry-run --target "$dry_target" 2>&1)"
dry_rc=$?
assert_contains "create  scripts/e2e-report.mjs" "$dry_out" "dry-run が作成予定を一覧表示する"
if [ ! -e "$dry_target" ]; then ok "dry-run で対象に一切書き込まない"; else ng "dry-run が $dry_target に書き込んだ"; fi
if [ "$dry_rc" -eq 0 ]; then ok "dry-run が exit 0"; else ng "dry-run が exit $dry_rc"; fi

# ------------------------------------------------------------------ (h)
step "(h) 既存ファイルがある対象での差分ハンドリング"
alt="/tmp/kit-alt-target"
rm -rf "$alt"
mkdir -p "$alt/openspec"
git -C "$alt" init -q 2>/dev/null || mkdir -p "$alt/.git"
printf 'export default { testDir: "./e2e" };\n' > "$alt/playwright.config.ts"
node "$KIT_ROOT/install.mjs" install --target "$alt" >/dev/null 2>&1
assert_file "$alt/playwright.config.example.ts" "既存 playwright.config.ts があると .example.ts で配置される"
assert_grep 'testDir: "./e2e"' "$alt/playwright.config.ts" "既存 playwright.config.ts は上書きされない"

# payload と異なる内容へ書き換えて、diff 表示 + skip になることを確認
printf '# locally modified\n' >> "$alt/scripts/e2e-report.mjs"
diff_out="$(node "$KIT_ROOT/install.mjs" install --target "$alt" 2>&1)"
assert_contains "差分あり" "$diff_out" "差分のあるファイルで diff を表示する"
assert_contains "-# locally modified" "$diff_out" "unified diff に削除行が出る"
assert_contains "skip しました" "$diff_out" "skip したファイルを一覧表示する"
assert_grep "# locally modified" "$alt/scripts/e2e-report.mjs" "skip なので対象ファイルは変更されない"

force_out="$(node "$KIT_ROOT/install.mjs" update --target "$alt" --force 2>&1)"
assert_contains "更新" "$force_out" "update サブコマンドは「更新」と表示する"
if grep -qF "# locally modified" "$alt/scripts/e2e-report.mjs"; then
  ng "--force でも上書きされていない"
else
  ok "--force で差分ファイルを上書きする"
fi

# ------------------------------------------------------------------ (i)
step "(i) スキーマが実際の change フローで機能することを検証する"
# schema validate は構造しか見ないため、openspec 本体のアップグレードで
# アーティファクトのパイプラインや context の受け渡しが壊れても検出できない。
# config.yaml が無い対象へ導入し、実際に change を作って確認する。
if ! command -v openspec >/dev/null 2>&1; then
  skip "openspec CLI が無いため change フローの検証を省略"
else
  pipe="/tmp/kit-pipeline-target"
  rm -rf "$pipe"
  mkdir -p "$pipe"
  git -C "$pipe" init -q
  node "$KIT_ROOT/install.mjs" install --target "$pipe" >/dev/null 2>&1

  # config.yaml が無い対象では新規作成され、schema が spec-driven-e2e になる
  assert_grep "schema: spec-driven-e2e" "$pipe/openspec/config.yaml" "config.yaml が無い対象では schema: spec-driven-e2e で新規作成される"

  new_out="$(cd "$pipe" && openspec new change demo-change 2>&1)"
  status_out="$(cd "$pipe" && openspec status --change demo-change 2>&1)"
  printf '%s\n' "$status_out" | sed 's/^/    | /'

  assert_contains "Schema: spec-driven-e2e" "$status_out" "config.yaml から spec-driven-e2e が自動検出される"
  assert_contains "test-plan (blocked by: specs)" "$status_out" "test-plan が specs に依存してパイプラインに現れる"
  assert_contains "tasks (blocked by: specs, design, test-plan)" "$status_out" "tasks の依存に test-plan が入っている"

  instr_out="$(cd "$pipe" && openspec instructions test-plan --change demo-change 2>&1)"
  assert_contains "<project_context>" "$instr_out" "test-plan の instructions に project_context が含まれる"
  assert_contains ".claude/skills/e2e-conventions/SKILL.md" "$instr_out" "config.yaml の context 追記が instructions に届いている"
  assert_contains "TP-NNN" "$instr_out" "タグ規約が instructions に届いている"
fi

# ------------------------------------------------------------------ 結果
step "結果"
printf '  PASS %d / FAIL %d\n' "$pass_count" "$fail_count"
if [ "$fail_count" -gt 0 ]; then
  printf '\n\033[31mセルフテスト失敗\033[0m\n'
  exit 1
fi
printf '\n\033[32mセルフテスト成功\033[0m\n'
