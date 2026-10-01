import Vapor

/// At most one Contractor-link photo is decoded and re-encoded at a time in this process (Lane A P2, Fable
/// condition 7, 1 Oct 2026). The container has a quarter of a CPU and 1 GiB: two ImageMagick runs finish no
/// sooner than one after the other, and two large inputs (256 MiB memory + 512 MiB map limit each) risk the
/// memory ceiling. This holds whatever the NIO thread pool size is.
///
/// A request waits at most `wait` for its turn. A wait that reaches the bound is answered 503
/// `media_unavailable` — retryable, because nothing is wrong with the photo (not 422 `image_processing_failed`).
/// The page retries the same idempotent upload command.
actor ImageProcessingGate {
    static let shared = ImageProcessingGate()
    /// Nanoseconds a request may wait for its turn: well under the page's 180 s upload timeout.
    let wait: UInt64
    init(wait: UInt64 = 120 * 1_000_000_000) { self.wait = wait }

    private var held = false
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Waits for the gate (at most `wait`). Every successful acquire must be followed by exactly one `release`.
    func acquire() async throws {
        guard held else { held = true; return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiting.append((id, continuation))
            let wait = self.wait
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: wait)
                await self?.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: Abort(.serviceUnavailable, reason: "The server is busy checking another photo. Try again", identifier: "media_unavailable"))
    }

    /// Hands the gate straight to the next waiter (it stays held), or frees it.
    func release() {
        if waiting.isEmpty { held = false } else { waiting.removeFirst().continuation.resume() }
    }
}
