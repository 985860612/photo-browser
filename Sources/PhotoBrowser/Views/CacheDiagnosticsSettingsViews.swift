import BrowserCore
import SwiftUI

struct CacheSettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @State private var confirmClear = false

    var body: some View {
        Section {
            if let usage = store.diskUsage {
                LabeledContent(L10n.text("磁盘占用"), value: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
                LabeledContent(L10n.text("缓存图片"), value: String(usage.entries))
            }
            Stepper(value: $store.diskLimitGB, in: 1...20) {
                HStack { Text(L10n.text("容量上限")); Spacer(); Text("\(store.diskLimitGB) GB").monospacedDigit() }
            }.disabled(store.cacheBusy)
            if let usage = store.livePhotoDiskUsage {
                LabeledContent(L10n.text("实况原图与视频缓存"), value: ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file))
            }
            HStack {
                Button(L10n.text("清理预览缓存…")) { confirmClear = true }.disabled(store.cacheBusy)
                if store.cacheBusy { ProgressView().controlSize(.small) }
            }
            if let failure = store.cacheFailure { Text(failure).foregroundStyle(.orange).font(.caption) }
        } header: { Label(L10n.text("缓存空间"), systemImage: "internaldrive") }
        footer: { Text(L10n.text("仅清理本机预览缓存，保留原文件、分组、移动记录和播放位置。")) }
        .confirmationDialog(L10n.text("清理本机预览缓存？"), isPresented: $confirmClear) {
            Button(L10n.text("清理缓存"), role: .destructive) { Task { await store.clearPreviewCaches() } }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("清理后按需重新生成缩略图，当前画面和视频播放不受影响。")) }
        Section {
            DisclosureGroup(L10n.text("了解更多")) {
                Text(L10n.text("缩略图与视频封面按最近访问清理。"))
                Text(L10n.text("实况缓存上限 1 GB，视频仅在播放时解包。清理时保留正在使用的视频。"))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PreviewDiagnosticsSettingsView: View {
    @EnvironmentObject private var store: BrowserStore

    var body: some View {
        Section {
            LabeledContent(L10n.text("相邻大图就绪"), value: "\(store.adjacentReady)/\(store.adjacentTotal)")
            LabeledContent(L10n.text("相邻视频信息就绪"), value: "\(store.adjacentVideoReady)/\(store.adjacentVideoTotal)")
            if let stats = store.previewStatistics {
                LabeledContent(L10n.text("大图内存占用"), value: ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .memory))
            }
            LabeledContent(L10n.text("缓存命中 / 请求"), value: "\(store.diagnostics.hits)/\(store.diagnostics.requests)")
        } header: { Label(L10n.text("预览诊断"), systemImage: "chart.bar") }
        if let sample = store.diagnostics.samples.last(where: { $0.cached != nil || $0.failed }) {
            Section {
                Text(URL(fileURLWithPath: sample.path).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle).font(.caption).help(sample.path)
                if sample.failed { Text(L10n.text("预览加载失败")).foregroundStyle(.orange) }
                else {
                    LabeledContent(L10n.text("来源"), value: sample.cached == true ? L10n.text("内存缓存") : L10n.text("原图解码"))
                    HStack {
                        timingColumn("排队", sample.timing?.queue)
                        timingColumn("读取", sample.timing?.source)
                        timingColumn("解码", sample.timing?.decode)
                        timingColumn("绘制", sample.render)
                    }
                }
            } header: { Text(L10n.text("最近一次预览")) }
        }
        Section {
            Button(L10n.text("重置诊断统计")) {
                PreviewDiagnostics.shared.reset(); store.diagnostics = PreviewDiagnostics.shared.snapshot()
            }
            DisclosureGroup(L10n.text("统计说明")) {
                Text(L10n.text("读取为打开图像源的耗时；解码包含后续文件读取。绘制包含提交至 GPU 完成。统计保留本次运行最近 100 次请求。"))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func timingColumn(_ key: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.lookup(key)).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f ms", $0) } ?? "—").monospacedDigit()
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}
