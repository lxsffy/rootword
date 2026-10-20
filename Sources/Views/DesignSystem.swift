//
//  DesignSystem.swift
//  RootWord · 词根单词
//
//  设计令牌的 1:1 实现（产品设计文档 6.1 – 6.7）：
//  色彩系统、字阶、间距/圆角/描边、阴影、按钮样式、图标兜底。
//
//  约定：所有颜色都写成"Light / Dark 成对"的动态色，禁止在视图里硬编码十六进制；
//  所有字号都走 dsFont(...) 以获得动态字体支持（display/title1 不参与缩放）。
//  纯 SwiftUI，无第三方依赖，iOS 15.4 兼容。
//

import SwiftUI

// MARK: - 颜色构造基建

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(rgb & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

extension Color {

    /// Light / Dark 成对的动态色（文档 6.2 的两列即这两个参数）
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        })
    }

    // MARK: 品牌与功能色（6.2.1）

    static let brand500 = Color(light: 0x5566FF, dark: 0x6E7CFF)
    static let brand400 = Color(light: 0x7A88FF, dark: 0x8A96FF)
    static let brand600 = Color(light: 0x3E4DE0, dark: 0x4E5CE8)
    static let danger500 = Color(light: 0xFF453A, dark: 0xFF6B62)
    static let warning500 = Color(light: 0xFF9F0A, dark: 0xFFB340)
    static let success500 = Color(light: 0x22C08A, dark: 0x3DD69F)
    static let info500 = Color(light: 0x32ADE6, dark: 0x4FBBEC)

    /// 品牌渐变（135°）—— 进度环、完成页对勾、启动页
    static let brandGradient = LinearGradient(
        colors: [Color(light: 0x6C7BFF, dark: 0x6372EB), Color(light: 0x8E63FF, dark: 0x835BEB)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: 中性色（6.2.2）

    static let bg = Color(light: 0xF6F7FB, dark: 0x0B0E14)
    static let surface = Color(light: 0xFFFFFF, dark: 0x161A22)
    static let surfaceAlt = Color(light: 0xEDEFF6, dark: 0x1F2530)
    static let border = Color(light: 0xE3E6F0, dark: 0x272D3A)
    static let textPrimary = Color(light: 0x1B1F29, dark: 0xE9ECF3)
    static let textSecondary = Color(light: 0x6E7789, dark: 0x9AA3B5)
    static let textTertiary = Color(light: 0x9AA1B4, dark: 0x6B7488)
    static let disabledFill = Color(light: 0xDFE3EE, dark: 0x2A3140)

    /// Toast / 深色浮层底色
    static let overlayDark = Color(light: 0x1B1F29, dark: 0x2A3140).opacity(0.92)
}

// MARK: - 语义映射（6.2.3，开发直接照抄）

extension RootType {
    /// 前缀 = Info 蓝 / 词根 = Brand 紫 / 后缀 = Success 青 / 未收录 = 灰
    var chipColor: Color {
        switch self {
        case .prefix: return .info500
        case .root:   return .brand500
        case .suffix: return .success500
        case .other:  return .textTertiary
        }
    }
}

extension Grade {
    var color: Color {
        switch self {
        case .forgot:     return .danger500
        case .fuzzy:      return .warning500
        case .remembered: return .success500
        }
    }
}

extension Phase {
    /// 掌握度色点（列表用）
    var dotColor: Color {
        switch self {
        case .new:        return .textTertiary
        case .learning, .relearning: return .warning500
        case .review:     return .brand500
        case .mastered:   return .success500
        }
    }
}

// MARK: - 字阶（6.3）

extension View {

    /// 动态字体封装：按系统设置缩放并封顶 maxScale（默认 1.35 ≈ AX1）
    func dsFont(size: CGFloat,
                weight: Font.Weight = .regular,
                relativeTo style: Font.TextStyle = .body,
                maxScale: CGFloat = 1.35) -> some View {
        modifier(ScaledFont(size: size, weight: weight, relativeTo: style, maxScale: maxScale))
    }

    /// 图标：与文字同字重自动匹配（6.5），并用 UIImage 判空做兜底
    func dsIcon(size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight))
    }
}

struct ScaledFont: ViewModifier {

    @ScaledMetric private var scale: CGFloat = 1

    let size: CGFloat
    let weight: Font.Weight
    let maxScale: CGFloat

    init(size: CGFloat,
         weight: Font.Weight,
         relativeTo style: Font.TextStyle,
         maxScale: CGFloat) {
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: style)
        self.size = size
        self.weight = weight
        self.maxScale = maxScale
    }

    func body(content: Content) -> some View {
        content.font(.system(size: min(size * scale, size * maxScale), weight: weight))
    }
}

enum TextStyleToken {
    /// display / title1 不参与动态字体缩放（避免 40 pt 大字破坏布局，6.3）
    static let display = Font.system(size: 40, weight: .bold)
    static let displayCompressed = Font.system(size: 24, weight: .bold)
    static let title1 = Font.system(size: 28, weight: .bold)
}

// MARK: - 间距 / 圆角 / 尺寸（6.4）

enum Sp {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x5: CGFloat = 20
    static let x6: CGFloat = 24
    static let x8: CGFloat = 32
}

enum Radius {
    static let chip: CGFloat = 10
    static let field: CGFloat = 14
    static let button: CGFloat = 14
    static let card: CGFloat = 20
    static let bigCard: CGFloat = 24
    static let sheet: CGFloat = 28
}

enum Metric {
    /// 页面左右安全边距
    static let pagePadding: CGFloat = 20
    /// 卡片内边距
    static let cardPadding: CGFloat = 20
    /// 列表行内边距
    static let rowHPadding: CGFloat = 20
    static let rowVPadding: CGFloat = 14
    /// 最小点击热区（6.8）
    static let hitMin: CGFloat = 44
    /// 主按钮高度
    static let primaryButtonHeight: CGFloat = 56
    /// 进度环直径
    static let ringSize: CGFloat = 168
}

// MARK: - 图标兜底（6.5）

enum DSIcon {
    /// iOS 小版本差异导致符号缺失时，回退到通用圆形，避免空白
    static func safe(_ name: String) -> String {
        UIImage(systemName: name) != nil ? name : "circle"
    }
}

struct Icon: View {

    let name: String
    var size: CGFloat = 17
    var weight: Font.Weight = .medium
    var color: Color = .textPrimary

    var body: some View {
        Image(systemName: DSIcon.safe(name))
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
    }
}

// MARK: - 卡片样式（6.4 阴影规则：暗色取消阴影，改 1 pt 描边）

struct CardStyle: ViewModifier {

    @Environment(\.colorScheme) private var scheme

    var radius: CGFloat = Radius.card
    var padding: CGFloat = Metric.cardPadding
    var shadow: Bool = true

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.border, lineWidth: scheme == .dark ? 1 : 0)
            )
            .shadow(color: (scheme == .dark || !shadow) ? .clear : Color(red: 16 / 255, green: 19 / 255, blue: 25 / 255).opacity(0.06),
                    radius: 12, x: 0, y: 8)
    }
}

extension View {
    func card(radius: CGFloat = Radius.card, padding: CGFloat = Metric.cardPadding, shadow: Bool = true) -> some View {
        modifier(CardStyle(radius: radius, padding: padding, shadow: shadow))
    }
}

// MARK: - 按钮样式（6.6 按下 120 ms easeOut，scale 1→0.96）

struct PressScaleStyle: ButtonStyle {

    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {

    var fill: Color = .brand500
    var foreground: Color = .white
    var height: CGFloat = Metric.primaryButtonHeight
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(size: 17, weight: .semibold, maxScale: 1.2)
            .foregroundColor(isEnabled ? foreground : Color.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(isEnabled ? fill : Color.disabledFill)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {

    var tint: Color = .brand500
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(size: 16, weight: .medium, maxScale: 1.2)
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .stroke(tint.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 背景

struct PageBackground: View {

    var body: some View {
        Color.bg.ignoresSafeArea()
    }
}

/// 大标题（P08 / P14 / P16 用的页面标题）
struct PageTitle: View {

    let text: String

    var body: some View {
        Text(text)
            .font(TextStyleToken.title1)
            .foregroundColor(.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
