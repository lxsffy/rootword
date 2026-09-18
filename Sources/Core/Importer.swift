//
//  Importer.swift
//  RootWord · 词根单词
//
//  单词导入解析器（产品设计文档第 8 章）：
//    · 三种格式：JSON / CSV / TXT（含粘贴文本）
//    · 词条形态：单个单词（predict）与词组（good morning / ice cream）都支持
//    · 编码识别：UTF-8(BOM) → UTF-8 → GB18030
//    · 分隔符嗅探：@ → \t → ,（含中文，） → | → 连续空格 → 无分隔符
//    · 表头别名映射：9 个标准字段 × 多语言别名
//    · 校验分级：ERROR 跳行 / ERROR 整体失败 / WARNING 截断提示 / INFO 静默计数
//    · 去重与补全：词单内保留信息更完整的一条；跨词单仅提示；同名补全释义
//
//  本文件只做「文本 → 结构化行」，不触碰 UI 与持久化。
//

import Foundation
import CoreFoundation

// MARK: - 校验分级

enum ImportLevel: String {
    case error
    case warning
    case info

    var cnLabel: String {
        switch self {
        case .error:   return "错误"
        case .warning: return "警告"
        case .info:    return "提示"
        }
    }
}

struct ImportIssue: Equatable, Identifiable {
    var id: String { "\(level.rawValue)-\(line)-\(message)" }
    var level: ImportLevel
    /// 行号（1-based，文件原始行号；整体性错误为 0）
    var line: Int
    var message: String
}

// MARK: - 解析结果

struct ImportResult {

    /// 通过校验、可直接入库的单词
    var words: [ImportedWord] = []
    var issues: [ImportIssue] = []

    /// 文件总行数 / 有效行数
    var totalLines: Int = 0
    /// 空行、注释行
    var skippedLines: Int = 0
    /// 文件内部重复被合并的条数
    var mergedDuplicates: Int = 0
    /// 已存在于目标词单、被跳过或合并的条数
    var existingInDeck: Int = 0
    /// 已存在于其他词单（仅提示）
    var existingInOtherDecks: Int = 0
    /// 释义被自动补全的条数
    var backfilledMeanings: Int = 0

    var errorIssues: [ImportIssue] { issues.filter { $0.level == .error } }
    var warningIssues: [ImportIssue] { issues.filter { $0.level == .warning } }

    var summaryText: String {
        "识别 \(words.count) 个单词 · 跳过 \(skippedLines) 行 · 警告 \(warningIssues.count) 条"
    }
}

/// 导入过程中的中间结构（尚未生成 Word 实体）
struct ImportedWord {
    var sourceLine: Int
    var text: String
    var meaning: String = ""
    var phonetic: String = ""
    var pos: String = ""
    var rootSpec: String = ""
    var mnemonic: String = ""
    var examples: [Example] = []
    var deckName: String = ""

    /// 信息完整度，用于同词去重时择优（文档 8.6.1）
    var richness: Int {
        var score = 0
        if !meaning.isEmpty { score += 8 }
        if !phonetic.isEmpty { score += 4 }
        if !examples.isEmpty { score += 2 }
        if !mnemonic.isEmpty { score += 1 }
        if !rootSpec.isEmpty { score += 1 }
        return score
    }
}

// MARK: - 导入错误

enum ImportFailure: LocalizedError {
    case unsupportedExtension(String)
    case encodingFailed
    case fileTooLarge
    case tooManyWords(Int)
    case emptyResult
    /// 逐行明细错误（例如「第 3 行：词根列格式无法识别」），由调用方拼接好直接展示
    case lineErrors(String)
    /// 文件解析成功，但所有单词都已存在于目标词单（不是「解析失败」，而是「无需重复导入」）
    case allWordsAlreadyInDeck(count: Int, deckName: String)
    case jsonSyntax(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext):
            if ext.lowercased() == "xlsx" || ext.lowercased() == "xls" {
                return "暂不支持 .\(ext)，请在 Excel 里另存为 CSV 后导入"
            }
            return "暂不支持 .\(ext) 格式，请使用 TXT / CSV / JSON"
        case .encodingFailed:
            return "文件编码无法识别，请另存为 UTF-8 后重试"
        case .fileTooLarge:
            return "文件超过 5 MB，请拆分后分批导入"
        case .tooManyWords(let count):
            return "单次导入上限 20000 词，当前 \(count) 词，请拆分后重试"
        case .emptyResult:
            return "没有解析到任何单词，请检查文件内容"
        case .lineErrors(let detail):
            return detail
        case .allWordsAlreadyInDeck(let count, let deckName):
            return "这 \(count) 个单词已在「\(deckName)」词单中，无需重复导入"
        case .jsonSyntax(let detail):
            return "JSON 格式不正确：\(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .emptyResult, .jsonSyntax, .lineErrors:
            return "查看格式规范 →"
        case .allWordsAlreadyInDeck:
            return "可直接在「词单」页查看，或换一个词单名再导入"
        default:
            return nil
        }
    }
}

// MARK: - 解析器

enum Importer {

    /// 单次导入上限
    static let maxWordCount = 20_000
    /// 单文件体积上限（5 MB）
    static let maxFileSize = 5 * 1024 * 1024

    /// 9 个标准字段（顺序即列序，文档 8.4.1）
    static let fieldOrder = ["word", "meaning", "phonetic", "pos", "root",
                             "mnemonic", "example", "example_cn", "deck"]

    /// 表头别名（文档 8.4.2）
    static let headerAliases: [String: String] = [
        "word": "word", "单词": "word", "词汇": "word", "英文": "word", "english": "word",
        "en": "word", "headword": "word",
        "meaning": "meaning", "释义": "meaning", "中文": "meaning", "意思": "meaning",
        "翻译": "meaning", "translation": "meaning", "cn": "meaning",
        "phonetic": "phonetic", "音标": "phonetic", "ipa": "phonetic", "pronunciation": "phonetic",
        "pos": "pos", "词性": "pos", "词类": "pos",
        "root": "root", "词根": "root", "词根词缀": "root", "拆解": "root",
        "词根拆解": "root", "构词": "root", "词根词缀拆解": "root", "拆分": "root",
        "mnemonic": "mnemonic", "记忆法": "mnemonic", "助记": "mnemonic", "备注": "mnemonic",
        "example": "example", "例句": "example", "sentence": "example",
        "example_cn": "example_cn", "例句翻译": "example_cn", "例句中文": "example_cn",
        "sentence_cn": "example_cn",
        "deck": "deck", "词单": "deck", "单元": "deck", "列表": "deck",
        "词单名": "deck", "词单名称": "deck", "所属词单": "deck", "分组": "deck"
    ]

    // MARK: - 编码识别（文档 8.2）

    static func decode(_ data: Data) -> String? {
        // 1) UTF-8 with BOM
        if data.count >= 3 {
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            if Array(data.prefix(3)) == bom {
                return String(data: data.dropFirst(3), encoding: .utf8)
            }
        }
        // 2) UTF-8
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // 3) GB18030（Windows 版 Excel 导出的 CSV）
        let gbEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gbEncoding)
    }

    static func decodeFile(at url: URL) throws -> String {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maxFileSize {
            throw ImportFailure.fileTooLarge
        }
        let data = try Data(contentsOf: url)
        guard let text = decode(data) else { throw ImportFailure.encodingFailed }
        return text
    }

    static func checkExtension(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let allowed = ["txt", "csv", "tsv", "json", "md", "text", ""]
        if !allowed.contains(ext) {
            throw ImportFailure.unsupportedExtension(ext)
        }
    }

    // MARK: - 统一入口

    /// - Parameters:
    ///   - text: 文本内容（粘贴）或已解码的文件内容
    ///   - fileName: 文件名（用于判断格式），粘贴时为 nil
    ///   - targetDeckName: 目标词单名，用于同词单去重
    ///   - knownWords: 本机已有单词（word.lowercased → Word），用于去重与释义补全
    static func parse(text: String,
                      fileName: String? = nil,
                      targetDeckID: String,
                      targetDeckName: String,
                      knownWords: [String: Word] = [:]) throws -> ImportResult {

        let ext = (fileName as NSString?)?.pathExtension.lowercased() ?? ""

        if ext == "json" {
            return try parseJSON(text: text,
                                 targetDeckID: targetDeckID,
                                 targetDeckName: targetDeckName,
                                 knownWords: knownWords)
        }
        return try parseDelimited(text: text,
                                  targetDeckID: targetDeckID,
                                  targetDeckName: targetDeckName,
                                  knownWords: knownWords)
    }

    // MARK: - JSON（文档 8.5.3）

    private static func parseJSON(text: String,
                                  targetDeckID: String,
                                  targetDeckName: String,
                                  knownWords: [String: Word]) throws -> ImportResult {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportFailure.jsonSyntax("无法解析，请检查括号与引号是否配对")
        }

        var rawWords: [[String: Any]] = []
        var jsonDeckName = ""

        if let array = object as? [Any] {
            // 形态 1：["apple", "banana"]
            for item in array {
                if let s = item as? String {
                    rawWords.append(["word": s])
                } else if let dict = item as? [String: Any] {
                    rawWords.append(dict)
                }
            }
        } else if let dict = object as? [String: Any] {
            jsonDeckName = (dict["deck"] as? String) ?? ""
            if let array = dict["words"] as? [Any] {
                for item in array {
                    if let s = item as? String {
                        rawWords.append(["word": s])
                    } else if let d = item as? [String: Any] {
                        rawWords.append(d)
                    }
                }
            } else if let array = dict["list"] as? [Any] {
                // 形态 3：{ "list": [...] }
                for item in array {
                    if let s = item as? String { rawWords.append(["word": s]) }
                    else if let d = item as? [String: Any] { rawWords.append(d) }
                }
            } else {
                throw ImportFailure.jsonSyntax("缺少 words 数组")
            }
        } else {
            throw ImportFailure.jsonSyntax("顶层应为对象或数组")
        }

        var result = ImportResult()
        result.totalLines = rawWords.count
        let deckForRows = jsonDeckName.isEmpty ? targetDeckName : jsonDeckName

        var rows: [ImportedWord] = []
        for (index, dict) in rawWords.enumerated() {
            var row = ImportedWord(sourceLine: index + 1, text: "")
            row.text = (dict["word"] as? String) ?? (dict["text"] as? String) ?? ""
            row.meaning = (dict["meaning"] as? String) ?? ""
            row.phonetic = (dict["phonetic"] as? String) ?? ""
            row.pos = (dict["pos"] as? String) ?? ""
            row.rootSpec = (dict["root"] as? String) ?? ""
            row.mnemonic = (dict["mnemonic"] as? String) ?? ""
            row.deckName = (dict["deck"] as? String) ?? deckForRows

            if let examples = dict["examples"] as? [[String: Any]] {
                row.examples = examples.compactMap { item in
                    guard let en = item["en"] as? String, !en.isEmpty else { return nil }
                    return Example(en: en, cn: (item["cn"] as? String) ?? "")
                }
            } else if let example = dict["example"] as? String, !example.isEmpty {
                let cn = (dict["example_cn"] as? String) ?? ""
                row.examples = splitExamples(example).enumerated().map { pair in
                    let cns = splitExamples(cn)
                    return Example(en: pair.element, cn: pair.offset < cns.count ? cns[pair.offset] : "")
                }
            }
            rows.append(row)
        }

        return try finalize(rows: rows,
                            result: result,
                            targetDeckID: targetDeckID,
                            targetDeckName: targetDeckName,
                            knownWords: knownWords)
    }

    // MARK: - TXT / CSV / 粘贴（文档 8.3）

    private static func parseDelimited(text: String,
                                       targetDeckID: String,
                                       targetDeckName: String,
                                       knownWords: [String: Word]) throws -> ImportResult {
        var result = ImportResult()

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")
        result.totalLines = rawLines.count

        // 过滤空行与注释行（文档 8.3）
        var lines: [(no: Int, text: String)] = []
        for (index, line) in rawLines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                result.skippedLines += 1
                continue
            }
            lines.append((index + 1, line))
        }
        guard !lines.isEmpty else { throw ImportFailure.emptyResult }

        let delimiter = sniffDelimiter(lines.map { $0.text })

        // 表头识别：列序不可压缩，表头里没识别出来的列留空占位，避免后面的列整体前移
        var columnKeys: [String]?
        var dataLines = lines
        if let first = lines.first {
            let fields = split(first.text, by: delimiter).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            if let map = matchHeader(fields), let lastIndex = map.keys.max() {
                columnKeys = (0...lastIndex).map { map[$0] ?? "" }
                dataLines = Array(lines.dropFirst())
                result.skippedLines += 1
            }
        }

        let keys = columnKeys ?? fieldOrder

        var rows: [ImportedWord] = []
        for line in dataLines {
            let fields = splitIntoColumns(line.text, delimiter: delimiter, keys: keys)
            var row = ImportedWord(sourceLine: line.no, text: "")

            for (index, key) in keys.enumerated() where !key.isEmpty {
                guard index < fields.count else { continue }
                assign(key: key, value: fields[index], to: &row)
            }

            if row.deckName.isEmpty { row.deckName = targetDeckName }
            rows.append(row)
        }

        return try finalize(rows: rows,
                            result: result,
                            targetDeckID: targetDeckID,
                            targetDeckName: targetDeckName,
                            knownWords: knownWords)
    }

    private static func assign(key: String, value: String, to row: inout ImportedWord) {
        let value = value.trimmingCharacters(in: .whitespaces)
        switch key {
        case "word":
            row.text = value
        case "meaning":
            // 释义内的分号不分割，统一转中文分号（文档 8.4.3）
            row.meaning = value.replacingOccurrences(of: ";", with: "；")
        case "phonetic":
            row.phonetic = value
        case "pos":
            row.pos = value
        case "root":
            row.rootSpec = value
        case "mnemonic":
            row.mnemonic = value
        case "example":
            row.examples = splitExamples(value).map { Example(en: $0, cn: "") }
        case "example_cn":
            let cns = splitExamples(value)
            if row.examples.isEmpty {
                row.examples = cns.map { Example(en: "", cn: $0) }
            } else {
                for (index, cn) in cns.enumerated() {
                    if index < row.examples.count {
                        row.examples[index].cn = cn
                    }
                }
            }
        case "deck":
            row.deckName = value
        default:
            break
        }
    }

    // MARK: - 校验 / 去重 / 补全（文档 8.6）

    private static func finalize(rows: [ImportedWord],
                                 result inputResult: ImportResult,
                                 targetDeckID: String,
                                 targetDeckName: String,
                                 knownWords: [String: Word]) throws -> ImportResult {
        var result = inputResult
        var accepted: [ImportedWord] = []
        var indexByKey: [String: Int] = [:]
        var alreadyReported: Set<String> = []
        /// 因「已在目标词单」被跳过的行的词单名（用于准确提示文案）
        var skippedDeckNames: [String] = []

        for var row in rows {
            // 词条空白归一放在校验最前面：词组（good morning）内部的空白先规整，
            // 既让校验只看「词与词之间恰好一个空格」，也让去重键稳定可比。
            row.text = normalizeWordSpacing(row.text)

            // ---- ERROR：跳过该行
            guard !row.text.isEmpty else {
                reject(line: row.sourceLine, reason: "单词为空", into: &result)
                continue
            }
            if row.text.count > 32 {
                reject(line: row.sourceLine, reason: "单词超过 32 个字符", into: &result)
                continue
            }
            if isPhraseTooLong(row.text) {
                reject(line: row.sourceLine,
                       reason: "词组超过 \(maxPhraseWordCount) 个词",
                       into: &result)
                continue
            }
            if !isValidWord(row.text) {
                reject(line: row.sourceLine, reason: "单词含数字或非法字符", into: &result)
                continue
            }
            // 归一之后再取去重键：必须与上面的 row.text 改动保持一致
            let key = normalizeKey(row.text)

            // ---- WARNING：截断类
            row.meaning = truncate(row.meaning, to: 200, field: "释义", line: row.sourceLine, into: &result)
            row.phonetic = truncate(row.phonetic, to: 48, field: "音标", line: row.sourceLine, into: &result)
            row.pos = truncate(row.pos, to: 12, field: "词性", line: row.sourceLine, into: &result)
            row.mnemonic = truncate(row.mnemonic, to: 100, field: "记忆法", line: row.sourceLine, into: &result)

            var examples: [Example] = []
            for example in row.examples {
                let en = truncate(example.en, to: 160, field: "例句", line: row.sourceLine, into: &result)
                let cn = truncate(example.cn, to: 160, field: "例句译文", line: row.sourceLine, into: &result)
                if !en.isEmpty { examples.append(Example(en: en, cn: cn)) }
            }
            row.examples = examples

            // ---- WARNING：root 字段格式无法识别 → 忽略该字段，改用自动解析
            if !row.rootSpec.isEmpty && !isValidRootSpec(row.rootSpec) {
                result.issues.append(ImportIssue(level: .warning, line: row.sourceLine,
                                                 message: "词根拆解格式无法识别，已改用自动解析"))
                row.rootSpec = ""
            }

            // ---- WARNING：例句译文与例句数量不匹配（文档 8.6）
            if row.examples.count > 1 {
                let missingCN = row.examples.filter { $0.cn.isEmpty }.count
                if missingCN > 0 && missingCN < row.examples.count {
                    result.issues.append(ImportIssue(level: .warning, line: row.sourceLine,
                                                     message: "例句译文数量与例句不一致"))
                }
            }

            // ---- 文件内部去重：同词保留信息更完整的一条（文档 8.6.1）
            if let existingIndex = indexByKey[key] {
                result.mergedDuplicates += 1
                if row.richness > accepted[existingIndex].richness {
                    accepted[existingIndex] = row
                }
                result.issues.append(ImportIssue(level: .info, line: row.sourceLine,
                                                 message: "与前方重复，已合并（保留信息更完整的一条）"))
                continue
            }

            // ---- 与已有单词比对
            if let known = knownWords[key] {
                if known.deckID == targetDeckID {
                    // 已在目标词单 → 跳过导入，仅计数
                    result.existingInDeck += 1
                    if !row.deckName.isEmpty { skippedDeckNames.append(row.deckName) }
                    if alreadyReported.insert(key).inserted {
                        result.issues.append(ImportIssue(level: .info, line: row.sourceLine,
                                                         message: "\(row.text) 已在本词单中，已跳过"))
                    }
                    continue
                } else {
                    // 跨词单重复合法，仅提示
                    result.existingInOtherDecks += 1
                }
                // 释义补全链路（文档 8.6.2）
                if row.meaning.isEmpty && !known.meaning.isEmpty {
                    row.meaning = known.meaning
                    result.backfilledMeanings += 1
                }
            }

            indexByKey[key] = accepted.count
            accepted.append(row)
        }

        if accepted.isEmpty {
            // 整批单词都已在目标词单里：这不是「解析失败」，而是「无需重复导入」。
            // 用准确文案替代笼统的 emptyResult，避免用户以为文件格式有问题。
            if result.existingInDeck > 0 {
                // 被跳过的词判定依据是「已在用户选中的目标词单里」，
                // 所以文案优先用目标词单名，避免用文件里的「词单名」列误导用户。
                let name = !targetDeckName.isEmpty
                    ? targetDeckName
                    : (skippedDeckNames.first ?? "当前词单")
                throw ImportFailure.allWordsAlreadyInDeck(count: result.existingInDeck, deckName: name)
            }
            throw ImportFailure.emptyResult
        }
        if accepted.count > maxWordCount {
            throw ImportFailure.tooManyWords(accepted.count)
        }

        result.words = accepted
        return result
    }

    /// 行号只保留在 `ImportIssue.line` 里，由 UI 统一展示（预览页以「第 N 行」为标题，
    /// 整体失败提示由调用方拼行号）——避免出现「第 3 行：第 3 行：…」这种双前缀。
    private static func reject(line: Int, reason: String, into result: inout ImportResult) {
        result.issues.append(ImportIssue(level: .error, line: line,
                                         message: "\(reason)，已跳过"))
    }

    // MARK: - 生成 Word 实体（此处完成词根解析，S7 缓存）

    static func makeWords(from result: ImportResult,
                          deckID: String,
                          startPosition: Int,
                          now: Date = Date()) -> [Word] {
        var output: [Word] = []
        for (offset, item) in result.words.enumerated() {
            var segments = RootParser.parse(item.text, explicitRoot: item.rootSpec.isEmpty ? nil : item.rootSpec)
            if item.rootSpec.isEmpty && segments.count < 2 {
                segments = []
            }
            let mnemonic = item.mnemonic.isEmpty
                ? RootParser.makeMnemonic(segments: segments, meaning: item.meaning)
                : item.mnemonic

            var word = Word(text: item.text,
                            meaning: item.meaning,
                            phonetic: item.phonetic,
                            pos: item.pos,
                            segments: segments,
                            mnemonic: mnemonic,
                            examples: item.examples,
                            deckID: deckID,
                            position: startPosition + offset)
            word.srs = SRScheduler.makeNewState(now: now)
            output.append(word)
        }
        return output
    }

    // MARK: - 分词工具

    /// 分隔符嗅探（文档 8.3）：取首个能保证「每行字段数一致且 ≥2」的分隔符，优先级 @ → \t → , → | → 连续空格。
    ///
    /// **@ 为最高优先级**：只要行内出现 @（能切出 ≥2 段）就按 @ 切分。
    /// 理由：@ 在视觉上远比逗号/竖线容易分辨，且几乎不会出现在单词、释义、例句里，
    /// 用户用 @ 写表格时不必担心「单元格内逗号被当成分隔符」。
    ///
    /// 首轮全部候选都不满足时，再对逗号做一轮宽容判定：只要
    /// 「首行表头能识别，或字段数众数 ≥3」且各行字段数只比众数多出有限几个，
    /// 就仍按逗号解析——这种情况来自单元格里混进了逗号（模板的「记忆法」列即如此），
    /// 错位的列交由 `splitIntoColumns` 的列对齐摆正，而不是把整行当成一个超长单词拒收。
    static func sniffDelimiter(_ lines: [String]) -> Character? {
        // 优先级 1：@（行内出现 @ 即按 @ 切分，命中时旧分隔符判定逻辑完全不走，旧格式行为不变）
        // 仅加一道保守闸门：含 @ 的行要占到多数（单行粘贴天然满足），
        // 免得逗号/Tab 表格里某个单元格偶尔出现一个 @（如例句里的邮箱）就把整表判成 @ 分隔。
        let atLineCount = lines.filter { split($0, by: "@").count >= 2 }.count
        if atLineCount >= 1, atLineCount * 2 >= lines.count { return "@" }

        for candidate: Character in ["\t", ",", "|"] {
            let counts = lines.map { split($0, by: candidate).count }
            guard let first = counts.first, first >= 2 else { continue }
            if counts.allSatisfy({ $0 == first }) { return candidate }
        }
        // 连续两个及以上空格
        let spaceCounts = lines.map { splitByMultipleSpaces($0).count }
        if let first = spaceCounts.first, first >= 2, spaceCounts.allSatisfy({ $0 == first }) {
            return " "
        }

        // 第二轮（宽容）：只针对逗号，且要求文件确实「像表格」
        let commaCounts = lines.map { commaPieces($0).tokens.count }
        guard let minCount = commaCounts.min(), minCount >= 2,
              let maxCount = commaCounts.max(), maxCount - minCount <= 3 else { return nil }

        // 首行是能识别的表头（单词/释义/…）→ 基本可以确定就是逗号表格，
        // 哪怕只有一行数据（字段数众数达不到 2）也按逗号解析
        let headerRecognized: Bool = {
            guard let first = lines.first else { return false }
            let fields = commaPieces(first).tokens.map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            return matchHeader(fields) != nil
        }()
        if headerRecognized { return "," }

        let frequencies = Dictionary(grouping: commaCounts, by: { $0 }).mapValues { $0.count }
        guard let dominant = frequencies.max(by: { $0.value < $1.value }),
              dominant.value >= 2, dominant.value * 2 >= commaCounts.count else { return nil }
        return dominant.key >= 3 ? "," : nil
    }

    /// 按分隔符切分一行。
    /// · 逗号分隔符同时认半角「,」与全角「，」（文档 8.3 第 2 条）；
    /// · 行内「，」到底是分隔符还是单元格内容，留到 `splitIntoColumns` 按列数对齐时判定。
    static func split(_ line: String, by delimiter: Character?) -> [String] {
        guard let delimiter = delimiter else {
            return [line.trimmingCharacters(in: .whitespaces)]
        }
        if delimiter == " " {
            return splitByMultipleSpaces(line).map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if delimiter == "," {
            return commaPieces(line).tokens.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return line
            .components(separatedBy: String(delimiter))
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - 列对齐（单元格内出现逗号时）

    /// 把一行按逗号切开，并保留每个片段后面的原始逗号，便于重合并时原样拼回。
    ///
    /// `includeFullWidth` 为 false 时只认半角「,」，全角「，」留在单元格内容里不切
    /// （中文例句/记忆法里的「，」不该把它后面的列整体前移）。
    private static func commaPieces(_ line: String,
                                    includeFullWidth: Bool = true) -> (tokens: [String], separators: [Character]) {
        pieces(line, by: ",", alsoFullWidthComma: includeFullWidth)
    }

    /// 按单个字符切分一行，并保留每个片段后面的原始分隔符（用于把单元格内的分隔符并回原列）。
    private static func pieces(_ line: String,
                               by delimiter: Character,
                               alsoFullWidthComma: Bool = false) -> (tokens: [String], separators: [Character]) {
        var tokens: [String] = []
        var separators: [Character] = []
        var current = ""
        for character in line {
            if character == delimiter || (alsoFullWidthComma && character == "，") {
                tokens.append(current)
                separators.append(character)
                current = ""
            } else {
                current.append(character)
            }
        }
        tokens.append(current)
        return (tokens, separators)
    }

    /// 把一行落到各列上，返回与 `keys` 等长的字段数组（缺列补空串）。
    ///
    /// 逗号行同时生成两种候选切法，再由列语义总分择优：
    /// ① 只认半角「,」——全角「，」视为单元格内容（中文例句/记忆法里的「，」不该切列）；
    /// ② 半角 + 全角都当分隔符——兼容「predict，预测，/prɪˈdɪkt/，v.」这类纯中文逗号表格。
    /// 两者都先对齐到列（片段数 ≤ 列数按位置补空，片段数更多走 `bestAlignment` 合并）。
    ///
    /// 其他单字符分隔符（@ / \t / | 等）在片段数多于列数时，同样走列语义对齐：
    /// 例如「多例句」列内部写了 @，多出来的片段会被并回该列，而不是把后面的列整体顶掉。
    private static func splitIntoColumns(_ line: String,
                                        delimiter: Character?,
                                        keys: [String]) -> [String] {
        guard !keys.isEmpty else { return [] }

        if delimiter != "," {
            let tokens = split(line, by: delimiter)
            if let delimiter = delimiter, delimiter != " " {
                // 尾部空片段（如行尾多打了一个分隔符）先丢掉，避免把「空列」也送去合并
                var trimmed = tokens
                while let last = trimmed.last, last.isEmpty { trimmed.removeLast() }
                if trimmed.count > keys.count {
                    let raw = pieces(line, by: delimiter)
                    if let aligned = bestAlignment(tokens: raw.tokens, separators: raw.separators, keys: keys) {
                        return aligned.values
                    }
                }
            }
            var values = (0..<keys.count).map { $0 < tokens.count ? tokens[$0] : "" }
            if let delimiter = delimiter, delimiter != " " {
                repairSplitRootColumn(&values, delimiter: delimiter, keys: keys)
            }
            return values
        }

        let strict = commaPieces(line, includeFullWidth: false)
        let loose = commaPieces(line, includeFullWidth: true)
        let strictCandidate = columnCandidate(tokens: strict.tokens, separators: strict.separators, keys: keys)
        let looseCandidate = columnCandidate(tokens: loose.tokens, separators: loose.separators, keys: keys)
        let candidates = [strictCandidate, looseCandidate].compactMap { $0 }
        guard !candidates.isEmpty else {
            let fallback = strict.tokens
            return (0..<keys.count).map { $0 < fallback.count ? fallback[$0] : "" }
        }

        // 半角逗号正好切满每一列：说明「，」只可能是单元格内容，直接采用该切法
        // （否则列语义评分可能为了凑分把例句里的「，」拆成列，反而错位）。
        if let strictCandidate = strictCandidate,
           strictCandidate.hasValidWord,
           strict.tokens.count == keys.count {
            return strictCandidate.values
        }

        // 能切出合法单词列的候选优先（纯中文逗号行只有候选 ② 合法）；都成立时取语义总分更高者。
        // 平分时 `max` 保留靠前的候选，即优先「中文逗号归单元格内容」的切法。
        let valid = candidates.filter { $0.hasValidWord }
        let pool = valid.isEmpty ? candidates : valid
        return pool.max { $0.score < $1.score }?.values ?? []
    }

    /// 窄修：非逗号分隔符的行里，「词根拆解」列的连接符与分隔符同形时会把自己切断。
    ///
    /// 例如竖线行 `predict|预测|/prɪˈdɪkt/|v.|pre-|dict`：按位置对号入座后，
    /// 词根列只剩 `pre-`（非法，最终被丢弃并报一条警告），`dict` 还会被顶到「记忆法」列。
    /// 这里仅在该列「非空但非法」、且与紧邻下一列合并后「合法」时，把两列并回词根列，
    /// 避免用户写了正确词根却丢词根、还被塞进错误列。
    private static func repairSplitRootColumn(_ values: inout [String],
                                              delimiter: Character,
                                              keys: [String]) {
        guard let rootIndex = keys.firstIndex(of: "root"),
              rootIndex + 1 < keys.count, rootIndex + 1 < values.count else { return }

        let root = values[rootIndex].trimmingCharacters(in: .whitespaces)
        let next = values[rootIndex + 1].trimmingCharacters(in: .whitespaces)
        guard !root.isEmpty, !next.isEmpty else { return }
        guard !isValidRootSpec(root) else { return }
        // 下一列是中文内容时不动（那多半是记忆法/释义，不是被切断的词根片段）
        guard !hasCJK(next) else { return }

        let merged = root + String(delimiter) + next
        guard isValidRootSpec(merged) else { return }

        values[rootIndex] = merged
        values[rootIndex + 1] = ""
    }

    /// 一种候选切法对齐后的结果：字段数组 + 列语义总分 + 单词列是否合法
    private struct ColumnCandidate {
        var values: [String]
        var score: Int
        var hasValidWord: Bool
    }

    /// 把一组片段对齐到 `keys` 各列，并给出用于择优的列语义总分。
    /// 片段数 ≤ 列数按位置一一对应；更多则交给 `bestAlignment` 合并。
    private static func columnCandidate(tokens: [String],
                                        separators: [Character],
                                        keys: [String]) -> ColumnCandidate? {
        guard !keys.isEmpty, !tokens.isEmpty else { return nil }

        var values: [String]
        var score = 0
        if tokens.count <= keys.count {
            values = (0..<keys.count).map { $0 < tokens.count ? tokens[$0] : "" }
            for index in 0..<tokens.count {
                score += columnFitScore(key: keys[index], value: values[index]) * 100
                    + (keys.count - index)
            }
        } else {
            guard let aligned = bestAlignment(tokens: tokens, separators: separators, keys: keys) else { return nil }
            values = aligned.values
            score = aligned.score
        }

        let wordIndex = keys.firstIndex(of: "word") ?? 0
        let word = values[wordIndex].trimmingCharacters(in: .whitespaces)
        return ColumnCandidate(values: values, score: score, hasValidWord: isValidWord(word))
    }

    /// 动态规划对齐：把 m 个片段切成 n 段（n = 列数），使各段与所在列的语义最匹配。
    /// 主目标是 `columnFitScore` 之和（乘 100 保持主导），平手时优先让靠前的列只占一个片段。
    /// 返回值同时给出该切法的总分，供多候选（半角逗号 / 半角+全角逗号）之间比较。
    private static func bestAlignment(tokens: [String],
                                      separators: [Character],
                                      keys: [String]) -> (values: [String], score: Int)? {
        let n = keys.count
        let m = tokens.count
        guard n > 0, m > n else { return nil }

        let unreachable = Int.min / 4
        var dp = [[Int]](repeating: [Int](repeating: unreachable, count: m + 1), count: n + 1)
        var origin = [[Int]](repeating: [Int](repeating: -1, count: m + 1), count: n + 1)
        dp[0][0] = 0

        for column in 0..<n {
            for start in 0...m where dp[column][start] > unreachable {
                let lowest = start + 1
                let highest = m - (n - column - 1)
                guard lowest <= highest else { continue }
                for end in lowest...highest {
                    let value = join(tokens: tokens, separators: separators, from: start, to: end)
                    var score = dp[column][start] + columnFitScore(key: keys[column], value: value) * 100
                    if end - start == 1 { score += n - column }
                    if score > dp[column + 1][end] {
                        dp[column + 1][end] = score
                        origin[column + 1][end] = start
                    }
                }
            }
        }

        guard dp[n][m] > unreachable else { return nil }

        var values = [String](repeating: "", count: n)
        var end = m
        for column in stride(from: n, through: 1, by: -1) {
            let start = origin[column][end]
            guard start >= 0 else { return nil }
            values[column - 1] = join(tokens: tokens, separators: separators, from: start, to: end)
            end = start
        }
        return (values, dp[n][m])
    }

    /// 重合并相邻片段：用原文里的分隔符原样拼回（「，」保持「，」）
    private static func join(tokens: [String],
                             separators: [Character],
                             from start: Int,
                             to end: Int) -> String {
        guard end - start > 1 else { return start < tokens.count ? tokens[start] : "" }
        var text = tokens[start]
        for index in start..<(end - 1) {
            text.append(index < separators.count ? separators[index] : ",")
            text.append(tokens[index + 1])
        }
        return text
    }

    /// 列语义评分：仅用于「字段数多于列数」时的切法择优，分值只做相对排序，不参与校验。
    private static func columnFitScore(key: String, value: String) -> Int {
        let text = value.trimmingCharacters(in: .whitespaces)
        switch key {
        case "word":
            if text.isEmpty { return -10 }
            if hasCJK(text) { return -8 }
            // 词组（good morning）也是合法词条：给正分，别让列对齐把它当成「填错的列」推开
            if isValidWord(text) { return text.contains(" ") ? 2 : 3 }
            return -4
        case "phonetic":
            if text.hasPrefix("/") || text.hasPrefix("[") { return 3 }
            if hasCJK(text) { return -3 }
            if text.contains(" ") { return -3 }
            return -1
        case "pos":
            let bare = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
            if knownPOS.contains(bare) { return 3 }
            if hasCJK(text) || text.count > 10 { return -3 }
            return -1
        case "root":
            if isValidRootSpec(text) { return 4 }
            if hasCJK(text) { return -4 }
            return -2
        case "example":
            if hasCJK(text) { return -3 }
            return text.contains(" ") ? 2 : 0
        case "example_cn":
            if hasCJK(text) { return 1 }
            return text.contains(" ") ? -1 : 0
        default:
            return 0
        }
    }

    private static let knownPOS: Set<String> = [
        "n", "v", "vt", "vi", "adj", "adv", "prep", "conj", "pron",
        "num", "art", "int", "aux", "abbr", "phr", "det"
    ]

    /// 是否含中日韩文字或全角/中文标点（用于列语义评分）
    private static func hasCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3000...0x303F).contains(scalar.value)     // 中文标点
                || (0x3400...0x4DBF).contains(scalar.value)  // 扩展 A
                || (0x4E00...0x9FFF).contains(scalar.value)  // 基本区
                || (0xF900...0xFAFF).contains(scalar.value)  // 兼容表意
                || (0xFF00...0xFFEF).contains(scalar.value)  // 全角
        }
    }

    static func splitByMultipleSpaces(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var spaceRun = 0
        for character in line {
            if character == " " {
                spaceRun += 1
                continue
            }
            if spaceRun >= 2 {
                if !current.isEmpty { parts.append(current); current = "" }
            } else if spaceRun == 1 {
                if !current.isEmpty { current.append(" ") }
            }
            spaceRun = 0
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 表头识别：命中别名即算，但**必须命中「单词」列**才算表头。
    ///
    /// 只要求「任意一列命中别名」会误伤首行数据：像 `translate@翻译`、`unit@单元`
    /// 这类数据的释义列恰好等于别名（翻译 / 单元 / 中文 / 意思 …），整行会被当表头吃掉，
    /// 用户看到的是「明明有内容却少了一个词」。
    /// 而真正的表头不可能没有单词列——没有单词列的表头本来也导不出任何词。
    static func matchHeader(_ fields: [String]) -> [Int: String]? {
        var map: [Int: String] = [:]
        for (index, field) in fields.enumerated() {
            let key = field.replacingOccurrences(of: " ", with: "")
            if let standard = headerAliases[key] {
                map[index] = standard
            }
        }
        guard map.values.contains("word") else { return nil }
        return map
    }

    static func splitExamples(_ raw: String) -> [String] {
        raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isValidWord(_ text: String) -> Bool {
        let normalized = normalizeWordSpacing(text)
        guard !normalized.isEmpty else { return false }
        let tokens = normalized.split(separator: " ").map(String.init)
        guard tokens.count <= maxPhraseWordCount else { return false }
        return tokens.allSatisfy { isPlainToken($0) }
    }

    /// 词组型词条最多允许的词数（good morning = 2 / as soon as possible = 4）
    static let maxPhraseWordCount = 4

    /// 词条是否为空或超出词组词数上限（用于把错误文案说清楚：
    /// 「词组超过 4 个词」≠「单词含数字或非法字符」）
    static func isPhraseTooLong(_ text: String) -> Bool {
        normalizeWordSpacing(text).split(separator: " ").count > maxPhraseWordCount
    }

    /// 单个「词」的字符集：字母（含重音字母，如 café）、连字符、撇号。
    /// 中日韩文字与全角字符不属于英文词条，直接判非法——否则「早上好」会被当成一个合法单词收进库里。
    private static func isPlainToken(_ token: String) -> Bool {
        guard !token.isEmpty, !hasCJK(token) else { return false }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'"))
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 词组内部空白归一：去首尾空白，并把连续空白（空格 / 全角空格 / Tab）压成一个半角空格。
    /// 「Good  Morning 」→「Good Morning」，这样它才能和「good morning」判为同一个词。
    static func normalizeWordSpacing(_ text: String) -> String {
        var unified = text
        unified = unified.replacingOccurrences(of: "\u{3000}", with: " ")   // 全角空格
        unified = unified.replacingOccurrences(of: "\t", with: " ")
        return unified
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 词根字段是否可识别：支持 `un-+happy`（加号）与 `pre-|dict`（竖线）两种写法，
    /// 只要能拆出 ≥2 个片段即算合法（模板的「词根拆解」列用的是竖线写法）
    static func isValidRootSpec(_ spec: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        return RootParser.parseExplicit(trimmed).count >= 2
    }

    /// 去重键：空白归一 + 转小写。
    /// 词组必须归一空白，否则「Good  Morning」与「good morning」会成为两个不同的键，
    /// 同一份文件里重复出现的词组合并不掉、库里已有的词组会被重复导入。
    static func normalizeKey(_ text: String) -> String {
        normalizeWordSpacing(text).lowercased()
    }

    private static func truncate(_ value: String,
                                 to limit: Int,
                                 field: String,
                                 line: Int,
                                 into result: inout ImportResult) -> String {
        guard value.count > limit else { return value }
        result.issues.append(ImportIssue(level: .warning, line: line,
                                         message: "\(field)已截断至 \(limit) 字"))
        return String(value.prefix(limit))
    }

    // MARK: - 内嵌示例（粘贴框占位与"查看格式规范"）

    static let sampleText = """
    # 一行一个单词，也可以按 单词@释义@音标 依次写
    unhappy@不快乐的@/ʌnˈhæpi/
    impossible@不可能的@/ɪmˈpɒsəbl/
    teacher@老师@/ˈtiːtʃə(r)/
    """

    static let sampleCSV = """
    word@meaning@phonetic@pos@root@mnemonic@example@example_cn@deck
    unhappy@不快乐的@/ʌnˈhæpi/@adj.@un-|happy@un（不）+ happy（快乐）@She looks unhappy today.@她今天看起来不开心。@七年级上 Unit 3
    impossible@不可能的@/ɪmˈpɒsəbl/@adj.@im-|poss|-ible@im（不）+ poss（能够）+-ible（可…的）@Nothing is impossible.@没有什么是不可能的。@七年级上 Unit 3
    """
}


// MARK: - DEBUG 自检（模拟器 / 真机运行时验证导入解析关键场景）

#if DEBUG
/// 在真实 App 进程里跑一遍导入解析的关键场景，用于运行时验证：
/// ① @ 分隔符 ② 整批单词已在目标词单时的准确提示 ③ 旧格式兼容 ④ 词根 | 与 + 等价 ⑤ 单行 @ 嗅探
enum ImportSelfCheck {

    @MainActor
    static func run() {
        let state = AppState.shared
        guard let deck = state.currentDeck else {
            print("[ImportSelfCheck] 无词单，跳过")
            return
        }
        let deckID = deck.id
        let deckName = deck.name
        let existing = state.existingWordsByKey()
        let deckWordList = state.words(in: deckID)
        let deckWords = deckWordList.prefix(3).map { $0.text }

        print("[ImportSelfCheck] 词单「\(deckName)」共 \(deckWordList.count) 词，全库索引 \(existing.count) 词")

        var failures: [String] = []

        func note(_ name: String, _ ok: Bool, _ detail: String) {
            print("[ImportSelfCheck] \(ok ? "PASS" : "FAIL") \(name)：\(detail)")
            if !ok { failures.append(name) }
        }

        // 场景 1：@ 分隔的新词（最高优先级分隔符）
        let atTemplate = """
        单词@释义@音标@词性@词根拆解@记忆法@例句@例句翻译@词单名
        predict@预测；预言@/prɪˈdɪkt/@v.@pre-|dict@提前说出来就是预测@I can predict the result.@我能预测结果。@\(deckName)
        describe@描述@/dɪˈskraɪb/@v.@de-|scrib@写下来就是描述@Please describe your school.@请描述你的学校。@\(deckName)
        import@进口；导入@/ɪmˈpɔːrt/@v.@im-|port@搬进来就是进口@We import books from abroad.@我们从国外进口书籍。@\(deckName)
        """
        do {
            let r = try Importer.parse(text: atTemplate, fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName,
                                       knownWords: existing)
            let roots = r.words.map { "\($0.text):\($0.rootSpec)" }.joined(separator: " ")
            note("@ 分隔符模板", r.words.count == 3 && r.errorIssues.isEmpty,
                 "\(r.words.count) 词 / 错误 \(r.errorIssues.count) 条 / \(roots)")
        } catch {
            note("@ 分隔符模板", false, "抛错：\(describe(error))")
        }

        // 场景 2：目标词单里已存在全部单词 → 必须给「已在词单中」的准确提示
        if deckWords.count >= 3 {
            let dup = "单词@释义\n" + deckWords.map { "\($0)@释义" }.joined(separator: "\n")
            do {
                _ = try Importer.parse(text: dup, fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName,
                                       knownWords: existing)
                note("整批已存在于目标词单", false, "未报错，应给出「已在词单中」提示")
            } catch {
                let desc = describe(error)
                let accurate = desc.contains("已在「\(deckName)」词单中") && !desc.contains("没有解析到任何单词")
                note("整批已存在于目标词单", accurate, desc)
            }
        } else {
            note("整批已存在于目标词单", false, "当前词单不足 3 词，无法构造场景")
        }

        // 场景 3：旧格式兼容（英文逗号 / 中文逗号 / 竖线 / 制表符）
        let legacy: [(String, String)] = [
            ("英文逗号", "predict,预测；预言,/prɪˈdɪkt/,v.,pre-|dict"),
            ("中文逗号", "predict，预测；预言，/prɪˈdɪkt/，v.，pre-|dict"),
            ("竖线", "predict|预测；预言|/prɪˈdɪkt/|v.|pre-|dict"),
            ("制表符", "predict\t预测；预言\t/prɪˈdɪkt/\tv.\tpre-|dict")
        ]
        for (name, line) in legacy {
            do {
                let r = try Importer.parse(text: line, fileName: nil,
                                           targetDeckID: deckID, targetDeckName: deckName,
                                           knownWords: [:])
                let rootOK = r.words.first?.rootSpec.contains("pre") ?? false
                note("旧格式兼容-\(name)", r.words.count == 1 && rootOK,
                     "\(r.words.count) 词 root=\(r.words.first?.rootSpec ?? "-")")
            } catch {
                note("旧格式兼容-\(name)", false, "抛错：\(describe(error))")
            }
        }

        // 场景 4：词根 | 与 + 等价
        do {
            let a = try Importer.parse(text: "predict@预测@/prɪˈdɪkt/@v.@pre-|dict", fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            let b = try Importer.parse(text: "predict@预测@/prɪˈdɪkt/@v.@pre-+dict", fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            let sa = RootParser.parseExplicit(a.words.first?.rootSpec ?? "").map { $0.text }
            let sb = RootParser.parseExplicit(b.words.first?.rootSpec ?? "").map { $0.text }
            note("词根 | 与 + 等价", sa == sb && !sa.isEmpty, "|→\(sa)  +→\(sb)")
        } catch {
            note("词根 | 与 + 等价", false, "抛错：\(describe(error))")
        }

        // 场景 5：单行只含一个 @ 也要按 @ 切分（嗅探兜底）
        do {
            let r = try Importer.parse(text: "abandon@放弃", fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            note("单行 @ 嗅探", r.words.count == 1 && r.words.first?.meaning == "放弃",
                 "\(r.words.count) 词 meaning=\(r.words.first?.meaning ?? "-")")
        } catch {
            note("单行 @ 嗅探", false, "抛错：\(describe(error))")
        }

        // 场景 6：词组型词条（单词列含空格）必须能导入，且空白归一 / 去重正确
        do {
            let phraseText = """
            good morning@早上好@/ɡʊd ˈmɔːnɪŋ/@n.
            ice cream@冰淇淋
            as soon as possible@尽快
            """
            let r = try Importer.parse(text: phraseText, fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            let hasMeaning = r.words.first(where: { $0.text == "good morning" })?.meaning == "早上好"
            note("词组型词条导入", r.words.count == 3 && hasMeaning,
                 "\(r.words.count) 词 / \(r.words.map { $0.text })")

            // 同一份文件里大小写与多余空格不同 → 必须合并成一条
            let messy = """
            good morning@早上好
            Good  Morning@早上好
            """
            let r2 = try Importer.parse(text: messy, fileName: nil,
                                        targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            note("词组空白/大小写归一去重",
                 r2.words.count == 1 && r2.words.first?.text == "good morning" && r2.mergedDuplicates == 1,
                 "\(r2.words.count) 词 / 合并 \(r2.mergedDuplicates) / text=\(r2.words.first?.text ?? "-")")

            // 已在库里的词组（相同 key）→ 跨词单仅提示，不重复导入到当前词单之外的判定依赖 key 稳定
            let known = ["good morning": Word(text: "good morning", meaning: "早上好")]
            let r3 = try Importer.parse(text: "good morning", fileName: nil,
                                        targetDeckID: deckID, targetDeckName: deckName, knownWords: known)
            note("词组跨词单去重命中", r3.words.count == 1 && r3.existingInOtherDecks == 1
                 && r3.words.first?.meaning == "早上好",
                 "\(r3.words.count) 词 / 跨词单 \(r3.existingInOtherDecks) / 释义补全 \(r3.backfilledMeanings)")
        } catch {
            note("词组型词条导入", false, "抛错：\(describe(error))")
        }

        // 场景 7：词条非法字符必须拦下（中文释义误填进单词列 / 超长词组 / 含数字）
        do {
            let bad = """
            早上好@早上好
            good morning noon night evening@一整天
            abc123@含数字
            """
            let r = try Importer.parse(text: bad, fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            note("非法词条拦截", false, "不应通过校验，实际 \(r.words.count) 词")
        } catch {
            note("非法词条拦截", true, describe(error).replacingOccurrences(of: "\n", with: " "))
        }

        // 场景 8：表头识别回归 —— 首行数据的释义恰好等于表头别名时不能被当表头吃掉
        do {
            let headerFalsePositive = """
            translate@翻译
            unit@单元
            """
            let r = try Importer.parse(text: headerFalsePositive, fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            note("表头误判回归（首行数据 alias）", r.words.count == 2 && r.words.first?.meaning == "翻译",
                 "\(r.words.count) 词 / \(r.words.map { "\($0.text)=\($0.meaning)" })")

            let withHeader = """
            单词@释义
            happy@快乐
            """
            let r2 = try Importer.parse(text: withHeader, fileName: nil,
                                        targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            note("表头仍正常识别", r2.words.count == 1 && r2.skippedLines == 1,
                 "\(r2.words.count) 词 / 跳过 \(r2.skippedLines) 行")
        } catch {
            note("表头误判回归（首行数据 alias）", false, "抛错：\(describe(error))")
        }

        // 场景 9：分隔符与词根连接符同形（竖线）时，词根不能被切断丢弃 / 顶进记忆法列
        do {
            let r = try Importer.parse(text: "predict|预测；预言|/prɪˈdɪkt/|v.|pre-|dict", fileName: nil,
                                       targetDeckID: deckID, targetDeckName: deckName, knownWords: [:])
            let w = r.words.first
            note("竖线行词根并回",
                 w?.rootSpec == "pre-|dict" && (w?.mnemonic.isEmpty ?? false) && r.warningIssues.isEmpty,
                 "root=\(w?.rootSpec ?? "-") mnemonic=\(w?.mnemonic ?? "-") 警告 \(r.warningIssues.count) 条")
        } catch {
            note("竖线行词根并回", false, "抛错：\(describe(error))")
        }

        if failures.isEmpty {
            print("[ImportSelfCheck] 全部通过（9 组场景）")
        } else {
            print("[ImportSelfCheck] 失败 \(failures.count) 项：\(failures.joined(separator: "、"))")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return "\(error)" }
        let description = localized.errorDescription ?? "\(error)"
        if let suggestion = localized.recoverySuggestion, !suggestion.isEmpty {
            return "\(description) / \(suggestion)"
        }
        return description
    }
}
#endif
