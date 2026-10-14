import AppKit
import BrowserCore

extension BrowserStore {
    func sortingChanged() {
        preferencesDefaults.set(previewSortField.rawValue, forKey: "previewSortField")
        preferencesDefaults.set(previewSortDescending, forKey: "previewSortDescending")
        visibleOrdering = nil; sortingRevision = UUID()
        selectionAnchorID = focusedID; rangeSelectionBase = nil
        ensureCaptureSortDates()
    }
    func cancelSortDates() { captureDates.cancel() }

    func ensureCaptureSortDates() {
        guard previewSortField == .captured, !isLoading, !isMoving else { cancelSortDates(); return }
        captureDates.load(visibleAssets, scope: "\(scope)|\(search)") { [weak self] result in
            guard let self else { return }
            for index in self.assets.indices {
                let asset = self.assets[index]
                guard result.fingerprints[asset.id] == asset.fingerprint else { continue }
                if asset.metadata?.captured == nil, let date = result.dates[asset.id] {
                    if self.assets[index].metadata == nil { self.assets[index].metadata = PhotoMetadata(captured: date) }
                    else { self.assets[index].metadata?.captured = date }
                }
            }
            self.visibleOrdering = nil; self.sortingRevision = UUID()
            if self.directory != nil { do { try self.saveSession() } catch { self.report(error) } }
            self.ensureCaptureSortDates()
        }
    }
}
