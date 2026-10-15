import Foundation

/// EXIF coordinates stay in their original WGS 84 system; no geographic guessing or offsets.
public struct PhotoLocation: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?

    public init?(latitude: Double, longitude: Double, altitude: Double? = nil) {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        self.latitude = latitude; self.longitude = longitude
        self.altitude = altitude.flatMap { $0.isFinite ? $0 : nil }
    }

    public init?(exifLatitude: Double?, latitudeRef: String?, exifLongitude: Double?, longitudeRef: String?,
                 altitude: Double? = nil, belowSeaLevel: Bool = false) {
        guard let latitude = Self.signed(exifLatitude, reference: latitudeRef, positive: "N", negative: "S"),
              let longitude = Self.signed(exifLongitude, reference: longitudeRef, positive: "E", negative: "W") else { return nil }
        self.init(latitude: latitude, longitude: longitude, altitude: altitude.map { belowSeaLevel ? -abs($0) : $0 })
    }

    private static func signed(_ value: Double?, reference: String?, positive: String, negative: String) -> Double? {
        guard let value else { return nil }
        guard let reference else { return value } // Already-signed coordinates are also supported.
        switch reference.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case positive: return abs(value)
        case negative: return -abs(value)
        default: return nil
        }
    }

    public var latitudeLabel: String { String(format: "%.6f° %@", locale: Locale(identifier: "en_US_POSIX"), abs(latitude), latitude < 0 ? "S" : "N") }
    public var longitudeLabel: String { String(format: "%.6f° %@", locale: Locale(identifier: "en_US_POSIX"), abs(longitude), longitude < 0 ? "W" : "E") }
}
