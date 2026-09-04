import { readFileSync } from 'node:fs';

// 終了コード:
//   0 = 失敗もカバレッジ欠落もなし
//   1 = カバレッジ欠落あり(test-plan の TP-ID に対応するテストが未実装/未実行)
//   2 = 引数エラー、または results.json / test-plan.md を読めない
//   3 = 失敗したテストあり(欠落の有無は問わない。両方あるときも 3)
const USAGE = `usage: e2e-report.mjs <change-id> [results.json]

exit code: 0=問題なし / 1=カバレッジ欠落 / 2=引数・入力エラー / 3=失敗テストあり`;

const changeId = process.argv[2];
if (!changeId) { console.error(USAGE); process.exit(2); }
const resultsPath = process.argv[3] ?? 'test-results/e2e-results.json';
const planPath = `openspec/changes/${changeId}/test-plan.md`;

function read(path, what) {
  try {
    return readFileSync(path, 'utf8');
  } catch (err) {
    console.error(`${what} を読めません: ${path} (${err.code ?? err.message})`);
    process.exit(2);
  }
}

const results = JSON.parse(read(resultsPath, 'Playwright JSON レポート'));
const planned = [...new Set(
  [...read(planPath, 'test-plan.md').matchAll(/TP-\d{3}/g)].map(m => m[0])
)];

// Playwright JSON レポーターの test.status は expected/unexpected/flaky/skipped。
// results.length > 1 はリトライ済みを意味するだけで、フレークとは限らない
// (retries>0 では失敗テストも複数 results を持つ)ため status を正とする。
const STATUS_LABEL = { expected: 'pass', unexpected: 'fail', flaky: 'pass', skipped: 'skip' };

const rows = [];
function walk(suite, depth = 0, titlePath = []) {
  // 最上位 suite はファイル名なので、テスト名の前置きには describe だけを使う
  const path = depth === 0 ? titlePath : [...titlePath, suite.title];
  for (const s of suite.suites ?? []) walk(s, depth + 1, path);
  for (const spec of suite.specs ?? []) {
    const tagText = [...(spec.tags ?? []), spec.title].join(' ');
    const tpIds = [...new Set([...tagText.matchAll(/TP-\d{3}/g)].map(m => m[0]))];
    const title = [...path, spec.title].join(' › ');
    for (const t of spec.tests ?? []) {
      const attempts = t.results ?? [];
      const raw = t.status ?? attempts.at(-1)?.status ?? 'unknown';
      const status = STATUS_LABEL[raw] ?? raw;
      const flaky = raw === 'flaky';
      rows.push({ tpIds, title, project: t.projectName || '', status, flaky });
    }
  }
}
for (const suite of results.suites ?? []) walk(suite, 0);

const multiProject = new Set(rows.map(r => r.project)).size > 1;
const executed = new Set(rows.flatMap(r => r.tpIds));
const missing = planned.filter(id => !executed.has(id));

console.log('| TP-ID | テスト | 結果 | フレーク |');
console.log('|-------|-------|------|---------|');
for (const r of rows) {
  const title = multiProject && r.project ? `${r.title} [${r.project}]` : r.title;
  console.log(`| ${r.tpIds.join(',') || '-'} | ${title} | ${r.status} | ${r.flaky ? '⚠' : ''} |`);
}

const count = s => rows.filter(r => r.status === s).length;
const failed = count('fail');
console.log(
  `\n合計 ${rows.length} 件: pass ${count('pass')} / fail ${failed} / skip ${count('skip')}` +
  ` / フレーク ${rows.filter(r => r.flaky).length}`
);

if (missing.length) {
  console.log(`\n⚠ カバレッジ欠落: ${missing.join(', ')} に対応するテストが未実装/未実行`);
}

// 失敗はカバレッジ欠落より重いので 3 を優先する(欠落の警告は上に出力済み)。
if (failed > 0) process.exitCode = 3;
else if (missing.length) process.exitCode = 1;
