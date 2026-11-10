//
//  SQLiteRootIndexTests.swift
//  完整性保护：返回值、表结构校验、NOCASE 查询、DEBUG 命中统计
//

import Foundation
import SQLite3

func runSQLiteRootIndexTests(_ t: TestContext) {
    let goodPath = TestEnvironment.rootsDatabase
    SQLiteRootIndex.configure(path: goodPath)
    SQLiteRootIndex.resetStats()

    t.expect(SQLiteRootIndex.ensureOpen(), "真实 roots.sqlite 应能打开并通过结构校验")

    // 命中 / 大小写不敏感 / 未命中
    t.equal(SQLiteRootIndex.spec(for: "unhappy"), "un-|happy", "unhappy 的预计算 spec")
    t.equal(SQLiteRootIndex.spec(for: "UNHAPPY"), "un-|happy", "主键 COLLATE NOCASE 应大小写不敏感")
    t.expect(SQLiteRootIndex.spec(for: "Transportation") != nil, "混合大小写应命中 transportation")
    t.expect(SQLiteRootIndex.spec(for: "gzzxq") == nil, "不存在的词应返回 nil")
    t.expect(SQLiteRootIndex.spec(for: "") == nil, "空词应直接返回 nil")

    // 统计
    let stats = SQLiteRootIndex.stats()
    t.expect(stats.hits >= 3, "命中次数应被记录（实际 \(stats.hits)）")
    t.expect(stats.misses >= 1, "未命中次数应被记录（实际 \(stats.misses)）")
    t.equal(stats.queryErrors, 0, "正常查询不应产生查询错误")
    t.equal(stats.openFailures, 0, "正常数据库不应产生打开失败")

    // 打开失败：路径不存在要明确计数，而不是静默返回 nil
    let failuresBefore = SQLiteRootIndex.stats().openFailures
    SQLiteRootIndex.configure(path: TestEnvironment.projectRoot
        .appendingPathComponent("Resources/__missing_roots__.sqlite").path)
    t.expect(!SQLiteRootIndex.ensureOpen(), "缺失数据库应打开失败")
    t.expect(SQLiteRootIndex.spec(for: "unhappy") == nil, "打开失败时查询应返回 nil")
    t.expect(SQLiteRootIndex.stats().openFailures > failuresBefore, "打开失败应被计入 openFailures")

    // 表结构不符：有数据库文件但缺少 word / spec 字段，必须拒绝打开
    let badPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("rootword-bad-schema-\(UUID().uuidString).sqlite").path
    var db: OpaquePointer?
    if sqlite3_open(badPath, &db) == SQLITE_OK {
        sqlite3_exec(db, "CREATE TABLE precomputed_roots(id INTEGER PRIMARY KEY, payload TEXT)",
                     nil, nil, nil)
    }
    if let db = db { sqlite3_close(db) }
    let schemaFailuresBefore = SQLiteRootIndex.stats().openFailures
    SQLiteRootIndex.configure(path: badPath)
    t.expect(!SQLiteRootIndex.ensureOpen(), "缺少 word/spec 字段时结构校验应失败")
    t.expect(SQLiteRootIndex.stats().openFailures > schemaFailuresBefore,
             "结构校验失败应被计入 openFailures")
    try? FileManager.default.removeItem(atPath: badPath)

    // 恢复为真实数据库，避免影响同进程内后续用例
    SQLiteRootIndex.configure(path: goodPath)
    t.expect(SQLiteRootIndex.ensureOpen(), "重新配置后应能再次打开真实数据库")
}
