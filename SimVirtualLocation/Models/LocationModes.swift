import Foundation

enum DeviceMode: Int, Identifiable {
    case simulator
    case device

    var id: Int { rawValue }
}

enum PointsMode: Int, Identifiable {
    case single
    case two

    var id: Int { rawValue }
}

enum TransportType: Int, Identifiable {
    case driving
    case walking

    var id: Int { rawValue }
}

/// Which half of the control panel is showing.
///
/// Placing a point and driving a route never overlap, and the controls for one are
/// noise while you are doing the other — so the panel shows one at a time.
enum PanelMode: Int, Identifiable, CaseIterable {
    case place
    case route

    var id: Int { rawValue }
}
