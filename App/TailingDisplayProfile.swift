import Foundation
import CoreGraphics

enum ZeehoFrameRate: Int, CaseIterable, Sendable {
    case fps25 = 25
    case fps30 = 30
    /// 贴着仪表拉帧上限跑的两档：波动比「目标 60、实际 40–55」更均匀。
    case fps45 = 45
    case fps50 = 50
    case fps60 = 60

    var title: String { self == .fps60 ? "60 FPS（实验）" : "\(rawValue) FPS" }
    var sourceFPS: Int { max(30, rawValue) }
    var bitrate: Int { 2_500_000 * rawValue / 25 }
}

enum ZeehoVideoMode: Int, CaseIterable, Sendable {
    case transcode = 0, relay = 1
    var title: String { self == .relay ? "H.264 直传（实验）" : "兼容转码" }
    func effective(for rate: ZeehoFrameRate) -> Self {
        // A compressed P-frame cannot be discarded to turn a 30 FPS source into 25 FPS.
        rate == .fps25 ? .transcode : self
    }
}

enum ZeehoCanvas: Int, CaseIterable, Sendable {
    case wide = 0, compatible = 1
    var title: String { self == .wide ? "全宽 1600×770" : "兼容 800×480" }
    var size: InstrumentFrameSize {
        self == .wide ? InstrumentFrameSize(width: 1600, height: 770) : InstrumentFrameSize(width: 800, height: 480)
    }
}

/// 仪表输出的编码码率。自动档按 profile 的像素倍率从 2.5 Mbit/s 起算并随帧率放大；
/// 手动档直接给定值。码率越高越清晰，也越吃仪表 Wi-Fi 和解码能力。
enum ZeehoBitrate: Int, CaseIterable, Sendable {
    case auto = 0, m12 = 12, m15 = 15, m18 = 18, m24 = 24, m30 = 30

    var title: String { self == .auto ? "自动（随帧率）" : "\(rawValue) Mbit/s" }
    var bitsPerSecond: Int? { self == .auto ? nil : rawValue * 1_000_000 }
}

/// H.264 编码档位。Main 允许 CABAC，同码率下文字更干净；极个别老解码器只认 Baseline。
enum ZeehoEncodeProfile: Int, CaseIterable, Sendable {
    case baseline = 0, main = 1

    var title: String { self == .baseline ? "Baseline（兼容）" : "Main（更清晰）" }
}

/// A bounded compressed-frame FIFO. On overflow, discard the dependent GOP and wait for IDR.
/// The owner supplies synchronization and SPS/PPS with every keyframe.
struct ZeehoRelayBuffer {
    private var frames: [Data] = []
    private var bytes = 0
    private(set) var waitingForKeyframe = true
    private(set) var discardedGroups = 0
    let maximumFrames: Int
    let maximumBytes: Int

    init(maximumFrames: Int = 30, maximumBytes: Int = 8 * 1024 * 1024) {
        precondition(maximumFrames > 0 && maximumBytes > 0)
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        bytes = 0
        waitingForKeyframe = true
    }

    /// True means that a new keyframe is required. Never retain a dependent tail after overflow.
    mutating func append(_ data: Data, keyframe: Bool) -> Bool {
        if data.count > maximumBytes {
            reset(); discardedGroups += 1
            return true
        }
        if frames.count >= maximumFrames || bytes + data.count > maximumBytes {
            reset(); discardedGroups += 1
        }
        guard !waitingForKeyframe || keyframe else { return true }
        waitingForKeyframe = false
        frames.append(data); bytes += data.count
        return false
    }

    mutating func pop() -> Data? {
        guard !frames.isEmpty else { return nil }
        let result = frames.removeFirst()
        bytes -= result.count
        return result
    }
}

struct InstrumentFrameSize: Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)×\(height)" }

    func fittedRect(for source: CGSize) -> CGRect {
        let canvasWidth = CGFloat(width), canvasHeight = CGFloat(height)
        let scale = min(canvasWidth / source.width, canvasHeight / source.height)
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: (canvasWidth - w) / 2, y: (canvasHeight - h) / 2, width: w, height: h)
    }
}

enum TailingDisplayProfile: Equatable, Sendable {
    case tailing43
    case zeeho62
    case zeehoSEPlus
    case zeehoAE2
    /// 2026 款极核 AE4i Pro+ 这类新一代 6.2 寸仪表：面板像素 2048×968
    /// （1024×484 的 2 倍），媒体配置阶段就上报这个尺寸。
    case zeehoAE4i

    var isZeeho: Bool { self != .tailing43 }

    /// CarPlay starts producing frames before the instrument reports its media dimensions.
    var preferredSize: InstrumentFrameSize {
        switch self {
        case .tailing43: return InstrumentFrameSize(width: 480, height: 272)
        case .zeeho62, .zeehoAE2: return InstrumentFrameSize(width: 1024, height: 480)
        case .zeehoSEPlus: return InstrumentFrameSize(width: 800, height: 480)
        // 按面板像素向 CarPlay 请求画面，缩放时才能一比一，不白白放大 2 倍。
        case .zeehoAE4i: return InstrumentFrameSize(width: 2048, height: 968)
        }
    }

    /// 编码码率随仪表输出像素数放大。旧款 6.2 寸 1024×480 用 2.5 Mbit/s 实测可用，
    /// 2048×968 的像素数是它的 4 倍；再留一点余量给文字边缘，取 6 倍。
    var bitrateScale: Double {
        switch self {
        case .zeehoAE4i: return 6
        default: return 1
        }
    }

    /// 2 倍屏上的文字边缘对量化很敏感，编码时优先画质而不是编码速度。
    var prioritizesEncodingQuality: Bool { self == .zeehoAE4i }

    func outputSize(for reported: InstrumentFrameSize) -> InstrumentFrameSize? {
        switch self {
        case .tailing43:
            return reported == preferredSize ? preferredSize : nil
        case .zeeho62:
            guard reported.width == 1024, reported.height == 480 || reported.height == 488 else { return nil }
            return preferredSize
        case .zeehoAE2:
            guard (240...1920).contains(reported.width), (240...1080).contains(reported.height) else { return nil }
            return InstrumentFrameSize(width: reported.width & ~1, height: reported.height & ~1)
        case .zeehoSEPlus:
            // Use the PXC media dimensions verbatim. Bound pixel-buffer allocations and
            // require even dimensions for the encoder's 4:2:0 chroma format.
            guard (2...1920).contains(reported.width), (2...1080).contains(reported.height),
                  reported.width >= reported.height, reported.width.isMultiple(of: 2),
                  reported.height.isMultiple(of: 2) else { return nil }
            return reported
        case .zeehoAE4i:
            // 仪表上报的多半就是它自己解码缓冲区的尺寸：2048×968 是 1024×484 面板的
            // 2 倍上报。按上报尺寸原样编码，仪表放大或一比一都正确；老款 1024×480 的
            // 6.2 寸仪表选到这一项时也接受，编码时再缩到它的尺寸。
            guard (1024...2048).contains(reported.width), (480...1080).contains(reported.height),
                  reported.width >= reported.height, reported.width.isMultiple(of: 2),
                  reported.height.isMultiple(of: 2) else { return nil }
            return reported
        }
    }
}
