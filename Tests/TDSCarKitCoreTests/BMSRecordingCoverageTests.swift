import Foundation
import XCTest
@testable import TDSCarKitCore

final class BMSRecordingCoverageTests: XCTestCase {
    private func sample(_ time: Double) -> ANTBMSSample {
        ANTBMSSample(reading: ANTBMSReading(voltage: 82, current: 1, power: 82, stateOfCharge: 80,
            stateOfHealth: nil, stateCode: 4, capacityAh: 100, remainingAh: 80, cells: [],
            temperatures: [], mosTemperature: nil, protectionBits: 0, warningBits: 0), uptime: time)
    }
    func testContinuousDataCoverageUsesRecordingStartAndFinishTimes() {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 100)
        for t in 100...110 { XCTAssertTrue(s.append(sample(Double(t)), now: Double(t))) }
        s.finishRecording(at: 110)
        XCTAssertEqual(s.coverage?.recordingSeconds, 10)
        XCTAssertEqual(s.coverageRatio, 1)
        XCTAssertEqual(s.coverage?.interruptionCount, 0)
        XCTAssertFalse(s.append(sample(111), now: 111))
        s.advanceRecording(to: 200)
        XCTAssertEqual(s.coverage?.recordingSeconds, 10)
    }
    func testInitialWaitingLowersCoverageWithoutInventingDisconnects() {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 0)
        s.advanceRecording(to: 10)
        s.append(sample(10), now: 10); s.append(sample(11), now: 11)
        s.finishRecording(at: 20)
        XCTAssertEqual(s.coverage?.recordingSeconds, 20)
        XCTAssertEqual(s.sampledSeconds, 1)
        XCTAssertEqual(s.coverageRatio!, 0.05, accuracy: 0.00001)
        XCTAssertEqual(s.coverage?.interruptionCount, 1) // Last data expired at 16.
        XCTAssertEqual(s.coverage?.longestInterruption, 4)
    }
    func testOutageStartsAfterFreshnessWindowAndCountsOnceAcrossRepeatedTicks() {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 0); s.append(sample(0), now: 0)
        s.advanceRecording(to: 5)
        XCTAssertEqual(s.coverage?.interruptionCount, 0)
        s.advanceRecording(to: 6); s.advanceRecording(to: 7); s.advanceRecording(to: 8)
        XCTAssertEqual(s.coverage?.interruptionCount, 1)
        XCTAssertEqual(s.coverage?.longestInterruption, 3)
        s.append(sample(10), now: 10)
        XCTAssertEqual(s.coverage?.longestInterruption, 5)
        s.append(sample(11), now: 11)
        s.advanceRecording(to: 17)
        XCTAssertEqual(s.coverage?.interruptionCount, 2)
        XCTAssertEqual(s.sampledSeconds, 1)
    }
    func testBackgroundGapIsDetectedWhenDataReturnsWithoutIntermediateTicks() {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 100)
        s.append(sample(100), now: 100); s.append(sample(130), now: 130)
        XCTAssertEqual(s.coverage?.interruptionCount, 1)
        XCTAssertEqual(s.coverage?.longestInterruption, 25)
        XCTAssertEqual(s.sampledSeconds, 0)
    }
    func testDuplicateStaleAndReversedSamplesCannotImproveCoverage() {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 100); s.append(sample(100), now: 100)
        s.advanceRecording(to: 110)
        XCTAssertFalse(s.append(sample(100), now: 110))
        XCTAssertFalse(s.append(sample(108), now: 110))
        s.advanceRecording(to: 105)
        XCTAssertEqual(s.coverage?.recordingSeconds, 10)
        XCTAssertEqual(s.coverage?.interruptionCount, 1)
        XCTAssertEqual(s.sampleCount, 1)
    }
    func testEmptyRecordingHasNoFakeCoverageAndCanStillTrackWaitTime() {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 0)
        XCTAssertNil(s.coverageRatio)
        s.finishRecording(at: 30)
        XCTAssertEqual(s.coverageRatio, 0)
        XCTAssertEqual(s.coverage?.interruptionCount, 0)
        XCTAssertEqual(s.coverage?.recordingSeconds, 30)
    }
    func testNewCoverageRoundTripAndLegacyMissingCoverageRemainReadable() throws {
        var s = ANTBMSSessionStatistics(); s.startRecording(at: 100)
        s.append(sample(100), now: 100); s.advanceRecording(to: 115)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encoded = try encoder.encode(s)
        XCTAssertEqual(try decoder.decode(ANTBMSSessionStatistics.self, from: encoded), s)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "coverage")
        let legacy = try decoder.decode(ANTBMSSessionStatistics.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.coverage); XCTAssertNil(legacy.coverageRatio)
        XCTAssertEqual(legacy.sampleCount, s.sampleCount)
    }
}
