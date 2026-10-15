import Foundation
import ImageIO

public enum PhotoMediaSource {
    public static func open(_ file: PhotoFile, check: () throws -> Void = {}) throws -> CGImageSource? {
        try check()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if file.isLivePhoto {
            let data = try LivePhotoCache.shared.photoData(file, check: check)
            return CGImageSourceCreateWithData(data as CFData, options)
        }
        return try NetworkPhotoReader.open(file, check: check)
    }
}
