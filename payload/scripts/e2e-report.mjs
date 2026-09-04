import { readFileSync } from 'node:fs';

// 終了コード:
//   0 = 失敗もカバレッジ欠落もなし
//   1 = カバレッジ欠落あり(test-plan の TP-ID に対応するテストが未実装/未実行)
//   2 = 引数エラー、results.json / test-plan.md が読めない、または --max-age 超過で
//       results.json が古い(前の周の結果を読んでいる疑い)
//   3 = 失敗したテストあり(欠落の有無は問わない。両方あるときも 3)
const USAGE = `usage: e2e-report.mjs <change-id> [results.json] [--max-age <seconds>]

  --max-age <seconds>  results.json の実行開始時刻がこの秒数より古ければ exit 2。
                       周回ごとに実行する用途で、前の周の結果を読んでしまう事故を防ぐ。
                       実行時刻が記録されていない場合も検証不能として exit 2 にする

exit code: 0=問題なし / 1=カバレッジ欠落 / 2=引数・入力エラー / 3=失敗テストあり`;

const argv = process.argv.slice(2);
const positional = [];
let maxAge = null;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '-h' || a === '--help') { console.log(USAGE); process.exit(0); }
  if (a === '--max-age' || a.startsWith('--max-age=')) {
    const raw = a.includes('=') ? a.slice('--max-age='.length) : argv[++i];
    maxAge = Number(raw);
    if (!Number.isFinite(maxAge) || maxAge < 0) {
      console.error(`--max-age には 0 以上の秒数を指定してください: ${raw}`);
      process.exit(2);
    }
  } else {
    positional.push(a);
  }
}

const changeId = positional[0];
if (!changeId) { console.error(USAGE); process.exit(2); }
const resultsPath = positional[1] ?? 'test-results/e2e-results.json';
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

// --- 実行の鮮度 ---
// 周回ごとに実行する運用では、その周の Playwright が JSON を書けなかった場合
// (設定エラー、起動失敗、grep が0件マッチ、途中クラッシュ)、前の周の JSON を
// そのまま読んで「fail → pass で解消」と誤報告してしまう。リグレッション検出の
// ために作った遷移表がいちばん静かに壊れる経路なので、実行時刻は必ず出力する。
const startTimeRaw = results.stats?.startTime;
const startTime = startTimeRaw ? new Date(startTimeRaw) : null;
const ageSec = startTime && !Number.isNaN(startTime.getTime())
  ? (Date.now() - startTime.getTime()) / 1000
  : null;

const fmtAge = s => s < 60 ? `${Math.round(s)}秒`
  : s < 3600 ? `${Math.round(s / 60)}分`
  : `${(s / 3600).toFixed(1)}時間`;

if (maxAge !== null) {
  if (ageSec === null) {
    console.error(`${resultsPath} に実行開始時刻(stats.startTime)がありません。鮮度を検証できないため中断します。`);
    process.exit(2);
  }
  if (ageSec > maxAge) {
    console.error(`${resultsPath} の実行開始が ${fmtAge(ageSec)}前で、--max-age ${maxAge} 秒を超えています。`);
    console.error('前の周の結果を読んでいる可能性があります。今回の Playwright 実行が JSON を書けたか確認してください。');
    process.exit(2);
  }
}

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

const durationSec = results.stats?.duration != null ? (results.stats.duration / 1000).toFixed(1) : '?';
console.log(
  `実行開始: ${startTimeRaw ?? '不明'}` +
  (ageSec !== null ? ` (${fmtAge(ageSec)}前)` : '') +
  ` / 所要 ${durationSec}s / ${resultsPath}`
);
console.log('');

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
