//
//  HomeView.swift
//  RootWord · 词根单词
//
//  P03 今日任务（首页）+ P07 空状态。文档 5.3 / 5.7。
//
//  设计要点：
//    · 整屏只有一个主按钮「开始学习」，不滚动即可点击（文档 3.4）
//    · 首页不承载任何浏览型内容，不展示词单、不展示统计
//    · 三种形态：默认（有任务）/ 今日已完成 / 无词可学
//

import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var state: AppState
    var onOpenSettings: () -> Void

    @State private var showStudy = false
    @State private var showImport = false
    @State private var showRootTip = false

    private var hasWords: Bool { !state.words.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: Sp.x5) {
                header
                if !hasWords {
                    emptyLibrary
                } else if state.todayTotalCount == 0 {
                    allDone
                } else {
                    todayCard
                    statRow
                    startButton
                    footnote
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: onOpenSettings) {
                    Icon(name: "gearshape", size: 17, weight: .medium, color: .textSecondary)
                        .frame(width: Metric.hitMin, height: Metric.hitMin)
                }
                .accessibilityLabel("设置")
            }
        }
        .fullScreenCover(isPresented: $showStudy) {
            StudyFlowView().environmentObject(state)
        }
        .sheet(isPresented: $showImport) {
            ImportView().environmentObject(state)
        }
    }

    // MARK: 顶部问候

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .dsFont(size: 26, weight: .bold, maxScale: 1.1)
                    .foregroundColor(.textPrimary)
                Text(dateText)
                    .dsFont(size: 13)
                    .foregroundColor(.textSecondary)
            }
            Spacer(minLength: Sp.x2)
            if state.streakDays > 0 {
                HStack(spacing: Sp.x1) {
                    Icon(name: "flame.fill", size: 13, weight: .semibold, color: .warning500)
                    Text("连续 \(state.streakDays) 天")
                        .dsFont(size: 13, weight: .semibold, maxScale: 1.15)
                        .foregroundColor(.warning500)
                }
                .padding(.horizontal, Sp.x3)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Color.warning500.opacity(0.12))
                )
                .accessibilityLabel("已连续学习 \(state.streakDays) 天")
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 6 { return "夜深了" }
        if hour < 12 { return "早上好" }
        if hour < 18 { return "下午好" }
        return "晚上好"
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 EEEE"
        return formatter.string(from: Date())
    }

    // MARK: 今日卡片（P03 默认态）

    private var todayCard: some View {
        VStack(spacing: Sp.x4) {
            ProgressRing(progress: todayProgress,
                         size: Metric.ringSize,
                         lineWidth: 14,
                         centerTitle: "\(state.todayReviewedCount)",
                         centerSubtitle: "已完成",
                         footNote: "今日共 \(state.todayTotalCount) 个")

            if state.overdueCount > 0 {
                BannerView(kind: .warning,
                           text: "有 \(state.overdueCount) 个词已到期，先复习它们效果最好。")
                    .padding(.horizontal, Sp.x2)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: Sp.x5)
    }

    private var todayProgress: Double {
        let total = state.todayTotalCount + state.todayReviewedCount
        guard total > 0 else { return 0 }
        return Double(state.todayReviewedCount) / Double(total)
    }

    // MARK: 新词 / 复习 指标

    private var statRow: some View {
        HStack(spacing: Sp.x3) {
            StatCard(title: "新词",
                     value: "\(state.newTodayCount)",
                     subtitle: state.newTodayCount > 0 ? "今天要认识的新词" : "今日新词已学完",
                     color: .brand500)
            StatCard(title: "复习",
                     value: "\(state.dueTodayCount)",
                     subtitle: state.overdueCount > 0 ? "含 \(state.overdueCount) 个逾期" : "按遗忘曲线到期",
                     color: .info500)
        }
    }

    // MARK: 主按钮

    private var startButton: some View {
        Button(action: {
            state.startSession(source: .todayPlan)
            if state.session != nil {
                showStudy = true
            } else {
                state.showToast("今天没有需要学习的单词了", icon: "checkmark.circle.fill")
            }
        }) {
            HStack(spacing: Sp.x2) {
                Icon(name: "play.fill", size: 16, weight: .semibold, color: .white)
                Text(state.todayReviewedCount > 0 ? "继续学习" : "开始学习")
                    .dsFont(size: 17, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(PrimaryButtonStyle(height: 58))
        .accessibilityHint("进入学习会话，共 \(state.todayTotalCount) 个单词")
    }

    private var footnote: some View {
        VStack(spacing: Sp.x3) {
            HStack(spacing: Sp.x2) {
                Icon(name: "clock", size: 13, weight: .medium, color: .textTertiary)
                Text("预计用时约 \(estimatedMinutes) 分钟")
                    .dsFont(size: 13)
                    .foregroundColor(.textTertiary)
                Spacer(minLength: 0)
            }

            if let accuracy = state.todayAccuracy {
                HStack(spacing: Sp.x2) {
                    Icon(name: "checkmark.seal", size: 13, weight: .medium, color: .textTertiary)
                    Text("今日正确率 \(Int((accuracy * 100).rounded()))%")
                        .dsFont(size: 13)
                        .foregroundColor(.textTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Sp.x1)
    }

    private var estimatedMinutes: Int {
        // 约 20 秒 / 个（新词更慢，复习更快），向上取整至少 1 分钟
        let seconds = state.newTodayCount * 26 + state.dueTodayCount * 16
        return max(1, Int(ceil(Double(seconds) / 60.0)))
    }

    // MARK: 今日已完成（P03 已完成形态）

    private var allDone: some View {
        VStack(spacing: Sp.x5) {
            ProgressRing(progress: 1,
                         size: Metric.ringSize,
                         lineWidth: 14,
                         showsCheckmark: true,
                         footNote: tomorrowText)

            VStack(spacing: Sp.x2) {
                Text("今天的任务完成了")
                    .dsFont(size: 18, weight: .semibold, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text("去玩吧。明天再来，间隔重复会在你最需要的时候把单词送回来。")
                    .dsFont(size: 14)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Sp.x4)

            Button("随便复习一组") {
                if let deck = state.currentDeck {
                    state.startSession(source: .deck(deck.id))
                    if state.session != nil { showStudy = true }
                }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .card(padding: Sp.x5)
    }

    private var tomorrowText: String {
        let items = state.forecast()
        if items.count > 1 {
            return "明天预计复习 \(items[1].count) 个"
        }
        return "明天见"
    }

    // MARK: 无词可学（P07）

    private var emptyLibrary: some View {
        VStack(spacing: Sp.x4) {
            EmptyStateView(symbol: "square.stack",
                           title: "还没有单词",
                           message: "导入自己的词表，或用示例词表先体验一遍完整流程。",
                           primaryTitle: "导入单词",
                           primaryAction: { showImport = true },
                           secondaryTitle: "使用示例词表（20 个）",
                           secondaryAction: {
                               state.addSampleDeck()
                               state.showToast("已加入 20 个示例单词")
                           })
        }
        .card(padding: Sp.x5)
    }
}
