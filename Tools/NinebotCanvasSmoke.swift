import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO

@main
struct NinebotCanvasSmoke {
    static let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    static let bounds = CGRect(x: 0, y: 0, width: 480, height: 272)

    static func main() throws {
        let source = try buffer(width: 960, height: 544)
        let renderer = InstrumentVideoCanvas()
        let red = try overlay(CIColor(red: 1, green: 0, blue: 0))
        let green = try overlay(CIColor(red: 0, green: 1, blue: 0))
        var config = ANTBMSCardConfiguration()
        for position in ANTBMSCardConfiguration.Position.allCases {
            config.position = position
            renderer.setBMSOverlay(red, configuration: config)
            let jpeg = try required(renderer.jpeg(source, in: bounds, refresh: false))
            let image = try decoded(jpeg)
            precondition(image.extent.width == 480 && image.extent.height == 272)
            let x: CGFloat = position.isAtRight ? 420 : 60
            let y: CGFloat = position.isAtTop ? 252 : 20
            try expectColor(image, at: CGPoint(x: x, y: y), channel: 0)
            try expectColor(image, at: CGPoint(x: 240, y: 136), channel: 2)
        }
        print("PASS: 4.3-inch JPEG contains the overlay in all four corners, preserves 480x272 and the background")

        config.position = .topRight
        renderer.setBMSOverlay(red, configuration: config)
        let first = try required(renderer.jpeg(source, in: bounds, refresh: false))
        let cached = try required(renderer.jpeg(source, in: bounds, refresh: false))
        precondition(first == cached)
        renderer.setBMSOverlay(green, configuration: config)
        let changed = try required(renderer.jpeg(source, in: bounds, refresh: false))
        precondition(first != changed)
        try expectColor(decoded(changed), at: CGPoint(x: 420, y: 252), channel: 1)
        print("PASS: changed BMS data invalidates JPEG cache without a new CarPlay frame")

        config.position = .bottomLeft
        renderer.setBMSOverlay(green, configuration: config)
        let moved = try decoded(required(renderer.jpeg(source, in: bounds, refresh: false)))
        try expectColor(moved, at: CGPoint(x: 60, y: 20), channel: 1)
        try expectColor(moved, at: CGPoint(x: 420, y: 252), channel: 2)
        renderer.setBMSOverlay(nil, configuration: config)
        let disabled = try decoded(required(renderer.jpeg(source, in: bounds, refresh: false)))
        try expectColor(disabled, at: CGPoint(x: 60, y: 20), channel: 2)
        print("PASS: moving and disabling BMS clear the old card on a static frame")

        for (width, height) in [(848, 480), (1024, 600)] {
            config.position = .topRight
            renderer.setBMSOverlay(red, configuration: config)
            let fitted = try renderer.fittedImage(source, width: width, height: height)
            precondition(CVPixelBufferGetWidth(fitted) == width && CVPixelBufferGetHeight(fitted) == height)
            try expectColor(CIImage(cvPixelBuffer: fitted), at: CGPoint(x: width - 60, y: height - 20), channel: 0)
        }
        print("PASS: 5/7-inch H.264 input canvases retain the same card composition")

        for (width, height) in [(800, 480), (1600, 770), (1024, 480), (480, 800)] {
            for position in ANTBMSCardConfiguration.Position.allCases {
                for size in ANTBMSCardConfiguration.Size.allCases {
                    config.position = position; config.size = size
                    renderer.setBMSOverlay(red, configuration: config)
                    let fitted = try renderer.fittedImage(source, width: width, height: height)
                    precondition(CVPixelBufferGetWidth(fitted) == width && CVPixelBufferGetHeight(fitted) == height)
                    let x: CGFloat = position.isAtRight ? CGFloat(width) - 60 : 60
                    let y: CGFloat = position.isAtTop ? CGFloat(height) - 20 : 20
                    try expectColor(CIImage(cvPixelBuffer: fitted), at: CGPoint(x: x, y: y), channel: 0)
                    try expectColor(CIImage(cvPixelBuffer: fitted), at: CGPoint(x: width / 2, y: height / 2), channel: 2)
                }
            }
        }
        print("PASS: ZEEHO SE+/AE2/6.2 canvases support all corners and sizes, including reported portrait dimensions")

        config.position = .topRight; config.size = .medium
        for (width, height) in [(848, 480), (1024, 600), (800, 480), (1600, 770), (1024, 480)] {
            for (card, channel) in [(red, 0), (green, 1)] {
                renderer.setBMSOverlay(card, configuration: config)
                let fitted = try renderer.fittedImage(source, width: width, height: height)
                let received = try h264RoundTrip(fitted, width: width, height: height)
                try expectColor(CIImage(cvPixelBuffer: received),
                    at: CGPoint(x: width - 60, y: height - 20), channel: channel)
            }
            renderer.setBMSOverlay(nil, configuration: config)
            let fitted = try renderer.fittedImage(source, width: width, height: height)
            let received = try h264RoundTrip(fitted, width: width, height: height)
            let pixel = Self.pixel(CIImage(cvPixelBuffer: received), at: CGPoint(x: width - 60, y: height - 20))
            precondition(pixel[0] < 90 && pixel[1] < 90, "Disabled card remains in H.264")
            try expectColor(CIImage(cvPixelBuffer: received), at: CGPoint(x: width / 2, y: height / 2), channel: 2)
        }
        print("PASS: actual H.264 encode/decode retains card updates and removes disabled cards for Ninebot 5/7-inch and ZEEHO SE+/AE2/6.2 formats")

        renderer.setBMSOverlay(nil, configuration: config)
        let sameSize = try buffer(width: 848, height: 480)
        let unchanged = try renderer.fittedImage(sameSize, width: 848, height: 480)
        precondition(unchanged === sameSize)
        let resizedJPEG = try decoded(required(renderer.jpeg(source, in: CGRect(x: 0, y: 0, width: 240, height: 136), refresh: false)))
        precondition(resizedJPEG.extent.width == 240 && resizedJPEG.extent.height == 136)
        print("PASS: no-overlay fast path and JPEG canvas size changes remain correct")
    }

    static func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess)
        let image = try required(result)
        let area = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: area),
            to: image, bounds: area, colorSpace: CGColorSpaceCreateDeviceRGB())
        return image
    }

    static func overlay(_ color: CIColor) throws -> CGImage {
        let area = CGRect(x: 0, y: 0, width: 640, height: 122)
        return try required(context.createCGImage(CIImage(color: color).cropped(to: area), from: area))
    }
    static func decoded(_ data: Data) throws -> CIImage { try required(CIImage(data: data)) }
    static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "NinebotCanvasSmoke", code: 1) }
        return value
    }
    static func expectColor(_ image: CIImage, at point: CGPoint, channel: Int) throws {
        let pixel = Self.pixel(image, at: point)
        precondition(pixel[channel] > 170 && (0..<3).filter { $0 != channel }.allSatisfy { pixel[$0] < 90 },
            "Unexpected pixel at \(point): \(pixel), expected channel \(channel)")
    }
    static func pixel(_ image: CIImage, at point: CGPoint) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixel
    }

    static func h264RoundTrip(_ image: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        let encoded = CanvasValue<Result<H264EncodedFrame, Error>?>(nil)
        let encoder = try H264Encoder(width: width, height: height, fps: 25, bitrate: 2_500_000) { encoded.set($0) }
        defer { encoder.invalidate() }
        try encoder.encode(image, presentationTime: .zero, forceKeyframe: true)
        encoder.complete()
        let frame = try required(encoded.get()).get()
        precondition(frame.isKeyframe)
        var parameters = VideoParameterSets(codec: .h264)
        var picture: [Data] = []
        for unit in try AnnexB.units(in: frame.data) {
            if VideoCodec.h264.parameterSet(unit) != nil { _ = parameters.absorb(unit) }
            else { picture.append(unit) }
        }
        precondition(parameters.isComplete && !picture.isEmpty)
        let decoded = CanvasValue<CVPixelBuffer?>(nil)
        let failure = CanvasValue<Error?>(nil)
        let decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
            output: { decoded.set($0) }, failure: { failure.set($0) })
        defer { decoder.invalidate() }
        try decoder.decode(AnnexB.lengthPrefixed(picture), presentationTimeMicroseconds: 0, isKeyframe: true)
        decoder.waitForFrames()
        if let error = failure.get() { throw error }
        let result = try required(decoded.get())
        precondition(CVPixelBufferGetWidth(result) == width && CVPixelBufferGetHeight(result) == height)
        return result
    }
}

private final class CanvasValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ value: Value) { lock.withLock { self.value = value } }
    func get() -> Value { lock.withLock { value } }
}
