import Synchronization

/// A one-way "stop now" signal shared by the interrupt handler and the transcription pipeline.
///
/// Task cancellation alone is not sufficient here, for two reasons. `SpeechAnalyzer` iterates the
/// input from a task it owns rather than a child of the caller's, so `Task.isCancelled` inside the
/// ingest iterator stays false when the command's task is cancelled. And
/// `finalizeAndFinishThroughEndOfInput()` waits for an end of input that a stopped reader never
/// delivers, so it has to be unblocked from outside — which is what the handlers are for.
///
/// Without this, an interrupted run finishes quietly and writes whatever it had recognized so far,
/// which is indistinguishable from a complete transcript once it leaves the process.
final class InterruptFlag: Sendable {

    private let state = Mutex(State())

    private struct State {
        var isInterrupted = false
        var handlers: [@Sendable () -> Void] = []
    }

    var isSet: Bool {
        state.withLock(\.isInterrupted)
    }

    /// Records the interrupt and runs every registered handler exactly once.
    func set() {
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            state.isInterrupted = true
            defer { state.handlers.removeAll() }
            return state.handlers
        }
        for handler in handlers {
            handler()
        }
    }

    /// Registers work to run on interrupt, running it immediately if one already happened.
    ///
    /// Used to tear down anything that would otherwise block waiting for input that has stopped
    /// arriving.
    func onInterrupt(_ handler: @escaping @Sendable () -> Void) {
        let alreadyInterrupted = state.withLock { state -> Bool in
            guard !state.isInterrupted else { return true }
            state.handlers.append(handler)
            return false
        }
        if alreadyInterrupted {
            handler()
        }
    }

    /// Drops registered handlers once the work they would tear down has finished.
    func removeHandlers() {
        state.withLock { $0.handlers.removeAll() }
    }

    /// Throws `CancellationError` if an interrupt has been requested.
    func throwIfInterrupted() throws {
        if isSet { throw CancellationError() }
    }
}
