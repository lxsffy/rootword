//
//  RootParser.swift
//  RootWord · 词根单词
//
//  词根记忆法的核心：把一个单词拆成「前缀 + 词根 + 后缀」——
//  产品设计文档 7.6.2 的七步流程的 1:1 实现（S1–S7）。
//
//     S1 归一化：小写、去首尾空白；非字母（含数字）直接判为未收录
//     S2 前缀扫描：最长优先（5→2），支持 in- 家族同化变体 {im-, il-, ir-}
//     S3 后缀扫描：从剩余部分尾部最长优先（7→2），复合后缀在库中显式列出
//     S4 词干匹配：精确 → 子串（len≥4）→ 编辑距离 ≤1（len≥4）
//     S5 组装：按原文顺序输出，未匹配部分 type = .other
//     S6 兜底：整词无命中 → 单个 "未收录" 片段
//     S7 缓存：结果在导入时写入 Word.segments，学习时不再重算
//
//  工程决策（与文档 7.6.2 唯一的一处收紧，理由已在下方注明）：
//    ad- 家族同化变体 {ac-/af-/ag-/al-/ap-/ar-/as-/at-} 不做自动匹配。
//    原因是「al-/as-/at-」开头的常见单词（also / allow / as / at）极易被误拆成
//    伪词源，违反"不编造"铁律；此类词交给用户用导入的 root 字段显式指定。
//    in- 家族（im-/il-/ir-）与 com- 家族（con-/col-/cor-）语义收敛、误伤率低，予以支持。
//

import Foundation

enum RootParser {

    // MARK: - 前缀同化变体（S2）

    /// 变体 → 词根库中的规范 id
    static let assimilation: [String: String] = [
        // in- 家族：不、无
        "im": "in",
        "il": "in",
        "ir": "in",
        // com- 家族：共同、一起
        "con": "com",
        "col": "com",
        "cor": "com"
    ]

    // MARK: - 索引（懒加载一次）

    private static let prefixIndex: [String: RootEntry] = {
        Dictionary(RootLibrary.shared.entries
            .filter { $0.type == .prefix }
            .map { ($0.normalized, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    private static let suffixIndex: [String: RootEntry] = {
        Dictionary(RootLibrary.shared.entries
            .filter { $0.type == .suffix }
            .map { ($0.normalized, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    private static let rootIndex: [String: RootEntry] = {
        Dictionary(RootLibrary.shared.entries
            .filter { $0.type == .root }
            .map { ($0.normalized, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    /// 子串匹配用：按长度降序，保证"最长优先"
    private static let rootListByLength: [RootEntry] = {
        RootLibrary.shared.entries
            .filter { $0.type == .root && $0.normalized.count >= 4 }
            .sorted { $0.normalized.count > $1.normalized.count }
    }()

    // MARK: - 对外 API

    /// 解析入口。`explicitRoot` 为导入数据中用户/老师提供的 root 字段，优先级最高（文档 8.6.2）。
    static func parse(_ raw: String, explicitRoot: String? = nil) -> [WordSegment] {
        let word = normalize(raw)

        // S1 + T10：空词 / 非字母词不崩溃，直接返回未收录
        guard !word.isEmpty, isMatchable(word) else {
            return [unmatchedSegment(raw)]
        }

        // 显式 root 字段优先
        if let spec = explicitRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !spec.isEmpty {
            let explicit = parseExplicit(spec)
            if !explicit.isEmpty { return explicit }
        }

        // S2 前缀扫描
        var prefixSegment: WordSegment?
        var body = word
        if let match = matchPrefix(word) {
            prefixSegment = WordSegment(text: match.form + "-",
                                        type: .prefix,
                                        meaning: match.entry.meaning,
                                        rootID: match.entry.id)
            body = String(word.dropFirst(match.form.count))
        }

        // S3 后缀扫描
        var suffixSegment: WordSegment?
        var stem = body
        if let match = matchSuffix(body) {
            suffixSegment = WordSegment(text: "-" + match.form,
                                        type: .suffix,
                                        meaning: match.entry.meaning,
                                        rootID: match.entry.id)
            stem = String(body.dropLast(match.form.count))
        }

        // S4 词干匹配
        var stemSegment: WordSegment?
        if !stem.isEmpty {
            if let entry = matchRoot(stem) {
                stemSegment = WordSegment(text: entry.normalized,
                                          type: .root,
                                          meaning: entry.meaning,
                                          rootID: entry.id)
            } else if prefixSegment != nil || suffixSegment != nil {
                stemSegment = WordSegment(text: stem, type: .other, meaning: "")
            }
        }

        // S5 组装（按原文顺序）
        var segments: [WordSegment] = []
        if let prefixSegment = prefixSegment { segments.append(prefixSegment) }
        if let stemSegment = stemSegment { segments.append(stemSegment) }
        if let suffixSegment = suffixSegment { segments.append(suffixSegment) }
        if prefixSegment == nil && stemSegment == nil && suffixSegment == nil {
            segments.append(unmatchedSegment(raw))
        }

        // 命中片段不足 2 个 → 视为未收录（避免"只有后缀"这种半截拆解误导学生）
        if segments.count < 2 {
            return [unmatchedSegment(raw)]
        }
        return segments
    }

    /// 批量解析（导入时调用）
    static func parseAll(words: [String], explicitRoots: [String: String] = [:]) -> [String: [WordSegment]] {
        var result: [String: [WordSegment]] = [:]
        for word in words {
            result[word] = parse(word, explicitRoot: explicitRoots[word])
        }
        return result
    }

    // MARK: - 记忆法文案（文档 7.6.4）

    /// 算法拼接：`un（不）+ happy（快乐）→ 不快乐的`；仅当命中 ≥ 2 个片段时生成
    static func makeMnemonic(segments: [WordSegment], meaning: String) -> String {
        let valid = segments.filter { $0.type != .other && !$0.meaning.isEmpty }
        guard valid.count >= 2 else { return "" }

        let parts = valid.map { segment -> String in
            let form = segment.text.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return "\(form)（\(segment.meaning)）"
        }
        var text = parts.joined(separator: " + ")
        let tail = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            text += " → \(tail)"
        }
        return text
    }

    // MARK: - S2 前缀扫描

    private struct Match {
        let form: String        // 原文中的形式，如 im
        let entry: RootEntry
    }

    private static func matchPrefix(_ word: String) -> Match? {
        guard word.count > 3 else { return nil }
        let maxLength = min(5, word.count - 3)
        guard maxLength >= 2 else { return nil }

        for length in stride(from: maxLength, through: 2, by: -1) {
            let form = String(word.prefix(length))
            let remainder = String(word.dropFirst(length))
            // 剩余部分至少 4 个字母：避免 about → ab- + out 这类无意义的伪拆解
            guard remainder.count >= 4 else { continue }

            let entry: RootEntry?
            if let direct = prefixIndex[form] {
                entry = direct
            } else if let canonical = assimilation[form] {
                entry = prefixIndex[canonical]
            } else {
                entry = nil
            }

            guard let matched = entry else { continue }

            // 误伤防护：同化变体（非字面命中）要求剩余部分是可信词干
            let isLiteral = (form == matched.normalized)
            if !isLiteral {
                let trustworthy = matchRoot(remainder) != nil || remainder.count >= 5
                guard trustworthy else { continue }
            }
            return Match(form: form, entry: matched)
        }
        return nil
    }

    // MARK: - S3 后缀扫描

    private static func matchSuffix(_ body: String) -> Match? {
        guard body.count > 3 else { return nil }
        let maxLength = min(7, body.count - 3)
        guard maxLength >= 2 else { return nil }

        for length in stride(from: maxLength, through: 2, by: -1) {
            let form = String(body.suffix(length))
            guard let entry = suffixIndex[form] else { continue }
            let stem = String(body.dropLast(length))
            guard stem.count >= 3 else { continue }
            return Match(form: form, entry: entry)
        }
        return nil
    }

    // MARK: - S4 词干匹配

    static func matchRoot(_ stem: String) -> RootEntry? {
        guard !stem.isEmpty else { return nil }

        // (a) 精确命中
        if let exact = rootIndex[stem] { return exact }

        // (b) 子串命中（词根长度 ≥ 4，取最长）
        if stem.count >= 4 {
            for entry in rootListByLength where stem.contains(entry.normalized) {
                return entry
            }
        }

        // (c) 近似命中：编辑距离 ≤ 1（词长 ≥ 4），如 teaching → teach
        if stem.count >= 4 {
            for entry in rootListByLength where abs(entry.normalized.count - stem.count) <= 1 {
                if editDistance(stem, entry.normalized) <= 1 { return entry }
            }
        }
        return nil
    }

    /// 标准 Levenshtein 距离（带上限剪枝，词长短，性能无忧）
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > 1 { return 2 }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - 显式 root 字段（形如 `im-+poss+-ible` 或 `pre-|dict`）

    static func parseExplicit(_ spec: String) -> [WordSegment] {
        let rawParts = spec
            .replacingOccurrences(of: "＋", with: "+")
            .replacingOccurrences(of: "｜", with: "|")
            .replacingOccurrences(of: "|", with: "+")   // 竖线写法（模板「词根拆解」列）与加号等价
            .replacingOccurrences(of: " ", with: "")
            .split(separator: "+")
            .map { String($0) }

        guard !rawParts.isEmpty, rawParts.count <= 4 else { return [] }

        var segments: [WordSegment] = []
        for part in rawParts {
            let bare = part.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            guard !bare.isEmpty else { continue }

            let looked: RootEntry?
            if part.hasSuffix("-") && !part.hasPrefix("-") {
                looked = prefixIndex[bare] ?? assimilation[bare].flatMap { prefixIndex[$0] }
            } else if part.hasPrefix("-") {
                looked = suffixIndex[bare]
            } else {
                looked = rootIndex[bare]
            }

            if let entry = looked {
                segments.append(WordSegment(text: entry.form,
                                            type: entry.type,
                                            meaning: entry.meaning,
                                            rootID: entry.id))
            } else {
                // 文档 8.6.2：词根库里没有的片段按原样展示，类型统一为 other
                segments.append(WordSegment(text: part, type: .other, meaning: "", rootID: nil))
            }
        }
        return segments.count >= 2 ? segments : []
    }

    // MARK: - 工具

    private static func unmatchedSegment(_ raw: String) -> WordSegment {
        WordSegment(text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: .other,
                    meaning: "",
                    rootID: nil)
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 允许参与匹配的字符集：字母、连字符、撇号（文档 8.4.1 的 word 字符集）
    private static func isMatchable(_ word: String) -> Bool {
        let allowed = CharacterSet.letters
            .union(CharacterSet(charactersIn: "-'"))
        return word.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 同根词聚合用：取出该词命中的词根 id 列表
    static func rootIDs(in segments: [WordSegment]) -> [String] {
        segments.compactMap { $0.type == .other ? nil : $0.rootID }
    }
}

// MARK: - 自检（文档 7.6.3 示例 + 7.7 的 T9/T10，仅 DEBUG 编译）

#if DEBUG
enum RootParserSelfCheck {

    static func run() {
        var failures: [String] = []

        func expect(_ segments: [WordSegment], _ types: [RootType], _ label: String) {
            let actual = segments.map { $0.type }
            if actual != types {
                failures.append("\(label)：期望 \(types.map { $0.rawValue }) 实际 \(actual.map { $0.rawValue })")
            }
        }

        let unhappy = RootParser.parse("unhappy")
        expect(unhappy, [.prefix, .root], "unhappy")
        if unhappy.first?.text != "un-" { failures.append("unhappy 前缀展示错误") }

        let impossible = RootParser.parse("impossible")
        expect(impossible, [.prefix, .root, .suffix], "impossible")   // T9

        let teacher = RootParser.parse("teacher")
        expect(teacher, [.root, .suffix], "teacher")

        let international = RootParser.parse("international")
        expect(international, [.prefix, .root, .suffix], "international")

        let spectator = RootParser.parse("spectator")
        expect(spectator, [.root, .suffix], "spectator")

        let nonsense = RootParser.parse("gzzxq")
        expect(nonsense, [.other], "gzzxq 未收录")                    // T10

        expect(RootParser.parse(""), [.other], "空词")                // T10
        expect(RootParser.parse("2024abc"), [.other], "含数字")        // T10

        if failures.isEmpty {
            print("[RootParser] 自检通过：7.6.3 五个示例与 T9/T10 全部一致")
        } else {
            print("[RootParser] 自检失败：\(failures.joined(separator: "；"))")
        }
    }
}
#endif
