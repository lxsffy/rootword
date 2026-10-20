//
//  SRScheduler.swift
//  RootWord · 词根单词
//
//  艾宾浩斯间隔重复排期（SM-2 变体）—— 产品设计文档第 7 章的 1:1 实现。
//
//  本文件是纯函数集合：无状态、无副作用、可单测（见文件末尾 #if DEBUG 自检 T1–T10）。
//
//  ⚠ 与标准 SM-2 的两处有意偏离（文档 7.3 第 3、4 条，已在「关于」页向用户说明）：
//    ① 「忘记」档惩罚固定为 EF −0.20（标准公式会给出 −0.54，对初学者过严）；
//    ② EF 上限 2.8（标准 SM-2 无上限，长期全对会使间隔爆炸）。
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

    /// EF 下限
    static let minEF: Double = 1.3
    /// EF 上限（本产品变体）
    static let maxEF: Double = 2.8
    /// 间隔上限（天）
    static let maxInterval: Int = 180
    /// 达到该间隔即视为「已掌握」
    static let masteredInterval: Int = 21
    /// 「忘记」后当日重插的时间间隔（秒）
    static let reinsertSeconds: TimeInterval = 10 * 60
    /// 当日在队列中被重插的最大次数（超过则顺延次日 04:00）
    static let maxReinsertPerDay = 2
    /// 日界小时（凌晨 4:00 换日）
    static let dayBoundaryHour = 4

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - 日界（文档 7.3 收口规则 2）

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

    // MARK: - 新词初始化（文档 7.3 收口规则 6）

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

    // MARK: - 逾期惩罚（文档 7.3 收口规则 5）

    /// 逾期 > 2 × interval 时先降档：interval 减半、reps 减 1，再进入本次会话。
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

    // MARK: - 核心：三档评分 → 新状态（文档 7.3 表格）

    static func apply(_ state: SrsState,
                      grade: Grade,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> SrsState {
        var s = state
        let today = dayKey(for: now, calendar: calendar)

        // 懒重置当日的重插计数（文档 7.5 第 2 步）
        if s.dayKey != today {
            s.dayKey = today
            s.reinsertCountToday = 0
        }

        switch grade {

        case .forgot:
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
            s.ef = max(minEF, s.ef - 0.14)
            s.reps += 1
            let next: Int
            if s.reps == 1 {
                next = 1
            } else if s.reps == 2 {
                next = 3
            } else {
                next = Int((Double(s.interval) * s.ef * 0.6).rounded())
            }
            s.interval = min(max(1, next), maxInterval)
            s.phase = phaseFor(interval: s.interval, reps: s.reps)
            if s.interval == 1 {
                // 「模糊」且间隔为 1 天：本次会话后当日再练一次
                s.dueAt = now.addingTimeInterval(reinsertSeconds)
            } else {
                s.dueAt = dueDate(intervalDays: s.interval, from: now, calendar: calendar)
            }

        case .remembered:
            s.ef = min(maxEF, s.ef + 0.10)
            s.reps += 1
            let next: Int
            if s.reps == 1 {
                next = 1
            } else if s.reps == 2 {
                next = 6
            } else {
                next = Int((Double(s.interval) * s.ef).rounded())
            }
            s.interval = min(max(1, next), maxInterval)
            s.phase = phaseFor(interval: s.interval, reps: s.reps)
            s.dueAt = dueDate(intervalDays: s.interval, from: now, calendar: calendar)
        }

        return s
    }

    /// interval ≥ 21 天 → 已掌握；reps ≥ 2 → 复习中；否则学习中（文档 7.3 收口规则 7）
    static func phaseFor(interval: Int, reps: Int) -> Phase {
        if interval >= masteredInterval { return .mastered }
        if reps >= 2 { return .review }
        return .learning
    }

    // MARK: - 评分按钮下方的「下次间隔」预览（文档 5.4 / 原型行为）

    static func previewLabel(_ state: SrsState,
                             grade: Grade,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> String {
        let next = apply(state, grade: grade, now: now, calendar: calendar)
        switch grade {
        case .forgot:
            return next.reinsertCountToday <= maxReinsertPerDay ? "10 分钟后" : "明天"
        case .fuzzy:
            return next.interval == 1 ? "今天再练" : "\(next.interval) 天后"
        case .remembered:
            if next.interval >= maxInterval { return "已掌握" }
            return "\(next.interval) 天后"
        }
    }

    // MARK: - 每日队列装配（文档 7.5，确定性，无随机）

    static func buildQueue(words: [Word],
                           settings: AppSettings,
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

        // 第 4 步：新词列表（词单 id → 词单内 position 升序）
        var newList = normalized.filter { $0.srs.phase == .new }
        newList.sort { lhs, rhs in
            if lhs.deckID != rhs.deckID { return lhs.deckID < rhs.deckID }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id < rhs.id
        }
        // 说明：本函数保持纯函数，不改动「当前词单优先」的业务规则；
        // AppState 会在调用前把当前词单的词排到数组前面，从而实现新词优先级。
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

// MARK: - 单元自检（文档 7.7 的 T1–T10，仅 DEBUG 编译）

#if DEBUG
enum SRSchedulerSelfCheck {

    /// 便于在 Xcode 断点/控制台调用；有失败会在控制台打印。
    static func run() {
        var failures: [String] = []

        func expect(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }

        // T1 / T2 / T3：连续「记得」的间隔序列
        var s = SrsState()
        s = SRScheduler.apply(s, grade: .remembered)
        expect(abs(s.ef - 2.6) < 0.0001 && s.reps == 1 && s.interval == 1, "T1")
        s = SRScheduler.apply(s, grade: .remembered)
        expect(abs(s.ef - 2.7) < 0.0001 && s.reps == 2 && s.interval == 6, "T2")

        var longState = SrsState()
        longState.ef = 2.5; longState.interval = 100; longState.reps = 5
        longState = SRScheduler.apply(longState, grade: .remembered)
        expect(longState.interval == 180, "T3 间隔封顶")

        // T4 / T5：EF 上下限
        var low = SrsState(); low.ef = 1.25
        low = SRScheduler.apply(low, grade: .forgot)
        expect(abs(low.ef - 1.3) < 0.0001, "T4 EF 下限")

        var high = SrsState(); high.ef = 2.7; high.interval = 6; high.reps = 2
        high = SRScheduler.apply(high, grade: .remembered)
        expect(abs(high.ef - 2.8) < 0.0001, "T5 EF 上限")

        // T6：逾期降档
        let now = Date()
        var overdue = SrsState()
        overdue.interval = 10; overdue.reps = 3
        overdue.dueAt = now.addingTimeInterval(-25 * 86_400)
        let penalized = SRScheduler.applyOverduePenalty(overdue, now: now)
        expect(penalized.interval == 5 && penalized.reps == 2, "T6 逾期降档")

        // T7：同日连续「忘记」第 3 次不再重插
        var forgot = SrsState(); forgot.dayKey = SRScheduler.dayKey(for: now)
        forgot = SRScheduler.apply(forgot, grade: .forgot, now: now)
        forgot = SRScheduler.apply(forgot, grade: .forgot, now: now)
        expect(forgot.reinsertCountToday == 2 && forgot.dueAt.timeIntervalSince(now) < 3600, "T7 前两次重插")
        forgot = SRScheduler.apply(forgot, grade: .forgot, now: now)
        expect(forgot.dueAt > now.addingTimeInterval(3600), "T7 第三次顺延次日")

        // T8：09/18 23:30 学习 interval=1 → 09/19 04:00
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let night = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 23, minute: 30))!
        let due = SRScheduler.dueDate(intervalDays: 1, from: night, calendar: cal)
        let comps = cal.dateComponents([.month, .day, .hour], from: due)
        expect(comps.month == 9 && comps.day == 19 && comps.hour == 4, "T8 日界规则")

        // 演算表（文档 7.4）：1→6→9→24 的一段链路
        var chain = SrsState()
        chain = SRScheduler.apply(chain, grade: .remembered)
        chain = SRScheduler.apply(chain, grade: .remembered)
        chain = SRScheduler.apply(chain, grade: .fuzzy)
        expect(chain.interval == 9, "演算表第 3 步 = 9 天")
        chain = SRScheduler.apply(chain, grade: .remembered)
        expect(chain.interval == 24 && chain.phase == .mastered, "演算表第 4 步 = 24 天 / 已掌握")

        if failures.isEmpty {
            print("[SRScheduler] 自检通过：T1–T8 与演算表链路一致")
        } else {
            print("[SRScheduler] 自检失败项：\(failures.joined(separator: ", "))")
        }
    }
}
#endif
