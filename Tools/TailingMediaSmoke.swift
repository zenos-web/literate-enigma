import Foundation
import AVFoundation
import VideoToolbox
import ImageIO
import CoreImage

private final class MediaBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
private struct MediaSmokeError: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw MediaSmokeError(message: message) }
}

/// Real VT H.264 → decoder → Core Image JPEG → pull-frame socket round trip on loopback.
func tailingMediaSmoke() throws {
    let encoded = MediaBox<Data?>(nil)
    let failure = MediaBox<Error?>(nil)
    var encoder: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: 960, height: 544,
        codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
        compressedDataAllocator: nil, outputCallback: { ref, _, status, _, sample in
            guard let ref, status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else { return }
            let box = Unmanaged<MediaBox<Data?>>.fromOpaque(ref).takeUnretainedValue()
            var output = Data()
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var count = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &count,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    output.append(contentsOf: [0, 0, 0, 1]); output.append(pointer, count: count)
                }
            }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let size = data.count
            let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,
                atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard copied == noErr else { return }
            var offset = 0
            while offset + 4 <= data.count {
                let length = (offset..<offset + 4).reduce(0) { ($0 << 8) | Int(data[$1]) }
                offset += 4
                guard length > 0, offset + length <= data.count else { return }
                output.append(contentsOf: [0, 0, 0, 1]); output.append(data[offset..<offset + length])
                offset += length
            }
            box.set(output)
        }, refcon: Unmanaged.passUnretained(encoded).toOpaque(), compressionSessionOut: &encoder)
    try require(status == noErr && encoder != nil, "创建真实 H.264 编码器")
    guard let encoder else { return }
    defer { VTCompressionSessionInvalidate(encoder) }
    VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var buffer: CVPixelBuffer?
    try require(CVPixelBufferCreate(nil, 960, 544, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, "创建测试画面")
    guard let buffer else { return }
    CVPixelBufferLockBaseAddress(buffer, [])
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<544 {
        for x in 0..<960 {
            let offset = y * stride + x * 4
            base[offset] = x < 480 ? 0 : 255
            base[offset + 1] = 0; base[offset + 2] = x < 480 ? 255 : 0; base[offset + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    try require(VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: .zero,
        duration: CMTime(value: 1, timescale: 30), frameProperties: nil, sourceFrameRefcon: nil,
        infoFlagsOut: nil) == noErr, "编码 H.264 首帧")
    VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
    guard let accessUnit = encoded.get() else { throw MediaSmokeError(message: "未生成 H.264 数据") }

    let announcement = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
    defer { announcement.close() }
    let reserved = try (0..<3).map { _ in try TailingSocket.listening(localIP: "127.0.0.1", port: 0) }
    let ports = try TailingPorts(control: reserved[0].localPort, auxiliary: reserved[1].localPort,
        video: reserved[2].localPort, announcement: announcement.localPort)
    reserved.forEach { $0.close() }
    let identity = try TailingIdentity.generate()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        var sockets: [TailingSocket] = []
        defer { sockets.forEach { $0.close() }; done.signal() }
        func connect(_ port: UInt16) throws -> TailingSocket {
            let s = try TailingSocket.create(); sockets.append(s)
            try s.connect(localIP: "127.0.0.1", remoteIP: "127.0.0.1", port: port)
            return s
        }
        do {
            let a = try announcement.accept(remoteIP: "127.0.0.1"); sockets.append(a)
            _ = try TailingProtocol.readControl { try a.readExactly($0) }
            try a.write(TailingProtocol.control(0x70000011, payload: TailingProtocol.json(["status": true])))
            let control = try connect(ports.control)
            try control.write(TailingProtocol.control(0x10010,
                payload: TailingProtocol.json(["HUName": "TL-DASH-V2", "HUID": "MEDIA-SMOKE"])))
            let info = try TailingProtocol.object(TailingProtocol.readControl { try control.readExactly($0) }.payload)
            let signature = info["encryptedHUID"] as! String
            let reverse = try connect(ports.control)
            try reverse.write(TailingProtocol.control(0x20000))
            _ = try TailingProtocol.readControl { try reverse.readExactly($0) }
            for _ in 0..<5 {
                let m = try TailingProtocol.readControl { try reverse.readExactly($0) }
                try reverse.write(TailingProtocol.control(m.command == 0x205a0 ? 0x80000010 : m.command + 1, identifier: m.identifier))
            }
            let aux = try connect(ports.auxiliary)
            var config = Data(); config.appendLE(UInt32(272 << 16 | 480))
            config.append(Data(repeating: 0, count: 28)); config.append(Data(signature.utf8))
            try aux.write(TailingProtocol.auxiliary(0x10, payload: config))
            _ = try TailingProtocol.readAuxiliary { try aux.readExactly($0) }
            try aux.write(TailingProtocol.auxiliary(0x70))
            _ = try TailingProtocol.readAuxiliary { try aux.readExactly($0) }
            let video = try connect(ports.video)
            var previous: Data?
            for _ in 0..<3 {
                try video.write(TailingProtocol.auxiliary(0x72))
                let length = Int(try video.readExactly(4, timeout: 20).uint32LE(0))
                try require((1...1_000_000).contains(length), "JPEG 长度合理")
                let jpeg = try video.readExactly(length)
                if let previous { try require(jpeg == previous, "静态画面复用最新 JPEG") }
                previous = jpeg
                guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw MediaSmokeError(message: "JPEG 不可解码")
                }
                try require(image.width == 480 && image.height == 272, "JPEG 固定 480×272")
                var pixels = [UInt8](repeating: 0, count: 480 * 272 * 4)
                try pixels.withUnsafeMutableBytes { bytes in
                    guard let context = CGContext(data: bytes.baseAddress, width: 480, height: 272,
                        bitsPerComponent: 8, bytesPerRow: 480 * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw MediaSmokeError(message: "JPEG 像素读取")
                    }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 480, height: 272))
                }
                let left = (136 * 480 + 100) * 4, right = (136 * 480 + 380) * 4
                try require(pixels[left] > 220 && pixels[left + 2] < 35 && pixels[right + 2] > 220 && pixels[right] < 35,
                            "红蓝通道、比例及左右方向正确")
            }
        } catch { failure.set(error) }
    }
    let output = TailingOutputSession(localAddress: "127.0.0.1", targetAddress: "127.0.0.1",
        phone: TailingPhoneInfo(package: "test.carwithin", versionCode: 12, model: "iPhone", systemVersion: "16.0",
            width: 1320, height: 2868, rotation: 0), log: { print($0) }, ports: ports, identityProvider: { identity })
    defer { output.close() }
    output.start()
    output.append(accessUnit)
    try require(done.wait(timeout: .now() + 25) == .success, "转码输出超时")
    if let error = failure.get() { throw error }
    print("PASS: 真实 H.264 → JPEG → 模拟仪表，480×272、颜色方向、静态画面三次拉取")
}


func tailingJPEGSizeSmoke() throws {
    var buffer: CVPixelBuffer?
    try require(CVPixelBufferCreate(nil, 480, 272, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess, "创建复杂画面")
    guard let buffer else { return }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var random: UInt32 = 1234567
    for y in 0..<272 {
        for x in 0..<480 {
            for channel in 0..<3 {
                random = random &* 1664525 &+ 1013904223
                base[y * stride + x * 4 + channel] = UInt8(truncatingIfNeeded: random >> 24)
            }
            base[y * stride + x * 4 + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let image = CIImage(cvPixelBuffer: buffer)
    guard let original = context.jpegRepresentation(of: image, colorSpace: colorSpace,
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]) else {
        throw MediaSmokeError(message: "复杂画面原始 JPEG 编码")
    }
    try require(original.count > TailingJPEGEncoder.byteLimit, "复杂画面须触发限幅")
    for quality in [80, 100, 0] {
        let bounded = try TailingJPEGEncoder.encode(image, context: context, colorSpace: colorSpace, quality: quality)
        try require(bounded.data.count <= TailingJPEGEncoder.byteLimit, "每帧不超过 24 KiB")
        if quality == 80 { try require(bounded.reduced, "默认质量复杂帧记录限幅") }
        guard let source = CGImageSourceCreateWithData(bounded.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MediaSmokeError(message: "限幅 JPEG 无法解码")
        }
        try require(decoded.width == 480 && decoded.height == 272, "限幅保持协商尺寸")
    }
    let simple = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 480, height: 272))
    let unchanged = try TailingJPEGEncoder.encode(simple, context: context, colorSpace: colorSpace)
    let baseline = context.jpegRepresentation(of: simple, colorSpace: colorSpace,
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
    try require(!unchanged.reduced && unchanged.data == baseline, "小帧保留原质量")
    print("PASS: 复杂 JPEG 单帧 ≤24 KiB、480×272，最低质量兜底；简单画面保留原质量")
}
