// Read-only Swift adaptation of lswlc33/maibms LuXingProtocol (MIT).
// Reference: 6bbb5d64ef823385df5f5b8dd54580594a604ba5. See LICENSES/maibms-MIT.txt.
import Foundation

extension BMSReadOnlyProtocol {
    // EM02's register table, not the unrelated CJ01/ECU02 table.
    static let luxingBlocks: [(address: Int, count: Int, length: Int)] = [
        (4000, 89, 178), (4092, 54, 108), (4200, 45, 90), (4152, 48, 96)
    ]

    func drainLuXing(_ now: Double) -> [ANTBMSReading] {
        guard buffer.first == 1 else { buffer.removeFirst(); return [] }
        guard buffer.count >= 2 else { return [] }
        let exception = buffer[1] == 0x83
        guard exception || buffer[1] == 3 else { buffer.removeFirst(); return [] }
        guard buffer.count >= 3 else { return [] }
        let count = Int(buffer[2])
        guard exception || Self.luxingBlocks.contains(where: { $0.length == count }) else {
            buffer.removeFirst(); return []
        }
        let length = exception ? 5 : count + 5
        guard buffer.count >= length else { return [] }
        let frame = Array(buffer.prefix(length))
        // Validate receive CRC too. A malformed frame cannot refresh a sample.
        guard Self.withCRC(Array(frame.dropLast(2))) == frame else {
            buffer.removeFirst(); error = "陆行 CRC 校验失败"; return []
        }
        buffer.removeFirst(length)
        guard let pending else { return [] }
        if exception {
            complete(now: now); step = (step + 1) % 4
            error = "陆行读取异常（\(count)），继续读取下一块"
            return []
        }
        guard count == pending else { return [] }
        let d = BMSBytes(Array(frame[3..<(length - 2)]))
        complete(now: now); step = (step + 1) % 4
        switch count {
        case 90:
            // Relay-board voltage at offset 18 must NEVER become meter voltage.
            luxingRelay = [:]; luxingRelayAt = now
            luxingRelay["中继绑定"] = d.u8(0) == 1 ? "已绑定" : "未绑定"
            luxingRelay["中继连接"] = d.u8(1) == 1 ? "已连接" : "未连接"
            luxingRelay["中继品牌"] = Self.luxingVendor(d.u8(50)) ?? "未知（\(d.u8(50))）"
            let name = d.text(51, 33)
            if !name.isEmpty { luxingRelay["中继名称"] = name }
            let mac = Array(d.b[84..<90])
            if !mac.allSatisfy({ $0 == 0 }) && !mac.allSatisfy({ $0 == 255 }) {
                luxingRelay["中继 MAC"] = mac.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
            return []
        case 96:
            luxingCycles = d.le16(0) == 0xffff ? nil : d.le16(0)
            luxingCyclesAt = now
            return []
        case 108:
            return decodeLuXingRealtime(d, now: now)
        default:
            return [] // Device information cannot revive stale realtime data.
        }
    }

    private func decodeLuXingRealtime(_ d: BMSBytes, now: Double) -> [ANTBMSReading] {
        guard d.u8(0) <= 30, d.u8(2) <= 1, d.u8(4) <= 1, d.u8(7) <= 8 else {
            error = "陆行 EM02 实时布局不兼容"; return []
        }
        var reading = BMSValues()
        let rawVoltage = d.le32(22), rawCurrent = d.le32(26)
        if rawVoltage != 0xffffffff {
            let voltage = Double(rawVoltage) / 1000
            if voltage > 0 && voltage <= 650 { reading.voltage = voltage }
        }
        if rawCurrent != 0x7fffffff {
            let current = Double(d.li32(26)) / 100
            if abs(current) <= 10_000 {
                reading.current = current
                // Preserve factory sign: positive charging, negative discharging.
                reading.state = abs(current) <= 0.3 ? 1 : current > 0 ? 2 : 4
            }
        }
        if d.li16(20) != 32767 { reading.power = d.li16(20) }
        if d.u8(106) <= 100 { reading.soc = d.u8(106) }
        if d.le16(102) != 0xffff, d.le16(102) > 0 {
            reading.capacity = Double(d.le16(102)) / 10
            if let soc = reading.soc { reading.remaining = reading.capacity! * Double(soc) / 100 }
        }
        // actualCapacity (104) and SOH (107) have no adopted mapping.
        reading.cells = (0..<d.u8(0)).map { index in
            let raw = d.le16(30 + index * 2)
            return (500...6000).contains(raw) ? Double(raw) / 1000 : nil
        }
        func temperature(_ offset: Int) -> Double? {
            let value = Int(Int8(bitPattern: d.b[offset])) - 40
            return value != -40 && (-50...150).contains(value) ? Double(value) : nil
        }
        if d.u8(2) > 0 { reading.mos = temperature(3) }
        if d.u8(4) > 0 { reading.temperatures.append(temperature(5)) }
        reading.temperatures += (0..<d.u8(7)).map { temperature(8 + $0) }
        let high = d.le16(92), low = d.le16(94)
        if (500...6000).contains(low), (low...6000).contains(high) {
            reading.delta = Double(high - low) / 1000
            reading.details["最高单体"] = String(format: "%.3f V", Double(high) / 1000)
            reading.details["最低单体"] = String(format: "%.3f V", Double(low) / 1000)
        }
        if now - luxingRelayAt <= 15 { reading.details.merge(luxingRelay) { _, new in new } }
        if now - luxingCyclesAt <= 15, let luxingCycles { reading.details["循环次数"] = String(luxingCycles) }
        reading.details["协议"] = "陆行 EM2APP / EM02 · FC03 · CRC16"
        reading.details["总压来源"] = "电量计自测 systemVoltage（108 字节实时块）"
        reading.details["电流方向"] = "保留原厂符号：正值充电，负值放电"
        if reading.remaining != nil { reading.details["剩余容量来源"] = "计算值：SOC × 额定容量，非直接测量" }
        guard reading.voltage != nil || reading.current != nil || reading.soc != nil ||
                reading.cells.contains(where: { $0 != nil }) else { return [] }
        values = reading
        return [reading.reading(.luxing)]
    }

    private static func luxingVendor(_ id: Int) -> String? {
        [1: "彦阳保护板", 2: "蚂蚁保护板", 3: "嘉佰达保护板", 4: "极空保护板",
         5: "超力源保护板", 6: "达理保护板", 7: "小哈个人", 8: "陆行电量计",
         9: "蓝宝电量计", 10: "蓝宝电量计（带天线）", 11: "黑蛇精灵", 12: "明唐",
         13: "小哈换电", 14: "电岭", 15: "锋锐", 16: "比亚迪", 17: "亿纬", 18: "超威",
         19: "天能", 20: "闪充", 21: "佰铭城", 22: "黄金锂电", 23: "华集源", 24: "弗铭",
         25: "星恒", 26: "新途", 28: "优旦", 29: "中船海为", 30: "克林", 31: "乐充",
         32: "澄芯", 33: "新能安", 34: "美顺"][id]
    }
}
