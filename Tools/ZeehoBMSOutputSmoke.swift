// Native integration harness: actual ZeehoOutput + codecs, with only the instrument transport replaced.
import AVFoundation
import CoreImage
import Foundation

private final class Capture {
    let size: InstrumentFrameSize
    let condition = NSCondition()
    private var frames: [Data] = []
    private var logs: [String] = []
    private var closed = false
    init(_ size: InstrumentFrameSize) { self.size = size }
    func log(_ text: String) { condition.lock(); logs.append(text); condition.broadcast(); condition.unlock() }
    func send(_ data: Data) throws {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { throw TailingError.timeout("closed") }
        frames.append(data); if frames.count > 8 { frames.removeFirst() }; condition.broadcast()
    }
    func health() throws {
        condition.lock(); defer { condition.unlock() }
        if closed { throw TailingError.timeout("closed") }
    }
    func close() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
    func frame(timeout: TimeInterval = 8, matching predicate: (Data) throws -> Bool) throws -> Data {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            condition.lock()
            let next = frames.isEmpty ? nil : frames.removeFirst()
            if next == nil { _ = condition.wait(until: min(deadline, Date(timeIntervalSinceNow: 0.1))) }
            condition.unlock()
            if let next, try predicate(next) { return next }
        }
        condition.lock(); let text = logs.joined(separator: "\n"); condition.unlock()
        throw NSError(domain: "ZeehoBMSOutputSmoke: frame timeout\n" + text, code: 1)
    }
    func didSwitch() -> Bool {
        condition.lock(); defer { condition.unlock() }
        return logs.contains { $0.contains("BMS 电池卡片已启用") }
    }
}

// The production output's transport API. No live ports, Bluetooth or iOS simulator.
struct TailingPhoneInfo {
    let package: String; let versionCode: Int; let model: String; let systemVersion: String
    let width: Int; let height: Int; let rotation: Int
}
final class TailingConnection {
    fileprivate static var capture: Capture!
    private let capture: Capture
    init(localIP: String, targetIP: String, profile: TailingDisplayProfile,
         phone: TailingPhoneInfo, log: @escaping (String) -> Void) { capture = Self.capture }
    func start() throws -> InstrumentFrameSize { capture.size }
    func checkHealth() throws { try capture.health() }
    func waitForH264Request() throws { try capture.health(); Thread.sleep(forTimeInterval: 0.01) }
    func sendH264(_ data: Data) throws { try capture.send(data) }
    func close() { capture.close() }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct ZeehoBMSOutputSmoke {
    static let context = CIContext(options: [.useSoftwareRenderer: true])
    static func main() throws {
        try session(profile: .zeehoSEPlus, size: .init(width: 800, height: 480), preloaded: false)
        print("PASS: actual ZEEHO SE+ output switches relay to BMS transcode, updates/moves/clears static cards")
        try session(profile: .zeehoSEPlus, size: .init(width: 1600, height: 770), preloaded: true)
        print("PASS: ZEEHO SE+ applies a preloaded BMS card before the wide output session starts")
        try session(profile: .zeehoAE2, size: .init(width: 480, height: 800), preloaded: true)
        print("PASS: actual ZEEHO AE2 output composites and clears BMS at portrait negotiated dimensions")
    }
    static func session(profile: TailingDisplayProfile, size: InstrumentFrameSize, preloaded: Bool) throws {
        let capture = Capture(size); TailingConnection.capture = capture
        let source = try sourceFrame(size)
        let output = ZeehoOutput()
        defer { output.stop() }
        var config = ANTBMSCardConfiguration(); config.position = .topRight
        if preloaded { output.setBMSOverlay(try overlay(red: true), configuration: config) }
        output.start(localAddress: "127.0.0.1", targetAddress: "127.0.0.1", profile: profile,
            frameRate: .fps30, videoMode: .relay, sourceSize: size,
            phone: .init(package: "test", versionCode: 1, model: "test", systemVersion: "test",
                width: size.width, height: size.height, rotation: 1),
            onState: { _ in }, onLog: { capture.log($0) },
            requestKeyframe: { output.append(source, codec: .h264, keyframe: true) })
        output.append(source, codec: .h264, keyframe: true)
        if !preloaded {
            _ = try capture.frame { try blue($0, at: CGPoint(x: size.width - 60, y: size.height - 20)) }
            output.setBMSOverlay(try overlay(red: true), configuration: config)
        }
        let red = try capture.frame { try color($0, at: CGPoint(x: size.width - 60, y: size.height - 20), channel: 0) }
        let redUnits = try AnnexB.units(in: red)
        precondition(redUnits.contains { VideoCodec.h264.isRandomAccess($0) }, "First composed output must be independently decodable")
        if profile == .zeehoSEPlus { precondition(capture.didSwitch(), "BMS did not switch relay mode") }
        // No new source frame after this point: only the BMS image changes.
        config.position = .bottomLeft
        output.setBMSOverlay(try overlay(red: false), configuration: config)
        _ = try capture.frame { data in
            try color(data, at: CGPoint(x: 60, y: 20), channel: 1) &&
                blue(data, at: CGPoint(x: size.width - 60, y: size.height - 20))
        }
        output.setBMSOverlay(nil, configuration: config)
        _ = try capture.frame { try blue($0, at: CGPoint(x: 60, y: 20)) }
    }
    static func sourceFrame(_ size: InstrumentFrameSize) throws -> Data {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        let image = buffer!, bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.render(CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds),
            to: image, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        let result = Locked<Result<H264EncodedFrame, Error>?>(nil)
        let encoder = try H264Encoder(width: size.width, height: size.height, fps: 30, bitrate: 2_500_000) { result.set($0) }
        defer { encoder.invalidate() }
        try encoder.encode(image, presentationTime: .zero, forceKeyframe: true); encoder.complete()
        return try result.get()!.get().data
    }
    static func overlay(red: Bool) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 122)
        return context.createCGImage(CIImage(color: CIColor(red: red ? 1 : 0, green: red ? 0 : 1, blue: 0)).cropped(to: bounds), from: bounds)!
    }
    static func blue(_ data: Data, at point: CGPoint) throws -> Bool { try color(data, at: point, channel: 2) }
    static func color(_ data: Data, at point: CGPoint, channel: Int) throws -> Bool {
        var parameters = VideoParameterSets(codec: .h264), picture: [Data] = []
        for unit in try AnnexB.units(in: data) {
            if VideoCodec.h264.parameterSet(unit) != nil { _ = parameters.absorb(unit) }
            else { picture.append(unit) }
        }
        guard parameters.isComplete else { return false }
        let result = Locked<CVPixelBuffer?>(nil), failure = Locked<Error?>(nil)
        let decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
            output: { result.set($0) }, failure: { failure.set($0) })
        defer { decoder.invalidate() }
        try decoder.decode(AnnexB.lengthPrefixed(picture), presentationTimeMicroseconds: 0, isKeyframe: true)
        decoder.waitForFrames()
        if let error = failure.get() { throw error }
        guard let image = result.get() else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(CIImage(cvPixelBuffer: image), toBitmap: bytes.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixel[channel] > 170 && (0..<3).filter { $0 != channel }.allSatisfy { pixel[$0] < 90 }
    }
}
