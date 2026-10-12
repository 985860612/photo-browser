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
                           priority: PreviewWorkPriority? = nil,
                           _ work: @escaping (@escaping () throws -> Void) throws -> Value) async throws -> Value {
        let request = PreviewWorkRequest<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.start(continuation, on: isBackground ? background : foreground, work: work)
                priority?.install { [weak request, foreground] in request?.promote(on: foreground, work: work) }
            }
        } onCancel: { request.cancel() }
    }
}

/// A visible waiter can promote shared work that has not begun decoding yet.
public final class PreviewWorkPriority: @unchecked Sendable {
    private let lock = NSLock()
    private var promoted = false
    private var callback: (() -> Void)?
    public init() {}
    public func promote() {
        lock.lock(); promoted = true; let action = callback; lock.unlock()
        action?()
    }
    fileprivate func install(_ action: @escaping () -> Void) {
        lock.lock(); callback = action; let run = promoted; lock.unlock()
        if run { action() }
    }
}

private final class PreviewWorkRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: BlockOperation?
    private var operationID = UUID()
    private var began = false

    func start(_ continuation: CheckedContinuation<Value, Error>, on queue: OperationQueue,
               work: @escaping (@escaping () throws -> Void) throws -> Value) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let operation = makeOperation(work: work)
        self.operation = operation
        lock.unlock()
        queue.addOperation(operation)
    }

    func promote(on queue: OperationQueue, work: @escaping (@escaping () throws -> Void) throws -> Value) {
        lock.lock()
        guard !cancelled, !began, continuation != nil else { lock.unlock(); return }
        operation?.cancel(); operationID = UUID()
        let operation = makeOperation(work: work); self.operation = operation
        lock.unlock(); queue.addOperation(operation)
    }

    /// Called with the lock held. Superseded queued operations never execute their work.
    private func makeOperation(work: @escaping (@escaping () throws -> Void) throws -> Value) -> BlockOperation {
        let ticket = operationID
        return BlockOperation { [self] in
            lock.lock()
            guard !cancelled, !began, operationID == ticket else { lock.unlock(); return }
            began = true; lock.unlock()
            let result = Result { try autoreleasepool {
                try checkCancellation()
                let value = try work { [self] in try checkCancellation() }
                try checkCancellation()
                return value
            } }
            finish(result)
        }
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
