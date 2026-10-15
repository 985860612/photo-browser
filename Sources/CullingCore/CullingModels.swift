import Foundation
import BrowserCore

public enum CullingMark: String, Codable, CaseIterable, Sendable {
    case unreviewed, keep, maybe, reject
}

public struct CullingDecision: Codable, Equatable, Sendable {
    public let mark: CullingMark
    public let fingerprint: String
    public init(mark: CullingMark, fingerprint: String) { self.mark = mark; self.fingerprint = fingerprint }
}

public struct AnalysisOptions: Codable, Equatable, Sendable {
    public var similarityThreshold: Float = 0.35
    public var similarity = true
    public var aesthetics = true
    public var faces = true
    public var classification = true
    public init() {}
    // Changing the pipeline or image normalization invalidates machine results, never decisions.
    public var signature: String { "vision-v2-1280-srgb-fp2|\(similarity)|\(aesthetics)|\(faces)|\(classification)" }
    public var isEmpty: Bool { !similarity && !aesthetics && !faces && !classification }
}

public struct AnalysisRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let quality: Float?
    public init(x: Double, y: Double, width: Double, height: Double, quality: Float? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.quality = quality
    }
}

public struct AnalysisLabel: Codable, Equatable, Sendable {
    public let identifier: String
    public let confidence: Float
    public init(identifier: String, confidence: Float) { self.identifier = identifier; self.confidence = confidence }
}

public struct PhotoAnalysis: Codable, Sendable {
    public let assetID: String
    public let fingerprint: String
    public let signature: String
    public var captured: Date?
    public var featurePrint: Data?
    public var aesthetics: Float?
    public var isUtility: Bool?
    public var faces: [AnalysisRegion] = []
    public var subjects: [AnalysisRegion] = []
    public var labels: [AnalysisLabel] = []
    public init(assetID: String, fingerprint: String, signature: String) {
        self.assetID = assetID; self.fingerprint = fingerprint; self.signature = signature
    }
    public func isCurrent(for asset: PhotoAsset, options: AnalysisOptions? = nil) -> Bool {
        assetID == asset.id && fingerprint == asset.fingerprint && (options == nil || options?.signature == signature)
    }
}

public struct SimilarityGroup: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var assetIDs: [String]
    public init(id: String = UUID().uuidString, assetIDs: [String]) { self.id = id; self.assetIDs = assetIDs }
}

public struct CullingSession: Codable, Sendable {
    public var version = 1
    public var decisions: [String: CullingDecision] = [:]
    public var excludedFromSimilarity: Set<String> = []
    public var manualGroups: [SimilarityGroup] = []
    public var options = AnalysisOptions()
    public init() {}
}
