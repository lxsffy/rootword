import SwiftUI
import UIKit

/// 拍照/选图后的手动编辑页：自由比例「边界拖拽」裁剪 + 微旋转（-10°~+10°，步进 0.5°）。
///
/// 交互设计：
/// - 裁剪：四边与四角均为独立把手，边拖拽只改变单边位置，角拖拽同时改变相邻两边；
///   支持任意比例（不锁宽高比），裁剪框约束在图像显示区域内（最小 15%）。
/// - 旋转：微调角度（滑块 ±0.5° 步进），实时预览 + 水平参考线辅助对齐；
///   旋转只作用于显示与最终输出，裁剪框以「相对旋转后图像」的归一化坐标保持相对位置。
/// - 输出：先按微调角度旋转整图（画布扩展为外接矩形、留白透明），再按裁剪框 rect 裁剪。
///
/// 内存与兼容：编辑页只持有降采样图（最长边 2048）；旋转/裁剪在 autoreleasepool 内完成；
/// 纯 SwiftUI + UIGraphicsImageRenderer / CGContext，iOS 15.4 兼容，无三方库。
struct ImageEditView: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    /// 源缩略图（正立，最长边 2048）
    @State private var displayImage: UIImage
    /// 按当前微调角度实时重绘的预览图
    @State private var renderedImage: UIImage
    /// 微调角度（度），-10° ~ +10°，步进 0.5°
    @State private var rotationAngle: Double = 0
    /// 裁剪框（归一化 0..1，相对旋转后图像的显示区域；旋转时保持相对位置）
    @State private var cropNorm: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var containerSize: CGSize = .zero
    /// 拖拽把手时的手势起点（同一时刻只操作一个把手）
    @State private var handleStart: CGRect? = nil

    init(image: UIImage,
         onConfirm: @escaping (UIImage) -> Void,
         onCancel: @escaping () -> Void) {
        self.image = image
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _displayImage = State(initialValue: image)
        _renderedImage = State(initialValue: image)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            canvas
            rotateBar
            footer
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: rotationAngle) { newValue in
            renderedImage = ImageEditUtil.rotated(displayImage, angleDegrees: newValue)
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack {
            Button("取消") { onCancel() }
                .foregroundColor(.white)
            Spacer()
            Text("裁剪图片")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Button("重置") { resetEditing() }
                .foregroundColor(.white)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// 重置角度与裁剪框为全图
    private func resetEditing() {
        rotationAngle = 0
        cropNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
        renderedImage = displayImage
    }

    // MARK: - 画布

    private var canvas: some View {
        GeometryReader { geo in
            let fit = ImageEditUtil.aspectFitRect(image: renderedImage.size, container: geo.size)
            let cropRect = rectFromNorm(fit: fit)
            ZStack {
                // 图片本体（旋转后实时预览）
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // 水平参考线：辅助对齐水平边缘
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: fit.width + 24, height: 1)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // 裁剪框外暗化遮罩
                cropMask(fit: fit, rect: cropRect)

                // 裁剪框边框 + 三分线
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)
                thirdLines(rect: cropRect)

                // 八个边界/角把手（可独立拖拽）
                cropHandles(fit: fit, rect: cropRect)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear {
                containerSize = geo.size
            }
            .onChange(of: geo.size) { newSize in
                containerSize = newSize
            }
        }
    }

    /// 归一化裁剪框 → 显示坐标系
    private func rectFromNorm(fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + cropNorm.minX * fit.width,
               y: fit.minY + cropNorm.minY * fit.height,
               width: cropNorm.width * fit.width,
               height: cropNorm.height * fit.height)
    }

    /// 裁剪框外部暗化遮罩（四块矩形）
    @ViewBuilder
    private func cropMask(fit: CGRect, rect: CGRect) -> some View {
        let top = CGRect(x: fit.minX, y: fit.minY, width: fit.width, height: max(0, rect.minY - fit.minY))
        let bottom = CGRect(x: fit.minX, y: rect.maxY, width: fit.width, height: max(0, fit.maxY - rect.maxY))
        let left = CGRect(x: fit.minX, y: rect.minY, width: max(0, rect.minX - fit.minX), height: rect.height)
        let right = CGRect(x: rect.maxX, y: rect.minY, width: max(0, fit.maxX - rect.maxX), height: rect.height)

        Rectangle().fill(Color.black.opacity(0.55))
            .frame(width: top.width, height: top.height).position(x: top.midX, y: top.midY)
        Rectangle().fill(Color.black.opacity(0.55))
            .frame(width: bottom.width, height: bottom.height).position(x: bottom.midX, y: bottom.midY)
        Rectangle().fill(Color.black.opacity(0.55))
            .frame(width: left.width, height: left.height).position(x: left.midX, y: left.midY)
        Rectangle().fill(Color.black.opacity(0.55))
            .frame(width: right.width, height: right.height).position(x: right.midX, y: right.midY)
    }

    /// 三分参考线
    @ViewBuilder
    private func thirdLines(rect: CGRect) -> some View {
        Path { p in
            let x1 = rect.minX + rect.width / 3
            let x2 = rect.minX + rect.width * 2 / 3
            let y1 = rect.minY + rect.height / 3
            let y2 = rect.minY + rect.height * 2 / 3
            p.move(to: CGPoint(x: x1, y: rect.minY)); p.addLine(to: CGPoint(x: x1, y: rect.maxY))
            p.move(to: CGPoint(x: x2, y: rect.minY)); p.addLine(to: CGPoint(x: x2, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX, y: y1)); p.addLine(to: CGPoint(x: rect.maxX, y: y1))
            p.move(to: CGPoint(x: rect.minX, y: y2)); p.addLine(to: CGPoint(x: rect.maxX, y: y2))
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
    }

    // MARK: - 边界/角把手

    enum CropHandle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
            default: return false
            }
        }

        /// 把手中心（显示坐标系，基于裁剪框 rect）
        func center(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
            case .top: return CGPoint(x: rect.midX, y: rect.minY)
            case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
            case .left: return CGPoint(x: rect.minX, y: rect.midY)
            case .right: return CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
            case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    @ViewBuilder
    private func cropHandles(fit: CGRect, rect: CGRect) -> some View {
        ForEach(CropHandle.allCases, id: \.self) { handle in
            ZStack {
                if handle.isCorner {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: 16, height: 16)
                } else {
                    switch handle {
                    case .top, .bottom:
                        Rectangle().fill(Color.white)
                            .frame(width: 18, height: 3)
                    default:
                        Rectangle().fill(Color.white)
                            .frame(width: 3, height: 18)
                    }
                }
            }
            .frame(width: 44, height: 44) // 透明命中区，便于点按
            .contentShape(Rectangle())
            .position(handle.center(in: rect))
            .gesture(handleDrag(handle))
        }
    }

    /// 边界/角拖拽手势：边只改单边，角同时改相邻两边；增量 = translation 归一化到图像区域
    private func handleDrag(_ handle: CropHandle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = handleStart ?? cropNorm
                handleStart = start
                guard containerSize.width > 0, containerSize.height > 0 else { return }
                let dx = value.translation.width / containerSize.width
                let dy = value.translation.height / containerSize.height
                var new = start
                switch handle {
                case .topLeft:
                    new.origin.x = start.minX + dx
                    new.origin.y = start.minY + dy
                    new.size.width = start.maxX - new.minX
                    new.size.height = start.maxY - new.minY
                case .top:
                    new.origin.y = start.minY + dy
                    new.size.height = start.maxY - new.minY
                case .topRight:
                    new.origin.y = start.minY + dy
                    new.size.width = start.maxX + dx - new.minX
                    new.size.height = start.maxY - new.minY
                case .left:
                    new.origin.x = start.minX + dx
                    new.size.width = start.maxX - new.minX
                case .right:
                    new.size.width = start.maxX + dx - new.minX
                case .bottomLeft:
                    new.origin.x = start.minX + dx
                    new.size.height = start.maxY + dy - new.minY
                case .bottom:
                    new.size.height = start.maxY + dy - new.minY
                case .bottomRight:
                    new.size.width = start.maxX + dx - new.minX
                    new.size.height = start.maxY + dy - new.minY
                }
                cropNorm = ImageEditUtil.clampNorm(new)
            }
            .onEnded { _ in
                handleStart = nil
            }
    }

    // MARK: - 旋转控制

    private var rotateBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("微旋转")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(String(format: "%+.1f°", rotationAngle))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.white)
            }
            HStack(spacing: 12) {
                Button("-0.5°") { adjustRotation(-0.5) }
                    .buttonStyle(RoundToggleStyle())
                Slider(value: $rotationAngle, in: -10...10, step: 0.5)
                    .tint(.white)
                Button("+0.5°") { adjustRotation(0.5) }
                    .buttonStyle(RoundToggleStyle())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func adjustRotation(_ delta: Double) {
        rotationAngle = min(max(rotationAngle + delta, -10), 10)
    }

    // MARK: - 底部栏

    private var footer: some View {
        HStack {
            Button("重选") { onCancel() }
                .foregroundColor(.white)
            Spacer()
            Button {
                confirmCrop()
            } label: {
                Text("确认裁剪")
                    .fontWeight(.semibold)
                    .foregroundColor(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    // MARK: - 输出

    /// 确认：先按微调角度旋转整图（外接矩形画布 + 透明留白），再按裁剪框 rect 裁剪。
    private func confirmCrop() {
        guard containerSize != .zero else { return }
        let rotated = ImageEditUtil.rotated(displayImage, angleDegrees: rotationAngle)
        guard rotated.size.width > 0, rotated.size.height > 0 else { return }

        // cropNorm 相对旋转后图像（显示区域 fit 即 rotated 的 aspectFit），直接映射像素
        let pxRect = CGRect(x: cropNorm.minX * rotated.size.width,
                            y: cropNorm.minY * rotated.size.height,
                            width: cropNorm.width * rotated.size.width,
                            height: cropNorm.height * rotated.size.height)
        let cropped = ImageEditUtil.cropped(rotated, to: pxRect)
        onConfirm(cropped)
    }
}

/// 圆形小按钮样式（旋转微调按钮）
struct RoundToggleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote)
            .foregroundColor(configuration.isPressed ? .black : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
            )
    }
}

/// 图片编辑工具：旋转/裁剪/等比计算/归一化约束，绘制均在 autoreleasepool 内完成。
enum ImageEditUtil {
    /// 任意角度旋转（度）：画布扩展为外接矩形，旋转留白区域透明。
    /// 角度为 0 时直接返回原图（避免无谓重绘）。
    static func rotated(_ image: UIImage, angleDegrees: Double) -> UIImage {
        if angleDegrees == 0 { return image }
        return autoreleasepool {
            let w = image.size.width, h = image.size.height
            let rad = angleDegrees * .pi / 180
            let cosA = abs(cos(rad)), sinA = abs(sin(rad))
            let newW = ceil(w * cosA + h * sinA)
            let newH = ceil(w * sinA + h * cosA)
            let size = CGSize(width: newW, height: newH)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false // 保留透明留白
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            return renderer.image { ctx in
                let c = ctx.cgContext
                c.clear(CGRect(origin: .zero, size: size))
                c.translateBy(x: size.width / 2, y: size.height / 2)
                c.rotate(by: rad)
                c.translateBy(x: -w / 2, y: -h / 2)
                image.draw(at: .zero)
            }
        }
    }

    /// 按像素 rect 裁剪（保留 alpha）
    static func cropped(_ image: UIImage, to rect: CGRect) -> UIImage {
        autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
            return renderer.image { _ in
                image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
            }
        }
    }

    /// 图片 aspectFit 到容器后的实际显示区域（裁剪框坐标系基准）
    static func aspectFitRect(image: CGSize, container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: (container.width - w) / 2,
                      y: (container.height - h) / 2,
                      width: w,
                      height: h)
    }

    /// 归一化裁剪框约束：各分量限制在 0..1，最小尺寸为 15%，再保证位置不越界
    static func clampNorm(_ r: CGRect) -> CGRect {
        let minW: CGFloat = 0.15
        let minH: CGFloat = 0.15
        let w = min(max(r.width, minW), 1)
        let h = min(max(r.height, minH), 1)
        let x = min(max(r.minX, 0), 1 - w)
        let y = min(max(r.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
