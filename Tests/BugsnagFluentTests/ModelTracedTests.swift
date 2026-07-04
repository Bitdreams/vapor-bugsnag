import BugsnagFluent
import BugsnagNotifier
import FluentKit
import Logging
import NIOEmbedded
import XCTest
import XCTFluent

/// The point of `BugsnagFluent` is that a failing DB mutation is rethrown
/// wrapped in a `BugsnagTracedError` whose guaranteed top frame is the
/// **caller's** `#fileID`/`#line`/`#function`, not this helper's. Because the
/// `file`/`line`/`function` parameters default to the call site, these tests
/// assert the captured top frame points back into *this test file* and *this
/// test method* — never `Model+Traced.swift`.
final class ModelTracedTests: XCTestCase {

    // MARK: - Fixtures

    struct BoomError: Error, Equatable {}

    /// A `TestDatabase` whose every query throws — so `save`/`create` fail at
    /// the DB layer exactly like a stackless `PSQLError` would in production.
    struct ThrowingDatabase: TestDatabase {
        func execute(
            query: DatabaseQuery,
            onOutput: @escaping @Sendable (any DatabaseOutput) -> ()
        ) throws {
            throw BoomError()
        }
    }

    final class Widget: Model, @unchecked Sendable {
        static let schema = "widgets"

        @ID(key: .id) var id: UUID?
        @Field(key: "name") var name: String

        init() {}
        init(id: UUID? = nil, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// A database backed by an `EmbeddedEventLoop`, whose `inEventLoop` is
    /// always true, so a failed future resolves synchronously without having to
    /// run the loop — the async bridge completes immediately.
    private func throwingDB() -> any Database {
        let test = ThrowingDatabase()
        return test.database(context: .init(
            configuration: test.configuration,
            logger: Logger(label: "bugsnag.fluent.test"),
            eventLoop: EmbeddedEventLoop()
        ))
    }

    private func assertCallerTopFrame(
        _ error: any Error,
        expectedLine: Int,
        expectedFunction: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let traced = try XCTUnwrap(
            error as? BugsnagTracedError,
            "expected a BugsnagTracedError, got \(error)",
            file: file, line: line
        )
        let top = try XCTUnwrap(traced.bugsnagStacktrace.first, file: file, line: line)
        XCTAssertTrue(
            top.file.contains("ModelTracedTests"),
            "top frame should be this test file, got \(top.file)",
            file: file, line: line
        )
        XCTAssertFalse(
            top.file.contains("Model+Traced"),
            "top frame must NOT be the helper file, got \(top.file)",
            file: file, line: line
        )
        XCTAssertEqual(top.lineNumber, expectedLine, file: file, line: line)
        XCTAssertTrue(
            top.method.contains(expectedFunction),
            "top frame method should be the caller's #function, got \(top.method)",
            file: file, line: line
        )
    }

    // MARK: - Real Model extension: call-site capture

    func testTracedSaveRethrowsTracedErrorAtCallerSite() async throws {
        let db = throwingDB()
        let widget = Widget(name: "boom")
        let callLine = #line + 2
        do {
            try await widget.tracedSave(on: db)
            XCTFail("expected tracedSave to rethrow")
        } catch {
            try assertCallerTopFrame(
                error,
                expectedLine: callLine,
                expectedFunction: "testTracedSaveRethrowsTracedErrorAtCallerSite"
            )
            XCTAssertTrue((error as? BugsnagTracedError)?.wrapped is BoomError)
        }
    }

    func testTracedCreateRethrowsTracedErrorAtCallerSite() async throws {
        let db = throwingDB()
        let widget = Widget(name: "boom")
        let callLine = #line + 2
        do {
            try await widget.tracedCreate(on: db)
            XCTFail("expected tracedCreate to rethrow")
        } catch {
            try assertCallerTopFrame(
                error,
                expectedLine: callLine,
                expectedFunction: "testTracedCreateRethrowsTracedErrorAtCallerSite"
            )
            XCTAssertTrue((error as? BugsnagTracedError)?.wrapped is BoomError)
        }
    }

    func testTracedUpdateRethrowsTracedErrorAtCallerSite() async throws {
        let db = throwingDB()
        // Mark the model as persisted so `update` proceeds to the DB layer.
        let widget = Widget(id: UUID(), name: "boom")
        widget._$id.exists = true
        let callLine = #line + 2
        do {
            try await widget.tracedUpdate(on: db)
            XCTFail("expected tracedUpdate to rethrow")
        } catch {
            try assertCallerTopFrame(
                error,
                expectedLine: callLine,
                expectedFunction: "testTracedUpdateRethrowsTracedErrorAtCallerSite"
            )
        }
    }

    // MARK: - Successful mutations pass through untouched

    func testTracedCreateDoesNotWrapOnSuccess() async throws {
        let arrayDB = ArrayTestDatabase()
        arrayDB.append([TestOutput()]) // one result → the insert "succeeds"
        let db = arrayDB.database(context: .init(
            configuration: arrayDB.configuration,
            logger: Logger(label: "bugsnag.fluent.test"),
            eventLoop: EmbeddedEventLoop()
        ))
        // Should not throw; proves the happy path is untouched by the wrapper.
        try await Widget(name: "ok").tracedCreate(on: db)
    }

    // MARK: - Contract: params thread through to the captured frame

    /// Belt-and-suspenders: proves the exact `file`/`line`/`function` values the
    /// helper forwards land as the top frame, independent of Fluent — this is
    /// the contract `Model+Traced.swift` relies on.
    func testBugsnagTracedErrorHonorsThreadedCallSiteParams() throws {
        let traced = BugsnagTracedError(
            wrapping: BoomError(),
            file: "Controllers/EntryController.swift",
            line: 4242,
            function: "store(req:)"
        )
        let top = try XCTUnwrap(traced.bugsnagStacktrace.first)
        XCTAssertEqual(top.file, "Controllers/EntryController.swift")
        XCTAssertEqual(top.lineNumber, 4242)
        XCTAssertEqual(top.method, "store(req:)")
    }
}
