//
//  OCRService.swift
//  RootWord · 词根单词
//
//  Vision 框架拍照/相册 OCR：识别单词书页 → 视觉行聚类 → 双栏排序 →
//  解析为「单词 + 释义」词条，并用 ECDICT 三层校验标记可疑/生僻词。
//
//  技术要点（iOS 15.4 / Vision / UIKit）：
//    · 双 Pass OCR（zh-Hans 优先保中文释义、en-US 优先提英文单词），按编号/坐标合并
//    · 拼写纠正只用 UITextChecker 单候选（guesses 首位，Apple 按常见度排序）；
//      不采用 topCandidates 多候选交叉验证取合法词的词典判定法（已被验证反引入错误）
//    · 词库校验：ECDictValidator 存在性 / 常用度 / 释义一致性三层，可疑词标 ⚠、生僻词标 ?
//

import Vision
import UIKit
import CoreImage

// MARK: - OCR 词条

struct WordEntry: Codable, Identifiable {

    var id = UUID()
    var word: String
    var def: String = ""
    /// 词库三层校验标记（⚠ 可疑 / ? 生僻 / 候选提示）
    var validation: String = ""
}

// MARK: - OCR Service

enum OCRService {

    // MARK: - Public API

    /// OCR 识别 → 行聚类 → 解析词条 → ECDICT 三层校验标记
    /// 全程在后台队列执行，完成后回主线程回调。
    static func recognize(_ image: UIImage, completion: @escaping (Result<[WordEntry], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // 词库 36MB 首次加载较慢，必须在后台线程（懒加载 + 缓存，之后不再耗时）
            let dict = ECDictValidator.loadDict()
            do {
                guard let cg = image.cgImage else {
                    throw NSError(domain: "ocr", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "无法读取图像数据"])
                }
                let zhRows = try performPass(cg, langs: ["zh-Hans", "en-US"], correction: true)
                let enRows = try performPass(cg, langs: ["en-US", "zh-Hans"], correction: true)
                let lines = mergeDualPass(zhRows: zhRows, enRows: enRows, cg: cg)
                var parsed = parseEntries(from: lines)
                for i in parsed.indices {
                    parsed[i].validation = ECDictValidator
                        .validateResult(word: parsed[i].word, def: parsed[i].def, dict: dict)
                        .hint
                }
                DispatchQueue.main.async { completion(.success(parsed)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - OCR core

    /// 视觉行聚类：同栏内垂直重叠 >50% 的观测并为同一行，行内按 x 拼接
    private static func groupRows(_ items: [(text: String, box: CGRect)]) -> [String] {
        guard !items.isEmpty else { return [] }
        let left = items.filter { $0.box.midX < 0.5 }
        let right = items.filter { $0.box.midX >= 0.5 }
        let two = left.count >= items.count / 3 && right.count >= items.count / 3

        func cluster(_ src: [(text: String, box: CGRect)]) -> [String] {
            let sorted = src.sorted { $0.box.midY > $1.box.midY }
            var rows: [[(text: String, box: CGRect)]] = []
            for it in sorted {
                if var last = rows.last, let ref = last.first {
                    let overlap = min(ref.box.midY + ref.box.height / 2, it.box.midY + it.box.height / 2)
                                - max(ref.box.midY - ref.box.height / 2, it.box.midY - it.box.height / 2)
                    let minH = min(ref.box.height, it.box.height)
                    if overlap > minH * 0.5 {
                        last.append(it)
                        rows[rows.count - 1] = last
                        continue
                    }
                }
                rows.append([it])
            }
            return rows.map {
                $0.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: " ")
            }
        }

        return two ? cluster(left) + cluster(right) : cluster(items)
    }

    // MARK: - Parsing

    private static let numRegex = try! NSRegularExpression(pattern: "^(\\d{1,3})\\s*[.、．:：，,]?\\s+(.+)$")
    private static let posRegex = try! NSRegularExpression(
        pattern: "(v\\.&\\s*n\\.|v\\.|n\\.|adj\\.|adv\\.|vi\\.|vt\\.|prep\\.|conj\\.|pron\\.|&\\s*n\\.)")
    private static let posTokens: Set<String> = ["v", "n", "adj", "adv", "vi", "vt", "prep", "conj", "pron"]
    private static let leadNumRegex = try! NSRegularExpression(pattern: "^\\d{1,3}\\s*[.、．，,]?\\s*")
    private static let embeddedNumRegex = try! NSRegularExpression(pattern: "\\s\\d{1,3}\\s*[.，,、．]\\s*[A-Za-z]")

    static func parseEntries(from lines: [String]) -> [WordEntry] {
        var result: [WordEntry] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.range(of: "^Part\\s*\\d*$", options: .regularExpression) != nil { continue }
            var rest: String?
            if let m = numRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               m.numberOfRanges >= 3, let r = Range(m.range(at: 2), in: line) {
                rest = String(line[r])
            }
            for e in makeEntries(rest ?? line) { result.append(e) }
        }
        // 同词去重，保留信息更全的一条
        var best: [String: WordEntry] = [:]
        for e in result {
            let k = e.word.lowercased()
            if let old = best[k] {
                if e.word.count + e.def.count > old.word.count + old.def.count { best[k] = e }
            } else { best[k] = e }
        }
        return best.values.sorted { $0.word < $1.word }
    }

    private static func makeEntries(_ text0: String) -> [WordEntry] {
        guard !looksLikeJunk(text0) else { return [] }
        let text = leadNumRegex.stringByReplacingMatches(
            in: text0, range: NSRange(text0.startIndex..., in: text0), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }

        var word = "", def = ""
        if let m = posRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range, in: text) {
            word = String(text[text.startIndex..<r.lowerBound])
            def = String(text[r.lowerBound...])
        } else {
            let re = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z .'\\-&…]*")
            if let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range, in: text) {
                word = String(text[text.startIndex..<r.upperBound])
                def = String(text[r.upperBound...])
            } else { return [] }
        }
        guard let w = cleanWord(word) else { return [] }
        let d = cleanDef(def)
        // def 内嵌后续编号词条（行聚类误并）：切开分别成条
        if d.range(of: "\\s\\d{1,3}\\s*[.，,、．]\\s*[A-Za-z]", options: .regularExpression) != nil {
            let parts = splitEmbedded(d)
            if parts.count > 1 { return parts.flatMap { makeEntries($0) } }
        }
        var e = WordEntry(word: w)
        e.def = d
        return [e]
    }

    private static func cleanWord(_ w0: String) -> String? {
        var w = w0
        // 编号被误读成单个字母："L. create" → "create"
        w = w.replacingOccurrences(of: "^[A-Za-z]\\s*[.、．]\\s+", with: "", options: .regularExpression)
        w = w.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "…….…-"))
        // 尾部词性残留："normally adv" → "normally"
        w = w.replacingOccurrences(of: "\\s+(v|n|adj|adv|vi|vt|prep|conj|pron)$",
                                   with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let letters = w.filter { $0.isLetter }
        guard letters.count >= 3 else { return nil }
        guard !posTokens.contains(w.lowercased()) else { return nil }
        guard w.range(of: "^[A-Za-z][A-Za-z .'\\-&…]+$", options: .regularExpression) != nil else { return nil }
        // 首字母误大写："Clerk" → "clerk"
        if let f = w.first, f.isUppercase, w.dropFirst().allSatisfy({ !$0.isUppercase }) {
            w = w.lowercased()
        }
        // 单个英文 token 拼写自动纠正："alford"→"afford"、"dresent"→"present"
        // 词组不纠正（避免 "be bom with" 被误纠为 "be mom with"），留给审阅页
        if !w.contains(" ") {
            w = spellCorrect(w) ?? w
        }
        return w
    }

    private static let textChecker = UITextChecker()

    /// 单候选拼写纠正：UITextChecker 判定拼写错误时，取 guesses 首位
    /// （Apple 按常见度排序）。不做多候选交叉验证取合法词。
    private static func spellCorrect(_ word: String) -> String? {
        let ns = word as NSString
        let range = NSRange(location: 0, length: ns.length)
        let misspelled = textChecker.rangeOfMisspelledWord(
            in: word, range: range, startingAt: 0, wrap: false, language: "en")
        guard misspelled.location != NSNotFound, misspelled.length > 0 else { return nil }
        guard let guesses = textChecker.guesses(forWordRange: misspelled, in: word, language: "en"),
              let first = guesses.first, !first.isEmpty else { return nil }
        return first.lowercased()
    }

    private static func cleanDef(_ d0: String) -> String {
        d0.trimmingCharacters(in: .whitespaces)
          .replacingOccurrences(of: "^\\d{1,2}\\s*[.、，,]\\s*", with: "", options: .regularExpression)
    }

    private static func splitEmbedded(_ s: String) -> [String] {
        let ns = s as NSString
        var cuts: [Int] = [0]
        embeddedNumRegex.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, m.range.location > 0 { cuts.append(m.range.location + 1) }
        }
        guard cuts.count > 1 else { return [s] }
        var parts: [String] = []
        for (i, c) in cuts.enumerated() {
            let end = i + 1 < cuts.count ? cuts[i + 1] - 1 : ns.length
            let p = ns.substring(with: NSRange(location: c, length: end - c))
                .trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { parts.append(p) }
        }
        return parts
    }

    /// 乱码判定：字母少、数字多、大小写混乱
    private static func looksLikeJunk(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        let digits = s.filter { $0.isNumber }
        if letters.count < 3 { return true }
        if digits.count > letters.count / 2 { return true }
        let lowers = s.filter { $0.isLowercase }.count
        if lowers < letters.count / 3 { return true }
        if containsCJK(s) { return false }
        let weird = s.filter { $0.isUppercase && $0.isLetter }.count
        return weird > letters.count / 2
    }

    private static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    // MARK: - Dual Pass OCR

    private static let leadMixedNumRegex = try! NSRegularExpression(
        pattern: "([A-Za-z]?)(\\d{1,3})\\s*[.、．:：，,]?\\s*")

    private static func performPass(_ cg: CGImage, langs: [String], correction: Bool)
        throws -> [(text: String, box: CGRect, midY: CGFloat, conf: Float)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = langs
        request.usesLanguageCorrection = correction
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])
        let obs = request.results ?? []
        let items = obs.compactMap { o -> (text: String, box: CGRect, midY: CGFloat, conf: Float)? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (trimmed, o.boundingBox, o.boundingBox.midY, o.confidence)
        }
        return groupRowsDetailed(items)
    }

    private static func groupRowsDetailed(_ items: [(text: String, box: CGRect, midY: CGFloat, conf: Float)])
        -> [(text: String, box: CGRect, midY: CGFloat, conf: Float)] {
        guard !items.isEmpty else { return [] }
        let left = items.filter { $0.box.midX < 0.5 }
        let right = items.filter { $0.box.midX >= 0.5 }
        let two = left.count >= items.count / 3 && right.count >= items.count / 3

        func cluster(_ src: [(text: String, box: CGRect, midY: CGFloat, conf: Float)]) -> [(text: String, box: CGRect, midY: CGFloat, conf: Float)] {
            let sorted = src.sorted { $0.midY > $1.midY }
            var rows: [[(text: String, box: CGRect, midY: CGFloat, conf: Float)]] = []
            for it in sorted {
                if var last = rows.last, let ref = last.first {
                    let overlap = min(ref.box.midY + ref.box.height / 2, it.box.midY + it.box.height / 2)
                                - max(ref.box.midY - ref.box.height / 2, it.box.midY - it.box.height / 2)
                    let minH = min(ref.box.height, it.box.height)
                    if overlap > minH * 0.5 {
                        last.append(it)
                        rows[rows.count - 1] = last
                        continue
                    }
                }
                rows.append([it])
            }
            return rows.map { r in
                let text = r.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: " ")
                let box = r.map { $0.box }.reduce(CGRect.null) { $0.union($1) }
                let my = r.map { $0.midY }.reduce(0, +) / CGFloat(r.count)
                let cf = r.map { $0.conf }.min() ?? 0
                return (text, box, my, cf)
            }
        }
        return two ? cluster(left) + cluster(right) : cluster(items)
    }

    /// 编号纠错："SO."→50、"s.5"→55、"I1."→11、"O."→10
    private static func fixNum(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let m = trimmed.range(of: "^([A-Za-z])(\\d{1,3})\\s*[.、．]", options: .regularExpression) {
            let ns = trimmed as NSString
            let full = ns.substring(with: NSRange(m, in: trimmed))
            let letter = full.first?.lowercased() ?? ""
            var digits = ""
            for ch in full.dropFirst() where ch.isNumber { digits.append(ch) }
            guard let n = Int(digits) else { return nil }
            switch letter {
            case "s": return n < 5 ? 50 + n : 5
            case "i", "l": return n < 10 ? 10 + n : 1
            case "o": return 10
            default: return n
            }
        }
        if let m = leadMixedNumRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r2 = Range(m.range(at: 2), in: trimmed) {
            return Int(String(trimmed[r2]))
        }
        return nil
    }

    /// 从英文行提取单词（容忍编号前缀/词性后缀/噪声尾巴）
    private static func extractEnWord(_ line: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: "^Part", options: .regularExpression) != nil { return nil }
        s = s.replacingOccurrences(of: "^[A-Za-z]?\\d{1,3}\\s*[.、．:：，,]?\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[A-Za-z]\\s*[.、．]\\s+", with: "", options: .regularExpression)
        let ns = s as NSString
        if let m = posRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            s = ns.substring(with: NSRange(location: 0, length: m.range.location))
        }
        var w = ""
        for ch in s {
            if (ch >= "a" && ch <= "z") || ch == " " || ch == "-" || ch == "'" {
                w.append(ch)
            } else if !w.isEmpty { break }
        }
        w = w.trimmingCharacters(in: .whitespaces)
        var toks = w.split(separator: " ").map(String.init)
        if let lastT = toks.last, lastT.count == 1 { toks.removeLast(); w = toks.joined(separator: " ") }
        guard w.count >= 3, w.filter({ $0.isLetter }).count >= 3 else { return nil }
        return w
    }

    /// 从中文行提取释义（剥编号/英文/词性后收集连续 CJK）
    private static func extractZhDef(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "^[A-Za-z]?\\d{1,3}\\s*[.、．:：，,]?\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[A-Za-z]\\s*[.、．]\\s+", with: "", options: .regularExpression)
        let ns = s as NSString
        var rest = s
        if let m = posRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            rest = ns.substring(from: m.range.upperBound)
        } else {
            var idx = s.startIndex
            for ch in s {
                let isEn = (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch == " "
                if isEn { idx = s.index(after: idx) } else { break }
            }
            rest = String(s[idx...])
        }
        var d = ""
        for ch in rest {
            let v = ch.unicodeScalars.first?.value ?? 0
            let isCJK = (0x4E00...0x9FFF).contains(v) || (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v)
                || "（）：，；…。、·().".contains(ch)
            if isCJK { d.append(ch) }
            else if d.isEmpty { continue } else { break }
        }
        return d.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// token 级拼写纠正（3 字母以上）：UITextChecker 判错时取 guesses 首位
    /// （Apple 按常见度排序）单候选纠正，避免多候选交叉验证反引入错误。
    private static func correctTokens(_ phrase: String) -> String {
        let tokens = phrase.split(separator: " ").map(String.init)
        var out: [String] = []
        for t in tokens {
            guard t.range(of: "^[A-Za-z]{3,}$", options: .regularExpression) != nil else { out.append(t); continue }
            let ns = t as NSString
            let miss = textChecker.rangeOfMisspelledWord(in: t, range: NSRange(location: 0, length: ns.length),
                                                         startingAt: 0, wrap: false, language: "en")
            if miss.location != NSNotFound, miss.length > 0 {
                if let guesses = textChecker.guesses(forWordRange: miss, in: t, language: "en"),
                   let first = guesses.first, !first.isEmpty {
                    out.append(first.lowercased())
                } else {
                    out.append(t)
                }
            } else {
                out.append(t)
            }
        }
        return out.joined(separator: " ")
    }

    /// 是否拼写错误（词典判定，仅作裁剪重识别的触发信号，不用于最终选词）
    private static func isMisspelled(_ w: String) -> Bool {
        let ns = w as NSString
        let miss = textChecker.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: ns.length),
                                                     startingAt: 0, wrap: false, language: "en")
        return miss.location != NSNotFound && miss.length > 0
    }

    /// 按归一化 box 裁剪原图并放大 scale 倍（Vision 原点左下 → CGImage 原点左上）
    private static func cropAndScale(_ cg: CGImage, box: CGRect, scale: Int) -> CGImage? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let x = box.minX * w
        let yTop = (1 - box.maxY) * h
        let bw = box.width * w
        let bh = box.height * h
        let pad: CGFloat = 8
        let rect = CGRect(x: max(0, x - pad), y: max(0, yTop - pad),
                          width: min(w, bw + pad * 2), height: min(h, bh + pad * 2))
        guard let cropped = cg.cropping(to: rect) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: cropped.width * scale,
                                                            height: cropped.height * scale))
        let scaled = renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0,
                width: cropped.width * scale, height: cropped.height * scale))
        }
        return scaled.cgImage
    }

    /// zh 行分组（编号行 + 无编号续行合并跨行中文）+ en 行提取与裁剪重识别 + 三级配对合并 + 释义修复
    private static func mergeDualPass(zhRows: [(text: String, box: CGRect, midY: CGFloat, conf: Float)],
                                      enRows: [(text: String, box: CGRect, midY: CGFloat, conf: Float)],
                                      cg: CGImage) -> [String] {
        struct ZhGroup { var num: Int?; var text: String; var midY: CGFloat; var box: CGRect; var conf: Float }
        var zhGroups: [ZhGroup] = []
        var pendNum: Int? = nil
        for zr in zhRows {
            if zr.text.range(of: "^Part", options: .regularExpression) != nil { continue }
            if let n = fixNum(zr.text) {
                pendNum = n
                zhGroups.append(ZhGroup(num: n, text: zr.text, midY: zr.midY, box: zr.box, conf: zr.conf))
            } else if pendNum != nil, !zhGroups.isEmpty {
                zhGroups[zhGroups.count - 1].text += " " + zr.text
                zhGroups[zhGroups.count - 1].box = zhGroups[zhGroups.count - 1].box.union(zr.box)
            }
        }

        struct EnRow { var num: Int?; var rawWord: String; var word: String; var midY: CGFloat; var conf: Float; var box: CGRect }
        var enRows2: [EnRow] = []
        for er in enRows {
            if er.text.range(of: "^Part", options: .regularExpression) != nil { continue }
            guard let raw = extractEnWord(er.text) else { continue }
            enRows2.append(EnRow(num: fixNum(er.text), rawWord: raw,
                                 word: correctTokens(raw), midY: er.midY, conf: er.conf, box: er.box))
        }

        // 步骤A：低置信度/词典不干净的行，裁剪原行放大3x重识别，词典更干净或置信度更高则采纳
        var refined: [EnRow] = []
        for en in enRows2 {
            var w = en.word
            let badOld = en.rawWord.split(separator: " ").filter { isMisspelled(String($0)) }.count
            let rawBad = en.rawWord.split(separator: " ").contains { isMisspelled(String($0)) }
            let stillBad = w.split(separator: " ").contains { isMisspelled(String($0)) }
            if en.conf < 0.6 || rawBad || stillBad {
                if let crop = cropAndScale(cg, box: en.box, scale: 3),
                   let reRows = try? performPass(crop, langs: ["en-US", "zh-Hans"], correction: true) {
                    for ro in reRows {
                        if let w2raw = extractEnWord(ro.text) {
                            let w2 = correctTokens(w2raw)
                            let badNew = w2raw.split(separator: " ").filter { isMisspelled(String($0)) }.count
                            if badNew < badOld || (badNew == badOld && ro.conf > en.conf) {
                                w = w2
                            }
                            break
                        }
                    }
                }
            }
            refined.append(EnRow(num: en.num, rawWord: en.rawWord, word: w, midY: en.midY, conf: en.conf, box: en.box))
        }
        enRows2 = refined

        // 步骤B：en pass 漏识别的编号，从 zh 行文本补英文词
        let enNums = Set(enRows2.compactMap { $0.num })
        for zg in zhGroups {
            if let n = zg.num, !enNums.contains(n), let w = extractEnWord(zg.text) {
                enRows2.append(EnRow(num: n, rawWord: w, word: correctTokens(w),
                                     midY: zg.midY, conf: zg.conf, box: zg.box))
            }
        }

        var used = Set<Int>()
        var merged: [(word: String, def: String, zhNum: Int?)] = []
        for en in enRows2 {
            var zi: Int? = nil
            if let n = en.num, let hit = zhGroups.firstIndex(where: { $0.num == n && !used.contains($0.num ?? -1) }) {
                zi = hit; used.insert(zhGroups[hit].num ?? -1)
            } else if let hit = zhGroups.firstIndex(where: { $0.text.lowercased().contains(en.word) && !used.contains($0.num ?? -1) }) {
                zi = hit; used.insert(zhGroups[hit].num ?? -1)
            } else {
                var bestI: Int? = nil; var bestD = CGFloat.greatestFiniteMagnitude
                for (i, zg) in zhGroups.enumerated() where !used.contains(zg.num ?? -1) {
                    let d = abs(zg.midY - en.midY)
                    if d < bestD { bestD = d; bestI = i }
                }
                if let bi = bestI { zi = bi; used.insert(zhGroups[bi].num ?? -1) }
            }
            guard let zIdx = zi else { continue }
            let def = extractZhDef(zhGroups[zIdx].text)
            merged.append((en.word, def, zhGroups[zIdx].num))
        }

        // 步骤C：释义无中文的行，裁剪 zh 行放大3x重识别修复
        var fixed: [(word: String, def: String)] = []
        for m in merged {
            var def = m.def
            if !containsCJK(def), let n = m.zhNum, let zg = zhGroups.first(where: { $0.num == n }),
               let crop = cropAndScale(cg, box: zg.box, scale: 3),
               let reRows = try? performPass(crop, langs: ["zh-Hans", "en-US"], correction: true) {
                for ro in reRows {
                    let d2 = extractZhDef(ro.text)
                    if containsCJK(d2) { def = d2; break }
                }
            }
            fixed.append((m.word, def))
        }

        var bestMap: [String: (String, String)] = [:]
        for m in fixed {
            if let old = bestMap[m.word] {
                if m.def.count > old.1.count { bestMap[m.word] = (m.word, m.def) }
            } else { bestMap[m.word] = (m.word, m.def) }
        }
        return bestMap.values.sorted { $0.0 < $1.0 }.map { $0.1.isEmpty ? $0.0 : "\($0.0) \($0.1)" }
    }
}
