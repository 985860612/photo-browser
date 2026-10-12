import Foundation

/// Shared by windowed and fullscreen browsing; zero disables one direction.
public struct PreviewPreferences {
    private let defaults: UserDefaults
    public static let range = 0...20
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var before: Int {
        get { Self.clamp(defaults.object(forKey: "previewBefore") as? Int ?? 2) }
        nonmutating set { defaults.set(Self.clamp(newValue), forKey: "previewBefore") }
    }
    public var after: Int {
        get { Self.clamp(defaults.object(forKey: "previewAfter") as? Int ?? 5) }
        nonmutating set { defaults.set(Self.clamp(newValue), forKey: "previewAfter") }
    }
    public static func clamp(_ count: Int) -> Int { min(range.upperBound, max(range.lowerBound, count)) }

    public static func neighbors<T>(in items: [T], index: Int, before: Int, after: Int) -> [T] {
        guard items.indices.contains(index) else { return [] }
        let before = clamp(before), after = clamp(after)
        var result: [T] = []
        for distance in 1..<max(before, after) + 1 {
            if distance <= after, index + distance < items.count { result.append(items[index + distance]) }
            if distance <= before, index - distance >= 0 { result.append(items[index - distance]) }
        }
        return result
    }
}
