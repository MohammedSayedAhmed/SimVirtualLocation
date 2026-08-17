//
//  LogEntry.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.05.2024.
//

import Foundation

struct LogEntry: Identifiable {

    /// Not the date: keep-alive logging can produce several entries inside the same
    /// timestamp, and duplicate ids break `ForEach` identity.
    let id = UUID()

    let date: Date
    let message: String
}
