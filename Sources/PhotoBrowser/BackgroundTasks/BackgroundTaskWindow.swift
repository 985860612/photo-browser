import SwiftUI
import AppKit
import BrowserCore

struct BackgroundTaskWindow: View {
    @ObservedObject var store: BackgroundTaskStore
    @State private var page = 0
    @State private var creating = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("后台任务"), systemImage: "list.bullet.clipboard").font(.headline)
                Picker(L10n.text("查看内容"), selection: $page) {
                    Text(L10n.text("任务")).tag(0); Text(L10n.text("识别结果")).tag(1)
                }.pickerStyle(.segmented).frame(width: 200)
                Spacer()
                Text(L10n.text("AI 并发")); Stepper("\(store.aiConcurrency)", value: $store.aiConcurrency, in: 1...32).fixedSize()
                Text(L10n.text("向量并发")); Stepper("\(store.vectorConcurrency)", value: $store.vectorConcurrency, in: 1...4).fixedSize()
                Button(L10n.text("新建任务"), systemImage: "plus") { creating = true }
            }.padding(14)
            Divider()
            if page == 0 {
                HStack(spacing: 0) {
                    List(selection: $store.selectedTask) {
                        ForEach(store.tasks) { task in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(task.root.lastPathComponent).font(.headline).lineLimit(1)
                                Text(task.state.title).foregroundStyle(task.failed > 0 ? .orange : .secondary)
                                Text(L10n.text("完成 \(task.done)/\(task.total) 张")).font(.caption).monospacedDigit()
                                Text(task.created, style: .time).font(.caption2).foregroundStyle(.tertiary)
                            }.padding(.vertical, 6).tag(task.id)
                        }
                    }.frame(width: 245)
                    Divider()
                    if let task = store.tasks.first(where: { $0.id == store.selectedTask }) {
                        VStack(spacing: 0) {
                            taskHeader(task)
                            Divider()
                            BackgroundResultBrowser(root: task.root, taskID: task.id, store: store).id(task.id)
                        }.frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView { Label(L10n.text("选择或新建任务"), systemImage: "list.bullet.clipboard") }
                        description: { Text(L10n.text("切换页面不会停止任务，退出应用后可手动续跑。")) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(store.root.path).lineLimit(1).truncationMode(.middle)
                        Spacer(); Button(L10n.text("选择目录…")) { chooseRoot() }
                    }.font(.caption).padding(12)
                    Divider()
                    BackgroundResultBrowser(root: store.root, taskID: nil, store: store).id(store.root)
                }
            }
            if let error = store.error {
                Divider()
                HStack { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled); Spacer(); Button(L10n.text("关闭")) { store.error = nil } }.font(.caption).padding(12)
            }
        }
        .frame(minWidth: 1050, minHeight: 660)
        .background(GlassBackdrop().ignoresSafeArea()).controlSize(.small)
        .sheet(isPresented: $creating) { BackgroundNewTaskView(store: store) }
        .onChange(of: store.aiConcurrency) { _, _ in store.configureConcurrency() }
        .onChange(of: store.vectorConcurrency) { _, _ in store.configureConcurrency() }
        .onAppear { store.start() }
    }
    private func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.directoryURL = store.root
        if panel.runModal() == .OK, let url = panel.url { store.root = url }
    }
    private func taskHeader(_ task: BackgroundTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(task.state.title).font(.headline)
                Spacer()
                if [.running, .queued].contains(task.state) { Button(L10n.text("暂停"), systemImage: "pause") { store.pause(task.id) } }
                if [.paused, .cancelled].contains(task.state) { Button(L10n.text("继续"), systemImage: "play") { store.resume(task.id, retry: task.state == .cancelled) } }
                if task.failed > 0 { Button(L10n.text("重试失败"), systemImage: "arrow.clockwise") { store.resume(task.id, retry: true) } }
                if [.running, .queued, .paused, .pausing].contains(task.state) { Button(L10n.text("取消任务"), systemImage: "xmark") { store.cancel(task.id) } }
            }
            Text(task.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text((task.ai ? L10n.text("AI 识别") + " · " + task.model : "") + (task.ai && task.vector ? "  /  " : "") + (task.vector ? L10n.text("图片向量") : "")).font(.caption)
            ProgressView(value: Double(task.done), total: Double(max(1, task.total)))
            HStack {
                if task.ai { Text(L10n.text("AI 完成 \(task.aiDone) 张 · 失败 \(task.aiFailed) 张")) }
                if task.vector { Text(L10n.text("向量完成 \(task.vectorDone) 张 · 失败 \(task.vectorFailed) 张")) }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(L10n.text("完成 \(task.done)/\(task.total) 张 · 复用 \(task.reused) 张 · 失败 \(task.failed) 张")).monospacedDigit()
                Spacer()
                if task.state == .running {
                    Text(L10n.text("\(String(format: "%.1f", task.rate)) 张/秒")).monospacedDigit()
                    if let remaining = task.remainingSeconds { Text(L10n.text("预计剩余 \(Int(ceil(remaining / 60))) 分钟")) }
                }
            }.font(.caption).foregroundStyle(.secondary)
            if let issue = task.issue { Text(issue).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(14)
    }
}
