import Foundation

/// Two visible-image workers stay available while one utility worker warms the disk cache.
public final class PreviewWorkQueue: @unchecked Sendable {
    public static let shared = PreviewWorkQueue()
    private let foreground = OperationQueue()
    private let background = OperationQueue()

    public init() {
        foreground.name = "PhotoBrowser.visiblePreviews"
        foreground.maxConcurrentOperationCount = 2
        foreground.qualityOfService = .userInitiated
        background.name = "PhotoBrowser.backgroundPreviews"
        background.maxConcurrentOperationCount = 1
        background.qualityOfService = .utility
    }

    public func run<Value>(background isBackground: Bool = false,
                           _ work: @escaping (@escaping () throws -> Void) throws -> Value) async throws -> Value {
        let request = PreviewWorkRequest<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(continuation, on: isBackground ? background : foreground, work: work)
            }
        } onCancel: { request.cancel() }
    }
}

private final class PreviewWorkRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: BlockOperation?

    func start(_ continuation: CheckedContinuation<Value, Error>, on queue: OperationQueue,
               work: @escaping (@escaping () throws -> Void) throws -> Value) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let operation = BlockOperation { [self] in
            let result = Result { try autoreleasepool {
                try checkCancellation()
                let value = try work { [self] in try checkCancellation() }
                try checkCancellation()
                return value
            } }
            finish(result)
        }
        self.operation = operation
        lock.unlock()
        queue.addOperation(operation)
    }

    func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    func cancel() {
        lock.lock(); cancelled = true
        let waiter = continuation; continuation = nil
        let operation = operation; self.operation = nil
        lock.unlock()
        operation?.cancel()
        waiter?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock(); let waiter = continuation; continuation = nil; operation = nil; lock.unlock()
        waiter?.resume(with: result)
    }
}
