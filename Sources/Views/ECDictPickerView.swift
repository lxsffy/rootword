//
//  ECDictPickerView.swift
//  RootWord · 词根单词
//
//  EC Dictionary 大词库选词：按前缀浏览/检索内置 ecdict_light.tsv 常用词
//  （tag 含 zk/gk/cet4/cet6/ky/toefl/ielts 或 frq>0），勾选后生成
//  「单词@释义」文本，复用 Importer 标准链路预览并导入词单。
//

import SwiftUI

struct ECDictPickerView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    var preselectedDeckID: String? = nil

    @State private var searchText = ""
    @State private var results: [(word: String, translation: String)] = []
    @State private var selected: Set<String> = []
    @State private var dictReady = false
    @State private var deckID = ""
    @State private var isParsing = false

    struct PreviewPayload: Identifiable {
        let id = UUID()
        let result: ImportResult
    }

    @State private var preview: PreviewPayload?

    private var targetDeckID: String {
        deckID.isEmpty ? (preselectedDeckID ?? state.currentDeck?.id ?? "") : deckID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.x4) {
                searchCard
                if !dictReady {
                    loadingCard
                } else if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    guideCard
                } else {
                    resultCard
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, 120)
        }
        .background(PageBackground())
        .navigationTitle("大词库选词")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { presentationMode.wrappedValue.dismiss() }
                    .dsFont(size: 15)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    Button("预览导入 \(selected.count) 个单词") { doPreview() }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: !isParsing))
                        .disabled(isParsing)
                        .padding(.horizontal, Metric.pagePadding)
                        .padding(.vertical, Sp.x3)
                }
                .background(Color.bg)
            }
        }
        .sheet(item: $preview) { payload in
            ImportPreviewView(result: payload.result,
                              deckID: targetDeckID,
                              onDone: { presentationMode.wrappedValue.dismiss() })
                .environmentObject(state)
                .id(payload.id)
        }
        .overlay(Group {
            if isParsing { parsingOverlay }
        })
        .onAppear {
            if deckID.isEmpty {
                deckID = preselectedDeckID ?? state.currentDeck?.id ?? state.decks.first?.id ?? ""
            }
            // 大词库 36MB 后台预加载，避免搜索首击卡顿
            DispatchQueue.global(qos: .userInitiated).async {
                _ = ECDictValidator.loadDict()
                DispatchQueue.main.async { dictReady = true }
            }
        }
        .onChange(of: searchText) { _ in refresh() }
    }

    // MARK: 搜索

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: Sp.x2) {
            Text("检索大词库")
                .dsFont(size: 13, weight: .semibold)
                .foregroundColor(.textSecondary)

            HStack(spacing: Sp.x2) {
                Icon(name: "magnifyingglass", size: 15, weight: .medium, color: .textTertiary)
                TextField("输入英文前缀，如 ab / take / un", text: $searchText)
                    .dsFont(size: 15)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Icon(name: "xmark.circle.fill", size: 16, weight: .regular, color: .textTertiary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, Sp.x3)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                    .fill(Color.surface)
            )
        }
    }

    private var loadingCard: some View {
        HStack(spacing: Sp.x3) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("正在加载大词库…")
                    .dsFont(size: 14, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text("内置 EC Dictionary 词库约 77 万词条（36MB），仅首次加载")
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: Sp.x4)
    }

    private var guideCard: some View {
        SectionCard(title: "使用说明", subtitle: "EC Dictionary 常用词（考试词表）") {
            VStack(alignment: .leading, spacing: Sp.x2) {
                bullet("输入英文前缀即可浏览匹配的常用词，例如输入 ab 出现 abandon、ability…")
                bullet("常用词 = tag 含 zk / gk / cet4 / cet6 / ky / toefl / ielts，或词频 > 0")
                bullet("点选单词加入待导入列表，底部可一键「预览导入」")
                bullet("导入会复用标准去重与补全逻辑，不会改动已有词单")
                bullet("常用前缀示例：a / ab / ad / re / un / in / dis / pre / take / make / good")
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Sp.x2) {
            Circle().fill(Color.brand500).frame(width: 5, height: 5).padding(.top, 7)
            Text(text)
                .dsFont(size: 13)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 结果

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: Sp.x2) {
            HStack {
                Text("匹配结果")
                    .dsFont(size: 13, weight: .semibold)
                    .foregroundColor(.textSecondary)
                Spacer(minLength: 0)
                if !selected.isEmpty {
                    Button(action: { selected.removeAll() }) {
                        Text("清除选择 (\(selected.count))")
                            .dsFont(size: 12, weight: .medium, maxScale: 1.15)
                            .foregroundColor(.brand500)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            if results.isEmpty {
                EmptyStateView(title: "没有匹配的常用词",
                               message: "试试更短的前缀，或换一个首字母")
            } else {
                VStack(spacing: 0) {
                    ForEach(results, id: \.word) { item in
                        row(item)
                        if item.word != results.last?.word {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, Sp.x3)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.surface)
                )
            }
        }
    }

    private func row(_ item: (word: String, translation: String)) -> some View {
        let isOn = selected.contains(item.word)
        return Button(action: { toggle(item.word) }) {
            HStack(spacing: Sp.x3) {
                Icon(name: isOn ? "checkmark.circle.fill" : "circle",
                     size: 20, weight: .regular,
                     color: isOn ? .brand500 : .textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.word)
                        .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                        .foregroundColor(.textPrimary)
                    Text(item.translation)
                        .dsFont(size: 12)
                        .foregroundColor(.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Sp.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func toggle(_ word: String) {
        if selected.contains(word) {
            selected.remove(word)
        } else {
            selected.insert(word)
        }
    }

    // MARK: 解析中浮层

    private var parsingOverlay: some View {
        ZStack {
            Color.black.opacity(0.10).ignoresSafeArea()
            HStack(spacing: Sp.x3) {
                ProgressView()
                Text("正在生成预览…")
                    .dsFont(size: 14, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
            }
            .padding(.horizontal, Sp.x5)
            .padding(.vertical, Sp.x4)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.surface)
            )
        }
        .transition(.opacity)
    }

    // MARK: 行为

    private func refresh() {
        guard dictReady else { return }
        let p = searchText.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else {
            results = []
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let hits = ECDictValidator.commonWords(prefix: p, limit: 200)
            DispatchQueue.main.async { self.results = hits }
        }
    }

    private func doPreview() {
        guard !isParsing, !selected.isEmpty else { return }
        isParsing = true

        let text = buildText()
        let deck = targetDeckID
        let deckLabel = state.decks.first(where: { $0.id == deck })?.name ?? "未分类"
        let known = state.existingWordsByKey()

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<ImportResult, Error>
            do {
                let result = try Importer.parse(text: text,
                                                fileName: nil,
                                                targetDeckID: deck,
                                                targetDeckName: deckLabel,
                                                knownWords: known)
                if result.words.isEmpty && !result.errorIssues.isEmpty {
                    let message = result.errorIssues.prefix(3)
                        .map { "第 \($0.line) 行：\($0.message)" }
                        .joined(separator: "\n")
                    outcome = .failure(ImportFailure.lineErrors(message))
                } else {
                    outcome = .success(result)
                }
            } catch {
                outcome = .failure(error)
            }

            DispatchQueue.main.async {
                self.isParsing = false
                switch outcome {
                case .success(let result):
                    self.preview = PreviewPayload(result: result)
                case .failure(let error):
                    self.state.showToast("预览失败：\(self.describe(error))")
                }
            }
        }
    }

    private func buildText() -> String {
        selected.sorted().map { word in
            if let entry = ECDictValidator.loadDict()[word] {
                return "\(word)@\(entry.translation)"
            }
            return word
        }.joined(separator: "\n")
    }

    private func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return error.localizedDescription }
        let description = localized.errorDescription ?? error.localizedDescription
        guard let suggestion = localized.recoverySuggestion, !suggestion.isEmpty else { return description }
        return "\(description)\n\(suggestion)"
    }
}
