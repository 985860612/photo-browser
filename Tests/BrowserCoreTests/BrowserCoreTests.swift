import Foundation
import BrowserCore

final class BrowserCoreTests {
    private var root: URL!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoBrowserTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    @discardableResult private func file(_ name: String, content: String = "original-photo") throws -> URL {
        let url = root.appendingPathComponent(name); try Data(content.utf8).write(to: url); return url
    }
    private func setupPlan() throws -> ArchivePlan {
        for name in ["DSC00001.ARW", "DSC00001.HIF", "DSC00001.xmp", "DSC00002.ARW", "DSC00002.JPG"] { try file(name) }
        let assets = try DirectoryScanner.scan(root)
        let group = PhotoGroup(name: "全景 1", assetIDs: assets.map(\.id))
        return try ArchivePlan(directory: root, destination: root.appendingPathComponent("全景 1"), group: group, assets: assets)
    }
    private func engine(mover: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) -> ArchiveEngine {
        ArchiveEngine(journalDirectory: root.appendingPathComponent("journal"), mover: mover)
    }

    func testPairsFormatsAndSidecarsWithoutReadingSubfolders() throws {
        for name in ["DSC00001.ARW", "DSC00001.HIF", "DSC00001.JPG", "DSC00001.ARW.xmp", "dsc00001.xmp", "DSC00002.HIF", "orphan.xmp", "notes.txt"] { try file(name) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("DNG"), withIntermediateDirectories: true)
        let assets = try DirectoryScanner.scan(root)
        try expectEqual(assets.count, 2)
        try expectEqual(assets[0].imageFiles.count, 3)
        try expectEqual(assets[0].files.count, 5)
        try expectEqual(assets[0].preferred.format, "HIF")
        try expectEqual(assets[1].preferred.format, "HIF")
    }

    func testImportsCSVWithBOMQuotesNewlinesAndDeduplicatesPairs() throws {
        try file("DSC00001.ARW"); try file("DSC00001.HIF"); try file("DSC00002.HIF")
        let csv = "\u{feff}组号,分类,文件名,判断依据\r\n1,全景候选,DSC00001.ARW,\"岸线,连续\n横移\"\r\n1,全景候选,DSC00001.HIF,相同\r\n1,全景候选,DSC00002.HIF,相同\r\n"
        let groups = try Grouping.importCSV(Data(csv.utf8), assets: DirectoryScanner.scan(root))
        try expectEqual(groups.count, 1)
        try expectEqual(groups[0].assetIDs, ["dsc00001", "dsc00002"])
        try expectEqual(groups[0].reason, "岸线,连续\n横移")
        try expectEqual(groups[0].confidence, .candidate)
    }

    func testBurstResetFocalChangeAndTimeGapBreakGroups() throws {
        func asset(_ index: Int, time: Double, sequence: Int, focal: Double = 50) -> PhotoAsset {
            PhotoAsset(id: "\(index)", name: "\(index)", files: [], metadata: PhotoMetadata(captured: Date(timeIntervalSince1970: time), sequence: sequence, focalLength: focal))
        }
        let assets = [asset(1,time:0,sequence:1), asset(2,time:0.2,sequence:2), asset(3,time:0.4,sequence:3),
                      asset(4,time:1,sequence:1), asset(5,time:1.2,sequence:2), asset(6,time:1.4,sequence:3),
                      asset(7,time:2,sequence:4,focal:70), asset(8,time:20,sequence:5,focal:70)]
        let groups = Grouping.candidates(assets.reversed())
        try expectEqual(groups.map(\.assetIDs), [["1","2","3"],["4","5","6"]])
        try expectTrue(groups.allSatisfy { $0.confidence == .review })
    }

    func testSplitPreservesAllFramesAndRejectsFirstFrame() throws {
        let group = PhotoGroup(name: "P", assetIDs: ["a","b","c","d"])
        let split = try Grouping.split(group, at: "c")
        try expectEqual(split.map(\.assetIDs), [["a","b"],["c","d"]])
        try expectThrows(try Grouping.split(group, at: "a"))
    }

    func testArchiveAndUndoMoveEveryFormatAndPreserveBytes() throws {
        let plan = try setupPlan(), worker = engine()
        let record = try worker.archive(plan)
        try expectEqual(record.state, "complete")
        try expectEqual(record.entries.count, 5)
        for entry in record.entries {
            try expectFalse(FileManager.default.fileExists(atPath: entry.source.path))
            try expectEqual(try String(contentsOf: entry.destination, encoding: .utf8), "original-photo")
        }
        try expectEqual(try worker.records().first?.state, "complete")
        let restored = try worker.undo(record)
        try expectEqual(restored.state, "undone")
        for entry in restored.entries { try expectEqual(try String(contentsOf: entry.source, encoding: .utf8), "original-photo") }
        try expectFalse(FileManager.default.fileExists(atPath: record.destination.path))
    }

    func testDestinationCollisionNeverMovesOrOverwrites() throws {
        let plan = try setupPlan()
        try FileManager.default.createDirectory(at: plan.record.destination, withIntermediateDirectories: true)
        let marker = plan.record.destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try expectThrows(try engine().archive(plan))
        try expectEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        try expectTrue(plan.record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
    }

    func testMoveFailureRollsBackPartialGroup() throws {
        let plan = try setupPlan()
        var calls = 0
        let worker = engine { source, destination in
            calls += 1
            if calls == 2 { throw BrowserFailure.message("模拟连接中断") }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try expectThrows(try worker.archive(plan))
        for entry in plan.record.entries { try expectEqual(try String(contentsOf: entry.source, encoding: .utf8), "original-photo") }
        try expectFalse(FileManager.default.fileExists(atPath: plan.record.destination.path))
        try expectEqual(try worker.records().first?.state, "rolledBack")
    }

    func testUndoConflictIsPreflightedBeforeAnyFileMoves() throws {
        let plan = try setupPlan(), worker = engine(), record = try worker.archive(plan)
        let collision = record.entries[2].source
        try Data("new-unrelated-photo".utf8).write(to: collision)
        try expectThrows(try worker.undo(record))
        try expectTrue(record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) })
        try expectEqual(try String(contentsOf: collision, encoding: .utf8), "new-unrelated-photo")
    }

    func testRecoveryReconcilesCrashBetweenMoveAndJournalUpdate() throws {
        let plan = try setupPlan(), worker = engine(), record = try worker.archive(plan)
        // Simulate one file restored before an interruption, while the durable record is stale.
        try FileManager.default.moveItem(at: record.entries[0].destination, to: record.entries[0].source)
        let restored = try worker.undo(record)
        try expectEqual(restored.state, "undone")
        try expectTrue(restored.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
    }

    func testJournalWriteFailurePreventsAnyOriginalMoves() throws {
        let plan = try setupPlan(), invalidJournal = try file("journal-is-a-file")
        let worker = ArchiveEngine(journalDirectory: invalidJournal)
        try expectThrows(try worker.archive(plan))
        try expectTrue(plan.record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
        try expectFalse(FileManager.default.fileExists(atPath: plan.record.destination.path))
    }

    func testChangedTargetPreventsUndo() throws {
        let plan = try setupPlan(), worker = engine(), record = try worker.archive(plan)
        try Data("edited-photo-with-different-size".utf8).write(to: record.entries[1].destination)
        try expectThrows(try worker.undo(record))
        try expectTrue(record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) })
    }

    func testPendingDeletionReusesFolderAndUndoKeepsOtherBatches() throws {
        let original = try setupPlan(), assets = try DirectoryScanner.scan(root), worker = engine()
        let first = try worker.archive(ArchivePlan.pendingDeletion(directory: root, assets: [assets[0]], groups: [original.record.group]))
        let second = try worker.archive(ArchivePlan.pendingDeletion(directory: root, assets: [assets[1]], groups: []))
        try expectTrue(first.isPendingDeletion && first.destinationCreated)
        try expectFalse(second.destinationCreated)
        try expectEqual(first.destination, second.destination)
        try expectEqual(first.entries.count, 3)
        try expectEqual(first.deletionGroups?.first?.assetIDs, original.record.group.assetIDs)
        try expectEqual(second.deletionGroups?.count, 0)
        try expectTrue(original.record.entries.allSatisfy { !FileManager.default.fileExists(atPath: $0.source.path) })
        _ = try worker.undo(first)
        try expectTrue(first.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
        try expectTrue(second.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) })
        _ = try worker.undo(second)
        try expectTrue(FileManager.default.fileExists(atPath: second.destination.path))
        for entry in original.record.entries { try expectEqual(try String(contentsOf: entry.source, encoding: .utf8), "original-photo") }
    }

    func testPendingDeletionPreflightsCaseInsensitiveSidecarCollision() throws {
        _ = try setupPlan()
        try file("DSC00002.xmp")
        let assets = try DirectoryScanner.scan(root), worker = engine()
        let target = root.appendingPathComponent("_del")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let collision = target.appendingPathComponent("dsc00002.XMP")
        try Data("previous-deletion".utf8).write(to: collision)
        let plan = try ArchivePlan.pendingDeletion(directory: root, assets: assets, groups: [])
        try expectThrows(try worker.archive(plan))
        try expectTrue(plan.record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
        try expectEqual(try String(contentsOf: collision, encoding: .utf8), "previous-deletion")
        try expectEqual(try worker.records().count, 0)
    }

    func testPendingDeletionRollbackPreservesExistingFolderContents() throws {
        _ = try setupPlan()
        let assets = try DirectoryScanner.scan(root), target = root.appendingPathComponent("_del")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let plan = try ArchivePlan.pendingDeletion(directory: root, assets: assets, groups: [])
        var calls = 0
        let worker = engine { source, destination in
            calls += 1
            if calls == 2 { throw BrowserFailure.message("connection interrupted") }
            try FileManager.default.moveItem(at: source, to: destination)
        }
        try expectThrows(try worker.archive(plan))
        for entry in plan.record.entries { try expectEqual(try String(contentsOf: entry.source, encoding: .utf8), "original-photo") }
        try expectEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        try expectEqual(try worker.records().first?.state, "rolledBack")
    }

    func testPendingDeletionRejectsFileAndSymbolicLinkTargets() throws {
        _ = try setupPlan()
        let assets = try DirectoryScanner.scan(root), target = root.appendingPathComponent("_del")
        let plan = try ArchivePlan.pendingDeletion(directory: root, assets: assets, groups: [])
        try Data("keep".utf8).write(to: target)
        try expectThrows(try engine().archive(plan))
        try expectEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: target)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)
        try expectThrows(try engine().archive(plan))
        try expectTrue(plan.record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
        try expectTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: root.appendingPathComponent("missing"))
        try expectThrows(try engine().archive(plan))
        try expectTrue(plan.record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
    }

    func testPendingDeletionJournalFailureLeavesSourcesUntouched() throws {
        _ = try setupPlan()
        let plan = try ArchivePlan.pendingDeletion(directory: root, assets: DirectoryScanner.scan(root), groups: [])
        let worker = ArchiveEngine(journalDirectory: try file("blocked-journal"))
        try expectThrows(try worker.archive(plan))
        try expectFalse(FileManager.default.fileExists(atPath: plan.record.destination.path))
        try expectTrue(plan.record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
    }

    func testPendingDeletionRecoveryAndAlreadyPendingGuard() throws {
        _ = try setupPlan()
        let plan = try ArchivePlan.pendingDeletion(directory: root, assets: DirectoryScanner.scan(root), groups: [])
        let worker = engine(), record = try worker.archive(plan)
        try expectThrows(try ArchivePlan.pendingDeletion(directory: record.destination, assets: DirectoryScanner.scan(record.destination), groups: []))
        try FileManager.default.moveItem(at: record.entries[0].destination, to: record.entries[0].source)
        let restored = try worker.undo(record)
        try expectEqual(restored.state, "undone")
        try expectTrue(record.entries.allSatisfy { FileManager.default.fileExists(atPath: $0.source.path) })
    }

    func testExistingArchiveRecordsRemainReadable() throws {
        let plan = try setupPlan()
        let encoded = try JSONEncoder().encode(plan.record)
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "deletionGroups")
        let decoded = try JSONDecoder().decode(ArchiveRecord.self, from: JSONSerialization.data(withJSONObject: json))
        try expectFalse(decoded.isPendingDeletion)
        try expectEqual(decoded.entries.count, 5)
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
private func expectEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: String = #fileID, line: Int = #line) throws {
    let a = try left(), b = try right()
    guard a == b else { throw CheckFailure(description: "\(file):\(line): expected \(b), got \(a)") }
}
private func expectTrue(_ expression: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) throws {
    guard try expression() else { throw CheckFailure(description: "\(file):\(line): expected true") }
}
private func expectFalse(_ expression: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) throws {
    guard try !expression() else { throw CheckFailure(description: "\(file):\(line): expected false") }
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: String = #fileID, line: Int = #line) throws {
    do { _ = try expression() } catch { return }
    throw CheckFailure(description: "\(file):\(line): expected an error")
}

@main struct BrowserCoreChecks {
    static func main() {
        let suite = BrowserCoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("session repository compatibility and failure checks", SessionRepositoryChecks.run),
            ("AI metadata compatibility and source association checks", RecognitionChecks.run),
            ("testPairsFormatsAndSidecarsWithoutReadingSubfolders", suite.testPairsFormatsAndSidecarsWithoutReadingSubfolders),
            ("testImportsCSVWithBOMQuotesNewlinesAndDeduplicatesPairs", suite.testImportsCSVWithBOMQuotesNewlinesAndDeduplicatesPairs),
            ("testBurstResetFocalChangeAndTimeGapBreakGroups", suite.testBurstResetFocalChangeAndTimeGapBreakGroups),
            ("testSplitPreservesAllFramesAndRejectsFirstFrame", suite.testSplitPreservesAllFramesAndRejectsFirstFrame),
            ("testArchiveAndUndoMoveEveryFormatAndPreserveBytes", suite.testArchiveAndUndoMoveEveryFormatAndPreserveBytes),
            ("testDestinationCollisionNeverMovesOrOverwrites", suite.testDestinationCollisionNeverMovesOrOverwrites),
            ("testMoveFailureRollsBackPartialGroup", suite.testMoveFailureRollsBackPartialGroup),
            ("testUndoConflictIsPreflightedBeforeAnyFileMoves", suite.testUndoConflictIsPreflightedBeforeAnyFileMoves),
            ("testRecoveryReconcilesCrashBetweenMoveAndJournalUpdate", suite.testRecoveryReconcilesCrashBetweenMoveAndJournalUpdate),
            ("testJournalWriteFailurePreventsAnyOriginalMoves", suite.testJournalWriteFailurePreventsAnyOriginalMoves),
            ("testChangedTargetPreventsUndo", suite.testChangedTargetPreventsUndo),
            ("testPendingDeletionReusesFolderAndUndoKeepsOtherBatches", suite.testPendingDeletionReusesFolderAndUndoKeepsOtherBatches),
            ("testPendingDeletionPreflightsCaseInsensitiveSidecarCollision", suite.testPendingDeletionPreflightsCaseInsensitiveSidecarCollision),
            ("testPendingDeletionRollbackPreservesExistingFolderContents", suite.testPendingDeletionRollbackPreservesExistingFolderContents),
            ("testPendingDeletionRejectsFileAndSymbolicLinkTargets", suite.testPendingDeletionRejectsFileAndSymbolicLinkTargets),
            ("testPendingDeletionJournalFailureLeavesSourcesUntouched", suite.testPendingDeletionJournalFailureLeavesSourcesUntouched),
            ("testPendingDeletionRecoveryAndAlreadyPendingGuard", suite.testPendingDeletionRecoveryAndAlreadyPendingGuard),
            ("testExistingArchiveRecordsRemainReadable", suite.testExistingArchiveRecordsRemainReadable)
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try suite.setUpWithError()
                try check()
                try suite.tearDownWithError()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
                do { try suite.tearDownWithError() } catch { print("Cleanup failed: \(error)") }
            }
        }
        print("\(checks.count - failures)/\(checks.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
