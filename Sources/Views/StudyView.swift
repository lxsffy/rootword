//
//  StudyView.swift
//  RootWord · 词根单词
//
//  P04 学习会话 · 固定锚点答题页 / P06 会话完成页。文档 5.4–5.6。
//
//  交互约定（显示答案前后共用同一固定骨架）：
//    · 顶部锚点固定：单词 + 音标 + 听发音按钮，位置与大小不随答案出现而改变
//    · 显示答案前只给「单词 + 发音 + 回忆提示」，强制主动回忆，绝不提前显示释义
//    · 显示答案后在听发音按钮下方居中展开「词性 + 中文释义」→ 词根拆解卡片 → 记忆法 → 例句
//    · 底部操作区固定高度：显示答案前为「显示答案」，显示答案后同高度替换为「忘记 / 模糊 / 记得」
//    · 仅中间内容超界时内部滚动，顶部锚点与底部操作区固定
//    · 三档评分按钮常驻显示下次出现时间（intervalAfter 预览）
//

import SwiftUI

struct StudyView: View {

    @EnvironmentObject private var state: AppState
    var onExit: () -> Void

    @State private var revealed = false
    @State private var lastWordID: String = ""

    private var word: Word? { state.currentWord }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let word = word {
                // 固定锚点：单词 + 听发音按钮。显示答案前后位置与大小完全一致，
                // 答案出现只向下展开内容，不重排顶部，避免快速背诵时视线跳变。
                wordAnchor(for: word)

                // 中间内容区：仅超界时内部滚动；顶部锚点与底部操作区保持固定。
                // 显示答案后：主卡（含释义）下方留出明显间距，词根卡 → 弱化提示 → 例句依次排布。
                ScrollView {
                    VStack(spacing: Sp.x5) {
                        if revealed {
                            if word.hasSegments {
                                segmentSection(for: word)
                            }
                            if !word.mnemonic.isEmpty {
                                meaningHint(word.mnemonic)
                            }
                            if !word.examples.isEmpty {
                                exampleSection(for: word)
                            }
                        } else {
                            recallHint
                        }
                    }
                    .padding(.horizontal, Metric.pagePadding)
                    .padding(.top, revealed ? Sp.x6 : Sp.x3)
                    .padding(.bottom, Sp.x6)
                    .animation(.easeInOut(duration: 0.25), value: revealed)
                }

                bottomArea(for: word)
            } else {
                Spacer()
                EmptyStateView(symbol: "checkmark.circle",
                               title: "本组已学完",
                               message: "正在生成结果…",
                               primaryTitle: "查看结果",
                               primaryAction: { state.finishSession() },
                               secondaryTitle: nil,
                               secondaryAction: nil)
                Spacer()
            }
        }
        .background(PageBackground())
        .onAppear { prepareAudio(for: word) }
        .onChange(of: state.session?.index) { _ in
            revealed = false
            prepareAudio(for: state.currentWord)
        }
    }

    // MARK: 顶栏（进度 + 退出）

    private var topBar: some View {
        VStack(spacing: Sp.x2) {
            HStack(spacing: Sp.x3) {
                Button(action: askExit) {
                    Icon(name: "xmark", size: 15, weight: .semibold, color: .textSecondary)
                        .frame(width: Metric.hitMin, height: Metric.hitMin)
                }
                .accessibilityLabel("退出学习")

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.disabledFill)
                        Capsule()
                            .fill(Color.brandGradient)
                            .frame(width: max(6, geo.size.width * progressValue))
                            .animation(.easeOut(duration: 0.25), value: progressValue)
                    }
                }
                .frame(height: 6)

                Text(progressText)
                    .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textSecondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .padding(.horizontal, Sp.x3)
            .padding(.top, Sp.x2)

            if let session = state.session, session.remembered + session.fuzzy + session.forgot > 0 {
                // 轻量过程反馈：不显示"对/错"，只显示三档计数，避免焦虑
                HStack(spacing: Sp.x4) {
                    countChip(symbol: "arrow.uturn.left", value: session.forgot, color: .danger500)
                    countChip(symbol: "questionmark", value: session.fuzzy, color: .warning500)
                    countChip(symbol: "checkmark", value: session.remembered, color: .success500)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, Metric.pagePadding)
            }
        }
    }

    private func countChip(symbol: String, value: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Icon(name: symbol, size: 11, weight: .semibold, color: color)
            Text("\(value)")
                .dsFont(size: 12, weight: .semibold, maxScale: 1.1)
                .foregroundColor(color)
        }
    }

    private var progressValue: Double {
        state.session?.progressValue ?? 0
    }

    private var progressText: String {
        state.session?.progressText ?? "0/0"
    }

    // MARK: 固定锚点（单词 + 听发音按钮）

    /// 显示答案前后共用同一顶部骨架：单词与发音入口的位置、大小完全一致。
    /// 点击整块（未显示答案时）等同于「显示答案」，保留原有"再点卡片"交互。
    private func wordAnchor(for word: Word) -> some View {
        VStack(spacing: Sp.x4) {
            Text(word.text)
                .dsFont(size: 40, weight: .bold, maxScale: 1.25)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)

            if !word.phonetic.isEmpty {
                Text(word.phonetic)
                    .dsFont(size: 15)
                    .foregroundColor(.textSecondary)
            }

            Button(action: { speak(word) }) {
                HStack(spacing: Sp.x2) {
                    Icon(name: "speaker.wave.2.fill", size: 15, weight: .medium, color: .brand500)
                    Text("听发音")
                        .dsFont(size: 14, weight: .medium, maxScale: 1.15)
                        .foregroundColor(.brand500)
                }
                .padding(.horizontal, Sp.x4)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(Color.brand500.opacity(0.10))
                )
            }
            .buttonStyle(PressScaleStyle(scale: 0.96))

            // 显示答案后：词性 + 中文释义内聚进同一张主卡，居中展开在听发音按钮下方。
            // 单词与按钮位置保持不动，卡片向下展开，保证快速背诵时视线不跳变。
            if revealed {
                meaningBlock(for: word)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Sp.x4)
        .card(padding: Sp.x5)
        .padding(.horizontal, Metric.pagePadding)
        .padding(.top, Sp.x2)
        .contentShape(Rectangle())
        .onTapGesture {
            if !revealed {
                revealed = true
                Haptics.selection()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: 释义 + 词性（主卡内聚，居中整块）

    /// 显示答案后内聚进主卡内部、听发音按钮下方：细分隔线 + 词性胶囊 + 中文释义，整体居中。
    /// 词性标签取词库 pos 字段；无 pos 时隐藏标签，释义仍保持居中。
    private func meaningBlock(for word: Word) -> some View {
        VStack(spacing: Sp.x4) {
            Rectangle()
                .fill(Color.border)
                .frame(height: 1)
                .opacity(0.5)

            HStack(spacing: Sp.x2) {
                if !word.pos.isEmpty {
                    Text(word.pos)
                        .dsFont(size: 14, weight: .semibold, maxScale: 1.2)
                        .foregroundColor(.brand500)
                        .padding(.horizontal, Sp.x2)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(Color.brand500.opacity(0.10))
                        )
                }
                Text(word.displayMeaning)
                    .dsFont(size: 22, weight: .semibold, maxScale: 1.2)
                    .foregroundColor(.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 拼合提示（浅灰弱化，置于词根卡之后）

    /// 记忆法 / 拼合提示：`com（共同、一起）+ fid（信任）+ ence（名词：状态）→ 释义`。
    /// 视觉层级最弱：浅灰背景、小字、灰字，与主卡（高密度）和词根卡（次之）形成递减。
    private func meaningHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Sp.x2) {
            Icon(name: "lightbulb", size: 13, weight: .medium, color: .textTertiary)
            Text(text)
                .dsFont(size: 13)
                .foregroundColor(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Sp.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Color.surfaceAlt)
        )
    }

    // MARK: 回忆提示（显示答案前）

    private var recallHint: some View {
        HStack(spacing: Sp.x2) {
            Icon(name: "hand.tap", size: 13, weight: .medium, color: .textTertiary)
            Text("先在心里说出意思，再点卡片")
                .dsFont(size: 13)
                .foregroundColor(.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Sp.x2)
    }

    // MARK: 词根拆解（P05 核心）

    private func segmentSection(for word: Word) -> some View {
        // 兜底卡：未拆解出词根的基础词/词组（单段 other）以说明文案展示，其余正常出词根卡
        let fallback = word.segments.count == 1 && word.segments[0].type == .other
        return SectionCard(title: "拆开看",
                           subtitle: fallback ? "基础词或词组，暂无可拆解词根" : "点词根可查看同根词") {
            if fallback {
                HStack(spacing: Sp.x2) {
                    Icon(name: "textformat", size: 13, weight: .medium, color: .textTertiary)
                    Text("未找到常见词根，建议按整体记忆")
                        .dsFont(size: 13)
                        .foregroundColor(.textTertiary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: Sp.x2) {
                    ForEach(word.segments) { segment in
                        RootChip(segment: segment, onTap: { showRootWords(segment: segment) })
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func showRootWords(segment: WordSegment) {
        guard let rootID = segment.rootID, let entry = RootLibrary.shared.entry(id: rootID) else {
            state.showToast("这个部分暂未收录词根库", icon: "info.circle.fill")
            return
        }
        let matches = state.words(forRoot: entry.id)
        guard matches.count >= 2 else {
            state.showToast("\(entry.form) 目前只带出 \(matches.count) 个单词", icon: "info.circle.fill")
            return
        }
        ConfirmCenter.shared.ask(ConfirmRequest(
            title: "同根词 · \(entry.form)",
            message: "\(entry.meaning)。本机有 \(matches.count) 个单词含这个词根，要现在就一起练一遍吗？",
            confirmTitle: "一起学",
            destructive: false,
            requiresTyping: nil,
            action: {
                state.startSession(source: .rootWords(matches.map { $0.id }))
                Haptics.success()
            }))
    }

    // MARK: 例句

    private func exampleSection(for word: Word) -> some View {
        SectionCard(title: "例句") {
            VStack(alignment: .leading, spacing: Sp.x3) {
                ForEach(word.examples) { example in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(example.en)
                            .dsFont(size: 15)
                            .foregroundColor(.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !example.cn.isEmpty {
                            Text(example.cn)
                                .dsFont(size: 13)
                                .foregroundColor(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: 底部（固定高度操作区）

    /// 底部操作区固定高度：显示答案前为「显示答案」按钮；
    /// 显示答案后在同一高度、同一纵向位置替换为「忘记 / 模糊 / 记得」三按钮，
    /// 手指无需上下移动。已移除「跳过这个」入口。
    @ViewBuilder
    private func bottomArea(for word: Word) -> some View {
        VStack(spacing: 0) {
            if revealed {
                HStack(spacing: Sp.x3) {
                    gradeButton(.forgot, word: word)
                    gradeButton(.fuzzy, word: word)
                    gradeButton(.remembered, word: word)
                }
                .padding(.horizontal, Metric.pagePadding)
            } else {
                Button("显示答案") { revealed = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, Metric.pagePadding)
            }
        }
        .padding(.top, Sp.x2)
        .padding(.bottom, Sp.x5)
        .background(Color.bg)
    }

    private func gradeButton(_ grade: Grade, word: Word) -> some View {
        let preview = SRScheduler.previewLabel(word.srs, grade: grade)
        return Button(action: { gradeWord(grade) }) {
            VStack(spacing: 4) {
                Text(grade.title)
                    .dsFont(size: 16, weight: .semibold, maxScale: 1.2)
                    .foregroundColor(.white)
                Text(preview)
                    .dsFont(size: 11, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metric.primaryButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(grade.color)
            )
        }
        .buttonStyle(PressScaleStyle(scale: 0.95))
        .accessibilityLabel("\(grade.title)，下次出现时间 \(preview)")
    }

    // MARK: 行为

    private func gradeWord(_ grade: Grade) {
        if grade == .forgot {
            state.showToast("没关系，10 分钟后它会再出现一次", icon: "arrow.uturn.left", isError: false)
        }
        state.grade(grade)
    }

    private func prepareAudio(for word: Word?) {
        guard let word = word else { return }
        guard state.settings.autoPlayAudio else { return }
        guard lastWordID != word.id else { return }
        lastWordID = word.id
        SpeechService.shared.speak(word.text, accent: state.settings.accent)
    }

    private func speak(_ word: Word) {
        SpeechService.shared.speak(word.text, accent: state.settings.accent)
    }

    private func askExit() {
        ConfirmCenter.shared.ask(ConfirmRequest(
            title: "退出学习？",
            message: "本次已评分的单词会保留，未评分的部分不会记录。",
            confirmTitle: "退出",
            destructive: false,
            requiresTyping: nil,
            action: {
                SpeechService.shared.stop()
                state.abortSession()
                state.lastSummary = nil
                onExit()
            }))
    }
}

// MARK: - P06 会话完成页

struct SessionSummaryView: View {

    @EnvironmentObject private var state: AppState
    var summary: SessionSummary
    var onDone: () -> Void
    var onAgain: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Sp.x5) {
                VStack(spacing: Sp.x3) {
                    ZStack {
                        Circle().fill(Color.success500.opacity(0.12)).frame(width: 84, height: 84)
                        Icon(name: "checkmark", size: 34, weight: .bold, color: .success500)
                    }
                    .padding(.top, Sp.x5)

                    Text("这一组完成了")
                        .dsFont(size: 22, weight: .bold, maxScale: 1.15)
                        .foregroundColor(.textPrimary)

                    Text("共 \(summary.total) 张 · 用时 \(summary.durationText)")
                        .dsFont(size: 14)
                        .foregroundColor(.textSecondary)
                }

                HStack(spacing: Sp.x3) {
                    StatCard(title: "正确率", value: summary.accuracyText, color: .success500)
                    StatCard(title: "总张数", value: "\(summary.total)", color: .brand500)
                }

                SectionCard(title: "本次明细") {
                    VStack(spacing: Sp.x3) {
                        detailRow(title: "记得", value: summary.remembered, color: .success500, symbol: "checkmark")
                        detailRow(title: "模糊", value: summary.fuzzy, color: .warning500, symbol: "questionmark")
                        detailRow(title: "忘记", value: summary.forgot, color: .danger500, symbol: "arrow.uturn.left")
                    }
                }

                if let next = nextReviewText {
                    HintBlock(symbol: "clock", text: next)
                }

                VStack(spacing: Sp.x3) {
                    Button("再学一组", action: onAgain)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(state.todayTotalCount == 0)
                    Button("回到首页", action: onDone)
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationBarHidden(true)
        .onAppear { Haptics.success() }
    }

    private func detailRow(title: String, value: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: Sp.x3) {
            Icon(name: symbol, size: 13, weight: .semibold, color: color)
            Text(title)
                .dsFont(size: 15)
                .foregroundColor(.textPrimary)
            Spacer(minLength: 0)
            Text("\(value)")
                .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                .foregroundColor(color)
        }
    }

    private var nextReviewText: String? {
        let items = state.forecast()
        guard items.count > 1 else { return nil }
        return "明天预计还有 \(items[1].count) 个单词需要复习。"
    }
}
