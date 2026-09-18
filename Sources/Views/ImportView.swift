//
//  ImportView.swift
//  RootWord · 词根单词
//
//  P12 导入入口 / P13 导入预览确认。文档 5.14、第 8 章。
//
//  三种来源：粘贴文本 / 从文件选择 / 示例模板；解析后先预览、再确认落库。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImportView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    var preselectedDeckID: String? = nil

    enum Source: String, CaseIterable, Identifiable {
        case paste, file, template
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paste:    return "粘贴文本"
            case .file:     return "从文件导入"
            case .template: return "示例模板"
            }
        }
    }

    @State private var source: Source = .paste
    @State private var rawText = ""
    /// 三种来源各自独立的内容草稿（rawText 只是「当前来源的编辑缓冲区」）。
    ///
    /// 修复「从示例模板切回粘贴文本后，模板内容残留在输入框里」：
    /// 原实现切到 .template 时直接 `rawText = csvTemplate`，切回 .paste 时 rawText 不动，
    /// 于是用户自己粘的文本被模板顶掉、模板又被当成用户的粘贴内容去解析。
    /// 现在切换来源时先把当前缓冲区存回旧来源的草稿，再取新来源的草稿，
    /// 三个来源互不污染，切回来还是用户原来的内容。
    @State private var pasteDraft = ""
    @State private var fileDraft = ""
    @State private var templateDraft = ImportView.csvTemplate
    @State private var deckID = ""
    /// 预览页的载荷：用 `.sheet(item:)` 驱动，保证 sheet 首次呈现时就拿得到解析结果。
    ///
    /// 修复「第一次解析白屏、第二次才成功」：原实现用 `.sheet(isPresented:)` + `parsed` 可选值，
    /// sheet 的内容闭包可能在 `parsed` 赋值前的那次视图快照里构建，首帧渲染成空白页；
    /// 第二次点解析时 `parsed` 已有旧值，于是「碰巧」能显示。
    struct PreviewPayload: Identifiable {
        let id = UUID()
        let result: ImportResult
    }

    @State private var preview: PreviewPayload?
    @State private var showPicker = false
    @State private var parseFailure: String?
    /// 解析进行中（后台解析 + 按钮防连点）
    @State private var isParsing = false
    /// 来源文件名（用于扩展名校验与格式判定），粘贴时为 nil
    @State private var sourceFileName: String?

    private var targetDeckID: String {
        deckID.isEmpty ? (preselectedDeckID ?? state.currentDeck?.id ?? "") : deckID
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Sp.x4) {
                    sourcePicker
                    inputArea
                    deckPicker
                    formatGuide
                }
                .padding(.horizontal, Metric.pagePadding)
                .padding(.top, Sp.x3)
                .padding(.bottom, 120)
            }
            .background(PageBackground())
            .navigationTitle("导入单词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                        .dsFont(size: 15)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("下一步") { doParse() }
                        .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                        .disabled(trimmedRaw.isEmpty || isParsing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    Button("解析并预览") { doParse() }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: !trimmedRaw.isEmpty && !isParsing))
                        .disabled(trimmedRaw.isEmpty || isParsing)
                        .padding(.horizontal, Metric.pagePadding)
                        .padding(.vertical, Sp.x3)
                }
                .background(Color.bg)
            }
            // 文件选择器挂在内层（NavigationView 内部），预览页挂在外层，
            // 两个 sheet 不落在同一个视图上——同一视图挂多个 sheet 时后来的会遮蔽先前的，
            // 第一次呈现容易出现空白页。
            .sheet(isPresented: $showPicker) {
                DocumentPicker(allowed: [UTType.plainText, UTType.commaSeparatedText, UTType.json, UTType.text]) { url in
                    loadFile(url)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        // 解析中浮层：后台解析期间给用户明确反馈，避免「点了没反应」的错觉
        .overlay(Group {
            if isParsing { parsingOverlay }
        })
        // 预览页用 .sheet(item:) 由载荷驱动：载荷一到就有值，不会出现
        // 「sheet 已弹出但内容还没拿到解析结果」的首帧空白。
        .sheet(item: $preview) { payload in
            ImportPreviewView(result: payload.result,
                              deckID: targetDeckID,
                              onDone: { presentationMode.wrappedValue.dismiss() })
            .environmentObject(state)
            .id(payload.id)
        }
        .alert(isPresented: Binding(get: { parseFailure != nil },
                                    set: { if !$0 { parseFailure = nil } })) {
            Alert(title: Text("无法导入"),
                  message: Text(parseFailure ?? ""),
                  dismissButton: .default(Text("知道了")))
        }
        .onAppear {
            if deckID.isEmpty {
                deckID = preselectedDeckID ?? state.currentDeck?.id ?? state.decks.first?.id ?? ""
            }
        }
    }

    // MARK: 来源切换

    private var sourcePicker: some View {
        HStack(spacing: Sp.x2) {
            ForEach(Source.allCases) { item in
                Button(action: { switchSource(to: item) }) {
                    Text(item.title)
                        .dsFont(size: 14, weight: .medium, maxScale: 1.15)
                        .foregroundColor(item == source ? .white : .textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(item == source ? Color.brand500 : Color.surface)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityAddTraits(item == source ? [.isSelected] : [])
            }
        }
    }

    /// 切换来源：先存旧草稿 → 复位来源相关状态 → 再载入新草稿。
    /// `presentPicker` 为 false 时不弹文件选择器（用于「已经选完文件、只切来源」的内部调用）。
    private func switchSource(to item: Source, presentPicker: Bool = true) {
        if item == source {
            // 重复点同一个来源不清空内容（避免误点把正在编辑的文本抹掉）；
            // 「从文件导入」再点一次等于「重新选文件」
            if item == .file && presentPicker { showPicker = true }
            return
        }

        // 1) 把当前缓冲区存回它所属的来源草稿
        switch source {
        case .paste:    pasteDraft = rawText
        case .file:     fileDraft = rawText
        case .template: templateDraft = rawText
        }

        // 2) 来源变了，来源相关状态必须同步复位：
        //    否则「粘贴文本」会带着上一个 .json 文件的名字，被 Importer 判定成 JSON 去解析。
        sourceFileName = nil
        source = item

        // 3) 载入新来源自己的草稿（模板首次进入或草稿被清空时补一份示例）
        switch item {
        case .paste:
            rawText = pasteDraft
        case .file:
            rawText = fileDraft
            if presentPicker { showPicker = true }
        case .template:
            rawText = templateDraft.isEmpty ? ImportView.csvTemplate : templateDraft
            templateDraft = rawText
        }
    }

    // MARK: 输入区

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: Sp.x2) {
            HStack {
                Text("单词内容")
                    .dsFont(size: 13, weight: .semibold)
                    .foregroundColor(.textSecondary)
                Spacer(minLength: 0)
                Text("\(lineCount) 行")
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
            }

            ZStack(alignment: .topLeading) {
                if rawText.isEmpty {
                    Text("每行一个单词或词组，可用 @ 分隔字段（也认 Tab / 逗号 / 竖线）：\n\nabandon@放弃@/əˈbændən/@v.\ngood morning@早上好\nap-|-band-|-on")
                        .dsFont(size: 14)
                        .foregroundColor(.textTertiary)
                        .padding(.horizontal, Sp.x3 + 2)
                        .padding(.vertical, Sp.x3 + 2)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $rawText)
                    .dsFont(size: 14)
                    .frame(minHeight: 200)
                    .padding(.horizontal, Sp.x2)
                    .padding(.vertical, Sp.x2)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.surface)
            )

            HStack(spacing: Sp.x3) {
                Button(action: { showPicker = true }) {
                    Label("选择文件", systemImage: "folder")
                        .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                }
                .buttonStyle(SecondaryButtonStyle(height: 38))

                Button(action: {
                    UIPasteboard.general.string = rawText.isEmpty ? ImportView.csvTemplate : rawText
                    state.showToast("已复制到剪贴板")
                }) {
                    Label("复制内容", systemImage: "doc.on.doc")
                        .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                }
                .buttonStyle(SecondaryButtonStyle(height: 38))

                Spacer(minLength: 0)

                // 模板/文件内容会一直留在输入框里，必须给一个显式的清空出口，
                // 否则用户只能手动全选删除（或误把示例当成自己的词表导入）。
                Button(action: clearCurrentInput) {
                    Label("清空", systemImage: "xmark.circle")
                        .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                }
                .buttonStyle(SecondaryButtonStyle(height: 38))
                .disabled(trimmedRaw.isEmpty)
            }
        }
    }

    /// 清空当前来源的输入：缓冲区与该来源的草稿一起清掉，切换来源后不会又冒出来。
    private func clearCurrentInput() {
        guard !trimmedRaw.isEmpty else { return }
        rawText = ""
        switch source {
        case .paste:
            pasteDraft = ""
        case .file:
            fileDraft = ""
            sourceFileName = nil
        case .template:
            templateDraft = ""
        }
        state.showToast("已清空输入内容")
    }

    // MARK: 目标词单

    private var deckPicker: some View {
        VStack(alignment: .leading, spacing: Sp.x2) {
            Text("导入到")
                .dsFont(size: 13, weight: .semibold)
                .foregroundColor(.textSecondary)

            Menu {
                ForEach(state.decks) { deck in
                    Button(action: { deckID = deck.id }) {
                        if deck.id == targetDeckID {
                            Label(deck.name, systemImage: "checkmark")
                        } else {
                            Text(deck.name)
                        }
                    }
                }
                Button(action: {
                    let deck = state.createDeck(name: "新词单 \(state.decks.count + 1)")
                    deckID = deck.id
                    state.showToast("已创建「\(deck.name)」")
                }) {
                    Label("新建词单…", systemImage: "plus")
                }
            } label: {
                HStack(spacing: Sp.x2) {
                    Icon(name: "folder", size: 15, weight: .medium, color: .brand500)
                    Text(state.decks.first(where: { $0.id == targetDeckID })?.name ?? "未分类")
                        .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                        .foregroundColor(.textPrimary)
                    Spacer(minLength: 0)
                    Icon(name: "chevron.up.chevron.down", size: 12, weight: .semibold, color: .textTertiary)
                }
                .padding(.horizontal, Sp.x3)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                        .fill(Color.surface)
                )
            }
            .accessibilityLabel("选择目标词单")
        }
    }

    // MARK: 格式说明

    private var formatGuide: some View {
        SectionCard(title: "导入格式", subtitle: "支持 TXT / CSV / JSON") {
            VStack(alignment: .leading, spacing: Sp.x2) {
                bullet("字段顺序：单词@释义@音标@词性@词根拆解@记忆法@例句@例句翻译@词单名")
                bullet("单词列可以是词组：good morning、ice cream（词与词之间用空格，最多 4 个词），词组不参与词根拆解")
                bullet("只有第 1 列必填，其余可留空；缺释义的单词会标注「待补充」")
                bullet("分隔符自动识别：@ / Tab / 英文逗号 / 中文逗号 / 竖线")
                bullet("编码自动识别：UTF-8 BOM → UTF-8 → GB18030")
                bullet("重复单词：同一文件内自动合并；已在目标词单里的会跳过，整批都已存在时会直接提示「无需重复导入」")
                bullet("词根拆解写法：pre-|dict 或 un-+happy，两种写法等价")
                bullet("不会自动编造释义，宁可留空也不猜")
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

    // MARK: 解析中浮层

    private var parsingOverlay: some View {
        ZStack {
            Color.black.opacity(0.10).ignoresSafeArea()
            HStack(spacing: Sp.x3) {
                ProgressView()
                Text("正在解析…")
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

    private var trimmedRaw: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lineCount: Int {
        trimmedRaw.isEmpty ? 0 : trimmedRaw.components(separatedBy: .newlines).count
    }

    private func doParse() {
        // 幂等保护：解析进行中不重复触发（避免连点造成两次 sheet 呈现）
        guard !isParsing else { return }
        isParsing = true

        // 主线程快照：rawText / 词库 均为 UI 状态，先取值再离开主线程
        let text = rawText
        // 只有「从文件导入」才带来源文件名：粘贴文本与示例模板都必须当纯文本走分隔符嗅探，
        // 不能因为之前选过 .json 就被判定成 JSON（切换来源时 sourceFileName 已复位）。
        let fileName = (source == .file) ? sourceFileName : nil
        let deck = targetDeckID
        let deckLabel = deckName
        let known = state.existingWordsByKey()

        // 解析放到后台队列：大词表 + 与词库合并是同步计算，原先占用主线程会
        // 让 sheet 首帧渲染被卡住，出现「第一次点解析是白屏、第二次才成功」。
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<ImportResult, Error>
            do {
                let result = try Importer.parse(text: text,
                                                fileName: fileName,
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
                    // 结果与呈现同帧赋值：sheet(item:) 拿到 payload 时数据已就绪，首帧不会是空白
                    self.preview = PreviewPayload(result: result)
                case .failure(let error):
                    self.parseFailure = self.describe(error)
                }
            }
        }
    }

    /// 错误文案：主描述 + 恢复建议（如「这 N 个单词已在「XX」词单中」→「换一个词单名再导入」）
    private func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return error.localizedDescription }
        let description = localized.errorDescription ?? error.localizedDescription
        guard let suggestion = localized.recoverySuggestion, !suggestion.isEmpty else { return description }
        return "\(description)\n\(suggestion)"
    }

    /// 目标词单展示名
    private var deckName: String {
        state.decks.first(where: { $0.id == targetDeckID })?.name ?? "未分类"
    }

    private func loadFile(_ url: URL) {
        do {
            try Importer.checkExtension(url)
            let content = try Importer.decodeFile(at: url)
            // 从「选择文件」按钮进来时来源可能还是 .paste，先切到「从文件导入」：
            // 这样解析才会带上文件名（JSON/CSV 的格式判定依赖它），
            // 且已有内容会存进各自草稿，不会互相污染。presentPicker=false 避免重复弹选择器。
            if source != .file { switchSource(to: .file, presentPicker: false) }
            rawText = content
            fileDraft = content
            sourceFileName = url.lastPathComponent
            state.showToast("已读取 \(url.lastPathComponent)")
        } catch {
            parseFailure = describe(error)
        }
    }

    // MARK: 示例模板

    static let csvTemplate = """
    单词@释义@音标@词性@词根拆解@记忆法@例句@例句翻译@词单名
    predict@预测；预言@/prɪˈdɪkt/@v.@pre-|dict@pre 表示「预先」，dict 表示「说」——提前说出来就是预测@I can predict the result.@我能预测结果。@七年级 Unit 3
    describe@描述@/dɪˈskraɪb/@v.@de-|scrib@scrib 表示「写」——写下来就是描述@Please describe your school.@请描述你的学校。@七年级 Unit 3
    import@进口；导入@/ɪmˈpɔːrt/@v.@im-|port@port 表示「搬运」——搬进来就是进口@We import books from abroad.@我们从国外进口书籍。@七年级 Unit 3
    """
}

// MARK: - P13 导入预览

struct ImportPreviewView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    let result: ImportResult
    let deckID: String
    var onDone: () -> Void

    @State private var showAllIssues = false
    @State private var committed = false

    private var deckName: String {
        state.decks.first(where: { $0.id == deckID })?.name ?? "未分类"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: Sp.x4) {
                    summaryCard

                    if !result.issues.isEmpty {
                        issueCard
                    }

                    wordPreviewCard
                }
                .padding(.horizontal, Metric.pagePadding)
                .padding(.top, Sp.x3)
                .padding(.bottom, 120)
            }
            .background(PageBackground())
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回修改") { presentationMode.wrappedValue.dismiss() }
                        .dsFont(size: 15)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    Button("导入 \(result.words.count) 个单词到「\(deckName)」") {
                        commit()
                    }
                    .buttonStyle(PrimaryButtonStyle(isEnabled: !committed))
                    .disabled(committed)
                    .padding(.horizontal, Metric.pagePadding)
                    .padding(.vertical, Sp.x3)
                }
                .background(Color.bg)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            HStack(spacing: Sp.x3) {
                StatCard(title: "可导入", value: "\(result.words.count)", color: .success500)
                StatCard(title: "跳过", value: "\(result.skippedLines)", color: .warning500)
                StatCard(title: "错误", value: "\(result.errorIssues.count)", color: result.errorIssues.isEmpty ? .success500 : .danger500)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(result.summaryText)
                    .dsFont(size: 14, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if result.mergedDuplicates > 0 {
                    Text("文件内有 \(result.mergedDuplicates) 个重复单词已自动合并。")
                        .dsFont(size: 12)
                        .foregroundColor(.textSecondary)
                }
                if result.existingInDeck > 0 {
                    Text("「\(deckName)」里已有 \(result.existingInDeck) 个相同单词，将跳过不重复导入。")
                        .dsFont(size: 12)
                        .foregroundColor(.textSecondary)
                }
                if result.existingInOtherDecks > 0 {
                    Text("另有 \(result.existingInOtherDecks) 个单词存在于其他词单，本次会一并导入到「\(deckName)」。")
                        .dsFont(size: 12)
                        .foregroundColor(.textSecondary)
                }
                if result.backfilledMeanings > 0 {
                    Text("有 \(result.backfilledMeanings) 个单词补全了释义。")
                        .dsFont(size: 12)
                        .foregroundColor(.textSecondary)
                }
            }

            HintBlock(symbol: "checkmark.shield",
                      text: "导入只做「新增」，不会修改或删除你已有的单词与进度。")
        }
        .card(padding: Sp.x4)
    }

    private var issueCard: some View {
        SectionCard(title: "校验结果",
                    subtitle: "\(result.warningIssues.count) 条提示 · \(result.errorIssues.count) 条错误") {
            VStack(alignment: .leading, spacing: Sp.x2) {
                let shown = showAllIssues ? result.issues : Array(result.issues.prefix(6))
                ForEach(shown) { issue in
                    HStack(alignment: .top, spacing: Sp.x2) {
                        Icon(name: issue.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
                             size: 12, weight: .semibold,
                             color: issue.level == .error ? .danger500 : .warning500)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("第 \(issue.line) 行")
                                .dsFont(size: 12, weight: .semibold, maxScale: 1.15)
                                .foregroundColor(.textPrimary)
                            Text(issue.message)
                                .dsFont(size: 12)
                                .foregroundColor(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if result.issues.count > 6 {
                    Button(showAllIssues ? "收起" : "查看全部 \(result.issues.count) 条") {
                        showAllIssues.toggle()
                    }
                    .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.brand500)
                }
            }
        }
    }

    private var wordPreviewCard: some View {
        SectionCard(title: "单词预览", subtitle: "前 \(min(result.words.count, 10)) 个") {
            VStack(spacing: 0) {
                ForEach(Array(result.words.prefix(10).enumerated()), id: \.offset) { index, item in
                    HStack(spacing: Sp.x3) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Sp.x2) {
                                Text(item.text)
                                    .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                                    .foregroundColor(.textPrimary)
                                if !item.pos.isEmpty { PlainChip(text: item.pos, color: .textTertiary) }
                            }
                            Text(item.meaning.isEmpty ? "待补充释义" : item.meaning)
                                .dsFont(size: 13)
                                .foregroundColor(item.meaning.isEmpty ? .warning500 : .textSecondary)
                        }
                        Spacer(minLength: 0)
                        if !item.rootSpec.isEmpty {
                            Text(item.rootSpec)
                                .dsFont(size: 11)
                                .foregroundColor(.textTertiary)
                        }
                    }
                    .padding(.vertical, Sp.x2)

                    if index != min(result.words.count, 10) - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func commit() {
        state.commitImport(result, toDeckID: deckID)
        committed = true
        state.showToast("已导入 \(result.words.count) 个单词")
        onDone()
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - 系统文件选择器（iOS 14+，替代 iOS 16 的 fileImporter）

struct DocumentPicker: UIViewControllerRepresentable {

    let allowed: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowed, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
