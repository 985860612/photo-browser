import AppKit
import SwiftUI
import BrowserCore

struct ArchiveSheet: View {
    let group: PhotoGroup
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var parent: URL?
    @State private var folderName: String

    init(group: PhotoGroup) {
        self.group = group
        let name = group.name.components(separatedBy: CharacterSet(charactersIn: "/:\0\n")).filter { !$0.isEmpty }.joined(separator: "_")
        _folderName = State(initialValue: name == "." || name == ".." || name.isEmpty ? L10n.text("全景_") + (group.assetIDs.first ?? L10n.text("组")).uppercased() : name)
    }

    private var destination: URL? {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), let root = parent ?? store.directory else { return nil }
        return root.appendingPathComponent(name, isDirectory: true)
    }
    private func makePlan() throws -> ArchivePlan {
        guard let source = store.directory, let destination else { throw BrowserFailure.message(L10n.text("请填写有效的文件夹名称。")) }
        return try ArchivePlan(directory: source, destination: destination, group: group, assets: store.assets)
    }

    var body: some View {
        let plan = try? makePlan()
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "folder.badge.checkmark").font(.title).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("移动整组到新文件夹")).font(.title2)
                    Text(L10n.text("\(group.name) · \(group.assetIDs.count) 张照片")).foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("请核对整组素材和文件名单。移动会包含所有同名 RAW、HIF/JPG 及 XMP，并可通过移动记录撤销。"))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(L10n.text("存放位置")).frame(width: 72, alignment: .leading)
                Text((parent ?? store.directory)?.path ?? "").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(L10n.text("选择…")) { chooseParent() }
            }
            HStack {
                Text(L10n.text("新文件夹")).frame(width: 72, alignment: .leading)
                TextField(L10n.text("文件夹名称"), text: $folderName).textFieldStyle(.roundedBorder)
            }
            Text(destination?.path ?? L10n.text("文件夹名称无效")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            if let plan {
                HStack {
                    Text(L10n.text("将移动 \(plan.fileCount) 个文件")).font(.headline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(plan.record.entries, id: \.source) { entry in
                            HStack {
                                Text(entry.source.lastPathComponent).font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(10)
                }.frame(height: 190).background(Color.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 7))
            } else { Text(L10n.text("请检查文件夹名称和当前分组。")) .foregroundStyle(.orange) }
            HStack {
                Text(L10n.text("目标文件夹必须为新目录，不会覆盖已有文件。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("确认移动 \(plan?.fileCount ?? 0) 个文件")) {
                    do { store.archive(try makePlan()); dismiss() } catch { store.report(error) }
                }.buttonStyle(.borderedProminent).disabled(plan == nil || !store.canArchive)
            }
        }.padding(26).frame(width: 710)
    }

    private func chooseParent() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = parent ?? store.directory; panel.prompt = L10n.text("选择存放位置")
        if panel.runModal() == .OK { parent = panel.url }
    }
}

struct RenameGroupSheet: View {
    let group: PhotoGroup
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool
    init(group: PhotoGroup) { self.group = group; _name = State(initialValue: group.name) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("重命名分组")).font(.title2)
            TextField(L10n.text("分组名称"), text: $name).textFieldStyle(.roundedBorder).focused($focused)
            Text(L10n.text("分组名称会保存，并用于移动整组时的默认文件夹名。原照片文件名不变。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) { store.rename(group, to: name) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(25).frame(width: 430).onAppear { focused = true }
    }
}

struct MergeSheet: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("合并分组")).font(.title2)
            Text(L10n.text("当前组：\(store.currentGroup?.name ?? "")"))
            Picker(L10n.text("合并到"), selection: $target) {
                Text(L10n.text("选择另一个组")).tag("")
                ForEach(store.groups.filter { $0.id != store.scope }) { group in
                    Text(L10n.text("\(group.name) · \(group.assetIDs.count) 张")).tag(group.id)
                }
            }
            Text(L10n.text("合并只调整分组，不移动原文件。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer(); Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("合并")) { store.mergeGroup(into: target); dismiss() }.buttonStyle(.borderedProminent).disabled(target.isEmpty)
            }
        }.padding(28).frame(width: 470)
    }
}

struct HistorySheet: View {
    @EnvironmentObject private var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirming: ArchiveRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(L10n.text("移动记录与撤销")).font(.title2)
                Spacer(); Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if store.history.isEmpty {
                ContentUnavailableView(L10n.text("还没有移动记录"), systemImage: "clock.arrow.circlepath")
            } else {
                List(store.history) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(record.group.name).font(.headline)
                            Spacer()
                            Text(stateName(record.state)).font(.caption).foregroundStyle(record.state == "complete" ? Color.cyan : Color.secondary)
                        }
                        Text(L10n.text("\(record.created.formatted(date: .numeric, time: .standard)) · \(record.group.assetIDs.count) 张照片 · \(record.entries.count) 个文件"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(record.destination.path).font(.caption).lineLimit(2).textSelection(.enabled)
                        if let message = record.message { Text(message).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button(L10n.text("查看目标目录")) { NSWorkspace.shared.open(record.destination) }
                            if ["complete", "prepared", "moving", "undoing", "recoveryNeeded"].contains(record.state) {
                                Button(record.state == "complete" ? L10n.text("撤销移动…") : L10n.text("恢复原位置…")) { confirming = record }.disabled(store.isMoving)
                            }
                        }.font(.caption)
                    }.padding(.vertical, 10)
                }
            }
            Text(L10n.text("撤销会移回记录中的原目录；遇到同名文件或文件已改变时停止，不会覆盖。")).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 780, height: 540)
        .confirmationDialog(L10n.text("确认将这一组移回原目录？"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let record = confirming {
                Button(L10n.text("移回 \(record.entries.count) 个文件")) { store.undo(record); confirming = nil }
                Button(L10n.text("取消"), role: .cancel) { confirming = nil }
            }
        } message: { Text(confirming?.sourceDirectory.path ?? "") }
    }

    private func stateName(_ state: String) -> String {
        switch state {
        case "complete": return L10n.text("已移动")
        case "undone": return L10n.text("已撤销")
        case "rolledBack": return L10n.text("失败后已回滚")
        case "prepared": return L10n.text("待恢复：移动准备中")
        case "moving": return L10n.text("待恢复：移动中断")
        case "undoing": return L10n.text("待恢复：撤销中断")
        default: return L10n.text("需要恢复")
        }
    }
}
