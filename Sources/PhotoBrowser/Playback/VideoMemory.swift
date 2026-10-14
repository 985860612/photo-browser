import Foundation
import BrowserCore

@MainActor final class VideoMemory {
    private struct Position: Codable {
        let seconds: Double
        let updated: Date
    }
    private let defaults: UserDefaults
    private var positions: [String: Position]
    init(defaults: UserDefaults) {
        self.defaults = defaults
        positions = defaults.data(forKey: "videoPositions").flatMap { try? JSONDecoder().decode([String: Position].self, from: $0) } ?? [:]
    }
    private func key(_ file: PhotoFile) -> String {
        ThumbnailCache.digest("\(file.url.standardizedFileURL.path)|\(file.size)|\(file.modified.timeIntervalSince1970)")
    }
    func position(_ file: PhotoFile) -> Double { positions[key(file)]?.seconds ?? 0 }
    func save(_ file: PhotoFile, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[key(file)] = Position(seconds: seconds, updated: Date())
        if positions.count > 200 {
            positions = Dictionary(uniqueKeysWithValues: positions.sorted { $0.value.updated > $1.value.updated }.prefix(200).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(positions) { defaults.set(data, forKey: "videoPositions") }
    }
    var volume: Float {
        get { min(1, max(0, defaults.object(forKey: "videoVolume") as? Float ?? 1)) }
        set { if newValue.isFinite { defaults.set(min(1, max(0, newValue)), forKey: "videoVolume") } }
    }
    var muted: Bool {
        get { defaults.bool(forKey: "videoMuted") }
        set { defaults.set(newValue, forKey: "videoMuted") }
    }
}
