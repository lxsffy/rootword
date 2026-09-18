//
//  Settings.swift
//  RootWord · 词根单词
//
//  极简的学习参数：只有 2 个数值 + 2 个开关 + 1 个引导标记（文档 2.5 节「参数极简化设计」）
//

import Foundation

struct AppSettings: Codable, Equatable {

    // MARK: 学习参数

    /// 每日新词上限（默认 10，范围 5–30）
    var dailyNewLimit: Int = 10
    /// 每日复习上限（默认 30，范围 10–100）
    var dailyReviewLimit: Int = 30

    // MARK: 开关

    /// 进入卡片时自动朗读单词
    var autoPlayAudio: Bool = false
    /// 震动反馈（关闭后全部触觉反馈静默）
    var hapticEnabled: Bool = true

    // MARK: 状态标记

    /// 是否已完成首次引导（P02）
    var hasCompletedOnboarding: Bool = false
    /// 是否已导入过示例词表
    var hasImportedSeed: Bool = false
    /// 发音口音：en-US / en-GB
    var accent: String = "en-US"

    // MARK: 取值范围（设置页 Stepper 使用）

    static let newLimitRange: ClosedRange<Int> = 5...30
    static let reviewLimitRange: ClosedRange<Int> = 10...100
    static let newLimitStep = 5
    static let reviewLimitStep = 10

    mutating func normalize() {
        dailyNewLimit = min(max(dailyNewLimit, AppSettings.newLimitRange.lowerBound),
                            AppSettings.newLimitRange.upperBound)
        dailyReviewLimit = min(max(dailyReviewLimit, AppSettings.reviewLimitRange.lowerBound),
                               AppSettings.reviewLimitRange.upperBound)
        if accent != "en-US" && accent != "en-GB" { accent = "en-US" }
    }

    /// 每日新词上限变更后的展示文案
    var dailyNewText: String { "\(dailyNewLimit) 个" }
    var dailyReviewText: String { "\(dailyReviewLimit) 个" }
}
