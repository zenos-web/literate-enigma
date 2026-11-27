import Foundation
import XCTest
@testable import TDSCarKitCore

final class ANTBMSRideRecordTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
    private func record(id: UUID = UUID(), name: String = "My vehicle", vehicle: UUID? = nil,
                        bms: UUID? = nil, offset: TimeInterval = 0, completed: Bool = true) -> BMSRideRecord {
        BMSRideRecord(id: id, startedAt: now.addingTimeInterval(offset), endedAt: now,
                      vehicleName: name, statistics: ANTBMSSessionStatistics(), completed: completed,
                      vehicleID: vehicle, bmsID: bms, bmsName: bms == nil ? nil : "ANT test")
    }

    private func withStore(_ body: (BMSRideRecordStore) throws -> Void) throws {
        let suite = "CarWithin.BMSRecordsTest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(BMSRideRecordStore(defaults: defaults))
    }

    func testCheckpointsReplaceTheSameRecordAndCompletionKeepsIdentity() throws {
        try withStore { store in
            let id = UUID(), battery = UUID()
            try store.save(record(id: id, bms: battery, completed: false))
            try store.save(record(id: id, bms: battery, completed: false))
            XCTAssertEqual(store.records().count, 1)
            XCTAssertFalse(try XCTUnwrap(store.records().first).completed)
            try store.save(record(id: id, bms: battery))
            let saved = try XCTUnwrap(store.records().first)
            XCTAssertEqual(saved.id, id)
            XCTAssertEqual(saved.bmsID, battery)
            XCTAssertEqual(saved.bmsName, "ANT test")
            XCTAssertTrue(saved.completed)
        }
    }

    func testStoreRetainsTwentyMostRecentlySavedRecordsAndDeletesOnlyRequestedOne() throws {
        try withStore { store in
            let records = (0..<25).map { record(name: "Record \($0)") }
            for record in records { try store.save(record) }
            XCTAssertEqual(store.records().map(\.id), records.suffix(20).reversed().map(\.id))
            try store.remove(records[10].id)
            XCTAssertEqual(store.records().count, 19)
            XCTAssertFalse(store.records().contains { $0.id == records[10].id })
            try store.remove(UUID())
            XCTAssertEqual(store.records().count, 19)
        }
    }

    func testVehicleIdentitySurvivesRenameAndLegacyRecordsUseSavedName() {
        let vehicle = UUID()
        let filter = BMSRecordFilter(vehicleID: vehicle, vehicleName: "Renamed vehicle")
        XCTAssertTrue(filter.matches(record(name: "Old name", vehicle: vehicle)))
        XCTAssertFalse(filter.matches(record(name: "Renamed vehicle", vehicle: UUID())))
        XCTAssertTrue(filter.matches(record(name: "Renamed vehicle")))
        XCTAssertFalse(filter.matches(record(name: "Another legacy vehicle")))
    }

    func testBMSFilterDistinguishesDevicesWithTheSameVehicleName() {
        let battery = UUID()
        let filter = BMSRecordFilter(vehicleName: "My vehicle", bmsID: battery)
        XCTAssertTrue(filter.matches(record(bms: battery)))
        XCTAssertFalse(filter.matches(record(bms: UUID())))
        XCTAssertFalse(filter.matches(record()))
        XCTAssertTrue(BMSRecordFilter().matches(record()))
    }

    func testCurrentRecordIsNotPresentedAsAnInterruptedFragmentOrCompletedRide() {
        let id = UUID(), fragment = record(id: id, completed: false)
        XCTAssertFalse(BMSRecordFilter(completion: .fragments).matches(fragment, activeRecordID: id))
        XCTAssertFalse(BMSRecordFilter(completion: .finished).matches(fragment, activeRecordID: id))
        XCTAssertTrue(BMSRecordFilter(completion: .recording).matches(fragment, activeRecordID: id))
        XCTAssertTrue(BMSRecordFilter(completion: .fragments).matches(fragment))
        XCTAssertFalse(BMSRecordFilter(completion: .recording).matches(fragment))
        XCTAssertTrue(BMSRecordFilter(completion: .finished).matches(record()))
    }

    func testLocalDateFiltersIncludeTheBoundaryDayAndExcludeFutureDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let start = calendar.startOfDay(for: now)
        for (period, days) in [(BMSRecordFilter.Period.today, 0), (.last7Days, 6), (.last30Days, 29)] {
            let filter = BMSRecordFilter(period: period)
            let lower = calendar.date(byAdding: .day, value: -days, to: start)!
            XCTAssertTrue(filter.matches(record(offset: lower.timeIntervalSince(now)), now: now, calendar: calendar))
            XCTAssertFalse(filter.matches(record(offset: lower.timeIntervalSince(now) - 1), now: now, calendar: calendar))
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start)!
            XCTAssertFalse(filter.matches(record(offset: tomorrow.timeIntervalSince(now)), now: now, calendar: calendar))
        }
    }

    func testLegacyRecordWithoutDeviceOrVehicleFieldsRemainsReadable() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as? [String: Any])
        for key in ["vehicleID", "bmsID", "bmsName"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(BMSRideRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.vehicleID)
        XCTAssertNil(restored.bmsID)
        XCTAssertNil(restored.bmsName)
        XCTAssertEqual(restored.vehicleName, "My vehicle")
    }
}
