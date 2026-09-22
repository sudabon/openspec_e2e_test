# openspec-e2e-kit

OpenSpec プロジェクトに「仕様シナリオ → E2E テスト観点 → Playwright テスト → PR レビューでの実行」の
一本の導線を 1 コマンドで組み込む bootstrap kit。カスタムスキーマ・実装規約スキル・レポータ・CI ゲートを
配布物 (`payload/`) として持ち、インストーラが対象リポジトリへ冪等にコピーする。

`openspec update` で再生成される `.claude/commands/opsx/` などの生成物には一切触れないので、
OpenSpec 本体のアップグレードで設定が飛ぶことがない。

## 導入

```bash
npx github:sudabon/openspec_e2e_test
```

`openspec init` の前でも後でも導入できる。

```bash
# openspec init の前に導入する場合
npx github:sudabon/openspec_e2e_test --language Japanese
openspec init --tools claude          # --language は付けない

# openspec init の後に導入する場合
openspec init --tools claude --language Japanese
npx github:sudabon/openspec_e2e_test
```

kit が `openspec/config.yaml` を作成した後の `openspec init` に `--language` を付けると
**エラーで中断する**(OpenSpec は既存の config を `--language` で上書きしない)。
言語は kit の `--language` で指定する。`openspec init` は既存の config.yaml とカスタムスキーマを保持したまま初期化する。

対象リポジトリのルートで実行する。別ディレクトリを指定する場合は `--target` を使う。

```bash
npx github:sudabon/openspec_e2e_test install --target /path/to/repo
npx github:sudabon/openspec_e2e_test --dry-run          # 書き込まず、実行予定だけ表示
```

## 更新

```bash
npx github:sudabon/openspec_e2e_test update
```

同一内容のファイルは黙って skip される。対象側で内容が変わっているファイルは
**上書きせず** unified diff を表示して skip し、最後に一覧表示する。
意図的に kit 側で揃えたい場合だけ `--force` を付ける。

```
usage: openspec-e2e-kit [install|update] [--force] [--dry-run] [--target <dir>] [--e2e-root <path>] [--language <lang>]
```

### E2E ルートの自動判別

E2E テストの置き場所はプロジェクトによって違う(`tests/e2e/`、`e2e/`、
モノレポなら `frontend/e2e/` など)。インストーラは**リポジトリを探索して自動判別する**ので、
導入後にパスを付け替える手作業は不要である。

判別の優先順:

1. `--e2e-root <path>` の明示指定
2. `.openspec-e2e-kit.json` に記録された `e2eRoot`(update 時に配置が動かないようにするため)
3. **Playwright 設定の `testDir`** — 深さ 3 まで `playwright.config.*` を探し、
   設定ファイルの位置を基準に `testDir` を解決する
   (例: `frontend/playwright.config.ts` + `testDir: './e2e'` → `frontend/e2e`)
4. 既存ディレクトリの存在(`e2e/`、`tests/e2e/`、`playwright/`)
5. 既定値 `tests/e2e`

判別したルートは、**配置先と配布ファイルの中身の両方**に反映される。
`e2e-conventions/SKILL.md` の `pages/` `fixtures/` `mocks/`、スキーマの instruction、
`check-test-plan.sh` の検索対象がすべて実際のパスに書き換わる。

```
$ npx github:sudabon/openspec_e2e_test --dry-run
E2E ルート: frontend/e2e  (frontend/playwright.config.ts の testDir)
```

Playwright 設定が**複数**見つかった場合は最も浅いものを採用し、採用したものと対象外に
したものを表示する。意図と違えば `--e2e-root` で指定する。
E2E ルートが前回と変わった場合、**古い場所のファイルは自動削除せず警告のみ**表示する。

## 導入されるもの

| 配置先 | 内容 |
|--------|------|
| `openspec/schemas/spec-driven-e2e/` | `spec-driven` を fork し `test-plan` アーティファクトを追加したカスタムスキーマ |
| `.claude/skills/e2e-conventions/SKILL.md` | Playwright E2E の実装規約(ロケーター・構造・安定性・タグ・禁止事項) |
| `scripts/e2e-report.mjs` | Playwright JSON レポートから TP-ID 別の結果表とカバレッジ欠落を出力 |
| `scripts/check-test-plan.sh` | change 差分に対し test-plan.md とタグ付きテストの存在を検証(CI 用) |
| `playwright.config.ts` | 推奨設定。**リポジトリ内のどこかに既存の config があるときは `playwright.config.example.ts` として配置**し、既存設定は上書きしない |
| `<e2eRoot>/fixtures/README.md` | シード fixture 名 → 作られる状態の対応表テンプレート(パスは自動判別) |
| `openspec/config.yaml` | `schema: spec-driven-e2e` の設定と、context 内へのマーカー付きブロックの追記(新規作成時は `--language` の context も) |
| `.openspec-e2e-kit.json` | 導入した kit のバージョンと導入時刻 |

`openspec init` が書く既定値 `schema: spec-driven` は `spec-driven-e2e` へ自動で切り替える。
進行中の change は各自の `.openspec.yaml` にスキーマを記録しているので影響を受けない。
それ以外の `schema:`(例: `quality-driven`)が設定されている場合は**変更せず警告のみ**表示する。
その場合は手動で `schema: spec-driven-e2e` へ変更するか、change 単位で `--schema spec-driven-e2e` を指定する。

### config.yaml の context

kit の行は `context: |` の**内側**にマーカーで囲んで置き、update ではマーカー間だけを書き換える。
マーカーの外(`Language:` や他ツールの行)には触らない。

```yaml
context: |
  Language: Japanese
  # --- openspec-e2e-kit ---
  E2Eテスト: Playwright。実装規約は .claude/skills/e2e-conventions/SKILL.md に従う。
  テストには必ず @<change-id> と @TP-NNN タグを付ける。
  # --- /openspec-e2e-kit ---
```

v0.1.0 は `context: |` ごとトップレベルのマーカーで囲んでいたため、その context に後から追記した行が
update のたびに消えていた。旧形式を見つけた場合は、kit 以外の行を保持したまま上の形へ移行する。

### `scripts/e2e-report.mjs` の終了コード

```bash
node scripts/e2e-report.mjs <change-id> [results.json] [--max-age <seconds>]
```

| コード | 意味 |
|--------|------|
| 0 | 失敗もカバレッジ欠落もなし |
| 1 | カバレッジ欠落あり(test-plan の TP-ID に対応するテストが未実装/未実行) |
| 2 | 引数エラー、`results.json` / `test-plan.md` を読めない、または `--max-age` 超過 |
| 3 | 失敗したテストあり(欠落の有無は問わない) |

失敗はカバレッジ欠落より重いので、両方あるときは 3 を返す(欠落の警告は出力に載る)。
レポート転記が目的で終了コードを見ない使い方なら `|| true` を付けて呼ぶ。

### 同じ change を複数回まわすときは `--max-age` を付ける

レビューと修正を2周まわして「1周目 → 2周目」の遷移表を作る使い方には、静かな失敗モードがある。
2周目の Playwright が JSON を書けなかった場合(設定エラー、起動失敗、`--grep` が0件マッチ、
途中クラッシュ)、`e2e-report.mjs` は**1周目の古い JSON をそのまま2周目の結果として報告する**。
「fail → pass で解消」という嘘の遷移が出て、リグレッション検出のために作った表がいちばん
静かに壊れる。

対策は2段構え。

1. **実行開始時刻を必ず出力する** — 出力の1行目に `実行開始: <ISO8601> (N分前) / 所要 Ns` が入る。
   1周目と2周目で同じ時刻が並んでいれば、同一実行を2回転記したことが目で見てわかる
2. **`--max-age <seconds>` で落とす** — 実行開始がその秒数より古ければ結果表を出さずに exit 2。
   周回ごとに呼ぶ自動化ではこれを付ける。実行時刻が記録されていない場合も検証不能として
   exit 2 にする(fail closed)

```bash
# 直前に走らせた実行の結果だけを受け付ける
node scripts/e2e-report.mjs add-checkout test-results/e2e-results.json --max-age 600
```

`--max-age` は**テストスイートの所要時間より長く**取る。`stats.startTime` は実行の開始時刻なので、
30分かかるスイートでは正常な結果でも30分前の値になる。

## 導入後の開発フロー

1. **propose** — `openspec` の change を起票する。`spec-driven-e2e` スキーマでは
   `proposal → specs → design → test-plan → tasks` の順にアーティファクトが作られる。
   `test-plan.md` は specs のシナリオを E2E で観測可能な観点へ翻訳したもので、TP-001 から
   連番の ID が振られる。
2. **test-plan レビュー** — ここが人間のレビューポイント。specs のシナリオが漏れなく
   拾われているか、E2E 対象外にした判断とその理由が妥当かを見る。
   test-plan は新しい仕様を定義する場所ではない(受け入れ基準の原本は specs のシナリオ)。
3. **apply** — `tasks.md` の各 TP-ID に 1:1 対応する E2E 実装タスクを消化する。
   実装は `.claude/skills/e2e-conventions/SKILL.md` の規約に従い、すべてのテストに
   `@<change-id>` と `@TP-NNN` タグを付ける。
4. **pr-review-codex-fix** — レビューと修正の各周で change スコープの E2E を実行し、
   `scripts/e2e-report.mjs <change-id>` の出力(TP-ID 別の結果表とカバレッジ欠落)を
   レポートに転記する。テストを通すためのアサーション緩和・削除は禁止で、期待値の食い違いは
   仕様変更としてエスカレーションする。

## CI ゲート

reusable workflow を呼び出すスタブを、対象リポジトリの `.github/workflows/` に置く。

```yaml
name: e2e-gate
on: [pull_request]
jobs:
  e2e-gate:
    uses: sudabon/openspec_e2e_test/.github/workflows/openspec-e2e-gate.yml@main
    with:
      e2e-base-url: http://localhost:3000
      # package.json と playwright.config.* がルートに無い構成では指定する
      # working-directory: frontend
```

ゲートがやること:

1. `scripts/check-test-plan.sh` — PR に `openspec/changes/` の差分があるとき、
   その change に `test-plan.md` があり、`@<change-id>` タグ付きの E2E テストが
   `tests/e2e/` に存在することを検証する
2. change スコープの Playwright 実行 — `--grep "@(<変更された change-id>)|@smoke"`。
   change の差分が無い PR では `@smoke` のみ実行する

reusable workflow は**呼び出し側リポジトリの文脈で動く**ため、前提が2つある。

1. **kit が導入済みであること** — `scripts/check-test-plan.sh` が存在しないと、
   ゲートはそのステップで失敗する
2. **`working-directory` に `package-lock.json` が存在すること** — 依存インストールに
   `npm ci` を使うため、lockfile が無いリポジトリや pnpm / yarn を使うリポジトリでは失敗する。
   その場合はこの reusable workflow を使わず、`check-test-plan.sh` の実行と
   `--grep` 付きの `playwright test` を呼び出し側で組むほうが早い

`package.json` と `playwright.config.*` がリポジトリルートに無い構成では
`working-directory` を指定する。change-id の検出は常にリポジトリルート基準で行われる。

## OpenSpec をアップグレードしたとき

`spec-driven-e2e` はビルトインスキーマの fork なので、OpenSpec 本体のスキーマ形式が変わると
追従が必要になる。アップグレード後は対象リポジトリで validate を回すこと。

```bash
openspec schema validate spec-driven-e2e
```

ただし `schema validate` は**構造しか見ない**。アーティファクトの依存関係や context の
受け渡しが壊れていても通ってしまうため、実際の change で確認するほうが確実である。

```bash
openspec new change tmp-upgrade-check
openspec status --change tmp-upgrade-check
#   [-] test-plan (blocked by: specs)
#   [-] tasks (blocked by: specs, design, test-plan)   ← この2行が出ること
openspec instructions test-plan --change tmp-upgrade-check | head -30
#   <project_context> に config.yaml の E2E 2行が入っていること
```

kit 側のリポジトリではこの検証を `npm test` の (i) で自動化してある。
失敗した場合は、kit 側で `spec-driven` を再 fork し直して `test-plan` アーティファクトの
追加を当て直したうえで、`npx github:sudabon/openspec_e2e_test update` で配り直す。

## kit 自体の開発

```bash
npm test    # test/selftest.sh。/tmp にサンドボックスを作り、導入・冪等性・スキーマ validate・レポータを検証
```

外部 dependencies は持たない(インストーラは Node 標準ライブラリのみ)。
`openspec` CLI が無い環境ではスキーマ validate のステップだけ skip される。
