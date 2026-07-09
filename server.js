#!/usr/bin/env node
// Claude Code セッションビューア
// 使い方: node server.js  →  http://localhost:7444
// ~/.claude/projects/ 配下のセッションJSONLを読み取り専用で閲覧する。依存パッケージなし。

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { StringDecoder } = require('string_decoder');

const PORT = process.env.PORT || 7444;
const PROJECTS_DIR = path.join(os.homedir(), '.claude', 'projects');
const TRUNCATE = 10000; // ツール入出力の最大表示文字数

// ---------- JSONL パース ----------

// 1MBチャンクで読む行ジェネレータ。数十MBのファイルでも全文を
// メモリに載せないので、ヒープのピークが小さく済む
function* readLines(filePath) {
  const fd = fs.openSync(filePath, 'r');
  const buf = Buffer.alloc(1 << 20);
  const decoder = new StringDecoder('utf8');
  let rest = '';
  try {
    let n;
    while ((n = fs.readSync(fd, buf, 0, buf.length, null)) > 0) {
      const parts = (rest + decoder.write(buf.subarray(0, n))).split('\n');
      rest = parts.pop();
      yield* parts;
    }
    rest += decoder.end();
    if (rest) yield rest;
  } finally {
    fs.closeSync(fd);
  }
}

function* readJsonlLines(filePath) {
  for (const line of readLines(filePath)) {
    if (!line.trim()) continue;
    try {
      yield JSON.parse(line);
    } catch {
      /* 壊れた行はスキップ */
    }
  }
}

function truncate(s, n = TRUNCATE) {
  if (typeof s !== 'string') return s;
  return s.length > n ? s.slice(0, n) + `\n… (${s.length - n} 文字省略)` : s;
}

// tool_result の content は string または [{type:"text",text}...]
function toolResultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && b.type === 'text')
      .map((b) => b.text)
      .join('\n');
  }
  return '';
}

// セッション一覧用: 先頭 256KB だけ読んでタイトルと最初のプロンプトを拾う
function sessionMeta(filePath) {
  let title = null;
  let firstPrompt = null;
  let firstTs = null;
  let cwd = null;
  try {
    const fd = fs.openSync(filePath, 'r');
    const buf = Buffer.alloc(256 * 1024);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    const lines = buf.toString('utf8', 0, n).split('\n');
    for (const line of lines) {
      if (!line.trim()) continue;
      let row;
      try {
        row = JSON.parse(line);
      } catch {
        continue;
      }
      if (row.type === 'ai-title' && !title) title = row.aiTitle;
      if (row.type === 'summary' && !title) title = row.summary;
      if (!firstTs && row.timestamp) firstTs = row.timestamp;
      if (!cwd && row.cwd) cwd = row.cwd;
      if (
        !firstPrompt &&
        row.type === 'user' &&
        typeof row.message?.content === 'string' &&
        !row.message.content.startsWith('<') // コマンド実行ログ等は除外
      ) {
        firstPrompt = row.message.content.slice(0, 120);
      }
      if (title && firstPrompt && cwd) break;
    }
  } catch {
    /* 読めないファイルは無視 */
  }
  return { title, firstPrompt, firstTs, cwd };
}

// 会話詳細: JSONL全体をメッセージ列に変換
function parseSession(filePath, includeSidechain) {
  const messages = [];
  const toolUseIndex = new Map(); // tool_use id → messages内のツールエントリ

  for (const row of readJsonlLines(filePath)) {
    if (row.isSidechain && !includeSidechain) continue;

    if (row.type === 'summary' && row.summary) {
      messages.push({ kind: 'summary', text: row.summary, ts: row.timestamp });
      continue;
    }

    if (row.type === 'user') {
      const content = row.message?.content;
      const pushSystem = (label, text) =>
        messages.push({ kind: 'system', label, text: truncate(text, 4000), ts: row.timestamp });

      if (typeof content === 'string') {
        // /コマンド実行のシステム的な行を区別する
        const cmdMatch = content.match(/^<command-name>([^<]+)<\/command-name>/);
        // 注入タグは閉じタグまで揃って初めて注入と判定する
        // (ユーザーが「<task-notification>とか…」のようにタグ名を話題にしただけの入力を誤分類しないため)
        const tagMatch = content.match(
          /^<(task-notification|system-reminder|bash-stdout|bash-stderr|bash-input|local-command-stdout|local-command-stderr|local-command-caveat|hook-[a-z-]+)>/
        );
        const injected = tagMatch && content.includes(`</${tagMatch[1]}>`) ? tagMatch : null;
        if (cmdMatch) {
          messages.push({ kind: 'command', text: cmdMatch[1].trim(), ts: row.timestamp });
        } else if (injected || row.isMeta || content.startsWith('[Request interrupted')) {
          pushSystem(injected ? injected[1] : 'meta', content);
        } else {
          messages.push({
            kind: 'user',
            text: content,
            ts: row.timestamp,
            sidechain: !!row.isSidechain,
          });
        }
      } else if (Array.isArray(content)) {
        // arrayコンテンツのtextブロックは基本ハーネス注入(中断マーカー、スキル本文等)。
        // 画像添付付きプロンプトのtextだけは本物のユーザー入力として扱う。
        const hasImage = content.some((b) => b?.type === 'image');
        for (const block of content) {
          if (block.type === 'tool_result') {
            const entry = toolUseIndex.get(block.tool_use_id);
            const text = truncate(toolResultText(block.content));
            if (entry) {
              entry.result = text;
              entry.isError = !!block.is_error;
            } else {
              messages.push({ kind: 'tool', name: '(不明なツール)', result: text, ts: row.timestamp });
            }
          } else if (block.type === 'text' && block.text?.trim()) {
            if (hasImage && !row.isMeta) {
              messages.push({ kind: 'user', text: block.text, ts: row.timestamp, sidechain: !!row.isSidechain });
            } else {
              pushSystem('injected', block.text);
            }
          } else if (block.type === 'image') {
            messages.push({ kind: 'user', text: '(画像添付)', ts: row.timestamp });
          }
        }
      }
      continue;
    }

    if (row.type === 'assistant') {
      const content = row.message?.content;
      if (!Array.isArray(content)) continue;
      for (const block of content) {
        if (block.type === 'text' && block.text?.trim()) {
          messages.push({
            kind: 'assistant',
            text: block.text,
            ts: row.timestamp,
            model: row.message.model,
            sidechain: !!row.isSidechain,
          });
        } else if (block.type === 'thinking' && block.thinking?.trim()) {
          messages.push({ kind: 'thinking', text: truncate(block.thinking, 3000), ts: row.timestamp });
        } else if (block.type === 'tool_use') {
          const entry = {
            kind: 'tool',
            name: block.name,
            input: truncate(JSON.stringify(block.input, null, 2)),
            inputSummary: toolInputSummary(block.name, block.input),
            result: null,
            ts: row.timestamp,
            sidechain: !!row.isSidechain,
          };
          toolUseIndex.set(block.id, entry);
          messages.push(entry);
        }
      }
    }
  }
  return messages;
}

// ツール呼び出しの1行サマリ（一覧で見やすくする用）
function toolInputSummary(name, input) {
  if (!input || typeof input !== 'object') return '';
  const s =
    input.command ||
    input.file_path ||
    input.path ||
    input.pattern ||
    input.url ||
    input.description ||
    input.prompt ||
    '';
  return String(s).split('\n')[0].slice(0, 100);
}

// ---------- API ----------

function listProjects() {
  return fs
    .readdirSync(PROJECTS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => {
      const dir = path.join(PROJECTS_DIR, d.name);
      const sessions = fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl'));
      let last = 0;
      let newest = null;
      for (const f of sessions) {
        try {
          const m = fs.statSync(path.join(dir, f)).mtimeMs;
          if (m > last) {
            last = m;
            newest = f;
          }
        } catch {}
      }
      // 表示名用の実パスはディレクトリ名(ハイフン化で曖昧)ではなくJSONL内のcwdから取る
      const cwd = newest ? sessionMeta(path.join(dir, newest)).cwd : null;
      return { name: d.name, count: sessions.length, lastModified: last, cwd };
    })
    .filter((p) => p.count > 0)
    .sort((a, b) => b.lastModified - a.lastModified);
}

function listSessions(project) {
  const dir = path.join(PROJECTS_DIR, project);
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith('.jsonl'))
    .map((f) => {
      const full = path.join(dir, f);
      const st = fs.statSync(full);
      const meta = sessionMeta(full);
      return {
        id: f.replace(/\.jsonl$/, ''),
        size: st.size,
        mtime: st.mtimeMs,
        ...meta,
      };
    })
    .sort((a, b) => b.mtime - a.mtime);
}

// ---------- 全セッション検索 ----------

// file path → {mtime, texts, bytes, used} のキャッシュ(mtimeが変わったら再抽出)
// 長時間運用でメモリが際限なく増えないよう、合計サイズに上限を設けLRUで追い出す
const searchCache = new Map();
let cacheClock = 0;
const SEARCH_CACHE_MAX_BYTES = (parseInt(process.env.SEARCH_CACHE_MB, 10) || 200) * 1024 * 1024;

// 削除済みファイルのエントリと、上限超過分(LRU)を追い出す
// seenPathsがnullのとき(走査が途中打ち切りのとき)は削除済み判定をスキップ
function pruneSearchCache(seenPaths) {
  let total = 0;
  for (const [p, e] of searchCache) {
    if (seenPaths && !seenPaths.has(p)) searchCache.delete(p);
    else total += e.bytes;
  }
  if (total <= SEARCH_CACHE_MAX_BYTES) return;
  for (const [p, e] of [...searchCache.entries()].sort((a, b) => a[1].used - b[1].used)) {
    searchCache.delete(p);
    total -= e.bytes;
    if (total <= SEARCH_CACHE_MAX_BYTES) break;
  }
}

const INJECTED_PREFIX = /^<(task-notification|system-reminder|bash-|local-command-|command-name|hook-)/;

// 検索対象のテキスト(ユーザー入力とClaudeの応答)を1ファイルから抽出
function extractSearchTexts(filePath) {
  const st = fs.statSync(filePath);
  const cached = searchCache.get(filePath);
  if (cached && cached.mtime === st.mtimeMs) {
    cached.used = ++cacheClock;
    return cached.texts;
  }
  const texts = [];
  // user/assistant行だけJSON.parseする(snapshot等の巨大行のparseを避けてGC圧を下げる)
  for (const line of readLines(filePath)) {
    if (!line.includes('"type":"user"') && !line.includes('"type":"assistant"')) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (row.isSidechain) continue;
    const c = row.message?.content;
    if (row.type === 'user') {
      if (typeof c === 'string' && !INJECTED_PREFIX.test(c) && !c.startsWith('[Request interrupted')) {
        texts.push({ kind: 'user', ts: row.timestamp, text: c });
      }
    } else if (row.type === 'assistant' && Array.isArray(c)) {
      for (const b of c) {
        if (b.type === 'text' && b.text) texts.push({ kind: 'assistant', ts: row.timestamp, text: b.text });
      }
    }
  }
  const bytes = texts.reduce((a, t) => a + t.text.length * 2 + 48, 64);
  searchCache.set(filePath, { mtime: st.mtimeMs, texts, bytes, used: ++cacheClock });
  return texts;
}

function makeSnippet(text, idx, qlen) {
  const start = Math.max(0, idx - 50);
  const end = Math.min(text.length, idx + qlen + 100);
  return (
    (start > 0 ? '…' : '') +
    text.slice(start, end).replace(/\s+/g, ' ').trim() +
    (end < text.length ? '…' : '')
  );
}

function searchAll(q) {
  const needle = q.toLowerCase();
  const sessions = [];
  const seenPaths = new Set();
  for (const dirent of fs.readdirSync(PROJECTS_DIR, { withFileTypes: true })) {
    if (!dirent.isDirectory()) continue;
    const dir = path.join(PROJECTS_DIR, dirent.name);
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith('.jsonl')) continue;
      const full = path.join(dir, f);
      seenPaths.add(full);
      let texts;
      try {
        texts = extractSearchTexts(full);
      } catch {
        continue;
      }
      const matches = [];
      for (const t of texts) {
        const idx = t.text.toLowerCase().indexOf(needle);
        if (idx < 0) continue;
        matches.push({ kind: t.kind, ts: t.ts, snippet: makeSnippet(t.text, idx, q.length) });
        if (matches.length >= 50) break;
      }
      if (matches.length) {
        const meta = sessionMeta(full);
        sessions.push({
          project: dirent.name,
          id: f.replace(/\.jsonl$/, ''),
          title: meta.title || meta.firstPrompt,
          mtime: fs.statSync(full).mtimeMs,
          cwd: meta.cwd,
          count: matches.length,
          matches: matches.slice(0, 3),
        });
      }
      if (sessions.length >= 200) break;
    }
  }
  pruneSearchCache(sessions.length >= 200 ? null : seenPaths);
  sessions.sort((a, b) => b.mtime - a.mtime);
  return sessions;
}

// ---------- お気に入り ----------
// Macアプリ版(Engine.swift)と同じファイルを読み書きして共有する

const FAV_PATH = path.join(
  os.homedir(), 'Library', 'Application Support', 'claude-session-viewer', 'favorites.json'
);

function readFavorites() {
  try {
    return JSON.parse(fs.readFileSync(FAV_PATH, 'utf8'));
  } catch {
    return [];
  }
}

function writeFavorites(list) {
  fs.mkdirSync(path.dirname(FAV_PATH), { recursive: true });
  fs.writeFileSync(FAV_PATH, JSON.stringify(list, null, 2));
}

// パラメータ検証（パストラバーサル防止）
const SAFE_NAME = /^[A-Za-z0-9._-]+$/;

function handleApi(url, res) {
  const send = (obj, code = 200) => {
    res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(obj));
  };
  try {
    if (url.pathname === '/api/projects') {
      return send(listProjects());
    }
    if (url.pathname === '/api/sessions') {
      const project = url.searchParams.get('project') || '';
      if (!SAFE_NAME.test(project)) return send({ error: 'bad project' }, 400);
      return send(listSessions(project));
    }
    if (url.pathname === '/api/stats') {
      let bytes = 0;
      for (const e of searchCache.values()) bytes += e.bytes;
      return send({
        cacheEntries: searchCache.size,
        cacheMB: Math.round(bytes / 1048576),
        cacheLimitMB: Math.round(SEARCH_CACHE_MAX_BYTES / 1048576),
        rssMB: Math.round(process.memoryUsage().rss / 1048576),
      });
    }
    if (url.pathname === '/api/favorites') {
      // タイトル等を付与して返す(元セッションが削除済みならmissing)
      const enriched = readFavorites().map((f) => {
        const file = path.join(PROJECTS_DIR, f.project, f.id + '.jsonl');
        if (!fs.existsSync(file)) return { ...f, missing: true };
        const meta = sessionMeta(file);
        return {
          ...f,
          title: meta.title || meta.firstPrompt,
          mtime: fs.statSync(file).mtimeMs,
          cwd: meta.cwd,
        };
      });
      return send(enriched);
    }
    if (url.pathname === '/api/favorite') {
      const project = url.searchParams.get('project') || '';
      const id = url.searchParams.get('id') || '';
      if (!SAFE_NAME.test(project) || !SAFE_NAME.test(id)) return send({ error: 'bad params' }, 400);
      let favs = readFavorites().filter((f) => !(f.project === project && f.id === id));
      if (url.searchParams.get('on') === '1') favs.unshift({ project, id, addedAt: Date.now() });
      writeFavorites(favs);
      return send(favs);
    }
    if (url.pathname === '/api/search') {
      const q = (url.searchParams.get('q') || '').trim();
      if (q.length < 2) return send({ error: '検索語は2文字以上' }, 400);
      const t0 = Date.now();
      const sessions = searchAll(q);
      return send({ sessions, tookMs: Date.now() - t0 });
    }
    if (url.pathname === '/api/session') {
      const project = url.searchParams.get('project') || '';
      const id = url.searchParams.get('id') || '';
      if (!SAFE_NAME.test(project) || !SAFE_NAME.test(id)) return send({ error: 'bad params' }, 400);
      const file = path.join(PROJECTS_DIR, project, id + '.jsonl');
      if (!fs.existsSync(file)) return send({ error: 'not found' }, 404);
      const includeSidechain = url.searchParams.get('sidechain') === '1';
      return send(parseSession(file, includeSidechain));
    }
    send({ error: 'unknown endpoint' }, 404);
  } catch (e) {
    send({ error: String(e.message || e) }, 500);
  }
}

// ---------- サーバー ----------

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname.startsWith('/api/')) return handleApi(url, res);
  if (url.pathname === '/' || url.pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(__dirname, 'index.html')));
  }
  if (url.pathname === '/marked.min.js') {
    res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
    return res.end(fs.readFileSync(path.join(__dirname, 'marked.min.js')));
  }
  res.writeHead(404);
  res.end('not found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Claude Session Viewer: http://localhost:${PORT}`);
  console.log(`読み取り対象: ${PROJECTS_DIR}`);
});
