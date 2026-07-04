import Foundation

// MARK: - BugsnagStackTraceProviding

/// An error that carries its own stack trace for Bugsnag reporting.
///
/// Swift on Linux does not attach a throw-site stack to a thrown `Error` — by
/// the time middleware catches it, the frames are unwound. Errors conforming
/// to this protocol supply their own frames instead (typically captured at
/// `init`, i.e. at the throw site), and the `BugsnagVapor` event builder
/// copies them into the event's `stacktrace`.
///
/// Conform directly for domain error types that want to control their frames,
/// or use ``BugsnagTracedError`` / ``Swift/Error/bugsnagTraced(file:line:function:)``
/// to wrap any existing error.
public protocol BugsnagStackTraceProviding: Error {
    /// The frames to report, outermost (throw site) first.
    var bugsnagStacktrace: [StackFrame] { get }
}

// MARK: - BugsnagTracedError

/// Wraps any error and captures `Thread.callStackSymbols` at initialization,
/// so throwing `BugsnagTracedError(wrapping: error)` — or the sugar
/// `error.bugsnagTraced()` — records the throw-site stack.
///
/// What you get, honestly:
/// - The first frame is always exact: the `#fileID`/`#line`/`#function` of the
///   call site, captured via default arguments.
/// - The remaining frames come from `Thread.callStackSymbols`: **mangled**
///   symbols (`$s...`; demangle with `swift demangle`), `lineNumber` always 0,
///   and possibly missing frames in release builds due to inlining. On Linux,
///   frames from the app binary may carry only an address unless the image
///   exports symbols.
///
/// The wrapped error is preserved in ``wrapped`` and used by the event builder
/// for `errorClass`/`message`/grouping, so wrapping does not reshuffle how
/// events group in Bugsnag. Wrapping an already-traced error is a no-op: the
/// original throw-site frames win.
public struct BugsnagTracedError: Error, BugsnagStackTraceProviding {
    /// The original error, used for `errorClass` and `message` extraction.
    public let wrapped: any Error

    /// Frames captured at init: the exact call-site frame first, then the
    /// best-effort parse of `Thread.callStackSymbols`.
    public let bugsnagStacktrace: [StackFrame]

    /// Captures the current call stack and wraps `error`.
    ///
    /// - Parameters:
    ///   - error: the error to wrap. If it is already a `BugsnagTracedError`,
    ///     its wrapped error and original frames are kept unchanged.
    ///   - file/line/function: leave defaulted — they record the call site.
    ///   - maxFrames: cap on the total number of reported frames.
    public init(
        wrapping error: any Error,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function,
        maxFrames: Int = 50
    ) {
        if let alreadyTraced = error as? BugsnagTracedError {
            self.wrapped = alreadyTraced.wrapped
            self.bugsnagStacktrace = alreadyTraced.bugsnagStacktrace
            return
        }
        self.wrapped = error
        let throwSite = StackFrame(file: file, lineNumber: line, method: function)
        let captured = BugsnagCallStackParser.parse(
            Thread.callStackSymbols,
            // Skip the innermost capture machinery: the callStackSymbols
            // getter and this initializer. (Best-effort — a `bugsnagTraced()`
            // shim frame may still appear; the throw-site frame above is the
            // guaranteed-useful one.)
            droppingFirst: 2,
            maxFrames: max(0, maxFrames - 1)
        )
        self.bugsnagStacktrace = [throwSite] + captured
    }
}

extension Error {
    /// Returns this error wrapped in a ``BugsnagTracedError`` that captured
    /// the stack at the call site:
    ///
    /// ```swift
    /// throw DatabaseWriteError().bugsnagTraced()
    /// ```
    ///
    /// Idempotent — tracing an already-traced error keeps the original frames.
    public func bugsnagTraced(
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) -> BugsnagTracedError {
        BugsnagTracedError(wrapping: self, file: file, line: line, function: function)
    }
}

// MARK: - Call-stack symbol parsing

/// Best-effort parser from `Thread.callStackSymbols` lines to ``StackFrame``s.
///
/// Handles both symbol formats defensively and never crashes on input it does
/// not understand — unparseable lines are dropped:
/// - Darwin: `"4   MyApp   0x0000000104a0b1c4 $s5MyApp3fooyyF + 180"`
/// - Linux (glibc `backtrace_symbols`): `"/app/Run($s3Run4mainyyYaKF+0x2c) [0x55f00c2a1b2c]"`,
///   including symbol-less frames like `"/app/Run(+0x2c) [0x55f00c2a1b2c]"`,
///   which are kept with the address as the method so stack depth is preserved.
///
/// `method` is the raw (mangled) symbol, `file` is the image/binary name, and
/// `lineNumber` is always 0 — symbol lines carry no source location.
public enum BugsnagCallStackParser {
    /// Parses symbol lines into frames.
    ///
    /// - Parameters:
    ///   - symbols: lines as returned by `Thread.callStackSymbols`.
    ///   - dropCount: innermost frames to skip (capture machinery).
    ///   - maxFrames: cap on the number of parsed frames returned.
    public static func parse(
        _ symbols: [String],
        droppingFirst dropCount: Int = 0,
        maxFrames: Int = 50
    ) -> [StackFrame] {
        guard maxFrames > 0 else { return [] }
        return Array(
            symbols
                .dropFirst(max(0, dropCount))
                .compactMap(parseLine)
                .prefix(maxFrames)
        )
    }

    /// Parses a single symbol line; returns `nil` for lines in neither format.
    public static func parseLine(_ line: String) -> StackFrame? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return parseDarwinLine(trimmed) ?? parseLinuxLine(trimmed)
    }

    /// `"4   MyApp   0x0000000104a0b1c4 $s5MyApp3fooyyF + 180"`
    private static func parseDarwinLine(_ line: String) -> StackFrame? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard
            parts.count >= 4,
            Int(parts[0]) != nil,
            parts[2].hasPrefix("0x"),
            UInt64(parts[2].dropFirst(2), radix: 16) != nil
        else { return nil }

        var symbolParts = Array(parts[3...])
        // Strip the trailing decimal offset ("+ 180") if present.
        if symbolParts.count >= 3,
           symbolParts[symbolParts.count - 2] == "+",
           Int(symbolParts[symbolParts.count - 1]) != nil {
            symbolParts.removeLast(2)
        }
        let method = symbolParts.joined(separator: " ")
        guard !method.isEmpty else { return nil }
        return StackFrame(file: String(parts[1]), lineNumber: 0, method: method)
    }

    /// `"/app/Run($s3Run4mainyyYaKF+0x2c) [0x55f00c2a1b2c]"`
    private static func parseLinuxLine(_ line: String) -> StackFrame? {
        guard
            line.hasSuffix("]"),
            let bracket = line.range(of: " [0x", options: .backwards),
            let openParen = line.firstIndex(of: "("),
            let closeParen = line[openParen...].firstIndex(of: ")"),
            closeParen < bracket.lowerBound
        else { return nil }

        let binaryPath = line[..<openParen].trimmingCharacters(in: .whitespaces)
        guard !binaryPath.isEmpty else { return nil }
        let file = binaryPath.split(separator: "/").last.map(String.init) ?? binaryPath

        let inside = line[line.index(after: openParen)..<closeParen]
        // "(sym+0x2c)", "(sym)", "(+0x2c)", or "()" — offset-only means no symbol.
        let symbol = inside.hasPrefix("+")
            ? ""
            : (inside.split(separator: "+").first.map(String.init) ?? "")

        // " [0xADDR]" — the return address, used as a stand-in method for
        // symbol-less frames so depth is preserved.
        let addressStart = line.index(bracket.lowerBound, offsetBy: 2)
        let address = String(line[addressStart..<line.index(before: line.endIndex)])

        return StackFrame(
            file: file,
            lineNumber: 0,
            method: symbol.isEmpty ? address : symbol
        )
    }
}
