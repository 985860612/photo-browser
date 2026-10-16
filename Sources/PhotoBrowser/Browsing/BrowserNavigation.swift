import AppKit
import BrowserCore

extension BrowserStore {
    var canGoBack: Bool { navigationIndex > 0 && !isLoading && !isMoving && !isEjectingDiskImage }
    var canGoForward: Bool { navigationIndex + 1 < navigationHistory.count && !isLoading && !isMoving && !isEjectingDiskImage }
    var breadcrumbs: [URL] {
        guard var url = directory else { return [] }
        if let image = activeDiskImage {
            var inside: [URL] = []
            while url.standardizedFileURL != image.root.standardizedFileURL {
                inside.insert(url, at: 0); url.deleteLastPathComponent()
            }
            return Self.pathBreadcrumbs(image.source) + inside
        }
        return Self.pathBreadcrumbs(url)
    }
    private static func pathBreadcrumbs(_ input: URL) -> [URL] {
        var url = input
        var components = [url]
        while url.path != "/" { url.deleteLastPathComponent(); components.insert(url, at: 0) }
        return components
    }
    func navigateHistory(_ delta: Int) {
        guard delta < 0 ? canGoBack : canGoForward else { return }
        navigationIndex += delta; load(navigationHistory[navigationIndex], recordNavigation: false)
    }
    func editPath() { pathText = directory?.path ?? ""; editingPath = true }
    func openTypedPath() {
        let path = (pathText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { report(BrowserFailure.message(L10n.text("请输入绝对路径，例如 /Volumes/照片库，或 ~/Pictures。"))); return }
        load(URL(fileURLWithPath: path))
    }
}
