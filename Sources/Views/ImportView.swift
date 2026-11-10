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
                    smartImportCard
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

    // MARK: 智能导入（OCR 识别 / 大词库选词）

    private var smartImportCard: some View {
        SectionCard(title: "智能导入", subtitle: "拍单词书页识别导入 · 内置大词库选词") {
            VStack(spacing: Sp.x2) {
                NavigationLink(destination: OcrImportView(preselectedDeckID: targetDeckID)
                    .environmentObject(state)) {
                    smartRow(symbol: "camera.viewfinder",
                             title: "拍照识别单词",
                             subtitle: "拍单词书页，Vision 识别单词与释义并做词典校验")
                }
                NavigationLink(destination: ECDictPickerView(preselectedDeckID: targetDeckID)
                    .environmentObject(state)) {
                    smartRow(symbol: "text.book.closed",
                             title: "EC Dictionary 大词库",
                             subtitle: "按前缀浏览内置 77 万词条常用词，勾选导入")
                }
            }
        }
    }

    private func smartRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Sp.x3) {
            Icon(name: symbol, size: 20, weight: .medium, color: .brand500)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text(subtitle)
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
            }
            Spacer(minLength: 0)
            Icon(name: "chevron.right", size: 13, weight: .semibold, color: .textTertiary)
        }
        .padding(.horizontal, Sp.x3)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
                .fill(Color.surface)
        )
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
    ///
    /// 「粘贴文本」是特例：**无论是否已是当前来源，点击都会读取系统剪贴板并填入输入框**。
    /// 因为默认来源本身就是 .paste，若不特判「再次点击」，按钮点击会因 `item == source`
    /// 直接 return，出现"点了没反应"——用户期待的是点一下就把剪贴板内容贴进来。
    private func switchSource(to item: Source, presentPicker: Bool = true) {
        if item == source {
            // 重复点同一个来源不清空内容（避免误点把正在编辑的文本抹掉）；
            // 「从文件导入」再点一次等于「重新选文件」
            if item == .file && presentPicker { showPicker = true }
            // 「粘贴文本」再点一次 = 再次从剪贴板拉取（已有内容时追加到末尾）
            if item == .paste {
                pasteFromClipboard(appendToExisting: true)
            }
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
            // 切到「粘贴文本」：先恢复本来源旧草稿，再读取剪贴板。
            // 旧草稿非空时剪贴板内容追加到末尾（appendToExisting: true），
            // 避免把用户已编辑的内容覆盖掉；旧草稿为空则直接填入。
            rawText = pasteDraft
            pasteFromClipboard(appendToExisting: !pasteDraft.isEmpty)
        case .file:
            rawText = fileDraft
            if presentPicker { showPicker = true }
        case .template:
            rawText = templateDraft.isEmpty ? ImportView.csvTemplate : templateDraft
            templateDraft = rawText
        }
    }

    /// 从系统剪贴板读取文本并填入当前输入框（「粘贴文本」按钮的核心行为）。
    /// - appendToExisting: true 时把剪贴板内容追加到已有内容末尾（自动补换行避免粘连）；
    ///                     false 时（输入框为空）直接填入。
    /// 剪贴板为空时 toast「剪贴板为空」，不静默；读取成功 toast「已从剪贴板粘贴 N 行」。
    private func pasteFromClipboard(appendToExisting: Bool) {
        let clipped = (UIPasteboard.general.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipped.isEmpty else {
            state.showToast("剪贴板为空")
            return
        }

        if appendToExisting && !rawText.isEmpty {
            // 追加语义：已有内容保留，先保证末尾换行再拼接，两段内容不会粘在同一行
            let separator = rawText.hasSuffix("\n") ? "" : "\n"
            rawText += separator + clipped
        } else {
            rawText = clipped
        }
        // 与 pasteDraft 同步：后续切走再切回，粘贴内容不会丢
        pasteDraft = rawText
        let lines = clipped.components(separatedBy: .newlines).count
        state.showToast("已从剪贴板粘贴 \(lines) 行")
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
                    Text("每行一个单词或词组，冒号前是单词、冒号后是释义（也兼容 @ / Tab / 逗号 / 竖线旧格式）：\n\ndisease:n. 疾病，病\ndish:n. （烹制好的）菜肴，一道菜\neach other:互相，彼此")
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
                bullet("默认格式（推荐）：每行一个「单词:释义」，如 disease:n. 疾病，病；词性前缀（n./adj./v. 等）会自动识别并剥离")
                bullet("单词可以是词组：each other、good morning（词与词之间用空格，最多 4 个词），词组不参与词根拆解")
                bullet("旧格式仍兼容：单词@释义@音标@词性@词根拆解@记忆法@例句@例句翻译@词单名，只有第 1 列必填")
                bullet("分隔符自动识别：:（半角/全角）→ @ / Tab / 英文逗号 / 中文逗号 / 竖线")
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
    # 每行一个「单词:释义」（词性自动识别，词根自动解析）
    disease:n. 疾病，病
    dish:n. （烹制好的）菜肴，一道菜
    dodo:n. 渡渡鸟
    each other:互相，彼此
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
