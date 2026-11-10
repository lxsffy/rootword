//
//  SettingsView.swift
//  RootWord · 词根单词
//
//  P17 设置 / P18 数据管理。文档 5.21、5.22、2.5「参数极简化设计」。
//
//  原则：只暴露 2 个数值 + 2 个开关；破坏性操作一律二次确认，清空类更要输入文字。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {

    @EnvironmentObject private var state: AppState

    // 设置页需要两个 sheet：分享备份 / 选备份文件。挂两个 sheet 到同一视图会互相遮蔽
    // （第一次呈现容易空白），所以统一由一个 item 驱动。
    private enum SettingsSheet: Identifiable {
        case share(URL)
        case restorePicker

        var id: String {
            switch self {
            case .share(let url): return "share-\(url.absoluteString)"
            case .restorePicker:  return "restore-picker"
            }
        }
    }

    @State private var activeSheet: SettingsSheet?
    /// 已通过校验、等待用户二次确认的备份
    @State private var pendingBackup: Store.BackupFile?
    @State private var pendingBackupName = ""
    @State private var restoreFailure: String?

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.x4) {
                studyCard
                switchCard
                accentCard
                dataCard

                Text("RootWord \(AppInfo.shortVersion) · 本地存储，无账号")
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let url):
                ShareSheet(items: [url])
            case .restorePicker:
                DocumentPicker(allowed: [UTType.json, UTType.data]) { url in
                    handlePickedBackup(url)
                }
            }
        }
        .alert(isPresented: Binding(get: { restoreFailure != nil },
                                    set: { if !$0 { restoreFailure = nil } })) {
            Alert(title: Text("无法从备份恢复"),
                  message: Text(restoreFailure ?? ""),
                  dismissButton: .default(Text("知道了")))
        }
    }

    // MARK: 学习参数

    private var studyCard: some View {
        SectionCard(title: "每日任务量", subtitle: "改完立刻生效，明天按新数量排") {
            VStack(spacing: Sp.x4) {
                stepperRow(title: "新词上限",
                           detail: "每天最多学几个新词",
                           value: state.settings.dailyNewLimit,
                           range: AppSettings.newLimitRange,
                           step: AppSettings.newLimitStep,
                           text: state.settings.dailyNewText) { newValue in
                    state.updateSettings { $0.dailyNewLimit = newValue }
                }

                Divider()

                stepperRow(title: "复习上限",
                           detail: "每天最多复习多少个",
                           value: state.settings.dailyReviewLimit,
                           range: AppSettings.reviewLimitRange,
                           step: AppSettings.reviewLimitStep,
                           text: state.settings.dailyReviewText) { newValue in
                    state.updateSettings { $0.dailyReviewLimit = newValue }
                }

                HintBlock(symbol: "leaf",
                          text: "少量多次比一次背 50 个更有效。建议新词 10–15 个。",
                          tint: .info500)
            }
        }
    }

    private func stepperRow(title: String,
                            detail: String,
                            value: Int,
                            range: ClosedRange<Int>,
                            step: Int,
                            text: String,
                            onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: Sp.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text(detail)
                    .dsFont(size: 12)
                    .foregroundColor(.textSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: Sp.x3) {
                Button(action: {
                    let next = max(range.lowerBound, value - step)
                    if next != value { onChange(next); Haptics.light() }
                }) {
                    Icon(name: "minus", size: 14, weight: .semibold, color: value <= range.lowerBound ? .textTertiary : .brand500)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.surfaceAlt))
                }
                .disabled(value <= range.lowerBound)
                .accessibilityLabel("减少\(title)")

                Text(text)
                    .dsFont(size: 16, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                    .frame(minWidth: 58)

                Button(action: {
                    let next = min(range.upperBound, value + step)
                    if next != value { onChange(next); Haptics.light() }
                }) {
                    Icon(name: "plus", size: 14, weight: .semibold, color: value >= range.upperBound ? .textTertiary : .brand500)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.surfaceAlt))
                }
                .disabled(value >= range.upperBound)
                .accessibilityLabel("增加\(title)")
            }
        }
    }

    // MARK: 开关

    private var switchCard: some View {
        SectionCard(title: "学习体验") {
            VStack(spacing: Sp.x4) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("进卡片自动朗读")
                            .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                            .foregroundColor(.textPrimary)
                        Text("只读单词本身，不读释义")
                            .dsFont(size: 12)
                            .foregroundColor(.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { state.settings.autoPlayAudio },
                        set: { value in
                            state.updateSettings { $0.autoPlayAudio = value }
                            if value { SpeechService.shared.speak("hello", accent: state.settings.accent) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: .brand500))
                    .accessibilityLabel("进卡片自动朗读")
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("震动反馈")
                            .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                            .foregroundColor(.textPrimary)
                        Text("评分、完成、错误时轻震")
                            .dsFont(size: 12)
                            .foregroundColor(.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: Binding(
                        get: { state.settings.hapticEnabled },
                        set: { value in
                            state.updateSettings { $0.hapticEnabled = value }
                            if value { Haptics.light() }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: .brand500))
                    .accessibilityLabel("震动反馈")
                }
            }
        }
    }

    // MARK: 口音

    private var accentCard: some View {
        SectionCard(title: "发音口音") {
            VStack(spacing: Sp.x3) {
                HStack(spacing: Sp.x2) {
                    accentChip("美式 en-US", value: "en-US")
                    accentChip("英式 en-GB", value: "en-GB")
                    Spacer(minLength: 0)
                    Button(action: {
                        SpeechService.shared.speak("schedule", accent: state.settings.accent)
                    }) {
                        Label("试听", systemImage: "speaker.wave.2")
                            .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                    }
                    .buttonStyle(SecondaryButtonStyle(height: 36))
                }
                HintBlock(symbol: "info.circle",
                          text: "使用系统语音合成，不会下载音频文件。",
                          tint: .info500)
            }
        }
    }

    private func accentChip(_ title: String, value: String) -> some View {
        let active = state.settings.accent == value
        return Button(action: {
            state.updateSettings { $0.accent = value }
            SpeechService.shared.speak("word", accent: value)
        }) {
            Text(title)
                .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                .foregroundColor(active ? .white : .textSecondary)
                .padding(.horizontal, Sp.x3)
                .frame(height: 36)
                .background(Capsule().fill(active ? Color.brand500 : Color.surfaceAlt))
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: 数据管理

    private var dataCard: some View {
        VStack(spacing: Sp.x3) {
            SectionCard(title: "数据管理", subtitle: "单词与进度都存在这台设备上") {
                VStack(spacing: 0) {
                    actionRow(symbol: "square.and.arrow.up",
                              title: "导出备份",
                              detail: "生成 JSON 备份，可在「文件」App 的「背多分」文件夹里找到",
                              color: .brand500) {
                        let outcome = state.exportBackup()
                        if let url = outcome.url {
                            activeSheet = .share(url)
                        } else {
                            state.showToast(outcome.error ?? "导出失败，请稍后重试",
                                            icon: "xmark.circle.fill",
                                            isError: true)
                        }
                    }

                    Divider().padding(.leading, 44)

                    actionRow(symbol: "square.and.arrow.down",
                              title: "从备份导入",
                              detail: "选择 rootword-backup-*.json，覆盖当前全部数据",
                              color: .warning500) {
                        activeSheet = .restorePicker
                    }

                    Divider().padding(.leading, 44)

                    actionRow(symbol: "clock.arrow.circlepath",
                              title: "清空复习记录",
                              detail: "只删历史记录，单词与进度保留",
                              color: .warning500) {
                        ConfirmCenter.shared.ask(ConfirmRequest(
                            title: "清空复习记录？",
                            message: "热力图、连续天数、正确率会全部归零，但单词和已安排的复习时间不受影响。此操作不可撤销。",
                            confirmTitle: "清空记录",
                            destructive: true,
                            action: {
                                state.clearHistory()
                                state.showToast("复习记录已清空")
                            }))
                    }

                    Divider().padding(.leading, 44)

                    actionRow(symbol: "arrow.counterclockwise",
                              title: "重置全部学习进度",
                              detail: "所有单词回到「新词」，需重新学一遍",
                              color: .warning500) {
                        ConfirmCenter.shared.ask(ConfirmRequest(
                            title: "重置全部进度？",
                            message: "\(state.words.count) 个单词都会回到未学习状态，复习记录一并清空。单词本身会保留。此操作不可撤销。",
                            confirmTitle: "重置进度",
                            destructive: true,
                            action: {
                                state.resetWordProgress()
                                state.showToast("已重置全部学习进度")
                            }))
                    }
                }
            }

            SectionCard {
                actionRow(symbol: "trash",
                          title: "清空所有数据",
                          detail: "删除单词、词单、记录与设置，回到初始状态",
                          color: .danger500) {
                    ConfirmCenter.shared.ask(ConfirmRequest(
                        title: "清空所有数据？",
                        message: "App 会自动先导出一份备份到本地，然后删除全部单词、词单、复习记录与设置。这是不可撤销的操作。",
                        confirmTitle: "清空所有数据",
                        destructive: true,
                        requiresTyping: "清空",
                        action: {
                            if state.wipeAllData() {
                                state.showToast("已清空所有数据，清空前备份已存入「文件」App")
                            } else {
                                state.showToast("已清空数据，但清空前备份没能生成",
                                                icon: "exclamationmark.triangle.fill",
                                                isError: true)
                            }
                        }))
                }
            }
        }
    }

    // MARK: - 从备份恢复

    /// 选到备份文件后：先只读校验一遍（格式 / 版本 / 内容），
    /// 校验通过再弹二次确认——避免用户在确认框里点了「覆盖」，之后才发现文件不可用。
    private func handlePickedBackup(_ url: URL) {
        do {
            let backup = try state.readBackup(from: url)
            pendingBackup = backup
            pendingBackupName = url.lastPathComponent

            // 等文件选择器完全收起再弹确认框，否则弹窗会被 sheet 盖住
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let pending = pendingBackup else { return }
                ConfirmCenter.shared.ask(ConfirmRequest(
                    title: "用备份覆盖当前数据？",
                    message: confirmMessage(for: pending),
                    confirmTitle: "覆盖并恢复",
                    destructive: true,
                    requiresTyping: "恢复",
                    action: { applyPendingRestore() }))
            }
        } catch {
            pendingBackup = nil
            restoreFailure = describeBackupError(error)
        }
    }

    private func confirmMessage(for backup: Store.BackupFile) -> String {
        let exportedAt = Self.backupDateFormatter.string(from: backup.exportedAt)
        return """
        备份：\(pendingBackupName)（\(exportedAt) 导出）
        恢复后可得到 \(backup.words.count) 个单词、\(backup.decks.count) 个词单、\(backup.logs.count) 条复习记录。

        当前设备上的 \(state.words.count) 个单词、\(state.decks.count) 个词单、\(state.logs.count) 条复习记录与全部设置都会被这份备份替换，此操作不可撤销。
        """
    }

    private func applyPendingRestore() {
        guard let backup = pendingBackup else { return }
        state.restoreBackup(backup)
        pendingBackup = nil
        state.showToast("已从备份恢复 \(backup.words.count) 个单词")
    }

    private func describeBackupError(_ error: Error) -> String {
        guard let localized = error as? LocalizedError else { return error.localizedDescription }
        let description = localized.errorDescription ?? error.localizedDescription
        guard let suggestion = localized.recoverySuggestion, !suggestion.isEmpty else { return description }
        return "\(description)\n\(suggestion)"
    }

    private func actionRow(symbol: String,
                           title: String,
                           detail: String,
                           color: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Sp.x3) {
                Icon(name: symbol, size: 16, weight: .medium, color: color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .dsFont(size: 15, weight: .medium, maxScale: 1.15)
                        .foregroundColor(.textPrimary)
                    Text(detail)
                        .dsFont(size: 12)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Icon(name: "chevron.right", size: 12, weight: .semibold, color: .textTertiary)
            }
            .padding(.vertical, Sp.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.99))
    }
}

// MARK: - 分享面板（iOS 14+，替代 iOS 16 的 ShareLink）

struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
