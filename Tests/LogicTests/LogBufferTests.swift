import XCTest
@testable import SimVLLogic

/// The log's two rules exist because of real failures: an unbounded list made the pane
/// quadratic to redraw, and a failure repeating on a timer evicted everything else.
final class LogBufferTests: XCTestCase {

    private func entry(_ message: String, stamp: String = "T0") -> LogEntry {
        LogEntry(date: Date(timeIntervalSince1970: 0), message: message, stamp: stamp)
    }

    func testNewestLineComesFirst() {
        var buffer = LogBuffer()
        buffer.record(entry("first"))
        buffer.record(entry("second"))

        XCTAssertEqual(buffer.entries.map(\.message), ["second", "first"])
    }

    func testOldestLinesFallOffTheEndAtTheLimit() {
        var buffer = LogBuffer(limit: 3)
        for index in 1...5 {
            buffer.record(entry("line \(index)"))
        }

        XCTAssertEqual(buffer.entries.count, 3)
        XCTAssertEqual(buffer.entries.map(\.message), ["line 5", "line 4", "line 3"])
    }

    func testARunOfIdenticalLinesCollapsesToOneCountedLine() {
        // The bug this catches: the first version compared against the DISPLAYED
        // message, which had already been rewritten with a "(2x…)" suffix — so the
        // third arrival no longer matched and started a fresh line. A failure on a
        // timer then filled the buffer at half rate instead of not at all.
        var buffer = LogBuffer(limit: 100)
        for _ in 1...20 {
            buffer.record(entry("simctl failed", stamp: "T1"))
        }

        XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertTrue(buffer.entries[0].message.hasPrefix("simctl failed"))
        XCTAssertTrue(buffer.entries[0].message.contains("20x"))
    }

    func testACollapsedLineKeepsWhenItFirstAppeared() {
        var buffer = LogBuffer()
        buffer.record(entry("repeating", stamp: "FIRST"))
        buffer.record(entry("repeating", stamp: "LATER"))

        XCTAssertEqual(buffer.entries[0].stamp, "FIRST")
        XCTAssertTrue(buffer.entries[0].message.contains("latest LATER"))
    }

    func testADifferentLineBreaksTheRun() {
        var buffer = LogBuffer(limit: 100)
        buffer.record(entry("a"))
        buffer.record(entry("a"))
        buffer.record(entry("b"))
        buffer.record(entry("a"))

        XCTAssertEqual(buffer.entries.count, 3)
        XCTAssertEqual(buffer.entries[0].message, "a")
        XCTAssertEqual(buffer.entries[1].message, "b")
        XCTAssertTrue(buffer.entries[2].message.contains("2x"))
    }

    func testCollapsingDoesNotHideANewFailure() {
        // Collapsing must never cost visibility: a new message after a long run is
        // still recorded, which is the whole reason the cap alone was not enough.
        var buffer = LogBuffer(limit: 100)
        for _ in 1...500 {
            buffer.record(entry("noise"))
        }
        buffer.record(entry("device disconnected"))

        XCTAssertEqual(buffer.entries.count, 2)
        XCTAssertEqual(buffer.entries[0].message, "device disconnected")
    }

    func testClearEmptiesAndResetsTheRun() {
        var buffer = LogBuffer()
        buffer.record(entry("x"))
        buffer.record(entry("x"))
        buffer.clear()
        XCTAssertTrue(buffer.entries.isEmpty)

        // After clearing, the same message starts a fresh line rather than counting on.
        buffer.record(entry("x"))
        XCTAssertEqual(buffer.entries.count, 1)
        XCTAssertEqual(buffer.entries[0].message, "x")
    }

    func testExportIsNewestFirstAndCarriesTimestamps() {
        var buffer = LogBuffer()
        buffer.record(entry("older", stamp: "T1"))
        buffer.record(entry("newer", stamp: "T2"))

        XCTAssertEqual(buffer.exportText, "T2: newer\n\nT1: older")
    }
}
