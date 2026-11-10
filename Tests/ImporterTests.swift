//
//  ImporterTests.swift
//  导入解析：分隔符识别、冒号切分、批量导入与性能
//

import Foundation

func runImporterTests(_ t: TestContext) {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // 分隔符与冒号切分
    t.expect(Importer.sniffDelimiter(["apple,苹果", "banana,香蕉"]) == ",",
             "逗号分隔应被识别")
    let split = Importer.colonSplit("apple:苹果")
    t.equal(split?.word, "apple", "冒号切分应取到单词")
    t.equal(split?.meaning, "苹果", "冒号切分应取到中文释义")
    t.expect(Importer.colonSplit("没有分隔符") == nil, "没有冒号时应返回 nil")

    // 文本导入 → 落库单词
    do {
        let result = try Importer.parse(text: "apple:苹果\nbanana:香蕉",
                                        targetDeckID: "D",
                                        targetDeckName: "测试词单")
        let words = Importer.makeWords(from: result, deckID: "D", startPosition: 0, now: now)
        t.equal(words.count, 2, "两行文本应解析成 2 个单词")
        t.equal(words.first?.text, "apple", "第一个单词文本")
        t.equal(words.last?.deckID, "D", "导入单词应带上目标词单 id")
    } catch {
        t.expect(false, "文本导入不应抛错：\(error)")
    }

    // 空文本：产品约定是明确拒绝（emptyResult），而不是静默生成 0 个单词
    var emptyRejected = false
    do {
        _ = try Importer.parse(text: "", targetDeckID: "D", targetDeckName: "测试词单")
    } catch {
        emptyRejected = true
    }
    t.expect(emptyRejected, "空文本应被明确拒绝，且不崩溃")

    // 重复词：整批都已存在时产品约定抛出 allWordsAlreadyInDeck，避免用户以为导入成功
    var duplicateRejected = false
    do {
        let once = try Importer.parse(text: "apple:苹果",
                                      targetDeckID: "D",
                                      targetDeckName: "测试词单")
        let seed = Importer.makeWords(from: once, deckID: "D", startPosition: 0, now: now)
        let known = Dictionary(uniqueKeysWithValues: seed.map { (Importer.normalizeKey($0.text), $0) })
        _ = try Importer.parse(text: "apple:苹果",
                               targetDeckID: "D",
                               targetDeckName: "测试词单",
                               knownWords: known)
    } catch {
        duplicateRejected = true
    }
    t.expect(duplicateRejected, "全部单词已存在时应明确提示，不应无限重复导入")

    // 性能基线：批量导入（文档第五节 100 / 500 / 1000 词）
    let lines = (0..<500).map { "word\($0):释义\($0)" }.joined(separator: "\n")
    t.measure("导入解析 · 500 词", iterations: 3) {
        _ = try? Importer.parse(text: lines, targetDeckID: "D", targetDeckName: "批量")
    }
}
