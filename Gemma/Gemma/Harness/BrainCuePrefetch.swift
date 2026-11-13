import BrainContract
import Foundation

/// Debounces explicitly active dictation. This read never supplies evidence to a final turn.
@MainActor
final class BrainCuePrefetch {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var previous: String?
    private var submitted = 0
    private var admission: (operationID: UUID, threadID: String, client: MemoryClient)?

    init(delay: Duration = .milliseconds(380)) { self.delay = delay }

    @discardableResult
    func submit(partial: String, threadID: String, client: MemoryClient) -> Task<Void, Never>? {
        let query = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != previous else { return pending }
        pending?.cancel()
        pending = nil
        admission = nil
        previous = query
        guard query.split(whereSeparator: \.isWhitespace).count >= 3, query.utf8.count <= 1200,
              submitted < 4 else { return nil }
        let task = Task { @MainActor [weak self, delay] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                guard let self else { return }
                self.submitted += 1
                let operationID = UUID()
                self.admission = (operationID, threadID, client)
                let budget = try BrainContextBudget(contextTokens: 4096, outputTokens: 512)
                let request = try BrainContextRequest(clientOperationID: operationID.uuidString, threadID: threadID,
                    query: query, budget: budget, quoteEvidenceIDs: [], detailEvidenceIDs: [])
                _ = try await client.prefetchBrainContext(request)
            } catch {
                // This read is optional. Final admission obtains fresh evidence independently.
            }
        }
        pending = task
        return task
    }

    func consume(final: String, threadID: String, client: MemoryClient?) -> UUID? {
        defer { cancel() }
        guard final == previous, let admission, admission.threadID == threadID,
              admission.client === client else { return nil }
        return admission.operationID
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        previous = nil
        admission = nil
        submitted = 0
    }
}
