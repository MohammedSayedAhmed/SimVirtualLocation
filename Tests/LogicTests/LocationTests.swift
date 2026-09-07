import XCTest
@testable import SimVLLogic

/// Saved locations are persisted JSON, so both rules here govern data already on disk:
/// identity had to stop being derived from the coordinates, and old records that predate
/// the stored id still have to decode.
final class LocationTests: XCTestCase {

    func testTwoPointsAtTheSamePlaceAreNotTheSameLocation() {
        // The id used to be "\(latitude)_\(longitude)", so these two collided: deleting
        // one deleted both, and renaming one renamed whichever came first.
        let home = Location(name: "Home", latitude: 25.3, longitude: 51.4)
        let office = Location(name: "Office", latitude: 25.3, longitude: 51.4)

        XCTAssertNotEqual(home.id, office.id)

        var saved = [home, office]
        saved.removeAll { $0.id == home.id }

        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.name, "Office")
    }

    func testRecordsSavedBeforeIdsExistedStillDecode() throws {
        // Exactly what UserDefaults and any exported file hold from earlier versions.
        let legacy = Data("""
        [{"name":"Old point","latitude":25.3,"longitude":51.4}]
        """.utf8)

        let decoded = try JSONDecoder().decode([Location].self, from: legacy)

        XCTAssertEqual(decoded.count, 1, "a missing id must not fail the decode and empty the list")
        XCTAssertEqual(decoded[0].name, "Old point")
        XCTAssertEqual(decoded[0].latitude, 25.3)
        XCTAssertEqual(decoded[0].longitude, 51.4)
    }

    func testTwoLegacyRecordsAtOnePlaceGetDistinctIdentities() throws {
        let legacy = Data("""
        [{"name":"A","latitude":25.3,"longitude":51.4},
         {"name":"B","latitude":25.3,"longitude":51.4}]
        """.utf8)

        let decoded = try JSONDecoder().decode([Location].self, from: legacy)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertNotEqual(decoded[0].id, decoded[1].id)
    }

    func testIdentitySurvivesASaveAndReload() throws {
        let original = Location(name: "Pinned", latitude: 25.3, longitude: 51.4)

        let reloaded = try JSONDecoder().decode(
            Location.self,
            from: JSONEncoder().encode(original)
        )

        XCTAssertEqual(reloaded.id, original.id, "a reload must not reshuffle saved identities")
    }
}
