import SwiftUI
//
//  Word.swift
//  RootWord · 词根单词
//
//  数据模型层：构词片段 / SRS 状态 / 单词 / 词单 / 复习记录
//  对应产品设计文档：第 7.2 节「数据结构」、第 3.5 节「数据实体与页面映射」
//  纯 Foundation，无第三方依赖，iOS 15.4 兼容。
//

import Foundation

// MARK: - 构词类型（第 6.2.3 节语义映射）

enum RootType: String, Codable, CaseIterable, Identifiable {
    case prefix
    case root
    case suffix
    case other

    var id: String { rawValue }

    var cnLabel: String {
        switch self {
        case .prefix: return "前缀"
        case .root:   return "词根"
        case .suffix: return "后缀"
        case .other:  return "未收录"
        }
    }

    /// 标识色，用于 chip 圆点与标签
    var dotColor: Color {
        switch self {
        case .prefix: return .brand500
        case .root:   return .warning500
        case .suffix: return .info500
        case .other:  return .textTertiary
        }
    }
}

// MARK: - 构词片段

/// 单词的一个构词片段，如 `un-`（前缀·不）、`spect`（词根·看）、`-ible`（后缀·可…的）。
/// 解析结果在导入时写入 `Word.segments` 并持久化，学习时不再重算（文档 7.6.2 的 S7）。
struct WordSegment: Codable, Equatable, Hashable, Identifiable {

    var id: String { "\(type.rawValue)-\(text)-\(rootID ?? "-")" }

    /// 展示形式，带连字符，如 `un-` / `-ible`
    var text: String
    /// 片段类型
    var type: RootType
    /// 中文含义，如「不、否定」；未收录时为空串
    var meaning: String
    /// 关联词根库 id（未收录时为 nil）
    var rootID: String?

    init(text: String, type: RootType, meaning: String, rootID: String? = nil) {
        self.text = text
        self.type = type
        self.meaning = meaning
        self.rootID = rootID
    }

    /// 用于 chip 展示的文案：`un-（不）`
    var displayText: String {
        meaning.isEmpty ? text : "\(text)（\(meaning)）"
    }
}

// MARK: - 学习阶段（第 7.2 节）

enum Phase: String, Codable, CaseIterable {
    case new
    case learning
    case review
    case relearning
    case mastered

    var cnLabel: String {
        switch self {
        case .new:        return "新词"
        case .learning:   return "学习中"
        case .review:     return "复习中"
        case .relearning: return "重学中"
        case .mastered:   return "已掌握"
        }
    }
}

// MARK: - 三档评分（第 7.3 节：q = 1 / 3 / 5）

enum Grade: Int, Codable, CaseIterable, Identifiable {
    case forgot = 1       // q = 1
    case fuzzy = 3        // q = 3
    case remembered = 5   // q = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .forgot:     return "忘记"
        case .fuzzy:      return "模糊"
        case .remembered: return "记得"
        }
    }

    /// 无障碍朗读用说明（第 6.8 节）
    var accessibilityHint: String {
        switch self {
        case .forgot:     return "没想起来，10 分钟后重来"
        case .fuzzy:      return "想起来了但不确定"
        case .remembered: return "顺利想起来"
        }
    }
}

// MARK: - SRS 状态（第 7.2 节）

struct SrsState: Codable, Equatable {

    /// 难易因子 Easiness Factor，下限 1.3，上限 2.8（本产品变体，见 7.3 第 4 条）
    var ef: Double = 2.5
    /// 连续答对次数（「忘记」会归零）
    var reps: Int = 0
    /// 累计遗忘次数
    var lapses: Int = 0
    /// 当前间隔（天）；0 表示尚未进入天级间隔
    var interval: Int = 0
    /// 下次到期时间
    var dueAt: Date = Date()
    /// 学习阶段
    var phase: Phase = .new
    /// 当日在队列中被重插的次数（上限 2）
    var reinsertCountToday: Int = 0
    /// 用于懒重置 `reinsertCountToday`，格式 yyyy-MM-dd（以 04:00 为日界）
    var dayKey: String = ""

    /// 连续记住次数（与 reps 同义，供 UI 语义化读取）
    var streak: Int { reps }

    var intervalText: String {
        if interval <= 0 {
            if phase == .new { return "未开始" }
            return "10 分钟后"
        }
        if interval == 1 { return "1 天" }
        if interval >= SRScheduler.maxInterval { return "已掌握" }
        return "\(interval) 天"
    }
}

// MARK: - 例句

struct Example: Codable, Equatable, Identifiable {

    var id: String = UUID().uuidString
    var en: String
    var cn: String

    init(en: String, cn: String = "") {
        self.en = en
        self.cn = cn
    }
}

// MARK: - 单词

struct Word: Codable, Equatable, Identifiable {

    var id: String = UUID().uuidString
    var text: String
    var meaning: String = ""
    var phonetic: String = ""
    var pos: String = ""
    /// 构词拆解缓存（导入时由 RootParser 写入）
    var segments: [WordSegment] = []
    /// 记忆法文案（导入自带优先）
    var mnemonic: String = ""
    var examples: [Example] = []
    var deckID: String = ""
    /// 词单内顺序，用于「新词」确定性排序（文档 7.5 第 4 步）
    var position: Int = 0
    var createdAt: Date = Date()
    var srs: SrsState = SrsState()

    init(text: String,
         meaning: String = "",
         phonetic: String = "",
         pos: String = "",
         segments: [WordSegment] = [],
         mnemonic: String = "",
         examples: [Example] = [],
         deckID: String = "",
         position: Int = 0) {
        self.text = text
        self.meaning = meaning
        self.phonetic = phonetic
        self.pos = pos
        self.segments = segments
        self.mnemonic = mnemonic
        self.examples = examples
        self.deckID = deckID
        self.position = position
    }

    /// 释义缺失时展示占位符（不编造释义，见文档 8.6.2）
    var displayMeaning: String { meaning.isEmpty ? "—" : meaning }

    var hasSegments: Bool { !segments.isEmpty }

    func isDue(at now: Date = Date()) -> Bool {
        srs.phase != .mastered && srs.phase != .new && srs.dueAt <= now
    }

    /// 逾期天数（用于首页「逾期」标签）
    func overdueDays(at now: Date = Date()) -> Int {
        guard isDue(at: now) else { return 0 }
        let seconds = now.timeIntervalSince(srs.dueAt)
        return max(0, Int(seconds / 86_400))
    }

    /// 首字母（列表分组 / 头像占位）
    var initial: String {
        String(text.prefix(1)).uppercased()
    }
}

// MARK: - 词单

struct Deck: Codable, Equatable, Identifiable {

    var id: String = UUID().uuidString
    var name: String
    var isBuiltIn: Bool = false
    /// 「当前词单」：首页优先从该词单取新词（只允许一个为 true）
    var isCurrent: Bool = false
    var note: String = ""
    var createdAt: Date = Date()

    init(name: String, isBuiltIn: Bool = false, isCurrent: Bool = false, note: String = "") {
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isCurrent = isCurrent
        self.note = note
    }
}

// MARK: - 复习记录（统计页数据源）

struct ReviewLog: Codable, Equatable, Identifiable {

    var id: String = UUID().uuidString
    var wordID: String
    var deckID: String
    var date: Date
    var grade: Grade
    /// 评分后的间隔（天）
    var intervalAfter: Int
    var phaseAfter: Phase
    /// 该次评分是否发生在「新词首次学习」时
    var isNewWord: Bool

    init(wordID: String,
         deckID: String,
         date: Date = Date(),
         grade: Grade,
         intervalAfter: Int,
         phaseAfter: Phase,
         isNewWord: Bool) {
        self.wordID = wordID
        self.deckID = deckID
        self.date = date
        self.grade = grade
        self.intervalAfter = intervalAfter
        self.phaseAfter = phaseAfter
        self.isNewWord = isNewWord
    }
}

// MARK: - 会话

/// 一次学习会话（内存态，不落盘）
struct StudySession {

    /// 待学队列（单词 id，按 7.5 确定性装配）
    var queue: [String]
    var index: Int = 0
    var startedAt: Date = Date()
    var remembered: Int = 0
    var fuzzy: Int = 0
    var forgot: Int = 0
    /// 队列初始长度（用于进度显示，重插不改变分母）
    var plannedCount: Int

    var currentID: String? {
        guard index >= 0, index < queue.count else { return nil }
        return queue[index]
    }

    var isFinished: Bool { index >= queue.count }

    var progressValue: Double {
        guard plannedCount > 0 else { return 0 }
        return min(1.0, Double(index) / Double(plannedCount))
    }

    var progressText: String { "\(min(index, plannedCount))/\(plannedCount)" }

    var totalGraded: Int { remembered + fuzzy + forgot }
}
