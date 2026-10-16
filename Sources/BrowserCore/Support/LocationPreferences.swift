import Foundation

public struct LocationPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Used only when the photo has no recognized coordinate-system marker.
    public var preferredCoordinateSystem: PhotoCoordinateSystem {
        get { defaults.string(forKey: "preferredCoordinateSystem").flatMap(PhotoCoordinateSystem.init(rawValue:)) ?? .wgs84 }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "preferredCoordinateSystem") }
    }
}
