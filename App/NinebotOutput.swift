import CoreImage
import Foundation
import VideoToolbox

/// Runs codecs and UDP writes off the CarPlay receive queue.
final class NinebotOutput {
    static let width = 848
    static let height = 480
    static let fps = 30

    private let queue = DispatchQueue(label: "CarWithin.ninebot", qos: .userInitiated)
    private var session: Session?

    deinit { stop() }

    func start(localAddress: String, targetAddress: String, onState: @escaping (String) -> Void,
               onLog: @escaping (String) -> Void, requestKeyframe: @escaping () -> Void) {
        stop()
        let next = Session(queue: queue, onState: onState, onLog: onLog, requestKeyframe: requestKeyframe)
        session = next
        queue.async { next.start(localAddress, targetAddress) }
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
        let onState: (String) -> Void
        let onLog: (String) -> Void
        let requestKeyframe: () -> Void
        private let lock = NSLock()
        private var cancelled = false
        private var acceptingFrames = true
        private var queued = 0
        private var skipping = false
        private var decoded: CVPixelBuffer?
        private var decodeError: Error?
        private var encoded: Result<H264EncodedFrame, Error>?

        private var timer: DispatchSourceTimer?
        private var video: NinebotUDPSocket?
        private var control: NinebotUDPSocket?
        private let packetizer = NinebotH264Packetizer()
        private var decoder: TailingH264Decoder?
        private var encoder: H264Encoder?
        private var parameters = VideoParameterSets(codec: .h264)
        private var waitingForIDR = true
        private var latest: CVPixelBuffer?
        private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
        private var fresh = false
        private let origin = ProcessInfo.processInfo.systemUptime
        private var lastFrame = -Double.infinity
        private var lastKeyframe = -Double.infinity
        private var lastCodecFailure = -Double.infinity
        private var nextHeartbeat = 0.0
        private var counter: UInt32 = 0
        private var lastReply: Double?
        private var sentPicture = false
        private var status = ""

        init(queue: DispatchQueue, onState: @escaping (String) -> Void, onLog: @escaping (String) -> Void,
             requestKeyframe: @escaping () -> Void) {
            self.queue = queue
            self.onState = onState
            self.onLog = onLog
            self.requestKeyframe = requestKeyframe
        }

        func start(_ local: String, _ target: String) {
            guard active else { return }
            do {
                let videoPort = NinebotH264Packetizer.videoPort
                let controlPort = NinebotH264Packetizer.controlPort
                video = try NinebotUDPSocket(localIP: local, localPort: videoPort, remoteIP: target, remotePort: videoPort)
                control = try NinebotUDPSocket(localIP: local, localPort: controlPort, remoteIP: target, remotePort: controlPort)
                report("等待九号仪表回应…")
                onLog("九号 5 寸：UDP 5012/5013 · 848×480 · H.264 Baseline · 30 FPS")
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(3))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            } catch { fail(error) }
        }

        private var active: Bool { lock.withLock { !cancelled } }

        func cancel() { lock.withLock { cancelled = true } }

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
            do {
                var picture: [Data] = []
                for unit in try AnnexB.units(in: data) {
                    if VideoCodec.h264.parameterSet(unit) != nil {
                        if parameters.absorb(unit) { waitingForIDR = true }
                    } else { picture.append(unit) }
                }
                if waitingForIDR {
                    // Throttle rebuilds while VideoToolbox is unavailable during a lock transition.
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
                if let image { latest = image; fresh = true }
            } catch {
                decoder?.invalidate()
                decoder = nil
                lock.withLock { decoded = nil; decodeError = nil }
                waitingForIDR = true
                logCodecFailure("解码", error)
                requestKeyframe()
            }
        }

        private func tick() {
            guard active, let video, let control else { return }
            let now = ProcessInfo.processInfo.systemUptime
            do {
                if now >= nextHeartbeat {
                    nextHeartbeat = now + 1
                    counter &+= 1
                    do { try control.send(NinebotH264Packetizer.heartbeat(counter: counter)) }
                    catch let error as NinebotSocketError where error.isTransient {}
                }
                for _ in 0..<8 {
                    guard let response = try control.receive() else { break }
                    if let reply = NinebotH264Packetizer.heartbeatReplyCounter(response), counter &- reply < 8 {
                        lastReply = now
                    }
                }
                if let lastReply, now - lastReply < 4 {
                    report(sentPicture ? "仪表已回应，正在发送画面" : "仪表已回应，等待发送画面…")
                } else if now - origin > 4 {
                    report("未收到仪表回应，请检查 Wi-Fi 和仪表 IP。")
                }
                guard let latest, fresh || now - lastFrame >= 0.5 else { return }
                lastFrame = now
                fresh = false
                guard let frame = encode(latest, at: now) else { return }
                let timestamp = UInt32(truncatingIfNeeded: Int64(now * 1_000))
                let packets = packetizer.packets(for: frame.data, timestampMilliseconds: timestamp,
                                                isKeyframe: frame.isKeyframe, repeatKeyframe: false)
                do {
                    for (index, packet) in packets.enumerated() {
                        guard active else { return }
                        try video.send(packet)
                        if packets.count > 12, index + 1 < packets.count, (index + 1).isMultiple(of: 8) {
                            usleep(750)
                        }
                    }
                    sentPicture = true
                    if frame.isKeyframe { lastKeyframe = now }
                } catch let error as NinebotSocketError where error.isTransient {
                    lastKeyframe = -.infinity
                }
            } catch { fail(error) }
        }

        private func encode(_ image: CVPixelBuffer, at now: Double) -> H264EncodedFrame? {
            do {
                if encoder == nil {
                    guard now - lastCodecFailure >= 0.5 else { return nil }
                    encoder = try H264Encoder(width: NinebotOutput.width, height: NinebotOutput.height,
                                              fps: NinebotOutput.fps, bitrate: 1_500_000) { [weak self] result in
                        guard let self else { return }
                        self.lock.withLock { self.encoded = result }
                    }
                    lastKeyframe = -.infinity
                }
                guard let encoder else { return nil }
                try encoder.encode(try fittedImage(image), presentationTime: CMTime(seconds: now, preferredTimescale: 1_000_000),
                                   forceKeyframe: now - lastKeyframe >= 0.5)
                encoder.complete()
                let result = lock.withLock {
                    defer { encoded = nil }
                    return encoded
                }
                return try result?.get()
            } catch H264EncoderError.frameDropped {
                return nil
            } catch {
                encoder?.invalidate()
                encoder = nil
                lock.withLock { encoded = nil }
                logCodecFailure("编码", error)
                return nil
            }
        }

        private func fittedImage(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
            let width = NinebotOutput.width, height = NinebotOutput.height
            if CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height { return image }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                             [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw ConfigurationError("无法分配九号缩放画面（\(status)）") }
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
            if now - lastCodecFailure > 4 { onLog("九号\(stage)恢复：\(error.localizedDescription)") }
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

        private func fail(_ error: Error) {
            let message = "九号输出失败：\(error.localizedDescription)"
            onLog(message)
            report(message)
            close()
        }

        func close() {
            lock.withLock { acceptingFrames = false }
            timer?.cancel()
            timer = nil
            try? control?.send(NinebotH264Packetizer.bye)
            control = nil
            video = nil
            decoder?.invalidate()
            decoder = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
        }
    }
}
