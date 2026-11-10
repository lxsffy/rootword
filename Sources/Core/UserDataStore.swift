//
//  UserDataStore.swift
//  RootWord · 用户数据 SQLite 迁移层（1.5.0 预置，默认不启用）
//
//  设计原则（对应审查建议）：
//    · 两个静态数据库（Dictionary.sqlite / roots.sqlite）继续放 Bundle，只读；
//    · UserData.sqlite 放 Application Support，只写用户数据；
//    · JSON 保留为主数据源以及备份 / 导入 / 导出格式 —— 迁移不会删除或改写任何 JSON；
//    · 迁移有 schema 版本号、单事务、迁移前 JSON 备份、迁移后逐表校验、失败自动回退；
//    · 默认关闭（UserDefaults.rootword.useSQLiteUserData），开启后才生成副本。
//      数据读写切换到 SQLite 属于 1.5.0 的独立发布，不与 UI 改动捆绑。
//
//  表结构：words / decks / srs_states / review_logs / word_roots /
//          study_sessions / settings / meta。
//  每条记录保留完整 JSON payload，同时把高频查询字段提成列，便于后续按词根、
//  按到期时间、按词单做索引查询，而不必先做一次全量反序列化。
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_USERDATA = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum UserDataMigrationError: LocalizedError {
    case backupFailed(String)
    case openFailed(String)
    case schemaFailed(String)
    case insertFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .backupFailed(let m): return "迁移前备份失败：\(m)"
        case .openFailed(let m): return "打开 UserData.sqlite 失败：\(m)"
        case .schemaFailed(let m): return "建表失败：\(m)"
        case .insertFailed(let m): return "写入数据失败：\(m)"
        case .validationFailed(let m): return "迁移后校验失败：\(m)"
        }
    }
}

enum UserDataMigration {

    static let schemaVersion = 1
    private static let enabledKey = "rootword.useSQLiteUserData"

    /// 总开关。默认 false：JSON 仍是唯一数据源，本层不产生任何副作用。
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    /// 显式回退：关闭开关并移除已生成的 SQLite 副本。JSON 从未被改动，数据不会丢。
    static func rollback() {
        setEnabled(false)
        guard let url = databaseURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    struct Snapshot {
        var words: [Word]
        var decks: [Deck]
        var logs: [ReviewLog]
        var settings: AppSettings
        var sessions: [StudySession]
    }

    struct Report {
        var databasePath: String
        var backupPath: String
        var words: Int
        var decks: Int
        var logs: Int
        var rootLinks: Int
        var schemaVersion: Int
    }

    static var databaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RootWord/UserData.sqlite", isDirectory: false)
    }

    /// App 启动时调用。默认不启用；启用且副本已存在时直接跳过，避免重复迁移。
    @discardableResult
    static func migrateIfEnabled(snapshot: Snapshot) -> Result<Report?, Error> {
        guard isEnabled else { return .success(nil) }
        if let url = databaseURL, FileManager.default.fileExists(atPath: url.path) {
            return .success(nil)
        }
        switch migrate(snapshot: snapshot) {
        case .success(let report): return .success(report)
        case .failure(let error): return .failure(error)
        }
    }

    /// 生成一份完整校验过的 UserData.sqlite 副本。任何失败都会清理临时文件并关闭开关。
    static func migrate(snapshot: Snapshot) -> Result<Report, Error> {
        do {
            guard let dbURL = databaseURL else {
                throw UserDataMigrationError.openFailed("找不到 Application Support 目录")
            }
            let fm = FileManager.default
            try fm.createDirectory(at: dbURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            // 1. 迁移前备份：把当前 JSON 全量快照写到 Documents，绝不覆盖同名文件
            let backup = try backupJSON(snapshot: snapshot)

            // 2. 始终在 .tmp 上操作，成功后才原子替换，失败不影响现有数据
            let tmpURL = dbURL.appendingPathExtension("tmp")
            try? fm.removeItem(at: tmpURL)
            defer { try? fm.removeItem(at: tmpURL) }

            var db: OpaquePointer?
            let rc = sqlite3_open_v2(tmpURL.path, &db,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
            guard rc == SQLITE_OK, let opened = db else {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
                if let db = db { sqlite3_close(db) }
                throw UserDataMigrationError.openFailed("rc=\(rc) \(message)")
            }
            defer { sqlite3_close(opened) }

            // 3. 单事务：BEGIN → DDL → 写入 → 校验 → COMMIT
            try exec(opened, "BEGIN IMMEDIATE TRANSACTION")
            try createSchema(opened)
            let links = try insertAll(opened, snapshot: snapshot)
            try validate(opened, snapshot: snapshot, links: links)
            try exec(opened, "COMMIT")

            // 4. 校验通过才替换正式文件；旧的副本留一份 .bak 便于人工比对
            if fm.fileExists(atPath: dbURL.path) {
                let bak = dbURL.appendingPathExtension("bak")
                try? fm.removeItem(at: bak)
                try? fm.moveItem(at: dbURL, to: bak)
            }
            try fm.moveItem(at: tmpURL, to: dbURL)

            return .success(Report(databasePath: dbURL.path,
                                   backupPath: backup.path,
                                   words: snapshot.words.count,
                                   decks: snapshot.decks.count,
                                   logs: snapshot.logs.count,
                                   rootLinks: links,
                                   schemaVersion: schemaVersion))
        } catch {
            // 失败回退：JSON 一直是主数据源，只需关掉开关，下一次启动仍走原路径
            setEnabled(false)
            return .failure(error)
        }
    }

    // MARK: - Schema

    private static let ddl = """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE words(
            id TEXT PRIMARY KEY, deck_id TEXT NOT NULL, text TEXT NOT NULL COLLATE NOCASE,
            phase TEXT NOT NULL, due_at REAL NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE decks(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, is_current INTEGER NOT NULL,
            payload TEXT NOT NULL);
        CREATE TABLE srs_states(
            word_id TEXT PRIMARY KEY, phase TEXT NOT NULL, due_at REAL NOT NULL,
            reps INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE review_logs(
            id TEXT PRIMARY KEY, word_id TEXT NOT NULL, deck_id TEXT NOT NULL,
            date REAL NOT NULL, grade INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE word_roots(
            root_id TEXT NOT NULL, word_id TEXT NOT NULL,
            PRIMARY KEY(root_id, word_id));
        CREATE TABLE study_sessions(
            session_id TEXT PRIMARY KEY, current_index INTEGER NOT NULL,
            planned_count INTEGER NOT NULL, updated_at REAL NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE INDEX idx_words_deck ON words(deck_id, phase);
        CREATE INDEX idx_words_due ON words(due_at);
        CREATE INDEX idx_logs_date ON review_logs(date);
        CREATE INDEX idx_roots_word ON word_roots(word_id);
        """

    private static func createSchema(_ db: OpaquePointer) throws {
        try exec(db, ddl)
        try insert(db, "INSERT INTO meta(key, value) VALUES('schema_version', ?)") { stmt in
            bindText(stmt, 1, String(schemaVersion))
        }
    }

    // MARK: - 写入

    private static func insertAll(_ db: OpaquePointer, snapshot: Snapshot) throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func payload<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }

        for deck in snapshot.decks {
            try insert(db, "INSERT OR REPLACE INTO decks VALUES(?,?,?,?)") { stmt in
                bindText(stmt, 1, deck.id)
                bindText(stmt, 2, deck.name)
                sqlite3_bind_int(stmt, 3, deck.isCurrent ? 1 : 0)
                bindText(stmt, 4, try payload(deck))
            }
        }

        var rootLinks = 0
        for word in snapshot.words {
            try insert(db, "INSERT OR REPLACE INTO words VALUES(?,?,?,?,?,?)") { stmt in
                bindText(stmt, 1, word.id)
                bindText(stmt, 2, word.deckID)
                bindText(stmt, 3, word.text)
                bindText(stmt, 4, word.srs.phase.rawValue)
                sqlite3_bind_double(stmt, 5, word.srs.dueAt.timeIntervalSince1970)
                bindText(stmt, 6, try payload(word))
            }
            try insert(db, "INSERT OR REPLACE INTO srs_states VALUES(?,?,?,?,?)") { stmt in
                bindText(stmt, 1, word.id)
                bindText(stmt, 2, word.srs.phase.rawValue)
                sqlite3_bind_double(stmt, 3, word.srs.dueAt.timeIntervalSince1970)
                sqlite3_bind_int(stmt, 4, Int32(word.srs.reps))
                bindText(stmt, 5, try payload(word.srs))
            }
            // 只登记可靠的词根拆解结果，避免把「含相同字母」误判成同根
            for rootID in Set(RootParser.rootIDs(in: word.segments)) where !rootID.isEmpty {
                try insert(db, "INSERT OR IGNORE INTO word_roots VALUES(?,?)") { stmt in
                    bindText(stmt, 1, rootID)
                    bindText(stmt, 2, word.id)
                }
                rootLinks += 1
            }
        }

        for log in snapshot.logs {
            try insert(db, "INSERT OR REPLACE INTO review_logs VALUES(?,?,?,?,?,?)") { stmt in
                bindText(stmt, 1, log.id)
                bindText(stmt, 2, log.wordID)
                bindText(stmt, 3, log.deckID)
                sqlite3_bind_double(stmt, 4, log.date.timeIntervalSince1970)
                sqlite3_bind_int(stmt, 5, Int32(log.grade.rawValue))
                bindText(stmt, 6, try payload(log))
            }
        }

        for session in snapshot.sessions {
            try insert(db, "INSERT OR REPLACE INTO study_sessions VALUES(?,?,?,?,?)") { stmt in
                bindText(stmt, 1, session.id)
                sqlite3_bind_int(stmt, 2, Int32(session.index))
                sqlite3_bind_int(stmt, 3, Int32(session.plannedCount))
                sqlite3_bind_double(stmt, 4, session.updatedAt.timeIntervalSince1970)
                bindText(stmt, 5, try payload(session))
            }
        }

        try insert(db, "INSERT OR REPLACE INTO settings VALUES('app_settings', ?)") { stmt in
            bindText(stmt, 1, try payload(snapshot.settings))
        }
        return rootLinks
    }

    // MARK: - 校验与备份

    private static func validate(_ db: OpaquePointer,
                                 snapshot: Snapshot,
                                 links: Int) throws {
        try expectCount(db, table: "words", expected: snapshot.words.count)
        try expectCount(db, table: "decks", expected: snapshot.decks.count)
        try expectCount(db, table: "review_logs", expected: snapshot.logs.count)
        try expectCount(db, table: "srs_states", expected: snapshot.words.count)
        try expectCount(db, table: "study_sessions", expected: snapshot.sessions.count)

        // word_roots 是 (rootID, wordID) 去重后的关系数，与写入时统计的 links 对照
        let expectedLinks = Set(snapshot.words.flatMap { word in
            Set(RootParser.rootIDs(in: word.segments))
                .filter { !$0.isEmpty }
                .map { "\($0)#\(word.id)" }
        }).count
        try expectCount(db, table: "word_roots", expected: expectedLinks)
        guard links == expectedLinks else {
            throw UserDataMigrationError.validationFailed(
                "word_roots 写入计数 \(links) 与校验值 \(expectedLinks) 不一致")
        }
    }

    private static func expectCount(_ db: OpaquePointer,
                                    table: String,
                                    expected: Int) throws {
        let actual = countRows(db, table: table)
        guard actual == expected else {
            throw UserDataMigrationError.validationFailed(
                "\(table)：JSON \(expected) 条，SQLite \(actual) 条")
        }
    }

    private static func countRows(_ db: OpaquePointer, table: String) -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT count(*) FROM \(table)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return -1 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : -1
    }

    private static func backupJSON(snapshot: Snapshot) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("UserData-pre-migration-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BackupSnapshot(words: snapshot.words,
                                                     decks: snapshot.decks,
                                                     logs: snapshot.logs,
                                                     settings: snapshot.settings))
        try data.write(to: url, options: .atomic)
        // 回读自检，避免留下空备份
        guard let read = try? Data(contentsOf: url), read.count == data.count else {
            throw UserDataMigrationError.backupFailed("备份回读失败")
        }
        return url
    }

    private struct BackupSnapshot: Codable {
        var words: [Word]
        var decks: [Deck]
        var logs: [ReviewLog]
        var settings: AppSettings
    }

    // MARK: - SQLite 小工具

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(message)
            throw UserDataMigrationError.schemaFailed(text)
        }
        sqlite3_free(message)
    }

    private static func insert(_ db: OpaquePointer,
                               _ sql: String,
                               bind: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw UserDataMigrationError.insertFailed(
                "\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(s) }
        do {
            try bind(s)
        } catch {
            throw UserDataMigrationError.insertFailed("\(error)")
        }
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw UserDataMigrationError.insertFailed(
                "\(sql): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_USERDATA)
    }
}
