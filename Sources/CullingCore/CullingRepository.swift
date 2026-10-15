import Foundation
import BrowserCore

/// Human decisions and disposable machine results have separate, atomic storage.
public struct CullingRepository: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func libraryDirectory(_ library: URL) -> URL {
        directory.appendingPathComponent(ThumbnailCache.digest(library.resolvingSymlinksInPath().standardizedFileURL.path))
    }
    public func loadSession(in library: URL) throws -> CullingSession {
        let file = libraryDirectory(library).appendingPathComponent("decisions.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return CullingSession() }
        let session = try JSONDecoder().decode(CullingSession.self, from: Data(contentsOf: file))
        guard session.version == 1 else { throw BrowserFailure.message(L10n.text("选片记录版本不受支持，未覆盖已有记录。")) }
        return session
    }
    public func save(_ session: CullingSession, in library: URL) throws {
        let folder = libraryDirectory(library)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: folder.appendingPathComponent("decisions.json"), options: .atomic)
    }
    private func analysisURL(_ id: String, in library: URL) -> URL {
        libraryDirectory(library).appendingPathComponent("Analysis").appendingPathComponent(ThumbnailCache.digest(id) + ".json")
    }
    public func loadAnalyses(for assets: [PhotoAsset], in library: URL) throws -> [String: PhotoAnalysis] {
        var result: [String: PhotoAnalysis] = [:]
        for asset in assets where !asset.isVideo {
            let file = analysisURL(asset.id, in: library)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file)
            do {
                let analysis = try JSONDecoder().decode(PhotoAnalysis.self, from: data)
                if let feature = analysis.featurePrint { _ = try VisionPhotoAnalyzer.feature(feature) }
                if analysis.isCurrent(for: asset) { result[asset.id] = analysis }
            } catch { continue } // Invalid machine content is replaceable; I/O failures above still report.
        }
        return result
    }
    public func save(_ analysis: PhotoAnalysis, in library: URL) throws {
        let file = analysisURL(analysis.assetID, in: library)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(analysis).write(to: file, options: .atomic)
    }
}
