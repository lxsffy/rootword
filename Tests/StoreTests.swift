//
//  StoreTests.swift
//  JSON 持久化往返、会话恢复、损坏容忍与写入性能
//

import Foundation

func runStoreTests(_ t: TestContext) {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("rootword-store-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let store = Store(rootDir: temp, documentsDir: temp)
    store.load()
    t.expect(store.words.isEmpty, "空目录加载后单词列表应为空")

    let words = [
        Word(text: "apple", meaning: "苹果", deckID: "D", position: 0),
        Word(text: "banana", meaning: "香蕉", deckID: "D", position: 1),
    ]
    let decks = [Deck(name: "测试词单", isCurrent: true)]
    let settings = AppSettings()
    store.persistSync(words: words, decks: decks, logs: [], settings: settings)

    let reloaded = Store(rootDir: temp, documentsDir: temp)
    reloaded.load()
    t.equal(reloaded.words.count, 2, "重新加载应读回 2 个单词")
    t.equal(reloaded.words.first?.meaning, "苹果", "释义应完整往返")
    t.equal(reloaded.decks.count, 1, "词单应完整往返")

    // 会话持久化：模拟「背到第 2 个词时 App 被回收」
    var session = StudySession(queue: ["id-a", "id-b", "id-c"],
                               startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               plannedCount: 3)
    session.index = 1
    session.remembered = 1
    store.saveSession(session)
    let restored = store.loadSession()
    t.equal(restored?.queue, ["id-a", "id-b", "id-c"], "会话队列应完整恢复")
    t.equal(restored?.index, 1, "应恢复到当前学到第几个词")
    t.equal(restored?.remembered, 1, "本轮统计应恢复")

    store.saveSession(nil)
    t.expect(store.loadSession() == nil, "会话结束后应删除 session.json")

    // 差异写入：只改 words 后，decks 与 settings 仍须保持一致可读
    var changed = words
    changed[0].meaning = "苹果（已修订）"
    store.persist(words: changed, decks: decks, logs: [], settings: settings)
    // persist 为异步，给串行 IO 队列一点时间完成后再回读
    Thread.sleep(forTimeInterval: 0.3)
    let afterDiff = Store(rootDir: temp, documentsDir: temp)
    afterDiff.load()
    t.equal(afterDiff.words.first?.meaning, "苹果（已修订）", "差异写入应更新 words")
    t.equal(afterDiff.decks.count, 1, "差异写入不应破坏 decks")

    // 损坏文件不应让 load 崩溃
    let corruptDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rootword-corrupt-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: corruptDir) }
    try? Data("{ not json".utf8).write(to: corruptDir.appendingPathComponent("words.json"))
    let corruptStore = Store(rootDir: corruptDir, documentsDir: corruptDir)
    corruptStore.load()
    t.expect(corruptStore.words.isEmpty, "损坏的 words.json 应降级为空列表")
    t.expect(corruptStore.wordsCorrupted, "损坏应被标记以便 UI 提示")

    // 性能基线：JSON 全量写盘（文档第五节）
    let bulk = (0..<1000).map { Word(text: "bulk\($0)", meaning: "释义\($0)", deckID: "D", position: $0) }
    t.measure("JSON 持久化 · 1000 词", iterations: 3) {
        store.persistSync(words: bulk, decks: decks, logs: [], settings: settings)
    }
}
