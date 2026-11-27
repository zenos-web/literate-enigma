import Foundation

/// Selected support levels follow maibms 6bbb5d6 (2026-11-20); identification is not protocol validation.
public enum BMSFamily: String, CaseIterable, Codable {
    case ant, yanyang, jikong, lanbao, jbd, luxing
    public var title: String {
        switch self {
        case .ant: return CWL("蚂蚁保护板")
        case .yanyang: return CWL("彦阳保护板")
        case .jikong: return CWL("极空保护板")
        case .lanbao: return CWL("蓝宝电量计")
        case .luxing: return CWL("陆行电量计")
        case .jbd: return CWL("嘉佰达保护板")
        }
    }
    public var shortName: String {
        switch self {
        case .ant: CWL("蚂蚁")
        case .yanyang: CWL("彦阳")
        case .jikong: CWL("极空")
        case .lanbao: CWL("蓝宝")
        case .luxing: CWL("陆行")
        case .jbd: CWL("嘉佰达")
        }
    }
    public var protocolDescription: String {
        switch self {
        case .ant: "ANT · FFE0/FFE1"
        case .yanyang: "YYBMS B / 旧 A"
        case .jikong: "JK02 24S / 32S、JK04"
        case .lanbao: "FA50 双表"
        case .luxing: "EM2APP / EM02 · FC03"
        case .jbd: "JBD 经典 BLE / DD"
        }
    }
    public var supportsGATT: Bool { true }
    public var supportDescription: String {
        switch self {
        case .ant: return CWL("只读实时帧；沿用已验证的 ANT 通道。")
        case .yanyang: return CWL("B 代与旧 A 基础布局；旧 A 的电流方向和 SOC 未确认，隐藏相关值。")
        case .jikong: return CWL("JK02 24S / 32S；JK04 仅单体、总压和均衡，不提供电流或 SOC。")
        case .lanbao: return CWL("FA50 双表及中继信息；没有逐串网格、MOS 或 SOH。匹配码可在本机配置。")
        case .luxing: return CWL("EM2APP / EM02 只读：自测总压、电流、功率、SOC、最多 30 串、有效温度和中继信息。剩余容量按 SOC × 额定容量计算；不提供保护控制或 SOH。待真机验证。")
        case .jbd: return CWL("经典 DD 只读；需要登录的模块可填写自己的密码与真实 MAC，不修改设备密码。")
        }
    }
    public struct Channel: Equatable {
        public let service: String
        public let write: String
        public let notify: String
        public init(_ service: String, _ write: String, _ notify: String) {
            self.service = service; self.write = write; self.notify = notify
        }
    }
    public var channels: [Channel] {
        switch self {
        case .ant, .jikong: return [.init("FFE0", "FFE1", "FFE1")]
        case .yanyang: return [.init("FFE0", "FFE2", "FFE1"), .init("FFE0", "FFE1", "FFE1"),
            .init("FEE9", "D44BC439-ABFD-45A2-B575-925416129600", "FEE1"),
            .init("FEE9", "8EC90001-F315-4F60-9FB8-838830DAEA50", "8EC90002-F315-4F60-9FB8-838830DAEA50")]
        case .lanbao, .luxing: return [.init("FFE0", "FFE2", "FFE1")]
        case .jbd: return [.init("FF00", "FF02", "FF01"), .init("FFE0", "FFE1", "FFE1")]
        }
    }
    public static func identify(name: String, services: [String] = [], manufacturerID: UInt16? = nil) -> Self? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !n.hasPrefix("CJ01") else { return nil }
        if n.range(of: "^BT[0-9]+$", options: .regularExpression) != nil { return .yanyang }
        let prefixes: [(Self, [String])] = [(.ant,["ANT"]),(.yanyang,["YYBMS","YY-","彦阳"]),
            (.jikong,["JK-","JK_","极空"]),(.jbd,["JBD","SP","DB","嘉佰达","XIAOXIANG","DP04S","GJ-"]),
            (.luxing,["EM2APP"]),(.lanbao,["BLUEBABE","BLUE","LB"]) ]
        if let match = prefixes.first(where: { $0.1.contains { n.hasPrefix($0) } }) { return match.0 }
        if n.range(of: "^AP2[0-9]S", options: .regularExpression) != nil { return .jbd }
        let services = services.map { $0.uppercased().replacingOccurrences(of: "0000-1000-8000-00805F9B34FB", with: "") }
        func has(_ s: String) -> Bool { services.contains { $0 == s || $0 == "0000" + s + "-" } }
        if has("FF00") { return .jbd }
        if has("FEE9") { return .yanyang }
        if has("FFE0"), (manufacturerID == 0x0b65 || manufacturerID == 0x4b4a) { return .jikong }
        return nil // FFE0 and Nordic UART alone never select a protocol.
    }
}

/// Optional values stay optional until mapped to the existing renderer, which uses availability.
struct BMSValues {
    var voltage: Double?
    var current: Double?
    var soc: Int?
    var power: Int?
    var capacity: Double?
    var remaining: Double?
    var soh: Int?
    var cells: [Double?] = []
    var temperatures: [Double?] = []
    var mos: Double?
    var protection: UInt64?
    var warnings: UInt64?
    var delta: Double?
    var state: Int?
    var details: [String: String] = [:]
    func reading(_ family: BMSFamily) -> ANTBMSReading {
        var value = ANTBMSReading(voltage: voltage ?? 0, current: current ?? 0, power: power ?? 0,
            stateOfCharge: soc ?? 0, stateOfHealth: soh, stateCode: state ?? 0, capacityAh: capacity ?? 0,
            remainingAh: remaining ?? 0, cells: cells, temperatures: temperatures, mosTemperature: mos,
            protectionBits: protection ?? 0, warningBits: warnings ?? 0)
        value.family = family
        value.available = Set([voltage != nil ? "voltage" : nil, current != nil ? "current" : nil,
            soc != nil ? "charge" : nil, power != nil ? "power" : nil, capacity != nil ? "capacity" : nil,
            remaining != nil ? "remaining" : nil, state != nil ? "state" : nil,
            protection != nil ? "protection" : nil, warnings != nil ? "warnings" : nil].compactMap { $0 })
        value.reportedCellDelta = delta
        value.extraDetails = details
        return value
    }
}
