//
//  Store.swift
//  RootWord · 词根单词
//
//  本地持久化层（文档 9.8）：全量 JSON 落盘 + 原子替换，异步串行队列，不阻塞 UI。
//
//  沙盒目录结构：
//    Documents/                              对用户可见（UIFileSharingEnabled=YES）
//      rootword-backup-YYYYMMDD-HHMMSS.json  设置页导出的备份（带时间戳，不覆盖历史备份）
//      words.bak.json                        数据损坏时的自动备份
//    Library/Application Support/RootWord/   隐藏，App 私有
//      words.json / decks.json / logs.json / settings.json
//
//  设计原则：任何一次写入失败都不能让 App 崩溃；失败只记录 writeError，由 UI 用 Toast 提示。
//

import Foundation

// MARK: - 备份恢复的校验错误

/// 设置页「从备份导入（恢复）」在读取备份文件时的校验失败原因。
/// 收敛成枚举是为了让 UI 能区分「选错文件」「版本太新」「备份是空的」几种情况并给出对应建议。
enum BackupError: LocalizedError {

    /// 不是 .json 文件
    case unsupportedExtension(String)
    /// 文件过大
    case fileTooLarge
    /// 打不开或不是合法备份结构
    case unreadable
    /// 备份结构版本高于当前 App 支持的版本
    case schemaTooNew(Int)
    /// 备份里没有任何单词与词单（恢复等于清空，属于破坏性结果）
    case noContent

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension(let ext):
            return ext.isEmpty
                ? "请选择 RootWord 导出的 .json 备份文件"
                : "暂不支持 .\(ext) 文件，请选择 RootWord 导出的 .json 备份"
        case .fileTooLarge:
            return "备份文件超过 50 MB，无法导入"
        case .unreadable:
            return "这个文件不是可用的 RootWord 备份，内容无法解析"
        case .schemaTooNew(let version):
            return "备份版本 v\(version) 比当前 App 支持的 v\(Store.BackupFile.currentSchemaVersion) 更新，请先升级 App"
        case .noContent:
            return "备份里没有任何单词或词单，导入会把当前数据清空，已取消"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unsupportedExtension, .unreadable:
            return "在设置页「导出备份」，再到「文件」App 里选择那份 rootword-backup-*.json"
        case .schemaTooNew:
            return "升级到最新版本后再恢复"
        case .fileTooLarge, .noContent:
            return nil
        }
    }
}

final class Store {

    static let shared = Store()

    // MARK: - 路径

    private let fm = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.rootword.vocab.store.io", qos: .utility)
    /// 单份备份文件的体积上限（恢复时的安全闸门）
    private let maxBackupSize = 50 * 1024 * 1024

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
        // Documents 是导出备份的落点，同样要保证存在：
        // 目录缺失时 `Data.write` 会直接抛错，用户看到的现象就是「导出后什么都没有」。
        try? fm.createDirectory(at: documentsDir, withIntermediateDirectories: true)
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

    /// 设置页「导出备份」：全量写成 JSON 到 Documents 并返回文件 URL。
    ///
    /// 三个必须守住的点（对应「导出备份是空白的 / 找不到」这类问题）：
    /// 1. 文件名带**秒级时间戳、绝不覆盖已有备份**。旧实现只按 `yyyyMMdd` 命名，
    ///    同一天里「清空前的自动备份」与「手动导出」会写到同一个文件，
    ///    后写的少量数据会把先写出的完整备份顶掉——用户打开备份只看到一小段甚至空白；
    /// 2. 写完后**回读自检**：文件不存在 / 读不回来 / 词条数与本次导出对不上，一律判定失败，
    ///    并删掉半成品，绝不让空文件流到分享面板或「文件」App 里；
    /// 3. 失败原因写进 `lastWriteError`，由 UI 明确告知，而不是静默返回 nil。
    func exportBackup(words: [Word], decks: [Deck], logs: [ReviewLog], settings: AppSettings) -> URL? {
        try? fm.createDirectory(at: documentsDir, withIntermediateDirectories: true)

        let payload = BackupFile(exportedAt: Date(), words: words, decks: decks, logs: logs, settings: settings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload), !data.isEmpty else {
            lastWriteError = "备份内容编码失败"
            return nil
        }

        let url = uniqueBackupURL(now: Date())
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastWriteError = "写入备份失败：\(error.localizedDescription)"
            return nil
        }

        if let reason = verifyWrittenBackup(at: url, expectWords: words.count, expectDecks: decks.count) {
            try? fm.removeItem(at: url)   // 不把空/残缺文件留在「文件」App 里误导用户
            lastWriteError = reason
            return nil
        }
        lastWriteError = nil
        return url
    }

    /// 备份文件名：`rootword-backup-20260918-231530.json`（秒级唯一）
    /// 同一秒内重复导出时追加 `-2`、`-3`，保证任何情况下都不覆盖历史备份。
    private func uniqueBackupURL(now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)

        var url = documentsDir.appendingPathComponent("rootword-backup-\(stamp).json")
        var suffix = 2
        while fm.fileExists(atPath: url.path) {
            url = documentsDir.appendingPathComponent("rootword-backup-\(stamp)-\(suffix).json")
            suffix += 1
        }
        return url
    }

    /// 导出后的回读自检：文件确实落盘、能被解码回来、词条数与本次导出的一致。
    /// 返回 nil 表示校验通过，否则返回可展示给用户的失败原因。
    private func verifyWrittenBackup(at url: URL, expectWords: Int, expectDecks: Int) -> String? {
        guard fm.fileExists(atPath: url.path) else { return "备份文件没有生成" }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "备份文件是空的" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(BackupFile.self, from: data) else { return "备份文件写完后读不回来" }
        guard file.words.count == expectWords, file.decks.count == expectDecks else {
            return "备份内容不完整（单词 \(file.words.count)/\(expectWords)，词单 \(file.decks.count)/\(expectDecks)）"
        }
        return nil
    }

    /// 读取并校验备份文件（只读，不触碰任何当前数据）。
    /// 扩展名、体积、结构、版本、内容五项都过一遍；不通过一律抛 `BackupError`。
    func importBackup(from url: URL) throws -> BackupFile {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ext == "json" || ext.isEmpty else { throw BackupError.unsupportedExtension(ext) }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maxBackupSize {
            throw BackupError.fileTooLarge
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw BackupError.unreadable }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: BackupFile
        do {
            file = try decoder.decode(BackupFile.self, from: data)
        } catch {
            throw BackupError.unreadable
        }

        // 旧 App 读新结构会静默丢字段，宁可拦住
        guard file.schemaVersion <= BackupFile.currentSchemaVersion else {
            throw BackupError.schemaTooNew(file.schemaVersion)
        }
        // 空备份会「恢复」成空库，属于破坏性结果，直接拦下
        guard !(file.words.isEmpty && file.decks.isEmpty) else {
            throw BackupError.noContent
        }
        return file
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

        /// 当前 App 能读的最高备份结构版本（结构变更时 +1）
        static let currentSchemaVersion = 1

        var exportedAt: Date
        var words: [Word]
        var decks: [Deck]
        var logs: [ReviewLog]
        var settings: AppSettings
        /// 兼容性标记，便于未来升级
        var schemaVersion: Int

        init(exportedAt: Date,
             words: [Word],
             decks: [Deck],
             logs: [ReviewLog],
             settings: AppSettings,
             schemaVersion: Int = BackupFile.currentSchemaVersion) {
            self.exportedAt = exportedAt
            self.words = words
            self.decks = decks
            self.logs = logs
            self.settings = settings
            self.schemaVersion = schemaVersion
        }

        /// 手写解码：`schemaVersion` / `logs` / `settings` 允许缺失（按 v1 备份处理）。
        /// 合成解码不会使用属性默认值，缺字段会直接抛 keyNotFound——那会把一份其实可用的
        /// 备份判成「无法解析」，所以这里显式兜底。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            exportedAt = try container.decode(Date.self, forKey: .exportedAt)
            words = try container.decode([Word].self, forKey: .words)
            decks = try container.decode([Deck].self, forKey: .decks)
            logs = try container.decodeIfPresent([ReviewLog].self, forKey: .logs) ?? []
            settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }

        /// 恢复前的数据体检（纯函数）：把备份里 App 无法直接消化的部分修正成可用形态——
        /// ① 只有单词没有词单 → 补一个「已恢复」词单，否则恢复出来的单词在界面上找不到归属；
        /// ② 多个词单都标了「当前词单」→ 只保留第一个（App 要求恰好一个）；
        /// ③ 没有任何词单是「当前词单」→ 把第一个设为当前；
        /// ④ 单词的 deckID 指向已不存在的词单 → 收拢到当前词单，避免「孤儿单词」。
        ///
        /// 只做结构修补，不改动单词内容（释义、进度、例句原样保留）。
        func sanitizedForRestore() -> BackupFile {
            var file = self

            if file.decks.isEmpty {
                file.decks = [Deck(name: "已恢复", isCurrent: true)]
            }

            var seenCurrent = false
            for index in file.decks.indices where file.decks[index].isCurrent {
                if seenCurrent {
                    file.decks[index].isCurrent = false
                } else {
                    seenCurrent = true
                }
            }
            if !seenCurrent { file.decks[0].isCurrent = true }

            let deckIDs = Set(file.decks.map { $0.id })
            let fallbackID = file.decks.first(where: { $0.isCurrent })?.id ?? file.decks[0].id
            for index in file.words.indices where !deckIDs.contains(file.words[index].deckID) {
                file.words[index].deckID = fallbackID
            }
            return file
        }
    }
}
