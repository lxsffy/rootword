//
//  Components.swift
//  RootWord · 词根单词
//
//  跨页面复用的 UI 组件（产品设计文档 5.18 全局状态组件 + 各页公共元素）：
//  C01 Toast、C02 确认弹窗、C04 骨架屏、空状态模板、词根 chip、进度环、
//  指标卡、热力图、预测柱状图、词单行、单词行。
//
//  纯 SwiftUI 绘制，无位图资源，无第三方依赖。
//

import SwiftUI

// MARK: - C01 Toast

/// 全局轻提示中心：同屏最多 1 个，新 Toast 替换旧 Toast（不排队）
final class ToastCenter: ObservableObject {

    @Published var message: String?
    @Published var confirm: ConfirmRequest?

    private var dismissWorkItem: DispatchWorkItem?

    func show(_ text: String) {
        dismissWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { message = text }
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.message = nil }
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    func ask(_ request: ConfirmRequest) {
        withAnimation(.easeOut(duration: 0.2)) { confirm = request }
    }

    func dismissConfirm() {
        withAnimation(.easeOut(duration: 0.2)) { confirm = nil }
    }
}

struct ToastOverlay: View {

    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .dsFont(size: 14, weight: .regular, maxScale: 1.3)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Sp.x4)
                .padding(.vertical, Sp.x3)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(Color.overlayDark)
                )
                .padding(.horizontal, Sp.x5)
                .padding(.bottom, 24)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - C02 确认弹窗

struct ConfirmRequest: Identifiable {

    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String = "确认"
    /// 危险操作：需要两次点击确认（文档 5.18.2）
    var destructive: Bool = false
    /// 高危操作：需输入指定文字才能激活确认按钮（如「清空」）
    var requiresTyping: String?
    var action: () -> Void
}

struct ConfirmDialogView: View {

    let request: ConfirmRequest
    let onDismiss: () -> Void

    @State private var typed: String = ""
    @State private var armed: Bool = false

    private var confirmEnabled: Bool {
        if let keyword = request.requiresTyping {
            return typed.trimmingCharacters(in: .whitespaces) == keyword
        }
        return true
    }

    private var confirmTitle: String {
        if request.destructive && !armed && request.requiresTyping == nil {
            return request.confirmTitle + "（再点一次）"
        }
        return request.confirmTitle
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: Sp.x4) {
                Text(request.title)
                    .dsFont(size: 17, weight: .semibold)
                    .foregroundColor(.textPrimary)

                Text(request.message)
                    .dsFont(size: 14)
                    .foregroundColor(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let keyword = request.requiresTyping {
                    TextField("请输入「\(keyword)」", text: $typed)
                        .dsFont(size: 15)
                        .padding(.horizontal, Sp.x3)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                .fill(Color.surfaceAlt)
                        )
                }

                HStack(spacing: Sp.x3) {
                    Button("取消") { onDismiss() }
                        .buttonStyle(SecondaryButtonStyle(tint: .textSecondary))

                    Button(confirmTitle) {
                        if request.destructive && !armed && request.requiresTyping == nil {
                            armed = true          // 第一次点击只"上膛"
                            return
                        }
                        onDismiss()
                        request.action()
                    }
                    .buttonStyle(PrimaryButtonStyle(fill: request.destructive ? .danger500 : .brand500,
                                                    isEnabled: confirmEnabled))
                    .disabled(!confirmEnabled)
                }
            }
            .padding(Sp.x5)
            .background(
                RoundedRectangle(cornerRadius: Radius.sheet, style: .continuous)
                    .fill(Color.surface)
            )
            .padding(.horizontal, Sp.x6)
            .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
        }
    }
}

// MARK: - C04 骨架屏（shimmer，6.6 允许的唯一循环动效之一）

struct SkeletonBlock: View {

    var height: CGFloat = 16
    var radius: CGFloat = 8

    @State private var phase: CGFloat = -1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.disabledFill)
            .frame(height: height)
            .overlay(
                GeometryReader { geo in
                    if !UIAccessibility.isReduceMotionEnabled {
                        LinearGradient(colors: [.clear, Color.white.opacity(scheme == .dark ? 0.12 : 0.5), .clear],
                                       startPoint: .leading,
                                       endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .onAppear {
                guard !UIAccessibility.isReduceMotionEnabled else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

// MARK: - 空状态模板（5.18.5）

struct IllustrationBadge: View {

    var symbol: String = "book"

    var body: some View {
        ZStack {
            Circle().fill(Color.brand500.opacity(0.10)).frame(width: 96, height: 96)
            Circle().fill(Color.brand500.opacity(0.06)).frame(width: 70, height: 70)
            Icon(name: symbol, size: 30, weight: .regular, color: .brand500)
        }
        .accessibilityHidden(true)
    }
}

struct EmptyStateView: View {

    var symbol: String = "book"
    var title: String
    var message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: Sp.x4) {
            IllustrationBadge(symbol: symbol)

            Text(title)
                .dsFont(size: 17, weight: .semibold)
                .foregroundColor(.textPrimary)
                .multilineTextAlignment(.center)

            Text(message)
                .dsFont(size: 14)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Sp.x4)

            if let primaryTitle = primaryTitle, let primaryAction = primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, Sp.x6)
                    .padding(.top, Sp.x1)
            }

            if let secondaryTitle = secondaryTitle, let secondaryAction = secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .dsFont(size: 15, weight: .medium)
                    .foregroundColor(.brand500)
                    .frame(minHeight: Metric.hitMin)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Sp.x6)
    }
}

// MARK: - 词根 chip（P05 / P10 的核心视觉）

struct RootChip: View {

    let segment: WordSegment
    var onTap: (() -> Void)?

    var body: some View {
        let color = segment.type.chipColor
        Group {
            if let onTap = onTap {
                Button(action: onTap) { content(color: color) }
                    .buttonStyle(PressScaleStyle(scale: 0.97))
                    .accessibilityLabel(segment.displayText)
            } else {
                content(color: color)
                    .accessibilityLabel(segment.displayText)
            }
        }
    }

    private func content(color: Color) -> some View {
        VStack(spacing: 2) {
            Text(segment.text)
                .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
                .foregroundColor(color)
            if !segment.meaning.isEmpty {
                Text(segment.meaning)
                    .dsFont(size: 11, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Sp.x3)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .stroke(color.opacity(0.28), lineWidth: 1)
        )
        // 视觉高度 28 pt，热区扩展到 44 pt（6.8）
        .frame(minHeight: Metric.hitMin)
    }
}

/// 未收录构词时的单色 chip
struct PlainChip: View {

    let text: String
    var color: Color = .textTertiary

    var body: some View {
        Text(text)
            .dsFont(size: 15, weight: .semibold, maxScale: 1.15)
            .foregroundColor(color)
            .padding(.horizontal, Sp.x3)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .stroke(color.opacity(0.24), lineWidth: 1)
            )
            .frame(minHeight: Metric.hitMin)
    }
}

// MARK: - 进度环（P03 / P06）

struct ProgressRing: View {

    var progress: Double
    var size: CGFloat = Metric.ringSize
    var lineWidth: CGFloat = 14
    /// 今日完成：中心显示对勾（品牌渐变）
    var showsCheckmark: Bool = false
    var centerTitle: String?
    var centerSubtitle: String?
    var footNote: String?

    private var clamped: Double { max(0, min(1, progress)) }

    var body: some View {
        VStack(spacing: Sp.x3) {
            ZStack {
                Circle()
                    .stroke(Color.disabledFill, lineWidth: lineWidth)

                if showsCheckmark {
                    Circle()
                        .stroke(Color.brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    Icon(name: "checkmark", size: size * 0.28, weight: .bold, color: .brand500)
                } else {
                    Circle()
                        .trim(from: 0, to: max(0.0005, clamped))
                        .stroke(Color.brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: clamped)

                    VStack(spacing: 2) {
                        if let centerTitle = centerTitle {
                            Text(centerTitle)
                                .dsFont(size: 26, weight: .bold, maxScale: 1.15)
                                .foregroundColor(.textPrimary)
                        }
                        if let centerSubtitle = centerSubtitle {
                            Text(centerSubtitle)
                                .dsFont(size: 13)
                                .foregroundColor(.textSecondary)
                        }
                    }
                }
            }
            .frame(width: size, height: size)

            if let footNote = footNote {
                Text(footNote)
                    .dsFont(size: 13)
                    .foregroundColor(.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日进度 \(Int(clamped * 100))%")
    }
}

// MARK: - 指标卡（P03 新词/复习、P16 统计）

struct StatCard: View {

    let title: String
    let value: String
    var subtitle: String?
    var color: Color = .brand500
    var onTap: (() -> Void)?

    var body: some View {
        Group {
            if let onTap = onTap {
                Button(action: onTap) { content }
                    .buttonStyle(PressScaleStyle(scale: 0.98))
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Sp.x2) {
            Text(title)
                .dsFont(size: 13)
                .foregroundColor(.textSecondary)
            Text(value)
                .dsFont(size: 24, weight: .bold, maxScale: 1.2)
                .foregroundColor(color)
            if let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .dsFont(size: 11, weight: .medium, maxScale: 1.2)
                    .foregroundColor(.warning500)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - 通用区块卡片

struct SectionCard<Content: View>: View {

    var title: String?
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            if let title = title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .dsFont(size: 15, weight: .semibold)
                        .foregroundColor(.textPrimary)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .dsFont(size: 12)
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - 记忆法 / 提示块（图标 + 灰底，不使用 Emoji）

struct HintBlock: View {

    var symbol: String = "lightbulb"
    var text: String
    var tint: Color = .brand500

    var body: some View {
        HStack(alignment: .top, spacing: Sp.x2) {
            Icon(name: symbol, size: 14, weight: .medium, color: tint)
            Text(text)
                .dsFont(size: 14)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Sp.x3)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Color.surfaceAlt)
        )
    }
}

/// 黄色警告条 / 绿色成功条 / 红色错误条（P12 预览页）
struct BannerView: View {

    enum Kind { case success, warning, error, info }

    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .success: return .success500
        case .warning: return .warning500
        case .error:   return .danger500
        case .info:    return .info500
        }
    }

    private var symbol: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Sp.x2) {
            Icon(name: symbol, size: 14, weight: .medium, color: color)
            Text(text)
                .dsFont(size: 13)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Sp.x3)
        .background(
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(color.opacity(0.12))
        )
    }
}

// MARK: - 掌握度色点

struct PhaseDot: View {

    let phase: Phase
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(phase.dotColor)
            .frame(width: size, height: size)
            .accessibilityLabel(phase.cnLabel)
    }
}

// MARK: - 单词行（P09）

struct WordRow: View {

    let word: Word
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: Sp.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(word.text)
                    .dsFont(size: 17, weight: .semibold)
                    .foregroundColor(.textPrimary)
                Text(word.displayMeaning)
                    .dsFont(size: 13)
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            PhaseDot(phase: word.srs.phase)
            if showsChevron {
                Icon(name: "chevron.right", size: 13, weight: .semibold, color: .textTertiary)
            }
        }
        .padding(.horizontal, Metric.rowHPadding)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

// MARK: - 热力图（P16，近 12 周 × 7 天）

struct HeatmapGrid: View {

    /// 84 天数据（含今日），按时间升序
    let days: [(date: Date, count: Int)]
    var onSelect: ((Int) -> Void)?

    private let cell: CGFloat = 12
    private let gap: CGFloat = 3

    private var maxCount: Int { max(1, days.map { $0.count }.max() ?? 1) }

    private func level(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let ratio = Double(count) / Double(maxCount)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.5 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    private func color(for level: Int) -> Color {
        switch level {
        case 0: return Color.disabledFill
        case 1: return Color.brand500.opacity(0.28)
        case 2: return Color.brand500.opacity(0.50)
        case 3: return Color.brand500.opacity(0.74)
        default: return Color.brand500
        }
    }

    var body: some View {
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }

        HStack(alignment: .top, spacing: gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, item in
                        let lv = level(item.count)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: lv))
                            .frame(width: cell, height: cell)
                            .onTapGesture { onSelect?(item.count) }
                            .accessibilityLabel("\(item.count) 张")
                    }
                }
            }
        }
    }
}

// MARK: - 未来复习预测柱状图（P16，纯 SwiftUI 绘制）

struct ForecastChart: View {

    let items: [(date: Date, count: Int)]
    var onTap: ((Int) -> Void)?

    private var maxCount: Int { max(1, items.map { $0.count }.max() ?? 1) }

    private func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "E"
        return f.string(from: date)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Sp.x2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(spacing: Sp.x1) {
                    Text("\(item.count)")
                        .dsFont(size: 11, weight: .medium, maxScale: 1.1)
                        .foregroundColor(.textSecondary)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(item.count > 0 ? Color.brand500 : Color.disabledFill)
                        .frame(height: max(2, CGFloat(item.count) / CGFloat(maxCount) * 96))

                    Text(weekday(item.date))
                        .dsFont(size: 11, maxScale: 1.1)
                        .foregroundColor(.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onTap?(item.count) }
                .accessibilityLabel("\(weekday(item.date)) 预计复习 \(item.count) 张")
            }
        }
        .frame(height: 140, alignment: .bottom)
    }
}

// MARK: - 掌握度堆叠条（P16）

struct MasteryBar: View {

    let newCount: Int
    let learningCount: Int
    let masteredCount: Int

    private var total: Int { max(1, newCount + learningCount + masteredCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: Sp.x3) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(color: .textTertiary, value: newCount, width: geo.size.width)
                    segment(color: .warning500, value: learningCount, width: geo.size.width)
                    segment(color: .success500, value: masteredCount, width: geo.size.width)
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)

            HStack(spacing: Sp.x4) {
                legend(color: .textTertiary, title: "新词", value: newCount)
                legend(color: .warning500, title: "学习中", value: learningCount)
                legend(color: .success500, title: "已掌握", value: masteredCount)
            }
        }
    }

    private func segment(color: Color, value: Int, width: CGFloat) -> some View {
        color.frame(width: width * CGFloat(value) / CGFloat(total))
    }

    private func legend(color: Color, title: String, value: Int) -> some View {
        HStack(spacing: Sp.x1) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) \(value)")
                .dsFont(size: 12, maxScale: 1.15)
                .foregroundColor(.textSecondary)
        }
    }
}

// MARK: - 弹层脚手架（P11 / P12 等 sheet 统一外观）

/// 底部弹层顶部的小横条（视觉锚点，无交互）
struct SheetGrabber: View {

    var body: some View {
        Capsule()
            .fill(Color.disabledFill)
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, Sp.x2)
            .padding(.bottom, Sp.x3)
            .accessibilityHidden(true)
    }
}

/// 通用 sheet 骨架：标题 + 内容 + 底部「取消 / 确认」
struct SheetScaffold<Content: View>: View {

    @Environment(\.presentationMode) private var presentationMode

    var title: String
    var confirmTitle: String = "确认"
    var confirmEnabled: Bool = true
    var onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            SheetGrabber()

            HStack {
                Text(title)
                    .dsFont(size: 18, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Spacer(minLength: 0)
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Icon(name: "xmark", size: 14, weight: .semibold, color: .textSecondary)
                        .frame(width: Metric.hitMin, height: Metric.hitMin)
                }
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, Metric.pagePadding)

            ScrollView {
                content()
                    .padding(.horizontal, Metric.pagePadding)
                    .padding(.vertical, Sp.x4)
            }

            VStack(spacing: Sp.x3) {
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(PrimaryButtonStyle(isEnabled: confirmEnabled))
                    .disabled(!confirmEnabled)
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.bottom, Sp.x6)
        }
        .background(Color.bg)
    }
}
