// Read-only Swift adaptation of maibms LanBaoProtocol (MIT).
import Foundation

extension BMSReadOnlyProtocol {
    func drainLanbao(_ now:Double)->[ANTBMSReading] {
        guard !buffer.isEmpty else { return [] }
        guard buffer[0]==0xfa else { buffer.removeFirst();return [] }
        guard buffer.count>=5 else { return [] }
        guard buffer[1]==0x50,buffer[4]==0x15 else { buffer.removeFirst();return [] }
        guard buffer.count>=130 else { return [] }
        let candidates=[130,153].filter { size in
            guard buffer.count>=size else { return false }
            let frame=Array(buffer.prefix(size))
            return frame.last==0xe5 && Self.withCRC(Array(frame.dropLast(3)),polynomial:0xc328,bigEndian:true)+[0xe5]==frame
        }
        guard let size=candidates.first else {
            if buffer.count>=153 {buffer.removeFirst();error="蓝宝 CRC 校验失败"};return []
        }
        let frame=Array(buffer.prefix(size));buffer.removeFirst(size)
        guard pending != nil else { return [] }
        let d=BMSBytes(Array(frame[16..<(size-3)]))
        complete(now:now);step+=1
        if size==153 {
            let cap=Double(d.be32(48))/1000
            values.capacity=cap>0 ? cap:nil;auxiliaryAt=now
            values.details["序列号"]=d.text(0,16);values.details["硬件版本"]=d.text(16,8);values.details["软件版本"]=d.text(24,8)
            values.details["串数"]=String(d.u8(47));values.details["循环次数"]=String(d.be16(57))
            return []
        }
        let voltage=Double(d.be16(0))/100,soc=d.be16(6)/10
        guard voltage>0,voltage<=650,soc<=100 else { return [] }
        values.voltage=voltage;values.current=Double(d.bi32(2))/100;values.soc=soc
        values.power=d.bi32(19);values.remaining=Double(d.be32(15))/100000
        values.temperatures=[Double(Int(Int8(bitPattern:d.b[14])))];values.cells=[]
        values.delta=Double(d.be16(86))/1000
        values.state=abs(values.current!)<0.3 ? 1:values.current!>0 ? 2:4 // meter retains factory signs
        values.details["中继品牌"]=[1:"ANT",2:"彦阳",3:"极空",4:"JBD"][d.u8(50)] ?? "未知"
        values.details["中继名称"]=d.text(57,25)
        values.details["最高单体"]=String(format:"%.3f V",Double(d.be16(82))/1000)
        values.details["最低单体"]=String(format:"%.3f V",Double(d.be16(84))/1000)
        values.details["协议"]="蓝宝 FA50 双表"
        if now-auxiliaryAt>15 {values.capacity=nil}
        return [values.reading(.lanbao)]
    }
}
