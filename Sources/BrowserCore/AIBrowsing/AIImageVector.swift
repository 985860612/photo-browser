import AppKit
import Accelerate
import ImageIO
import Vision

/// Pinned model, request revision, preprocessing and storage type are one vector space.
struct AIImageVector: Sendable {
    static let model = "apple-vision-featureprint-r2-scaleFill-f32-v1"
    static let dimensions = 768
    let values: [Float]
    var data: Data { values.withUnsafeBytes { Data($0) } }

    init(data: Data) throws {
        guard data.count == Self.dimensions * MemoryLayout<Float>.size else { throw Self.invalid() }
        var floats = [Float](repeating: 0, count: Self.dimensions)
        _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        guard floats.allSatisfy(\.isFinite), vDSP.sumOfSquares(floats) > 0 else { throw Self.invalid() }
        values = floats
    }
    func distance(to other: Self) -> Float {
        var squared: Float = 0
        vDSP_distancesq(values, 1, other.values, 1, &squared, vDSP_Length(values.count))
        return sqrt(max(0, squared))
    }
    static func invalid() -> Error { BrowserFailure.message(L10n.text("图片向量无效，请重新建立相似图片索引。")) }
    static func generate(_ item: AICatalogItem) async throws -> Self {
        // Batch previews are local and already oriented. Keep original decoding on the bounded thumbnail queue.
        if let preview = item.preview {
            let local: Self? = try await AICatalogRepository.background {
                guard FileManager.default.fileExists(atPath: preview.path) else { return nil }
                return try generate(imageAt: preview)
            }
            if let local { return local }
        }
        let thumbnail = try await ThumbnailCache.shared.image(item.asset.preferred, maximum: 720, background: true)
        return try await AICatalogRepository.background {
            let jpeg = try PhotoRecognitionGenerator.jpeg(thumbnail.image)
            guard let source = CGImageSourceCreateWithData(jpeg.data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw invalid() }
            return try generate(image: image)
        }
    }
    static func generate(imageAt url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
              ] as CFDictionary) else { throw BrowserFailure.message(L10n.text("无法读取图片：\(url.lastPathComponent)")) }
        return try generate(image: image)
    }
    static func generate(image: CGImage) throws -> Self {
        try Task.checkCancellation()
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        guard let result = request.results?.first, result.elementType == .float,
              result.elementCount == dimensions else { throw invalid() }
        return try Self(data: result.data)
    }
}
