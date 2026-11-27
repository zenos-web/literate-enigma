import XCTest
@testable import TDSCarKitCore

final class ANTBMSSessionStatisticsTests: XCTestCase {
    private func sample(at uptime: TimeInterval, voltage: Double = 82, charge: Int = 78,
                        current: Double = -10, power: Int = -820,
                        temperatures: [Double?] = [14], cells: [Double?] = [4.1, 4.106]) -> ANTBMSSample {
        let reading = ANTBMSReading(voltage: voltage, current: current, power: power, stateOfCharge: charge,
            stateOfHealth: nil, stateCode: 4, capacityAh: 170, remainingAh: 130, cells: cells,
            temperatures: temperatures, mosTemperature: nil, protectionBits: 0, warningBits: 0)
        return ANTBMSSample(reading: reading, uptime: uptime)
    }

    func testDuplicatesStaleFramesClockReversalAndOutagesDoNotCountAsRidingTime() {
        var statistics = ANTBMSSessionStatistics()
        XCTAssertTrue(statistics.append(sample(at: 100), now: 100))
        XCTAssertFalse(statistics.append(sample(at: 100), now: 101))
        XCTAssertFalse(statistics.append(sample(at: 99), now: 101))
        XCTAssertFalse(statistics.append(sample(at: 101), now: 110))
        XCTAssertTrue(statistics.append(sample(at: 102), now: 102))
        XCTAssertTrue(statistics.append(sample(at: 200), now: 200))
        XCTAssertEqual(statistics.sampleCount, 3)
        XCTAssertEqual(statistics.sampledSeconds, 2)
    }

    func testStatisticsPreserveSocRangeAndSignedCurrentMagnitude() throws {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100), now: 100)
        statistics.append(sample(at: 101, voltage: 80, charge: 75, current: 12, power: 960,
            temperatures: [nil, 28], cells: [4.0, nil, 4.02]), now: 101)
        XCTAssertEqual(statistics.firstCharge, 78)
        XCTAssertEqual(statistics.lastCharge, 75)
        XCTAssertEqual(statistics.minimumVoltage, 80)
        XCTAssertEqual(statistics.maximumVoltage, 82)
        XCTAssertEqual(statistics.peakAbsoluteCurrent, 12)
        XCTAssertEqual(statistics.peakAbsolutePower, 960)
        XCTAssertEqual(statistics.maximumTemperature, 28)
        XCTAssertEqual(try XCTUnwrap(statistics.maximumCellDelta), 0.02, accuracy: 0.000001)
        let restored = try JSONDecoder().decode(ANTBMSSessionStatistics.self, from: JSONEncoder().encode(statistics))
        XCTAssertEqual(restored, statistics)
    }

    func testMissingSensorsStayUnknownInSummary() {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100, temperatures: [nil], cells: [nil]), now: 100)
        XCTAssertNil(statistics.maximumTemperature)
        XCTAssertNil(statistics.maximumCellDelta)
    }

    func testTrendIsBoundedWithoutDiscardingWholeSessionStatistics() {
        var statistics = ANTBMSSessionStatistics()
        for index in 0..<1000 { statistics.append(sample(at: Double(index)), now: Double(index)) }
        XCTAssertEqual(statistics.sampleCount, 1000)
        XCTAssertEqual(statistics.sampledSeconds, 999)
        XCTAssertEqual(statistics.points.count, 120)
        XCTAssertGreaterThan(statistics.points.first?.elapsed ?? 0, 0)
    }

    func testShortVoltageSagBetweenFiveSecondSnapshotsIsPreserved() throws {
        var statistics = ANTBMSSessionStatistics()
        for (second, voltage) in [86.93, 86.5, 83.67, 85.5, 85.06, 86.0].enumerated() {
            statistics.append(sample(at: Double(second), voltage: voltage), now: Double(second))
        }
        XCTAssertEqual(statistics.points.count, 2)
        let interval = try XCTUnwrap(statistics.points.first)
        XCTAssertEqual(interval.minimumVoltage, 83.67)
        XCTAssertEqual(interval.maximumVoltage, 86.93)
        XCTAssertEqual(interval.voltage, 85.06)
        XCTAssertEqual(interval.lastElapsed, 4)
        XCTAssertEqual(statistics.points.map(\.lowerVoltage).min(), statistics.minimumVoltage)
        XCTAssertEqual(statistics.points.map(\.upperVoltage).max(), statistics.maximumVoltage)
        XCTAssertEqual(statistics.points.last?.voltage, 86.0)
        XCTAssertEqual(statistics.points.last?.latestElapsed, 5)
    }

    func testOutageStartsNewSegmentEvenWhenItIsShorterThanOldPlotThreshold() throws {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100), now: 100)
        statistics.append(sample(at: 106, voltage: 80), now: 106)
        XCTAssertEqual(statistics.points.count, 2)
        XCTAssertEqual(statistics.points.last?.startsSegment, true)
        XCTAssertEqual(statistics.sampledSeconds, 0)
        statistics.append(sample(at: 107, voltage: 81), now: 107)
        XCTAssertEqual(statistics.points.count, 2)
        XCTAssertEqual(statistics.points.last?.minimumVoltage, 80)
        XCTAssertEqual(statistics.points.last?.startsSegment, true)
        XCTAssertEqual(statistics.sampledSeconds, 1)
    }

    func testOldRecordRemainsReadableWithoutInventingLostExtrema() throws {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100, voltage: 86.93), now: 100)
        statistics.append(sample(at: 102, voltage: 83.67), now: 102)
        statistics.append(sample(at: 105, voltage: 85.06), now: 105)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(statistics)) as? [String: Any])
        json["points"] = [["elapsed": 0.0, "voltage": 86.93], ["elapsed": 5.0, "voltage": 85.06]]
        let old = try JSONDecoder().decode(ANTBMSSessionStatistics.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.minimumVoltage, 83.67)
        XCTAssertNil(old.points.first?.minimumVoltage)
        XCTAssertEqual(old.points.map(\.lowerVoltage).min(), 85.06)
        XCTAssertEqual(old.points.last?.latestElapsed, 5)
        XCTAssertEqual(try JSONDecoder().decode(ANTBMSSessionStatistics.self,
            from: JSONEncoder().encode(old)), old)
        XCTAssertTrue(old.voltageCSV.contains("0.000,0.000,,,86.930,,legacy_sample\r\n"))
        XCTAssertFalse(old.voltageCSV.contains("83.670"), "Lost historical extrema cannot be assigned to a CSV interval")
    }

    func testCSVIncludesIntervalExtremaAndOutageBoundaries() {
        var statistics = ANTBMSSessionStatistics()
        statistics.append(sample(at: 100, voltage: 86.93), now: 100)
        statistics.append(sample(at: 102, voltage: 83.67), now: 102)
        statistics.append(sample(at: 104, voltage: 85.06), now: 104)
        statistics.append(sample(at: 110, voltage: 86), now: 110)
        let csv = statistics.voltageCSV
        XCTAssertTrue(csv.contains("0.000,4.000,83.670,86.930,85.060,true,interval\r\n"))
        XCTAssertTrue(csv.contains("10.000,10.000,86.000,86.000,86.000,true,interval\r\n"))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 3)
    }

    func testEmptyCSVHasOnlyTheHeaderAndLongSessionsExportOnlyRetainedIntervals() {
        var statistics = ANTBMSSessionStatistics()
        XCTAssertEqual(statistics.voltageCSV.components(separatedBy: "\r\n").count, 2)
        for index in 0..<1000 { statistics.append(sample(at: Double(index)), now: Double(index)) }
        let rows = statistics.voltageCSV.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 121)
        XCTAssertTrue(rows[1].hasPrefix("400.000,"))
        XCTAssertFalse(rows[1].hasPrefix("0.000,"))
    }
}
