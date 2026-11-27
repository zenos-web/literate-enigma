import Foundation
import XCTest
@testable import TDSCarKitCore

final class BMSLuXingTests: XCTestCase {
    private func hex(_ value: String) -> Data {
        Data(BMSReadOnlyProtocol.hex(value.replacingOccurrences(of: " ", with: ""))!)
    }
    private func response(_ payload: [UInt8]) -> Data {
        Data(BMSReadOnlyProtocol.withCRC([1, 3, UInt8(payload.count)] + payload))
    }
    private func le16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    private func le32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    private func realtime() -> [UInt8] {
        // Synthetic EM02 layout; source offsets from maibms, not a hardware capture.
        var d = [UInt8](repeating: 0, count: 108)
        d[0] = 4; d[2] = 1; d[3] = 68; d[7] = 2; d[8] = 60; d[9] = 61
        le16(&d, 20, -240); le32(&d, 22, 48000); le32(&d, 26, UInt32(bitPattern: -500))
        for (index, value) in [4200, 4190, 0xffff, 4210].enumerated() { le16(&d, 30 + index * 2, value) }
        le16(&d, 92, 4210); le16(&d, 94, 4190)
        le16(&d, 102, 1000); le16(&d, 104, 1000); d[106] = 80; d[107] = 100
        return d
    }
    private func ready() -> BMSReadOnlyProtocol {
        let parser = BMSReadOnlyProtocol(family: .luxing)
        _ = parser.nextRequest(now: 0)
        _ = parser.append(response([UInt8](repeating: 0, count: 178)), now: 0.1)
        _ = parser.nextRequest(now: 0.5)
        return parser
    }
    private func read(_ payload: [UInt8]) throws -> ANTBMSReading {
        try XCTUnwrap(ready().append(response(payload), now: 0.6).last)
    }
    private func auxiliary(_ parser: BMSReadOnlyProtocol, at time: Double, vendor: UInt8 = 14) {
        _ = parser.nextRequest(now: time)
        var relay = [UInt8](repeating: 0, count: 90)
        relay[0] = 1; relay[1] = 1; relay[50] = vendor
        le32(&relay, 18, 99999) // Different relay-board voltage must not replace 48 V.
        relay.replaceSubrange(51..<55, with: Array("TEST".utf8))
        relay.replaceSubrange(84..<90, with: [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(parser.append(response(relay), now: time + 0.1).isEmpty)
        _ = parser.nextRequest(now: time + 0.5)
        var cycles = [UInt8](repeating: 0, count: 96); le16(&cycles, 0, 42)
        XCTAssertTrue(parser.append(response(cycles), now: time + 0.6).isEmpty)
    }

    func testIdentificationChannelsAndSavedFamily() throws {
        XCTAssertEqual(BMSFamily.identify(name: "em2app-A581", services: ["FF00"]), .luxing)
        XCTAssertNil(BMSFamily.identify(name: "CJ01-EM2APP", services: ["FFE0"]))
        XCTAssertNil(BMSFamily.identify(name: "UART", services: ["FFE0"]))
        XCTAssertEqual(BMSFamily.luxing.title, "陆行电量计")
        XCTAssertEqual(BMSFamily.luxing.channels, [.init("FFE0", "FFE2", "FFE1")])
        XCTAssertEqual(try JSONDecoder().decode(BMSFamily.self, from: JSONEncoder().encode(BMSFamily.luxing)), .luxing)
    }
    func testFourExactReadRequestsAndWhitelist() throws {
        let parser = BMSReadOnlyProtocol(family: .luxing)
        let expected = ["01030FA0005986C6", "01030FFC003606F8", "01031068002D00CB", "010310380030C0D3"]
        for (index, payloadLength) in [178, 108, 90, 96].enumerated() {
            let t = Double(index)
            let frame = try XCTUnwrap(parser.nextRequest(now: t))
            XCTAssertEqual(frame, hex(expected[index]))
            XCTAssertTrue(BMSReadOnlyProtocol.permits(frame, family: .luxing))
            XCTAssertNil(parser.nextRequest(now: t + 0.05))
            let payload = payloadLength == 108 ? realtime() : [UInt8](repeating: 0, count: payloadLength)
            _ = parser.append(response(payload), now: t + 0.1)
        }
        XCTAssertEqual(parser.nextRequest(now: 4), hex(expected[0]))
        for raw in ["010300000034441D", "01060001000119CA", "01030FA000588706", "7EA10100007F"] {
            XCTAssertFalse(BMSReadOnlyProtocol.permits(hex(raw), family: .luxing))
        }
    }
    func testSyntheticRealtimeUnitsDirectionCapacityAndCellIndices() throws {
        let r = try read(realtime())
        XCTAssertEqual(r.family, .luxing)
        XCTAssertEqual(r.voltage, 48, accuracy: 0.001)
        XCTAssertEqual(r.current, -5, accuracy: 0.001)
        XCTAssertEqual(r.power, -240); XCTAssertEqual(r.stateCode, 4)
        XCTAssertEqual(r.stateOfCharge, 80); XCTAssertEqual(r.capacityAh, 100)
        XCTAssertEqual(r.remainingAh, 80); XCTAssertEqual(r.mosTemperature, 28)
        XCTAssertEqual(r.temperatures, [20, 21]); XCTAssertEqual(r.maximumTemperature, 21)
        XCTAssertEqual(r.cells, [4.2, 4.19, nil, 4.21])
        XCTAssertEqual(try XCTUnwrap(r.cellDelta), 0.02, accuracy: 0.000001)
        XCTAssertNil(r.stateOfHealth); XCTAssertFalse(r.available.contains("protection"))
        XCTAssertTrue(r.extraDetails["剩余容量来源"]?.contains("计算值") == true)
    }
    func testPublishedHardwareFrameAndCRC() throws {
        // maibms MeterProtocolTest: EM2APP-A581 capture, 2026-10-15.
        let frame = hex("01 03 6C 14 00 00 00 00 00 00 04 40 40 40 40 00 00 00 00 00 00 40 40 07 00 36 37 01 00 0A 00 00 00 8D 0F 93 0F " +
            "8E 0F 8E 0F 8E 0F 8F 0F 93 0F 94 0F 8F 0F 8E 0F 8E 0F 90 0F 92 0F 8F 0F 90 0F 8E 0F 8F 0F 8E 0F 8E 0F 93 0F 00 " +
            "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 07 94 0F 8D 0F 00 00 00 00 00 00 6A 04 6A 04 53 64 96 0F")
        XCTAssertEqual(Data(BMSReadOnlyProtocol.withCRC(Array(frame.dropLast(2)))), frame)
        let r = try XCTUnwrap(ready().append(frame, now: 0.6).last)
        XCTAssertEqual(r.voltage, 79.67, accuracy: 0.001)
        XCTAssertEqual(r.stateOfCharge, 83); XCTAssertEqual(r.capacityAh, 113)
        XCTAssertEqual(r.remainingAh, 93.79, accuracy: 0.001)
        XCTAssertEqual(r.cells.count, 20); XCTAssertEqual(r.maximumTemperature, 24)
    }
    func testEveryFragmentSplitAndNoiseRecovery() {
        let frame = response(realtime())
        for split in 0...frame.count {
            let parser = ready()
            let a = parser.append(frame.prefix(split), now: 0.6)
            let b = parser.append(frame.dropFirst(split), now: 0.7)
            XCTAssertEqual((a + b).count, 1, "split \(split)")
        }
        let parser = ready()
        let garbage = Data(repeating: 0x55, count: 12000) + Data([1, 3, 7])
        XCTAssertTrue(parser.append(garbage, now: 0.6).isEmpty)
        XCTAssertEqual(parser.append(frame, now: 0.7).count, 1)
        XCTAssertLessThan(parser.buffer.count, 184)
    }
    func testCRCFailureTruncationAndDuplicateDoNotRefresh() {
        let parser = ready(), valid = response(realtime())
        var bad = valid; bad[25] ^= 1
        XCTAssertTrue(parser.append(bad, now: 0.6).isEmpty)
        XCTAssertNotNil(parser.pending)
        XCTAssertEqual(parser.append(valid, now: 0.7).count, 1)
        XCTAssertTrue(parser.append(valid, now: 0.8).isEmpty)
        let partial = ready()
        XCTAssertTrue(partial.append(valid.dropLast(), now: 0.6).isEmpty)
        XCTAssertEqual(partial.append(valid.suffix(1), now: 0.7).count, 1)
    }
    func testMismatchedBlockCannotCompletePendingRealtime() {
        let parser = ready()
        XCTAssertTrue(parser.append(response([UInt8](repeating: 0, count: 96)), now: 0.6).isEmpty)
        XCTAssertNil(parser.nextRequest(now: 0.7))
        XCTAssertEqual(parser.append(response(realtime()), now: 0.8).count, 1)
    }
    func testTimeoutAndExceptionAdvancePastMissingOptionalBlocks() {
        let parser = BMSReadOnlyProtocol(family: .luxing)
        _ = parser.nextRequest(now: 0)
        XCTAssertEqual(parser.nextRequest(now: 3.1), hex("01030FFC003606F8"))
        let exception = Data(BMSReadOnlyProtocol.withCRC([1, 0x83, 2]))
        XCTAssertTrue(parser.append(exception, now: 3.2).isEmpty)
        XCTAssertEqual(parser.nextRequest(now: 3.6), hex("01031068002D00CB"))
        XCTAssertEqual(parser.nextRequest(now: 6.7), hex("010310380030C0D3"))
        XCTAssertEqual(parser.nextRequest(now: 9.8), hex("01030FA0005986C6"))
    }
    func testAuxiliaryMetadataCannotPublishOrReplaceVoltage() throws {
        let parser = ready()
        let first = try XCTUnwrap(parser.append(response(realtime()), now: 0.6).last)
        auxiliary(parser, at: 1)
        _ = parser.nextRequest(now: 2)
        XCTAssertTrue(parser.append(response([UInt8](repeating: 0, count: 178)), now: 2.1).isEmpty)
        _ = parser.nextRequest(now: 2.5)
        let next = try XCTUnwrap(parser.append(response(realtime()), now: 2.6).last)
        XCTAssertEqual(first.voltage, next.voltage)
        XCTAssertEqual(next.extraDetails["中继品牌"], "电岭")
        XCTAssertEqual(next.extraDetails["中继名称"], "TEST")
        XCTAssertEqual(next.extraDetails["中继 MAC"], "01:02:03:04:05:06")
        XCTAssertEqual(next.extraDetails["循环次数"], "42")
        XCTAssertEqual(parser.values.voltage, 48)
        auxiliary(parser, at: 3, vendor: 15)
        _ = parser.nextRequest(now: 4)
        _ = parser.append(response([UInt8](repeating: 0, count: 178)), now: 4.1)
        _ = parser.nextRequest(now: 4.5)
        let changed = try XCTUnwrap(parser.append(response(realtime()), now: 4.6).last)
        XCTAssertEqual(changed.extraDetails["中继品牌"], "锋锐")
    }
    func testOldAuxiliaryMetadataExpiresAndNewSessionHasNone() throws {
        let parser = ready()
        _ = parser.append(response(realtime()), now: 0.6)
        auxiliary(parser, at: 1)
        _ = parser.nextRequest(now: 20)
        _ = parser.append(response([UInt8](repeating: 0, count: 178)), now: 20.1)
        _ = parser.nextRequest(now: 20.5)
        let old = try XCTUnwrap(parser.append(response(realtime()), now: 20.6).last)
        XCTAssertNil(old.extraDetails["中继品牌"]); XCTAssertNil(old.extraDetails["循环次数"])
        XCTAssertNil(try read(realtime()).extraDetails["中继品牌"])
    }
    func testMissingSentinelsClearPreviousFieldsAndKeepSlots() throws {
        let parser = ready()
        var d = realtime()
        le32(&d, 22, 0xffffffff); le32(&d, 26, 0x7fffffff); le16(&d, 20, 32767)
        le16(&d, 102, 0xffff); le16(&d, 92, 0xffff); le16(&d, 94, 0xffff)
        for i in 0..<4 { le16(&d, 30 + i * 2, 0xffff) }
        d[2] = 0; d[7] = 0
        let r = try XCTUnwrap(parser.append(response(d), now: 0.6).last)
        XCTAssertEqual(r.available, ["charge"])
        XCTAssertEqual(r.cells, [nil, nil, nil, nil]); XCTAssertTrue(r.temperatures.isEmpty)
        XCTAssertNil(r.mosTemperature); XCTAssertNil(r.cellDelta)
        XCTAssertEqual(ANTBMSCardConfiguration.Field.voltage.text(r), "--V")
        XCTAssertEqual(ANTBMSCardConfiguration.Field.current.text(r), "--A")
    }
    func testZeroSOCAndCurrentStayValidAndInvalidSOCIsNotClamped() throws {
        var d = realtime(); d[106] = 0; le32(&d, 26, 0); le16(&d, 20, 0)
        let zero = try read(d)
        XCTAssertEqual(zero.stateOfCharge, 0); XCTAssertEqual(zero.remainingAh, 0)
        XCTAssertTrue(zero.available.isSuperset(of: ["charge", "current", "power", "remaining"]))
        XCTAssertEqual(zero.stateCode, 1)
        d[106] = 255
        let missing = try read(d)
        XCTAssertFalse(missing.available.contains("charge")); XCTAssertFalse(missing.available.contains("remaining"))
        le32(&d, 26, 500)
        XCTAssertEqual(try read(d).stateCode, 2)
        le32(&d, 26, 0xffffffff)
        XCTAssertEqual(try read(d).current, -0.01, accuracy: 0.00001)
    }
    func testUnsupportedLayoutAndAbsentTemperatureDoNotInventValues() throws {
        for (offset, value) in [(0, 31), (2, 2), (4, 2), (7, 9)] {
            var d = realtime(); d[offset] = UInt8(value)
            XCTAssertTrue(ready().append(response(d), now: 0.6).isEmpty)
        }
        var d = realtime(); d[3] = 0; d[8] = 0; d[9] = 0
        let r = try read(d)
        XCTAssertNil(r.mosTemperature); XCTAssertNil(r.maximumTemperature)
        XCTAssertEqual(r.temperatures, [nil, nil])
    }
    func testSharedCapabilitiesStatisticsAndCSVUseMeterVoltage() throws {
        var stats = ANTBMSSessionStatistics(), caps = BMSFieldCapabilities(family: .luxing)
        let r = try read(realtime()); caps.observe(r)
        XCTAssertEqual(caps.availability(of: .cellDelta, reading: r), .available)
        XCTAssertEqual(caps.availability(of: .temperature, reading: r), .available)
        XCTAssertTrue(stats.append(ANTBMSSample(reading: r, uptime: 0), now: 0))
        XCTAssertEqual(stats.minimumVoltage, 48); XCTAssertEqual(stats.maximumVoltage, 48)
        XCTAssertEqual(stats.peakAbsoluteCurrent, 5); XCTAssertEqual(stats.peakAbsolutePower, 240)
        XCTAssertTrue(stats.voltageCSV.contains("48.000"))
        XCTAssertFalse(stats.voltageCSV.contains("99.999"))
        XCTAssertTrue(ANTBMSCardConfiguration().lines(for: r).first?.hasPrefix("陆行") == true)
    }
}
