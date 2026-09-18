//
//  Store.swift
//  RootWord · 词根单词
//
//  本地持久化层（文档 9.8）：全量 JSON 落盘 + 原子替换，异步串行队列，不阻塞 UI。
//
//  沙盒目录结构：
//    Documents/                              对用户可见（UIFileSharingEnabled=YES）
//      rootword-backup-YYYYMMDD.json         设置页导出的备份
//      words.bak.json                        数据损坏时的自动备份
//    Library/Application Support/RootWord/   隐藏，App 私有
//      words.json / decks.json / logs.json / settings.json
//
//  设计原则：任何一次写入失败都不能让 App 崩溃；失败只记录 writeError，由 UI 用 Toast 提示。
//

import Foundation

final class Store {

    static let shared = Store()

    // MARK: - 路径

    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.rootword.vocab.store.io", qos: .utility)

    private(set) var rootDir: URL
    private(set) var documentsDir: URL

    private var wordsURL: URL { rootDir.appendingPathComponent("words.json") }
    private var decksURL: URL { rootDir.appendingPathComponent("decks.json") }
    private var logsURL: URL { rootDir.appendingPathComponent("logs.json") }
    private var settingsURL: URL { rootDir.appendingPathComponent("settings.json") }

    // MARK: - 状态

    private(set) var words: [Word] = []
    private(set) var decks: [Deck] = []
    private(set) var logs: [ReviewLog] = []
    private(set) var settings = AppSettings()

    /// 数据文件损坏（P01「数据损坏」状态）
    private(set) var wordsCorrupted = false
    /// 最近一次写入失败原因（如磁盘空间不足）
    private(set) var lastWriteError: String?

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        rootDir = base.appendingPathComponent("RootWord", isDirectory: true)
        documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? base

        try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    // MARK: - 读取

    func load() {
        words = decode([Word].self, from: wordsURL, backupOnFailure: true) ?? []
        decks = decode([Deck].self, from: decksURL) ?? []
        logs = decode([ReviewLog].self, from: logsURL) ?? []
        settings = decode(AppSettings.self, from: settingsURL) ?? AppSettings()
        settings.normalize()
        ensureCurrentDeck()
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL, backupOnFailure: Bool = false) -> T? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            if backupOnFailure {
                wordsCorrupted = true
                let backup = documentsDir.appendingPathComponent("words.bak.json")
                try? fm.removeItem(at: backup)
                try? fm.copyItem(at: url, to: backup)
            }
            return nil
        }
    }

    /// 只有一个词单可以被标记为「当前词单」
    private func ensureCurrentDeck() {
        guard !decks.isEmpty else { return }
        if !decks.contains(where: { $0.isCurrent }) {
            decks[0].isCurrent = true
        }
    }

    // MARK: - 写入（全量 + 原子替换）

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
            try? fm.removeItem(at: tmp)
        }
    }

    /// 全量落盘（评分后调用，异步串行，不阻塞 UI）
    func persist(words: [Word], decks: [Deck], logs: [ReviewLog], settings: AppSettings) {
        self.words = words
        self.decks = decks
        self.logs = logs
        self.settings = settings

        let w = words, d = decks, l = logs, s = settings
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.write(w, to: self.wordsURL)
            self.write(d, to: self.decksURL)
            self.write(l, to: self.logsURL)
            self.write(s, to: self.settingsURL)
        }
    }

    /// 同步落盘（退出/危险操作前调用，保证数据不丢）
    func persistSync(words: [Word], decks: [Deck], logs: [ReviewLog], settings: AppSettings) {
        self.words = words
        self.decks = decks
        self.logs = logs
        self.settings = settings
        ioQueue.sync {
            write(words, to: wordsURL)
            write(decks, to: decksURL)
            write(logs, to: logsURL)
            write(settings, to: settingsURL)
        }
    }

    // MARK: - 备份 / 恢复 / 清空

    /// 设置页「导出全部数据」：写入 Documents 并返回文件 URL
    func exportBackup(words: [Word], decks: [Deck], logs: [ReviewLog], settings: AppSettings) -> URL? {
        let payload = BackupFile(exportedAt: Date(), words: words, decks: decks, logs: logs, settings: settings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        let url = documentsDir.appendingPathComponent("rootword-backup-\(f.string(from: Date())).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            lastWriteError = error.localizedDescription
            return nil
        }
    }

    /// 从备份文件恢复
    func importBackup(from url: URL) throws -> BackupFile {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupFile.self, from: data)
    }

    /// 「清空全部数据」前的自动备份（文档 5.13：执行前必须落一份备份）
    @discardableResult
    func autoBackupBeforeWipe(words: [Word], decks: [Deck], logs: [ReviewLog], settings: AppSettings) -> URL? {
        exportBackup(words: words, decks: decks, logs: logs, settings: settings)
    }

    /// 数据损坏后的重置（P01 的「重置并继续」）
    func resetCorruptedWordsFile() {
        try? fm.removeItem(at: wordsURL)
        wordsCorrupted = false
    }

    func wipeAllFiles() {
        for url in [wordsURL, decksURL, logsURL, settingsURL] {
            try? fm.removeItem(at: url)
        }
    }

    func clearLogsFile() {
        try? fm.removeItem(at: logsURL)
    }

    // MARK: - 备份文件结构

    struct BackupFile: Codable {
        var exportedAt: Date
        var words: [Word]
        var decks: [Deck]
        var logs: [ReviewLog]
        var settings: AppSettings
        /// 兼容性标记，便于未来升级
        var schemaVersion: Int = 1
    }
}
