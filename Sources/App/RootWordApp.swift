//
//  RootWordApp.swift
//  RootWord · 词根单词
//
//  应用入口与全局容器（对应产品设计文档 P01 启动页 / 全局浮层 C01–C04）。
//
//  结构：
//    RootWordApp（@main）
//      └── AppShell        启动 → 引导 → 主 Tab 三态切换
//            ├── LaunchView       P01
//            ├── OnboardingView   P02
//            └── MainTabView      4 个 Tab（今日 / 词单 / 词根 / 我的）
//            └── 全局浮层：Toast、确认弹窗
//
//  iOS 15.4 兼容：不使用任何 iOS 16+ API（无 NavigationStack、无 ShareLink、
//  无 .scrollContentBackground、无双参数 onChange）。
//

import SwiftUI

@main
struct RootWordApp: App {

    init() {
        // 设计系统：让系统控件（大标题、TabBar）跟随品牌色
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.shadowColor = .clear
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().standardAppearance = appearance

        #if DEBUG
        // 文档 7.7：算法与解析器的自检用例（仅在 DEBUG 构建执行）
        SRSchedulerSelfCheck.run()
        RootParserSelfCheck.run()
        ImportSelfCheck.run()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
        }
    }
}

// MARK: - 全局确认弹窗中心

/// 任意页面通过 `ConfirmCenter.shared.ask(...)` 弹出二次确认（C02）
final class ConfirmCenter: ObservableObject {

    static let shared = ConfirmCenter()

    @Published var request: ConfirmRequest?

    private init() {}

    func ask(_ request: ConfirmRequest) {
        withAnimation(.easeOut(duration: 0.2)) { self.request = request }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) { self.request = nil }
    }
}

// MARK: - 启动阶段

enum LaunchPhase {
    case launching
    case onboarding
    case main
}

// MARK: - AppShell

struct AppShell: View {

    @StateObject private var state = AppState.shared
    @ObservedObject private var confirms = ConfirmCenter.shared

    @State private var phase: LaunchPhase = .launching
    @State private var launchProgress: Double = 0

    var body: some View {
        ZStack {
            PageBackground()

            switch phase {
            case .launching:
                LaunchView(progress: launchProgress)
                    .transition(.opacity)
            case .onboarding:
                OnboardingView(onFinish: { finished in
                    state.updateSettings { $0.hasCompletedOnboarding = true }
                    _ = finished
                    withAnimation(.easeOut(duration: 0.25)) { phase = .main }
                })
                .transition(.opacity)
            case .main:
                MainTabView()
                    .environmentObject(state)
                    .transition(.opacity)
            }

            // C01 Toast
            if let toast = state.toast {
                ToastOverlay(text: toast.text)
                    .zIndex(10)
            }

            // C02 确认弹窗
            if let request = confirms.request {
                ConfirmDialogView(request: request, onDismiss: { confirms.dismiss() })
                    .zIndex(20)
            }

            // 数据损坏提示条（P01 异常态）
            if state.showCorruptionBanner && phase == .main {
                VStack {
                    BannerView(kind: .warning, text: "上次的数据文件读取失败，已自动备份并重建，学习记录可能不完整。")
                        .padding(.horizontal, Sp.x4)
                        .padding(.top, Sp.x2)
                    Spacer()
                }
                .zIndex(15)
                .onTapGesture { state.showCorruptionBanner = false }
            }
        }
        .onAppear(perform: bootstrap)
        .onChange(of: state.toast) { toast in
            guard let toast = toast else { return }
            // 2 秒后自动消失（同屏最多 1 个，新 Toast 直接替换）
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if state.toast?.id == toast.id {
                    withAnimation(.easeOut(duration: 0.25)) { state.toast = nil }
                }
            }
        }
    }

    private func bootstrap() {
        state.bootstrap()
        Haptics.enabled = state.settings.hapticEnabled

        // P01 品牌露出：0.6 秒加载动画后进入引导或主界面
        var done = false
        func finish() {
            guard !done else { return }
            done = true
            withAnimation(.easeOut(duration: 0.3)) {
                phase = state.settings.hasCompletedOnboarding ? .main : .onboarding
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish() }
        // 兜底：极端情况（主线程繁忙）下 1.5 秒强制放行，避免"永远停在启动页"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish() }
    }
}

// MARK: - P01 启动页

struct LaunchView: View {

    var progress: Double

    var body: some View {
        VStack(spacing: Sp.x5) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: Radius.bigCard + 6, style: .continuous)
                    .fill(Color.brandGradient)
                    .frame(width: 104, height: 104)

                Text("R")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .shadow(color: Color.brand500.opacity(0.28), radius: 20, x: 0, y: 12)

            VStack(spacing: Sp.x2) {
                Text("词根单词")
                    .dsFont(size: 26, weight: .bold, maxScale: 1.1)
                    .foregroundColor(.textPrimary)
                Text("拆开记 · 复习更久")
                    .dsFont(size: 14)
                    .foregroundColor(.textSecondary)
            }

            Spacer()

            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: Color.brand500))
                .padding(.bottom, Sp.x8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("词根单词，正在启动")
    }
}

// MARK: - P02 首次引导（3 屏，可跳过）

struct OnboardingView: View {

    var onFinish: (Bool) -> Void

    @State private var page = 0

    private struct Page: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let message: String
        let hint: String
    }

    private let pages: [Page] = [
        Page(symbol: "calendar.badge.clock",
             title: "每天只学一小把",
             message: "默认每天 10 个新词 + 30 个复习，十分钟就能完成。学完就结束，不逼你多背。",
             hint: "数量随时可在「我的 → 设置」里调整"),
        Page(symbol: "square.stack.3d.up",
             title: "拆开看，更好记",
             message: "unhappy = un（不）+ happy（快乐）。卡片背面会自动把单词拆成前缀、词根、后缀。",
             hint: "长按词根可以看它带出的所有单词"),
        Page(symbol: "clock.arrow.circlepath",
             title: "该复习时才复习",
             message: "系统按间隔重复算法安排复习：记得越牢，出现得越晚；忘记了，当天会再出现一次。",
             hint: "你只需要诚实地点三个按钮")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("跳过") { onFinish(false) }
                    .dsFont(size: 15)
                    .foregroundColor(.textSecondary)
                    .frame(minWidth: Metric.hitMin, minHeight: Metric.hitMin)
            }
            .padding(.horizontal, Sp.x3)
            .padding(.top, Sp.x2)

            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: Sp.x6) {
                        Spacer(minLength: 0)

                        ZStack {
                            Circle()
                                .fill(Color.brand500.opacity(0.10))
                                .frame(width: 148, height: 148)
                            Circle()
                                .fill(Color.brand500.opacity(0.07))
                                .frame(width: 108, height: 108)
                            Icon(name: item.symbol, size: 52, weight: .regular, color: .brand500)
                        }

                        VStack(spacing: Sp.x3) {
                            Text(item.title)
                                .dsFont(size: 22, weight: .bold, maxScale: 1.15)
                                .foregroundColor(.textPrimary)
                            Text(item.message)
                                .dsFont(size: 15)
                                .foregroundColor(.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Sp.x8)
                            Text(item.hint)
                                .dsFont(size: 13)
                                .foregroundColor(.textTertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, Sp.x8)
                        }

                        Spacer(minLength: 0)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

            HStack(spacing: Sp.x2) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.brand500 : Color.disabledFill)
                        .frame(width: index == page ? 20 : 8, height: 8)
                        .animation(.easeOut(duration: 0.2), value: page)
                }
            }
            .padding(.bottom, Sp.x5)

            Button(page == pages.count - 1 ? "开始使用" : "下一步") {
                if page == pages.count - 1 {
                    onFinish(true)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { page += 1 }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, Metric.pagePadding)
            .padding(.bottom, Sp.x6)
        }
        .background(PageBackground())
    }
}

// MARK: - 主 Tab（文档 3.1：4 个一级区域）

struct MainTabView: View {

    @EnvironmentObject private var state: AppState
    @State private var selection: Int = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationView {
                HomeView(onOpenSettings: { selection = 3 })
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label("今日", systemImage: DSIcon.safe("calendar"))
            }
            .tag(0)

            NavigationView {
                DeckListView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label("词单", systemImage: DSIcon.safe("square.stack"))
            }
            .tag(1)

            NavigationView {
                RootLibraryView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label("词根", systemImage: DSIcon.safe("textformat.abc"))
            }
            .tag(2)

            NavigationView {
                ProfileHomeView()
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .tabItem {
                Label("我的", systemImage: DSIcon.safe("person"))
            }
            .tag(3)
        }
        .accentColor(.brand500)
    }
}

// MARK: - 学习会话的全屏容器（P04 / P05 / P06）

struct StudyFlowView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        Group {
            if let summary = state.lastSummary {
                SessionSummaryView(summary: summary,
                                   onDone: { close() },
                                   onAgain: { again() })
            } else {
                StudyView(onExit: { close() })
            }
        }
        .background(PageBackground())
    }

    private func close() {
        state.lastSummary = nil
        presentationMode.wrappedValue.dismiss()
    }

    private func again() {
        state.lastSummary = nil
        state.startSession(source: .todayPlan)
    }
}
