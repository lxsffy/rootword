//
//  SQLiteRootIndex.swift
//  RootWord · 词根单词
//
//  预计算词根索引的只读查询层
//
//  替代 RootParser 原先「把 precomputed_roots.tsv 全量解析成 15.6 万条 Swift 字典」的做法：
//  roots.sqlite 随 bundle 发布，首次使用时以只读方式打开并预编译语句，之后按需主键查询。
//
//  表结构（由 tools/convert_roots_tsv_to_sqlite.py 生成）：
//    CREATE TABLE precomputed_roots(
//        word TEXT PRIMARY KEY COLLATE NOCASE,
//        spec TEXT NOT NULL
//    ) WITHOUT ROWID;
//
//  线程安全与 SQLiteDict 保持一致：NSLock 串行化，连接与语句在进程内复用（不主动关闭）。
//  bundle 内缺少资源或表结构不符时所有查询返回 nil，调用方回退到 RootParser 在线解析。
//
//  完整性保护（代码审查建议）：
//    · 检查 sqlite3_bind_text / sqlite3_step 返回值，异常时明确记录日志；
//    · 打开数据库时用 PRAGMA table_info 验证目标表和 word / spec 字段存在；
//    · DEBUG 下记录命中 / 未命中 / 在线解析 / 打开失败 / 查询错误次数；
//    · 提供 configure(path:) 供独立回归脚本注入测试数据库，产品行为不受影响。
//

import Foundation
import SQLite3

/// SQLITE_TRANSIENT：SQLite 在 bind 时复制字符串内容（而非引用调用方指针）。
private let SQLITE_TRANSIENT_ROOTS = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteRootIndex {

    // MARK: - 诊断计数

    struct Stats {
        var hits = 0
        var misses = 0
        var onlineFallbacks = 0
        var openFailures = 0
        var queryErrors = 0
    }

    private static let lock = NSLock()
    private static var _db: OpaquePointer?
    private static var _stmt: OpaquePointer?
    private static var _openAttempted = false
    private static var _overridePath: String?
    private static var _stats = Stats()

    /// DEBUG 自检 / 回归脚本读取当前统计。
    static func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    static func resetStats() {
        lock.lock(); defer { lock.unlock() }
        _stats = Stats()
    }

    /// RootParser 走在线解析时调用，用于评估预计算索引对实际学习词汇的覆盖率。
    static func noteOnlineFallback() {
        lock.lock(); defer { lock.unlock() }
        _stats.onlineFallbacks += 1
    }

    /// 注入数据库路径（主要供独立 swiftc 回归脚本使用）；会关闭已有连接并重置打开状态。
    static func configure(path: String) {
        lock.lock(); defer { lock.unlock() }
        if let stmt = _stmt { sqlite3_finalize(stmt) }
        if let db = _db { sqlite3_close(db) }
        _stmt = nil
        _db = nil
        _openAttempted = false
        _overridePath = path
    }

    // MARK: - 打开与结构校验

    /// 懒加载只读连接 + 预编译语句。失败后不再重复尝试，避免每次解析都付出打开开销。
    @discardableResult
    static func ensureOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if _db != nil { return true }
        if _openAttempted { return false }
        _openAttempted = true

        let url: URL?
        if let override = _overridePath {
            url = URL(fileURLWithPath: override)
        } else {
            url = Bundle.main.url(forResource: "roots", withExtension: "sqlite")
        }
        guard let path = url?.path else {
            recordOpenFailure("bundle 内缺少 roots.sqlite")
            return false
        }

        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openRC == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let db = db { sqlite3_close(db) }
            recordOpenFailure("只读打开失败 rc=\(openRC): \(message)")
            return false
        }

        guard validateSchema(opened) else {
            sqlite3_close(opened)
            return false
        }

        let sql = "SELECT spec FROM precomputed_roots WHERE word = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK,
              let prepared = stmt else {
            recordOpenFailure("预编译 SELECT 失败: \(String(cString: sqlite3_errmsg(opened)))")
            if let stmt = stmt { sqlite3_finalize(stmt) }
            sqlite3_close(opened)
            return false
        }

        _db = opened
        _stmt = prepared
        return true
    }

    /// 打开后确认目标表和 word / spec 字段存在，避免数据库损坏或版本不匹配时静默返回 nil。
    private static func validateSchema(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(precomputed_roots)", -1, &stmt, nil) == SQLITE_OK,
              let tableInfo = stmt else {
            recordOpenFailure("无法读取 precomputed_roots 表结构: \(String(cString: sqlite3_errmsg(db)))")
            if let stmt = stmt { sqlite3_finalize(stmt) }
            return false
        }
        defer { sqlite3_finalize(tableInfo) }

        var columns = Set<String>()
        while sqlite3_step(tableInfo) == SQLITE_ROW {
            if let c = sqlite3_column_text(tableInfo, 1) {
                columns.insert(String(cString: c))
            }
        }
        guard columns.contains("word"), columns.contains("spec") else {
            recordOpenFailure("precomputed_roots 缺少 word / spec 字段（实际：\(columns.sorted().joined(separator: ", "))）")
            return false
        }
        return true
    }

    // MARK: - 查询

    /// 查询单词对应的拆解 spec（`un-|happy` 形式）；未命中或资源不可用返回 nil。
    static func spec(for word: String) -> String? {
        guard !word.isEmpty, ensureOpen() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let stmt = _stmt, let db = _db else { return nil }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        guard sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT_ROOTS) == SQLITE_OK else {
            recordQueryError("bind_text 失败: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            _stats.hits += 1
            return String(cString: c)
        }
        if rc != SQLITE_DONE {
            recordQueryError("step 返回 rc=\(rc): \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        _stats.misses += 1
        return nil
    }

    // MARK: - 内部错误记录（调用方已持有 lock）

    private static func recordOpenFailure(_ message: String) {
        _stats.openFailures += 1
        NSLog("SQLiteRootIndex 打开失败：%@", message)
    }

    private static func recordQueryError(_ message: String) {
        _stats.queryErrors += 1
        _stats.misses += 1
        NSLog("SQLiteRootIndex 查询错误：%@", message)
    }
}
