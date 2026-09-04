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
if [ "$report_rc" -eq 3 ]; then ok "失敗テストがあるとき exit 3 ($report_rc)"; else ng "失敗テストがあるのに exit $report_rc (期待: 3)"; fi

# 終了コードの3系統を検証する。フィクスチャから失敗 spec を落としたものを派生させる。
node -e "
  const fs = require('fs');
  const r = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const strip = s => ({
    ...s,
    specs: (s.specs ?? []).filter(sp => sp.ok),
    ...(s.suites ? { suites: s.suites.map(strip) } : {}),
  });
  r.suites = r.suites.map(strip);
  fs.writeFileSync(process.argv[2], JSON.stringify(r));
" "$KIT_ROOT/test/fixtures/sample-results.json" "$REPORT_WORK/pass-only.json"

# 全 pass + 欠落あり(TP-002/TP-004 が未実行) → 1
(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" demo-change pass-only.json >/dev/null 2>&1)
rc_gap=$?
if [ "$rc_gap" -eq 1 ]; then ok "全 pass でカバレッジ欠落のみのとき exit 1"; else ng "カバレッジ欠落のみで exit $rc_gap (期待: 1)"; fi

# 全 pass + 欠落なし → 0
mkdir -p "$REPORT_WORK/openspec/changes/clean-change"
printf '| TP-001 | a |\n| TP-003 | c |\n' > "$REPORT_WORK/openspec/changes/clean-change/test-plan.md"
(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" clean-change pass-only.json >/dev/null 2>&1)
rc_clean=$?
if [ "$rc_clean" -eq 0 ]; then ok "全 pass かつ欠落なしのとき exit 0"; else ng "問題なしなのに exit $rc_clean (期待: 0)"; fi

# 読めないファイル → 2
(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" clean-change no-such-file.json >/dev/null 2>&1)
rc_err=$?
if [ "$rc_err" -eq 2 ]; then ok "results.json が読めないとき exit 2"; else ng "入力エラーで exit $rc_err (期待: 2)"; fi

# 鮮度検出: 周回ごとの実行で前の周の JSON を読んでしまう事故を防ぐ
assert_contains "実行開始:" "$report_out" "レポートに実行開始時刻が出力される"

# startTime を実行時に書き換えて、fresh / stale / stats なし の3系統を作る
node -e "
  const fs = require('fs');
  const base = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
  const write = (name, mutate) => {
    const r = JSON.parse(JSON.stringify(base));
    mutate(r);
    fs.writeFileSync(process.argv[2] + '/' + name, JSON.stringify(r));
  };
  write('fresh.json', r => { r.stats.startTime = new Date().toISOString(); });
  write('stale.json', r => { r.stats.startTime = new Date(Date.now() - 3600e3).toISOString(); });
  write('nostats.json', r => { delete r.stats; });
" "$KIT_ROOT/test/fixtures/sample-results.json" "$REPORT_WORK"

(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" demo-change fresh.json --max-age 300 >/dev/null 2>&1)
rc_fresh=$?
if [ "$rc_fresh" -eq 3 ]; then ok "--max-age 内なら鮮度チェックを通過し通常の終了コードになる ($rc_fresh)"; else ng "新鮮な JSON で exit $rc_fresh (期待: 3)"; fi

stale_out="$(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" demo-change stale.json --max-age 300 2>&1)"
rc_stale=$?
if [ "$rc_stale" -eq 2 ]; then ok "--max-age を超えた古い JSON は exit 2 で中断する ($rc_stale)"; else ng "古い JSON で exit $rc_stale (期待: 2)"; fi
assert_contains "前の周の結果を読んでいる可能性" "$stale_out" "古い JSON のとき原因の説明が出る"
if printf '%s' "$stale_out" | grep -qF '| TP-'; then
  ng "古い JSON なのに結果表を出力した(誤報告の温床)"
else
  ok "古い JSON では結果表を出さずに中断する"
fi

(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" demo-change nostats.json --max-age 300 >/dev/null 2>&1)
rc_nostats=$?
if [ "$rc_nostats" -eq 2 ]; then ok "実行時刻が無い JSON は検証不能として exit 2 (fail closed)"; else ng "stats 無しで exit $rc_nostats (期待: 2)"; fi

# --max-age 未指定なら鮮度で落とさない(既定の挙動は変えない)
(cd "$REPORT_WORK" && node "$KIT_ROOT/payload/scripts/e2e-report.mjs" demo-change stale.json >/dev/null 2>&1)
rc_noflag=$?
if [ "$rc_noflag" -eq 3 ]; then ok "--max-age 未指定なら古い JSON でも従来どおり動く ($rc_noflag)"; else ng "--max-age 未指定で exit $rc_noflag (期待: 3)"; fi

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

# ------------------------------------------------------------------ (j)
step "(j) E2E ルートを Playwright 設定から自動判別する"
# PostAll のような frontend/ 配下に Playwright がある構成では、payload の
# tests/e2e/ をそのまま配置すると毎回手作業の付け替えが必要になる。
mono="/tmp/kit-monorepo"
rm -rf "$mono"
mkdir -p "$mono/openspec" "$mono/frontend/e2e"
git -C "$mono" init -q
cat > "$mono/frontend/playwright.config.ts" <<'EOF'
import { defineConfig } from '@playwright/test'
export default defineConfig({
  testDir: './e2e',
  retries: 1,
})
EOF

mono_out="$(node "$KIT_ROOT/install.mjs" install --target "$mono" 2>&1)"
mono_rc=$?
printf '%s\n' "$mono_out" | sed 's/^/    | /'
if [ "$mono_rc" -eq 0 ]; then ok "monorepo 構成で install が exit 0"; else ng "install が exit $mono_rc"; fi
assert_contains "E2E ルート: frontend/e2e" "$mono_out" "frontend/playwright.config.ts の testDir から frontend/e2e を検出する"

# 配置先が検出したルートに読み替わる
assert_file "$mono/frontend/e2e/fixtures/README.md" "fixtures README が frontend/e2e/ に配置される"
if [ -e "$mono/tests" ]; then ng "既定パス tests/ が作られてしまった"; else ok "既定パス tests/ は作られない"; fi

# 内容の E2E ルートも置換される
assert_grep "frontend/e2e/pages/" "$mono/.claude/skills/e2e-conventions/SKILL.md" "SKILL.md の POM パスが置換される"
assert_grep "frontend/e2e/fixtures/" "$mono/.claude/skills/e2e-conventions/SKILL.md" "SKILL.md の fixtures パスが置換される"
assert_grep "frontend/e2e/mocks/" "$mono/.claude/skills/e2e-conventions/SKILL.md" "SKILL.md の mocks パスが置換される"
assert_grep "frontend/e2e/" "$mono/scripts/check-test-plan.sh" "check-test-plan.sh の grep 対象が置換される"
assert_grep "frontend/e2e/fixtures/README.md" "$mono/openspec/schemas/spec-driven-e2e/schema.yaml" "schema.yaml の instruction のパスが置換される"
if grep -q 'tests/e2e' "$mono/.claude/skills/e2e-conventions/SKILL.md" "$mono/scripts/check-test-plan.sh"; then
  ng "置換漏れの tests/e2e が残っている"
else
  ok "置換対象ファイルに tests/e2e が残っていない"
fi

# 既存の Playwright 設定がルート以外にある場合、ルートに2つ目を作らない
if [ -f "$mono/playwright.config.ts" ]; then
  ng "ルートに2つ目の playwright.config.ts が作られた"
else
  ok "ルートに2つ目の playwright.config.ts を作らない"
fi
assert_file "$mono/playwright.config.example.ts" "参考用に playwright.config.example.ts を配置する"
assert_grep "frontend/e2e" "$mono/playwright.config.example.ts" "example の testDir も置換される"

# スタンプに e2eRoot が記録される
if node -e "const j=require('$mono/.openspec-e2e-kit.json'); process.exit(j.e2eRoot === 'frontend/e2e' ? 0 : 1)"; then
  ok ".openspec-e2e-kit.json に e2eRoot が記録される"
else
  ng ".openspec-e2e-kit.json の e2eRoot が不正"
fi

# 冪等性: 置換後の内容と比較していないと2回目で毎回 diff が出る
mono_before="$(find "$mono" -type f -not -path '*/.git/*' -not -name '.openspec-e2e-kit.json' -exec shasum {} \; | sort | shasum)"
mono_second="$(node "$KIT_ROOT/install.mjs" install --target "$mono" 2>&1)"
mono_after="$(find "$mono" -type f -not -path '*/.git/*' -not -name '.openspec-e2e-kit.json' -exec shasum {} \; | sort | shasum)"
if [ "$mono_before" = "$mono_after" ]; then
  ok "置換込みでも2回目の install が無変更(冪等)"
else
  ng "2回目の install でファイルが変化した(置換後の内容と比較していない)"
fi
assert_contains "変更はありません" "$mono_second" "2回目は「変更はありません」と報告する"

# ------------------------------------------------------------------ (k)
step "(k) E2E ルートの明示指定と複数設定の扱い"
expl="/tmp/kit-explicit"
rm -rf "$expl"
mkdir -p "$expl/openspec"
git -C "$expl" init -q
expl_out="$(node "$KIT_ROOT/install.mjs" install --target "$expl" --e2e-root playwright/specs 2>&1)"
assert_contains "E2E ルート: playwright/specs" "$expl_out" "--e2e-root の指定が優先される"
assert_file "$expl/playwright/specs/fixtures/README.md" "指定したルートに配置される"
assert_grep "playwright/specs/pages/" "$expl/.claude/skills/e2e-conventions/SKILL.md" "指定したルートで内容が置換される"

# target の外を指す指定は拒否する
node "$KIT_ROOT/install.mjs" install --target "$expl" --e2e-root ../outside >/dev/null 2>&1
rc_escape=$?
if [ "$rc_escape" -eq 2 ]; then ok "'..' を含む --e2e-root を引数エラーで拒否する"; else ng "'..' 指定で exit $rc_escape (期待: 2)"; fi
node "$KIT_ROOT/install.mjs" install --target "$expl" --e2e-root /abs/path >/dev/null 2>&1
rc_abs=$?
if [ "$rc_abs" -eq 2 ]; then ok "絶対パスの --e2e-root を引数エラーで拒否する"; else ng "絶対パス指定で exit $rc_abs (期待: 2)"; fi

# 複数の Playwright 設定: 最も浅いものを採用し、対象外を警告表示する
multi="/tmp/kit-multi"
rm -rf "$multi"
mkdir -p "$multi/openspec" "$multi/packages/web" "$multi/packages/admin"
git -C "$multi" init -q
printf "export default { testDir: './e2e' }\n" > "$multi/packages/web/playwright.config.ts"
printf "export default { testDir: './e2e' }\n" > "$multi/packages/admin/playwright.config.ts"
multi_out="$(node "$KIT_ROOT/install.mjs" install --target "$multi" 2>&1)"
assert_contains "Playwright 設定が 2 件" "$multi_out" "複数設定を検出したことを報告する"
assert_contains "採用: packages/admin/playwright.config.ts" "$multi_out" "最も浅い(同深さなら名前順)設定を採用する"
assert_contains "対象外: packages/web/playwright.config.ts" "$multi_out" "対象外にした設定を列挙する"
assert_contains "--e2e-root" "$multi_out" "指定で上書きできることを案内する"
assert_file "$multi/packages/admin/e2e/fixtures/README.md" "採用した設定のルートに配置される"

# ------------------------------------------------------------------ 結果
step "結果"
printf '  PASS %d / FAIL %d\n' "$pass_count" "$fail_count"
if [ "$fail_count" -gt 0 ]; then
  printf '\n\033[31mセルフテスト失敗\033[0m\n'
  exit 1
fi
printf '\n\033[32mセルフテスト成功\033[0m\n'
