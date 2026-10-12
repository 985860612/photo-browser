import Foundation

public struct ArchiveEntry: Codable, Sendable {
    public let source: URL
    public let destination: URL
    public let size: Int64
    public let modified: Date
}

public struct ArchiveRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let created: Date
    public let sourceDirectory: URL
    public let destination: URL
    public let group: PhotoGroup
    public let entries: [ArchiveEntry]
    public var state: String
    public var message: String?
    public var destinationCreated: Bool = false
}

public struct ArchivePlan: Sendable {
    public let record: ArchiveRecord
    public var fileCount: Int { record.entries.count }
    public var totalBytes: Int64 { record.entries.reduce(0) { $0 + $1.size } }
    public init(directory: URL, destination: URL, group: PhotoGroup, assets: [PhotoAsset]) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard target != root, !target.path.hasPrefix(root.path + "/.") else {
            throw BrowserFailure.message("请选择独立的分组目录。")
        }
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        guard !group.assetIDs.isEmpty, Set(group.assetIDs).count == group.assetIDs.count else {
            throw BrowserFailure.message("分组为空或包含重复照片。")
        }
        var entries: [ArchiveEntry] = []
        for id in group.assetIDs {
            guard let asset = byID[id] else { throw BrowserFailure.message("照片 \(id) 已不在当前目录，请刷新后重试。") }
            for file in asset.files {
                let parent = file.url.deletingLastPathComponent().standardizedFileURL
                guard parent == directory.standardizedFileURL || parent.resolvingSymlinksInPath() == root else {
                    throw BrowserFailure.message("文件不属于当前照片目录：\(file.url.lastPathComponent)")
                }
                entries.append(ArchiveEntry(source: file.url, destination: target.appendingPathComponent(file.url.lastPathComponent), size: file.size, modified: file.modified))
            }
        }
        guard Set(entries.map { $0.destination.path.lowercased() }).count == entries.count else {
            throw BrowserFailure.message("分组存在大小写重名文件，请先处理冲突。")
        }
        record = ArchiveRecord(id: UUID().uuidString, created: Date(), sourceDirectory: root, destination: target, group: group, entries: entries, state: "prepared", message: nil)
    }
}

/// A durable local journal is written before any original file is moved.
/// Recovery reconciles real file locations, including a crash between rename and journal write.
public struct ArchiveEngine {
    public let journalDirectory: URL
    private let mover: (URL, URL) throws -> Void
    private let fm = FileManager.default

    public init(journalDirectory: URL, mover: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        self.journalDirectory = journalDirectory; self.mover = mover
    }

    public func journalURL(_ record: ArchiveRecord) -> URL { journalDirectory.appendingPathComponent(record.id + ".json") }

    public func records() throws -> [ArchiveRecord] {
        guard fm.fileExists(atPath: journalDirectory.path) else { return [] }
        return try fm.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(ArchiveRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    public func archive(_ plan: ArchivePlan) throws -> ArchiveRecord {
        var record = plan.record
        guard !fm.fileExists(atPath: record.destination.path) else {
            throw BrowserFailure.message("目标文件夹已存在，不会覆盖：\(record.destination.path)")
        }
        for entry in record.entries { try validate(entry.source, against: entry) }
        try persist(record)
        do {
            try fm.createDirectory(at: record.destination, withIntermediateDirectories: false)
            record.destinationCreated = true
            record.state = "moving"; try persist(record)
            for entry in record.entries {
                // Refuse races with a newly created destination file.
                guard !fm.fileExists(atPath: entry.destination.path) else { throw BrowserFailure.message("目标文件已存在：\(entry.destination.lastPathComponent)") }
                try validate(entry.source, against: entry)
                try mover(entry.source, entry.destination)
                try validate(entry.destination, against: entry)
                try persist(record)
            }
            record.state = "complete"; try persist(record)
            return record
        } catch {
            let initialError = error.localizedDescription
            do {
                try restoreFiles(record)
                try removeEmptyDestination(record)
                record.state = "rolledBack"; record.message = initialError; try persist(record)
            } catch {
                record.state = "recoveryNeeded"
                record.message = "\(initialError)；回滚未完成：\(error.localizedDescription)"
                do { try persist(record) } catch {
                    throw BrowserFailure.message("归档及回滚失败，记录更新也失败。原始记录：\(journalURL(record).path)。\(initialError)；\(error.localizedDescription)")
                }
                throw BrowserFailure.message("归档未完成，需要恢复：\(record.message!)。移动记录：\(journalURL(record).path)")
            }
            throw BrowserFailure.message("归档失败，已恢复原文件：\(initialError)")
        }
    }

    public func undo(_ input: ArchiveRecord) throws -> ArchiveRecord {
        var record = try JSONDecoder().decode(ArchiveRecord.self, from: Data(contentsOf: journalURL(input)))
        guard ["complete", "prepared", "moving", "undoing", "recoveryNeeded"].contains(record.state) else {
            throw BrowserFailure.message("这条记录已经撤销或回滚。")
        }
        // Preflight ALL entries first. A conflict must not cause a half-completed undo.
        try validateRestore(record)
        record.state = "undoing"; try persist(record)
        do {
            try restoreFiles(record)
            try removeEmptyDestination(record)
            record.state = "undone"; record.message = nil; try persist(record)
            return record
        } catch {
            record.state = "recoveryNeeded"; record.message = error.localizedDescription
            do { try persist(record) } catch {
                throw BrowserFailure.message("撤销中断且记录更新失败：\(error.localizedDescription)。保留记录：\(journalURL(record).path)")
            }
            throw BrowserFailure.message("撤销中断，可在移动记录中继续恢复：\(error.localizedDescription)")
        }
    }

    private func persist(_ record: ArchiveRecord) throws {
        try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: journalURL(record), options: .atomic)
    }

    private func validate(_ url: URL, against entry: ArchiveEntry) throws {
        guard fm.fileExists(atPath: url.path) else { throw BrowserFailure.message("文件不存在：\(url.path)") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == entry.size,
              abs((values.contentModificationDate ?? .distantPast).timeIntervalSince(entry.modified)) < 1 else {
            throw BrowserFailure.message("文件已变化或不是普通文件，请重新扫描：\(url.lastPathComponent)")
        }
    }

    private func validateRestore(_ record: ArchiveRecord) throws {
        for entry in record.entries {
            let sourceExists = fm.fileExists(atPath: entry.source.path)
            let targetExists = fm.fileExists(atPath: entry.destination.path)
            guard sourceExists != targetExists else {
                throw BrowserFailure.message(sourceExists ? "原目录有同名文件，拒绝覆盖：\(entry.source.lastPathComponent)" : "原目录和目标目录都找不到文件：\(entry.source.lastPathComponent)")
            }
            try validate(sourceExists ? entry.source : entry.destination, against: entry)
        }
    }

    private func restoreFiles(_ record: ArchiveRecord) throws {
        try validateRestore(record)
        for entry in record.entries.reversed() {
            guard fm.fileExists(atPath: entry.destination.path) else { continue }
            guard !fm.fileExists(atPath: entry.source.path) else { throw BrowserFailure.message("原目录出现同名文件：\(entry.source.lastPathComponent)") }
            try validate(entry.destination, against: entry)
            try mover(entry.destination, entry.source)
            try validate(entry.source, against: entry)
        }
    }

    private func removeEmptyDestination(_ record: ArchiveRecord) throws {
        guard record.destinationCreated else { return }
        guard fm.fileExists(atPath: record.destination.path) else { return }
        if try fm.contentsOfDirectory(atPath: record.destination.path).isEmpty {
            try fm.removeItem(at: record.destination)
        }
    }
}
