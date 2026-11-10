//
//  TestSupport.swift
//  独立回归测试的运行器与断言框架（不依赖 XCTest，可由 swiftc 直接在 macOS 编译运行）
//
//  · App 目标仍用 build-and-package.sh / Xcode 构建，Tests/ 不参与 App 编译。
//  · 本文件同时提供 DesignSystem 颜色的测试替身：
//    Word.swift 的 RootType.dotColor 引用了 brand500 等语义色，
//    而 Views/DesignSystem.swift 依赖大量 iOS SwiftUI 代码，无法在 macOS 命令行下编译。
//

import Foundation
import SwiftUI
import Darwin

// MARK: - 颜色测试替身（仅测试构建可见）

extension Color {
    static let brand500 = Color.blue
    static let warning500 = Color.orange
    static let info500 = Color.purple
    static let textTertiary = Color.gray
}

// MARK: - 断言

final class TestContext {

    let suite: String
    private(set) var passed = 0
    private(set) var failures: [String] = []

    init(suite: String) { self.suite = suite }

    func expect(_ condition: Bool,
                _ message: String,
                file: String = #filePath,
                line: Int = #line) {
        if condition {
            passed += 1
        } else {
            let name = URL(fileURLWithPath: file).lastPathComponent
            failures.append("[\(suite)] \(message) — \(name):\(line)")
        }
    }

    func equal<T: Equatable>(_ lhs: T,
                             _ rhs: T,
                             _ message: String,
                             file: String = #filePath,
                             line: Int = #line) {
        if lhs == rhs {
            passed += 1
        } else {
            let name = URL(fileURLWithPath: file).lastPathComponent
            failures.append("[\(suite)] \(message) — 期望 \(rhs)，实际 \(lhs) — \(name):\(line)")
        }
    }

    /// XCTest.measure 的轻量等价物：打印耗时，便于每次发布比较性能是否退步。
    func measure(_ label: String, iterations: Int = 1, _ block: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<max(1, iterations) { block() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let ms = Double(elapsed) / 1_000_000
        print(String(format: "    ⏱  %-32@ %9.2f ms / %d 次",
                     label as NSString, ms, max(1, iterations)))
    }
}

// MARK: - 项目路径 / 测试日历

enum TestEnvironment {
    static var projectRoot: URL {
        if let raw = ProcessInfo.processInfo.environment["ROOTWORD_PROJECT_ROOT"] {
            return URL(fileURLWithPath: raw)
        }
        // 兜底：从本文件位置 Tests/Support/ 上溯两级
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var rootsDatabase: String {
        projectRoot.appendingPathComponent("Resources/roots.sqlite").path
    }

    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}

// MARK: - 运行器

@main
struct TestRunner {

    static func main() {
        // 所有 suite 共用真实词根库；单个 suite 内可临时切换并负责恢复。
        SQLiteRootIndex.configure(path: TestEnvironment.rootsDatabase)

        let suites: [(String, (TestContext) -> Void)] = [
            ("SRScheduler", runSRSchedulerTests),
            ("RootParser", runRootParserTests),
            ("SQLiteRootIndex", runSQLiteRootIndexTests),
            ("Store", runStoreTests),
            ("Importer", runImporterTests),
        ]

        print("==> RootWord 独立回归测试（swiftc / macOS）")
        var totalPassed = 0
        var allFailures: [String] = []

        for (name, run) in suites {
            let context = TestContext(suite: name)
            run(context)
            totalPassed += context.passed
            allFailures.append(contentsOf: context.failures)
            if context.failures.isEmpty {
                print("  ✓ \(name)：\(context.passed) 项通过")
            } else {
                print("  ✗ \(name)：\(context.passed) 通过 / \(context.failures.count) 失败")
                for failure in context.failures { print("      · \(failure)") }
            }
        }

        let stats = SQLiteRootIndex.stats()
        print("==> 词根索引统计：命中 \(stats.hits) / 未命中 \(stats.misses) / 在线回退 \(stats.onlineFallbacks) / 打开失败 \(stats.openFailures) / 查询错误 \(stats.queryErrors)")
        print("==> 合计 \(totalPassed) 项通过，\(allFailures.count) 项失败")
        exit(allFailures.isEmpty ? 0 : 1)
    }
}
