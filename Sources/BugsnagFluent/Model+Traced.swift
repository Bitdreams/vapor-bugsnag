import BugsnagNotifier
import FluentKit

// MARK: - Traced Fluent mutations

/// Fluent model mutations that capture the **caller's** throw site when the
/// database operation fails.
///
/// PostgresNIO / FluentKit errors thrown on Linux carry no throw-site stack —
/// by the time `BugsnagMiddleware` catches one, the frames are unwound, so the
/// event ships with an empty `stacktrace`. These helpers wrap the failing
/// operation in a `do`/`catch` and rethrow the error inside a
/// ``BugsnagNotifier/BugsnagTracedError``, which captures the exact
/// `#fileID`/`#line`/`#function` of the **call site** as its guaranteed top
/// frame.
///
/// The `file`/`line`/`function` parameters are defaulted to `#fileID`/`#line`/
/// `#function`, so they resolve to the *caller* (typically a controller), not
/// to this file. Threading them into `BugsnagTracedError(wrapping:file:line:
/// function:)` makes the recorded throw-site frame point at the controller line
/// that issued the failing write:
///
/// ```swift
/// import BugsnagFluent
///
/// try await entry.tracedSave(on: req.db)
/// ```
///
/// Wrapping is idempotent and preserves the original error for `errorClass`,
/// `message`, severity, and grouping — see ``BugsnagNotifier/BugsnagTracedError``.
public extension Model {
    /// Calls ``FluentKit/Model/save(on:)`` and, if it throws, rethrows the error
    /// wrapped in a ``BugsnagNotifier/BugsnagTracedError`` capturing the caller's
    /// throw site. Leave `file`/`line`/`function` defaulted.
    func tracedSave(
        on database: any Database,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) async throws {
        do {
            try await save(on: database)
        } catch {
            throw BugsnagTracedError(wrapping: error, file: file, line: line, function: function)
        }
    }

    /// Calls ``FluentKit/Model/create(on:)`` and, if it throws, rethrows the
    /// error wrapped in a ``BugsnagNotifier/BugsnagTracedError`` capturing the
    /// caller's throw site. Leave `file`/`line`/`function` defaulted.
    func tracedCreate(
        on database: any Database,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) async throws {
        do {
            try await create(on: database)
        } catch {
            throw BugsnagTracedError(wrapping: error, file: file, line: line, function: function)
        }
    }

    /// Calls ``FluentKit/Model/update(on:)`` and, if it throws, rethrows the
    /// error wrapped in a ``BugsnagNotifier/BugsnagTracedError`` capturing the
    /// caller's throw site. Leave `file`/`line`/`function` defaulted.
    func tracedUpdate(
        on database: any Database,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) async throws {
        do {
            try await update(on: database)
        } catch {
            throw BugsnagTracedError(wrapping: error, file: file, line: line, function: function)
        }
    }
}
