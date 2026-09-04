#!/usr/bin/env node
// openspec-e2e-kit installer.
// Node 標準ライブラリのみで実装する(外部依存を持たせない)。
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, existsSync, chmodSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';

const HERE = dirname(fileURLToPath(import.meta.url));
const PAYLOAD = join(HERE, 'payload');
const STAMP_FILE = '.openspec-e2e-kit.json';
const MARKER_START = '# --- openspec-e2e-kit ---';
const MARKER_END = '# --- /openspec-e2e-kit ---';
const CONTEXT_LINES = [
  'E2Eテスト: Playwright。実装規約は .claude/skills/e2e-conventions/SKILL.md に従う。',
  'テストには必ず @<change-id> と @TP-NNN タグを付ける。',
];
const SCHEMA_NAME = 'spec-driven-e2e';

// payload 内の E2E ルート。導入先の実際のルートを検出して、配置先とファイル内容の
// 両方をこの文字列から置き換える。payload 側はリテラルのまま置いておくことで、
// プレースホルダを使わずに payload 単体でも読める・テストできる状態を保つ。
const E2E_ROOT_DEFAULT = 'tests/e2e';

// 内容に E2E ルートのパスを含み、置換が必要なファイル(payload 相対)
const E2E_PATH_FILES = new Set([
  '.claude/skills/e2e-conventions/SKILL.md',
  'openspec/schemas/spec-driven-e2e/schema.yaml',
  'scripts/check-test-plan.sh',
  'playwright.config.example.ts',
]);

const PW_CONFIG_RE = /^playwright\.config\.(?:[cm]?[jt]s)$/;
const SCAN_SKIP_DIRS = new Set([
  'node_modules', '.git', 'dist', 'build', 'out', 'coverage', 'vendor',
  '.next', '.nuxt', '.svelte-kit', '.turbo', '.cache', '.venv', 'target', 'tmp',
]);
const SCAN_MAX_DEPTH = 3;

const USAGE = `usage: openspec-e2e-kit [install|update] [--force] [--dry-run] [--target <dir>] [--e2e-root <path>]

  install            payload を対象リポジトリへ導入する(既定)
  update             install と同じ処理。出力の文言が「更新」になる
  --target <dir>     対象ディレクトリ(既定: カレントディレクトリ)
  --e2e-root <path>  E2E テストの置き場所(target 相対)。省略時は Playwright 設定の
                     testDir から自動判別し、見つからなければ ${E2E_ROOT_DEFAULT} を使う
  --force            差分のあるファイルを上書きし、git リポジトリ確認をスキップする
  --dry-run          一切書き込まず、実行予定の操作だけを表示する
  -h, --help         このヘルプを表示する`;

// ---------------------------------------------------------------- args

function parseArgs(argv) {
  const opts = { command: null, target: null, force: false, dryRun: false, help: false, e2eRoot: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === 'install' || a === 'update') {
      if (opts.command) throw new UsageError(`サブコマンドが重複しています: ${a}`);
      opts.command = a;
    } else if (a === '--force') {
      opts.force = true;
    } else if (a === '--dry-run') {
      opts.dryRun = true;
    } else if (a === '-h' || a === '--help') {
      opts.help = true;
    } else if (a === '--target') {
      const v = argv[++i];
      if (!v) throw new UsageError('--target には値が必要です');
      opts.target = v;
    } else if (a.startsWith('--target=')) {
      opts.target = a.slice('--target='.length);
      if (!opts.target) throw new UsageError('--target には値が必要です');
    } else if (a === '--e2e-root' || a.startsWith('--e2e-root=')) {
      const v = a.includes('=') ? a.slice('--e2e-root='.length) : argv[++i];
      if (!v) throw new UsageError('--e2e-root には値が必要です');
      opts.e2eRoot = normalizeE2eRoot(v);
    } else {
      throw new UsageError(`不明な引数: ${a}`);
    }
  }
  opts.command ??= 'install';
  opts.target = resolve(opts.target ?? process.cwd());
  return opts;
}

class UsageError extends Error {}

// ---------------------------------------------------------------- fs helpers

function walkFiles(root, base = root) {
  const out = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const abs = join(root, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(abs, base));
    else if (entry.isFile()) out.push(relative(base, abs).split(sep).join('/'));
  }
  return out.sort();
}

function isInsideGitRepo(dir) {
  let cur = resolve(dir);
  for (;;) {
    if (existsSync(join(cur, '.git'))) return true;
    const parent = dirname(cur);
    if (parent === cur) return false;
    cur = parent;
  }
}

// ---------------------------------------------------------------- E2E root 検出

/** target 相対の正規化。'./e2e/' → 'e2e'。target の外を指す指定は拒否する */
function normalizeE2eRoot(value) {
  const v = String(value).replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, '').trim();
  if (!v) throw new UsageError('E2E ルートが空です');
  if (v.startsWith('/') || /^[A-Za-z]:/.test(v)) {
    throw new UsageError(`E2E ルートは target 相対で指定してください: ${value}`);
  }
  if (v.split('/').includes('..')) {
    throw new UsageError(`E2E ルートに '..' は使えません: ${value}`);
  }
  return v;
}

/** playwright.config.* を深さ制限付きで探索する(浅い順 → 名前順) */
function findPlaywrightConfigs(root, dir = root, depth = 0) {
  if (!existsSync(dir)) return [];
  const found = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  for (const entry of entries) {
    if (entry.isFile() && PW_CONFIG_RE.test(entry.name)) {
      found.push(relative(root, join(dir, entry.name)).split(sep).join('/'));
    }
  }
  if (depth < SCAN_MAX_DEPTH) {
    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.') && entry.name !== '.') continue;
      if (SCAN_SKIP_DIRS.has(entry.name)) continue;
      found.push(...findPlaywrightConfigs(root, join(dir, entry.name), depth + 1));
    }
  }
  return found.sort((a, b) => {
    const da = a.split('/').length, db = b.split('/').length;
    return da !== db ? da - db : a.localeCompare(b);
  });
}

/** 設定ファイルから testDir を読む。読めなければ null */
function parseTestDir(absPath) {
  let text;
  try {
    text = readFileSync(absPath, 'utf8');
  } catch {
    return null;
  }
  const m = text.match(/testDir\s*:\s*['"`]([^'"`\n]+)['"`]/);
  return m ? m[1] : null;
}

/**
 * E2E ルートを決める。
 * 優先順: --e2e-root > スタンプの記録 > 設定の testDir > 既存ディレクトリ > 既定
 * @returns {{root: string, how: string, detected: string|null, configs: string[]}}
 */
function resolveE2eRoot(target, flagRoot, stampRoot) {
  const configs = findPlaywrightConfigs(target);

  // 設定の testDir から検出する(浅い設定を優先)
  let detected = null;
  let detectedHow = null;
  for (const rel of configs) {
    const testDir = parseTestDir(join(target, rel));
    if (!testDir) continue;
    const abs = resolve(dirname(join(target, rel)), testDir);
    const relRoot = relative(target, abs).split(sep).join('/');
    if (!relRoot || relRoot.startsWith('..')) continue;
    detected = relRoot;
    detectedHow = `${rel} の testDir`;
    break;
  }

  // testDir が読めなかった場合は既存ディレクトリから推定する
  if (!detected) {
    const candidates = [];
    for (const rel of configs) {
      const base = dirname(rel) === '.' ? '' : `${dirname(rel)}/`;
      candidates.push(`${base}e2e`, `${base}tests/e2e`, `${base}playwright`);
    }
    candidates.push(E2E_ROOT_DEFAULT, 'e2e', 'playwright/e2e');
    for (const c of candidates) {
      if (existsSync(join(target, c))) {
        detected = c;
        detectedHow = `既存ディレクトリ ${c}`;
        break;
      }
    }
  }

  if (flagRoot) return { root: flagRoot, how: '--e2e-root の指定', detected, configs };
  if (stampRoot) return { root: stampRoot, how: `${STAMP_FILE} の記録`, detected, configs };
  if (detected) return { root: detected, how: detectedHow, detected, configs };
  return { root: E2E_ROOT_DEFAULT, how: '既定値(検出できず)', detected, configs };
}

/** payload のパスを、検出した E2E ルートに合わせて読み替える */
function mapDestRel(rel, e2eRoot) {
  const prefix = `${E2E_ROOT_DEFAULT}/`;
  if (e2eRoot !== E2E_ROOT_DEFAULT && rel.startsWith(prefix)) {
    return `${e2eRoot}/${rel.slice(prefix.length)}`;
  }
  return rel;
}

/** ファイル内容の E2E ルートを書き換える */
function transformContent(rel, buf, e2eRoot) {
  if (e2eRoot === E2E_ROOT_DEFAULT || !E2E_PATH_FILES.has(rel)) return buf;
  return Buffer.from(buf.toString('utf8').replaceAll(E2E_ROOT_DEFAULT, e2eRoot), 'utf8');
}

// ---------------------------------------------------------------- unified diff

function unifiedDiff(oldText, newText, oldLabel, newLabel, context = 3) {
  const a = oldText.split('\n');
  const b = newText.split('\n');
  // LCS テーブル(payload のファイルは小さいので O(n*m) で十分)
  const n = a.length, m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { ops.push([' ', a[i]]); i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) { ops.push(['-', a[i++]]); }
    else { ops.push(['+', b[j++]]); }
  }
  while (i < n) ops.push(['-', a[i++]]);
  while (j < m) ops.push(['+', b[j++]]);

  // 変更点の周囲 context 行だけを残す
  const keep = new Array(ops.length).fill(false);
  ops.forEach((op, idx) => {
    if (op[0] === ' ') return;
    for (let k = Math.max(0, idx - context); k <= Math.min(ops.length - 1, idx + context); k++) keep[k] = true;
  });

  const lines = [`--- ${oldLabel}`, `+++ ${newLabel}`];
  let printedGap = false;
  for (let idx = 0; idx < ops.length; idx++) {
    if (!keep[idx]) { if (!printedGap) { lines.push('@@'); printedGap = true; } continue; }
    printedGap = false;
    lines.push(ops[idx][0] + ops[idx][1]);
  }
  return lines.join('\n');
}

// ---------------------------------------------------------------- config.yaml merge

/** 先頭が空白でない(= トップレベル)かつコメントでない `key:` 行を探す */
function findTopLevelKey(lines, key) {
  const re = new RegExp(`^${key}:(\\s*)(.*)$`);
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(re);
    if (m) return { index: i, value: m[2].trim() };
  }
  return null;
}

function findMarkerRange(lines) {
  const start = lines.findIndex(l => l.trim() === MARKER_START);
  if (start === -1) return null;
  const end = lines.findIndex((l, i) => i > start && l.trim() === MARKER_END);
  if (end === -1) return null;
  return { start, end, indent: lines[start].match(/^\s*/)[0] };
}

/**
 * config.yaml を冪等にマージする。
 * @returns {{text: string|null, notes: string[], warnings: string[]}} text=null は変更なし
 */
function mergeConfig(original) {
  const notes = [];
  const warnings = [];

  if (original === null) {
    const text = [
      `schema: ${SCHEMA_NAME}`,
      '',
      MARKER_START,
      'context: |',
      ...CONTEXT_LINES.map(l => `  ${l}`),
      MARKER_END,
      '',
    ].join('\n');
    notes.push(`openspec/config.yaml を新規作成 (schema: ${SCHEMA_NAME} + context ブロック)`);
    return { text, notes, warnings };
  }

  let lines = original.split('\n');

  // --- schema: キー ---
  const schemaKey = findTopLevelKey(lines, 'schema');
  if (!schemaKey) {
    lines.unshift(`schema: ${SCHEMA_NAME}`);
    notes.push(`schema: ${SCHEMA_NAME} を追加`);
  } else if (schemaKey.value !== SCHEMA_NAME) {
    warnings.push(
      `openspec/config.yaml の schema が '${schemaKey.value}' です。` +
      `'${SCHEMA_NAME}' へは自動変更しません。E2E アーティファクトを使うには手動で変更してください。`
    );
  }

  // --- context マーカーブロック ---
  const marker = findMarkerRange(lines);
  if (marker) {
    const body = CONTEXT_LINES.map(l => `${marker.indent}${l}`);
    const current = lines.slice(marker.start + 1, marker.end);
    const inside = current.filter(l => l.trim() !== 'context: |');
    const hasContextKey = current.some(l => l.trim() === 'context: |');
    const desired = hasContextKey
      ? [`${marker.indent}context: |`, ...CONTEXT_LINES.map(l => `${marker.indent}  ${l}`)]
      : body;
    if (inside.join('\n') !== desired.filter(l => l.trim() !== 'context: |').join('\n')) {
      lines = [...lines.slice(0, marker.start + 1), ...desired, ...lines.slice(marker.end)];
      notes.push('openspec-e2e-kit マーカーブロックを更新');
    }
  } else {
    const contextKey = findTopLevelKey(lines, 'context');
    if (!contextKey) {
      while (lines.length && lines.at(-1).trim() === '') lines.pop();
      lines.push('', MARKER_START, 'context: |', ...CONTEXT_LINES.map(l => `  ${l}`), MARKER_END, '');
      notes.push('context ブロック(マーカー付き)を追加');
    } else if (contextKey.value === '|' || contextKey.value === '|-' || contextKey.value === '|+') {
      // 既存の literal block scalar の末尾に、同じインデントで追記する
      let end = contextKey.index + 1;
      let indent = null;
      while (end < lines.length) {
        const l = lines[end];
        if (l.trim() === '') { end++; continue; }
        const ind = l.match(/^\s*/)[0];
        if (ind.length === 0) break;
        indent ??= ind;
        end++;
      }
      while (end > contextKey.index + 1 && lines[end - 1].trim() === '') end--;
      indent ??= '  ';
      lines = [
        ...lines.slice(0, end),
        `${indent}${MARKER_START}`,
        ...CONTEXT_LINES.map(l => `${indent}${l}`),
        `${indent}${MARKER_END}`,
        ...lines.slice(end),
      ];
      notes.push('既存の context ブロック末尾へマーカー付きで追記');
    } else {
      warnings.push(
        'openspec/config.yaml に literal block ではない context: があるため自動追記しません。' +
        `以下2行を手動で context へ追加してください:\n    ${CONTEXT_LINES.join('\n    ')}`
      );
    }
  }

  const text = lines.join('\n');
  return { text: text === original ? null : text, notes, warnings };
}

// ---------------------------------------------------------------- main

async function confirm(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = (await rl.question(`${question} [y/N] `)).trim().toLowerCase();
    return answer === 'y' || answer === 'yes';
  } finally {
    rl.close();
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { console.log(USAGE); return 0; }

  const verb = opts.command === 'update' ? '更新' : '導入';
  const version = JSON.parse(readFileSync(join(HERE, 'package.json'), 'utf8')).version;

  console.log(`openspec-e2e-kit v${version} — ${verb}先: ${opts.target}${opts.dryRun ? ' (dry-run)' : ''}`);

  // 1. git リポジトリ確認
  if (!isInsideGitRepo(opts.target)) {
    console.log(`\n⚠ ${opts.target} は git リポジトリではありません。`);
    if (opts.dryRun) {
      console.log('  (dry-run のため確認をスキップします)');
    } else if (opts.force) {
      console.log('  --force が指定されているため続行します。');
    } else if (process.stdin.isTTY) {
      if (!await confirm(`  このまま${verb}しますか?`)) {
        console.log('中止しました。');
        return 0;
      }
    } else {
      console.error('  対話できない環境です。続行するには --force を指定してください。');
      return 1;
    }
  }

  // E2E ルートの決定
  const stampPath = join(opts.target, STAMP_FILE);
  let stampRoot = null;
  if (existsSync(stampPath)) {
    try {
      stampRoot = JSON.parse(readFileSync(stampPath, 'utf8')).e2eRoot ?? null;
      if (stampRoot) stampRoot = normalizeE2eRoot(stampRoot);
    } catch {
      stampRoot = null; // 壊れたスタンプは無視して検出に任せる
    }
  }
  const e2e = resolveE2eRoot(opts.target, opts.e2eRoot, stampRoot);
  const e2eRoot = e2e.root;

  console.log(`E2E ルート: ${e2eRoot}  (${e2e.how})`);
  if (e2e.configs.length > 1) {
    console.log(
      `  Playwright 設定が ${e2e.configs.length} 件見つかりました。最も浅いものを採用しています。\n` +
      `  採用: ${e2e.configs[0]}\n` +
      `  対象外: ${e2e.configs.slice(1).join(', ')}\n` +
      `  意図と違う場合は --e2e-root <path> で指定してください。`
    );
  }
  if (stampRoot && e2e.detected && e2e.detected !== stampRoot) {
    console.log(
      `  ⚠ 記録は '${stampRoot}' ですが、検出結果は '${e2e.detected}' です。` +
      `記録を優先しました。切り替えるには --e2e-root ${e2e.detected} を指定してください。`
    );
  }
  if (stampRoot && stampRoot !== e2eRoot) {
    console.log(
      `  ⚠ 前回は '${stampRoot}' に配置していました。'${stampRoot}' 配下の不要になった` +
      `ファイルは自動削除しません。手で確認してください。`
    );
  }

  const planned = [];   // dry-run 用の操作一覧
  const created = [];
  const overwritten = [];
  const skipped = [];   // 内容が異なるため skip したファイル
  const warnings = [];

  // 2. payload の再帰コピー
  for (const rel of walkFiles(PAYLOAD)) {
    const src = join(PAYLOAD, rel);
    const content = transformContent(rel, readFileSync(src), e2eRoot);
    let destRel = mapDestRel(rel, e2eRoot);

    if (rel === 'playwright.config.example.ts') {
      // 既存プロジェクトの設定は上書きしない。設定は**リポジトリ全体**を探索して
      // 判定する(ルートだけ見ていると frontend/playwright.config.ts のような
      // 構成で 2 つ目の設定を作ってしまう)。
      const rootConfig = join(opts.target, 'playwright.config.ts');
      const kitPlacedRoot = e2e.configs.length === 1
        && e2e.configs[0] === 'playwright.config.ts'
        && existsSync(rootConfig)
        && readFileSync(rootConfig).equals(content);
      if (e2e.configs.length === 0) {
        destRel = 'playwright.config.ts';
      } else if (kitPlacedRoot) {
        continue; // kit が設置したものなので何もしない(2 回目で .example が増えるのを防ぐ)
      } else {
        destRel = 'playwright.config.example.ts';
      }
    }

    const dest = join(opts.target, destRel);

    if (!existsSync(dest)) {
      planned.push(`create  ${destRel}`);
      created.push(destRel);
      if (!opts.dryRun) {
        mkdirSync(dirname(dest), { recursive: true });
        writeFileSync(dest, content);
        if (destRel.endsWith('.sh')) applyExecBit(src, dest);
      }
      continue;
    }

    const existing = readFileSync(dest);
    if (existing.equals(content)) continue; // 同一内容 → サイレント skip

    if (opts.force) {
      planned.push(`overwrite ${destRel}`);
      overwritten.push(destRel);
      if (!opts.dryRun) {
        writeFileSync(dest, content);
        if (destRel.endsWith('.sh')) applyExecBit(src, dest);
      }
    } else {
      planned.push(`skip(差分あり) ${destRel}`);
      skipped.push(destRel);
      console.log(`\n差分あり(上書きしません): ${destRel}`);
      console.log(unifiedDiff(existing.toString('utf8'), content.toString('utf8'), `target/${destRel}`, `payload/${rel}`));
    }
  }

  // 3. openspec/config.yaml のマージ
  const configPath = join(opts.target, 'openspec', 'config.yaml');
  const configBefore = existsSync(configPath) ? readFileSync(configPath, 'utf8') : null;
  const merged = mergeConfig(configBefore);
  warnings.push(...merged.warnings);
  if (merged.text !== null) {
    for (const n of merged.notes) planned.push(`config  ${n}`);
    if (!opts.dryRun) {
      mkdirSync(dirname(configPath), { recursive: true });
      writeFileSync(configPath, merged.text);
    }
  }

  // 4. インストールスタンプ
  planned.push(`stamp   ${STAMP_FILE} (version ${version}, e2eRoot ${e2eRoot})`);
  if (!opts.dryRun) {
    writeFileSync(
      stampPath,
      JSON.stringify({ version, installedAt: new Date().toISOString(), e2eRoot }, null, 2) + '\n',
    );
  }

  // 5. 結果表示
  if (opts.dryRun) {
    console.log('\n実行予定の操作(書き込みは行っていません):');
    if (planned.length === 0) console.log('  (なし)');
    for (const p of planned) console.log(`  ${p}`);
  } else {
    console.log('');
    console.log(`作成: ${created.length} 件 / 上書き: ${overwritten.length} 件 / 差分により skip: ${skipped.length} 件`);
    for (const n of merged.notes) console.log(`  config.yaml: ${n}`);
    if (created.length === 0 && overwritten.length === 0 && merged.notes.length === 0) {
      console.log('  変更はありません(既に最新です)。');
    }
  }

  if (skipped.length) {
    console.log('\n以下のファイルは対象側の内容が異なるため skip しました(上書きするには --force):');
    for (const f of skipped) console.log(`  - ${f}`);
  }
  for (const w of warnings) console.log(`\n⚠ ${w}`);

  console.log(opts.dryRun ? `\ndry-run 完了。書き込みは行っていません。` : `\n${verb}が完了しました。`);
  return 0;
}

function applyExecBit(src, dest) {
  try {
    const mode = statSync(src).mode;
    if (mode & 0o111) chmodSync(dest, mode & 0o777);
  } catch {
    /* 実行ビットの引き継ぎに失敗しても致命的ではない */
  }
}

try {
  process.exitCode = await main();
} catch (err) {
  if (err instanceof UsageError) {
    console.error(`エラー: ${err.message}\n\n${USAGE}`);
    process.exitCode = 2;
  } else {
    console.error(`エラー: ${err?.stack ?? err}`);
    process.exitCode = 1;
  }
}
