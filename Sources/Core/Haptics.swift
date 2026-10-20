//
//  Haptics.swift
//  RootWord · 词根单词
//
//  触觉反馈封装（文档 6.7 动效与触觉）：
//    主按钮点击 → impactLight；评分 → impactMedium（忘记 notificationError / 记得 notificationSuccess）；
//    开关切换 → selectionChanged。
//  设置页「震动反馈」关闭后，本文件的所有调用直接短路，不再触发引擎。
//

import UIKit

enum Haptics {

    /// 由 AppState 在设置变更时同步
    static var enabled: Bool = true

    static func light() {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    static func medium() {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    static func selection() {
        guard enabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// 评分专用的统一入口：与文档 5.5 的映射一致
    static func feedback(for grade: Grade) {
        switch grade {
        case .forgot:
            error()
        case .fuzzy:
            medium()
        case .remembered:
            success()
        }
    }
}
