//
//  RootEntry.swift
//  RootWord · 词根单词
//
//  词根库模型（文档 7.6.1）。词根库以 RootLibrary.json 打进 App 包，只读，用户不可编辑。
//

import Foundation

struct RootEntry: Codable, Equatable, Identifiable {

    /// 唯一 id，如 "un" / "spect" / "tion"
    let id: String
    /// 展示形式，如 "un-" / "-tion"
    let form: String
    /// 用于匹配的裸形式，如 "un" / "tion"
    let normalized: String
    /// 前缀 / 词根 / 后缀
    let type: RootType
    /// 中文含义，如「不、否定」
    let meaning: String
    /// 语源，如「古英语 un-」
    let origin: String
    /// 记忆提示
    let note: String
    /// 例词（单词文本）
    let examples: [String]

    /// 匹配时的可用长度（前缀/后缀扫描按长度最长优先）
    var matchLength: Int { normalized.count }

    /// P15 词根详情首屏展示的补充说明（缺省时不显示空行）
    var hasOriginOrNote: Bool { !origin.isEmpty || !note.isEmpty }
}

// MARK: - 词根库容器

/// 词根库加载器（只读）。解析失败时降级为空库，App 仍可正常使用（只是不做构词拆解）。
final class RootLibrary {

    static let shared = RootLibrary()

    private(set) var entries: [RootEntry] = []
    private(set) var loadFailed = false

    private var byID: [String: RootEntry] = [:]

    private init() {
        load()
        buildIndex()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "RootLibrary", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            loadFailed = true
            return
        }
        do {
            entries = try JSONDecoder().decode([RootEntry].self, from: data)
        } catch {
            loadFailed = true
            entries = []
        }
    }

    private func buildIndex() {
        // 用 uniquingKeysWith 兜底：即使词根库误配了重复 id，也只取首条而不崩溃
        byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func entry(id: String) -> RootEntry? { byID[id] }

    func entries(of type: RootType) -> [RootEntry] {
        entries.filter { $0.type == type }
    }

    /// 库容量文案（P14 页脚）
    var capacityText: String {
        let p = entries.filter { $0.type == .prefix }.count
        let r = entries.filter { $0.type == .root }.count
        let s = entries.filter { $0.type == .suffix }.count
        return "前缀 \(p) · 词根 \(r) · 后缀 \(s)"
    }
}
