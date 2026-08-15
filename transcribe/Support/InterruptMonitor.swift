import Darwin
import Dispatch

/// Turns Ctrl-C into cooperative task cancellation.
///
/// The work cannot simply be killed where it stands: the audio reader documents that cancelling it
/// must not overlap a read in progress. Routing the signal into task cancellation lets the ingest
/// iterator notice at its next checkpoint and tear the reader down from the same context that
/// drives it.
final class InterruptMonitor {

    private let source: DispatchSourceSignal

    /// Begins watching for `SIGINT`.
    ///
    /// - Parameter onInterrupt: Called on a background queue when the signal arrives. It runs
    ///   outside signal-handler context, so it is not restricted to async-signal-safe calls.
    init(onInterrupt: @escaping @Sendable () -> Void) {
        // The default disposition terminates the process immediately, which would skip cleanup
        // entirely. Ignoring it leaves the dispatch source as the only consumer.
        signal(SIGINT, SIG_IGN)

        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler(handler: onInterrupt)
        source.resume()
    }

    /// Stops watching and restores the default behavior, so a second Ctrl-C during shutdown still
    /// ends the process.
    func stop() {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}
