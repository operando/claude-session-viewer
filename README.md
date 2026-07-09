# Claude Session Viewer

`~/.claude/projects/` 配下に自動保存されているClaude Codeの全セッション履歴（JSONL）を閲覧するMacアプリ。読み取り専用で、Claude Code側の設定変更は不要。

## ビルドと起動

Xcodeプロジェクト不要。build.shがswiftcで直接.appバンドルを生成する。依存なし（Nodeも不要）。

```sh
mac/native/build.sh
open mac/native/ClaudeSessionViewer.app
```

UI(index.html)やロジックを変更したら、build.shを再実行してアプリを起動し直せば反映される。

## 使い方

3ペイン構成: **プロジェクト**（作業ディレクトリ単位）→ **セッション** → **会話**。

- **会話表示** — チャット風（ユーザー入力は右寄せ、Claudeの応答は左寄せでMarkdown整形）。右下の↓ボタンで最下部へ即ジャンプ
- **全セッション検索** — ⌘Fで検索ボックスにフォーカス、Enterで実行。結果はプロジェクト欄に「🔍 <検索語>」として積まれ、セッション欄に一覧表示。開いた会話ではヒット箇所がハイライトされ、🔍行クリックでいつでも結果に戻れる。不要になったら行の×で削除
- **お気に入り** — セッション項目の☆で登録/解除。プロジェクト欄最上部の「★ お気に入り」からプロジェクト横断でアクセス
- **再開コマンドコピー** — セッション項目の⧉で `cd '<cwd>' && claude --resume <セッションID>` をコピー。ターミナルに貼ればそのセッションの続きからClaude Codeを再開できる

ヘッダーのチェックボックス（すべてデフォルトOFF）:

- **途中の応答を表示** — 途中経過のClaude応答とthinking。OFFなら各入力に対する最終応答のみ
- **システム注入を表示** — `<task-notification>`等、ハーネスが注入するシステムコンテンツ
- **ツール操作を表示** — Bash/Write等のツール呼び出しログ（クリックで入力と結果を展開）
- **サブエージェントも表示** — sidechainのやりとり

## データについて

- 参照するのは `~/.claude/projects/` のみ（読み取り専用）。お気に入りだけ `~/Library/Application Support/claude-session-viewer/favorites.json` に保存
- 元ファイルはClaude Codeの `cleanupPeriodDays`（デフォルト30日）で削除される。恒久保存したい場合は別途アーカイブが必要
- JSONLフォーマットはClaude Codeの内部仕様のため、バージョンアップで表示が崩れる可能性あり

## 開発

Web版（`node server.js` → http://localhost:7444）は開発時の動作確認用。アーキテクチャやAPI、開発の約束事は [CLAUDE.md](CLAUDE.md) を参照。

## ライセンス

MIT ([LICENSE](LICENSE))。Markdown表示に [marked](https://github.com/markedjs/marked) (MIT) を同梱している。
