//
//  ECDictValidator.swift
//  RootWord · 词根单词
//
//  离线 ECDICT 大词库三层校验（纯 Foundation，App 与自测共用）。
//
//  数据源：ecdict_light.tsv（word / tag / frq / translation 四列，约 77 万词条，
//  随 .app bundle 内置，首次使用懒加载并缓存）。
//
//  三层校验：
//    1) 存在性：识别词小写化后是否在词库中（词组按空格拆 token 逐词查字典）
//    2) 常用度：tag 含 zk/gk/cet4/cet6/ky/toefl/ielts 任一，或 frq > 0，否则标生僻「?」
//    3) 释义一致性：识别释义与词库标准释义按连续 CJK 片段集合求交集，
//       重叠率 < 30% 判可疑（能检出「合法词替换」类 OCR 错误，如 seek→sick）
//
//  纠错：仅用 UITextChecker（iOS 拼写检查）做单候选纠正；
//  不采用 topCandidates 多候选交叉验证取合法词的词典判定法（已被验证会反引入错误）。
//

import Foundation

// MARK: - 离线 ECDICT 词库三层校验

enum ECDictValidator {

    struct DictEntry {
        let tag: String
        let frq: Int
        let translation: String

        /// 常用度：tag 含考试标签任一，或 frq > 0
        var isCommon: Bool {
            if frq > 0 { return true }
            let tokens = tag.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "、" })
            return tokens.contains { ["zk", "gk", "cet4", "cet6", "ky", "toefl", "ielts"].contains(String($0)) }
        }
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

    // MARK: - 词库加载（懒加载 + 缓存，线程安全）

    private static let lock = NSLock()
    private static var _dict: [String: DictEntry]?
    private static var _firstIndex: [Character: [String]] = [:]  // 常用词按首字母索引

    /// 默认从 Bundle.main 读取 ecdict_light.tsv；自测脚本可传绝对路径覆盖
    ///
    /// 加载优化（36MB / 77 万词条）：
    ///  · 手动 \n 切行（零拷贝 Substring 游标遍历，不再生成 77 万行的全量 [Substring] 数组）
    ///  · firstIndex 精确定位前 3 个 \t（替代每行再 split 生成中间数组）
    ///  · 预分配 80 万容量（防字典扩容时的整体复制峰值）
    static func loadDict(from fileURL: URL? = nil) -> [String: DictEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let d = _dict { return d }

        var d: [String: DictEntry] = [:]
        d.reserveCapacity(800_000)
        var firstIdx: [Character: [String]] = [:]
        firstIdx.reserveCapacity(32)

        let url: URL
        if let f = fileURL {
            url = f
        } else if let bundled = Bundle.main.url(forResource: "ecdict_light", withExtension: "tsv") {
            url = bundled
        } else {
            _dict = d
            return d
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            _dict = d
            return d
        }

        // 手动按 \n 切行：每次只保留当前行的 Substring（零拷贝），不构建全量行数组
        var lineStart = content.startIndex
        while lineStart < content.endIndex {
            let nl = content[lineStart...].firstIndex(of: "\n") ?? content.endIndex
            var lineEnd = nl
            if lineEnd > lineStart {
                let prev = content.index(before: lineEnd)
                if content[prev] == "\r" { lineEnd = prev }   // 兼容 \r\n
            }

            if lineEnd > lineStart {
                let line = content[lineStart..<lineEnd]
                // firstIndex 依次定位前 3 个 \t（第 4 列即 translation，取到行尾）
                if let t1 = line.firstIndex(of: "\t") {
                    let after1 = line.index(after: t1)
                    if let t2 = line[after1...].firstIndex(of: "\t") {
                        let after2 = line.index(after: t2)
                        if let t3 = line[after2...].firstIndex(of: "\t") {
                            let w = String(line[line.startIndex..<t1])
                            let tag = String(line[after1..<t2])
                            let frqStr = String(line[after2..<t3])
                            let translation = String(line[line.index(after: t3)...])
                            let e = DictEntry(tag: tag,
                                              frq: Int(frqStr) ?? 0,
                                              translation: translation)
                            d[w] = e
                            if e.isCommon, let f = w.first {
                                firstIdx[f, default: []].append(w)
                            }
                        }
                    }
                }
            }

            if nl == content.endIndex { break }
            lineStart = content.index(after: nl)
        }

        // 首字母桶排序，供「大词库选词」前缀浏览直接使用
        for (k, v) in firstIdx { firstIdx[k] = v.sorted() }
        _dict = d
        _firstIndex = firstIdx
        return d
    }

    static var loadedCount: Int { (_dict ?? [:]).count }

    /// 常用词前缀搜索：供「大词库选词」功能浏览/检索用。
    /// 空前缀返回空（由 UI 引导输入）；最多返回 limit 条。
    static func commonWords(prefix: String, limit: Int = 200) -> [(word: String, translation: String)] {
        let dict = loadDict()
        guard !dict.isEmpty else { return [] }
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty, let f = p.first, let bucket = _firstIndex[f] else { return [] }
        var out: [(word: String, translation: String)] = []
        for w in bucket where w.hasPrefix(p) {
            if let e = dict[w] {
                out.append((w, e.translation))
                if out.count >= limit { break }
            }
        }
        return out
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

    /// 在常用词（tag 命中考试标签或 frq>0）中找编辑距离 <= 2 的候选，最多 limit 个
    static func suggestions(for word: String, limit: Int = 3) -> [String] {
        let w = word.lowercased()
        guard let f = w.first, let bucket = _firstIndex[f] else { return [] }
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
        let dict = loadDict()
        guard !dict.isEmpty else { return "" }  // 词库缺失时不标记，避免全量误报
        return validateResult(word: word, def: def, dict: dict).hint
    }

    static func validateResult(word: String, def: String,
                               dict: [String: DictEntry]? = nil) -> ValidationResult {
        let d = dict ?? loadDict()
        var r = ValidationResult()
        let toks = tokens(word)
        guard !toks.isEmpty else { return r }

        // 第一层：存在性（词组逐 token）
        let tokenEntries = toks.map { d[$0] }
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
        if toks.count == 1, let entry = d[toks[0]] {
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
