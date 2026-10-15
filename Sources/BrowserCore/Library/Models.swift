import Foundation

public enum PhotoKind: String, Codable, Sendable {
    case raw, rendered, video, sidecar
}

public struct PhotoFile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let kind: PhotoKind
    public let size: Int64
    public let modified: Date
    public var format: String { url.pathExtension.uppercased() }
    public var isLivePhoto: Bool { url.pathExtension.lowercased() == "livp" }
    public init(url: URL, kind: PhotoKind, size: Int64 = 0, modified: Date = .distantPast) {
        self.url = url; self.kind = kind; self.size = size; self.modified = modified
    }
}

public struct PhotoMetadata: Codable, Sendable {
    public var captured: Date?
    public var sequence: Int?
    public var focalLength: Double?
    public var aperture: Double?
    public var iso: Int?
    public var shutter: String?
    public var camera: String?
    public var lensModel: String?
    public var gpsLatitude: Double?
    public var gpsLongitude: Double?
    public var gpsAltitude: Double?
    public var location: PhotoLocation? {
        guard let gpsLatitude, let gpsLongitude else { return nil }
        return PhotoLocation(latitude: gpsLatitude, longitude: gpsLongitude, altitude: gpsAltitude)
    }
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var frameRate: Float?
    public init(captured: Date? = nil, sequence: Int? = nil, focalLength: Double? = nil) {
        self.captured = captured; self.sequence = sequence; self.focalLength = focalLength
    }
}

public struct PhotoAsset: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let files: [PhotoFile]
    public var metadata: PhotoMetadata?
    public var imageFiles: [PhotoFile] { files.filter { $0.kind == .raw || $0.kind == .rendered } }
    public var mediaFiles: [PhotoFile] { files.filter { $0.kind != .sidecar } }
    public var isVideo: Bool { mediaFiles.contains { $0.kind == .video } }
    public var isLivePhoto: Bool { mediaFiles.contains( where: \.isLivePhoto) }
    public var preferred: PhotoFile { mediaFiles.first { $0.kind == .rendered } ?? mediaFiles[0] }
    public var metadataFile: PhotoFile { imageFiles.first { $0.kind == .raw } ?? preferred }
    public var formatLabel: String { mediaFiles.map(\.format).joined(separator: " + ") }
    public init(id: String, name: String, files: [PhotoFile], metadata: PhotoMetadata? = nil) {
        self.id = id; self.name = name; self.files = files; self.metadata = metadata
    }
}

public enum GroupConfidence: String, Codable, Sendable, CaseIterable {
    case candidate = "全景候选"
    case review = "待确认"
    case manual = "手动分组"
}

public struct PhotoGroup: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var assetIDs: [String]
    public var confidence: GroupConfidence
    public var reason: String
    public init(id: String = UUID().uuidString, name: String, assetIDs: [String], confidence: GroupConfidence = .manual, reason: String = L10n.text("手动选择的照片")) {
        self.id = id; self.name = name; self.assetIDs = assetIDs; self.confidence = confidence; self.reason = reason
    }
}

public enum BrowserFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
