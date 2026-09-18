//
//  StudyView.swift
//  RootWord · 词根单词
//
//  P04 学习会话 · 卡片正面 / P05 卡片背面 / P06 会话完成页。文档 5.4–5.6。
//
//  交互约定：
//    · 正面只给「单词 + 音标 + 发音」，强制主动回忆，绝不提前显示释义
//    · 点击卡片翻转，0.45 秒 easeInOut 3D 翻转
//    · 背面按「词根拆解 → 记忆法 → 例句」自上而下，评分按钮固定在底部
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
                ScrollView {
                    VStack(spacing: Sp.x4) {
                        card(for: word)
                        if revealed, word.hasSegments {
                            segmentSection(for: word)
                        }
                        if revealed, !word.mnemonic.isEmpty {
                            HintBlock(symbol: "lightbulb", text: word.mnemonic)
                        }
                        if revealed, !word.examples.isEmpty {
                            exampleSection(for: word)
                        }
                    }
                    .padding(.horizontal, Metric.pagePadding)
                    .padding(.top, Sp.x2)
                    .padding(.bottom, Sp.x6)
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

    // MARK: 卡片（正反面）

    private func card(for word: Word) -> some View {
        ZStack {
            if revealed {
                backFace(for: word)
            } else {
                frontFace(for: word)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 300)
        .card(padding: Sp.x5)
        .rotation3DEffect(.degrees(revealed ? 0 : 0), axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.45), value: revealed)
        .contentShape(Rectangle())
        .onTapGesture {
            if !revealed {
                revealed = true
                Haptics.selection()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func frontFace(for word: Word) -> some View {
        VStack(spacing: Sp.x4) {
            Text(word.text)
                .dsFont(size: 40, weight: .bold, maxScale: 1.25)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)

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

            Spacer(minLength: Sp.x3)

            HStack(spacing: Sp.x2) {
                Icon(name: "hand.tap", size: 13, weight: .medium, color: .textTertiary)
                Text("先在心里说出意思，再点卡片")
                    .dsFont(size: 13)
                    .foregroundColor(.textTertiary)
            }
            .padding(.top, Sp.x2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Sp.x4)
    }

    private func backFace(for word: Word) -> some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            HStack(alignment: .firstTextBaseline, spacing: Sp.x2) {
                Text(word.text)
                    .dsFont(size: 26, weight: .bold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                if !word.pos.isEmpty {
                    PlainChip(text: word.pos, color: .brand500)
                }
                Spacer(minLength: 0)
                Button(action: { speak(word) }) {
                    Icon(name: "speaker.wave.2.fill", size: 16, weight: .medium, color: .brand500)
                        .frame(width: Metric.hitMin, height: Metric.hitMin)
                }
                .accessibilityLabel("朗读 \(word.text)")
            }

            Text(word.displayMeaning)
                .dsFont(size: 20, weight: .semibold, maxScale: 1.2)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: Sp.x2) {
                Icon(name: "textformat.abc", size: 13, weight: .medium, color: .textTertiary)
                Text(word.hasSegments ? "构词拆解" : "暂无构词信息")
                    .dsFont(size: 13, weight: .semibold)
                    .foregroundColor(.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 词根拆解（P05 核心）

    private func segmentSection(for word: Word) -> some View {
        SectionCard(title: "拆开看", subtitle: "点词根可查看同根词") {
            HStack(spacing: Sp.x2) {
                ForEach(word.segments) { segment in
                    RootChip(segment: segment, onTap: { showRootWords(segment: segment) })
                }
                Spacer(minLength: 0)
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

    // MARK: 底部（翻转提示 / 三档评分）

    @ViewBuilder
    private func bottomArea(for word: Word) -> some View {
        VStack(spacing: Sp.x3) {
            if revealed {
                HStack(spacing: Sp.x3) {
                    gradeButton(.forgot, word: word)
                    gradeButton(.fuzzy, word: word)
                    gradeButton(.remembered, word: word)
                }
                .padding(.horizontal, Metric.pagePadding)

                Button("跳过这个") { state.skipCurrent() }
                    .dsFont(size: 14)
                    .foregroundColor(.textTertiary)
                    .frame(minHeight: 36)
                    .accessibilityHint("把当前单词放到本组最后")
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
            .frame(height: 58)
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
