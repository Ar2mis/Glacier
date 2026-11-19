import Foundation
import GlacierCore

private actor PreparationFixture {
    var calls = 0
    var ready = false
    func load() async throws -> Int {
        calls += 1
        while !ready { try await Task.sleep(for: .milliseconds(5)) }
        return 42
    }
    func release() { ready = true }
}
func verifyPreparationCancellation() async throws {
    let shared = SharedPreparation<Int>(), fixture = PreparationFixture()
    let canceled = Task { try await shared.get { try await fixture.load() } }
    while await fixture.calls == 0 { try await Task.sleep(for: .milliseconds(2)) }
    canceled.cancel()
    do { _ = try await canceled.value; preconditionFailure("Canceled waiter completed") } catch is CancellationError { }
    do { _ = try await shared.get(timeout: .milliseconds(30)) { try await fixture.load() }; preconditionFailure("Missing timeout") } catch { }
    await fixture.release()
    let result = try await shared.get { try await fixture.load() }
    let repeated = try await shared.get { preconditionFailure("Warm model reloaded") }
    let calls = await fixture.calls
    precondition(result == 42 && repeated == 42 && calls == 1)
    let failed = SharedPreparation<Int>()
    do { _ = try await failed.get { throw GlacierCoreError.message("Offline") }; preconditionFailure("Lost failure") } catch { }
    let retried = try await failed.get { 9 }
    precondition(retried == 9)
    print("PASS: canceled/expired model waiters return without awaiting loader, one compiler shared, failed preparation retries")
}
