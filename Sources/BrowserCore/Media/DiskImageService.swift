import Foundation

public struct MountedDiskImage: Equatable, Sendable {
    public let source: URL
    public let root: URL
    public let device: String

    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }
}

/// Uses private, stable mount points so cached previews and saved groups survive reopening.
/// Only mounts created at this service's mount points may be detached by the app.
public actor DiskImageService {
    private let directory: URL
    private var pending: [URL: Task<MountedDiskImage, Error>] = [:]

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBrowser/DiskImages", isDirectory: true)
    }

    public nonisolated static func supports(_ url: URL) -> Bool { url.pathExtension.lowercased() == "iso" }

    public func mount(_ input: URL) async throws -> MountedDiskImage {
        let source = input.resolvingSymlinksInPath().standardizedFileURL
        if let task = pending[source] { return try await task.value }
        let root = directory.appendingPathComponent(ThumbnailCache.digest(source.path), isDirectory: true).resolvingSymlinksInPath()
        let task = Task.detached(priority: .userInitiated) { try Self.attach(source, at: root) }
        pending[source] = task
        defer { pending[source] = nil }
        return try await task.value
    }

    public func eject(_ image: MountedDiskImage) async throws {
        // Resolve ownership again: a previously saved /dev/diskN may have been reused.
        try await Task.detached(priority: .userInitiated) {
            let images = try Self.attachedImages()
            guard let current = Self.find(image.source, root: image.root, in: images) else {
                if images.contains(where: { Self.hasMountPoint(image.root, in: $0) }) {
                    throw BrowserFailure.message(L10n.text("镜像挂载状态已变化，请重新打开后再推出。"))
                }
                return // Already ejected by Finder; never detach an unrelated device.
            }
            _ = try Self.run(["detach", current.device])
        }.value
    }

    private static func attach(_ source: URL, at proposedRoot: URL) throws -> MountedDiskImage {
        guard supports(source), try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BrowserFailure.message(L10n.text("请选择有效的 ISO 光盘镜像。"))
        }
        try FileManager.default.createDirectory(at: proposedRoot, withIntermediateDirectories: true)
        let root = proposedRoot.resolvingSymlinksInPath()
        if let existing = find(source, root: root, in: try attachedImages()) {
            guard try root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true else {
                throw BrowserFailure.message(L10n.text("镜像未以只读方式挂载，无法打开。"))
            }
            return existing
        }
        let data = try run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-noautofsck", "-noverify",
                            "-plist", "-mountpoint", root.path, source.path])
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        guard let image = find(source, root: root, in: [info.merging(["image-path": source.path]) { _, new in new }]) else {
            throw BrowserFailure.message(L10n.text("无法找到镜像的挂载目录，请检查镜像格式或是否已在其他应用打开。"))
        }
        guard try root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true else {
            _ = try run(["detach", image.device])
            throw BrowserFailure.message(L10n.text("镜像未以只读方式挂载，无法打开。"))
        }
        return image
    }

    private static func attachedImages() throws -> [[String: Any]] {
        let data = try run(["info", "-plist"])
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["images"] as? [[String: Any]] ?? []
    }

    private static func entities(_ info: [String: Any]) -> [[String: Any]] {
        info["system-entities"] as? [[String: Any]] ?? []
    }

    private static func hasMountPoint(_ root: URL, in info: [String: Any]) -> Bool {
        entities(info).contains { part in
            guard let path = part["mount-point"] as? String else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == root.standardizedFileURL.path
        }
    }

    private static func find(_ source: URL, root: URL, in images: [[String: Any]]) -> MountedDiskImage? {
        for info in images {
            guard let path = info["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath() == source else { continue }
            let parts = entities(info)
            guard hasMountPoint(root, in: info),
                  let device = parts.first?["dev-entry"] as? String, device.hasPrefix("/dev/disk") else { continue }
            return MountedDiskImage(source: source, root: root, device: device)
        }
        return nil
    }

    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        let errors = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoBrowser-disk-image-" + UUID().uuidString)
        try Data().write(to: errors, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: errors) }
        let handle = try FileHandle(forWritingTo: errors)
        defer { try? handle.close() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = handle
        try process.run()
        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeout.schedule(deadline: .now() + 120)
        timeout.setEventHandler { if process.isRunning { process.terminate() } }
        timeout.resume()
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(decoding: try Data(contentsOf: errors), as: UTF8.self).split(separator: "\n")
                .filter { !$0.hasPrefix("hdiutil: WARNING:") }.joined(separator: "\n")
            throw BrowserFailure.message(L10n.text("光盘镜像操作失败：\(details)"))
        }
        return data
    }
}
