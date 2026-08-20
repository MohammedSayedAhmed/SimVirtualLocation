import AppKit

/// Guards the two ways a live hold gets dropped by accident: quitting the app, and
/// closing its last window. Both end every injection session, and the device is back on
/// real GPS the moment they do.
final class AppDelegate: NSObject, NSApplicationDelegate {

    weak var locationController: LocationController?

    private var isHolding: Bool {
        guard let state = locationController?.holdState else { return false }
        return state != .idle
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isHolding else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quitting drops the simulated location"
        alert.informativeText = "A location is being held right now. The device goes back to its real GPS as soon as SimVirtualLocation quits."
        alert.addButton(withTitle: "Keep holding")
        alert.addButton(withTitle: "Quit anyway")

        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    /// Closing the window must not take the hold with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isHolding
    }
}
