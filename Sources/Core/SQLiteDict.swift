//
//  SQLiteDict.swift
//  RootWord · 词根单词
//
//  离线 SQLite 词典查询层（替代 ecdict_light.tsv 全量加载）
//
//  数据源：Dictionary.sqlite（46MB，随 .app bundle 内置，懒加载只读连接；源文件 BUKADictionary.sqlite 来自 FlashCardApp 逆向）
//    english_entries  : word PRIMARY KEY COLLATE NOCASE / translation / phonetic / priority
//    english_variants : variant → lemma（变体兜底，如 2-d → 2d）
//
//  核心思维转变：词典是「查询」，不是「加载」。
//  旧实现把 36MB tsv 全量解析为 77 万条 Swift 字典（内存峰值 150MB+，
//  正是此前 Jetsam OOM 的根源之一）；现在词典常驻磁盘，主键查询 O(log n)，
//  内存占用趋近于零，同时获得 tsv 没有的 phonetic（音标）数据。
//
//  线程安全：SQLite 连接用 NSLock 串行化；连接打开一次后复用。
//

import Foundation
import SQLite3

/// SQLITE_TRANSIENT：SQLite 在 bind 时复制字符串内容（而非引用调用方指针）。
/// C 头文件里是宏定义，Clang importer 不会导出，需手动构造。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteDict {

    struct Entry {
        let translation: String
        let phonetic: String
        let priority: Int

        /// 常用度：priority <= 80 视为常用（20=常规词，80=次常用，合计占 98%）
        var isCommon: Bool { priority <= 80 }
    }

    private static let lock = NSLock()
    private static var _db: OpaquePointer?

    /// 打开词典连接（懒加载，线程安全）。bundle 内找不到时返回 false。
    @discardableResult
    static func ensureOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _db != nil { return true }
        guard let url = Bundle.main.url(forResource: "Dictionary", withExtension: "sqlite") else {
            return false
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        _db = db
        return true
    }

    /// 是否已就绪（供 UI 预加载判断）
    static var isReady: Bool { _db != nil }

    /// 词条查询：word 精确命中（COLLATE NOCASE）；未命中时尝试变体映射后二次查询。
    static func lookup(_ word: String) -> Entry? {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, ensureOpen() else { return nil }
        if let e = rawLookup(key) { return e }
        if let lemma = variant(key), let e = rawLookup(lemma) { return e }
        return nil
    }

    /// english_entries 主键查询
    private static func rawLookup(_ word: String) -> Entry? {
        guard let db = _db else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT translation, phonetic, priority FROM english_entries WHERE word = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let translation = colText(stmt, 0)
        let phonetic = colText(stmt, 1)
        let priority = Int(sqlite3_column_int(stmt, 2))
        return Entry(translation: translation, phonetic: phonetic, priority: priority)
    }

    /// english_variants 变体映射（variant → lemma）
    private static func variant(_ word: String) -> String? {
        guard let db = _db else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT lemma FROM english_variants WHERE variant = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return colText(stmt, 0)
    }

    /// 前缀检索：供「大词库选词」浏览/搜索。
    /// 用主键范围扫描（word >= p AND word < p+\u{FFFF}）替代 LIKE，等价且走 B-tree。
    static func commonWords(prefix: String, limit: Int = 200) -> [(word: String, translation: String)] {
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty, ensureOpen(), let db = _db else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let upper = p + "\u{FFFF}"
        let sql = "SELECT word, translation FROM english_entries WHERE word >= ? AND word < ? ORDER BY word LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, p, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, upper, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((colText(stmt, 0), colText(stmt, 1)))
        }
        return out
    }

    /// 常用词候选池（priority <= 80，同首字母前缀）：供 OCR 纠错编辑距离候选使用。
    static func commonCandidates(prefix: Character, limit: Int = 2000) -> [String] {
        guard ensureOpen(), let db = _db else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let p = String(prefix)
        let sql = "SELECT word FROM english_entries WHERE word >= ? AND word < ? AND priority <= 80 ORDER BY word LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, p, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, p + "\u{FFFF}", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(colText(stmt, 0))
        }
        return out
    }

    private static func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }
}
