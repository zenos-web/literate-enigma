import Foundation

public struct ANTBMSSessionStatistics: Codable, Equatable {
    public struct Point: Codable, Equatable {
        /// First sample time in this five-second interval; voltage is the latest.
        public let elapsed: TimeInterval
        public let voltage: Double
        /// Optional for compatibility with older records that retained only a snapshot.
        public let minimumVoltage: Double?
        public let maximumVoltage: Double?
        public let lastElapsed: TimeInterval?
        public let startsSegment: Bool?

        public var lowerVoltage: Double { minimumVoltage ?? voltage }
        public var upperVoltage: Double { maximumVoltage ?? voltage }
        public var latestElapsed: TimeInterval { lastElapsed ?? elapsed }
    }
    public private(set) var sampleCount = 0
    public private(set) var firstCharge: Int?
    public private(set) var lastCharge: Int?
    public private(set) var minimumVoltage: Double?
    public private(set) var maximumVoltage: Double?
    public private(set) var peakAbsoluteCurrent: Double?
    public private(set) var peakAbsolutePower: Int?
    public private(set) var maximumTemperature: Double?
    public private(set) var maximumCellDelta: Double?
    public private(set) var sampledSeconds: TimeInterval = 0
    public private(set) var points: [Point] = []
    /// Absent in older records; never reconstruct missing historical coverage from snapshots.
    public private(set) var coverage: BMSRecordingCoverage? = nil
    private var firstUptime: TimeInterval?
    private var lastUptime: TimeInterval?

    public init() {}

    public mutating func startRecording(at uptime: TimeInterval) {
        guard coverage == nil, sampleCount == 0, uptime.isFinite else { return }
        coverage = BMSRecordingCoverage(startedAt: uptime)
    }
    public mutating func advanceRecording(to uptime: TimeInterval) { coverage?.observe(at: uptime) }
    public mutating func finishRecording(at uptime: TimeInterval) { coverage?.finish(at: uptime) }
    public var coverageRatio: Double? {
        guard let coverage, coverage.recordingSeconds > 0 else { return nil }
        return min(1, max(0, sampledSeconds / coverage.recordingSeconds))
    }

    /// Exports the retained trend window, not the original per-frame history.
    /// Missing legacy extrema remain empty rather than presenting a snapshot as an interval range.
    public var voltageCSV: String {
        let locale = Locale(identifier: "en_US_POSIX")
        func number(_ value: Double) -> String { String(format: "%.3f", locale: locale, value) }
        let header = "elapsed_start_s,elapsed_end_s,minimum_voltage_v,maximum_voltage_v,latest_voltage_v,starts_segment,sample_kind"
        let rows = points.map { point in
            [number(point.elapsed), number(point.latestElapsed),
             point.minimumVoltage.map(number) ?? "", point.maximumVoltage.map(number) ?? "",
             number(point.voltage), point.startsSegment.map { $0 ? "true" : "false" } ?? "",
             point.minimumVoltage != nil && point.maximumVoltage != nil ? "interval" : "legacy_sample"]
                .joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\r\n") + "\r\n"
    }

    /// Duplicate callbacks, stale frames and clock reversal cannot add samples.
    @discardableResult
    public mutating func append(_ sample: ANTBMSSample, now: TimeInterval) -> Bool {
        guard sample.isFresh(at: now), lastUptime.map({ sample.uptime > $0 }) ?? true else { return false }
        guard coverage?.isFinished != true else { return false }
        if coverage?.receive(at: sample.uptime) == false { return false }
        coverage?.observe(at: now)
        let followsPrevious = lastUptime.map { sample.uptime - $0 <= 5 } ?? false
        if followsPrevious, let lastUptime { sampledSeconds += sample.uptime - lastUptime }
        if firstUptime == nil { firstUptime = sample.uptime }
        lastUptime = sample.uptime
        let reading = sample.reading
        sampleCount += 1
        if reading.available.contains("charge") {
            if firstCharge == nil { firstCharge = reading.stateOfCharge }
            lastCharge = reading.stateOfCharge
        }
        if reading.available.contains("voltage") {
            minimumVoltage = min(minimumVoltage ?? reading.voltage, reading.voltage)
            maximumVoltage = max(maximumVoltage ?? reading.voltage, reading.voltage)
        }
        if reading.available.contains("current") { peakAbsoluteCurrent = max(peakAbsoluteCurrent ?? 0, abs(reading.current)) }
        if reading.available.contains("power") { peakAbsolutePower = max(peakAbsolutePower ?? 0, abs(reading.power)) }
        if let temperature = reading.maximumTemperature {
            maximumTemperature = max(maximumTemperature ?? temperature, temperature)
        }
        if let delta = reading.cellDelta { maximumCellDelta = max(maximumCellDelta ?? delta, delta) }
        guard reading.available.contains("voltage") else { return true }
        let elapsed = sample.uptime - (firstUptime ?? sample.uptime)
        if let last = points.last, followsPrevious,
           Int(elapsed / 5) == Int(last.elapsed / 5), last.minimumVoltage != nil {
            // Keep short voltage sags and peaks even between the old snapshot times.
            points[points.count - 1] = Point(elapsed: last.elapsed, voltage: reading.voltage,
                minimumVoltage: min(last.lowerVoltage, reading.voltage),
                maximumVoltage: max(last.upperVoltage, reading.voltage), lastElapsed: elapsed,
                startsSegment: last.startsSegment)
        } else {
            points.append(Point(elapsed: elapsed, voltage: reading.voltage,
                minimumVoltage: reading.voltage, maximumVoltage: reading.voltage,
                lastElapsed: elapsed, startsSegment: !followsPrevious))
            if points.count > 120 { points.removeFirst(points.count - 120) }
        }
        return true
    }
}

/// Monotonic recording duration and gaps after the shared five-second freshness window.
/// Initial waiting lowers coverage but is not counted as an interruption before any data arrived.
public struct BMSRecordingCoverage: Codable, Equatable {
    public private(set) var recordingSeconds: TimeInterval = 0
    public private(set) var interruptionCount: Int = 0
    public private(set) var longestInterruption: TimeInterval = 0
    public private(set) var isFinished = false
    private let startedAt: TimeInterval
    private var lastObservedAt: TimeInterval
    private var lastReadingAt: TimeInterval?
    private var interruptionStartedAt: TimeInterval?

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt; lastObservedAt = startedAt
    }
    public mutating func observe(at uptime: TimeInterval) {
        guard !isFinished, uptime.isFinite, uptime >= lastObservedAt else { return }
        lastObservedAt = uptime
        recordingSeconds = max(0, uptime - startedAt)
        if let lastReadingAt, uptime > lastReadingAt + 5 {
            if interruptionStartedAt == nil {
                interruptionStartedAt = lastReadingAt + 5
                interruptionCount += 1
            }
            longestInterruption = max(longestInterruption, uptime - (interruptionStartedAt ?? uptime))
        }
    }
    @discardableResult
    public mutating func receive(at uptime: TimeInterval) -> Bool {
        guard !isFinished, uptime.isFinite, uptime >= startedAt,
              lastReadingAt.map({ uptime > $0 }) ?? true else { return false }
        // A frame may be processed after a previous observation; only count actual missing time.
        // Client frames use validation time as their uptime; reject historical insertion.
        guard uptime >= lastObservedAt else { return false }
        observe(at: uptime)
        interruptionStartedAt = nil
        lastReadingAt = uptime
        return true
    }
    public mutating func finish(at uptime: TimeInterval) {
        guard !isFinished else { return }
        observe(at: uptime); isFinished = true
    }
}
