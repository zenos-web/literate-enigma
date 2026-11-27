import Foundation

func cfmotoNegotiationSmoke() throws {
    func body(_ width: UInt16, _ height: UInt16, _ fps: UInt32 = 30, _ codec: UInt32 = 2) -> Data {
        var data = Data(); data.appendLE(width); data.appendLE(height); data.appendLE(fps); data.appendLE(codec); return data
    }
    let five = try PxcConnection.validatedMediaSize(body(800, 386))
    precondition(five.width == 800 && five.height == 386 && five.fps == 30)
    let zeroFive = try PxcConnection.captureConfiguration(body(800, 386, 0))
    precondition(zeroFive.size.fps == 25 && zeroFive.size.height == 386)
    let six = try PxcConnection.validatedMediaSize(body(1024, 515))
    precondition(six.width == 1024 && six.height == 516)
    let zero = try PxcConnection.captureConfiguration(body(1024, 515, 0))
    precondition(zero.size.fps == 30 && zero.size.height == 516)
    let otherEncoder = try PxcConnection.captureConfiguration(body(1024, 515, 30, 1))
    precondition(otherEncoder.encoder == 1)
    let defaultEncoder = try PxcConnection.captureConfiguration(body(800, 386, 30, 0))
    precondition(defaultEncoder.encoder == 2)
    let short = try PxcConnection.captureConfiguration(Data(body(800, 386).prefix(4)))
    precondition(short.size.width == 800 && short.size.height == 386 && short.size.fps == 25 && short.encoder == 2)
    let unusualFPS = try PxcConnection.captureConfiguration(body(800, 386, UInt32.max))
    precondition(unusualFPS.size.fps == 25)
    for invalid in [Data(), Data([0, 4, 0]), body(0, 480), body(65535, 480), body(800, 0)] {
        do { _ = try PxcConnection.validatedMediaSize(invalid); fatalError("Accepted invalid PXC media configuration") }
        catch TailingError.protocolFailure { }
    }
    print("PASS: 春风媒体配置长度、尺寸、默认帧率、短配置、编码字段兼容与尺寸安全边界")
}
