# openspec-e2e-kit 構築指示書(Claude Code 向け)

あなた(Claude Code)への作業依頼書。このリポジトリ `openspec_e2e_test` を、
**openspec プロジェクトに E2E テスト統合一式を配布する bootstrap kit** として構築する。
この文書は自己完結しており、必要な仕様・ファイル内容はすべて本文と付録にある。

---

## 1. 背景と目的

開発プロセスは「openspec で propose(change 起票)→ apply(実装)→ pr-review-codex-fix
スキルでレビューと修正を2周」という流れである。ここに以下を統合したい:

- propose 時に、specs のシナリオ(受け入れ基準)から **test-plan.md(E2Eテスト観点書)** を自動生成
- apply 時に、test-plan に基づく **Playwright E2E テスト**をタグ付きで実装
- pr-review-codex-fix の各周で **E2E を選択実行し、結果表とカバレッジ欠落をレポート**

この統合をプロジェクトごとに手作業で仕込むのは負担なので、本リポジトリを
「1コマンドで導入・更新できる kit」にする。設計方針:

- **openspec のカスタムスキーマ機構を使う**(生成物 `.claude/commands/opsx/` 等は
  `openspec update` で上書きされるため、絶対にカスタマイズ対象にしない)
- 配布物は `payload/` に原本を置き、`install.mjs` が対象リポジトリへ冪等コピーする
- CI ゲートは reusable workflow として本リポジトリに置き、対象リポジトリは呼び出すだけ

## 2. 作業ルール(必読)

1. タスクは §4 の順に進め、各タスク完了時に**タスク単位でコミット**する(コミットメッセージは `T<番号>: <内容>`)。
2. **git push はしない。** push が必要な場面ではユーザーに確認を求める。
3. `/Users/y-suda/workspace/tribeck/pr_review_automation`(pr-review-codex-fix スキル)は
   **T9 の承認が下りるまで読み取り専用**。それまで一切変更しないこと。
4. openspec CLI のコマンド体系はバージョンで変わる可能性がある。本書のコマンド例が
   実際と異なる場合は `openspec --help` / `openspec schema --help` で確認し、
   **本書の意図(何を達成するか)を優先して**コマンドを読み替えること。読み替えた場合は
   最終レポートに明記する。
5. 不明点・設計判断が必要な点は、勝手に進めずユーザーに質問する。
6. 破壊的操作(rm -rf 等)はサンドボックス(`/tmp` 配下)でのみ行う。

## 3. 最終成果物(ディレクトリ構造)

```
openspec_e2e_test/
├── INSTRUCTIONS.md                  # 本書(既存)
├── README.md                        # T8 で作成(導入・更新手順)
├── package.json                     # bin: openspec-e2e-kit → install.mjs
├── install.mjs                      # インストーラ(Node 標準ライブラリのみ)
├── payload/                         # 配布物の原本
│   ├── openspec/
│   │   └── schemas/spec-driven-e2e/ # カスタムスキーマ(schema.yaml + templates/)
│   ├── .claude/
│   │   └── skills/e2e-conventions/SKILL.md
│   ├── scripts/
│   │   ├── e2e-report.mjs
│   │   └── check-test-plan.sh
│   ├── playwright.config.example.ts
│   └── tests/e2e/fixtures/README.md
├── .github/workflows/
│   └── openspec-e2e-gate.yml        # reusable workflow (workflow_call)
├── test/
│   ├── fixtures/sample-results.json # e2e-report.mjs のセルフテスト用
│   └── selftest.sh                  # npm test から呼ぶ
└── docs/
    └── pr-review-codex-fix-e2e-design.md  # T9 で作成(設計書)
```

## 4. タスク一覧

### T1: 環境確認とリポジトリ初期化

1. `node --version`(20 以上)を確認。
2. openspec CLI を確認: `openspec --version`。未導入なら `npm i -g @fission-ai/openspec`。
3. `openspec schema --help` を実行し、fork / validate / which 相当のサブコマンドが
   存在することを確認(なければ §2-4 に従い読み替え方針を決めてから進む)。
4. `package.json` を作成:
   - `"name": "openspec-e2e-kit"`, `"version": "0.1.0"`, `"type": "module"`
   - `"bin": { "openspec-e2e-kit": "./install.mjs" }`
   - `"scripts": { "test": "bash test/selftest.sh" }`
   - dependencies は**空**にすること(インストーラは Node 標準ライブラリのみで書く)

**完了条件**: 上記コマンドが通り、package.json がコミットされている。

### T2: カスタムスキーマの作成(payload/openspec/schemas/)

ビルトインスキーマ `spec-driven` を fork して `spec-driven-e2e` を作り、
test-plan アーティファクトを追加する。fork はプロジェクト文脈で動くため、
一時ディレクトリに openspec プロジェクトを作って作業する。

1. `/tmp/schema-work` を作成し、その中で `openspec init` を実行
   (非対話フラグがあれば使う。対話が必要なら最小構成の `openspec/` を手で作ってよい)。
2. `openspec schema fork spec-driven spec-driven-e2e` を実行し、
   `openspec/schemas/spec-driven-e2e/`(schema.yaml + templates/)が生成されることを確認。
3. **生成された schema.yaml の実際の書式に合わせて**、次の意味の変更を加える:
   - アーティファクト `test-plan` を追加(生成物 `test-plan.md`、依存 `specs`)
   - `tasks` アーティファクトの依存に `test-plan` を追加
4. `templates/test-plan.md` を新規作成 → 内容は **付録A**。
5. fork された `templates/tasks.md`(相当のテンプレート)の末尾に **付録B** の指示を追記。
6. `openspec schema validate spec-driven-e2e` が通ることを確認。
7. 完成した `openspec/schemas/spec-driven-e2e/` 一式を本リポジトリの
   `payload/openspec/schemas/spec-driven-e2e/` へコピーする。

**完了条件**: validate が通ったスキーマ一式が payload に入っている。
schema.yaml の diff(fork 直後 → 変更後)を最終レポートに含めること。

### T3: e2e-conventions スキル(payload/.claude/skills/)

`payload/.claude/skills/e2e-conventions/SKILL.md` を **付録C** の内容で作成する。
一字一句このままでよい(改善提案があれば実施せず、最終レポートで提案すること)。

### T4: scripts(payload/scripts/)

1. `payload/scripts/e2e-report.mjs` を **付録D** をベースに作成。
2. `payload/scripts/check-test-plan.sh` を **付録E** の内容で作成し、実行権限を付与。

### T5: Playwright 設定と fixtures README(payload/)

1. `payload/playwright.config.example.ts` を **付録F** の内容で作成。
   ファイル名を `.example.ts` にしている理由: 既存プロジェクトの設定を上書きしないため。
   install.mjs は対象に `playwright.config.ts` が**無い場合のみ** `.example` を外して配置する。
2. `payload/tests/e2e/fixtures/README.md` を作成。内容: 「fixture 名 → 作られる状態」の
   対応表テンプレート(空の表 + 記入例1行)と、シードAPI方式/fixture直接方式の説明2〜3行。

### T6: install.mjs(インストーラ本体)

Node 標準ライブラリのみで実装する。仕様:

**CLI**: `openspec-e2e-kit [install|update] [--force] [--dry-run] [--target <dir>]`
- サブコマンド省略時は `install`。`--target` 省略時はカレントディレクトリ。
- `update` は `install` と同処理でよいが、出力の文言を「更新」にする。

**動作**:
1. `--target` が git リポジトリでない場合は警告して確認を求める(`--force` でスキップ)。
2. `payload/` 配下の全ファイルを target へ再帰コピー。ただし:
   - target に同一内容のファイルがある → skip(サイレント)
   - target に**異なる内容**のファイルがある → unified diff を表示して skip。
     `--force` 時のみ上書き。skip したファイルは最後に一覧表示。
   - `playwright.config.example.ts` は特別扱い: target に `playwright.config.ts` が
     無ければ `playwright.config.ts` として配置、あれば `.example.ts` のまま配置。
3. `openspec/config.yaml` のマージ(冪等):
   - `schema:` キーが無ければ `schema: spec-driven-e2e` を追加。既に別値があれば
     変更せず警告表示。
   - マーカー `# --- openspec-e2e-kit ---` 〜 `# --- /openspec-e2e-kit ---` で囲んだ
     context 追記ブロック(内容は付録Gの2行)を追加。マーカーが既にあればブロックを置換。
   - config.yaml 自体が無ければ、schema 行とマーカーブロックだけの config.yaml を新規作成。
4. `.openspec-e2e-kit.json` を target 直下に書く: `{ "version": <package.jsonのversion>, "installedAt": <ISO8601> }`
5. `--dry-run` 時は一切書き込まず、実行予定の操作を一覧表示する。
6. 終了コード: 正常 0(skip があっても 0)、引数エラー・例外時のみ非 0。

**完了条件**: T7 のセルフテストで検証されること。

### T7: セルフテスト(test/)

1. `test/fixtures/sample-results.json` を作成: Playwright JSON レポーターの出力を模した
   最小フィクスチャ(suites がネストし、pass 1件・fail 1件・retry で pass した flaky 1件、
   タグに TP-001〜TP-003 を含む)。**可能なら実際に最小の Playwright プロジェクトを
   `/tmp` に作って本物の JSON 出力を採取し、それを整形して使うこと**(構造の正確性が目的)。
   採取した場合、e2e-report.mjs のパース処理(付録D)を実構造に合わせて修正してよい。
2. `test/selftest.sh` を作成。内容:
   - (a) `/tmp/kit-sandbox` を作り直し、最小の openspec プロジェクト構造を用意
   - (b) `node install.mjs install --target /tmp/kit-sandbox` を実行
   - (c) スキーマ・スキル・scripts が配置されたこと、config.yaml がマージされたことを assert
   - (d) もう一度 install を実行し、**2回目が無変更で終わる(冪等)** ことを assert
   - (e) sandbox 内で `openspec schema validate spec-driven-e2e` が通ることを assert
     (CLI が無い CI 環境を考慮し、openspec が無ければ (e) は skip と表示)
   - (f) `test/fixtures/sample-results.json` と架空の test-plan.md を使って
     `e2e-report.mjs` を実行し、結果表に pass/fail/フレークが出ること、
     欠落 TP-ID の警告が出ることを assert
3. `npm test` が通ること。

**完了条件**: `npm test` が exit 0 で、(a)〜(f) の各 assert 結果が出力に表示される。

### T8: reusable workflow と README

1. `.github/workflows/openspec-e2e-gate.yml` を **付録H** の内容で作成。
2. `README.md` を作成。含めるもの:
   - このリポジトリが何か(3行程度)
   - 導入: `npx github:<org>/openspec_e2e_test`(org 名は git remote から取得。
     remote 未設定ならプレースホルダのままにし、最終レポートで指摘)
   - 更新: `npx github:<org>/openspec_e2e_test update`
   - 呼び出し側リポジトリに置く workflow スタブの例(付録H末尾)
   - 導入後の開発フロー(propose → test-plan レビュー → apply → pr-review-codex-fix)の要約
   - openspec アップグレード時の注意(`openspec schema validate spec-driven-e2e` を回す)

### T9: pr-review-codex-fix への E2E 統合【設計のみ → 承認後に実装】

1. `/Users/y-suda/workspace/tribeck/pr_review_automation` を**読み取り専用で**調査し、
   スキルの構造(エントリポイント、2周ループの実装箇所、レポート生成箇所)を把握する。
2. `docs/pr-review-codex-fix-e2e-design.md` を本リポジトリに作成。内容:
   - 現状のスキル構造の要約
   - v1(E2E 実行 + 結果表をレポートに追加)の変更箇所と具体的な差分案
   - v2(失敗分類 → codex 修正タスク接続)の変更方針(実装はしない)
   - v1 の仕様は以下に従うこと:
     - change-id 特定: PR 差分(`git diff <base> --name-only`)から
       `openspec/changes/<id>/` を検出。不可ならブランチ名から推定。それも不可なら
       E2E をスキップし「change-id 特定不可」とレポートに明記(黙って省略しない)
     - 実行: `npx playwright test --grep "@<change-id>|@smoke"`(失敗しても続行)
     - 集計: `scripts/e2e-report.mjs <change-id>` の出力をレポートに転記
     - レポート形式: 「TP-ID | テスト | 1周目 | 2周目 | 対応」の表 + カバレッジ欠落警告
     - 禁止: テストのアサーション緩和・削除。期待値の食い違いは修正せず
       エスカレーション項目としてレポートに載せる
3. **ここで作業を止め、設計書のレビューをユーザーに依頼する。**
4. 承認後: pr_review_automation にブランチ `feat/e2e-report` を作成して v1 を実装。
   コミットまで(push しない)。

## 5. 受け入れ基準(最終チェックリスト)

- [ ] `npm test` が通る(冪等性・スキーマ validate・レポーターのセルフテスト含む)
- [ ] `node install.mjs --dry-run --target /tmp/any` が書き込みゼロで動作一覧を出す
- [ ] payload のスキーマが `openspec schema validate` を通過している
- [ ] `.claude/commands/` や `.claude/skills/openspec-*` など **openspec 生成物を一切含まない**
- [ ] package.json に外部 dependencies がない
- [ ] README だけ読めば第三者が導入できる
- [ ] docs/pr-review-codex-fix-e2e-design.md が作成され、レビュー待ちになっている
- [ ] 最終レポート(下記)を出力した

## 6. 最終レポートの形式

作業完了時(T9-3 の停止時点)に、以下をまとめて報告すること:
タスクごとの結果 / schema.yaml の変更 diff / コマンドを読み替えた箇所(§2-4)/
セルフテストの出力要約 / 未解決事項・ユーザーへの質問 / 改善提案(あれば)。

---
---

# 付録(ファイル内容の原本)

## 付録A: payload/openspec/schemas/spec-driven-e2e/templates/test-plan.md

````markdown
# Test Plan

このアーティファクトは specs/ 配下の各 Requirement のシナリオ(受け入れ基準)を
E2E で検証可能な観点に翻訳したものである。受け入れ基準の原本は specs のシナリオで
あり、本ファイルで新しい仕様を定義してはならない。

## 作成ルール
- specs/ のすべてのシナリオを列挙し、E2E で検証するもの・しないもの(unit/integration に委譲)を明示する
- E2E 観点には TP-001 から連番の ID を振る
- 各観点に: 対応シナリオ、前提状態(シード fixture 名)、操作の意図、期待結果、リスク(高/中/低)を記載する
- セレクタ・URL・実装詳細は書かない(実装は apply フェーズの責務)
- 異常系・権限境界・多重送信・空データを必ず検討し、E2E 対象外とした場合は理由を書く

## E2E観点一覧

| TP-ID | 対応シナリオ | 前提(fixture) | 操作の意図 | 期待結果 | リスク |
|-------|-------------|---------------|-----------|---------|--------|
| TP-001 | ... | ... | ... | ... | 高 |

## E2E対象外(委譲先と理由)

| シナリオ | 委譲先 | 理由 |
|---------|--------|------|

## タグ対応
- すべての実装テストに `@<change-id>` と `@TP-NNN` を付与すること
````

## 付録B: templates/tasks.md への追記内容

````markdown
## E2Eテスト実装タスク(必須)
- test-plan.md の各 TP-ID に対して、対応する E2E 実装タスクを 1:1 で列挙すること
- 各タスクには TP-ID とタグ名(@<change-id>, @TP-NNN)を明記すること
- E2E 実装タスクの前に、必要なシード fixture の追加タスクを置くこと
- 実装規約は .claude/skills/e2e-conventions/SKILL.md に従うこと
````

## 付録C: payload/.claude/skills/e2e-conventions/SKILL.md

````markdown
---
name: e2e-conventions
description: Playwright E2Eテストの実装規約。openspec change の apply で test-plan.md
  からテストを実装するとき、既存E2Eテストを修正・レビューするとき、E2Eテストの失敗を
  調査するときは必ずこのスキルを参照すること。tests/e2e/ 配下を触る作業すべてが対象。
---

# E2E実装規約

## ロケーター
- getByRole / getByLabel / getByText を最優先。次点 getByTestId
- 生の CSS / XPath セレクタは禁止
- アクセシブルネームに依存するため、UI文言の変更は仕様変更として test-plan に反映してから行う

## 構造
- Page Object Model: セレクタとページ操作は tests/e2e/pages/ に分離
- セットアップ/テアダウンは fixture で行う。テスト本体でのログイン操作の繰り返しは禁止
- 1テスト = 1検証意図。テスト間の順序依存は禁止(各テストが独立して実行可能であること)

## 安定性
- page.waitForTimeout / sleep は禁止。自動待機ロケーターと expect のリトライに任せる
- 外部SaaS(決済・メール等)はモック。自社サービス境界内は実物を使う

## タグとトレーサビリティ
- すべてのテストに { tag: ['@<change-id>', '@TP-NNN'] } を付与
- テスト名は test-plan.md の「操作の意図 + 期待結果」を日本語で要約したものにする

## 禁止事項
- 失敗を通すためのアサーション緩和・削除は禁止。期待値の変更が必要な場合は
  仕様変更なので、変更せずに人間へエスカレーションする
````

## 付録D: payload/scripts/e2e-report.mjs(骨格 — T7 で実構造に合わせて調整可)

````js
import { readFileSync } from 'node:fs';

const changeId = process.argv[2];
if (!changeId) { console.error('usage: e2e-report.mjs <change-id> [results.json]'); process.exit(2); }
const resultsPath = process.argv[3] ?? 'test-results/e2e-results.json';
const results = JSON.parse(readFileSync(resultsPath, 'utf8'));
const planPath = `openspec/changes/${changeId}/test-plan.md`;

const planned = [...new Set(
  [...readFileSync(planPath, 'utf8').matchAll(/TP-\d{3}/g)].map(m => m[0])
)];

const rows = [];
function walk(suite) {
  for (const s of suite.suites ?? []) walk(s);
  for (const spec of suite.specs ?? []) {
    const attempts = spec.tests?.[0]?.results ?? [];
    const status = attempts.at(-1)?.status ?? 'unknown';
    const retried = attempts.length > 1;
    const tagText = [...(spec.tags ?? []), spec.title].join(' ');
    const tpIds = [...new Set([...tagText.matchAll(/TP-\d{3}/g)].map(m => m[0]))];
    rows.push({ tpIds, title: spec.title, status, retried });
  }
}
for (const suite of results.suites ?? []) walk(suite);

const executed = new Set(rows.flatMap(r => r.tpIds));
const missing = planned.filter(id => !executed.has(id));

console.log('| TP-ID | テスト | 結果 | フレーク |');
console.log('|-------|-------|------|---------|');
for (const r of rows) {
  console.log(`| ${r.tpIds.join(',') || '-'} | ${r.title} | ${r.status} | ${r.retried ? '⚠' : ''} |`);
}
if (missing.length) {
  console.log(`\n⚠ カバレッジ欠落: ${missing.join(', ')} に対応するテストが未実装/未実行`);
  process.exitCode = 1;
}
````

## 付録E: payload/scripts/check-test-plan.sh

````bash
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
````

## 付録F: payload/playwright.config.example.ts

````ts
import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  retries: 1, // リトライ成功 = フレークとして記録される
  reporter: [
    ['list'],
    ['json', { outputFile: 'test-results/e2e-results.json' }],
  ],
  use: {
    trace: 'on-first-retry',
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:3000',
  },
});
````

## 付録G: config.yaml に追記する context ブロックの中身(マーカー間の2行)

```
E2Eテスト: Playwright。実装規約は .claude/skills/e2e-conventions/SKILL.md に従う。
テストには必ず @<change-id> と @TP-NNN タグを付ける。
```

## 付録H: .github/workflows/openspec-e2e-gate.yml

````yaml
name: openspec-e2e-gate
on:
  workflow_call:
    inputs:
      base-ref:
        type: string
        default: origin/main
      e2e-base-url:
        type: string
        default: http://localhost:3000

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - name: test-plan とタグ付きテストの存在チェック
        run: bash scripts/check-test-plan.sh "${{ inputs.base-ref }}"
      - name: 依存インストール
        run: npm ci && npx playwright install --with-deps chromium
      - name: change スコープの E2E 実行
        env:
          E2E_BASE_URL: ${{ inputs.e2e-base-url }}
        run: |
          ids=$(git diff --name-only "${{ inputs.base-ref }}"...HEAD -- 'openspec/changes/**' \
            | grep -v '/archive/' | cut -d/ -f3 | sort -u | paste -sd'|' -)
          if [ -n "$ids" ]; then
            npx playwright test --grep "@($ids)|@smoke"
          else
            npx playwright test --grep "@smoke"
          fi
````

呼び出し側リポジトリに置くスタブ(README に記載するもの):

````yaml
name: e2e-gate
on: [pull_request]
jobs:
  e2e-gate:
    uses: <org>/openspec_e2e_test/.github/workflows/openspec-e2e-gate.yml@main
    with:
      e2e-base-url: http://localhost:3000
````

注: reusable workflow は呼び出し側のリポジトリ文脈で動くため、scripts/check-test-plan.sh は
kit 導入済み(= payload 配布済み)であることが前提。README にその旨を明記すること。
