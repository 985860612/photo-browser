import Foundation

public enum PhotoCoordinateSystem: String, CaseIterable, Codable, Sendable {
    case wgs84, gcj02, bd09

    public var label: String {
        switch self {
        case .wgs84: return "WGS-84"
        case .gcj02: return "GCJ-02"
        case .bd09: return "BD-09"
        }
    }

    /// Only explicit datum names establish a coordinate system. Coordinates and camera models do not.
    public init?(mapDatum: String?) {
        guard let mapDatum else { return nil }
        let code = mapDatum.uppercased().filter { $0.isLetter || $0.isNumber }
        switch code {
        case "WGS84", "WGS1984", "EPSG4326": self = .wgs84
        case "GCJ02": self = .gcj02
        case "BD09", "BD09LL": self = .bd09
        default: return nil
        }
    }

    /// Local approximations for map display; never write the result to original photo metadata.
    public func converting(_ location: PhotoLocation, to target: Self) -> PhotoLocation? {
        guard self != target else { return location }
        let gcj: PhotoLocation
        switch self {
        case .wgs84: gcj = Self.wgsToGCJ(location)
        case .gcj02: gcj = location
        case .bd09:
            let x = location.longitude - 0.0065, y = location.latitude - 0.006
            let factor = Double.pi * 3000 / 180
            let z = hypot(x, y) - 0.00002 * sin(y * factor)
            let angle = atan2(y, x) - 0.000003 * cos(x * factor)
            guard let decoded = PhotoLocation(latitude: z * sin(angle), longitude: z * cos(angle), altitude: location.altitude) else { return nil }
            gcj = decoded
        }
        switch target {
        case .gcj02: return gcj
        case .wgs84:
            // Iteratively invert the forward transform instead of doubling its first-order error.
            var result = gcj
            for _ in 0..<10 {
                let shifted = Self.wgsToGCJ(result)
                let north = shifted.latitude - gcj.latitude, east = shifted.longitude - gcj.longitude
                guard let corrected = PhotoLocation(latitude: result.latitude - north, longitude: result.longitude - east, altitude: location.altitude) else { return nil }
                result = corrected
                if max(abs(north), abs(east)) < 1e-10 { break }
            }
            return result
        case .bd09:
            let x = gcj.longitude, y = gcj.latitude, factor = Double.pi * 3000 / 180
            let z = hypot(x, y) + 0.00002 * sin(y * factor)
            let angle = atan2(y, x) + 0.000003 * cos(x * factor)
            return PhotoLocation(latitude: z * sin(angle) + 0.006, longitude: z * cos(angle) + 0.0065, altitude: location.altitude)
        }
    }

    private static func wgsToGCJ(_ location: PhotoLocation) -> PhotoLocation {
        let latitude = location.latitude, longitude = location.longitude
        // Algorithm envelope only. The launcher separately verifies mainland coverage before
        // choosing GCJ-02 as its destination; this rectangle never identifies a photo's country.
        guard (0...56).contains(latitude), (72...138).contains(longitude) else { return location }
        let x = longitude - 105, y = latitude - 35, pi = Double.pi
        let shared = (20 * sin(6 * x * pi) + 20 * sin(2 * x * pi)) * 2 / 3
        var north = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        north += shared + (20 * sin(y * pi) + 40 * sin(y / 3 * pi)) * 2 / 3
        north += (160 * sin(y / 12 * pi) + 320 * sin(y * pi / 30)) * 2 / 3
        var east = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        east += shared + (20 * sin(x * pi) + 40 * sin(x / 3 * pi)) * 2 / 3
        east += (150 * sin(x / 12 * pi) + 300 * sin(x / 30 * pi)) * 2 / 3
        let radians = latitude / 180 * pi, eccentricity = 0.00669342162296594323, axis = 6378245.0
        let magic = 1 - eccentricity * sin(radians) * sin(radians), root = sqrt(magic)
        // The bounded algorithm envelope guarantees a valid latitude and longitude here.
        return PhotoLocation(latitude: latitude + north * 180 / (axis * (1 - eccentricity) / (magic * root) * pi),
                             longitude: longitude + east * 180 / (axis / root * cos(radians) * pi), altitude: location.altitude)!
    }
}
