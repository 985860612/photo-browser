import Foundation
import ImageIO

public enum ImageMetadataReader {
    public static func read(_ source: CGImageSource) -> PhotoMetadata? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var value = PhotoMetadata()
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        let canon = props[kCGImagePropertyMakerCanonDictionary as String] as? [String: Any]
        let ciff = props[kCGImagePropertyCIFFDictionary as String] as? [String: Any]
        value.lensModel = [exif[kCGImagePropertyExifLensModel as String], aux?[kCGImagePropertyExifAuxLensModel as String],
                           canon?[kCGImagePropertyMakerCanonLensModel as String], ciff?[kCGImagePropertyCIFFLensModel as String]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        value.focalLength = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        value.aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        value.iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue
        if let seconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue {
            value.shutter = seconds < 1 && seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : String(format: "%.2f", seconds)
        }
        value.width = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        value.height = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        value.camera = tiff?[kCGImagePropertyTIFFModel as String] as? String
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        if let location = PhotoLocation(exifLatitude: (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
                                        latitudeRef: gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
                                        exifLongitude: (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue,
                                        longitudeRef: gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
                                        altitude: (gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue,
                                        belowSeaLevel: (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue == 1) {
            value.gpsLatitude = location.latitude; value.gpsLongitude = location.longitude; value.gpsAltitude = location.altitude
        }
        if let captured = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            value.captured = formatter.date(from: captured)
        }
        return value
    }
}
