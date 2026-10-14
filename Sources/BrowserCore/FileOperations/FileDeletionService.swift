import Foundation

/// Validates the confirmed snapshot before permanently removing files. No UI or move journal.
public enum FileDeletionService {
    public static func removeMedia(_ files: [PhotoFile], from parent: URL) throws {
        guard !files.isEmpty, Set(files.map(\.id)).count == files.count else {
            throw BrowserFailure.message(L10n.text("删除列表为空或包含重复文件。"))
        }
        func validate(_ file: PhotoFile) throws {
            guard file.url.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL else {
                throw BrowserFailure.message(L10n.text("只能删除当前目录中的文件。"))
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.size,
                  let modified = attributes[.modificationDate] as? Date, abs(modified.timeIntervalSince(file.modified)) < 1 else {
                throw BrowserFailure.message(L10n.text("文件已变化或不是普通文件，请重新扫描：\(file.url.lastPathComponent)"))
            }
        }
        for file in files { try validate(file) }
        for file in files { try validate(file); try FileManager.default.removeItem(at: file.url) }
    }

    public static func removeFolder(_ folder: URL, from parent: URL) throws {
        let target = folder.standardizedFileURL
        guard target.deletingLastPathComponent() == parent.standardizedFileURL, target != parent.standardizedFileURL else {
            throw BrowserFailure.message(L10n.text("只能删除当前目录中的子文件夹。"))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw BrowserFailure.message(L10n.text("目标不是普通文件夹，不能删除：\(target.lastPathComponent)"))
        }
        try FileManager.default.removeItem(at: target)
    }

}
