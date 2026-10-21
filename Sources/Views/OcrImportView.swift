//
//  OcrImportView.swift
//  RootWord · 词根单词
//
//  拍照 / 相册识别单词书页 → OCR（Vision 双 Pass + UITextChecker 单候选纠正）
//  → ECDICT 三层校验标记（⚠ 可疑 / ? 生僻 / 候选）→ 人工审阅微调 →
//  复用 Importer 标准链路生成预览 → 确认导入词单。
//

import SwiftUI
import UIKit

struct OcrImportView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    var preselectedDeckID: String? = nil

    enum Stage {
        case idle, recognizing, results
    }

    @State private var stage: Stage = .idle
    @State private var showCamera = false
    @State private var showLibrary = false
    /// 待编辑图片（拍照/相册回调后先降采样 2048 存入，编辑确认后再送 OCR）
    @State private var editImage: UIImage?
    @State private var entries: [WordEntry] = []
    @State private var ocrError: String?
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
                switch stage {
                case .idle:
                    sourceArea
                    howItWorks
                case .recognizing:
                    recognizingArea
                case .results:
                    resultArea
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, 120)
        }
        .background(PageBackground())
        .navigationTitle("拍照识别")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { presentationMode.wrappedValue.dismiss() }
                    .dsFont(size: 15)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if stage == .results {
                VStack(spacing: 0) {
                    Divider()
                    Button("预览导入 \(validCount) 个单词") { doPreview() }
                        .buttonStyle(PrimaryButtonStyle(isEnabled: validCount > 0 && !isParsing))
                        .disabled(validCount == 0 || isParsing)
                        .padding(.horizontal, Metric.pagePadding)
                        .padding(.vertical, Sp.x3)
                }
                .background(Color.bg)
            }
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { img in handleRawImage(img) }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showLibrary) {
            ImagePicker(sourceType: .photoLibrary) { img in handleRawImage(img) }
                .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { editImage != nil },
                                    set: { if !$0 { editImage = nil } })) {
            if let img = editImage {
                ImageEditView(image: img,
                              onConfirm: { edited in
                                  editImage = nil
                                  handleImage(edited)
                              },
                              onCancel: {
                                  editImage = nil
                                  stage = .idle
                              })
                    .ignoresSafeArea()
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
        .alert(isPresented: Binding(get: { ocrError != nil },
                                    set: { if !$0 { ocrError = nil } })) {
            Alert(title: Text("识别失败"),
                  message: Text(ocrError ?? ""),
                  dismissButton: .default(Text("知道了")))
        }
        .onAppear {
            if deckID.isEmpty {
                deckID = preselectedDeckID ?? state.currentDeck?.id ?? state.decks.first?.id ?? ""
            }
        }
    }

    // MARK: 来源选择

    private var sourceArea: some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            Text("选择图片来源")
                .dsFont(size: 13, weight: .semibold)
                .foregroundColor(.textSecondary)

            HStack(spacing: Sp.x3) {
                sourceButton(title: "拍照", symbol: "camera.fill", action: {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        state.showToast("当前设备不支持相机")
                    }
                })
                sourceButton(title: "相册", symbol: "photo.on.rectangle.angled", action: {
                    if UIImagePickerController.isSourceTypeAvailable(.photoLibrary) {
                        showLibrary = true
                    } else {
                        state.showToast("相册不可用")
                    }
                })
            }
        }
    }

    private func sourceButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Sp.x2) {
                Icon(name: symbol, size: 30, weight: .medium, color: .brand500)
                Text(title)
                    .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Color.surface)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var howItWorks: some View {
        SectionCard(title: "识别说明", subtitle: "Vision OCR · 本地词典校验") {
            VStack(alignment: .leading, spacing: Sp.x2) {
                bullet("对准单词书页拍照或从相册选图，自动识别「单词 + 中文释义」")
                bullet("识别结果经内置 EC Dictionary 大词库三层校验：⚠ 可疑词（查无此词 / 释义对不上）、? 生僻词（不在常见考试词表）")
                bullet("可疑词会给出编辑距离 ≤ 2 的候选词提示，可在下方手动修正")
                bullet("修正后进入「导入预览」，与普通导入一样去重、落库")
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

    // MARK: 识别中

    private var recognizingArea: some View {
        VStack(spacing: Sp.x4) {
            ProgressView()
                .scaleEffect(1.2)
            VStack(spacing: Sp.x2) {
                Text("正在识别…")
                    .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text("首次识别需加载大词库（约 36MB），请稍候")
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Sp.x8)
    }

    // MARK: 识别结果

    private var validCount: Int {
        entries.filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private var resultArea: some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            HStack {
                Text("识别到 \(validCount) 个单词")
                    .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: 0)
                Button("重新识别") {
                    stage = .idle
                    entries = []
                }
                .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                .foregroundColor(.brand500)
            }

            HintBlock(symbol: "checkmark.shield",
                      text: "⚠ = 可疑（词典查无或释义不一致），? = 生僻；带标记的行建议核对，可直接修改下方文字。")

            targetDeckPicker

            if entries.isEmpty {
                EmptyStateView(title: "未识别到有效单词",
                               message: "换一张更清晰、页面更平整的照片再试")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                        EntryRowView(index: index,
                                     word: item.word,
                                     def: item.def,
                                     validation: item.validation,
                                     isLast: index == entries.count - 1,
                                     onWord: { i, v in
                                         if entries.indices.contains(i) { entries[i].word = v }
                                     },
                                     onDef: { i, v in
                                         if entries.indices.contains(i) { entries[i].def = v }
                                     })
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

    // MARK: 识别结果单行（防御性子视图）
    //
    // 历史踩坑：ForEach 行内 TextField 直接绑定「每次 body 求值新建 get/set 的派生
    // Binding」会在 iOS 14 触发 AttributeGraph 无限递归崩溃（EXC_BAD_ACCESS），
    // iOS 15.4 风险虽低但仍属「拍照导单词」页面高危区。这里抽成独立子视图：
    // 行内 TextField 绑定本行私有 @State，值变化经 onChange 回调写回父级数组
    // （带索引守卫），彻底规避派生 Binding 依赖回环。

    private struct EntryRowView: View {
        let index: Int
        let word: String
        let def: String
        let validation: String
        let isLast: Bool
        let onWord: (Int, String) -> Void
        let onDef: (Int, String) -> Void

        @State private var wordText: String
        @State private var defText: String

        init(index: Int, word: String, def: String, validation: String, isLast: Bool,
             onWord: @escaping (Int, String) -> Void,
             onDef: @escaping (Int, String) -> Void) {
            self.index = index
            self.word = word
            self.def = def
            self.validation = validation
            self.isLast = isLast
            self.onWord = onWord
            self.onDef = onDef
            _wordText = State(initialValue: word)
            _defText = State(initialValue: def)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Sp.x2) {
                HStack(spacing: Sp.x2) {
                    TextField("单词", text: $wordText)
                        .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !validation.isEmpty {
                        Text(validation)
                            .dsFont(size: 11, weight: .medium, maxScale: 1.15)
                            .foregroundColor(validation.contains("⚠") ? .warning500 : .textTertiary)
                            .lineLimit(1)
                    }
                }
                TextField("释义（可修改）", text: $defText)
                    .dsFont(size: 13)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
            .padding(.vertical, Sp.x2)
            .onChange(of: wordText) { newValue in
                onWord(index, newValue)
            }
            .onChange(of: defText) { newValue in
                onDef(index, newValue)
            }
            if !isLast { Divider() }
        }
    }

    // MARK: 目标词单

    private var targetDeckPicker: some View {
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

    /// 拍照/相册回调：先降采样为最长边 2048 缩略图再进入编辑页，
    /// 避免 12MP 原图（约 48MB）常驻内存；编辑确认后再走 OCR（内部再降 1600）。
    private func handleRawImage(_ image: UIImage) {
        let thumb = OCRService.downsampled(image, maxDimension: 2048)
        editImage = thumb
    }

    private func handleImage(_ image: UIImage) {
        stage = .recognizing
        entries = []
        OCRService.recognize(image) { result in
            switch result {
            case .success(let items):
                entries = items
                stage = .results
                if items.isEmpty {
                    state.showToast("未识别到有效单词，请换一张更清晰的图片")
                }
            case .failure(let error):
                ocrError = error.localizedDescription
                stage = .idle
            }
        }
    }

    private func doPreview() {
        guard !isParsing, validCount > 0 else { return }
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
                    self.ocrError = self.describe(error)
                }
            }
        }
    }

    private func buildText() -> String {
        entries
            .filter { !$0.word.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { e in
                let w = e.word.trimmingCharacters(in: .whitespaces)
                let d = e.def.trimmingCharacters(in: .whitespaces)
                return d.isEmpty ? w : "\(w)@\(d)"
            }
            .joined(separator: "\n")
    }

    private func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return error.localizedDescription }
        let description = localized.errorDescription ?? error.localizedDescription
        guard let suggestion = localized.recoverySuggestion, !suggestion.isEmpty else { return description }
        return "\(description)\n\(suggestion)"
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
