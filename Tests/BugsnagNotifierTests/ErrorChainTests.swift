import BugsnagNotifier
import Foundation
import XCTest

final class ErrorChainTests: XCTestCase {
    struct RootError: Error {}

    struct WrapperError: BugsnagChainedError {
        let underlyingError: (any Error)?
    }

    /// Class-based chained error, so links can (pathologically) form a cycle.
    /// `next` is mutated only during single-threaded test setup.
    final class NodeError: BugsnagChainedError, @unchecked Sendable {
        var next: (any Error)?
        var underlyingError: (any Error)? { next }
    }

    func testPlainErrorYieldsSingleElementChain() {
        let chain = BugsnagErrorChain.unwrap(RootError())
        XCTAssertEqual(chain.count, 1)
        XCTAssertTrue(chain[0] is RootError)
    }

    func testChainedErrorsUnwrapPrimaryFirst() {
        let error = WrapperError(underlyingError: WrapperError(underlyingError: RootError()))
        let chain = BugsnagErrorChain.unwrap(error)
        XCTAssertEqual(chain.count, 3)
        XCTAssertTrue(chain[0] is WrapperError)
        XCTAssertTrue(chain[1] is WrapperError)
        XCTAssertTrue(chain[2] is RootError)
    }

    func testNilUnderlyingErrorEndsChain() {
        let chain = BugsnagErrorChain.unwrap(WrapperError(underlyingError: nil))
        XCTAssertEqual(chain.count, 1)
    }

    func testDepthIsCapped() {
        var error: any Error = RootError()
        for _ in 0..<20 {
            error = WrapperError(underlyingError: error)
        }
        XCTAssertEqual(
            BugsnagErrorChain.unwrap(error).count,
            BugsnagErrorChain.defaultMaxDepth
        )
        XCTAssertEqual(BugsnagErrorChain.unwrap(error, maxDepth: 3).count, 3)
    }

    func testCycleStopsTraversal() {
        let a = NodeError()
        let b = NodeError()
        a.next = b
        b.next = a  // b "caused by" a: a → b → a → ...
        let chain = BugsnagErrorChain.unwrap(a)
        XCTAssertEqual(chain.count, 2)
        XCTAssertTrue(chain[0] as? NodeError === a)
        XCTAssertTrue(chain[1] as? NodeError === b)
    }

    func testSelfReferencingErrorYieldsSingleElementChain() {
        let a = NodeError()
        a.next = a
        XCTAssertEqual(BugsnagErrorChain.unwrap(a).count, 1)
    }

    func testNSUnderlyingErrorKeyIsFollowed() {
        let outer = NSError(
            domain: "test.outer",
            code: 2,
            userInfo: [NSUnderlyingErrorKey: RootError()]
        )
        let chain = BugsnagErrorChain.unwrap(outer)
        XCTAssertEqual(chain.count, 2)
        XCTAssertTrue(chain[1] is RootError)
    }

    func testChainedConformanceTakesPrecedenceOverNSError() {
        /// Conforms to ``BugsnagChainedError`` *and* carries an
        /// `NSUnderlyingErrorKey`; the protocol must win.
        final class BothError: NSError, BugsnagChainedError, @unchecked Sendable {
            var underlyingError: (any Error)? { WrapperError(underlyingError: nil) }
        }
        let error = BothError(
            domain: "test.both",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: RootError()]
        )
        let chain = BugsnagErrorChain.unwrap(error)
        XCTAssertEqual(chain.count, 2)
        XCTAssertTrue(chain[1] is WrapperError)
    }
}
