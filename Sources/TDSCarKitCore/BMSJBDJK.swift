// Swift adaptation of maibms JbdProtocol / JikongProtocol, MIT; pinned source in docs/multibrand-bms.md.
import Foundation

extension BMSReadOnlyProtocol {
    func drainJBD(_ now: Double) -> [ANTBMSReading] {
        guard let first = buffer.first else { return [] }
        guard first == 0xdd || first == 0xff else { buffer.removeFirst(); return [] }
        guard buffer.count >= 4 else { return [] }
        if first == 0xff {
            guard buffer[1] == 0xaa else { buffer.removeFirst(); return [] }
            let count = Int(buffer[3]), total = count + 5
            guard count <= 32 else { buffer.removeFirst(); return [] }
            guard buffer.count >= total else { return [] }
            let frame = Array(buffer.prefix(total)); buffer.removeFirst(total)
            guard frame[2..<total-1].reduce(UInt8(0), &+) == frame.last,
                  pending == Int(frame[2]), (1...4).contains(authStage), count == 1 else { return [] }
            let command = Int(frame[2]), status = frame[4]
            complete(now: now)
            if command == 0x15 {
                if status == 0 { authStage = authStage == 1 ? 5 : 3; step = 0 }
                else if status == 2 { authStage = 5; step = 0 }
                else { authFailed(command: command) }
            } else if command == 0x17 { challenge = status; authStage = 4 }
            else if command == 0x18 {
                if status == 0 { authStage = 5; step = 0 }
                else { halted = true; error = "JBD 密码被拒绝，请核对自己的密码" }
            }
            return []
        }
        guard (3...5).contains(buffer[1]) || buffer[1] == 0x80 || buffer[1] == 0x83 else { buffer.removeFirst(); return [] }
        let count = Int(buffer[3]), total = count + 7
        guard buffer.count >= total else { return [] }
        let frame = Array(buffer.prefix(total))
        let sum = frame[2..<(4+count)].reduce(UInt16(0)) { $0 &+ UInt16($1) }
        guard frame.last == 0x77, UInt16(BMSBytes(frame).be16(total-3)) == 0 &- sum else {
            buffer.removeFirst(); error = "JBD 应答校验失败"; return []
        }
        buffer.removeFirst(total)
        let command = Int(frame[1])
        guard pending == command || frame[1] == 0x80 || frame[1] == 0x83 else { return [] }
        complete(now: now)
        guard frame[2] == 0, (3...5).contains(command) else { authFailed(command: 3); return [] }
        let d = BMSBytes(Array(frame[4..<(4+count)]))
        if command == 3 {
            guard count >= 23, (1...32).contains(d.u8(21)), d.u8(22) <= 16, count >= 23 + d.u8(22)*2,
                  d.be16(0) > 0, d.be16(0) <= 65000, d.u8(19) <= 100 else { return [] }
            let scale = d.u8(20) & 0x80 != 0 ? 0.1 : 0.01
            values.voltage = Double(d.be16(0))/100
            values.current = -Double(d.bi16(2))*scale
            values.soc = d.u8(19); values.capacity = Double(d.be16(6))*scale
            values.remaining = Double(d.be16(4))*scale
            values.power = Int((values.voltage! * values.current!).rounded())
            values.state = abs(values.current!) < 0.01 ? 1 : values.current! < 0 ? 2 : 4
            values.protection = UInt64(d.be16(16)); values.warnings = 0
            values.temperatures = (0..<d.u8(22)).map { i in
                let raw = d.be16(23+i*2)
                return raw != 0 && raw != 0xffff ? Double(raw-2731)/10 : nil
            }
            if now - auxiliaryAt > 5 { values.cells = [] }
            values.details["循环次数"] = String(d.be16(8))
            values.details["串数"] = String(d.u8(21))
            values.details["MOS"] = "充电 \(d.u8(20)&1 != 0 ? "开" : "关") / 放电 \(d.u8(20)&2 != 0 ? "开" : "关")"
            values.details["均衡位"] = String(format:"%08X",UInt32(d.be16(12)) | UInt32(d.be16(14))<<16)
            let date = d.be16(10)
            if (1...12).contains(date>>5&15), (1...31).contains(date&31) {
                values.details["生产日期"] = String(format:"%04d-%02d-%02d",2000+(date>>9),date>>5&15,date&31)
            }
            mainAt = now; step = 1; authStage = 5
            return [values.reading(.jbd)]
        } else if command == 4 {
            guard count > 0, count <= 64, count % 2 == 0 else { return [] }
            values.cells = stride(from:0,to:count,by:2).map { i in
                let value = d.be16(i); return (500...6000).contains(value) ? Double(value)/1000 : nil
            }
            auxiliaryAt = now
            // Never refresh the main reading's freshness from cell-only traffic.
            step = step == 1 ? 4 : 0
        } else { values.details["型号"] = d.text(0,count); step = 0 }
        return []
    }

    func drainJK(_ now: Double) -> [ANTBMSReading] {
        guard buffer.count >= 4 else { return [] }
        let response = Array(buffer.prefix(4)) == [0x55,0xaa,0xeb,0x90]
        let command = Array(buffer.prefix(4)) == [0xaa,0x55,0x90,0xeb]
        guard response || command else { buffer.removeFirst(); return [] }
        let count = response ? 300 : 20
        guard buffer.count >= count else { return [] }
        let frame = Array(buffer.prefix(count))
        guard frame.dropLast().reduce(UInt8(0), &+) == frame.last else { buffer.removeFirst(); error="JK 应答校验失败";return [] }
        buffer.removeFirst(count)
        if command { return [] }
        let d = BMSBytes(frame)
        if frame[4] == 3 {
            let model = d.text(6,16), software = d.text(30,8)
            guard model.uppercased().hasPrefix("JK"),
                  let major = Int(software.trimmingCharacters(in:CharacterSet(charactersIn:"Vv")).split(separator:".").first ?? ""),
                  (1...99).contains(major) else { error="JK 设备信息不兼容";return [] }
            version = major; complete(now: now); nextAt = now + 1
            values.details = ["型号":model,"硬件版本":d.text(22,8),"软件版本":software]
            return []
        }
        if frame[4] == 1, d.float(6) == 1, (1...24).contains(d.u8(34)), d.u8(35)==0, d.u8(36)==0, d.u8(37)==0 {
            jk04Count=d.u8(34);return []
        }
        guard frame[4] == 2, let major = version else { return [] }
        let offset = major < 11 ? -32 : 0, slots = major < 11 ? 24 : 32
        let mask = d.le32(70+offset/2)
        let floats = (0..<24).map { d.float(6+$0*4) }
        let floatLayout = floats.filter { (0.5...6).contains($0) }.count >= 2 && floats.allSatisfy { $0 == 0 || (0.5...6).contains($0) }
        let integerLayout = mask != 0 && (0..<slots).filter { mask & (UInt32(1)<<$0) != 0 }.allSatisfy { (500...6000).contains(d.le16(6+$0*2)) }
        if jk04 == nil {
            guard floatLayout != integerLayout else { error="JK02 / JK04 布局无法确认";return [] }
            jk04 = floatLayout
        }
        let identity = values.details
        if jk04 == true {
            let count = jk04Count ?? ((floats.lastIndex { (0.5...6).contains($0) } ?? -1)+1)
            guard (2...24).contains(count), floats.prefix(count).allSatisfy({(0.5...6).contains($0)}), d.u8(220)<=2 else { return [] }
            values = BMSValues(); values.details=identity
            values.cells=floats.prefix(count).map(Optional.some);values.voltage=floats.prefix(count).reduce(0,+)
            values.details["协议"]="JK04";values.details["总压来源"]="有效单体电压之和"
            values.details["均衡"] = d.u8(220)==0 ? "待机" : "均衡中"
            values.details["运行秒数"]=String(d.le32(286))
        } else {
            guard integerLayout, let last = (0..<slots).last(where:{ mask & (UInt32(1)<<$0) != 0 }) else { return [] }
            let voltage=Double(d.le32(150+offset))/1000
            guard voltage>0, voltage<=200 else { return [] }
            values=BMSValues();values.details=identity
            values.voltage=voltage;values.current = -Double(d.li32(158+offset))/1000
            values.power=Int((voltage*values.current!).rounded());values.soc=d.u8(173+offset)<=100 ? d.u8(173+offset):nil
            values.soh=d.u8(190+offset)<=100 ? d.u8(190+offset):nil
            let cap=Double(d.le32(178+offset))/1000
            values.capacity=cap>0 ? cap:nil;values.remaining=Double(d.le32(174+offset))/1000
            values.cells=(0...last).map { i in
                let raw=d.le16(6+i*2);return mask & (UInt32(1)<<i) != 0 && (1...5000).contains(raw) ? Double(raw)/1000:nil
            }
            let positions = major<11 ? [130,132,134] : [144,162,164,254]+(major>=14 ? [256,258]:[])
            let thermal=d.u8(214+offset)
            for (index,pos) in positions.enumerated() where thermal & (1<<index) != 0 && d.li16(pos) != -2000 {
                let value=Double(d.li16(pos))/10
                if (-100...200).contains(value) {
                    if pos == 134 || pos == 144 { values.mos = value } else { values.temperatures.append(value) }
                }
            }
            let faults = offset==0 ? d.le32(166):d.le32(166+offset)>>16
            values.protection=UInt64(faults & ~((1<<4)|(1<<19)));values.warnings=UInt64(faults & (1<<19))
            values.state=abs(values.current!)<0.05 ? 1:values.current! < 0 ? 2:4
            values.details["协议"]=major<11 ? "JK02 24S":"JK02 32S"
            values.details["循环次数"]=String(d.le32(182+offset))
            values.details["均衡"]=d.u8(172+offset)==0 ? "关":"开"
        }
        complete(now:now);nextAt=now+0.6;mainAt=now
        return [values.reading(.jikong)]
    }
}
