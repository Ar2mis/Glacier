import Foundation

/// One expensive loader, multiple independently cancellable/finite waiters.
/// A canceled Start must not await Core ML compilation or spawn another compiler.
public actor SharedPreparation<Value: Sendable> {
    private var value: Value?
    private var loading: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    public init() {}
    public func get(timeout: Duration = .seconds(180), load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let value { return value }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
                deadlines[id] = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.finish(id, result: .failure(GlacierCoreError.message("Speech model preparation timed out. The download may still finish; retry Base or restart Glacier. Saved text is retained.")))
                }
                if loading == nil {
                    loading = Task.detached(priority: .userInitiated) {
                        do { await self.complete(.success(try await load())) }
                        catch { await self.complete(.failure(error)) }
                    }
                }
            }
        } onCancel: { Task { await self.finish(id, result: .failure(CancellationError())) } }
    }
    private func finish(_ id: UUID, result: Result<Value, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        waiters.removeValue(forKey: id)?.resume(with: result)
    }
    private func complete(_ result: Result<Value, Error>) {
        if case .success(let ready) = result { value = ready }
        loading = nil
        for id in Array(waiters.keys) { finish(id, result: result) }
    }
}
