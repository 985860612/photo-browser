import SwiftUI
import BrowserCore

struct AICatalogPreview: View {
    @EnvironmentObject private var store: AIBrowseStore
    @StateObject private var presentation = PreviewPresentation()
    @State private var zoom = 1.0
    @State private var fitScale = 1.0
    @State private var hdr = true
    @State private var formatID: String?
    let fullscreen: Bool
    private var file: PhotoFile? { store.selected?.asset.imageFiles.first { $0.id == formatID } ?? store.selected?.asset.preferred }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                PhotoCanvas(photo: presentation.fileID == file?.id ? presentation.photo : nil, identity: file?.id ?? "", hdr: hdr, zoom: $zoom, fitScale: $fitScale) { presentation.failure = $0 }
                    .opacity(presentation.photo != nil ? 1 : 0)
                if presentation.photo == nil {
                    if let thumbnail = presentation.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else if let failure = presentation.failure { Text(failure).font(.caption).foregroundStyle(.orange).padding() }
                    else if file != nil { ProgressView() }
                }
            }
            HStack {
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                Text(store.selected?.title ?? L10n.text("请选择照片")).lineLimit(1)
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                Spacer()
                if let item = store.selected {
                    Menu(file?.format ?? "") {
                        ForEach(item.asset.imageFiles) { file in Button(file.format) { formatID = file.id } }
                    }.fixedSize()
                }
                Toggle("HDR", isOn: $hdr).toggleStyle(.switch)
                Button(L10n.text("适应")) { zoom = 1 }
                Button(L10n.text(fullscreen ? "退出全屏" : "返回照片墙")) { if fullscreen { store.fullscreen = false } else { store.large = false } }
            }.font(.caption).controlSize(.mini).padding(12)
        }
        .task(id: (file?.id ?? "") + String(hdr) + String(fullscreen)) {
            zoom = 1
            await presentation.load(file, hdr: hdr, maximum: fullscreen ? nil : 2800) { _ in }
        }
    }
}
