import BugsnagNotifier
import Vapor

extension Request {
    /// The Bugsnag session for this request (one session per HTTP request,
    /// per the server-notifier convention). Set by ``BugsnagMiddleware`` when
    /// `autoCaptureSessions` is enabled; nil otherwise.
    ///
    /// Read and written only inside request isolation — the value is a
    /// `Sendable` struct, so snapshots of it may safely cross into delivery
    /// tasks, but the storage itself is never touched from outside the
    /// request pipeline.
    var bugsnagSession: BugsnagSession? {
        get { storage[BugsnagSessionKey.self] }
        set { storage[BugsnagSessionKey.self] = newValue }
    }

    private struct BugsnagSessionKey: StorageKey {
        typealias Value = BugsnagSession
    }
}
