import Foundation

/// A place someone saved, by name.
///
/// Deliberately free of SwiftUI so the pure-logic package can compile it: the decoding
/// rule below governs data that has already been written to disk, and getting it wrong
/// empties somebody's saved list.
struct Location: Codable, Identifiable {

    /// An identity of its own, rather than one derived from the coordinates.
    ///
    /// It used to be `"\(latitude)_\(longitude)"`, so every point saved at the same spot
    /// shared one id — and the list's row identity, Delete and Rename all keyed off it.
    /// Deleting one of them deleted all of them, and Rename renamed whichever came first.
    let id: UUID

    let name: String
    let latitude: Double
    let longitude: Double

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Points saved before this field existed have no `id` in their JSON — in
    /// UserDefaults and in any file someone exported. Mint one for them rather than
    /// letting the decode fail, which would silently empty the whole list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
    }
}
