import Foundation
import SwiftUI
import BrowserCore

struct PhotoPixelSize: Equatable {
    let width: Int
    let height: Int
    let count: Int64

    init?(width: Int?, height: Int?) {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let product = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !product.overflow else { return nil }
        self.width = width; self.height = height; count = product.partialValue
    }

    init?(photo: DisplayPhoto) {
        if let original = Self(width: photo.metadata?.width, height: photo.metadata?.height) {
            // Header dimensions are unrotated. The displayed image establishes the orientation,
            // even while a smaller cached preview is used after a full-resolution load fails.
            let swapped = (original.width < original.height) != (photo.size.width < photo.size.height)
            self.init(width: swapped ? original.height : original.width, height: swapped ? original.width : original.height)
        } else {
            guard photo.size.width.isFinite, photo.size.height.isFinite,
                  photo.size.width > 0, photo.size.height > 0,
                  photo.size.width < CGFloat(Int.max), photo.size.height < CGFloat(Int.max) else { return nil }
            self.init(width: Int(photo.size.width), height: Int(photo.size.height))
        }
    }

    var resolution: String { "\(width) × \(height) px" }
    var total: String {
        if count >= 999_950_000 { return "\(number(Double(count) / 1_000_000_000)) GP" }
        if count >= 1_000_000 { return "\(number(Double(count) / 1_000_000)) MP" }
        return "\(exact) px"
    }
    var detail: String { L10n.text("\(resolution) · \(exact) 像素") }
    private var exact: String { count.formatted(.number.locale(Locale(identifier: L10n.language))) }
    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: L10n.language)))
    }
}

/// Bind source dimensions to the exact preview file, rather than shared RAW/JPEG asset metadata
/// or the 2800-pixel browsing image. Header reads reuse the inspector's metadata cache.
struct CurrentPhotoPixelCount: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var loadedFile: PhotoFile?
    @State private var pixels: PhotoPixelSize?
    @State private var failure: String?

    private var file: PhotoFile? {
        guard store.selectedFolderID == nil, store.playbackFile == nil,
              !store.isLoading, let file = store.focusedFile,
              file.kind == .raw || file.kind == .rendered else { return nil }
        return file
    }

    var body: some View {
        Group {
            if let file {
                if loadedFile == file, let pixels {
                    Text(L10n.text("当前照片：\(pixels.total)"))
                        .help(pixels.detail).accessibilityIdentifier("currentPhotoPixelCount")
                } else if loadedFile == file, let failure {
                    Text(L10n.text("当前照片：像素未知")).help(failure)
                } else {
                    Text(L10n.text("当前照片：读取像素…"))
                }
            }
        }
        .font(.caption).monospacedDigit().lineLimit(1)
        .task(id: file) {
            let requested = file
            loadedFile = requested; pixels = nil; failure = nil
            guard let requested else { return }
            do {
                let metadata = try await store.thumbnails.sourceMetadata(requested)
                try Task.checkCancellation()
                guard file == requested else { return }
                if let size = PhotoPixelSize(width: metadata?.width, height: metadata?.height) { pixels = size }
                else { failure = L10n.text("照片未提供有效的像素尺寸。") }
            } catch is CancellationError {}
            catch {
                guard !Task.isCancelled, file == requested else { return }
                failure = error.localizedDescription
            }
        }
    }
}
