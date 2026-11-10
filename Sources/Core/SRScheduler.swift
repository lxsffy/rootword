//
//  SRScheduler.swift
//  RootWord · 词根单词
//
//  艾宾浩斯间隔重复排期（提示词第 4.3 节「学习记录」/ 验收第 6 条）——固定间隔数组实现。
//
//  本文件是纯函数集合：无状态、无副作用、可单测（见文件末尾 #if DEBUG 自检）。
//
//  ⚠ 排期模型（对照提示词 4.3）：
//     · 学习记录 level 0~8（内部用 SrsState.reps 承载 level：连续答对档位）
//     · 固定间隔数组 5min → 30min → 12h → 1d → 2d → 4d → 7d → 15d（8 档，可配置）
//     · 记得 → level+1、nextReview = now + interval[level]
//     · 模糊 → 降一级（level-1）、nextReview = now + interval[level]
//     · 忘记 → level=0、nextReview = now + 5min（重插上限 2 次/日，超出顺延次日 04:00）
//       会话内为「队尾即时重练」，UI 显示「本轮稍后」；dueAt 的时间间隔在下次装配队列时生效
//     · 完成 15 天档到期复习（再次「记得」）→ 已掌握，不再安排复习
//     · 日界 04:00（凌晨 4 点换学习日）
//
//  说明：本实现放弃旧版 SM-2 动态 EF 间隔（1→6→9→24 天），改按提示词验收要求的固定
//  艾宾浩斯数组排期；SrsState.ef 字段保留用于兼容持久化契约，但不再参与间隔计算。
//

import Foundation

struct QueuePlan {
    /// 装配好的学习队列（复习在前、新词在后）
    var queue: [Word] = []
    /// 应用了「日界重置」与「逾期降档」后的单词（需回写持久化）
    var updatedWords: [Word] = []
    var dueCount: Int = 0
    var newCount: Int = 0
    var overdueCount: Int = 0
}

enum SRScheduler {

    // MARK: - 常量

    /// 艾宾浩斯固定间隔数组（秒）：level 1~8 对应 5min / 30min / 12h / 1d / 2d / 4d / 7d / 15d
    static let intervalArray: [TimeInterval] = [
        5 * 60,          // level 1：5 分钟
        30 * 60,         // level 2：30 分钟
        12 * 3600,       // level 3：12 小时
        1 * 86_400,      // level 4：1 天
        2 * 86_400,      // level 5：2 天
        4 * 86_400,      // level 6：4 天
        7 * 86_400,      // level 7：7 天
        15 * 86_400      // level 8：15 天
    ]

    /// EF 下限 / 上限（字段仅用于持久化兼容，不再参与间隔计算）
    static let minEF: Double = 1.3
    static let maxEF: Double = 2.8
    /// 间隔上限（天）：艾宾浩斯最高档 15 天
    static let maxInterval: Int = 15
    /// 达到该间隔即视为「已掌握」判定阈值（15 天档）
    static let masteredInterval: Int = 15
    /// 「忘记」后当日重插的时间间隔（秒）：5 分钟
    static let reinsertSeconds: TimeInterval = 5 * 60
    /// 当日在队列中被重插的最大次数（超过则顺延次日 04:00）
    static let maxReinsertPerDay = 2
    /// 学习期判定阈值：间隔 ≤ 12 小时（level ≤ 3）视为仍在「当日学习期」
    static let learningWindow: TimeInterval = 12 * 3600
    /// 日界小时（凌晨 4:00 换日）
    static let dayBoundaryHour = 4

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - 间隔换算

    /// level（0~8）→ 距下次复习的秒数；level=0 视为 5 分钟（第一档）
    static func intervalSeconds(forLevel level: Int) -> TimeInterval {
        let idx = max(0, min(level - 1, intervalArray.count - 1))
        return intervalArray[idx]
    }

    /// level → 「天」语义（供 interval 字段/统计/逾期判断；分钟/小时级返回 0）
    static func intervalDays(forLevel level: Int) -> Int {
        switch max(0, min(level, intervalArray.count)) {
        case 0, 1, 2, 3: return 0      // 5min / 30min / 12h 均属当日档（interval 字段记 0）
        case 4: return 1               // 1d
        case 5: return 2               // 2d
        case 6: return 4               // 4d
        case 7: return 7               // 7d
        default: return 15             // 15d
        }
    }

    // MARK: - 日界（提示词 4.3 收口：凌晨 4:00 换日）

    /// 学习日的起点：当天 04:00；若此刻早于 04:00，则属于「前一个学习日」。
    static func studyDayStart(_ date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        guard let boundary = calendar.date(byAdding: .hour, value: dayBoundaryHour, to: startOfDay) else {
            return startOfDay
        }
        if date < boundary {
            return calendar.date(byAdding: .day, value: -1, to: boundary) ?? boundary
        }
        return boundary
    }

    /// yyyy-MM-dd 形式的日键（用于重插次数的懒重置）
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        dayKeyFormatter.string(from: studyDayStart(date, calendar: calendar))
    }

    /// 按天排期：从今天的学习日起算 +interval 天，落回当日 04:00
    static func dueDate(intervalDays: Int, from now: Date, calendar: Calendar = .current) -> Date {
        // studyDayStart 已把锚点落在当日 04:00，直接加天数即可（不可再加一次日界小时）
        let dayStart = studyDayStart(now, calendar: calendar)
        return calendar.date(byAdding: .day, value: max(1, intervalDays), to: dayStart) ?? dayStart
    }

    // MARK: - 新词初始化（提示词 4.3：level=0、导入当天即可学）

    static func makeNewState(now: Date = Date(), calendar: Calendar = .current) -> SrsState {
        var s = SrsState()
        s.ef = 2.5
        s.reps = 0
        s.lapses = 0
        s.interval = 0
        s.dueAt = now          // 导入当天即可学
        s.phase = .new
        s.reinsertCountToday = 0
        s.dayKey = dayKey(for: now, calendar: calendar)
        return s
    }

    // MARK: - 逾期惩罚

    /// 逾期 > 2 × interval 时先降档：interval 减半、reps 减 1，再进入本次会话。
    /// 分钟/小时级（interval=0）不降档——当天未复习不算逾期。
    static func applyOverduePenalty(_ state: SrsState, now: Date = Date()) -> SrsState {
        guard state.interval > 0 else { return state }
        let overdue = now.timeIntervalSince(state.dueAt)
        let threshold = Double(state.interval) * 2 * 86_400
        guard overdue > threshold else { return state }

        var s = state
        s.interval = max(1, Int((Double(state.interval) * 0.5).rounded()))
        s.reps = max(0, state.reps - 1)
        if s.phase == .mastered && s.interval < masteredInterval {
            s.phase = .review
        }
        return s
    }

    // MARK: - 核心：三档评分 → 新状态（提示词 4.3 表）

    static func apply(_ state: SrsState,
                      grade: Grade,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> SrsState {
        var s = state
        let today = dayKey(for: now, calendar: calendar)

        // 懒重置当日的重插计数
        if s.dayKey != today {
            s.dayKey = today
            s.reinsertCountToday = 0
        }

        switch grade {

        case .forgot:
            // 忘记 → level=0，5 分钟后再出现（当日队列重插，上限 2 次）
            s.ef = max(minEF, s.ef - 0.20)
            s.reps = 0
            s.lapses += 1
            s.interval = 0
            s.phase = .relearning
            s.reinsertCountToday += 1
            if s.reinsertCountToday <= maxReinsertPerDay {
                s.dueAt = now.addingTimeInterval(reinsertSeconds)   // 当日队列重插
            } else {
                s.dueAt = dueDate(intervalDays: 1, from: now, calendar: calendar)  // 次日 04:00
            }

        case .fuzzy:
            // 模糊 → 降一级（level-1），严格按新档位间隔排期（提示词 4.3：模糊 → 降一级）。
            // 重插计数仅用于 AppState 判断「本会话是否再练一次」以杜绝无限重练，
            // 不改变 dueAt 档期：降级后的 5min / 30min / 12h 档本来就是当日可练，
            // 即使 forgot 预算已耗尽，也应按降级档位排期，而不是把 30 分钟档硬推到次日。
            s.ef = max(minEF, s.ef - 0.14)
            s.reps = max(0, s.reps - 1)
            s.interval = intervalDays(forLevel: s.reps)
            s.phase = phaseFor(level: s.reps)
            s.reinsertCountToday += 1
            s.dueAt = now.addingTimeInterval(intervalSeconds(forLevel: s.reps))

        case .remembered:
            // 记得 → level+1，按新档位间隔排期
            s.ef = min(maxEF, s.ef + 0.10)
            let prevLevel = s.reps
            s.reps = min(s.reps + 1, intervalArray.count)   // 上限 level 8
            s.interval = intervalDays(forLevel: s.reps)
            if prevLevel == intervalArray.count, s.interval == intervalDays(forLevel: intervalArray.count) {
                // 已在 15 天档完成到期复习 → 已掌握，不再安排复习
                s.phase = .mastered
                s.dueAt = now
            } else {
                s.phase = phaseFor(level: s.reps)
                s.dueAt = now.addingTimeInterval(intervalSeconds(forLevel: s.reps))
            }
        }

        return s
    }

    /// level → 阶段：level 0 = 重学；level 1~2（5min/30min）= 学习；
    /// level ≥ 3（12h 及以上）= 复习；已掌握由 apply 在完成 15 天档后显式设置。
    static func phaseFor(level: Int) -> Phase {
        if level >= 3 { return .review }
        if level >= 1 { return .learning }
        return .relearning
    }

    // MARK: - 会话内重插判定（算法层 / 会话层 / UI 共用）

    /// 本次评分后，该词是否会在**当前会话队列尾部**再练一次。
    /// 本次修订 修复：此前算法层、按钮预览与 AppState.grade 各写一套边界（`<` 与 `<=` 混用），
    /// 导致第 2 次「忘记」提示「5 分钟后」却不会入队。现在统一到这一处判定。
    /// 注意：这是队尾即时重练，**不是**等待 reinsertSeconds；dueAt 仍由 apply 按档位计算，
    /// 时间维度的间隔重复在下次装配队列（到期后）生效。
    static func shouldReinsert(next: SrsState, grade: Grade, now: Date) -> Bool {
        switch grade {
        case .forgot:
            return next.reinsertCountToday <= maxReinsertPerDay
        case .fuzzy:
            return next.dueAt.timeIntervalSince(now) <= learningWindow
                && next.reinsertCountToday <= maxReinsertPerDay
        case .remembered:
            return false
        }
    }

    /// 供 UI 在评分前预览使用（内部自行 apply 一次）。
    static func shouldReinsert(in state: SrsState,
                               grade: Grade,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> Bool {
        let next = apply(state, grade: grade, now: now, calendar: calendar)
        return shouldReinsert(next: next, grade: grade, now: now)
    }

    // MARK: - 评分按钮下方的「下次间隔」预览

    static func previewLabel(_ state: SrsState,
                             grade: Grade,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        let next = apply(state, grade: grade, now: now, calendar: calendar)
        let willReinsert = shouldReinsert(next: next, grade: grade, now: now)
        switch grade {
        case .forgot:
            return willReinsert ? "本轮稍后" : "明天"
        case .fuzzy:
            if next.phase == .mastered { return "已掌握" }
            return willReinsert ? "本轮稍后" : relativeText(next.dueAt, now: now)
        case .remembered:
            if next.phase == .mastered { return "已掌握" }
            return relativeText(next.dueAt, now: now)
        }
    }

    /// dueAt 相对 now 的友好文案：5 分钟后 / 30 分钟后 / 12 小时后 / N 天后
    static func relativeText(_ dueAt: Date, now: Date) -> String {
        let s = max(0, dueAt.timeIntervalSince(now))
        if s <= 10 * 60 { return "5 分钟后" }
        if s <= 45 * 60 { return "30 分钟后" }
        if s <= learningWindow + 3600 { return "12 小时后" }
        let days = Int(ceil(s / 86_400))
        return "\(days) 天后"
    }

    // MARK: - 每日队列装配（确定性，无随机）

    static func buildQueue(words: [Word],
                           settings: AppSettings,
                           currentDeckID: String? = nil,
                           now: Date = Date(),
                           calendar: Calendar = .current) -> QueuePlan {
        var plan = QueuePlan()
        let today = dayKey(for: now, calendar: calendar)

        // 第 2 步：懒重置当日的重插计数
        var normalized: [Word] = []
        normalized.reserveCapacity(words.count)
        for var w in words {
            if w.srs.dayKey != today {
                w.srs.dayKey = today
                w.srs.reinsertCountToday = 0
            }
            normalized.append(w)
        }

        // 第 3 步：到期复习列表（最旧优先），排除 .new 与 .mastered
        var dueList = normalized.filter { w in
            w.srs.phase != .mastered && w.srs.phase != .new && w.srs.dueAt <= now
        }
        dueList.sort { lhs, rhs in
            if lhs.srs.dueAt != rhs.srs.dueAt { return lhs.srs.dueAt < rhs.srs.dueAt }
            return lhs.id < rhs.id     // 保证同到期时间下顺序稳定
        }

        // 第 4 步：新词列表（当前词单优先 → 词单 id → 词单内 position 升序）
        // 本次修订 修复：旧版由 AppState 在调用前把当前词单排到数组前面，
        // 但下面的 sort 会按 deckID 重排（Swift sort 不保证稳定），优先级实际被覆盖；
        // 现在通过 currentDeckID 参数在本函数内显式实现，规则不再依赖调用方预处理。
        var newList = normalized.filter { $0.srs.phase == .new }
        newList.sort { lhs, rhs in
            if let current = currentDeckID {
                let lhsCurrent = lhs.deckID == current
                let rhsCurrent = rhs.deckID == current
                if lhsCurrent != rhsCurrent { return lhsCurrent }
            }
            if lhs.deckID != rhs.deckID { return lhs.deckID < rhs.deckID }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
        // 截断发生在排序之后，保证 dailyNewLimit 优先保留当前词单的新词。
        if newList.count > settings.dailyNewLimit {
            newList = Array(newList.prefix(settings.dailyNewLimit))
        }

        // 第 5 步：逾期降档 + 复习上限截断
        var overdueCount = 0
        var penalizedIDs = Set<String>()
        dueList = dueList.map { w in
            var word = w
            let penalized = applyOverduePenalty(word.srs, now: now)
            if penalized != word.srs {
                overdueCount += 1
                penalizedIDs.insert(word.id)
                word.srs = penalized
            }
            return word
        }
        if dueList.count > settings.dailyReviewLimit {
            dueList = Array(dueList.prefix(settings.dailyReviewLimit))
        }

        // 第 6 步：复习在前、新词在后
        plan.queue = dueList + newList
        plan.dueCount = dueList.count
        plan.newCount = newList.count
        plan.overdueCount = overdueCount

        // 回写：把降档/重置后的状态合并回全量数组
        var patched = normalized
        var patchIndex: [String: Int] = [:]
        for (i, w) in patched.enumerated() { patchIndex[w.id] = i }
        for w in plan.queue where penalizedIDs.contains(w.id) || w.srs.dayKey == today {
            if let i = patchIndex[w.id] {
                var merged = patched[i]
                if penalizedIDs.contains(w.id) { merged.srs = w.srs }
                merged.srs.dayKey = today
                patched[i] = merged
            }
        }
        plan.updatedWords = patched
        return plan
    }

    // MARK: - 未来 N 天复习量预测（统计页柱状图）

    static func forecast(words: [Word],
                         days: Int = 7,
                         now: Date = Date(),
                         calendar: Calendar = .current) -> [(date: Date, count: Int)] {
        var result: [(date: Date, count: Int)] = []
        let todayStart = studyDayStart(now, calendar: calendar)
        for offset in 0..<days {
            guard let start = calendar.date(byAdding: .day, value: offset, to: todayStart),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let count: Int
            if offset == 0 {
                count = words.filter { $0.srs.phase != .new && $0.srs.phase != .mastered && $0.srs.dueAt < end }.count
            } else {
                count = words.filter { $0.srs.phase != .new && $0.srs.dueAt >= start && $0.srs.dueAt < end }.count
            }
            result.append((date: start, count: count))
        }
        return result
    }
}

// MARK: - 单元自检（仅 DEBUG 编译）

#if DEBUG
enum SRSchedulerSelfCheck {

    /// 便于在 Xcode 断点/控制台调用；有失败会在控制台打印。
    static func run() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }

        let now = Date()

        // T1~T4：连续「记得」按艾宾浩斯数组推进（5min → 30min → 12h → 1d）
        var s = SRScheduler.apply(SrsState(), grade: .remembered, now: now)
        expect(s.reps == 1 && s.interval == 0 && s.phase == .learning
               && abs(s.dueAt.timeIntervalSince(now) - 5 * 60) < 5, "T1 第一档 5 分钟")
        s = SRScheduler.apply(s, grade: .remembered, now: now)
        expect(s.reps == 2 && s.interval == 0 && s.phase == .learning
               && abs(s.dueAt.timeIntervalSince(now) - 30 * 60) < 5, "T2 第二档 30 分钟")
        s = SRScheduler.apply(s, grade: .remembered, now: now)
        expect(s.reps == 3 && s.interval == 0 && s.phase == .review
               && abs(s.dueAt.timeIntervalSince(now) - 12 * 3600) < 5, "T3 第三档 12 小时")
        s = SRScheduler.apply(s, grade: .remembered, now: now)
        expect(s.reps == 4 && s.interval == 1 && s.phase == .review, "T4 第四档 1 天")

        // T5：连续推进到 15 天档（level 8），再完成到期复习 → 已掌握
        var chain = SrsState()
        for _ in 0..<8 { chain = SRScheduler.apply(chain, grade: .remembered, now: now) }
        expect(chain.reps == 8 && chain.interval == 15 && chain.phase == .review
               && abs(chain.dueAt.timeIntervalSince(now) - 15 * 86_400) < 60, "T5 第八档 15 天（复习中）")
        chain = SRScheduler.apply(chain, grade: .remembered, now: now)
        expect(chain.phase == .mastered, "T5 完成 15 天档后已掌握")

        // T6：忘记 → level 0、5 分钟后重插、lapses+1
        var forgot = SrsState(); forgot.dayKey = SRScheduler.dayKey(for: now)
        forgot = SRScheduler.apply(forgot, grade: .forgot, now: now)
        expect(forgot.reps == 0 && forgot.lapses == 1 && forgot.interval == 0
               && abs(forgot.dueAt.timeIntervalSince(now) - 5 * 60) < 5, "T6 忘记重插 5 分钟")

        // T7：同日连续「忘记」第 3 次不再重插（顺延次日 04:00）
        forgot = SRScheduler.apply(forgot, grade: .forgot, now: now)
        expect(forgot.reinsertCountToday == 2 && forgot.dueAt.timeIntervalSince(now) < 3600, "T7 前两次重插")
        forgot = SRScheduler.apply(forgot, grade: .forgot, now: now)
        expect(forgot.dueAt > now.addingTimeInterval(3600), "T7 第三次顺延次日")

        // T8：模糊降一级：level 3 → level 2、30 分钟后
        var mid = SrsState(); mid.reps = 3; mid.interval = 0
        mid = SRScheduler.apply(mid, grade: .fuzzy, now: now)
        expect(mid.reps == 2 && abs(mid.dueAt.timeIntervalSince(now) - 30 * 60) < 5, "T8 模糊降级 30 分钟")

        // T9：09/18 23:30 学习 interval=1 → 09/19 04:00
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let night = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 23, minute: 30))!
        let due = SRScheduler.dueDate(intervalDays: 1, from: night, calendar: cal)
        let comps = cal.dateComponents([.month, .day, .hour], from: due)
        expect(comps.month == 9 && comps.day == 19 && comps.hour == 4, "T9 日界规则")

        // T10：逾期降档
        var overdue = SrsState()
        overdue.interval = 10; overdue.reps = 3
        overdue.dueAt = now.addingTimeInterval(-25 * 86_400)
        let penalized = SRScheduler.applyOverduePenalty(overdue, now: now)
        expect(penalized.interval == 5 && penalized.reps == 2, "T10 逾期降档")

        if failures.isEmpty {
            print("[SRScheduler] 自检通过：T1–T10（艾宾浩斯 5min→30min→12h→1d→2d→4d→7d→15d）")
        } else {
            print("[SRScheduler] 自检失败项：\(failures.joined(separator: ", "))")
        }
    }
}
#endif
