//
//  RootLibraryView.swift
//  RootWord · 词根单词
//
//  P14 词根库 / P15 词根详情。文档 5.18、5.19、7.6。
//
//  词根库是只读资源，页面只做「检索 + 反向索引」：找出本机哪些单词命中同一个词根。
//

import SwiftUI

// MARK: - P14 词根库

struct RootLibraryView: View {

    @EnvironmentObject private var state: AppState

    @State private var keyword = ""
    @State private var typeFilter: RootType? = nil
    @State private var sortByHits = true

    private var aggregation: [(entry: RootEntry, words: [Word])] {
        var items = state.rootAggregation()
        if let type = typeFilter {
            items = items.filter { $0.entry.type == type }
        }
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            items = items.filter {
                $0.entry.form.localizedCaseInsensitiveContains(trimmed) ||
                $0.entry.meaning.localizedCaseInsensitiveContains(trimmed)
            }
        }
        if sortByHits {
            items.sort { $0.words.count > $1.words.count }
        } else {
            items.sort { $0.entry.form < $1.entry.form }
        }
        return items
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Sp.x3) {
                searchField
                typeRow
                summaryLine

                if aggregation.isEmpty {
                    SectionCard {
                        EmptyStateView(symbol: "text.magnifyingglass",
                                       title: emptyTitle,
                                       message: emptyMessage,
                                       primaryTitle: nil, primaryAction: nil,
                                       secondaryTitle: nil, secondaryAction: nil)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(aggregation.enumerated()), id: \.element.entry.id) { index, item in
                            NavigationLink(destination: RootDetailView(rootID: item.entry.id)) {
                                rootRow(item.entry, count: item.words.count)
                            }
                            .buttonStyle(PlainButtonStyle())

                            if index != aggregation.count - 1 {
                                Divider().padding(.leading, Metric.rowHPadding)
                            }
                        }
                    }
                    .card(padding: 0)

                    Text(RootLibrary.shared.capacityText + " · 共命中 \(aggregation.count) 个词根")
                        .dsFont(size: 12)
                        .foregroundColor(.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationTitle("词根库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { sortByHits.toggle() }) {
                    Icon(name: sortByHits ? "arrow.up.arrow.down" : "textformat.abc",
                         size: 15, weight: .semibold, color: .brand500)
                }
                .accessibilityLabel(sortByHits ? "按命中数量排序" : "按字母排序")
            }
        }
    }

    private var emptyTitle: String {
        state.words.isEmpty ? "词根库待激活" : "还没有命中词根"
    }

    private var emptyMessage: String {
        state.words.isEmpty
            ? "导入单词后，App 会自动拆解构词，把命中的词根聚合到这里。"
            : "换个关键词试试，或者先导入更多单词。"
    }

    private var searchField: some View {
        HStack(spacing: Sp.x2) {
            Icon(name: "magnifyingglass", size: 14, weight: .medium, color: .textTertiary)
            TextField("搜索词根，如 spect / 看", text: $keyword)
                .dsFont(size: 15)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !keyword.isEmpty {
                Button(action: { keyword = "" }) {
                    Icon(name: "xmark.circle.fill", size: 14, weight: .medium, color: .textTertiary)
                }
            }
        }
        .padding(.horizontal, Sp.x3)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .fill(Color.surface)
        )
    }

    private var typeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Sp.x2) {
                chip(title: "全部", active: typeFilter == nil) { typeFilter = nil }
                ForEach(RootType.allCases) { type in
                    chip(title: type.cnLabel, active: typeFilter == type) {
                        typeFilter = (typeFilter == type) ? nil : type
                    }
                }
            }
        }
    }

    private func chip(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                .foregroundColor(active ? .white : .textSecondary)
                .padding(.horizontal, Sp.x3)
                .frame(height: 32)
                .background(
                    Capsule().fill(active ? Color.brand500 : Color.surface)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var summaryLine: some View {
        HStack {
            Text(sortByHits ? "按命中单词数排序" : "按字母顺序排序")
                .dsFont(size: 12)
                .foregroundColor(.textTertiary)
            Spacer(minLength: 0)
            Text("本机 \(state.words.count) 词")
                .dsFont(size: 12)
                .foregroundColor(.textTertiary)
        }
    }

    private func rootRow(_ entry: RootEntry, count: Int) -> some View {
        HStack(spacing: Sp.x3) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Sp.x2) {
                    Text(entry.form)
                        .dsFont(size: 16, weight: .semibold, maxScale: 1.15)
                        .foregroundColor(.textPrimary)
                    PlainChip(text: entry.type.cnLabel, color: entry.type.dotColor)
                }
                Text(entry.meaning)
                    .dsFont(size: 13)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .dsFont(size: 16, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.brand500)
                Text("词").dsFont(size: 11).foregroundColor(.textTertiary)
            }
            Icon(name: "chevron.right", size: 12, weight: .semibold, color: .textTertiary)
        }
        .padding(.horizontal, Metric.rowHPadding)
        .padding(.vertical, Sp.x3)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

// MARK: - P15 词根详情

struct RootDetailView: View {

    @EnvironmentObject private var state: AppState
    let rootID: String

    private var entry: RootEntry? { RootLibrary.shared.entry(id: rootID) }
    private var hits: [Word] { state.words(forRoot: rootID) }

    var body: some View {
        ScrollView {
            if let entry = entry {
                VStack(alignment: .leading, spacing: Sp.x4) {
                    hero(entry)

                    if entry.hasOriginOrNote {
                        SectionCard(title: "记忆法") {
                            VStack(alignment: .leading, spacing: Sp.x2) {
                                if !entry.origin.isEmpty {
                                    labeledLine("语源", entry.origin)
                                }
                                if !entry.note.isEmpty {
                                    labeledLine("提示", entry.note)
                                }
                            }
                        }
                    }

                    wordListCard(entry)

                    if !entry.examples.isEmpty {
                        SectionCard(title: "典型例词", subtitle: "词根库自带") {
                            Text(entry.examples.joined(separator: " · "))
                                .dsFont(size: 14)
                                .foregroundColor(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, Metric.pagePadding)
                .padding(.top, Sp.x3)
                .padding(.bottom, Sp.x8)
            } else {
                EmptyStateView(symbol: "questionmark.circle",
                               title: "词根不存在",
                               message: "它可能不在当前词根库中。",
                               primaryTitle: nil, primaryAction: nil,
                               secondaryTitle: nil, secondaryAction: nil)
                    .padding(.top, Sp.x8)
            }
        }
        .background(PageBackground())
        .navigationTitle(entry?.form ?? "词根")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hero(_ entry: RootEntry) -> some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            Text(entry.form)
                .dsFont(size: 30, weight: .bold, maxScale: 1.2)
                .foregroundColor(.textPrimary)
            HStack(spacing: Sp.x2) {
                PlainChip(text: entry.type.cnLabel, color: entry.type.dotColor)
                PlainChip(text: "本机命中 \(hits.count) 词", color: .brand500)
            }
            Text(entry.meaning)
                .dsFont(size: 17, weight: .medium, maxScale: 1.15)
                .foregroundColor(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Sp.x4)
    }

    private func labeledLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Sp.x2) {
            Text(title)
                .dsFont(size: 13, weight: .semibold, maxScale: 1.15)
                .foregroundColor(.textSecondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .dsFont(size: 13)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func wordListCard(_ entry: RootEntry) -> some View {
        SectionCard(title: "本机命中单词", subtitle: "\(hits.count) 个") {
            if hits.isEmpty {
                VStack(alignment: .leading, spacing: Sp.x3) {
                    Text("你的单词里还没有命中这个词根的单词。")
                        .dsFont(size: 13)
                        .foregroundColor(.textSecondary)
                    Button("导入更多单词") {
                        state.showToast("在「词单 → 更多 → 导入单词」里添加", icon: "info.circle.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 44))
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, word in
                        NavigationLink(destination: WordDetailView(wordID: word.id)) {
                            WordRow(word: word)
                        }
                        .buttonStyle(PlainButtonStyle())
                        if index != hits.count - 1 {
                            Divider().padding(.leading, Metric.rowHPadding)
                        }
                    }
                }
                .padding(.horizontal, -Metric.cardPadding)
                .padding(.vertical, -Sp.x2)

                Button("一次练完这组同根词（\(hits.count)）") {
                    state.startSession(source: .rootWords(hits.map { $0.id }))
                    if state.session == nil {
                        state.showToast("暂时无法生成练习组", icon: "info.circle.fill", isError: true)
                    } else {
                        state.showToast("已生成同根词练习")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(height: 50))
            }
        }
    }
}
