import AVFoundation
import AppKit

/// Separate lanes keep video cover decoding bounded without occupying photo decode workers.
public enum VideoMedia {
    private static let foreground = VideoCoverGate(capacity: 2)
    private static let background = VideoCoverGate(capacity: 1)

    public static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds.rounded(.down), Double(Int32.max)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    public static func preview(_ file: PhotoFile, maximum: Int, background isBackground: Bool = false) async throws -> LoadedPreview {
        try await (isBackground ? background : foreground).run {
            let asset = AVURLAsset(url: file.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximum, height: maximum)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard try await asset.load(.isPlayable), let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw BrowserFailure.message(L10n.text("系统无法播放此视频：\(file.url.lastPathComponent)"))
                }
                let duration = CMTimeGetSeconds(try await asset.load(.duration))
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let frameRate = try await track.load(.nominalFrameRate)
                let bounds = CGRect(origin: .zero, size: size).applying(transform)
                var metadata = PhotoMetadata()
                metadata.width = Int(abs(bounds.width).rounded()); metadata.height = Int(abs(bounds.height).rounded())
                metadata.duration = duration.isFinite && duration >= 0 ? duration : nil
                metadata.frameRate = frameRate.isFinite && frameRate > 0 ? frameRate : nil
                let sample = CMTime(seconds: duration.isFinite && duration > 2 ? 1 : 0, preferredTimescale: 600)
                let result = try await generator.image(at: sample)
                try Task.checkCancellation()
                return LoadedPreview(image: NSImage(cgImage: result.image, size: CGSize(width: result.image.width, height: result.image.height)), metadata: metadata)
            } onCancel: { generator.cancelAllCGImageGeneration(); asset.cancelLoading() }
        }
    }
}

private actor VideoCoverGate {
    private let capacity: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(capacity: Int) { self.capacity = capacity }

    func run<Value>(_ work: () async throws -> Value) async throws -> Value {
        let ticket = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < capacity { active += 1; return }
            try await withCheckedThrowingContinuation { waiting.append((ticket, $0)) }
        } onCancel: { Task { await self.cancel(ticket) } }
        defer {
            if waiting.isEmpty { active -= 1 }
            else { waiting.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        return try await work()
    }
    private func cancel(_ ticket: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == ticket }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
}
