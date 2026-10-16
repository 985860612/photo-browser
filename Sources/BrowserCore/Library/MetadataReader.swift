import Foundation
import ImageIO

public final class MetadataReader {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public static var executable: URL? {
        ["/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }

    public func read(directory: URL, assets: [PhotoAsset]) throws -> [String: PhotoMetadata] {
        var liveMetadata: [String: PhotoMetadata] = [:]
        for asset in assets where asset.metadataFile.isLivePhoto {
            lock.lock(); let stop = cancelled; lock.unlock()
            if stop { throw CancellationError() }
            if let source = try PhotoMediaSource.open(asset.metadataFile, check: {
                self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
                if cancelled { throw CancellationError() }
            }), let metadata = ImageMetadataReader.read(source) { liveMetadata[asset.id] = metadata }
        }
        let assets = assets.filter { !$0.metadataFile.isLivePhoto }
        if assets.isEmpty { return liveMetadata }
        guard let binary = Self.executable else {
            throw BrowserFailure.message(L10n.text("自动分组需要 ExifTool。请安装后重试：brew install exiftool。照片浏览和手动分组仍可使用。"))
        }
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".stderr")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else { throw BrowserFailure.message(L10n.text("无法创建拍摄信息读取日志。")) }
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close(); try? FileManager.default.removeItem(at: errorURL) }
        let p = Process(), output = Pipe()
        p.executableURL = binary
        p.currentDirectoryURL = directory
        p.arguments = ["-fast", "-j", "-DateTimeOriginal", "-SubSecTimeOriginal", "-SequenceNumber", "-FocalLength#", "-FNumber", "-ISO", "-ExposureTime", "-Model", "-LensModel", "-ImageWidth", "-ImageHeight",
                       "-GPSMapDatum", "-GPSLatitude#", "-GPSLatitudeRef#", "-GPSLongitude#", "-GPSLongitudeRef#", "-GPSAltitude#", "-GPSAltitudeRef#", "--"] + assets.map { $0.metadataFile.url.lastPathComponent }
        p.standardOutput = output; p.standardError = errorHandle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = p
        do { try p.run(); lock.unlock() } catch { lock.unlock(); throw error }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard p.terminationStatus == 0 else {
            let message = String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? L10n.text("未知错误")
            throw BrowserFailure.message(L10n.text("拍摄信息读取失败：\(message.prefix(1200))"))
        }
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw BrowserFailure.message(L10n.text("无法解析相机拍摄信息。"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var result: [String: PhotoMetadata] = liveMetadata
        for object in objects {
            guard let source = object["SourceFile"] as? String else { continue }
            let id = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent.lowercased()
            var value = PhotoMetadata()
            if let time = object["DateTimeOriginal"] as? String, let captured = formatter.date(from: time) {
                var fraction = String(describing: object["SubSecTimeOriginal"] ?? "0")
                if fraction.count < 3 { fraction = String(repeating: "0", count: 3 - fraction.count) + fraction }
                value.captured = captured.addingTimeInterval(Double("0." + fraction) ?? 0)
            }
            value.sequence = (object["SequenceNumber"] as? NSNumber)?.intValue
            value.focalLength = (object["FocalLength"] as? NSNumber)?.doubleValue
            value.aperture = (object["FNumber"] as? NSNumber)?.doubleValue
            value.iso = (object["ISO"] as? NSNumber)?.intValue
            value.shutter = object["ExposureTime"].map { String(describing: $0) }
            value.camera = object["Model"] as? String
            value.lensModel = object["LensModel"] as? String
            value.width = (object["ImageWidth"] as? NSNumber)?.intValue
            value.height = (object["ImageHeight"] as? NSNumber)?.intValue
            value.gpsMapDatum = object["GPSMapDatum"] as? String
            value.gpsMapDatumRead = true
            if let location = PhotoLocation(exifLatitude: (object["GPSLatitude"] as? NSNumber)?.doubleValue,
                                            latitudeRef: object["GPSLatitudeRef"] as? String,
                                            exifLongitude: (object["GPSLongitude"] as? NSNumber)?.doubleValue,
                                            longitudeRef: object["GPSLongitudeRef"] as? String,
                                            altitude: (object["GPSAltitude"] as? NSNumber)?.doubleValue,
                                            belowSeaLevel: (object["GPSAltitudeRef"] as? NSNumber)?.intValue == 1) {
                value.gpsLatitude = location.latitude; value.gpsLongitude = location.longitude; value.gpsAltitude = location.altitude
            }
            result[id] = value
        }
        return result
    }
}
