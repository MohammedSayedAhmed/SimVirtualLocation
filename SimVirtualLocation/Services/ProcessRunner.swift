import Foundation

struct ProcessRunResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
    /// `true` when the process had to be killed because it outlived its timeout.
    let timedOut: Bool

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Reads one end of a `Pipe` on a background thread for as long as the child writes.
///
/// Draining has to happen *while* the child runs. A pipe buffer is 64 KB: a chatty
/// tool (pymobiledevice3 logs progress on both streams) fills it, blocks forever on
/// `write`, and any `waitUntilExit()` waiting on that child then never returns.
final class PipeDrain {

    private static let queue = DispatchQueue(
        label: "com.simvirtuallocation.pipe-drain",
        qos: .utility,
        attributes: .concurrent
    )

    /// A helper holding a device session can log for hours. Only the tail is ever
    /// useful for diagnosing a failure, so the buffer is bounded.
    private static let maxBufferedBytes = 64 * 1024

    private let lock = NSLock()
    private var buffer = Data()
    private let reachedEOF = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        PipeDrain.queue.async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                buffer.append(chunk)
                if buffer.count > PipeDrain.maxBufferedBytes {
                    buffer.removeFirst(buffer.count - PipeDrain.maxBufferedBytes)
                }
                lock.unlock()
            }
            reachedEOF.signal()
        }
    }

    /// Waits up to `timeout` for the writer to close, then returns everything read so
    /// far. Safe to call more than once, and never blocks past the timeout.
    func collect(timeout: TimeInterval = 3) -> Data {
        if reachedEOF.wait(timeout: .now() + timeout) == .success {
            // Put the signal back so later calls resolve immediately too.
            reachedEOF.signal()
        }
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func text(timeout: TimeInterval = 3) -> String {
        String(decoding: collect(timeout: timeout), as: UTF8.self)
    }
}

extension Process {

    /// Blocks up to `timeout` waiting for the process to exit.
    /// Returns `false` if it is still running when the deadline passes.
    ///
    /// Polls rather than calling `waitUntilExit()`, which has no timeout — a wedged
    /// child would otherwise hang the caller (and the location updates) forever.
    func wait(upTo timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning {
            if Date() >= deadline { return false }
            usleep(20_000) // 20 ms
        }
        return true
    }

    /// Terminates the process, escalating to `SIGKILL` if it ignores `SIGTERM`.
    func terminateNow() {
        guard isRunning else { return }
        terminate()
        if wait(upTo: 2) { return }
        kill(processIdentifier, SIGKILL)
        _ = wait(upTo: 2)
    }
}

/// Runs a configured `Process` to completion and collects stdout/stderr.
enum ProcessRunner {

    /// Ceiling for a single tool invocation. Device tooling that has not answered by
    /// then is wedged, and waiting longer only hides the failure.
    static let defaultTimeout: TimeInterval = 30

    static func run(_ task: Process, timeout: TimeInterval = defaultTimeout) throws -> ProcessRunResult {
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        if task.standardInput == nil {
            task.standardInput = FileHandle.nullDevice
        }

        let outDrain = PipeDrain(outPipe)
        let errDrain = PipeDrain(errPipe)

        try task.run()

        var timedOut = false
        if !task.wait(upTo: timeout) {
            timedOut = true
            task.terminateNow()
        }

        return ProcessRunResult(
            terminationStatus: task.isRunning ? -1 : task.terminationStatus,
            stdout: outDrain.collect(),
            stderr: errDrain.collect(),
            timedOut: timedOut
        )
    }
}
