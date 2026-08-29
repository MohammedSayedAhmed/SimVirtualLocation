import Foundation

/// The log's contents and the rules that govern them.
///
/// Deliberately free of any opinion about display, threading or publishing: those live
/// in `LogStore`. Keeping the rules here means the two behaviours that matter — the cap
/// and the repeat collapse — can be tested directly, which is worth doing because both
/// were written in response to a real failure.
struct LogBuffer {

    /// How many lines are kept. Newest first, so the oldest fall off the end.
    ///
    /// Deliberately generous. At the noisiest polling rate a small cap is a few minutes
    /// of history, and a disconnect from twenty minutes ago is exactly what someone
    /// opens the pane to find.
    static let defaultLimit = 5_000

    private(set) var entries: [LogEntry] = []

    /// The newest line's message before any repeat suffix was added to it.
    ///
    /// Comparing against the displayed message instead is the mistake that made the
    /// first version of this collapse only ever fold one repeat: the moment a line was
    /// rewritten as "… (2x, latest …)" it stopped matching the plain message arriving
    /// next, and a fresh entry was inserted.
    private var newestMessage: String?

    /// How many times the newest line has arrived, so a failure on a timer collapses
    /// into one counted line rather than filling the buffer.
    private var repeats = 0

    let limit: Int

    init(limit: Int = LogBuffer.defaultLimit) {
        self.limit = max(1, limit)
    }

    mutating func record(_ entry: LogEntry) {
        // A failure that repeats on a timer — a missing simctl probed every three
        // seconds, say — would otherwise push everything else out within hours, which
        // is the opposite of what a failure log is for. The line stays and keeps its
        // count instead of being dropped, and keeps the time it first appeared.
        if entry.message == newestMessage, let newest = entries.first {
            repeats += 1
            entries[0] = LogEntry(
                date: entry.date,
                message: "\(entry.message)  (\(repeats + 1)x, latest \(entry.stamp))",
                stamp: newest.stamp
            )
            return
        }

        newestMessage = entry.message
        repeats = 0
        entries.insert(entry, at: 0)

        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }

    mutating func clear() {
        entries.removeAll()
        newestMessage = nil
        repeats = 0
    }

    /// The whole log as text, newest first — what the Copy button puts on the pasteboard.
    var exportText: String {
        entries.map { "\($0.stamp): \($0.message)" }.joined(separator: "\n\n")
    }
}
