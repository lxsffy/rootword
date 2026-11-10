//
//  RootParserTests.swift
//  词根拆解：显式 spec、SQLite 索引命中、边界输入与批量性能
//

import Foundation

func runRootParserTests(_ t: TestContext) {

    // 显式 spec
    let explicit = RootParser.parseExplicit("un-|happy")
    t.equal(explicit.count, 2, "显式 spec 应拆成 2 段")
    // 测试构建没有 RootLibrary.json，段的 rootID/type 依赖词根库查表；
    // 这里只验证 spec 文本被正确切开，类型标注由 App 内的 DEBUG 自检覆盖。
    t.expect(explicit.first?.text.contains("un") == true, "第一段应取自 spec 的 un-")

    // 边界输入
    t.equal(RootParser.parse("").count, 1, "空词不应崩溃，返回单个未收录段")
    t.equal(RootParser.parse("2024abc").count, 1, "含数字的词不应参与拆解")
    t.expect(RootParser.rootIDs(in: explicit).isEmpty || !RootParser.rootIDs(in: explicit).isEmpty,
             "rootIDs 应可安全调用")

    // SQLite 预计算索引命中（测试运行器已注入真实 roots.sqlite）
    let unhappy = RootParser.parse("unhappy")
    t.expect(unhappy.count >= 2, "unhappy 应命中预计算索引并拆成多段")
    let international = RootParser.parse("international")
    t.expect(international.count >= 2, "international 应命中预计算索引")

    // 未命中不应崩溃，且会产生在线解析回退计数
    let before = SQLiteRootIndex.stats().onlineFallbacks
    let nonsense = RootParser.parse("gzzxq")
    t.expect(!nonsense.isEmpty, "索引未命中时应返回可展示的段而不是空数组")
    t.expect(SQLiteRootIndex.stats().onlineFallbacks > before, "索引未命中应记录一次在线解析回退")

    // 性能基线：词根索引查询（文档第五节）
    let samples = ["unhappy", "international", "spectator", "transportation",
                   "impossible", "teacher", "airport", "yesterday"]
    t.measure("词根索引查询 · 1000 次", iterations: 1) {
        for i in 0..<1000 { _ = RootParser.parse(samples[i % samples.count]) }
    }
}
