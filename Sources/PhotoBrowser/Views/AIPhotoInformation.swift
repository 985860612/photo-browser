import SwiftUI
import BrowserCore

struct AIPhotoInformation: View {
    let asset: PhotoAsset
    @State private var metadata: RecognitionMetadata?
    @State private var failure: String?
    @State private var loadedRequest: String?
    @State private var loading = true
    @State private var refreshID = UUID()
    @State private var forceRefresh = false

    private var request: String { (asset.imageFiles.first?.url.deletingLastPathComponent().path ?? "") + "|" + asset.id + "|" + asset.fingerprint + "|" + refreshID.uuidString }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label(L10n.text("AI 照片信息"), systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Button { forceRefresh = true; refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .help(L10n.text("重新读取 AI 信息")).accessibilityLabel(L10n.text("重新读取 AI 信息"))
            }
            if loadedRequest != request || loading {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text(L10n.text("正在读取 AI 信息…")).font(.caption).foregroundStyle(.secondary) }
            } else if let failure {
                Label(L10n.text("AI 信息读取失败"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                Text(failure).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            } else if let metadata {
                if let failure = metadata.failure {
                    Text(L10n.text("此照片识别失败。")).font(.caption).foregroundStyle(.orange)
                    Text(failure).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    if !metadata.title.isEmpty { Text(metadata.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if !metadata.description.isEmpty { Text(metadata.description).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    ForEach(metadata.sections) { section in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(L10n.lookup(section.name)).font(.system(size: 11)).foregroundStyle(.secondary)
                            if section.tags.isEmpty { Text("—").font(.caption).foregroundStyle(.tertiary) }
                            else {
                                RecognitionTagLayout(spacing: 5) {
                                    ForEach(section.tags) { tag in
                                        Text(tag.name).font(.system(size: 11)).textSelection(.enabled)
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.08), lineWidth: 1))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .help(tag.name)
                                    }
                                }
                            }
                        }
                    }
                    Text(L10n.text("AI 生成结果，尚未经人工复核。")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            } else {
                Text(L10n.text("暂无 AI 识别结果")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: request) {
            let identity = request
            let refresh = forceRefresh; forceRefresh = false
            loading = true; metadata = nil; failure = nil
            do {
                let result = try await RecognitionReader.shared.read(asset, refresh: refresh)
                try Task.checkCancellation()
                guard request == identity else { return }
                metadata = result
            } catch is CancellationError { return }
            catch { guard request == identity else { return }; failure = error.localizedDescription }
            guard request == identity else { return }
            loadedRequest = identity; loading = false
        }

    }
}

/// Chips wrap at the inspector width; an unusually long model label wraps inside its own chip.
private struct RecognitionTagLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 260, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  proposal: ProposedViewSize(width: result.widths[index], height: nil))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint], widths: [CGFloat]) {
        let width = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = [], widths: [CGFloat] = []
        for view in subviews {
            let natural = view.sizeThatFits(.unspecified)
            let chipWidth = min(width, natural.width)
            let size = view.sizeThatFits(ProposedViewSize(width: chipWidth, height: nil))
            if x > 0 && x + chipWidth > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); widths.append(chipWidth)
            x += chipWidth + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points, widths)
    }
}
