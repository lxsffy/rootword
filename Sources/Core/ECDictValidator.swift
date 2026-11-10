//
//  ECDictValidator.swift
//  RootWord · 词根单词
//
//  离线词典三层校验（纯 Foundation，App 与自测共用）。
//
//  数据源：Dictionary.sqlite（english_entries 主键查询，替代 ecdict_light.tsv 全量加载；源文件 BUKADictionary.sqlite 来自 FlashCardApp 逆向）
//
//  三层校验：
//    1) 存在性：识别词小写化后是否在词库中（词组按空格拆 token 逐词查字典）
//    2) 常用度：priority <= 80 视为常用（20=常规词、80=次常用，合计占词库 98%），否则标生僻「?」
//    3) 释义一致性：识别释义与词库标准释义按连续 CJK 片段集合求交集，
//       重叠率 < 30% 判可疑（能检出「合法词替换」类 OCR 错误，如 seek→sick）
//
//  纠错：仅用 UITextChecker（iOS 拼写检查）做单候选纠正；
//  不采用 topCandidates 多候选交叉验证取合法词的词典判定法（已被验证会反引入错误）。
//
//  大修要点（1.4.0）：词典从「全量加载进内存」（36MB tsv → 77 万条 Swift 字典，
//  峰值内存 150MB+）改为「SQLite 主键按需查询」（磁盘常驻，O(log n)，内存趋零），
//  并同步获得 tsv 缺失的 phonetic 音标数据。
//

import Foundation

// MARK: - 离线词典三层校验

enum ECDictValidator {

    struct DictEntry {
        let priority: Int
        let translation: String
        let phonetic: String

        /// 常用度：priority <= 80 视为常用（20=常规词、80=次常用）
        var isCommon: Bool { priority <= 80 }
    }

    struct ValidationResult {
        var exists = true
        var isCommon = true
        var overlapRate: Double?          // nil = 无中文释义可比对（跳过释义检查）
        var suspicious = false            // 释义一致性 FAIL / 词不存在
        var uncommon = false              // 常用度 WARN
        var suggestions: [String] = []    // 编辑距离 <= 2 的常用词候选
        var mark: String {                // 可疑 ⚠，生僻 ?
            var m = ""
            if suspicious { m += "⚠" }
            if uncommon { m += "?" }
            return m
        }
        var hint: String {
            var h = ""
            if !mark.isEmpty { h += mark }
            if !suggestions.isEmpty { h += " 候选:" + suggestions.joined(separator: "/") }
            return h
        }
    }

    // MARK: - 词条查询（SQLite 主键查询，线程安全，无全量加载）

    /// 单条词条查询（含变体兜底）。词库缺失/未打开时返回 nil。
    static func lookup(_ word: String) -> DictEntry? {
        guard let e = SQLiteDict.lookup(word) else { return nil }
        return DictEntry(priority: e.priority, translation: e.translation, phonetic: e.phonetic)
    }

    /// 打开词典连接（懒加载；UI 预加载用，返回是否就绪）
    @discardableResult
    static func ensureOpen() -> Bool { SQLiteDict.ensureOpen() }

    static var isReady: Bool { SQLiteDict.isReady }

    /// 常用词前缀搜索：供「大词库选词」功能浏览/检索用（SQLite 主键范围扫描）。
    /// 空前缀返回空（由 UI 引导输入）；最多返回 limit 条。
    static func commonWords(prefix: String, limit: Int = 200) -> [(word: String, translation: String)] {
        SQLiteDict.commonWords(prefix: prefix, limit: limit)
    }

    // MARK: - 三层校验

    /// 词组按空格拆分 token 逐词校验存在性
    static func tokens(_ word: String) -> [String] {
        word.lowercased()
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 提取连续 CJK 中文字符片段集合（标点/非汉字即断开）
    static func cjkRuns(_ s: String) -> Set<String> {
        var runs: Set<String> = []
        var cur = ""
        for ch in s {
            let v = ch.unicodeScalars.first?.value ?? 0
            let isCJK = (0x4E00...0x9FFF).contains(v)
                || (0x3400...0x4DBF).contains(v)
                || (0xF900...0xFAFF).contains(v)
            if isCJK {
                cur.append(ch)
            } else {
                if !cur.isEmpty { runs.insert(cur) }
                cur = ""
            }
        }
        if !cur.isEmpty { runs.insert(cur) }
        return runs
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aa = Array(a), bb = Array(b)
        if aa.isEmpty || bb.isEmpty { return max(aa.count, bb.count) }
        var dp = Array(repeating: Array(repeating: 0, count: bb.count + 1), count: aa.count + 1)
        for i in 0...aa.count { dp[i][0] = i }
        for j in 0...bb.count { dp[0][j] = j }
        for i in 1...aa.count {
            for j in 1...bb.count {
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1,
                               dp[i - 1][j - 1] + (aa[i - 1] == bb[j - 1] ? 0 : 1))
            }
        }
        return dp[aa.count][bb.count]
    }

    /// 在常用词（priority <= 80）中找编辑距离 <= 2 的候选，最多 limit 个
    static func suggestions(for word: String, limit: Int = 3) -> [String] {
        let w = word.lowercased()
        guard let f = w.first else { return [] }
        let bucket = SQLiteDict.commonCandidates(prefix: f)
        var cands: [(String, Int)] = []
        for c in bucket {
            if abs(c.count - w.count) > 2 { continue }
            let d = levenshtein(w, c)
            if d > 0 && d <= 2 { cands.append((c, d)) }
        }
        cands.sort { $0.1 < $1.1 }
        return Array(cands.prefix(limit).map { $0.0 })
    }

    /// 校验单个识别词条（word 与 def 来自 OCR 解析），返回标记文本
    static func validate(word: String, def: String) -> String {
        guard SQLiteDict.isReady else { return "" }  // 词库缺失时不标记，避免全量误报
        return validateResult(word: word, def: def).hint
    }

    static func validateResult(word: String, def: String) -> ValidationResult {
        var r = ValidationResult()
        let toks = tokens(word)
        guard !toks.isEmpty else { return r }

        // 第一层：存在性（词组逐 token；含变体兜底）
        let tokenEntries = toks.map { lookup($0) }
        r.exists = tokenEntries.allSatisfy { $0 != nil }
        if !r.exists {
            r.suspicious = true
            r.suggestions = suggestions(for: toks.first ?? word)
            return r
        }

        // 第二层：常用度（词组要求所有 token 常用）
        r.isCommon = tokenEntries.allSatisfy { $0?.isCommon ?? false }
        if !r.isCommon { r.uncommon = true }

        // 第三层：释义一致性（仅单词整体词条可比对；词组无整体释义，跳过）
        if toks.count == 1, let entry = lookup(toks[0]) {
            let recRuns = cjkRuns(def)
            let dictRuns = cjkRuns(entry.translation)
            if !recRuns.isEmpty && !dictRuns.isEmpty {
                let inter = recRuns.intersection(dictRuns).count
                let rate = Double(inter) / Double(recRuns.count)
                r.overlapRate = rate
                if rate < 0.3 {
                    r.suspicious = true
                    r.suggestions = suggestions(for: toks[0])
                }
            }
        }
        return r
    }
}
