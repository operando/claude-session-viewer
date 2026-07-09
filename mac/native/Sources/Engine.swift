// server.js のデータロジックのSwift移植。
// ~/.claude/projects/ 配下のセッションJSONLを読み、Web UIと同じJSON形状を返す。
import Foundation

enum Engine {
    static let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    static let truncateLimit = 10000

    // MARK: - ユーティリティ

    static func parseLine(_ line: Substring) -> [String: Any]? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func truncate(_ s: String, _ n: Int = truncateLimit) -> String {
        guard s.count > n else { return s }
        return String(s.prefix(n)) + "\n… (\(s.count - n) 文字省略)"
    }

    // tool_result の content は string または [{type:"text",text}...]
    static func toolResultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        }
        return ""
    }

    static func mtimeMs(_ url: URL) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
    }

    static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    static func jsonlFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
    }

    // MARK: - 注入コンテンツ判定

    static let injectedTags = [
        "task-notification", "system-reminder", "bash-stdout", "bash-stderr", "bash-input",
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
    ]

    // 開始タグ+対応する閉じタグが揃っている場合のみ注入と判定
    static func injectedTag(_ content: String) -> String? {
        for tag in injectedTags {
            if content.hasPrefix("<\(tag)>") && content.contains("</\(tag)>") { return tag }
        }
        if content.hasPrefix("<hook-"),
           let end = content.dropFirst(1).firstIndex(of: ">") {
            let tag = String(content[content.index(content.startIndex, offsetBy: 1)..<end])
            if content.contains("</\(tag)>") { return tag }
        }
        return nil
    }

    // MARK: - プロジェクト一覧

    static func listProjects() -> [[String: Any]] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var result: [[String: Any]] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let files = jsonlFiles(in: dir)
            guard !files.isEmpty else { continue }
            let newest = files.max { mtimeMs($0) < mtimeMs($1) }!
            // 表示名用の実パスはディレクトリ名(ハイフン化で曖昧)ではなくJSONL内のcwdから取る
            let cwd = sessionMeta(newest).cwd
            result.append([
                "name": dir.lastPathComponent,
                "count": files.count,
                "lastModified": mtimeMs(newest),
                "cwd": cwd as Any,
            ])
        }
        return result.sorted { ($0["lastModified"] as! Double) > ($1["lastModified"] as! Double) }
    }

    // MARK: - セッション一覧

    // 先頭 256KB だけ読んでタイトルと最初のプロンプトを拾う
    static func sessionMeta(_ file: URL) -> (title: String?, firstPrompt: String?, firstTs: String?, cwd: String?) {
      autoreleasepool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil, nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        var title: String?
        var firstPrompt: String?
        var firstTs: String?
        var cwd: String?
        for line in text.split(separator: "\n") {
            guard let row = parseLine(line) else { continue }
            let type = row["type"] as? String
            if type == "ai-title", title == nil { title = row["aiTitle"] as? String }
            if type == "summary", title == nil { title = row["summary"] as? String }
            if firstTs == nil { firstTs = row["timestamp"] as? String }
            if cwd == nil { cwd = row["cwd"] as? String }
            if firstPrompt == nil, type == "user",
               let message = row["message"] as? [String: Any],
               let content = message["content"] as? String,
               !content.hasPrefix("<") {
                firstPrompt = String(content.prefix(120))
            }
            if title != nil && firstPrompt != nil && cwd != nil { break }
        }
        return (title, firstPrompt, firstTs, cwd)
      }
    }

    static func listSessions(project: String) -> [[String: Any]] {
        let dir = projectsDir.appendingPathComponent(project)
        var result: [[String: Any]] = []
        for file in jsonlFiles(in: dir) {
            let meta = sessionMeta(file)
            result.append([
                "id": file.deletingPathExtension().lastPathComponent,
                "size": fileSize(file),
                "mtime": mtimeMs(file),
                "title": meta.title as Any,
                "firstPrompt": meta.firstPrompt as Any,
                "firstTs": meta.firstTs as Any,
                "cwd": meta.cwd as Any,
            ])
        }
        return result.sorted { ($0["mtime"] as! Double) > ($1["mtime"] as! Double) }
    }

    // MARK: - 会話詳細

    // ツール呼び出しの1行サマリ
    static func toolInputSummary(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "path", "pattern", "url", "description", "prompt"] {
            if let v = input[key] as? String, !v.isEmpty {
                return String(v.split(separator: "\n", omittingEmptySubsequences: false)[0].prefix(100))
            }
        }
        return ""
    }

    static func parseSession(project: String, id: String, includeSidechain: Bool) -> Any {
        let file = projectsDir.appendingPathComponent(project).appendingPathComponent(id + ".jsonl")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return ["error": "not found"]
        }
        let messages = NSMutableArray()
        var toolUseIndex: [String: NSMutableDictionary] = [:]

        for line in text.split(separator: "\n") {
            guard let row = parseLine(line) else { continue }
            let sidechain = row["isSidechain"] as? Bool ?? false
            if sidechain && !includeSidechain { continue }
            let type = row["type"] as? String
            let ts = row["timestamp"] as? String
            let message = row["message"] as? [String: Any]

            if type == "summary", let summary = row["summary"] as? String {
                messages.add(["kind": "summary", "text": summary, "ts": ts as Any])
                continue
            }

            if type == "user" {
                if let content = message?["content"] as? String {
                    if content.hasPrefix("<command-name>"),
                       let range = content.range(of: "</command-name>") {
                        let cmd = String(content[content.index(content.startIndex, offsetBy: 14)..<range.lowerBound])
                        messages.add(["kind": "command", "text": cmd.trimmingCharacters(in: .whitespaces), "ts": ts as Any])
                    } else if let tag = injectedTag(content) {
                        messages.add(["kind": "system", "label": tag, "text": truncate(content, 4000), "ts": ts as Any])
                    } else if row["isMeta"] as? Bool == true || content.hasPrefix("[Request interrupted") {
                        messages.add(["kind": "system", "label": "meta", "text": truncate(content, 4000), "ts": ts as Any])
                    } else {
                        messages.add(["kind": "user", "text": content, "ts": ts as Any, "sidechain": sidechain])
                    }
                } else if let blocks = message?["content"] as? [[String: Any]] {
                    let hasImage = blocks.contains { $0["type"] as? String == "image" }
                    for block in blocks {
                        switch block["type"] as? String {
                        case "tool_result":
                            let resultText = truncate(toolResultText(block["content"]))
                            if let useId = block["tool_use_id"] as? String, let entry = toolUseIndex[useId] {
                                entry["result"] = resultText
                                entry["isError"] = block["is_error"] as? Bool ?? false
                            } else {
                                messages.add(["kind": "tool", "name": "(不明なツール)", "result": resultText, "ts": ts as Any])
                            }
                        case "text":
                            guard let t = block["text"] as? String,
                                  !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
                            if hasImage && row["isMeta"] as? Bool != true {
                                messages.add(["kind": "user", "text": t, "ts": ts as Any, "sidechain": sidechain])
                            } else {
                                messages.add(["kind": "system", "label": "injected", "text": truncate(t, 4000), "ts": ts as Any])
                            }
                        case "image":
                            messages.add(["kind": "user", "text": "(画像添付)", "ts": ts as Any])
                        default: break
                        }
                    }
                }
                continue
            }

            if type == "assistant", let blocks = message?["content"] as? [[String: Any]] {
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let t = block["text"] as? String,
                           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            messages.add([
                                "kind": "assistant", "text": t, "ts": ts as Any,
                                "model": message?["model"] as Any, "sidechain": sidechain,
                            ])
                        }
                    case "thinking":
                        if let t = block["thinking"] as? String,
                           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            messages.add(["kind": "thinking", "text": truncate(t, 3000), "ts": ts as Any])
                        }
                    case "tool_use":
                        let input = block["input"] as? [String: Any]
                        let inputJson = (input.flatMap {
                            try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys])
                        }).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        let entry = NSMutableDictionary(dictionary: [
                            "kind": "tool",
                            "name": block["name"] as? String ?? "?",
                            "input": truncate(inputJson),
                            "inputSummary": toolInputSummary(input),
                            "result": NSNull(),
                            "ts": ts as Any,
                            "sidechain": sidechain,
                        ])
                        if let blockId = block["id"] as? String { toolUseIndex[blockId] = entry }
                        messages.add(entry)
                    default: break
                    }
                }
            }
        }
        return messages
    }

    // MARK: - 全セッション検索

    struct SearchText {
        let kind: String
        let ts: String?
        let text: String
        let lower: String
    }

    // 長時間運用でメモリが際限なく増えないよう、合計サイズに上限を設けLRUで追い出す
    private struct CacheEntry {
        let mtime: Double
        let texts: [SearchText]
        let bytes: Int
        var used: Int
    }

    private static var searchCache: [String: CacheEntry] = [:]
    private static var cacheClock = 0
    private static let searchCacheMaxBytes = 200 * 1024 * 1024
    private static let cacheLock = NSLock()

    // 削除済みファイルのエントリと、上限超過分(LRU)を追い出す
    // seenPathsがnilのとき(走査が途中打ち切りのとき)は削除済み判定をスキップ
    private static func pruneSearchCache(seenPaths: Set<String>?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var total = 0
        for (path, entry) in searchCache {
            if let seen = seenPaths, !seen.contains(path) {
                searchCache.removeValue(forKey: path)
            } else {
                total += entry.bytes
            }
        }
        guard total > searchCacheMaxBytes else { return }
        for (path, entry) in searchCache.sorted(by: { $0.value.used < $1.value.used }) {
            searchCache.removeValue(forKey: path)
            total -= entry.bytes
            if total <= searchCacheMaxBytes { break }
        }
    }

    static func cacheStats() -> (entries: Int, bytes: Int) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return (searchCache.count, searchCache.values.reduce(0) { $0 + $1.bytes })
    }

    static func extractSearchTexts(_ file: URL) -> [SearchText] {
        let mtime = mtimeMs(file)
        cacheLock.lock()
        if var cached = searchCache[file.path], cached.mtime == mtime {
            cacheClock += 1
            cached.used = cacheClock
            searchCache[file.path] = cached
            cacheLock.unlock()
            return cached.texts
        }
        cacheLock.unlock()

        // autoreleasepoolで囲まないと、JSONSerializationが生成するautorelease
        // オブジェクトが全ファイル走査の間解放されず、RSSが数百MB膨らむ
        let texts: [SearchText] = autoreleasepool {
            var texts: [SearchText] = []
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { return texts }
            for line in content.split(separator: "\n") {
                // user/assistant行だけparseする(snapshot等の巨大行のparseを避ける)
                guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") else { continue }
                guard let row = parseLine(line) else { continue }
                if row["isSidechain"] as? Bool == true { continue }
                let type = row["type"] as? String
                let ts = row["timestamp"] as? String
                let message = row["message"] as? [String: Any]
                if type == "user", let c = message?["content"] as? String {
                    if injectedTag(c) == nil && !c.hasPrefix("[Request interrupted") && !c.hasPrefix("<command-name>")
                        && !c.hasPrefix("<local-command-") {
                        texts.append(SearchText(kind: "user", ts: ts, text: c, lower: c.lowercased()))
                    }
                } else if type == "assistant", let blocks = message?["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "text" {
                        if let t = block["text"] as? String {
                            texts.append(SearchText(kind: "assistant", ts: ts, text: t, lower: t.lowercased()))
                        }
                    }
                }
            }
            return texts
        }
        let bytes = texts.reduce(64) { $0 + ($1.text.utf16.count + $1.lower.utf16.count) * 2 + 48 }
        cacheLock.lock()
        cacheClock += 1
        searchCache[file.path] = CacheEntry(mtime: mtime, texts: texts, bytes: bytes, used: cacheClock)
        cacheLock.unlock()
        return texts
    }

    static func makeSnippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        let core = text[start..<end]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + core + (end < text.endIndex ? "…" : "")
    }

    static func search(query: String) -> [String: Any] {
        let t0 = Date()
        let needle = query.lowercased()
        var sessions: [[String: Any]] = []
        var seenPaths = Set<String>()

        let dirs = (try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        outer: for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            for file in jsonlFiles(in: dir) {
                seenPaths.insert(file.path)
                var matches: [[String: Any]] = []
                for t in extractSearchTexts(file) {
                    guard let lowerRange = t.lower.range(of: needle) else { continue }
                    // lower上のオフセットを元テキストのRangeに変換(通常のケースでは1:1対応)
                    let offset = t.lower.distance(from: t.lower.startIndex, to: lowerRange.lowerBound)
                    let start = t.text.index(t.text.startIndex, offsetBy: min(offset, t.text.count),
                                             limitedBy: t.text.endIndex) ?? t.text.startIndex
                    let end = t.text.index(start, offsetBy: needle.count, limitedBy: t.text.endIndex) ?? t.text.endIndex
                    matches.append([
                        "kind": t.kind, "ts": t.ts as Any,
                        "snippet": makeSnippet(t.text, around: start..<end),
                    ])
                    if matches.count >= 50 { break }
                }
                if !matches.isEmpty {
                    let meta = sessionMeta(file)
                    sessions.append([
                        "project": dir.lastPathComponent,
                        "id": file.deletingPathExtension().lastPathComponent,
                        "title": (meta.title ?? meta.firstPrompt) as Any,
                        "mtime": mtimeMs(file),
                        "cwd": meta.cwd as Any,
                        "count": matches.count,
                        "matches": Array(matches.prefix(3)),
                    ])
                }
                if sessions.count >= 200 { break outer }
            }
        }
        pruneSearchCache(seenPaths: sessions.count >= 200 ? nil : seenPaths)
        sessions.sort { ($0["mtime"] as! Double) > ($1["mtime"] as! Double) }
        return ["sessions": sessions, "tookMs": Int(Date().timeIntervalSince(t0) * 1000)]
    }

    // MARK: - お気に入り (Web版server.jsと同じファイルを共有)

    static let favoritesFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/claude-session-viewer/favorites.json")

    static func readFavorites() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: favoritesFile),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list
    }

    static func writeFavorites(_ list: [[String: Any]]) {
        try? FileManager.default.createDirectory(
            at: favoritesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? data.write(to: favoritesFile)
        }
    }

    static func enrichedFavorites() -> [[String: Any]] {
        readFavorites().map { fav in
            var f = fav
            guard let project = f["project"] as? String, let id = f["id"] as? String else { return f }
            let file = projectsDir.appendingPathComponent(project).appendingPathComponent(id + ".jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                f["missing"] = true
                return f
            }
            let meta = sessionMeta(file)
            f["title"] = (meta.title ?? meta.firstPrompt) as Any
            f["mtime"] = mtimeMs(file)
            f["cwd"] = meta.cwd as Any
            return f
        }
    }

    static func toggleFavorite(project: String, id: String, on: Bool) -> [[String: Any]] {
        var favs = readFavorites().filter {
            !($0["project"] as? String == project && $0["id"] as? String == id)
        }
        if on {
            favs.insert(["project": project, "id": id, "addedAt": Date().timeIntervalSince1970 * 1000], at: 0)
        }
        writeFavorites(favs)
        return favs
    }

    // MARK: - 統計

    static func rssMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : 0
    }

    // MARK: - APIディスパッチ (server.jsのルーティング相当)

    static func handle(path: String) -> Any {
        guard let components = URLComponents(string: path) else { return ["error": "bad path"] }
        let query = { (name: String) in components.queryItems?.first { $0.name == name }?.value ?? "" }
        let safeName = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")
        let isSafe = { (s: String) in
            safeName.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }

        switch components.path {
        case "/api/stats":
            let stats = cacheStats()
            return [
                "cacheEntries": stats.entries,
                "cacheMB": stats.bytes / 1_048_576,
                "cacheLimitMB": searchCacheMaxBytes / 1_048_576,
                "rssMB": rssMB(),
            ]
        case "/api/projects":
            return listProjects()
        case "/api/sessions":
            let project = query("project")
            guard isSafe(project) else { return ["error": "bad project"] }
            return listSessions(project: project)
        case "/api/session":
            let project = query("project"), id = query("id")
            guard isSafe(project), isSafe(id) else { return ["error": "bad params"] }
            return parseSession(project: project, id: id, includeSidechain: query("sidechain") == "1")
        case "/api/favorites":
            return enrichedFavorites()
        case "/api/favorite":
            let project = query("project"), id = query("id")
            guard isSafe(project), isSafe(id) else { return ["error": "bad params"] }
            return toggleFavorite(project: project, id: id, on: query("on") == "1")
        case "/api/search":
            let q = query("q").trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { return ["error": "検索語は2文字以上"] }
            return search(query: q)
        default:
            return ["error": "unknown endpoint"]
        }
    }
}
