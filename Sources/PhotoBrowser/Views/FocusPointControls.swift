import SwiftUI
import BrowserCore

struct FocusPointToggle: View {
    @Binding var enabled: Bool
    var body: some View {
        Toggle(L10n.text("显示对焦点"), isOn: $enabled).toggleStyle(.switch)
            .help(L10n.text("显示相机记录的对焦区域；红色为已合焦，黄色为已选择，青色为记录位置。"))
            .accessibilityIdentifier("focusPointsToggle")
    }
}

struct FocusPointStatus: View {
    @ObservedObject var focus: FocusPointPresentation
    let file: PhotoFile?

    var body: some View {
        HStack(spacing: 6) {
            if focus.file != file || focus.loading {
                ProgressView().controlSize(.mini)
                Text(L10n.text("读取对焦点…"))
            } else if let failure = focus.failure {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(failure).lineLimit(2)
            } else if let metadata = focus.metadata {
                switch metadata.availability {
                case .available:
                    if metadata.regions.contains(where: { $0.kind == .inFocus }) { legend("已合焦", color: .red) }
                    if metadata.regions.contains(where: { $0.kind == .selected }) { legend("已选择", color: .yellow) }
                    if metadata.regions.contains(where: { $0.kind == .recorded }) { legend("记录位置", color: .cyan) }
                case .manualFocus: Text(L10n.text("手动对焦 · 无自动对焦点"))
                case .notRecorded: Text(L10n.text("未记录有效对焦点"))
                case .unsupported: Text(L10n.text("暂不支持此照片的对焦点"))
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        .padding(10).allowsHitTesting(false)
        .help(L10n.text("显示的是拍摄时记录的对焦区域，不代表该区域一定清晰。"))
    }

    private func legend(_ key: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "viewfinder").foregroundStyle(color)
            Text(L10n.lookup(key))
        }
    }
}
