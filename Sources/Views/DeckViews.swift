//
//  DeckViews.swift
//  RootWord · 词根单词
//
//  P08 词单列表 / P09 词单详情 / P11 新建词单 / 词单删除确认 / 重命名。
//  文档 5.8–5.11。
//

import SwiftUI

// MARK: - P08 词单列表

struct DeckListView: View {

    @EnvironmentObject private var state: AppState

    @State private var showCreate = false
    @State private var showImport = false
    @State private var renameTarget: Deck?
    @State private var deleteTarget: Deck?

    var body: some View {
        ScrollView {
            VStack(spacing: Sp.x3) {
                PageTitle(text: "词单")
                    .padding(.bottom, Sp.x1)

                if state.decks.isEmpty {
                    SectionCard {
                        EmptyStateView(symbol: "square.stack",
                                       title: "还没有词单",
                                       message: "新建一个词单，再把要背的单词导进去。",
                                       primaryTitle: "新建词单",
                                       primaryAction: { showCreate = true },
                                       secondaryTitle: nil,
                                       secondaryAction: nil)
                    }
                } else {
                    ForEach(state.decks) { deck in
                        deckRow(deck)
                    }
                }

                HintBlock(symbol: "info.circle",
                          text: "当前词单决定「今日」页面优先安排哪些单词。",
                          tint: .info500)
                    .padding(.top, Sp.x1)
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { showCreate = true }) {
                        Label("新建词单", systemImage: "folder.badge.plus")
                    }
                    Button(action: { showImport = true }) {
                        Label("导入单词", systemImage: "tray.and.arrow.down")
                    }
                } label: {
                    Icon(name: "plus", size: 17, weight: .semibold, color: .brand500)
                        .frame(width: Metric.hitMin, height: Metric.hitMin)
                }
                .accessibilityLabel("更多操作")
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateDeckSheet().environmentObject(state)
        }
        .sheet(isPresented: $showImport) {
            ImportView().environmentObject(state)
        }
        .sheet(item: $renameTarget) { deck in
            RenameDeckSheet(deck: deck).environmentObject(state)
        }
        .sheet(item: $deleteTarget) { deck in
            DeleteDeckSheet(deck: deck, onFinished: { deleteTarget = nil })
                .environmentObject(state)
        }
    }

    private func deckRow(_ deck: Deck) -> some View {
        NavigationLink(destination: DeckDetailView(deckID: deck.id)) {
            HStack(alignment: .center, spacing: Sp.x3) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Sp.x2) {
                        Text(deck.name)
                            .dsFont(size: 17, weight: .semibold, maxScale: 1.15)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        if deck.isCurrent {
                            PlainChip(text: "当前", color: .brand500)
                        }
                    }
                    Text(deckSummary(deck))
                        .dsFont(size: 13)
                        .foregroundColor(.textSecondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(state.words(in: deck.id).count)")
                        .dsFont(size: 17, weight: .semibold, maxScale: 1.15)
                        .foregroundColor(.textPrimary)
                    Text("词").dsFont(size: 11).foregroundColor(.textTertiary)
                }
                Icon(name: "chevron.right", size: 13, weight: .semibold, color: .textTertiary)
            }
            .padding(.horizontal, Metric.rowHPadding)
            .padding(.vertical, Sp.x3)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
        .card(padding: 0)
        .contextMenu {
            if !deck.isCurrent {
                Button(action: {
                    state.setCurrentDeck(id: deck.id)
                    state.showToast("已把「\(deck.name)」设为当前词单")
                }) {
                    Label("设为当前词单", systemImage: "checkmark.circle")
                }
            }
            Button(action: { renameTarget = deck }) {
                Label("重命名", systemImage: "pencil")
            }
            Button(action: { deleteTarget = deck }) {
                Label("删除词单", systemImage: "trash")
            }
        }
    }

    private func deckSummary(_ deck: Deck) -> String {
        let items = state.words(in: deck.id)
        guard !items.isEmpty else { return "空词单 · 可导入单词" }
        let now = Date()
        let due = items.filter { word in
            word.srs.phase == .new || word.srs.dueAt <= now
        }.count
        if due == 0 { return "\(items.count) 词 · 暂无待复习" }
        return "\(items.count) 词 · 待复习 \(due)"
    }
}

// MARK: - P11 新建词单

struct CreateDeckSheet: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    @State private var name: String = ""
    @State private var makeCurrent = true

    var body: some View {
        SheetScaffold(title: "新建词单",
                      confirmTitle: "创建",
                      confirmEnabled: !trimmed.isEmpty,
                      onConfirm: {
                          let deck = state.createDeck(name: trimmed, makeCurrent: makeCurrent)
                          state.showToast("已创建「\(deck.name)」")
                          presentationMode.wrappedValue.dismiss()
                      }) {
            VStack(alignment: .leading, spacing: Sp.x4) {
                VStack(alignment: .leading, spacing: Sp.x2) {
                    Text("词单名称")
                        .dsFont(size: 13, weight: .semibold)
                        .foregroundColor(.textSecondary)
                    TextField("例如：七年级上册 Unit 3", text: $name)
                        .dsFont(size: 16)
                        .padding(.horizontal, Sp.x3)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                                .fill(Color.surfaceAlt)
                        )
                }

                Toggle(isOn: $makeCurrent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设为当前词单")
                            .dsFont(size: 15)
                            .foregroundColor(.textPrimary)
                        Text("今日任务会优先从这个词单里排")
                            .dsFont(size: 12)
                            .foregroundColor(.textSecondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .brand500))

                HintBlock(symbol: "info.circle",
                          text: "重名时会自动加序号，不会覆盖已有词单。",
                          tint: .info500)
            }
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 重命名

struct RenameDeckSheet: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    let deck: Deck
    @State private var name: String = ""

    var body: some View {
        SheetScaffold(title: "重命名词单",
                      confirmTitle: "保存",
                      confirmEnabled: !trimmed.isEmpty,
                      onConfirm: {
                          state.renameDeck(id: deck.id, to: trimmed)
                          state.showToast("已重命名")
                          presentationMode.wrappedValue.dismiss()
                      }) {
            TextField("词单名称", text: $name)
                .dsFont(size: 16)
                .padding(.horizontal, Sp.x3)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .fill(Color.surfaceAlt)
                )
        }
        .onAppear { name = deck.name }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 删除词单（二选一确认）

struct DeleteDeckSheet: View {

    @EnvironmentObject private var state: AppState
    let deck: Deck
    var onFinished: () -> Void
    @State private var armed = false

    private var wordCount: Int { state.words(in: deck.id).count }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.x5) {
            SheetGrabber()

            VStack(alignment: .leading, spacing: Sp.x2) {
                Text("删除「\(deck.name)」")
                    .dsFont(size: 18, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text("这个词单里有 \(wordCount) 个单词。选一种删除方式，操作不可撤销。")
                    .dsFont(size: 14)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: Sp.x3) {
                Button(action: {
                    state.deleteDeck(id: deck.id, deleteWords: false)
                    state.showToast("已删除词单，单词已移到「未分类」")
                    onFinished()
                }) {
                    actionLabel(title: "只删除词单",
                                subtitle: "单词保留，移到「未分类」",
                                color: .warning500)
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))

                Button(action: {
                    guard armed else {
                        armed = true
                        Haptics.warning()
                        return
                    }
                    state.deleteDeck(id: deck.id, deleteWords: true)
                    state.showToast("已删除词单与 \(wordCount) 个单词")
                    onFinished()
                }) {
                    actionLabel(title: armed ? "确认连单词一起删除（\(wordCount) 个）" : "删除词单和单词",
                                subtitle: "单词、学习进度、复习记录一并删除",
                                color: .danger500)
                }
                .buttonStyle(PressScaleStyle(scale: 0.98))
            }

            Button("取消") { onFinished() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.bottom, Sp.x4)
        }
        .padding(.horizontal, Metric.pagePadding)
        .padding(.top, Sp.x3)
        .background(Color.bg)
    }

    private func actionLabel(title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: Sp.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .dsFont(size: 16, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text(subtitle)
                    .dsFont(size: 12)
                    .foregroundColor(.textSecondary)
            }
            Spacer(minLength: 0)
            Icon(name: "chevron.right", size: 13, weight: .semibold, color: color)
        }
        .padding(.horizontal, Metric.rowHPadding)
        .padding(.vertical, Sp.x3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - P09 词单详情

enum WordSortMode: String, CaseIterable, Identifiable {
    case custom, alphabet, mastery, due

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom:   return "自定义顺序"
        case .alphabet: return "字母顺序"
        case .mastery:  return "掌握度"
        case .due:      return "到期时间"
        }
    }
}

/// P09 词单详情页的弹层：导入单词 / 导出 CSV 后的系统分享（文档 5.9）。
private enum DeckDetailSheet: Identifiable {
    case importWords
    case share(URL)

    var id: String {
        switch self {
        case .importWords:
            return "importWords"
        case .share(let url):
            return "share-" + url.absoluteString
        }
    }
}

struct DeckDetailView: View {

    @EnvironmentObject private var state: AppState
    let deckID: String

    @State private var keyword = ""
    @State private var sortMode: WordSortMode = .custom
    @State private var activeSheet: DeckDetailSheet?
    @State private var showStudy = false
    @State private var pendingDelete: Word?

    private var deck: Deck? { state.decks.first(where: { $0.id == deckID }) }

    var body: some View {
        ScrollView {
            VStack(spacing: Sp.x3) {
                if let deck = deck {
                    headerCard(deck)
                }

                if let deck = deck, state.words(in: deck.id).isEmpty {
                    SectionCard {
                        EmptyStateView(symbol: "tray.and.arrow.down",
                                       title: "这个词单还是空的",
                                       message: "支持 TXT / CSV / JSON 三种格式，导入后可自动生成构词拆解。",
                                       primaryTitle: "导入单词",
                                       primaryAction: { activeSheet = .importWords },
                                       secondaryTitle: nil,
                                       secondaryAction: nil)
                    }
                } else {
                    toolbarRow
                    wordList
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationTitle(deck?.name ?? "词单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { activeSheet = .importWords }) {
                        Label("导入单词", systemImage: "tray.and.arrow.down")
                    }
                    Button(action: exportCSV) {
                        Label("导出词单（CSV）", systemImage: "square.and.arrow.up")
                    }
                    Button(action: startPractice) {
                        Label("练习这个词单", systemImage: "play.circle")
                    }
                } label: {
                    Icon(name: "ellipsis.circle", size: 18, weight: .medium, color: .brand500)
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .importWords:
                ImportView(preselectedDeckID: deckID).environmentObject(state)
            case .share(let url):
                ShareSheet(items: [url])
            }
        }
        .fullScreenCover(isPresented: $showStudy) {
            StudyFlowView().environmentObject(state)
        }
        .sheet(item: $pendingDelete) { word in
            DeleteWordSheet(word: word, onFinished: { pendingDelete = nil })
                .environmentObject(state)
        }
    }

    // MARK: 头部统计

    private func headerCard(_ deck: Deck) -> some View {
        let items = state.words(in: deck.id)
        let mastered = items.filter { $0.srs.phase == .mastered }.count
        let now = Date()
        let due = items.filter { $0.srs.phase == .new || $0.srs.dueAt <= now }.count

        return VStack(spacing: Sp.x4) {
            HStack(spacing: Sp.x3) {
                StatCard(title: "总词数", value: "\(items.count)", color: .brand500)
                StatCard(title: "已掌握", value: "\(mastered)", color: .success500)
                StatCard(title: "待复习", value: "\(due)", color: .info500)
            }

            Button(action: startPractice) {
                HStack(spacing: Sp.x2) {
                    Icon(name: "play.fill", size: 15, weight: .semibold, color: .white)
                    Text(due > 0 ? "练习这个词单（\(due)）" : "随便练几个")
                        .dsFont(size: 16, weight: .semibold, maxScale: 1.15)
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(PrimaryButtonStyle(height: 50))
            .disabled(items.isEmpty)
        }
        .card(padding: Sp.x4)
    }

    // MARK: 搜索 + 排序

    private var toolbarRow: some View {
        HStack(spacing: Sp.x3) {
            HStack(spacing: Sp.x2) {
                Icon(name: "magnifyingglass", size: 14, weight: .medium, color: .textTertiary)
                TextField("搜索单词或释义", text: $keyword)
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

            Menu {
                ForEach(WordSortMode.allCases) { mode in
                    Button(action: { sortMode = mode }) {
                        if mode == sortMode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Icon(name: "arrow.up.arrow.down", size: 15, weight: .semibold, color: .brand500)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                            .fill(Color.surface)
                    )
            }
            .accessibilityLabel("排序方式")
        }
    }

    private var wordList: some View {
        let items = displayedWords
        return Group {
            if items.isEmpty {
                SectionCard {
                    EmptyStateView(symbol: "magnifyingglass",
                                   title: "没有匹配的单词",
                                   message: "换个关键词试试，或者清空搜索框。",
                                   primaryTitle: nil,
                                   primaryAction: nil,
                                   secondaryTitle: nil,
                                   secondaryAction: nil)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, word in
                        NavigationLink(destination: WordDetailView(wordID: word.id)) {
                            WordRow(word: word)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu {
                            Button(action: { state.markMastered(id: word.id) }) {
                                Label("标记为已掌握", systemImage: "checkmark.seal")
                            }
                            Button(action: { state.resetProgress(id: word.id) }) {
                                Label("重置学习进度", systemImage: "arrow.counterclockwise")
                            }
                            Button(action: { pendingDelete = word }) {
                                Label("删除这个单词", systemImage: "trash")
                            }
                        }

                        if index != items.count - 1 {
                            Divider().padding(.leading, Metric.rowHPadding)
                        }
                    }
                }
                .card(padding: 0)

                Text("共 \(items.count) 个单词")
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Sp.x1)
            }
        }
    }

    private var displayedWords: [Word] {
        var items = state.words(in: deckID)
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            items = items.filter {
                $0.text.localizedCaseInsensitiveContains(trimmed) ||
                $0.meaning.localizedCaseInsensitiveContains(trimmed)
            }
        }
        switch sortMode {
        case .custom:
            items.sort { $0.position < $1.position }
        case .alphabet:
            items.sort { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
        case .mastery:
            items.sort { $0.srs.interval < $1.srs.interval }
        case .due:
            items.sort { $0.srs.dueAt < $1.srs.dueAt }
        }
        return items
    }

    /// 「导出词单（CSV）」：落盘到 Documents 后弹系统分享面板；
    /// 失败（空词单 / 磁盘写入失败）用 Toast 说明原因，不带出半成品文件。
    private func exportCSV() {
        let name = deck?.name ?? "词单"
        let outcome = state.exportDeckCSV(deckID: deckID)
        if let url = outcome.url {
            activeSheet = .share(url)
            state.showToast("已导出「\(name)」的 CSV")
        } else {
            state.showToast(outcome.error ?? "导出失败，请稍后重试",
                            icon: "xmark.circle.fill",
                            isError: true)
        }
    }

    private func startPractice() {
        state.setCurrentDeck(id: deckID)
        state.startSession(source: .deck(deckID))
        if state.session != nil {
            showStudy = true
        } else {
            state.showToast("这个词单暂时没有可学的单词", icon: "info.circle.fill")
        }
    }
}

// MARK: - 删除单个单词

struct DeleteWordSheet: View {

    @EnvironmentObject private var state: AppState
    let word: Word
    var onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.x4) {
            SheetGrabber()
            Text("删除「\(word.text)」？")
                .dsFont(size: 18, weight: .semibold, maxScale: 1.15)
                .foregroundColor(.textPrimary)
            Text("这个单词及其学习进度、复习记录都会被删除，操作不可撤销。")
                .dsFont(size: 14)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Sp.x3) {
                Button("删除") {
                    state.deleteWord(id: word.id)
                    state.showToast("已删除「\(word.text)」")
                    onFinished()
                }
                .buttonStyle(PrimaryButtonStyle(fill: .danger500))

                Button("取消") { onFinished() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.bottom, Sp.x4)
        }
        .padding(.horizontal, Metric.pagePadding)
        .padding(.top, Sp.x3)
        .background(Color.bg)
    }
}
