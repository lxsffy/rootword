//
//  ProfileView.swift
//  RootWord · 词根单词
//
//  P16 学习档案。文档 5.20。
//
//  只展示「真实记录」算出来的数据，不做任何游戏化分数或排行榜。
//

import SwiftUI

struct ProfileHomeView: View {

    @EnvironmentObject private var state: AppState

    @State private var selectedHeatCount: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.x4) {
                PageTitle(text: "学习档案")

                overviewGrid
                heatmapCard
                masteryCard
                forecastCard
                accuracyCard
                entryCard

                Text("所有统计来自本机学习记录，卸载 App 即清除。")
                    .dsFont(size: 12)
                    .foregroundColor(.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 概览

    private var overviewGrid: some View {
        VStack(spacing: Sp.x3) {
            HStack(spacing: Sp.x3) {
                StatCard(title: "词库总量", value: "\(state.words.count)", color: .brand500)
                StatCard(title: "已掌握", value: "\(state.masteredCount)", color: .success500)
            }
            HStack(spacing: Sp.x3) {
                StatCard(title: "连续打卡", value: "\(state.streakDays)", subtitle: state.streakDays > 0 ? "天" : "从今天开始", color: .warning500)
                StatCard(title: "累计复习", value: "\(state.totalReviews)", color: .info500)
            }
            HStack(spacing: Sp.x3) {
                StatCard(title: "学习天数", value: "\(state.totalStudyDays)", color: .brand500)
                StatCard(title: "平均熟练度", value: String(format: "%.2f", state.averageEF), subtitle: "满分 2.80", color: .textPrimary)
            }
        }
    }

    // MARK: 热力图

    private var heatmapCard: some View {
        SectionCard(title: "最近 12 周",
                    subtitle: selectedHeatCount.map { "所选日期复习 \($0) 次" } ?? "每天复习的单词数量") {
            VStack(alignment: .leading, spacing: Sp.x3) {
                HeatmapGrid(days: state.heatmapData()) { count in
                    selectedHeatCount = count
                }
                HStack(spacing: Sp.x2) {
                    Text("少").dsFont(size: 11).foregroundColor(.textTertiary)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(level == 0 ? Color.disabledFill : Color.brand500.opacity(0.28 + Double(level) * 0.18))
                            .frame(width: 10, height: 10)
                    }
                    Text("多").dsFont(size: 11).foregroundColor(.textTertiary)
                    Spacer(minLength: 0)
                    Text("共 \(state.totalReviews) 次")
                        .dsFont(size: 11)
                        .foregroundColor(.textTertiary)
                }
            }
        }
    }

    // MARK: 掌握度分布

    private var masteryCard: some View {
        SectionCard(title: "掌握度分布", subtitle: "按复习阶段划分") {
            VStack(alignment: .leading, spacing: Sp.x3) {
                MasteryBar(newCount: state.newCount,
                           learningCount: state.learningCount + state.reviewCount,
                           masteredCount: state.masteredCount)

                Button("查看未掌握的单词") {
                    let ids = state.words.filter { $0.srs.phase != .mastered }.map { $0.id }
                    state.startSession(source: .rootWords(ids))
                    if state.session == nil {
                        state.showToast("暂时没有可练的单词", icon: "info.circle.fill")
                    }
                }
                .buttonStyle(SecondaryButtonStyle(height: 44))
            }
        }
    }

    // MARK: 未来 7 天

    private var forecastCard: some View {
        SectionCard(title: "未来 7 天复习量", subtitle: "艾宾浩斯曲线的预测") {
            ForecastChart(items: state.forecast()) { count in
                state.showToast(count > 0 ? "这天预计复习 \(count) 个单词" : "这天没有安排复习",
                                icon: "calendar")
            }
        }
    }

    // MARK: 准确率趋势

    private var accuracyCard: some View {
        let trend = state.accuracyTrend()
        let values = trend.compactMap { $0.value }
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)

        return SectionCard(title: "近 14 天正确率", subtitle: values.isEmpty ? "还没有足够数据" : String(format: "平均 %.0f%%", average * 100)) {
            VStack(alignment: .leading, spacing: Sp.x3) {
                if values.isEmpty {
                    Text("完成几次复习后，这里会显示你的正确率变化。")
                        .dsFont(size: 13)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    GeometryReader { geo in
                        let step = geo.size.width / CGFloat(max(1, trend.count - 1))
                        ZStack(alignment: .bottomLeading) {
                            Path { path in
                                var started = false
                                for (index, item) in trend.enumerated() {
                                    guard let value = item.value else { continue }
                                    let point = CGPoint(x: CGFloat(index) * step,
                                                        y: geo.size.height * (1 - CGFloat(value)))
                                    if started {
                                        path.addLine(to: point)
                                    } else {
                                        path.move(to: point)
                                        started = true
                                    }
                                }
                            }
                            .stroke(Color.brand500, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                            ForEach(Array(trend.enumerated()), id: \.offset) { index, item in
                                if let value = item.value {
                                    Circle()
                                        .fill(Color.brand500)
                                        .frame(width: 5, height: 5)
                                        .position(x: CGFloat(index) * step,
                                                  y: geo.size.height * (1 - CGFloat(value)))
                                }
                            }
                        }
                    }
                    .frame(height: 90)

                    HStack {
                        Text("越靠右越近").dsFont(size: 11).foregroundColor(.textTertiary)
                        Spacer(minLength: 0)
                        Text("纵轴 0–100%").dsFont(size: 11).foregroundColor(.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: 入口

    private var entryCard: some View {
        VStack(spacing: 0) {
            NavigationLink(destination: SettingsView()) {
                entryRow(symbol: "gearshape", title: "设置", detail: "学习参数 · 数据管理")
            }
            .buttonStyle(PlainButtonStyle())
            Divider().padding(.leading, 56)
            NavigationLink(destination: RootLibraryView()) {
                entryRow(symbol: "text.book.closed", title: "词根库", detail: "浏览本机命中的词根")
            }
            .buttonStyle(PlainButtonStyle())
            Divider().padding(.leading, 56)
            NavigationLink(destination: AboutView()) {
                entryRow(symbol: "info.circle", title: "关于与算法说明", detail: "间隔重复如何工作")
            }
            .buttonStyle(PlainButtonStyle())
        }
        .card(padding: 0)
    }

    private func entryRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: Sp.x3) {
            Icon(name: symbol, size: 16, weight: .medium, color: .brand500)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .dsFont(size: 16, weight: .medium, maxScale: 1.15)
                    .foregroundColor(.textPrimary)
                Text(detail)
                    .dsFont(size: 12)
                    .foregroundColor(.textSecondary)
            }
            Spacer(minLength: 0)
            Icon(name: "chevron.right", size: 12, weight: .semibold, color: .textTertiary)
        }
        .padding(.horizontal, Metric.rowHPadding)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

// MARK: - 关于与算法说明

struct AboutView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Sp.x4) {
                SectionCard(title: "这个 App 怎么帮你记住单词") {
                    VStack(alignment: .leading, spacing: Sp.x3) {
                        line("1", "每个新词学一遍，然后按你的掌握程度安排下一次出现的时间。")
                        line("2", "记得越牢，下次间隔越长；忘了就回到短间隔重来。")
                        line("3", "同时用「词根拆解」把同一个词根的单词串起来记，一次记一串。")
                    }
                }

                SectionCard(title: "间隔规则", subtitle: "SM-2 简化版") {
                    VStack(alignment: .leading, spacing: Sp.x2) {
                        rule("记住了", "间隔 × 熟练度系数，最长 180 天")
                        rule("有点模糊", "间隔小幅增长，熟练度略降")
                        rule("忘记了", "10 分钟后重来一次（每次最多重插 2 次）")
                        rule("判定掌握", "连续答对且间隔达到 21 天")
                    }
                }

                SectionCard(title: "隐私", subtitle: "本地优先") {
                    Text("单词、进度、复习记录全部保存在这台设备上，不联网、不上传、无账号。")
                        .dsFont(size: 13)
                        .foregroundColor(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SectionCard(title: "版本") {
                    VStack(alignment: .leading, spacing: Sp.x2) {
                        rule("名称", "RootWord · 词根单词")
                        rule("版本", AppInfo.versionDisplay)
                        rule("系统要求", "iOS 15.4 及以上")
                    }
                }
            }
            .padding(.horizontal, Metric.pagePadding)
            .padding(.top, Sp.x3)
            .padding(.bottom, Sp.x8)
        }
        .background(PageBackground())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func line(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Sp.x3) {
            Text(index)
                .dsFont(size: 13, weight: .bold, maxScale: 1.15)
                .foregroundColor(.brand500)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.brand500.opacity(0.14)))
            Text(text)
                .dsFont(size: 13)
                .foregroundColor(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rule(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .dsFont(size: 13, weight: .medium, maxScale: 1.15)
                .foregroundColor(.textPrimary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .dsFont(size: 13)
                .foregroundColor(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
