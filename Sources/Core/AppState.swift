//
//  AppState.swift
//  RootWord · 词根单词
//
//  应用唯一的状态源（MVVM 的 ViewModel 层）：
//    · 持有 words / decks / logs / settings 四份数据
//    · 学习会话（StudySession）的装配与推进
//    · 首页、词单、统计、设置各页面的派生数据
//    · 所有写操作最终都通过 Store 落盘
//
//  依赖：Foundation + Combine（ObservableObject），零第三方。
//

import Foundation
import Combine

/// 学习会话的进入来源（决定队列装配范围）
enum SessionSource: Equatable {
    case todayPlan
    case deck(String)
    case rootWords([String])     // 「同根词一次学」（P15）

    var title: String {
        switch self {
        case .todayPlan:      return "今日任务"
        case .deck:           return "词单练习"
        case .rootWords:      return "同根词"
        }
    }
}

/// 全局轻提示（跨页面）
struct ToastMessage: Equatable, Identifiable {
    var id = UUID()
    var text: String
    var icon: String = "checkmark.circle.fill"
    var isError: Bool = false
}

@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // MARK: - 数据

    @Published private(set) var words: [Word] = []
    @Published private(set) var decks: [Deck] = []
    @Published private(set) var logs: [ReviewLog] = []
    @Published var settings = AppSettings()

    // MARK: - 会话

    @Published private(set) var session: StudySession?
    /// 会话结束页数据（P07）
    @Published var lastSummary: SessionSummary?

    // MARK: - 全局 UI 状态

    @Published var toast: ToastMessage?
    /// 数据文件损坏提示（P01 异常态）
    @Published var showCorruptionBanner = false

    private let store = Store.shared
    private var plan: QueuePlan = QueuePlan()

    private init() {}

    // MARK: - 启动

    func bootstrap() {
        store.load()
        words = store.words
        decks = store.decks
        logs = store.logs
        settings = store.settings
        showCorruptionBanner = store.wordsCorrupted
        Haptics.enabled = settings.hapticEnabled

        if decks.isEmpty {
            createSeedContent()
        }
        refreshPlan()
    }

    // MARK: - 派生：今日任务（文档 7.5）

    func refreshPlan(now: Date = Date()) {
        // 当前词单的新词优先：把当前词单的单词排到数组前面（buildQueue 保持纯函数）
        let currentID = currentDeck?.id
        let ordered = words.sorted { lhs, rhs in
            let lhsCurrent = lhs.deckID == currentID
            let rhsCurrent = rhs.deckID == currentID
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            return false
        }
        plan = SRScheduler.buildQueue(words: ordered, settings: settings, now: now)
    }

    var dueTodayCount: Int { plan.dueCount }
    var newTodayCount: Int { plan.newCount }
    var overdueCount: Int { plan.overdueCount }

    var todayTotalCount: Int { plan.dueCount + plan.newCount }

    /// 今日已学（今日的复习记录条数）
    var todayReviewedCount: Int {
        logs.filter { SRScheduler.dayKey(for: $0.date) == SRScheduler.dayKey(for: Date()) }.count
    }

    /// 今日正确率
    var todayAccuracy: Double? {
        let today = logs.filter { SRScheduler.dayKey(for: $0.date) == SRScheduler.dayKey(for: Date()) }
        guard !today.isEmpty else { return nil }
        let ok = today.filter { $0.grade == .remembered }.count
        return Double(ok) / Double(today.count)
    }

    // MARK: - 派生：词库统计

    var currentDeck: Deck? { decks.first(where: { $0.isCurrent }) ?? decks.first }

    func words(in deckID: String) -> [Word] {
        words.filter { $0.deckID == deckID }.sorted { $0.position < $1.position }
    }

    var masteredCount: Int { words.filter { $0.srs.phase == .mastered }.count }
    var learningCount: Int { words.filter { $0.srs.phase == .learning || $0.srs.phase == .relearning }.count }
    var reviewCount: Int { words.filter { $0.srs.phase == .review }.count }
    var newCount: Int { words.filter { $0.srs.phase == .new }.count }

    /// 平均难易因子（统计页展示，1.3–2.8 映射为百分比）
    var averageEF: Double {
        let studied = words.filter { $0.srs.phase != .new }
        guard !studied.isEmpty else { return 2.5 }
        return studied.map { $0.srs.ef }.reduce(0, +) / Double(studied.count)
    }

    /// 连续学习天数（按 04:00 日界）
    var streakDays: Int {
        let keys = Set(logs.map { SRScheduler.dayKey(for: $0.date) })
        guard !keys.isEmpty else { return 0 }
        var count = 0
        var cursor = Date()
        let formatterKey = SRScheduler.dayKey(for: cursor)
        if !keys.contains(formatterKey) {
            // 今天还没学：从昨天开始算
            cursor = cursor.addingTimeInterval(-86_400)
        }
        while keys.contains(SRScheduler.dayKey(for: cursor)) {
            count += 1
            cursor = cursor.addingTimeInterval(-86_400)
        }
        return count
    }

    /// 最近的复习热力图（最近 84 天 = 12 周 × 7 天，供 HeatmapGrid 使用）
    func heatmapData() -> [(date: Date, count: Int)] {
        var result: [(date: Date, count: Int)] = []
        let today = SRScheduler.studyDayStart(Date())
        let counts = Dictionary(grouping: logs) { SRScheduler.dayKey(for: $0.date) }
            .mapValues { $0.count }
        for offset in stride(from: 83, through: 0, by: -1) {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = SRScheduler.dayKey(for: day)
            result.append((date: day, count: counts[key] ?? 0))
        }
        return result
    }

    /// 未来 7 天复习量预测（统计页柱状图）
    func forecast() -> [(date: Date, count: Int)] {
        SRScheduler.forecast(words: words, days: 7)
    }

    /// 最近 N 天的正确率曲线
    func accuracyTrend(days: Int = 14) -> [(date: Date, value: Double?)] {
        var result: [(date: Date, value: Double?)] = []
        let today = SRScheduler.studyDayStart(Date())
        let grouped = Dictionary(grouping: logs) { SRScheduler.dayKey(for: $0.date) }
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: today) else { continue }
            let items = grouped[SRScheduler.dayKey(for: day)] ?? []
            if items.isEmpty {
                result.append((date: day, value: nil))
            } else {
                let ok = items.filter { $0.grade == .remembered }.count
                result.append((date: day, value: Double(ok) / Double(items.count)))
            }
        }
        return result
    }

    /// 累计学习天数（有记录的天数）
    var totalStudyDays: Int {
        Set(logs.map { SRScheduler.dayKey(for: $0.date) }).count
    }

    var totalReviews: Int { logs.count }

    /// 词根聚合：rootEntry → 本机命中的单词（文档 7.6.5 反向索引）
    func rootAggregation() -> [(entry: RootEntry, words: [Word])] {
        var bucket: [String: [Word]] = [:]
        for word in words {
            for id in Set(RootParser.rootIDs(in: word.segments)) {
                bucket[id, default: []].append(word)
            }
        }
        return RootLibrary.shared.entries.compactMap { entry in
            guard let list = bucket[entry.id], !list.isEmpty else { return nil }
            return (entry, list)
        }
        .sorted { $0.1.count > $1.1.count }
    }

    func words(forRoot id: String) -> [Word] {
        words.filter { RootParser.rootIDs(in: $0.segments).contains(id) }
    }

    // MARK: - 学习会话

    /// 当前会话正在展示的单词（会话结束或数据缺失时为 nil）
    var currentWord: Word? {
        guard let id = session?.currentID else { return nil }
        return words.first(where: { $0.id == id })
    }

    func word(id: String) -> Word? {
        words.first(where: { $0.id == id })
    }

    /// 剩余队列中还未评分的词数（含被重插的）
    var remainingInSession: Int {
        guard let s = session else { return 0 }
        return max(0, s.queue.count - s.index)
    }

    func startSession(source: SessionSource, now: Date = Date()) {
        var queue: [String] = []

        switch source {
        case .todayPlan:
            refreshPlan(now: now)
            queue = plan.queue.map { $0.id }

        case .deck(let deckID):
            let scope = words(in: deckID)
            let scopedPlan = SRScheduler.buildQueue(words: scope, settings: settings, now: now)
            queue = scopedPlan.queue.map { $0.id }
            applyPlanState(scopedPlan)

        case .rootWords(let ids):
            let scope = words.filter { ids.contains($0.id) }
            let scopedPlan = SRScheduler.buildQueue(words: scope, settings: settings, now: now)
            queue = scopedPlan.queue.map { $0.id }
            applyPlanState(scopedPlan)
        }

        guard !queue.isEmpty else { return }
        session = StudySession(queue: queue, startedAt: now, plannedCount: queue.count)
        lastSummary = nil
    }

    /// 会话内「跳过」：仅把当前词挪到队尾，不写记录
    func skipCurrent() {
        guard var s = session, let id = s.currentID else { return }
        s.queue.remove(at: s.index)
        s.queue.append(id)
        session = s
    }

    /// 评分：核心写路径（文档 7.3 + 7.5）
    func grade(_ value: Grade) {
        guard var s = session, let id = s.currentID,
              let index = words.firstIndex(where: { $0.id == id }) else { return }

        let now = Date()
        let word = words[index]
        let isNew = (word.srs.phase == .new)
        let next = SRScheduler.apply(word.srs, grade: value, now: now)

        words[index].srs = next

        logs.append(ReviewLog(wordID: word.id,
                              deckID: word.deckID,
                              date: now,
                              grade: value,
                              intervalAfter: next.interval,
                              phaseAfter: next.phase,
                              isNewWord: isNew))

        // 统计
        switch value {
        case .forgot:     s.forgot += 1
        case .fuzzy:      s.fuzzy += 1
        case .remembered: s.remembered += 1
        }

        // 「忘记」当日重插：把该词放回队列尾部，让它在 10 分钟后（或本轮末尾）再出现
        if value == .forgot && next.reinsertCountToday <= SRScheduler.maxReinsertPerDay {
            s.queue.append(id)
        }
        // 「模糊」且间隔仍为 1 天：本次会话内再练一次（文档 7.3 第 5 条）
        if value == .fuzzy && next.interval == 1 {
            s.queue.append(id)
        }

        s.index += 1
        session = s

        Haptics.feedback(for: value)
        persist()
        refreshPlan()

        if s.isFinished {
            finishSession()
        }
    }

    func finishSession() {
        guard let s = session else { return }
        let summary = SessionSummary(
            total: s.plannedCount,
            remembered: s.remembered,
            fuzzy: s.fuzzy,
            forgot: s.forgot,
            duration: Date().timeIntervalSince(s.startedAt)
        )
        lastSummary = summary
        session = nil
        persist(sync: true)
    }

    func abortSession() {
        session = nil
    }

    // MARK: - 词单管理

    @discardableResult
    func createDeck(name: String, makeCurrent: Bool = false) -> Deck {
        let deck = Deck(name: name, isCurrent: decks.isEmpty || makeCurrent)
        if deck.isCurrent {
            for i in decks.indices { decks[i].isCurrent = false }
        }
        decks.append(deck)
        persist()
        return deck
    }

    func renameDeck(id: String, to name: String) {
        guard let index = decks.firstIndex(where: { $0.id == id }) else { return }
        decks[index].name = name
        persist()
    }

    func setCurrentDeck(id: String) {
        for index in decks.indices {
            decks[index].isCurrent = (decks[index].id == id)
        }
        persist()
        refreshPlan()
    }

    /// 删除词单；deleteWords = true 时连同词单内单词一并移除（用户需二次确认）
    func deleteDeck(id: String, deleteWords: Bool) {
        decks.removeAll { $0.id == id }
        if deleteWords {
            words.removeAll { $0.deckID == id }
            logs.removeAll { $0.deckID == id }
        } else {
            // 保留单词但归属到「未分类」词单
            let fallback = decks.first(where: { $0.isBuiltIn })?.id ?? decks.first?.id ?? ""
            for index in words.indices where words[index].deckID == id {
                words[index].deckID = fallback
            }
        }
        if !decks.contains(where: { $0.isCurrent }), !decks.isEmpty {
            decks[0].isCurrent = true
        }
        persist(sync: true)
        refreshPlan()
    }

    // MARK: - 单词管理

    func deleteWord(id: String) {
        words.removeAll { $0.id == id }
        logs.removeAll { $0.wordID == id }
        persist(sync: true)
        refreshPlan()
    }

    /// 重置进度（回到新词状态）
    func resetProgress(id: String) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        words[index].srs = SRScheduler.makeNewState()
        persist()
        refreshPlan()
    }

    /// 「标记为已掌握」（P10 操作）
    func markMastered(id: String) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        words[index].srs.phase = .mastered
        words[index].srs.interval = SRScheduler.masteredInterval
        words[index].srs.dueAt = SRScheduler.dueDate(intervalDays: SRScheduler.maxInterval, from: Date())
        persist()
        refreshPlan()
    }

    /// 「稍后学」（把该词移到词单末尾）
    func moveToEnd(id: String) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        let deckID = words[index].deckID
        let maxPosition = words.filter { $0.deckID == deckID }.map { $0.position }.max() ?? 0
        words[index].position = maxPosition + 1
        persist()
    }

    func moveWord(id: String, toDeckID: String) {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return }
        let maxPosition = words.filter { $0.deckID == toDeckID }.map { $0.position }.max() ?? -1
        words[index].deckID = toDeckID
        words[index].position = maxPosition + 1
        persist()
    }

    /// 导入预览 → 确认写入
    func commitImport(_ result: ImportResult, toDeckID deckID: String, now: Date = Date()) {
        let start = (words.filter { $0.deckID == deckID }.map { $0.position }.max() ?? -1) + 1
        let newWords = Importer.makeWords(from: result, deckID: deckID, startPosition: start, now: now)
        words.append(contentsOf: newWords)
        persist(sync: true)
        refreshPlan()
    }

    func existingWordsByKey() -> [String: Word] {
        var map: [String: Word] = [:]
        for word in words {
            map[Importer.normalizeKey(word.text)] = word
        }
        return map
    }

    // MARK: - 设置

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        copy.normalize()
        settings = copy
        Haptics.enabled = copy.hapticEnabled
        persist()
        refreshPlan()
    }

    /// 导出备份：成功返回文件 URL；失败返回 nil 并带回可直接展示的原因
    /// （旧实现只返回 URL?，失败时 UI 只能给一句笼统的「导出失败」，用户不知道发生了什么）
    func exportBackup() -> (url: URL?, error: String?) {
        let url = store.exportBackup(words: words, decks: decks, logs: logs, settings: settings)
        return (url, url == nil ? (store.lastWriteError ?? "导出失败，请稍后重试") : nil)
    }

    // MARK: - 从备份恢复（P18 数据管理）

    /// 只读校验备份文件，不改动任何现有数据。供 UI 在二次确认前展示
    /// 「备份里有什么、会覆盖掉什么」。
    func readBackup(from url: URL) throws -> Store.BackupFile {
        try store.importBackup(from: url)
    }

    /// 用备份**覆盖**当前全部数据（破坏性操作，调用前必须已完成二次确认）。
    /// 恢复后同步刷新内存状态、落盘并重建今日队列，保证界面立刻反映备份内容。
    func restoreBackup(_ backup: Store.BackupFile) {
        // 先做数据体检（补词单 / 修「当前词单」不变量 / 收拢孤儿单词），再整体覆盖
        let restored = backup.sanitizedForRestore()

        words = restored.words
        decks = restored.decks
        logs = restored.logs
        settings = restored.settings
        settings.normalize()
        // 备份可能是很久以前的：恢复不该把已经在用 App 的用户踢回引导页
        settings.hasCompletedOnboarding = true
        Haptics.enabled = settings.hapticEnabled

        store.persistSync(words: words, decks: decks, logs: logs, settings: settings)
        // 会话与结算页里可能还挂着旧单词的 id，必须清掉再重建队列
        session = nil
        lastSummary = nil
        refreshPlan()
    }

    /// 清空全部数据（先自动备份，再清空 —— 文档 5.13）。
    /// - Returns: 自动备份是否成功落盘；失败时由 UI 明确提示「数据已清空但没留下备份」。
    @discardableResult
    func wipeAllData() -> Bool {
        let backupURL = store.autoBackupBeforeWipe(words: words, decks: decks, logs: logs, settings: settings)
        words = []
        decks = []
        logs = []
        settings = AppSettings()
        store.wipeAllFiles()
        store.persistSync(words: [], decks: [], logs: [], settings: settings)
        createSeedContent()
        persist(sync: true)
        refreshPlan()
        return backupURL != nil
    }

    func clearHistory() {
        logs = []
        store.clearLogsFile()
        persist(sync: true)
    }

    func resetWordProgress() {
        for index in words.indices {
            words[index].srs = SRScheduler.makeNewState()
        }
        logs = []
        persist(sync: true)
        refreshPlan()
    }

    // MARK: - 提示

    func showToast(_ text: String, icon: String = "checkmark.circle.fill", isError: Bool = false) {
        toast = ToastMessage(text: text, icon: icon, isError: isError)
    }

    // MARK: - 落盘

    private func applyPlanState(_ plan: QueuePlan) {
        for word in plan.updatedWords {
            if let index = words.firstIndex(where: { $0.id == word.id }) {
                words[index].srs = word.srs
            }
        }
    }

    func persist(sync: Bool = false) {
        if sync {
            store.persistSync(words: words, decks: decks, logs: logs, settings: settings)
        } else {
            store.persist(words: words, decks: decks, logs: logs, settings: settings)
        }
    }

    // MARK: - 示例内容（首次启动 / 用户主动创建）

    private func createSeedContent() {
        var seeded = Deck(name: "入门示例词表", isBuiltIn: true, isCurrent: true)
        seeded.note = "20 个最常用的构词示例，用来体验词根拆解"
        decks.append(seeded)

        var uncategorized = Deck(name: "未分类", isBuiltIn: true)
        uncategorized.note = "删除词单后保留下来的单词会归到这里"
        decks.append(uncategorized)

        words.append(contentsOf: Self.makeSeedWords(deckID: seeded.id, startPosition: 0))
        settings.hasImportedSeed = true
        persist(sync: true)
    }

    /// 用户主动「使用示例词表」（P03 空状态）
    @discardableResult
    func addSampleDeck() -> Deck {
        let deck = createDeck(name: "入门示例词表", makeCurrent: true)
        let start = words.filter { $0.deckID == deck.id }.count
        words.append(contentsOf: Self.makeSeedWords(deckID: deck.id, startPosition: start))
        settings.hasImportedSeed = true
        persist(sync: true)
        refreshPlan()
        return deck
    }

    static func makeSeedWords(deckID: String, startPosition: Int) -> [Word] {
        let seed: [(String, String, String, String)] = [
            ("unhappy", "不快乐的", "/ʌnˈhæpi/", "adj."),
            ("impossible", "不可能的", "/ɪmˈpɒsəbl/", "adj."),
            ("teacher", "老师", "/ˈtiːtʃə(r)/", "n."),
            ("international", "国际的", "/ˌɪntəˈnæʃnəl/", "adj."),
            ("spectator", "观众", "/spekˈteɪtə(r)/", "n."),
            ("preview", "预览", "/ˈpriːvjuː/", "n."),
            ("replay", "重播；重放", "/ˌriːˈpleɪ/", "v."),
            ("export", "出口；导出", "/ɪkˈspɔːt/", "v."),
            ("import", "进口；导入", "/ɪmˈpɔːt/", "v."),
            ("dislike", "不喜欢", "/dɪsˈlaɪk/", "v."),
            ("useful", "有用的", "/ˈjuːsfl/", "adj."),
            ("careful", "仔细的", "/ˈkeəfl/", "adj."),
            ("happiness", "幸福", "/ˈhæpinəs/", "n."),
            ("invention", "发明", "/ɪnˈvenʃn/", "n."),
            ("creative", "有创造力的", "/kriˈeɪtɪv/", "adj."),
            ("support", "支持", "/səˈpɔːt/", "v."),
            ("protect", "保护", "/prəˈtekt/", "v."),
            ("dictation", "听写", "/dɪkˈteɪʃn/", "n."),
            ("biography", "传记", "/baɪˈɒɡrəfi/", "n."),
            ("telephone", "电话", "/ˈtelɪfəʊn/", "n.")
        ]

        var created: [Word] = []
        for (offset, item) in seed.enumerated() {
            let segments = RootParser.parse(item.0)
            var word = Word(text: item.0,
                            meaning: item.1,
                            phonetic: item.2,
                            pos: item.3,
                            segments: segments.count >= 2 ? segments : [],
                            mnemonic: RootParser.makeMnemonic(segments: segments, meaning: item.1),
                            deckID: deckID,
                            position: startPosition + offset)
            word.srs = SRScheduler.makeNewState()
            created.append(word)
        }
        return created
    }
}

// MARK: - 会话小结（P07 结果页）

struct SessionSummary: Equatable {
    var total: Int
    var remembered: Int
    var fuzzy: Int
    var forgot: Int
    var duration: TimeInterval

    var accuracy: Double {
        guard total > 0 else { return 0 }
        return Double(remembered) / Double(total)
    }

    var accuracyText: String { "\(Int((accuracy * 100).rounded()))%" }

    var durationText: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes <= 0 { return "\(seconds) 秒" }
        return "\(minutes) 分 \(seconds) 秒"
    }
}
