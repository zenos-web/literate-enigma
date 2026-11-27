import Foundation

/// Connection stages come from BLE events, never inferred from translated log text.
public enum BMSConnectionPhase: Equatable {
    case idle, scanning, connecting, discovering, subscribing, waitingForData
    case receiving, reconnecting, needsAccess, needsFamily, bluetoothUnavailable
}

public struct BMSConnectionPresentation: Equatable {
    public enum Tone: Equatable { case neutral, working, good, attention }
    public enum Action: Equatable { case enable, scan, retry, access, family, settings, none }
    public let title: String
    public let detail: String
    public let tone: Tone
    public let action: Action
    public var actionTitle: String? {
        switch action {
        case .enable: "开启电池读取"
        case .scan: "查找电池"
        case .retry: "立即重试"
        case .access: "检查登录信息"
        case .family: "核对板型"
        case .settings: "打开系统设置"
        case .none: nil
        }
    }
    public init(enabled: Bool, hasSelection: Bool, family: BMSFamily, phase: BMSConnectionPhase,
                hasFreshData: Bool, lastReadingAge: TimeInterval?, reason: String) {
        if !enabled {
            title = "读取已关闭"; detail = "开启后读取电池数据并显示卡片。"
            tone = .neutral; action = .enable; return
        }
        if hasFreshData {
            title = "电池数据正常"
            let age = Int(max(0, min(lastReadingAge ?? 0, 86400)))
            detail = (age == 0 ? "刚刚更新" : "\(age) 秒前更新") + " · 已收到有效实时数据"
            tone = .good; action = .none; return
        }
        if phase == .bluetoothUnavailable {
            title = "蓝牙暂不可用"; detail = reason; tone = .attention; action = .settings; return
        }
        if phase == .needsAccess {
            title = "请检查模块登录信息"; detail = reason; tone = .attention; action = .access; return
        }
        if phase == .needsFamily {
            title = "请核对设备板型"; detail = reason; tone = .attention; action = hasSelection ? .family : .scan; return
        }
        if !hasSelection {
            title = phase == .scanning ? "正在查找电池" : "添加你的电池"
            detail = phase == .scanning ? "选择设备后确认板型，再核对首批读数。" : reason
            tone = phase == .scanning ? .working : .neutral; action = .scan; return
        }
        let prefix: String
        if let age = lastReadingAge {
            let seconds = Int(max(0, min(age, 86400)))
            prefix = "上次有效数据：\(seconds) 秒前。"
        } else { prefix = "" }
        switch phase {
        case .connecting: title = "正在连接电池"; tone = .working; action = .none
        case .discovering, .subscribing: title = "正在准备读取通道"; tone = .working; action = .none
        case .waitingForData: title = "正在读取首批数据"; tone = .working; action = .none
        case .scanning: title = "正在寻找已选电池"; tone = .working; action = .none
        case .receiving: title = "数据已过期"; tone = .attention; action = .retry
        case .reconnecting: title = lastReadingAge == nil ? "等待重新连接" : "数据已过期 · 正在重连"; tone = .attention; action = .retry
        default: title = "等待电池数据"; tone = .neutral; action = .retry
        }
        detail = prefix + reason
    }
}

/// A confirmed manual family takes precedence over advertisement hints.
public enum BMSSelectionPolicy {
    public static func family(saved: String?, inferred: BMSFamily?) -> BMSFamily? {
        guard let saved else { return inferred }
        return BMSFamily(rawValue: saved) // Removed families never silently switch protocols.
    }
}

/// Only valid per-cell voltages contribute to extrema; preserve missing slot positions.
public struct BMSCellSummary: Equatable {
    public let cells: [Double?]
    public let minimum: Double?
    public let maximum: Double?
    public let validCount: Int
    public var delta: Double? {
        guard validCount >= 2, let minimum, let maximum else { return nil }
        return maximum - minimum
    }
    public var lowestSlots: [Int] { cells.indices.filter { cells[$0] != nil && cells[$0] == minimum }.map { $0 + 1 } }
    public var highestSlots: [Int] { cells.indices.filter { cells[$0] != nil && cells[$0] == maximum }.map { $0 + 1 } }
    public init(cells: [Double?]) {
        self.cells = cells.prefix(64).map { value in
            guard let value, value.isFinite, (0.5...6).contains(value) else { return nil }
            return value
        }
        let valid = self.cells.compactMap { $0 }
        validCount = valid.count; minimum = valid.min(); maximum = valid.max()
    }
}
