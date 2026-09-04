---
name: e2e-conventions
description: Playwright E2Eテストの実装規約。openspec change の apply で test-plan.md
  からテストを実装するとき、既存E2Eテストを修正・レビューするとき、E2Eテストの失敗を
  調査するときは必ずこのスキルを参照すること。tests/e2e/ 配下を触る作業すべてが対象。
---

# E2E実装規約

## ロケーター
- getByRole / getByLabel / getByText を最優先。次点 getByTestId
- page.locator() / page.$() / page.$$() と XPath は禁止。CSS のクラス名だけでなく、
  要素名だけの指定も禁止(`locator('article')` ではなく `getByRole('article')` を使う)
- アクセシブルネームに依存するため、UI文言の変更は仕様変更として test-plan に反映してから行う

## 構造
- Page Object Model: セレクタとページ操作は tests/e2e/pages/ に分離
- fixture は tests/e2e/fixtures/ に置き、fixture 名と作られる状態の対応を
  同ディレクトリの README.md に記録する
- 外部依存のモックは tests/e2e/mocks/ に置く。テストファイル内に直接書かない
- セットアップ/テアダウンは fixture で行う。テスト本体でのログイン操作の繰り返しは禁止
- 1テスト = 1検証意図。テスト間の順序依存は禁止(各テストが独立して実行可能であること)

## 安定性
- page.waitForTimeout / sleep は禁止。自動待機ロケーターと expect のリトライに任せる
- 外部SaaS(決済・メール等)はモック(tests/e2e/mocks/)。自社サービス境界内は実物を使う

## タグとトレーサビリティ
- すべてのテストに { tag: ['@<change-id>', '@TP-NNN'] } を付与
- テスト名は test-plan.md の「操作の意図 + 期待結果」を日本語で要約したものにする

```ts
test('在庫切れ商品は注文できない', { tag: ['@add-checkout', '@TP-002'] }, async ({ page }) => {
  // ...
});
```

## 禁止事項
- 失敗を通すためのアサーション緩和・削除は禁止。期待値の変更が必要な場合は
  仕様変更なので、変更せずに人間へエスカレーションする
