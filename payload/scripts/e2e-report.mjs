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
