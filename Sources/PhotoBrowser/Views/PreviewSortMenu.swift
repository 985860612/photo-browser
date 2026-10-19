import AppKit
import SwiftUI
import BrowserCore

struct PreviewSortMenu: View {
    @EnvironmentObject private var store: BrowserStore
    var body: some View {
        HStack(spacing: 4) {
            if store.isReadingSortDates { ProgressView().controlSize(.mini) }
            PhotoSortMenu(field: $store.previewSortField, descending: $store.previewSortDescending)
                .disabled(store.isLoading || store.isMoving || store.visibleAssets.count < 2)
        }.font(.system(size: 12)).controlSize(.small)
            .help(L10n.text("排序：\(store.previewSortField.title) · \(store.previewSortDescending ? L10n.text("降序") : L10n.text("升序"))")
                  + "\n" + L10n.text("拍摄时间缺失时使用修改时间；文件大小为同次拍摄全部配套文件的合计大小。"))
            .task(id: "\(store.directory?.path ?? "")|\(store.scope)|\(store.search)|\(store.previewContentRevision)|\(store.assets.count)|\(store.previewSortField.rawValue)") {
                store.ensureCaptureSortDates()
            }
    }
}

/// Shared menu presentation; each browser supplies its supported ordering fields.
struct PhotoSortMenu: View {
    @Binding var field: PreviewSortField
    @Binding var descending: Bool
    var fields: [PreviewSortField] = PreviewSortField.allCases

    var body: some View {
        Menu {
            Picker(L10n.text("排序方式"), selection: $field) {
                ForEach(fields, id: \.self) { field in Text(field.title).tag(field) }
            }.pickerStyle(.inline)
            Divider()
            Picker(L10n.text("排列顺序"), selection: $descending) {
                Text(L10n.text("升序")).tag(false)
                Text(L10n.text("降序")).tag(true)
            }.pickerStyle(.inline)
        } label: { Label(L10n.text("排序"), systemImage: "arrow.up.arrow.down") }
        .menuStyle(.borderlessButton).fixedSize()
        .font(.system(size: 12)).controlSize(.small).tint(.blue)
    }
}
