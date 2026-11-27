import Foundation

/// Capabilities accumulate validated fields for one device/protocol variant. Missing frames never shrink layout.
public struct BMSFieldCapabilities: Equatable {
    public typealias Field = ANTBMSCardConfiguration.Field
    public enum Availability: Equatable {
        case available, temporarilyMissing, waiting, notProvided
        public var title: String {
            switch self {
            case .available: "当前可读取"
            case .temporarilyMissing: "暂未读到"
            case .waiting: "等待确认"
            case .notProvided: "当前协议未提供"
            }
        }
    }
    public let family: BMSFamily
    public private(set) var observed: Set<Field> = []
    public private(set) var unsupported: Set<Field> = []
    public private(set) var variant: String?
    public init(family: BMSFamily) {
        self.family = family
        unsupported = Self.excluded(family: family, variant: nil)
    }
    public static func fields(in reading: ANTBMSReading) -> Set<Field> {
        var fields = Set<Field>()
        for field in [Field.charge, .voltage, .current, .power] where reading.available.contains(field.rawValue) {
            fields.insert(field)
        }
        if reading.maximumTemperature != nil { fields.insert(.temperature) }
        if reading.reportedCellDelta != nil || reading.cells.compactMap({ $0 }).count >= 2 { fields.insert(.cellDelta) }
        return fields
    }
    public mutating func observe(_ reading: ANTBMSReading) {
        guard reading.family == family else { return }
        let nextVariant: String
        switch family {
        case .jikong: nextVariant = reading.extraDetails["协议"] == "JK04" ? "JK04" : "JK02"
        case .yanyang: nextVariant = reading.extraDetails["协议"]?.contains("旧 A") == true ? "旧 A" : "B"
        default: nextVariant = family.rawValue
        }
        if let variant, variant != nextVariant { observed.removeAll() }
        variant = nextVariant
        unsupported = Self.excluded(family: family, variant: variant)
        observed.formUnion(Self.fields(in: reading).subtracting(unsupported))
    }
    private static func excluded(family: BMSFamily, variant: String?) -> Set<Field> {
        switch family {
        case .jikong where variant == "JK04": return [.charge, .current, .power, .temperature]
        case .yanyang where variant == "旧 A": return [.charge, .current, .power]
        default: return []
        }
    }
    public func availability(of field: Field, reading: ANTBMSReading?) -> Availability {
        if unsupported.contains(field) { return .notProvided }
        if let reading, reading.family == family, Self.fields(in: reading).contains(field) { return .available }
        return observed.contains(field) ? .temporarilyMissing : .waiting
    }
    public func explanation(of field: Field, reading: ANTBMSReading?) -> String {
        switch availability(of: field, reading: reading) {
        case .available:
            if field == .cellDelta {
                return reading?.reportedCellDelta != nil ? "设备报告压差" : "按有效逐串电压计算"
            }
            return "已收到有效数据"
        case .temporarilyMissing: return "曾读取到此字段，等待有效数据恢复；显示 --"
        case .waiting: return "尚未确认此设备是否提供；不填充为零"
        case .notProvided: return "当前接入协议未提供此字段"
        }
    }
    public var recommendedFields: [Field] {
        let order: [Field] = [.charge, .voltage, .current, .temperature, .cellDelta, .power]
        if !observed.isEmpty { return Array(order.filter { observed.contains($0) }.prefix(4)) }
        if family == .jikong { return [.voltage, .cellDelta] }
        return Array(order.filter { !unsupported.contains($0) }.prefix(4))
    }
}
