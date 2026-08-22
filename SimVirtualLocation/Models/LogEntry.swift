//
//  LogEntry.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.05.2024.
//

import Foundation

struct LogEntry: Identifiable {

    /// A UUID rather than the date. The date was unique in practice, but a lazy list
    /// keys its scroll bookkeeping off these, so a duplicate would start showing up as
    /// misplaced rows rather than staying invisible.
    let id = UUID()

    let date: Date
    let message: String

    /// The timestamp already rendered. Formatting was happening per row per redraw, so
    /// it was paid again for every line every time anything in the app published.
    let stamp: String
}
