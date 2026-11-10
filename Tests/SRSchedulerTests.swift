//
//  SRSchedulerTests.swift
//  文档 P0：SRS 边界回归（含连续忘记/模糊/忘记的重插次数）
//

import Foundation

func runSRSchedulerTests(_ t: TestContext) {
    let cal = TestEnvironment.calendar()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func fresh() -> SrsState { SRScheduler.makeNewState(now: now, calendar: cal) }

    // 1. 新词第一次记得 → 进入下一档
    let remembered = SRScheduler.apply(fresh(), grade: .remembered, now: now, calendar: cal)
    t.equal(remembered.reps, 1, "新词第一次「记得」应升到 level 1")
    t.expect(remembered.dueAt > now, "「记得」应把 dueAt 排到将来")

    // 2. 新词第一次模糊 → 按规则降档（level 下限为 0，但阶段应离开 new）
    let fuzzy = SRScheduler.apply(fresh(), grade: .fuzzy, now: now, calendar: cal)
    t.equal(fuzzy.reps, 0, "新词「模糊」降档不能小于 level 0")
    t.expect(fuzzy.phase != .new, "「模糊」后不应仍停留在 new 阶段")

    // 3~5. 连续三次「忘记」：前两次进队尾，第三次不再重插
    var state = fresh()
    var reinserts = 0
    for round in 1...3 {
        state = SRScheduler.apply(state, grade: .forgot, now: now, calendar: cal)
        let willReinsert = SRScheduler.shouldReinsert(next: state, grade: .forgot, now: now)
        if willReinsert { reinserts += 1 }
        t.equal(state.reinsertCountToday, round, "第 \(round) 次忘记应累计计数 \(round)")
        if round <= 2 {
            t.expect(willReinsert, "第 \(round) 次忘记应回到本轮队尾")
        } else {
            t.expect(!willReinsert, "第 3 次忘记不应再重插")
        }
    }
    t.equal(reinserts, SRScheduler.maxReinsertPerDay, "连续三次忘记总共只应重插 2 次")
    t.expect(state.dueAt > now.addingTimeInterval(3600), "预算耗尽后应顺延到次日 04:00，而不是 5 分钟后")

    // 6. 按钮预览与实际入队判定必须一致
    t.equal(SRScheduler.previewLabel(fresh(), grade: .forgot, now: now, calendar: cal),
            "本轮稍后", "第 1 次忘记的按钮预览")
    let previewState = SRScheduler.apply(fresh(), grade: .forgot, now: now, calendar: cal)
    t.expect(SRScheduler.shouldReinsert(in: previewState, grade: .forgot, now: now, calendar: cal),
             "预览判定与 apply 结果应一致")

    // 7. 同一个词连续「忘记 → 模糊 → 忘记」：检查到底会重插几次
    var mixed = fresh()
    var mixedReinserts = 0
    for grade in [Grade.forgot, .fuzzy, .forgot] {
        mixed = SRScheduler.apply(mixed, grade: grade, now: now, calendar: cal)
        if SRScheduler.shouldReinsert(next: mixed, grade: grade, now: now) { mixedReinserts += 1 }
    }
    t.equal(mixed.reinsertCountToday, 3, "忘记/模糊/忘记应共用同一个当日计数器")
    t.expect(mixedReinserts <= SRScheduler.maxReinsertPerDay,
             "混合评分序列不能突破每日重插预算（实际 \(mixedReinserts)）")

    // 8. 跨越凌晨 4 点：日界与计数重置
    let before4 = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 3, minute: 30))!
    let after4 = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 4, minute: 30))!
    t.expect(SRScheduler.dayKey(for: before4, calendar: cal) != SRScheduler.dayKey(for: after4, calendar: cal),
             "凌晨 4 点前后应属于不同学习日")
    var stale = SRScheduler.makeNewState(now: before4, calendar: cal)
    stale.reinsertCountToday = 2
    let reset = SRScheduler.apply(stale, grade: .forgot, now: after4, calendar: cal)
    t.equal(reset.reinsertCountToday, 1, "跨过日界后计数应重置，再计入本次忘记")

    // 9. 完成 15 天档复习 → 已掌握
    var topLevel = fresh()
    topLevel.reps = SRScheduler.intervalArray.count
    topLevel.interval = SRScheduler.maxInterval
    topLevel.phase = .review
    topLevel.dueAt = now
    let mastered = SRScheduler.apply(topLevel, grade: .remembered, now: now, calendar: cal)
    t.equal(mastered.phase, .mastered, "15 天档到期再「记得」应标记已掌握")

    // 10. 当前词单的新词优先，且不会被每日新词上限截掉
    let otherA = Word(text: "alpha", deckID: "DECK-A", position: 0)
    let otherB = Word(text: "bravo", deckID: "DECK-B", position: 0)
    let current = Word(text: "current", deckID: "DECK-CUR", position: 99)
    let bag = [otherA, otherB, current]

    let plan = SRScheduler.buildQueue(words: bag,
                                      settings: AppSettings(),
                                      currentDeckID: "DECK-CUR",
                                      now: now, calendar: cal)
    t.equal(plan.queue.first?.text, "current", "当前词单新词应排在最前（即使 position 更大）")

    var limited = AppSettings()
    limited.dailyNewLimit = 1
    let limitedPlan = SRScheduler.buildQueue(words: bag,
                                             settings: limited,
                                             currentDeckID: "DECK-CUR",
                                             now: now, calendar: cal)
    t.equal(limitedPlan.queue.count, 1, "每日新词上限应生效")
    t.equal(limitedPlan.queue.first?.text, "current", "截断后保留的应仍是当前词单的新词")

    // 11. 性能基线：今日任务生成（文档第五节）
    let manyWords = (0..<1000).map { Word(text: "word\($0)", deckID: "DECK-A", position: $0) }
    t.measure("今日任务生成 · 1000 词", iterations: 5) {
        _ = SRScheduler.buildQueue(words: manyWords, settings: AppSettings(), now: now, calendar: cal)
    }
}
