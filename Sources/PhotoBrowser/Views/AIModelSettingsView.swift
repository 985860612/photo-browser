import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

struct AIModelSettingsView: View {
    var defaults: UserDefaults = .standard
    @State private var configuration = AIModelConfiguration()
    @State private var apiKey = ""
    @State private var hasKey = false
    @State private var message: String?
    @State private var failure: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        Section {
            TextField(L10n.text("服务地址"), text: $configuration.baseURL,
                      prompt: Text(verbatim: "https://…/compatible-mode/v1")).disabled(testing)
            TextField(L10n.text("模型名称"), text: $configuration.model).disabled(testing)
            SecureField(L10n.text("API Key"), text: $apiKey,
                        prompt: Text(L10n.text(hasKey ? "密钥已保存，输入可更换" : "输入或从 CSV 导入"))).disabled(testing)
            Toggle(L10n.text("启用思考模式"), isOn: $configuration.enableThinking).disabled(testing)
            HStack {
                Button(L10n.text("导入百炼 CSV…")) { importCSV() }
                Button(L10n.text("保存配置")) { save() }
                if hasKey { Button(L10n.text("移除密钥")) { removeKey() } }
            }.disabled(testing)
            HStack {
                Button(L10n.text(testing ? "正在测试…" : "测试连接")) { test() }.disabled(testing)
                if testing {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("取消")) { testTask?.cancel() }
                }
            }
            if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            if let message { Text(message).foregroundStyle(.secondary) }
        } header: { Label(L10n.text("AI 模型"), systemImage: "sparkles") }
        Section {
            Text(L10n.text("默认使用 qwen3.8-flash，思考模式默认关闭；保存后生效。"))
            Text(L10n.text("生成时会将最长边不超过 720 像素的照片发送到所配置的服务。原图不修改。"))
            Text(L10n.text("API Key 仅保存在本机钥匙串，并与服务地址绑定。切换地址需配置对应密钥。"))
            Text(L10n.text("新结果先保存到本机，保留历次生成记录；失败不会覆盖已有结果。"))
        }.font(.caption).foregroundStyle(.secondary)
        .task { load() }
        .onChange(of: configuration.baseURL) { _, _ in
            apiKey = ""; message = nil
            do { hasKey = try AIModelKeychain.read(configuration) != nil }
            catch { hasKey = false; failure = error.localizedDescription }
        }
        .onDisappear { testTask?.cancel() }
    }

    private func load() {
        do {
            configuration = try AIModelConfiguration.load(defaults: defaults)
            hasKey = try AIModelKeychain.read(configuration) != nil
        } catch { failure = error.localizedDescription }
    }
    @discardableResult private func save() -> Bool {
        do {
            _ = try configuration.endpoint()
            guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowserFailure.message(L10n.text("请输入模型名称。"))
            }
            if !apiKey.isEmpty { try AIModelKeychain.save(apiKey, configuration: configuration) }
            try configuration.save(defaults: defaults)
            apiKey = ""; hasKey = try AIModelKeychain.read(configuration) != nil
            failure = nil; message = L10n.text("AI 配置已保存。")
            return true
        } catch { message = nil; failure = error.localizedDescription; return false }
    }
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try AIModelConfiguration.importCSV(String(contentsOf: url, encoding: .utf8))
            try AIModelKeychain.save(imported.apiKey, configuration: imported.configuration)
            try imported.configuration.save(defaults: defaults)
            configuration = imported.configuration; apiKey = ""; hasKey = true
            failure = nil; message = L10n.text("AI 配置已导入，思考模式已关闭。")
        } catch { message = nil; failure = error.localizedDescription }
    }
    private func removeKey() {
        do { try AIModelKeychain.remove(configuration); apiKey = ""; hasKey = false; message = nil; failure = nil }
        catch { failure = error.localizedDescription }
    }
    private func test() {
        guard save() else { return }
        let selected = configuration
        testing = true; message = nil
        testTask = Task {
            do {
                guard let key = try AIModelKeychain.read(selected) else { throw BrowserFailure.message(L10n.text("请先在设置 → AI 模型中配置服务和密钥。")) }
                try await AIModelClient.test(configuration: selected, apiKey: key)
                try Task.checkCancellation()
                message = L10n.text("AI 连接测试通过。")
            } catch is CancellationError { message = L10n.text("已取消。") }
            catch { if Task.isCancelled { message = L10n.text("已取消。") } else { failure = error.localizedDescription } }
            testing = false
        }
    }
}
