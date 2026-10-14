import AppKit
import BrowserCore

extension BrowserStore {
    func observeFocusedFiles() { directoryObserver?.watchFiles(focusedAsset?.files ?? []) }
    func startDirectoryObservation() {
        guard let directory else { return }
        let revision = observationRevision
        observationStartTask = Task { [weak self] in
            do {
                let observer = try await DirectoryObserver(directory: directory, changed: { [weak self] full in
                    self?.scheduleAutomaticRefresh(full: full)
                }, failure: { [weak self] error in self?.reportObservationFailure(error) })
                guard let self, self.observationRevision == revision, self.directory == directory, !Task.isCancelled else { observer.stop(); return }
                self.directoryObserver = observer; self.observeFocusedFiles(); self.scheduleAutomaticRefresh(full: true)
            } catch is CancellationError {}
            catch { if self?.observationRevision == revision { self?.reportObservationFailure(error) } }
        }
    }
    func stopDirectoryObservation() {
        directoryObserver?.stop(); directoryObserver = nil
        observationStartTask?.cancel(); observationStartTask = nil
        automaticRefreshTask?.cancel(); automaticRefreshTask = nil
        observationRevision = UUID(); observedFolderDates = [:]
        refreshRequested = false; refreshFullRequested = false
    }
    func reportObservationFailure(_ error: Error) {
        status = L10n.text("目录变化检测失败：\(error.localizedDescription)")
        report(BrowserFailure.message(status))
    }
    func scheduleAutomaticRefresh(full: Bool) {
        guard directoryObserver != nil else { return }
        refreshRequested = true; refreshFullRequested = refreshFullRequested || full
        guard automaticRefreshTask == nil, !isMoving, !isLoading, !isReadingMetadata else { return }
        let revision = observationRevision
        automaticRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self else { return }
            defer { if revision == self.observationRevision { self.automaticRefreshTask = nil } }
            while self.refreshRequested, revision == self.observationRevision, !Task.isCancelled {
                guard let directory = self.directory, !self.isMoving, !self.isLoading, !self.isReadingMetadata else { return }
                let full = self.refreshFullRequested, dates = self.observedFolderDates
                let focused = self.focusedAsset?.files ?? []
                self.refreshRequested = false; self.refreshFullRequested = false
                do {
                    let snapshot = try await self.observationWorkers.run(background: true) { check -> DirectorySnapshot? in
                        try check()
                        var needsScan = full || dates[directory.path] == nil
                        if !needsScan {
                            var url = directory; url.removeAllCachedResourceValues()
                            needsScan = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate != dates[directory.path]
                            for file in focused where !needsScan {
                                var url = file.url; url.removeAllCachedResourceValues()
                                do {
                                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                                    needsScan = Int64(values.fileSize ?? -1) != file.size || values.contentModificationDate != file.modified
                                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { needsScan = true }
                            }
                        }
                        guard needsScan else { return nil }
                        let result = try DirectorySnapshot.read(directory); try check(); return result
                    }
                    guard revision == self.observationRevision, self.directory == directory, !Task.isCancelled else { return }
                    if let snapshot {
                        if self.isMoving || self.isLoading || self.isReadingMetadata { self.refreshRequested = true; self.refreshFullRequested = true; return }
                        await self.applyDirectorySnapshot(snapshot, directory: directory, revision: revision)
                    }
                } catch is CancellationError { return }
                catch { self.reportObservationFailure(error); self.directoryObserver?.stop(); self.directoryObserver = nil; return }
            }
        }
    }
    private func applyDirectorySnapshot(_ snapshot: DirectorySnapshot, directory: URL, revision: UUID) async {
        let oldByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let changed = snapshot.assets.count != assets.count || snapshot.assets.contains { $0.fingerprint != oldByID[$0.id]?.fingerprint }
        let previousDates = observedFolderDates
        let foldersChanged = !previousDates.isEmpty && previousDates != snapshot.dates
        observedFolderDates = snapshot.dates
        guard changed || foldersChanged else { return }
        let snapshotIDs = Set(snapshot.assets.map(\.id))
        let changedFiles = snapshot.assets.filter { $0.fingerprint != oldByID[$0.id]?.fingerprint }
            .flatMap { ($0.mediaFiles + (oldByID[$0.id]?.mediaFiles ?? [])) }
            + assets.filter { !snapshotIDs.contains($0.id) }.flatMap(\.mediaFiles)
        await displayCache.invalidate(changedFiles)
        do { try await thumbnails.invalidate(changedFiles) }
        catch is CancellationError { return }
        catch { reportObservationFailure(error); directoryObserver?.stop(); directoryObserver = nil; return }
        let changedFolders = snapshot.folders.filter { previousDates[$0.path] != snapshot.dates[$0.path] }
        let removedFolders = previousDates.keys.filter { $0 != directory.path && snapshot.dates[$0] == nil }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        await invalidateFolderCaches([directory] + changedFolders + removedFolders)
        guard revision == observationRevision, self.directory == directory, !isMoving, !isLoading, !isReadingMetadata, !Task.isCancelled else {
            refreshRequested = true; refreshFullRequested = true; return
        }
        let previousFile = focusedFile, previousIndex = visibleAssets.firstIndex { $0.id == focusedID } ?? 0
        let newIDs = Set(snapshot.assets.map(\.id))
        assets = snapshot.assets.map { asset in
            var value = asset
            if let old = oldByID[asset.id], old.fingerprint == asset.fingerprint { value.metadata = old.metadata }
            return value
        }
        subdirectories = snapshot.folders
        groups = groups.compactMap { group in
            var value = group; value.assetIDs = value.assetIDs.filter { newIDs.contains($0) }; return value.assetIDs.isEmpty ? nil : value
        }
        if scope != "all", scope != "ungrouped", !groups.contains(where: { $0.id == scope }) { scope = "all" }
        selection.formIntersection(newIDs)
        if let focusedID, !newIDs.contains(focusedID) {
            self.focusedID = visibleAssets.isEmpty ? nil : visibleAssets[min(previousIndex, visibleAssets.count - 1)].id
            if let focus = self.focusedID, selection.isEmpty { selection = [focus] }
            preferredFileID = nil
        }
        if focusedID == nil, oldByID.isEmpty, selectedFolderID == nil, let first = visibleAssets.first {
            focusedID = first.id; selection = [first.id]
        }
        if let selectedFolderID, !snapshot.folders.contains(where: { $0.path == selectedFolderID }) { self.selectedFolderID = nil }
        if previousFile != focusedFile { video.stop() }
        observeFocusedFiles()
        if changed { startPreviewGeneration(); previewContentRevision = UUID() }
        do { try saveSession(); status = L10n.text("已更新外部文件变化") }
        catch { report(error) }
    }
}
