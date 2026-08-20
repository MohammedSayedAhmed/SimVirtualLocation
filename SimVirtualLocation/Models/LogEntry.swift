//
//  LogEntry.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.05.2024.
//

import Foundation

struct LogEntry: Identifiable {

    var id: Date { date }

    let date: Date
    let message: String

    /// Whether this line is something the user could act on, so the log can default to
    /// showing only those. Most entries are a record of a command that worked.
    var isProblem: Bool {
        let lowered = message.lowercased()
        return lowered.contains("failed")
            || lowered.contains("error")
            || lowered.contains("could not")
            || lowered.contains("not reachable")
            || lowered.contains("no device")
            || lowered.hasPrefix("alert:")
    }
}
