# Claude Session Viewer

`~/.claude/projects/` のClaude CodeセッションJSONLを閲覧するローカルビューア。読み取り専用（お気に入りファイル以外、ユーザーデータには一切書き込まない）。

## アーキテクチャ

2形態が **同一の `index.html` + `marked.min.js`** を共有する:

| 形態 | データ層 | 通信 |
|---|---|---|
| Web版(動作確認用) | `server.js` (Node, 依存なし, port 7444) | fetch |
| mac/native/ (プロダクト) | `Engine.swift` (server.jsのSwift移植) | WKScriptMessageHandler JSブリッジ |

かつてserver.jsをnode子プロセスで動かすMacアプリ(mac/wrapper-node)もあったが、ネイティブ版完成後に削除した。ネイティブ版だけ挙動がおかしいときは、Web版をブラウザで開けばEngine.swiftの移植バグかどうか切り分けられる。

`index.html` の `api(path)` が唯一の通信窓口で、`webkit.messageHandlers.api` があればブリッジ、なければfetchに分岐する。

**重要: `server.js` と `mac/native/Sources/Engine.swift` は同じAPI・同じJSON形状を二重実装している。片方にAPIやフィールドを追加したら必ずもう片方にも同じ変更を入れること。**

## ビルド・起動・反映

プロダクトは**Macアプリ**（README参照）。Web版は開発時の動作確認用という位置づけ。

```sh
node server.js                 # Web版(動作確認用)起動 → http://localhost:7444
mac/native/build.sh            # Macアプリのビルド(Engine.swiftのコンパイル+index.html等をバンドルにコピー)
```

- 変更の検証はまずWeb版で行うのが速い: index.htmlの変更はブラウザリロードだけで反映される（server.jsの変更はサーバー再起動）
- 検証が済んだら**build.shの再実行+アプリ再起動でMacアプリに反映**（HTMLがバンドルにコピーされるため。これを忘れるとアプリだけ古いままになる）
- 環境変数(server.jsのみ): `PORT`(デフォルト7444)、`SEARCH_CACHE_MB`(検索キャッシュ上限、デフォルト200)

## API (server.jsとEngine.swiftが同一形状で実装)

- `GET /api/projects` — プロジェクト一覧
- `GET /api/sessions?project=<dir名>` — セッション一覧（先頭256KBだけ読む軽量スキャン）
- `GET /api/session?project=<dir名>&id=<uuid>[&sidechain=1]` — 会話の全メッセージ
- `GET /api/search?q=<語>` — 全セッション横断検索
- `GET /api/favorites` — お気に入り一覧 / `GET /api/favorite?project=&id=&on=1|0` — 登録/解除
- `GET /api/stats` — 検索キャッシュ量とRSS

## データ仕様の要点（JSONLパース）

- 1行1JSON。`type: "user" | "assistant" | "summary" | "ai-title" | ...`。フォーマットはClaude Code内部仕様で非公式
- **`type:"user"` にはユーザー以外のコンテンツが混ざる**。`<task-notification>` 等のハーネス注入は「開始タグ+対応する閉じタグが揃っている場合のみ」注入と判定する（ユーザーがタグ名を話題にしただけの入力を誤分類しないため）。`isMeta:true` と `[Request interrupted` もシステム扱い
- arrayコンテンツのtextブロックは基本ハーネス注入（スキル本文等）。ただし画像添付付きは本物のユーザー入力
- tool_use(assistant)とtool_result(user)は `tool_use_id` で突き合わせて1エントリに統合
- セッション一覧は各ファイルの先頭256KBだけ読む軽量スキャン（`sessionMeta`）。タイトルは `ai-title` 行から
- 検索はファイルごとに抽出テキストをmtimeキーでメモリキャッシュ（対象は user/assistant のテキストのみ）
- 表示の切り詰め: ツール入出力10000字、システム注入4000字、thinking3000字

## メモリの約束事（長時間運用対策。剥がすとRSSが数百MB膨らむ）

- **server.js: ファイルは必ず `readLines()`（1MBチャンクのストリーミング読み）経由で読む。** `readFileSync`で全文読み+splitすると、V8がピーク時のヒープをOSに返さずRSSが常駐で600MB超になる（ストリーミング化で90MB）
- **Engine.swift: ループ内でJSONSerializationを使う処理は`autoreleasepool`で囲む**（extractSearchTexts/sessionMeta）。囲まないとautoreleaseオブジェクトが走査完了まで解放されず800MB超になる（囲んで280MB程度）
- 検索キャッシュは合計サイズ上限付きLRU（デフォルト200MB）。削除済みファイルのエントリは全走査完了時に追い出す（200件打ち切り時はスキップ＝seenPaths不完全のため）。現在量は `GET /api/stats` で確認

## その他の約束事

- お気に入りの保存先は `~/Library/Application Support/claude-session-viewer/favorites.json`（3形態で共有）
- 再開コマンドのcwdはプロジェクトのディレクトリ名から復元せず、JSONL内の `cwd` フィールドを使う（ハイフン曖昧性のため）
- 依存パッケージを増やさない。ライブラリが必要ならmarked.jsのようにファイル同梱する
- UI変更の動作確認はブラウザ(http://localhost:7444)で行い、Engine.swiftの変更はscratchpadにCLIテストハーネス（`Engine.handle(path:)` を呼ぶだけの@main）を作って検証すると楽
