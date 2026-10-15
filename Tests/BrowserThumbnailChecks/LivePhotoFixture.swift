import AppKit
import ImageIO
import BrowserCore

enum LivePhotoFixture {
    static func create(at archive: URL, compressed: Bool = false, movie: Bool = true) async throws {
        let fm = FileManager.default, folder = archive.deletingLastPathComponent().appendingPathComponent("members-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("IMG_[1].HEIC.heic")
        let cg = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 480,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let output = CGImageDestinationCreateWithURL(photo as CFURL, "public.heic" as CFString, 1, nil)!
        CGImageDestinationAddImage(output, cg, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "Live Photo Fixture"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Fixture Lens", kCGImagePropertyExifDateTimeOriginal: "2020:01:02 12:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.25, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 34.5, kCGImagePropertyGPSLongitudeRef: "W"]] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw BrowserFailure.message("Cannot create Live Photo fixture") }
        var paths = [photo.path]
        if movie {
            let motion = folder.appendingPathComponent("IMG_[1].HEIC.mov")
            try await VideoFixture.create(at: motion); paths.append(motion.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-j", compressed ? "-9" : "-0", archive.path] + paths
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BrowserFailure.message("Cannot create LIVP archive") }
    }
}
