// Read-only YYBMS layout adaptation from maibms, MIT. Only FC03 is emitted.
import Foundation

extension BMSReadOnlyProtocol {
    func drainYY(_ now: Double) -> [ANTBMSReading] {
        guard !buffer.isEmpty else { return [] }
        guard buffer[0] > 0, buffer[0] <= 247 else { buffer.removeFirst();return [] }
        guard buffer.count >= 3 else { return [] }
        guard buffer[1]==3 || buffer[1]==0x83 else { buffer.removeFirst();return [] }
        let length = buffer[1]==3 ? Int(buffer[2])+5:5
        guard length<=167, buffer[1] != 3 || buffer[2]%2==0 else { buffer.removeFirst();return [] }
        guard buffer.count>=length else { return [] }
        let frame=Array(buffer.prefix(length))
        guard Self.withCRC(Array(frame.dropLast(2)))==frame else { buffer.removeFirst();error="彦阳 CRC 校验失败";return [] }
        buffer.removeFirst(length)
        guard let command=pending, command==0 || Int(frame[0])==yyAddress else { return [] }
        if frame[1]==0x83 { sentAt=now-10;timedOut(now);return [] }
        let expected = command==63 ? 8:command==0 ? 2:command==80 ? 160:command==48 ? 84:command==90 ? 44:yyLayout==2 ? 94:158
        guard Int(frame[2])==expected else { return [] }
        let d=BMSBytes(Array(frame[3..<(length-2)]))
        complete(now:now)
        if command==0 {
            let address=d.le16(0)
            guard (1...247).contains(address) else { yyLayout=2;step=0;return [] }
            yyAddress=address;yyProbe=0;step=0;return []
        }
        if command==63 { yyLayout=d.le32(0)==0x4d444253 ? 1:2; yyProbe=2;step=0;return [] }
        if yyLayout==2 {
            if command==1 {
                let count=d.u8(12),sensors=d.u8(13)
                let voltage=Double(UInt32(d.be16(22)) | UInt32(d.be16(24))<<16)/1000
                guard (1...25).contains(count),sensors<=4,(1...200).contains(voltage) else { error="彦阳旧 A 布局不兼容";return [] }
                let cells=(0..<min(count,18)).map { d.be16(44+$0*2) }
                let sum=Double(cells.reduce(0,+))/1000, tolerance=max(1,voltage*0.1),extra=count-cells.count
                guard cells.allSatisfy({(500...6000).contains($0)}),
                      voltage>=sum+Double(extra)*0.5-tolerance,voltage<=sum+Double(extra)*6+tolerance else { return [] }
                let previousCells=now-auxiliaryAt<=5 ? values.cells:[]
                values=BMSValues();values.voltage=voltage;yyCells=count
                values.cells=(0..<count).map { $0<cells.count ? Double(cells[$0])/1000:$0<previousCells.count ? previousCells[$0]:nil }
                let serial=(0..<6).map { String(format:"%04X",d.be16($0*2)) }.joined()
                yyThermal = !["0001","5948","0008","0009","000A","010A"].contains(String(serial.prefix(4)))
                if yyThermal {
                    values.temperatures=[81,80,83,82].prefix(sensors).map { pos in
                        let raw=d.u8(pos);return (1...127).contains(raw) ? Double(raw-40):nil
                    }
                }
                values.details=["协议":"YYBMS 旧 A（待实物验证）","原始电流（方向未确认）":String(format:"%.2f A",Double(d.bi16(26))/100),
                    "原始 SOC":String(d.be16(38)),"原始容量1":String(d.be16(40)),"原始容量2":String(d.be16(42))]
                mainAt=now;step=1
                return [values.reading(.yanyang)]
            }
            if command==48,yyCells>18 {
                for i in 18..<yyCells {
                    let raw=d.be16(40+(i-18)*2)
                    if i<values.cells.count { values.cells[i]=(500...6000).contains(raw) ? Double(raw)/1000:nil }
                }
                auxiliaryAt=now;step=2
                if now-mainAt<=5 { return [values.reading(.yanyang)] }
            } else { step=0 }
            return []
        }
        if command==1 {
            guard d.le32(124)==0x4d444253 else { halted=true;error="彦阳基础块魔数不符，停止解析";return [] }
            let count=d.u8(148),batt=d.u8(103),mos=d.u8(104),balance=d.u8(105)
            guard (1...25).contains(count),batt<=8,mos<=1,balance<=1 else { return [] }
            let voltage=Double(d.li32(150))/1000
            guard voltage>0,voltage<=200 else { return [] }
            yyLayout=1;yyCells=count;yySensors=(batt,mos,balance)
            let previous=values
            values=BMSValues();values.voltage=voltage;values.current=Double(d.li32(154))/100
            values.power=Int((voltage*values.current!).rounded())
            if now-auxiliaryAt<=5 {
                values.cells=previous.cells;values.soc=previous.soc;values.soh=previous.soh
                values.capacity=previous.capacity;values.remaining=previous.remaining
                values.temperatures=previous.temperatures;values.mos=previous.mos
                values.protection=previous.protection;values.warnings=previous.warnings;values.state=previous.state
            }
            let serial=d.b[2..<10].map { String(format:"%02X",$0) }.joined()
            yyThermal = !["0001","5948","0008","0009","000A","010A"].contains(String(serial.prefix(4)))
            values.details=["协议":"YYBMS B","型号":d.text(12,26),"产品":d.text(38,36),"串数":String(count),"地址":String(yyAddress)]
            mainAt=now;step=1
            return [values.reading(.yanyang)]
        }
        guard command==80,yyCells>0,now-mainAt<=5 else { step=0;return [] }
        let state=Int((d.le32(144)>>26)&3)
        if let raw=values.current {
            values.current=state==1 ? -abs(raw):state==2 ? abs(raw):raw
            values.power=Int((values.voltage! * values.current!).rounded())
        }
        values.soc=d.u8(80)<=100 ? d.u8(80):nil;values.soh=d.u8(81)<=100 ? d.u8(81):nil
        values.capacity=Double(d.le16(76))/10;values.remaining=Double(d.le16(78))/10
        values.cells=(0..<yyCells).map { i in
            let raw=d.le16(2+i*2)
            return ![0,20,35,36].contains(raw) && raw<=5000 ? Double(raw)/1000:nil
        }
        values.temperatures=[];values.mos=nil
        func thermal(_ pos:Int)->Double? {
            let raw=d.u8(pos);return raw != 0 && raw != 166 ? Double(raw-40):nil
        }
        if yyThermal {
            if yySensors.1>0 { values.mos=thermal(64) }
            if yySensors.2>0 { values.temperatures.append(thermal(65)) }
            values.temperatures += (0..<yySensors.0).map { thermal(66+$0) }
        }
        let faults=UInt64(d.le32(152)),protectionMask:UInt64=(0x3fff | (3<<17) | (0x7f<<25))
        values.protection=faults & protectionMask;values.warnings=faults & ((1<<14)|(0x3f<<19))
        values.state=state==1 ? 2:state==2 ? 4:1
        values.details["循环次数"]=String(d.u8(95))
        values.details["均衡位"]=String(format:"%08X",d.le32(118))
        auxiliaryAt=now;step=0
        return [values.reading(.yanyang)]
    }
}
