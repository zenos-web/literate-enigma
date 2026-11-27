import Foundation
import XCTest
@testable import TDSCarKitCore

/// Wire fixtures are from pinned maibms tests; fabricated vectors are labelled synthetic.
final class MultibrandBMSTests: XCTestCase {
    private func bytes(_ hex: String) -> Data { Data(BMSReadOnlyProtocol.hex(hex.replacingOccurrences(of:" ",with:""))!) }
    private func fixture(_ name:String)->Data {bytes(bmsWireFixtures[name]!)}
    private func fragments(_ parser:BMSReadOnlyProtocol,_ data:Data,at time:Double)->[ANTBMSReading] {
        data.flatMap { parser.append(Data([$0]),now:time) }
    }
    private func jbdResponse(_ command:UInt8,_ payload:[UInt8])->Data {
        let body=[UInt8(0),UInt8(payload.count)]+payload
        let sum=body.reduce(UInt16(0)){$0 &+ UInt16($1)},crc:UInt16=0 &- sum
        return Data([0xdd,command]+body+[UInt8(crc>>8),UInt8(truncatingIfNeeded:crc),0x77])
    }
    private func modbus(_ payload:[UInt8],address:UInt8=1)->Data {
        Data(BMSReadOnlyProtocol.withCRC([address,3,UInt8(payload.count)]+payload))
    }
    private func setLE16(_ b:inout [UInt8],_ index:Int,_ value:Int){b[index]=UInt8(truncatingIfNeeded:value);b[index+1]=UInt8(truncatingIfNeeded:value>>8)}
    private func setLE32(_ b:inout [UInt8],_ index:Int,_ value:UInt32){for i in 0..<4{b[index+i]=UInt8(truncatingIfNeeded:value>>(i*8))}}
    private func setBE16(_ b:inout [UInt8],_ index:Int,_ value:Int){b[index]=UInt8(truncatingIfNeeded:value>>8);b[index+1]=UInt8(truncatingIfNeeded:value)}

    func testBrandNamesAndWeakServiceHintsDoNotSelectANTForUnknownDevice() {
        for (name,family) in [("ANT@BLE",BMSFamily.ant),("YY-NiuM",.yanyang),("BT372",.yanyang),("JBD001",.jbd),("JK-BMS",.jikong),("BlueBabe123",.lanbao)] {
            XCTAssertEqual(BMSFamily.identify(name:name),family,name)
        }
        XCTAssertNil(BMSFamily.identify(name:"UART",services:["FFE0"]))
        XCTAssertNil(BMSFamily.identify(name:"UART",services:["6E400001-B5A3-F393-E0A9-E50E24DCCA9E"]))
        XCTAssertNil(BMSFamily.identify(name:"CJ01TEST",services:["FF00"]))
        XCTAssertEqual(BMSFamily.identify(name: "彦阳001"), .yanyang)
        XCTAssertEqual(BMSFamily.identify(name: "极空001"), .jikong)
        XCTAssertEqual(BMSFamily.identify(name: "嘉佰达001"), .jbd)
        XCTAssertEqual(BMSFamily.identify(name:"",services:["FF00"]),.jbd)
        XCTAssertEqual(BMSFamily.identify(name:"",services:["FFE0"],manufacturerID:0x0b65),.jikong)
        XCTAssertNil(BMSFamily.identify(name:"",services:[],manufacturerID:0x0b65))
        XCTAssertEqual(BMSFamily.identify(name:"ANTnamed",services:["FF00"]),.ant)
    }
    func testReadWhitelistAndSingleInFlightRequestForEverySupportedFamily() throws {
        for family in BMSFamily.allCases where family.supportsGATT {
            let p=BMSReadOnlyProtocol(family:family)
            let first=try XCTUnwrap(p.nextRequest(now:0),family.title)
            XCTAssertTrue(BMSReadOnlyProtocol.permits(first,family:family))
            XCTAssertNil(p.nextRequest(now:0.1))
            XCTAssertNotNil(p.nextRequest(now:4))
            XCTAssertFalse(BMSReadOnlyProtocol.permits(Data([0xdd,0x5a,3,0,0xff,0xfd,0x77]),family:family))
        }
        XCTAssertEqual(BMSReadOnlyProtocol(family:.jbd).nextRequest(now:0),bytes("DDA50300FFFD77"))
        XCTAssertEqual(BMSReadOnlyProtocol(family:.jikong).nextRequest(now:0),bytes("AA5590EB97000000000000000000000000000011"))
        XCTAssertEqual(BMSReadOnlyProtocol(family:.yanyang).nextRequest(now:0),bytes("0103003F00047405"))
    }
    func testJBDPublishedBasicFrameAndPayloadTerminatorAreDecoded() throws {
        let p=BMSReadOnlyProtocol(family:.jbd);_ = p.nextRequest(now:0)
        let reading=try XCTUnwrap(fragments(p,bytes("DD03001D0618FEE101F201F4002A2C7C00000000000080640304030B8B0B8A0B84F88477"),at:0.2).last)
        XCTAssertEqual(reading.voltage,15.6,accuracy:0.001)
        XCTAssertEqual(reading.current,2.87,accuracy:0.001)
        XCTAssertEqual(reading.stateOfCharge,100)
        XCTAssertEqual(reading.capacityAh,5,accuracy:0.001)
        XCTAssertEqual(reading.temperatures.compactMap{$0}.first!,22.4,accuracy:0.001)
        XCTAssertEqual(p.nextRequest(now:1),bytes("DDA50400FFFC77"))
        XCTAssertTrue(p.append(jbdResponse(4,[0x0c,0x77,0x0c,0x78]),now:1.1).isEmpty)
        XCTAssertEqual(p.nextRequest(now:2),bytes("DDA50500FFFB77"))
        XCTAssertTrue(p.append(jbdResponse(5,Array("JBD test".utf8)),now:2.1).isEmpty)
        _ = p.nextRequest(now:3)
        let next=try XCTUnwrap(p.append(bytes("DD03001D0618FEE101F201F4002A2C7C00000000000080640304030B8B0B8A0B84F88477"),now:3.1).last)
        XCTAssertEqual(next.cells.compactMap{$0},[3.191,3.192])
        XCTAssertEqual(next.extraDetails["型号"],"JBD test")
    }
    func testJBDRejectsCorruptionAndPreservesRealZeroSOCAndCurrent() throws {
        let p=BMSReadOnlyProtocol(family:.jbd);_ = p.nextRequest(now:0)
        var bad=[UInt8](bytes("DD03001D0618FEE101F201F4002A2C7C00000000000080640304030B8B0B8A0B84F88477"));bad[8]^=1
        XCTAssertTrue(p.append(Data(bad),now:0.2).isEmpty)
        var payload=[UInt8](repeating:0,count:23);payload[0]=0x14;payload[1]=0x50;payload[21]=16
        let value=try XCTUnwrap(p.append(jbdResponse(3,payload),now:0.3).last)
        XCTAssertEqual(value.stateOfCharge,0);XCTAssertEqual(value.current,0)
        XCTAssertEqual(ANTBMSCardConfiguration.Field.charge.text(value),"0%")
    }
    func testJBDOptionalDirectLoginOnlyUsesSuppliedPassword() throws {
        let p=BMSReadOnlyProtocol(family:.jbd,password:"654321")
        _ = p.nextRequest(now:0)
        let login=try XCTUnwrap(p.nextRequest(now:4))
        XCTAssertEqual(Array(login)[0..<4],[0xff,0xaa,0x15,6])
        XCTAssertEqual(String(decoding:login.dropFirst(4).dropLast(),as:UTF8.self),"654321")
        XCTAssertTrue(BMSReadOnlyProtocol.permits(login,family:.jbd))
        XCTAssertTrue(p.append(Data([0xff,0xaa,0x15,1,0,0x16]),now:4.1).isEmpty)
        XCTAssertEqual(p.nextRequest(now:5),bytes("DDA50300FFFD77"))
        let noPassword=BMSReadOnlyProtocol(family:.jbd)
        _ = noPassword.nextRequest(now:0)
        XCTAssertEqual(noPassword.nextRequest(now:4),bytes("DDA50300FFFD77"))
    }
    func testJK02Captured24And32CellLayoutsAndFragmentation() throws {
        for key in ["JK02_24S","JK02_32S","JK02_32S_v15"] {
            let p=BMSReadOnlyProtocol(family:.jikong);_ = p.nextRequest(now:0)
            XCTAssertTrue(fragments(p,fixture(key+"_dev"),at:0.1).isEmpty)
            XCTAssertEqual(p.nextRequest(now:2),bytes("AA5590EB96000000000000000000000000000010"))
            let value=try XCTUnwrap(fragments(p,fixture(key+"_cell"),at:2.1).last,key)
            XCTAssertTrue(value.available.contains("current"));XCTAssertTrue(value.available.contains("charge"))
            XCTAssertGreaterThan(value.cells.compactMap{$0}.count,4)
            XCTAssertGreaterThan(value.voltage,10)
            XCTAssertEqual(value.family,.jikong)
        }
    }
    func testJK04CapturedFramesNeverInventCurrentSOCOrCapacity() throws {
        let p=BMSReadOnlyProtocol(family:.jikong);_ = p.nextRequest(now:0)
        _ = p.append(fixture("JK04_device_info"),now:0.1)
        _ = p.nextRequest(now:2)
        _ = p.append(fixture("JK04_settings"),now:2.1)
        let value=try XCTUnwrap(fragments(p,fixture("JK04_cell"),at:2.2).last)
        XCTAssertEqual(value.cells.compactMap{$0}.count,16)
        XCTAssertEqual(value.voltage,value.cells.compactMap{$0}.reduce(0,+),accuracy:0.0001)
        for field in ["current","power","charge","capacity"]{XCTAssertFalse(value.available.contains(field))}
        XCTAssertEqual(ANTBMSCardConfiguration.Field.charge.text(value),"--%")
        XCTAssertEqual(ANTBMSCardConfiguration.Field.current.text(value),"--A")
        var statistics=ANTBMSSessionStatistics();statistics.append(.init(reading:value,uptime:10),now:10)
        XCTAssertNil(statistics.firstCharge);XCTAssertNil(statistics.peakAbsoluteCurrent);XCTAssertNil(statistics.peakAbsolutePower)
        XCTAssertNotNil(statistics.minimumVoltage)
    }
    func testJKRejectsBadChecksumAndAmbiguousLayouts() {
        let p=BMSReadOnlyProtocol(family:.jikong);_ = p.nextRequest(now:0)
        _ = p.append(fixture("JK02_32S_dev"),now:0.1);_ = p.nextRequest(now:2)
        var bad=fixture("JK02_32S_cell");bad[10]^=1
        XCTAssertTrue(p.append(bad,now:2.1).isEmpty)
        var empty=[UInt8](repeating:0,count:300);empty.replaceSubrange(0..<5,with:[0x55,0xaa,0xeb,0x90,2]);empty[299]=empty.prefix(299).reduce(0,&+)
        XCTAssertTrue(p.append(Data(empty),now:2.2).isEmpty)
    }
    func testYanYangCapturedBFramesProduceKnownValues() throws {
        let p=BMSReadOnlyProtocol(family:.yanyang);_ = p.nextRequest(now:0)
        _ = p.append(fixture("YY_PROFILE"),now:0.1)
        XCTAssertEqual(p.nextRequest(now:1),bytes("01030001004F55FE"))
        let summary=try XCTUnwrap(fragments(p,fixture("YY_REAL_SUMMARY"),at:1.1).last)
        XCTAssertEqual(summary.voltage,49.506,accuracy:0.001)
        XCTAssertEqual(summary.current,0.57,accuracy:0.001)
        XCTAssertFalse(summary.available.contains("charge"))
        XCTAssertEqual(p.nextRequest(now:2),bytes("01030050005045E7"))
        let status=try XCTUnwrap(fragments(p,fixture("YY_REAL_STATUS"),at:2.1).last)
        XCTAssertEqual(status.stateOfCharge,72);XCTAssertEqual(status.capacityAh,68)
        XCTAssertEqual(status.cells.count,13);XCTAssertEqual(status.cells[0]!,3.808,accuracy:0.001)
        XCTAssertEqual(status.mosTemperature,23)
        XCTAssertEqual(status.temperatures.compactMap{$0},[22,21])
    }
    func testYanYangLegacyASyntheticDoesNotInventSOCOrCurrentDirection() throws {
        let p=BMSReadOnlyProtocol(family:.yanyang);_ = p.nextRequest(now:0)
        _ = p.append(modbus([UInt8](repeating:0,count:8)),now:0.1)
        XCTAssertEqual(Array(try XCTUnwrap(p.nextRequest(now:1)))[4..<6],[0,47])
        var main=[UInt8](repeating:0,count:94);main[12]=4;main[13]=2
        setBE16(&main,22,16000);setBE16(&main,24,0)
        for i in 0..<4{setBE16(&main,44+i*2,4000)}
        main[80]=60;main[81]=61
        let value=try XCTUnwrap(p.append(modbus(main),now:1.1).last)
        XCTAssertEqual(value.voltage,16);XCTAssertEqual(value.cells.compactMap{$0},[4,4,4,4])
        XCTAssertFalse(value.available.contains("charge"));XCTAssertFalse(value.available.contains("current"))
    }
    func testYanYangFallbackProbeAndAddressDiscoveryAreReadOnly() throws {
        let p=BMSReadOnlyProtocol(family:.yanyang)
        for time in [0.0,4,8] {XCTAssertTrue(BMSReadOnlyProtocol.permits(try XCTUnwrap(p.nextRequest(now:time)),family:.yanyang))}
        let address=try XCTUnwrap(p.nextRequest(now:12))
        XCTAssertEqual(Array(address.prefix(6)),[0,3,0,0,0,1])
        _ = p.append(modbus([7,0],address:7),now:12.1)
        let next=try XCTUnwrap(p.nextRequest(now:13));XCTAssertEqual(next.first,7)
    }
    private func lanbao(_ payload:[UInt8],table:UInt8)->Data {
        var header:[UInt8]=[0xfa,0x50,0x28,0xa0,0x15,0,9]+[UInt8](repeating:6,count:6)+[table,0,UInt8(payload.count)]
        header+=payload
        return Data(BMSReadOnlyProtocol.withCRC(header,polynomial:0xc328,bigEndian:true)+[0xe5])
    }
    func testLanbaoSyntheticDualTablePreservesDeltaWithoutInventingCells() throws {
        let p=BMSReadOnlyProtocol(family:.lanbao,password:"123456")
        let first=try XCTUnwrap(p.nextRequest(now:0))
        XCTAssertEqual(Array(first)[7..<13],[1,2,3,4,5,6])
        XCTAssertTrue(BMSReadOnlyProtocol.permits(first,family:.lanbao))
        var payload=[UInt8](repeating:0,count:111)
        setBE16(&payload,0,8280);setBE16(&payload,6,780);payload[14]=20
        setBE16(&payload,82,4100);setBE16(&payload,84,4094);setBE16(&payload,86,6)
        let reading=try XCTUnwrap(fragments(p,lanbao(payload,table:1),at:0.1).last)
        XCTAssertEqual(reading.voltage,82.8);XCTAssertEqual(reading.stateOfCharge,78)
        XCTAssertEqual(reading.cellDelta!,0.006,accuracy:0.0001);XCTAssertTrue(reading.cells.isEmpty)
        XCTAssertNil(reading.stateOfHealth);XCTAssertNil(reading.mosTemperature)
        _ = p.nextRequest(now:1)
        var bad=lanbao(payload,table:1);bad[20]^=1
        XCTAssertTrue(p.append(bad,now:1.1).isEmpty)
    }
    func testSupportedScopeAndExplicitFamilyOverrideStayStable() {
        XCTAssertEqual(Set(BMSFamily.allCases.map(\.rawValue)), ["ant", "yanyang", "jikong", "lanbao", "jbd", "luxing"])
        XCTAssertEqual(BMSSelectionPolicy.family(saved: "jbd", inferred: .ant), .jbd)
        XCTAssertNil(BMSSelectionPolicy.family(saved: "removed", inferred: .ant))
        XCTAssertEqual(BMSSelectionPolicy.family(saved: nil, inferred: .luxing), .luxing)
        XCTAssertNil(BMSFamily.identify(name: "unknown", services: ["FFE0"]))
    }
    func testHexCredentialsRejectUnicodeWithoutOutOfBoundsAccess() {
        for value in ["a\u{301}b", "\u{1F600}a", "01GG", "A", String(repeating: "00", count: 1025)] {
            XCTAssertNil(BMSReadOnlyProtocol.hex(value))
        }
        XCTAssertEqual(BMSReadOnlyProtocol.hex("001aFF"), [0, 26, 255])
    }
    func testEveryFamilyUsesItsOwnCardLabelAndMissingFieldsStayUnknown() {
        for family in BMSFamily.allCases {
            var values = BMSValues(); values.soc = 0
            let reading = values.reading(family)
            let lines = ANTBMSCardConfiguration().lines(for: reading)
            XCTAssertTrue(lines[0].hasPrefix(family.shortName + "  0%"))
            XCTAssertEqual(ANTBMSCardConfiguration.Field.voltage.text(reading), "--V")
            XCTAssertEqual(ANTBMSCardConfiguration.Field.current.text(reading), "--A")
            XCTAssertEqual(ANTBMSCardConfiguration.Field.power.text(reading), "--W")
            var statistics = ANTBMSSessionStatistics()
            XCTAssertTrue(statistics.append(.init(reading: reading, uptime: 1), now: 1))
            XCTAssertEqual(statistics.firstCharge, 0)
            XCTAssertNil(statistics.minimumVoltage)
            XCTAssertNil(statistics.peakAbsoluteCurrent)
            XCTAssertNil(statistics.peakAbsolutePower)
        }
    }
    func testMalformedNoiseIsBoundedForAllParsers() {
        for family in BMSFamily.allCases where family.supportsGATT {
            let p=BMSReadOnlyProtocol(family:family);_ = p.nextRequest(now:0)
            XCTAssertTrue(p.append(Data(repeating:0xff,count:20000),now:0.1).isEmpty)
            XCTAssertLessThanOrEqual(p.buffer.count,4096)
        }
    }
}

// Captures from maibms tests at 6bbb5d6; JK info sanitized to model/version only.
// JK02 wire source: patman15/aiobmsble; JK04: syssi/esphome-jk-bms issue 213. YY: NiuHelper.
private let bmsWireFixtures: [String:String] = [
    "JK02_24S_dev": "55aaeb9003794a4b2d4232413230533230500000000031302e584700000031302e3038000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f9",
    "JK02_24S_cell": "55aaeb9002c8ee0cf20cf10cf00cf00cec0cf00ced0ced0ced0ced0cf00cf10ced0cee0ced0c00000000000000000000000000000000ffff0000ef0c05000109360037003900380037003700350041004200360037003a00380034003600370000000000000000000000000000000000000000000000ebce0000c70d020019090000b500ba00e4000000020000385dba0100101503003c000000a465b9006400d9028be86c030101b30600000000000000000000000007000100000023040b0000009f19404000000000e2040000000000010003000083d53700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000bd",
    "JK02_32S_dev": "55aaeb9003a34a4b5f4232413853323050000000000031312e584100000031312e34380000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002b",
    "JK02_32S_cell": "55aaeb9002adf30cf30cf30cf00cf10cf00cf10cf10c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ff000000f20c03000007380037003600370036003700360037000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003601000000008d67000060db020069e4ffff1c0124010000000000000044802c02005034030015000000bc624400640000001ef3680001010000000000000000000000000000ff0001000000f1030000230029b43f40000000005a0a00000001000100060000ef3d080400000000360100000000f103643967001a0000008051010000000000000000000000000001feff7fdc0f01008003000000b4",
    "JK02_32S_v15_dev": "55aaeb9003214a4b5f50423241313653323050000000313541000000000031352e3338000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a9",
    "JK02_32S_v15_cell": "55aaeb9002ac050dfe0cfe0c010d010dfd0cfb0c010dfc0cfb0cfe0cfb0cf80cfb0cfb0c090d0000000000000000000000000000000000000000000000000000000000000000ffff0000ff0c10000f0c40003d0040003d0041003f0041003e0041003e0041003d0040003e0041003f000000000000000000000000000000000000000000000000000000000000000000810000000000e8cf00004ae41900897c000086008000000000000000001986c00000400d030009000000b15f1c00640000008c4c760101010000000000000000000000000000ff0001000000050452000000d44e404000000000ca1400000001010100060000ea67000000000000cd00c300bf00bd03287f030a1d0000008051010000000100a50202000000000000feff7fdc2f0101b0cf070000bb",
    "JK04_cell": "55aaeb9002721544544087fb54403b81544087fb5440d96c5440c3d25440775854404b2455403b81544061be54409d95544061be54403b815440e90f55409d955440d96c54400000000000000000000000000000000000000000000000000000000000000000f732993de93ea13de47c9d3d8a099a3d70909a3d02b2923d5b82943d042d933dfa3c923d66eb933d883a933d5224973de653983d039a953dd965923d11f49a3d0000000000000000000000000000000000000000000000000000000000000000000000006c8b54400072373c00000000ffff0000070202013c5c26c000000000000000806d914a4000000000253b5a0000000000000000000000000000000000d002d0020000000000000000000003000000000000000000ea0509000098913f0078d53f001e",
    "JK04_settings": "55aaeb9001720000803f00000000000000000000000000000000000000000000000010000000cdcc4c400000000000000000000000000000000000000000000000000000000000000000c91e42400000000000000000000000000000000000000000000088409a9959406f12033c0000904001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006f",
    "JK04_device_info": "55aaeb9003724a4b2d42354132345300000000000000382e580000000000382e302e334d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000024",
    "YY_PROFILE": "0103085342444d0000000091b0",
    "YY_REAL_SUMMARY": "01039E65005911010167E273A3010059592D42435531332D4E49552D4D00000000000000000000000059592D42435531332D4E49552D4D000000000000000000000000000000000000000000006500E907031959592D4E69754D2D37334133313032340100050000000002010003000601090F46000300FF07FF0000006D8E5342444D1903010E27330000C37DAD02C12F9C02010000000D0062C10000390000006348",
    "YY_REAL_STATUS": "0103A01900E00EE00EE00EE00EE00EE00EE00EE10EE00EE00EE00EE00EE00E000000000000000000000000000000000000000000000000F401881300002D0FEB0E07013F3D3E3D0000003E3D000100A802860248611700000088010B1400000000003F93005401F1FD000025FF000000000000000000000000000000003C0F140004100000000000000000000007000000E41953024008020000000000000000000000BC05",
]
