import Foundation

/// An error that wraps another, lower-level error.
///
/// Conform wrapper errors to this protocol so the notifier can walk the cause
/// chain and report every link as its own entry in the event's `exceptions`
/// array. Bugsnag renders the extra entries as "caused by" sections — the
/// same convention `bugsnag-go` follows for Go errors implementing `Unwrap()`.
///
/// ```swift
/// struct SyncFailedError: BugsnagChainedError {
///     let underlyingError: (any Error)?
/// }
/// ```
public protocol BugsnagChainedError: Error {
    /// The next error down the cause chain, or `nil` if this is the root cause.
    var underlyingError: (any Error)? { get }
}

/// Walks an error's cause chain into an ordered list of errors.
public enum BugsnagErrorChain {
    /// The default maximum number of links followed by ``unwrap(_:maxDepth:)``.
    public static let defaultMaxDepth = 8

    /// Unwraps an arbitrary error into its ordered cause chain.
    ///
    /// The result always starts with `error` itself (the primary error),
    /// followed by each successive cause. The next link is discovered by:
    /// 1. ``BugsnagChainedError/underlyingError``, when the error conforms;
    ///    otherwise
    /// 2. best effort: `userInfo[NSUnderlyingErrorKey]` when the error is an
    ///    `NSError` (Cocoa's underlying-error convention — useful on Darwin,
    ///    typically a no-op on Linux).
    ///
    /// Traversal stops at the first missing link, after `maxDepth` links, or
    /// when a class-based error instance is revisited (cycle guard).
    public static func unwrap(_ error: any Error, maxDepth: Int = defaultMaxDepth) -> [any Error] {
        var chain: [any Error] = []
        var visited: Set<ObjectIdentifier> = []
        var current: (any Error)? = error
        while let link = current, chain.count < maxDepth {
            if let identity = referenceIdentity(of: link) {
                guard visited.insert(identity).inserted else { break }
            }
            chain.append(link)
            current = underlyingError(of: link)
        }
        return chain
    }

    private static func underlyingError(of error: any Error) -> (any Error)? {
        if let chained = error as? any BugsnagChainedError {
            return chained.underlyingError
        }
        #if canImport(Darwin)
        // Every Error bridges to NSError on Darwin; plain Swift errors just
        // carry an empty userInfo, so this is a safe best-effort lookup.
        let nsError = error as NSError
        #else
        // No implicit bridging on Linux — only genuine NSError instances match.
        guard let nsError = error as? NSError else { return nil }
        #endif
        return nsError.userInfo[NSUnderlyingErrorKey] as? any Error
    }

    /// A stable identity for class-based errors, used to detect cycles.
    /// Value-type errors get `nil`: they are boxed afresh on each cast, and a
    /// genuinely cyclic chain of values is bounded by `maxDepth` anyway.
    private static func referenceIdentity(of error: any Error) -> ObjectIdentifier? {
        guard type(of: error) is AnyClass else { return nil }
        return ObjectIdentifier(error as AnyObject)
    }
}
