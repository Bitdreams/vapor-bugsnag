import BugsnagNotifier
import XCTest

final class StackTraceCaptureTests: XCTestCase {
    struct DummyError: Error {}

    // MARK: - BugsnagTracedError capture

    func testTracedErrorCapturesExactThrowSiteTopFrame() throws {
        let traced = DummyError().bugsnagTraced(); let expectedLine = #line

        let top = try XCTUnwrap(traced.bugsnagStacktrace.first)
        XCTAssertTrue(
            top.file.contains("StackTraceCaptureTests"),
            "top frame should be this file's #fileID, got \(top.file)"
        )
        XCTAssertEqual(top.lineNumber, expectedLine)
        XCTAssertTrue(
            top.method.contains("testTracedErrorCapturesExactThrowSiteTopFrame"),
            "top frame method should be #function, got \(top.method)"
        )
    }

    func testTracedErrorCapturesNonEmptyCallStackBeyondTopFrame() {
        let traced = BugsnagTracedError(wrapping: DummyError())
        XCTAssertGreaterThan(
            traced.bugsnagStacktrace.count, 1,
            "expected callStackSymbols frames beyond the synthesized #file/#line frame"
        )
        // Symbol frames carry no source location by construction.
        for frame in traced.bugsnagStacktrace.dropFirst() {
            XCTAssertEqual(frame.lineNumber, 0)
            XCTAssertFalse(frame.method.isEmpty)
        }
    }

    func testTracedErrorPreservesWrappedError() {
        let traced = BugsnagTracedError(wrapping: DummyError())
        XCTAssertTrue(traced.wrapped is DummyError)
    }

    func testTracingIsIdempotent() {
        let once = DummyError().bugsnagTraced()
        let twice = once.bugsnagTraced()
        let thrice = BugsnagTracedError(wrapping: twice)
        XCTAssertTrue(thrice.wrapped is DummyError, "re-wrapping must not nest wrappers")
        XCTAssertEqual(
            thrice.bugsnagStacktrace, once.bugsnagStacktrace,
            "the original throw-site frames must win"
        )
    }

    func testMaxFramesCapsCapturedStack() {
        let traced = BugsnagTracedError(wrapping: DummyError(), maxFrames: 3)
        XCTAssertLessThanOrEqual(traced.bugsnagStacktrace.count, 3)
        XCTAssertEqual(traced.bugsnagStacktrace.first?.lineNumber, #line - 2)
    }

    // MARK: - Parser: Darwin format

    func testParsesDarwinStyleLines() {
        let symbols = [
            "0   BugsnagNotifier                     0x0000000104f1c2a0 $s15BugsnagNotifier17BugsnagTracedErrorV8wrappingACs0D0_p_tcfC + 64",
            "1   MyApp                               0x0000000104a0b1c4 $s5MyApp9someRouteyyYaKF + 180",
            "2   libswift_Concurrency.dylib          0x00000001c3b2e400 _ZN5swift34runJobInEstablishedExecutorContextEPNS_3JobE + 252",
        ]
        let frames = BugsnagCallStackParser.parse(symbols)
        XCTAssertEqual(frames, [
            StackFrame(file: "BugsnagNotifier", lineNumber: 0, method: "$s15BugsnagNotifier17BugsnagTracedErrorV8wrappingACs0D0_p_tcfC"),
            StackFrame(file: "MyApp", lineNumber: 0, method: "$s5MyApp9someRouteyyYaKF"),
            StackFrame(file: "libswift_Concurrency.dylib", lineNumber: 0, method: "_ZN5swift34runJobInEstablishedExecutorContextEPNS_3JobE"),
        ])
    }

    func testDarwinLineWithoutOffsetKeepsFullSymbol() {
        let frame = BugsnagCallStackParser.parseLine(
            "3   Run   0x0000000100003f2c main"
        )
        XCTAssertEqual(frame, StackFrame(file: "Run", lineNumber: 0, method: "main"))
    }

    // MARK: - Parser: Linux (glibc backtrace_symbols) format

    func testParsesLinuxStyleLines() {
        let symbols = [
            "/app/Run($s3Run4mainyyYaKF+0x2c) [0x55f00c2a1b2c]",
            "/lib/x86_64-linux-gnu/libc.so.6(__libc_start_main+0xea) [0x7f8e4c21d09b]",
        ]
        let frames = BugsnagCallStackParser.parse(symbols)
        XCTAssertEqual(frames, [
            StackFrame(file: "Run", lineNumber: 0, method: "$s3Run4mainyyYaKF"),
            StackFrame(file: "libc.so.6", lineNumber: 0, method: "__libc_start_main"),
        ])
    }

    func testLinuxSymbollessFramesKeepDepthUsingTheAddress() {
        // Static or stripped images yield "(+0x..)" or "()" — keep the frame,
        // report the return address, so stack depth is not silently lost.
        XCTAssertEqual(
            BugsnagCallStackParser.parseLine("/app/Run(+0x4a1b2c) [0x55d2c3a1b2c0]"),
            StackFrame(file: "Run", lineNumber: 0, method: "0x55d2c3a1b2c0")
        )
        XCTAssertEqual(
            BugsnagCallStackParser.parseLine("/app/Run() [0x55f00c2a1b2c]"),
            StackFrame(file: "Run", lineNumber: 0, method: "0x55f00c2a1b2c")
        )
    }

    // MARK: - Parser: defensiveness

    func testUnparseableLinesAreDropped() {
        let symbols = [
            "",
            "   ",
            "not a frame at all",
            "0x0000000104a0b1c4",
            "1   MyApp   0xNOTHEX $s5MyApp9someRouteyyYaKF + 180",
            "/app/Run($sOk+0x1) [0x1]",
        ]
        let frames = BugsnagCallStackParser.parse(symbols)
        XCTAssertEqual(frames, [StackFrame(file: "Run", lineNumber: 0, method: "$sOk")])
    }

    func testDroppingFirstSkipsInnermostFrames() {
        let symbols = [
            "0   Foundation   0x0000000104f1c2a0 callStackSymbols + 1",
            "1   BugsnagNotifier   0x0000000104f1c2b0 captureInit + 2",
            "2   MyApp   0x0000000104a0b1c4 realFrame + 3",
        ]
        let frames = BugsnagCallStackParser.parse(symbols, droppingFirst: 2)
        XCTAssertEqual(frames, [StackFrame(file: "MyApp", lineNumber: 0, method: "realFrame")])
    }

    func testMaxFramesCapsParserOutput() {
        let symbols = (0..<80).map { "\($0)   MyApp   0x0000000104a0b1c4 frame\($0) + 4" }
        XCTAssertEqual(BugsnagCallStackParser.parse(symbols).count, 50, "default cap")
        XCTAssertEqual(BugsnagCallStackParser.parse(symbols, maxFrames: 5).count, 5)
        XCTAssertEqual(BugsnagCallStackParser.parse(symbols, maxFrames: 0), [])
    }

    // MARK: - Custom conformances

    struct SelfTracingError: Error, BugsnagStackTraceProviding {
        var bugsnagStacktrace: [StackFrame] {
            [StackFrame(file: "custom.swift", lineNumber: 7, method: "custom()")]
        }
    }

    func testAnyErrorCanProvideItsOwnFrames() throws {
        let error: any Error = SelfTracingError()
        let traced = try XCTUnwrap(error as? any BugsnagStackTraceProviding)
        XCTAssertEqual(
            traced.bugsnagStacktrace,
            [StackFrame(file: "custom.swift", lineNumber: 7, method: "custom()")]
        )
    }
}
