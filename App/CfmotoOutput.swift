import CoreImage
import Foundation
import VideoToolbox

/// 春风仪表（HUName 形如 CFMOTO-xxxxxx）的输出规格。
/// 仪表原生像素：5 寸 800×386，6.2 寸 1024×515；H.264 4:2:0 要求偶数，
/// 1024×515 按 1024×516 编码，协议里回给仪表的就是实际编码尺寸。
///
/// 2026-11-26 改动（对齐极核 AE2 Pro 逻辑，见 TailingDisplayProfile.zeehoAE2）：
/// 5 寸不再写死 30 FPS / 3.5 Mbit/s，改成默认 25 FPS / 2.5 Mbit/s，
/// 实际帧率、码率跟仪表协商结果走：码率 = 2_500_000 * fps / 25。
/// 尺寸也不再按 16 对齐（800×386 会被压成 800×384），
/// 改成只保证偶数（800×386 保持 800×386，1024×515 编成 1024×516）。
struct CfmotoProfile: Equatable {
    let width: Int
    let height: Int
    let fps: Int
    let bitrate: Int
    let label: String

    static let fiveInch = CfmotoProfile(width: 800, height: 386, fps: 25, bitrate: 2_500_000, label: "春风 5 寸")
    static let sixInch = CfmotoProfile(width: 1024, height: 515, fps: 30, bitrate: 4_500_000, label: "春风 6.2 寸")

    var encodeWidth: Int { width - width % 2 }
    var encodeHeight: Int { height % 2 == 0 ? height : height + 1 }
    var sourceFPS: Int { max(30, fps) }
    var title: String { "\(width)×\(height)" }

    /// 极核 AE2 逻辑：只保证偶数，不按 16 对齐。
    /// 800×386 → 800×386，1024×515 → 1024×516。
    var pxcWidth: Int { width & ~1 }
    var pxcHeight: Int { height % 2 == 0 ? height : height + 1 }

    /// 极核码率公式：2.5 Mbit/s @25 FPS，按协商帧率线性换算。
    static func bitrate(for fps: Int) -> Int { 2_500_000 * max(1, fps) / 25 }
}

/// 春风仪表投屏输出：把 CarPlay 的 H.264 解回像素，缩放成仪表尺寸重新编码，
/// 再按仪表逐帧请求（PXC 协议，10920/10921/10922）送过去。
/// 握手、身份、SN 校验、媒体配置全部由 PxcConnection 负责。
final class CfmotoOutput {
    private let queue: DispatchQueue
    private var session: Session?

    init(name: String = "cfmoto") {
        queue = DispatchQueue(label: "CarWithin.\(name)", qos: .userInitiated)
    }

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, phone: TailingPhoneInfo, profile: CfmotoProfile,
               onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
               requestKeyframe: @escaping () -> Void, onGiveUp: (() -> Void)? = nil) {
        stop()
        let next = Session(queue: queue, localAddress: localAddress, targetAddress: targetAddress,
                           phone: phone, profile: profile,
                           onState: onState, onLog: onLog, requestKeyframe: requestKeyframe, onGiveUp: onGiveUp)
        session = next
        next.start()
    }

    func append(_ data: Data, codec: VideoCodec, keyframe: Bool) {
        guard codec == .h264 else { return }
        session?.append(data, keyframe: keyframe)
    }

    func stop() {
        guard let previous = session else { return }
        session = nil
        previous.cancel()
        queue.async { previous.close() }
    }

    private final class Session: @unchecked Sendable {
        let queue: DispatchQueue
        let profile: CfmotoProfile
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        let onGiveUp: (() -> Void)?
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private let localAddress: String
        private let targetAddress: String
        private let phone: TailingPhoneInfo
        private var encodeWidth: Int
        private var encodeHeight: Int
        /// 极核逻辑：帧率、码率不写死，跟仪表协商结果走。
        /// 协商前用 profile 的默认值（5 寸 25 FPS / 2.5 Mbit/s），协商后用仪表报的 fps 换算。
        private var effectiveFps: Int
        private var effectiveBitrate: Int
        private var connection: PxcConnection?
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var scaledBuffer: CVPixelBuffer?
        private var scaledBufferSize = (0, 0)
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var status = ""

        init(queue: DispatchQueue, localAddress: String, targetAddress: String, phone: TailingPhoneInfo,
             profile: CfmotoProfile, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void, onGiveUp: (() -> Void)? = nil) {
            self.queue = queue
            self.localAddress = localAddress
            self.targetAddress = targetAddress
            self.phone = phone
            self.profile = profile
            self.encodeWidth = profile.pxcWidth
            self.encodeHeight = profile.pxcHeight
            self.effectiveFps = profile.fps
            self.effectiveBitrate = profile.bitrate
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
            self.onGiveUp = onGiveUp
        }

        func start() {
            report("正在连接\(profile.label)仪表…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var retryAttempt = 0
                let retryDelays = [1.5, 3.0, 5.0]
                var disconnectedSince: TimeInterval?
                let maxReconnectDuration: TimeInterval = 180
                while active {
                    let conn = PxcConnection(localIP: localAddress, targetIP: targetAddress,
                                             phone: phone, dashboard: profile.label, log: onLog)
                    guard installConnection(conn) else { break }
                    do {
                        try conn.start()
                        guard active else { break }
                        retryAttempt = 0
                        disconnectedSince = nil
                        let size = conn.mediaSize
                        queue.sync {
                            encodeWidth = size.width
                            encodeHeight = size.height
                            // 极核逻辑：用仪表报的 fps，码率按 2.5 Mbit/s @25 FPS 线性换算。
                            // 例：仪表报 25 → 2.5 Mbit/s，报 30 → 3.0 Mbit/s。
                            effectiveFps = size.fps
                            effectiveBitrate = CfmotoProfile.bitrate(for: size.fps)
                            encoder?.invalidate()
                            encoder = nil
                            lastKeyframe = -.infinity
                        }
                        onLog("\(profile.label)协商尺寸 \(size.width)×\(size.height)@\(size.fps)，编码 \(effectiveFps) FPS / \(String(format: "%.1f", Double(effectiveBitrate) / 1_000_000)) Mbit/s")
                        report("仪表已连接，等待 CarPlay 画面…")
                        var first = true
                        var nextFrame = ProcessInfo.processInfo.systemUptime
                        while active {
                            try conn.checkHealth()
                            let ready = queue.sync { latest != nil }
                            if !ready { Thread.sleep(forTimeInterval: 0.05); continue }
                            let remaining = nextFrame - ProcessInfo.processInfo.systemUptime
                            if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.04)); continue }
                            try conn.waitForH264Request()
                            nextFrame = ProcessInfo.processInfo.systemUptime + 1.0 / Double(effectiveFps)
                            guard active else { break }
                            let result = queue.sync { () -> H264EncodedFrame? in
                                guard active, let image = latest else { return nil }
                                return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: first)
                            }
                            guard let result else {
                                // 仪表已经拉帧，这里保留请求，最多等 3 秒以容忍锁屏重建期间的编码恢复与关键帧到达。
                                var recovered: H264EncodedFrame?
                                for _ in 0..<60 where active && recovered == nil {
                                    try conn.checkHealth()
                                    Thread.sleep(forTimeInterval: 0.05)
                                    recovered = queue.sync {
                                        guard let image = latest else { return nil }
                                        return encode(image, at: ProcessInfo.processInfo.systemUptime, forceKeyframe: true)
                                    }
                                }
                                guard let recovered else { throw TailingError.timeout("等待 H.264 编码画面") }
                                try conn.sendH264(recovered.data)
                                first = false
                                report("正在投屏 · \(encodeWidth)×\(encodeHeight) · H.264")
                                continue
                            }
                            try conn.sendH264(result.data)
                            first = false
                            report("正在投屏 · \(encodeWidth)×\(encodeHeight) · H.264")
                        }
                    } catch {
                        if active {
                            let now = ProcessInfo.processInfo.systemUptime
                            if disconnectedSince == nil { disconnectedSince = now }
                            if let since = disconnectedSince, now - since >= maxReconnectDuration {
                                onLog("\(profile.label)连续 3 分钟无法连接仪表，已自动停止以节省后台资源")
                                report("\(profile.label)已离开仪表 Wi-Fi，自动停止")
                                clearConnection(conn)
                                conn.close()
                                onGiveUp?()
                                break
                            }
                            let delay = retryDelays[min(retryAttempt, retryDelays.count - 1)]
                            retryAttempt += 1
                            onLog("\(profile.label)输出中断（\(error.localizedDescription)），\(String(format: "%.1f", delay)) 秒后自动重连（第 \(retryAttempt) 次）")
                            report("\(profile.label)断开，正在重连…")
                            clearConnection(conn)
                            conn.close()
                            sleepWhileActive(delay)
                            continue
                        }
                    }
                    clearConnection(conn)
                    conn.close()
                }
                closeCurrentConnection()
                queue.async { [self] in close() }
            }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        private func installConnection(_ next: PxcConnection) -> Bool {
            let previous: PxcConnection? = lock.withLock {
                guard !cancelled else { return nil }
                let old = connection
                connection = next
                return old
            }
            previous?.close()
            return active
        }

        private func clearConnection(_ target: PxcConnection) {
            lock.withLock {
                if connection === target { connection = nil }
            }
        }

        private func closeCurrentConnection() {
            let current = lock.withLock { () -> PxcConnection? in
                let old = connection
                connection = nil
                return old
            }
            current?.close()
        }

        private func sleepWhileActive(_ seconds: TimeInterval) {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while active {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                Thread.sleep(forTimeInterval: min(remaining, 0.05))
            }
        }

        func cancel() {
            let current = lock.withLock { () -> PxcConnection? in
                cancelled = true
                let old = connection
                connection = nil
                return old
            }
            current?.close()
        }

        func append(_ data: Data, keyframe: Bool) {
            let (accepted, needsKeyframe) = lock.withLock {
                guard !cancelled, acceptingFrames else { return (false, false) }
                if queued >= 6 {
                    let request = !skipping
                    skipping = true
                    return (false, request)
                }
                guard !skipping || keyframe else { return (false, false) }
                skipping = false
                queued += 1
                return (true, false)
            }
            if needsKeyframe { requestKeyframe() }
            guard accepted else { return }
            queue.async { [self] in
                defer { lock.withLock { queued -= 1 } }
                guard lock.withLock({ !cancelled && acceptingFrames }) else { return }
                decode(data, keyframe: keyframe)
            }
        }

        private func decode(_ data: Data, keyframe: Bool) {
            autoreleasepool {
                do {
                    var picture: [Data] = []
                    for unit in try AnnexB.units(in: data) {
                        if VideoCodec.h264.parameterSet(unit) != nil {
                            if parameters.absorb(unit) { waitingForIDR = true }
                        } else { picture.append(unit) }
                    }
                    if waitingForIDR {
                        guard parameters.isComplete, keyframe, !picture.isEmpty else { return }
                        guard ProcessInfo.processInfo.systemUptime - lastCodecFailure >= 0.5 else {
                            requestKeyframe()
                            return
                        }
                        decoder?.invalidate()
                        decoder = try TailingH264Decoder(configuration: parameters.decoderConfigurationRecord(),
                            output: { [weak self] image in
                                guard let self else { return }
                                self.lock.withLock { self.decoded = image }
                            }, failure: { [weak self] error in
                                guard let self else { return }
                                self.lock.withLock { self.decodeError = error }
                            })
                        waitingForIDR = false
                    }
                    guard let decoder, !picture.isEmpty else { return }
                    try decoder.decode(AnnexB.lengthPrefixed(picture),
                        presentationTimeMicroseconds: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000), isKeyframe: keyframe)
                    decoder.waitForFrames()
                    let (image, error) = lock.withLock {
                        defer { decoded = nil; decodeError = nil }
                        return (decoded, decodeError)
                    }
                    if let error { throw error }
                    if let image { latest = image }
                } catch {
                    decoder?.invalidate()
                    decoder = nil
                    lock.withLock { decoded = nil; decodeError = nil }
                    waitingForIDR = true
                    logCodecFailure("解码", error)
                    requestKeyframe()
                }
            }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double, forceKeyframe: Bool) -> H264EncodedFrame? {
            autoreleasepool {
                do {
                    if encoder == nil {
                        guard now - lastCodecFailure >= 0.5 else { return nil }
                        encoder = try H264Encoder(width: encodeWidth, height: encodeHeight,
                                                  fps: effectiveFps, bitrate: effectiveBitrate) { [weak self] result in
                            guard let self else { return }
                            self.lock.withLock { self.encoded = result }
                        }
                        lastKeyframe = -.infinity
                    }
                    guard let encoder else { return nil }
                    let stamp = CMTime(seconds: now, preferredTimescale: 1_000_000)
                    try encoder.encode(try fittedImage(image), presentationTime: stamp,
                                       forceKeyframe: forceKeyframe || lastKeyframe == -.infinity)
                    encoder.complete()
                    let result = lock.withLock {
                        defer { encoded = nil }
                        return encoded
                    }
                    let frame = try result?.get()
                    if frame?.isKeyframe == true { lastKeyframe = now }
                    return frame
                } catch H264EncoderError.frameDropped {
                    return nil
                } catch {
                    encoder?.invalidate()
                    encoder = nil
                    lastKeyframe = -.infinity
                    lock.withLock { encoded = nil }
                    logCodecFailure("编码", error)
                    return nil
                }
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = encodeWidth, height = encodeHeight
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            let buffer: CVPixelBuffer
            if let existing = scaledBuffer, scaledBufferSize == (width, height) {
                buffer = existing
            } else {
                var created: CVPixelBuffer?
                let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                                 [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created)
                guard status == kCVReturnSuccess, let created else {
                    throw ConfigurationError("无法分配\(profile.label)缩放画面（\(status)）")
                }
                scaledBuffer = created
                scaledBufferSize = (width, height)
                buffer = created
            }
            let source = CIImage(cvPixelBuffer: image)
            let scale = min(CGFloat(width) / source.extent.width, CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let positioned = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            compositor.render(positioned.composited(over: CIImage(color: .black)).cropped(to: bounds),
                              to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            return buffer
        }

        private func logCodecFailure(_ stage: String, _ error: Error) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCodecFailure > 4 { onLog("\(profile.label)\(stage)恢复：\(error.localizedDescription)") }
            lastCodecFailure = now
        }

        private func report(_ message: String) {
            guard active, message != status else { return }
            status = message
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active else { return }
                self.onState(message)
            }
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            closeCurrentConnection()
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            scaledBuffer = nil
            scaledBufferSize = (0, 0)
            latest = nil
        }
    }
}
