import Foundation

/// Reads the currently live iOS 17+ tunnel from `pymobiledevice3 remote tunneld`.
///
/// The RSD address and port change every time a tunnel is re-established, and a tunnel
/// that went away is the most common reason an iOS 17+ hold dies for good. `tunneld`
/// keeps tunnels up by itself and publishes the live ones over HTTP on localhost, so
/// the app can pick up the new address on its own instead of stranding the device on
/// real GPS until someone pastes it in by hand.
///
/// Start it with:
///
///     sudo python3 -m pymobiledevice3 remote tunneld
enum TunneldDiscovery {

    struct Endpoint: Equatable {
        let address: String
        let port: String
        let udid: String?
    }

    static let defaultURL = URL(string: "http://127.0.0.1:49151/")!

    /// Returns the live tunnel for `preferredUDID`, or any live tunnel, or `nil` when
    /// tunneld is not running. Never throws — a missing tunneld is an ordinary state.
    static func fetch(
        url: URL = defaultURL,
        preferredUDID: String? = nil,
        timeout: TimeInterval = 2
    ) async -> Endpoint? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return nil
        }

        return parse(data, preferredUDID: preferredUDID)
    }

    /// Pulls address/port pairs out of whatever shape tunneld answers with.
    ///
    /// Parsed structurally rather than against one fixed schema: the payload has
    /// changed across pymobiledevice3 releases, and falling back to real GPS because a
    /// key was renamed would defeat the point of reading it at all.
    static func parse(_ data: Data, preferredUDID: String?) -> Endpoint? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var found: [Endpoint] = []
        collect(root, udid: nil, into: &found)

        if let preferredUDID, let match = found.first(where: { $0.udid == preferredUDID }) {
            return match
        }

        return found.first
    }

    // MARK: - Private

    private static func collect(_ node: Any, udid: String?, into found: inout [Endpoint]) {
        if let dictionary = node as? [String: Any] {
            if let endpoint = endpoint(from: dictionary, udid: udid) {
                found.append(endpoint)
            }
            for (key, value) in dictionary {
                // Tunnels are keyed by device identifier, which labels everything under it.
                collect(value, udid: looksLikeIdentifier(key) ? key : udid, into: &found)
            }
        } else if let array = node as? [Any] {
            for value in array {
                collect(value, udid: udid, into: &found)
            }
        }
    }

    private static func endpoint(from dictionary: [String: Any], udid: String?) -> Endpoint? {
        var address: String?
        var port: String?

        for (key, value) in dictionary {
            let name = key.lowercased()
            guard let text = stringValue(value), !text.isEmpty else { continue }

            if name.contains("port") {
                port = text
            } else if name.contains("address") || name.contains("host") {
                address = text
            }
        }

        guard let address, let port else { return nil }

        let identifier = (dictionary["udid"] as? String)
            ?? (dictionary["identifier"] as? String)
            ?? udid

        return Endpoint(address: address, port: port, udid: identifier)
    }

    private static func stringValue(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func looksLikeIdentifier(_ key: String) -> Bool {
        // Modern UDIDs look like 00008030-001A2B3C4D5E802E; older ones are 40 hex chars.
        if key.count == 25, key.contains("-") { return true }
        if key.count == 40, key.allSatisfy({ $0.isHexDigit }) { return true }
        return key.count >= 24 && key.contains("-")
    }
}
