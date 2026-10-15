import AppKit
import Vision
import CoreImage
import BrowserCore

/// One bounded utility worker. Vision sees the same oriented SDR preview regardless of viewer settings.
public final class VisionPhotoAnalyzer: @unchecked Sendable {
    private let thumbnails: ThumbnailCache
    private let workers = PreviewWorkQueue(backgroundConcurrency: 1)
    private let normalization = CIContext(options: [.cacheIntermediates: false])
    public static var supportsAesthetics: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
    public init(thumbnails: ThumbnailCache = .shared) { self.thumbnails = thumbnails }
    public func analyze(_ asset: PhotoAsset, options: AnalysisOptions) async throws -> PhotoAnalysis {
        guard !asset.isVideo else { throw BrowserFailure.message(L10n.text("选片分析暂不支持视频。")) }
        let preview = try await thumbnails.image(asset.preferred, maximum: 1280, background: true)
        return try await workers.run(background: true) { [normalization] check in
            try check()
            var rect = CGRect(origin: .zero, size: preview.image.size)
            guard let image = preview.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw BrowserFailure.message(L10n.text("无法读取用于选片分析的图像。"))
            }
            let source = CIImage(cgImage: image, options: [.toneMapHDRtoSDR: true])
            guard let normalized = normalization.createCGImage(source, from: source.extent, format: .RGBA8,
                                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
                throw BrowserFailure.message(L10n.text("无法读取用于选片分析的图像。"))
            }
            var result = try Self.analyze(normalized, asset: asset, options: options, check: check)
            result.captured = asset.metadata?.captured ?? preview.metadata?.captured
            return result
        }
    }
    public static func analyze(_ image: CGImage, asset: PhotoAsset, options: AnalysisOptions,
                               check: () throws -> Void = {}) throws -> PhotoAnalysis {
        var result = PhotoAnalysis(assetID: asset.id, fingerprint: asset.fingerprint, signature: options.signature)
        result.captured = asset.metadata?.captured
        func perform(_ request: VNRequest) throws {
            try check()
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            try check()
        }
        if options.similarity {
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = VNGenerateImageFeaturePrintRequestRevision2
            request.imageCropAndScaleOption = .scaleFit
            try perform(request)
            guard let observation = request.results?.first else { throw BrowserFailure.message(L10n.text("照片分析未返回结果，请重试。")) }
            result.featurePrint = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        }
        if options.aesthetics, #available(macOS 15, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            request.revision = VNCalculateImageAestheticsScoresRequestRevision1
            try perform(request)
            guard let observation = request.results?.first else { throw BrowserFailure.message(L10n.text("照片分析未返回结果，请重试。")) }
            result.aesthetics = observation.overallScore
            result.isUtility = observation.isUtility
        }
        if options.faces {
            let request = VNDetectFaceCaptureQualityRequest()
            request.revision = VNDetectFaceCaptureQualityRequestRevision3
            try perform(request)
            result.faces = (request.results ?? []).map {
                AnalysisRegion(x: $0.boundingBox.minX, y: $0.boundingBox.minY, width: $0.boundingBox.width,
                               height: $0.boundingBox.height, quality: $0.faceCaptureQuality)
            }
        }
        if options.classification {
            let request = VNClassifyImageRequest()
            request.revision = VNClassifyImageRequestRevision2
            try perform(request)
            result.labels = (request.results ?? []).filter { $0.confidence >= 0.2 }.prefix(5).map {
                AnalysisLabel(identifier: $0.identifier, confidence: $0.confidence)
            }
        }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        saliency.revision = VNGenerateAttentionBasedSaliencyImageRequestRevision2
        try perform(saliency)
        result.subjects = (saliency.results?.first?.salientObjects ?? []).map {
            AnalysisRegion(x: $0.boundingBox.minX, y: $0.boundingBox.minY, width: $0.boundingBox.width, height: $0.boundingBox.height)
        }
        return result
    }
    public static func feature(_ data: Data) throws -> VNFeaturePrintObservation {
        guard let feature = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else {
            throw BrowserFailure.message(L10n.text("相似度缓存不可用，请重新分析。"))
        }
        return feature
    }
    public static func distance(_ lhs: VNFeaturePrintObservation, _ rhs: VNFeaturePrintObservation) throws -> Float {
        var distance: Float = 0
        try lhs.computeDistance(&distance, to: rhs)
        return distance
    }
}
