//
//  WordDetailView.swift
//  RootWord · 词根单词
//
//  P10 单词详情。文档 5.12。
//
//  信息顺序 = 复习时的思考顺序：单词 → 释义 → 构词 → 记忆法 → 例句 → 我的学习数据。
//

import SwiftUI

struct WordDetailView: View {

    @EnvironmentObject private var state: AppState
    let wordID: String

    @State private var showDelete = false

    private var word: Word? { state.word(id: wordID) }

    var body: some View {
        ScrollView {
            if let word = word {
                VStack(alignment: .leading, spacing: Sp.x4) {
                    hero(word)
                    meaningCard(word)
                    if word.hasSegments { segmentCard(word) }
                    if !word.mnemonic.isEmpty { HintBlock(symbol: "lightbulb", text: word.mnemonic) }
                    if !word.examples.isEmpty { exampleCard(word) }
                    srsCard(word)
                    relatedCard(word)
                    logCard(word)
                    actionCard(word)
                }
                .padding(.horizontal, Metric.pagePadding)
                .padding(.top, Sp.x3)
                .padding(.bottom, Sp.x8)
            } else {
                EmptyStateView(symbol: "questionmark.circle",
                               title: "单词不存在",
                               message: "它可能已被删除。",
                               primaryTitle: nil, primaryAction: nil,
                               secondaryTitle: nil, secondaryAction: nil)
                    .padding(.top, Sp.x8)
            }
        }
        .background(PageBackground())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDelete) {
            if let word = word {
                DeleteWordSheet(word: word, onFinished: { showDelete = false })
                    .environmentObject(state)
            }
        }
    }

    // MARK: 头部

    private func hero(_ word: Word) -> some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            HStack(alignment: .firstTextBaseline, spacing: Sp.x2) {
                Text(word.text)
                    .dsFont(size: 30, weight: .bold, maxScale: 1.2)
                    .foregroundColor(.textPrimary)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Button(action: {
                    SpeechService.shared.speak(word.text, accent: state.settings.accent)
                }) {
                    Icon(name: "speaker.wave.2.fill", size: 18, weight: .medium, color: .brand500)
                        .frame(width: Metric.hitMin, height: Metric.hitMin)
                }
                .accessibilityLabel("朗读 \(word.text)")
            }

            HStack(spacing: Sp.x2) {
                if !word.phonetic.isEmpty {
                    Text(word.phonetic)
                        .dsFont(size: 14)
                        .foregroundColor(.textSecondary)
                }
                if !word.pos.isEmpty { PlainChip(text: word.pos, color: .brand500) }
                PlainChip(text: word.srs.phase.cnLabel, color: word.srs.phase.dotColor)
            }
        }
        .card(padding: Sp.x4)
    }

    private func meaningCard(_ word: Word) -> some View {
        SectionCard(title: "释义") {
            Text(word.displayMeaning)
                .dsFont(size: 18, weight: .semibold, maxScale: 1.2)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 构词

    private func segmentCard(_ word: Word) -> some View {
        SectionCard(title: "构词拆解", subtitle: "点词根可加入同根词练习") {
            VStack(alignment: .leading, spacing: Sp.x3) {
                HStack(spacing: Sp.x2) {
                    ForEach(word.segments) { segment in
                        RootChip(segment: segment, onTap: {
                            state.startSession(source: .rootWords(state.words(forRoot: segment.rootID ?? "").map { $0.id }))
                            if state.session == nil {
                                state.showToast("这个词根暂时没有更多单词", icon: "info.circle.fill")
                            } else {
                                state.showToast("已按「\(segment.text)」生成一组练习", icon: "play.circle.fill")
                            }
                        })
                    }
                    Spacer(minLength: 0)
                }

                Text(segmentFormula(word))
                    .dsFont(size: 13)
                    .foregroundColor(.textTertiary)
            }
        }
    }

    private func segmentFormula(_ word: Word) -> String {
        let parts = word.segments.map { "\($0.text)（\($0.meaning.isEmpty ? "—" : $0.meaning)）" }
        return "\(word.text) = " + parts.joined(separator: " + ")
    }

    // MARK: 例句

    private func exampleCard(_ word: Word) -> some View {
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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: 学习数据（算法透明化，文档 7.9）

    private func srsCard(_ word: Word) -> some View {
        let srs = word.srs
        return SectionCard(title: "学习数据", subtitle: "间隔重复算法的实时状态") {
            VStack(spacing: Sp.x3) {
                infoRow("阶段", srs.phase.cnLabel)
                infoRow("熟练度 EF", String(format: "%.2f", srs.ef))
                infoRow("当前间隔", srs.interval == 0 ? "尚未开始" : "\(srs.interval) 天")
                infoRow("下次复习", dueText(srs))
                infoRow("连续记住", "\(srs.streak) 次")
                infoRow("遗忘次数", "\(srs.lapses) 次")
                infoRow("累计复习", "\(srs.reps) 次")
            }
        }
    }

    private func dueText(_ srs: SrsState) -> String {
        if srs.phase == .new { return "还没学过" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return formatter.string(from: srs.dueAt)
    }

    private func logDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .dsFont(size: 14)
                .foregroundColor(.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .dsFont(size: 14, weight: .medium, maxScale: 1.15)
                .foregroundColor(.textPrimary)
        }
    }

    // MARK: 同根词

    @ViewBuilder
    private func relatedCard(_ word: Word) -> some View {
        let shared = relatedWords(word)
        if !shared.isEmpty {
            SectionCard(title: "同根词", subtitle: "本机共 \(shared.count) 个") {
                VStack(spacing: Sp.x2) {
                    ForEach(shared.prefix(8)) { item in
                        NavigationLink(destination: WordDetailView(wordID: item.id)) {
                            HStack(spacing: Sp.x3) {
                                Text(item.text)
                                    .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                                    .foregroundColor(.textPrimary)
                                Text(item.displayMeaning)
                                    .dsFont(size: 13)
                                    .foregroundColor(.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Icon(name: "chevron.right", size: 12, weight: .semibold, color: .textTertiary)
                            }
                            .frame(minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Button("一起练这一组") {
                        state.startSession(source: .rootWords(([word] + shared).map { $0.id }))
                        if state.session == nil {
                            state.showToast("暂时无法生成练习组", icon: "info.circle.fill", isError: true)
                        } else {
                            state.showToast("已生成一组同根词练习")
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 44))
                }
            }
        }
    }

    private func relatedWords(_ word: Word) -> [Word] {
        let ids = Set(word.segments.compactMap { $0.rootID })
        guard !ids.isEmpty else { return [] }
        return state.words.filter { other in
            other.id != word.id && !Set(other.segments.compactMap { $0.rootID }).isDisjoint(with: ids)
        }
    }

    // MARK: 学习记录

    @ViewBuilder
    private func logCard(_ word: Word) -> some View {
        let items = state.logs.filter { $0.wordID == word.id }.sorted { $0.date > $1.date }
        if !items.isEmpty {
            SectionCard(title: "复习记录", subtitle: "最近 \(min(items.count, 8)) 次") {
                VStack(spacing: Sp.x2) {
                    ForEach(items.prefix(8)) { log in
                        HStack(spacing: Sp.x3) {
                            Icon(name: log.grade == .remembered ? "checkmark" :
                                        (log.grade == .fuzzy ? "questionmark" : "arrow.uturn.left"),
                                 size: 12, weight: .semibold, color: log.grade.color)
                            Text(logDateText(log.date))
                                .dsFont(size: 13)
                                .foregroundColor(.textSecondary)
                            Spacer(minLength: 0)
                            Text(log.grade.title)
                                .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                                .foregroundColor(log.grade.color)
                            Text(log.intervalAfter == 0 ? "10 分钟" : "\(log.intervalAfter) 天")
                                .dsFont(size: 12)
                                .foregroundColor(.textTertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 操作区

    private func actionCard(_ word: Word) -> some View {
        VStack(spacing: Sp.x3) {
            Button("立刻复习这个单词") {
                state.startSession(source: .rootWords([word.id]))
                if state.session == nil {
                    state.showToast("无法生成练习", icon: "info.circle.fill", isError: true)
                }
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: Sp.x3) {
                Button("标记已掌握") {
                    state.markMastered(id: word.id)
                    state.showToast("已标记为掌握")
                }
                .buttonStyle(SecondaryButtonStyle(height: 44))

                Button("重置进度") {
                    state.resetProgress(id: word.id)
                    state.showToast("已重置学习进度")
                }
                .buttonStyle(SecondaryButtonStyle(height: 44))
            }

            HStack(spacing: Sp.x3) {
                Menu {
                    ForEach(state.decks) { deck in
                        Button(action: {
                            state.moveWord(id: word.id, toDeckID: deck.id)
                            state.showToast("已移到「\(deck.name)」")
                        }) {
                            if deck.id == word.deckID {
                                Label(deck.name, systemImage: "checkmark")
                            } else {
                                Text(deck.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Sp.x2) {
                        Icon(name: "arrow.left.arrow.right", size: 14, weight: .medium, color: .brand500)
                        Text("移到其他词单")
                            .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                            .foregroundColor(.brand500)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .fill(Color.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .stroke(Color.brand500.opacity(0.6), lineWidth: 1)
                    )
                }

                Button(action: { showDelete = true }) {
                    HStack(spacing: Sp.x2) {
                        Icon(name: "trash", size: 14, weight: .medium, color: .danger500)
                        Text("删除单词")
                            .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                            .foregroundColor(.danger500)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .fill(Color.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                            .stroke(Color.danger500.opacity(0.5), lineWidth: 1)
                    )
                }
            }
        }
    }
}
