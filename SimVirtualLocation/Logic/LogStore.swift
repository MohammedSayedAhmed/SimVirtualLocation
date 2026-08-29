import Combine
import Foundation

/// The Logs pane's state, kept apart from everything else.
///
/// It used to live on `LocationController` alongside forty other published properties,
/// which meant a log line invalidated the entire window — and, since a log line is
/// written on almost every code path, so did practically everything else. Observing
/// this instead of the controller is what lets the pane redraw for logs and nothing
/// else redraw for logs.
///
/// `LocationController` holds one of these as a plain `let`, so writing to it does not
/// touch the controller's own published state.
final class LogStore: ObservableObject {

    @Published private(set) var entries: [LogEntry] = []

    /// Whether the pane is open. Not persisted: it starts closed each launch, which is
    /// also why the pane costs nothing until someone asks for it.
    @Published var isExpanded = false

    private var buffer: LogBuffer

    init(limit: Int = LogBuffer.defaultLimit) {
        buffer = LogBuffer(limit: limit)
    }

    /// Records a line.
    ///
    /// Safe to call from anywhere: process termination handlers, device discovery and
    /// the scan loop all log, and none of them are on the main thread. The timestamp is
    /// taken at the call rather than on arrival so the hop does not skew it.
    func record(_ message: String) {
        let now = Date()
        let entry = LogEntry(date: now, message: message, stamp: Self.formatter.string(from: now))
        Self.onMain { [weak self] in
            guard let self else { return }
            self.buffer.record(entry)
            self.entries = self.buffer.entries
        }
    }

    func clear() {
        Self.onMain { [weak self] in
            guard let self else { return }
            self.buffer.clear()
            self.entries = self.buffer.entries
        }
    }

    var exportText: String { buffer.exportText }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Runs `work` on the main thread, straight away when already there.
    ///
    /// Every `@Published` write has to land on the main thread. SwiftUI takes a lock to
    /// publish, and a write from a background thread can hold that lock while waiting
    /// for main at the same moment main is waiting for the lock — which freezes the
    /// window with no crash and nothing in the log to say so.
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
