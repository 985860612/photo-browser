import Foundation

/// One read-only ExifTool invocation. Cancellation and timeout affect only this reader's process.
public final class FocusPointReader: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    public init() {}

    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if process?.isRunning == true { process?.terminate() }
    }

    public func read(_ file: PhotoFile) throws -> FocusPointMetadata {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        guard (file.kind == .raw || file.kind == .rendered), !file.isLivePhoto else {
            return FocusPointMetadata(availability: .unsupported)
        }
        guard let binary = MetadataReader.executable else {
            throw BrowserFailure.message(L10n.text("显示对焦点需要 ExifTool。请安装后重试：brew install exiftool。"))
        }
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoBrowser-Focus-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw BrowserFailure.message(L10n.text("无法创建拍摄信息读取日志。"))
        }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        let job = Process(), output = Pipe()
        job.executableURL = binary
        job.arguments = ["-j", "-G1", "-IFD0:Make", "-IFD0:Model", "-IFD0:Orientation#",
                         "-Canon:FocusMode#", "-Canon:NumAFPoints", "-Canon:ValidAFPoints", "-Canon:AFImageWidth", "-Canon:AFImageHeight",
                         "-Canon:AFAreaWidth", "-Canon:AFAreaHeight", "-Canon:AFAreaWidths", "-Canon:AFAreaHeights",
                         "-Canon:AFAreaXPositions", "-Canon:AFAreaYPositions", "-Canon:AFPointsInFocus", "-Canon:AFPointsSelected",
                         "-Sony:FocusMode#", "-Sony:FocusLocation", "-Sony:FocusLocation2", "-Sony:FocusFrameSize#", "--", file.url.path]
        job.standardOutput = output; job.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = job
        do { try job.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw error }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.process?.isRunning == true { self.timedOut = true; self.process?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        job.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled, expired = timedOut; process = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        if expired { throw BrowserFailure.message(L10n.text("读取对焦点超时，请重试。")) }
        guard job.terminationStatus == 0 else {
            let detail = String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8) ?? ""
            throw BrowserFailure.message(L10n.text("读取对焦点失败：\(detail.prefix(600))"))
        }
        return try FocusPointMetadata.decode(data)
    }
}
