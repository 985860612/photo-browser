import Foundation

extension PhotoAsset {
    /// Keep the persisted session format stable: metadata is valid only for this file snapshot.
    public var fingerprint: String {
        files.map { "\($0.url.lastPathComponent)|\($0.size)|\($0.modified.timeIntervalSince1970)" }.joined(separator: ";")
    }
}
