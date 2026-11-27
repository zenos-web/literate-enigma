// Read-only Swift adaptation of maibms protocol/board and protocol/meter, MIT.
// Source pinned to 6bbb5d64ef823385df5f5b8dd54580594a604ba5. See LICENSES/maibms-MIT.txt.
import Foundation

struct BMSBytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }
    func u8(_ i: Int) -> Int { Int(b[i]) }
    func le16(_ i: Int) -> Int { u8(i) | u8(i + 1) << 8 }
    func be16(_ i: Int) -> Int { u8(i) << 8 | u8(i + 1) }
    func le32(_ i: Int) -> UInt32 { UInt32(le16(i)) | UInt32(le16(i + 2)) << 16 }
    func be32(_ i: Int) -> UInt32 { UInt32(be16(i)) << 16 | UInt32(be16(i + 2)) }
    func li16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(le16(i)))) }
    func bi16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(be16(i)))) }
    func li32(_ i: Int) -> Int { Int(Int32(bitPattern: le32(i))) }
    func bi32(_ i: Int) -> Int { Int(Int32(bitPattern: be32(i))) }
    func float(_ i: Int) -> Double { Double(Float(bitPattern: le32(i))) }
    func text(_ i: Int, _ count: Int) -> String {
        String(bytes: b[i..<min(b.count, i + count)].prefix { $0 != 0 }.filter { (32...126).contains($0) }, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

/// Main-queue session engine. One request in flight; no setters, calibration or MOS commands.
public final class BMSReadOnlyProtocol {
    public let family: BMSFamily
    public internal(set) var error: String?
    var ant = ANTBMSProtocol()
    var buffer: [UInt8] = []
    var pending: Int?
    var sentAt = 0.0
    var lastFragment = 0.0
    var nextAt = 0.0
    var step = 0
    var values = BMSValues()
    var auxiliaryAt = -Double.infinity
    var mainAt = -Double.infinity
    var version: Int?
    var jk04: Bool?
    var jk04Count: Int?
    var yyLayout = 0 // 0 probe, 1 B, 2 legacy A
    var yyAddress = 1
    var yyProbe = 0
    var yyAddressTried = false
    var yyThermal = true
    var yyCells = 0
    var yySensors = (0, 0, 0)
    var luxingRelay: [String: String] = [:]
    var luxingCycles: Int?
    var luxingRelayAt = -Double.infinity
    var luxingCyclesAt = -Double.infinity
    var lanbaoMatch: [UInt8] = [6, 6, 6, 6, 6, 6]
    var accessPassword: [UInt8]?
    var accessMAC: [UInt8]?
    var authStage = 0 // 0 ordinary read, 1 direct, 2 app probe, 3 challenge, 4 login, 5 verified
    var authTried = false
    var legacyAuthTried = false
    var challenge: UInt8 = 0
    var halted = false

    public init(family: BMSFamily, password: String? = nil, mac: String? = nil) {
        self.family = family
        if family == .lanbao, let password {
            if password.count == 6, password.utf8.allSatisfy({ (48...57).contains($0) }) {
                lanbaoMatch = password.utf8.map { $0 - 48 }
            } else if let hex = Self.hex(password.replacingOccurrences(of: " ", with: "")), hex.count == 6 {
                lanbaoMatch = hex
            }
        }
        if family == .jbd, let password, password.utf8.count == 6,
           password.utf8.allSatisfy({ (32...126).contains($0) }) { accessPassword = Array(password.utf8) }
        if let mac, let data = Self.hex(mac.replacingOccurrences(of: ":", with: "")), data.count == 6 { accessMAC = data }
    }
    static func hex(_ s: String) -> [UInt8]? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0, chars.count <= 2048 else { return nil }
        var result: [UInt8] = []
        func digit(_ b: UInt8) -> UInt8? {
            switch b { case 48...57: b - 48; case 65...70: b - 55; case 97...102: b - 87; default: nil }
        }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = digit(chars[i]), let lo = digit(chars[i + 1]) else { return nil }
            result.append(hi << 4 | lo)
        }
        return result
    }
    static func crc(_ bytes: [UInt8], polynomial: UInt16 = 0xa001) -> UInt16 {
        bytes.reduce(UInt16.max) { crc, byte in
            var value = crc ^ UInt16(byte)
            for _ in 0..<8 { value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ polynomial }
            return value
        }
    }
    static func withCRC(_ bytes: [UInt8], polynomial: UInt16 = 0xa001, bigEndian: Bool = false) -> [UInt8] {
        let crc = crc(bytes, polynomial: polynomial)
        let lo = UInt8(truncatingIfNeeded: crc), hi = UInt8(crc >> 8)
        return bytes + (bigEndian ? [hi, lo] : [lo, hi])
    }
    static func jkRequest(_ command: UInt8) -> [UInt8] {
        let bytes: [UInt8] = [0xaa, 0x55, 0x90, 0xeb, command] + [UInt8](repeating: 0, count: 14)
        return bytes + [bytes.reduce(0, &+)]
    }
    func timedOut(_ now: Double) {
        guard let command = pending, now - sentAt >= 3,
              !(family == .yanyang && !buffer.isEmpty && now - lastFragment < 3 && now - sentAt < 10) else { return }
        pending = nil; buffer.removeAll()
        error = "\(family.shortName) 读取超时"
        switch family {
        case .yanyang:
            if yyLayout == 0 {
                if command == 63 { yyProbe += 1 }
                else if command == 1 && !yyAddressTried { yyAddressTried = true; step = -1 }
                else { yyLayout = 2; step = 0 }
            }
        case .luxing: step = (step + 1) % 4
        case .jbd: authFailed(command: command)
        default: break
        }
    }
    func authFailed(command: Int) {
        if command == 3, !authTried, accessPassword != nil { authTried = true; authStage = 1 }
        else if accessMAC != nil, !legacyAuthTried, authTried {
            legacyAuthTried = true; authStage = 2
        } else if command >= 0x15 || authTried { halted = true; error = "JBD 登录失败，请核对已有密码与真实 MAC；未修改设备密码" }
    }
    public func nextRequest(now: TimeInterval) -> Data? {
        guard family.supportsGATT, !halted else { return nil }
        timedOut(now)
        guard pending == nil, !halted, now >= nextAt else { return nil }
        let bytes: [UInt8]; let command: Int
        switch family {
        case .ant:
            bytes = Array(ANTBMSProtocol.realtimeRequest); command = 1
        case .jbd:
            if (1...4).contains(authStage) {
                command = [0, 0x15, 0x15, 0x17, 0x18][authStage]
                var payload = authStage == 2 ? Array("000000".utf8) : (accessPassword ?? [])
                if authStage == 3 { payload = [] }
                if authStage == 4, let mac = accessMAC, let password = accessPassword {
                    payload = zip(mac, password).map { ($0 ^ $1) &+ challenge }
                }
                let body = [UInt8(command), UInt8(payload.count)] + payload
                bytes = [0xff, 0xaa] + body + [body.reduce(0, &+)]
            } else {
                command = step == 0 ? 3 : step % 5 == 4 ? 5 : 4
                // Alternate basic and cells, with occasional model information.
                let cmd = UInt8(command)
                bytes = [0xdd, 0xa5, cmd, 0, 0xff, UInt8(truncatingIfNeeded: -command), 0x77]
            }
        case .jikong:
            command = version == nil ? 0x97 : 0x96; bytes = Self.jkRequest(UInt8(command))
        case .yanyang:
            let count: Int
            if step == -1 { command = 0; count = 1 }
            else if yyLayout == 0 && yyProbe < 2 { command = 63; count = 4 }
            else if yyLayout == 2 {
                (command, count) = step % 3 == 0 ? (1,47) : step % 3 == 1 ? (48,42) : (90,22)
            } else { (command, count) = step % 2 == 0 ? (1,79) : (80,80) }
            let address = command == 0 ? 0 : yyAddress
            bytes = Self.withCRC([UInt8(address), 3, UInt8(command >> 8), UInt8(command & 255), UInt8(count >> 8), UInt8(count & 255)])
        case .luxing:
            let block = Self.luxingBlocks[step % 4]
            command = block.length
            bytes = Self.withCRC([1, 3, UInt8(block.address >> 8), UInt8(block.address & 255), 0, UInt8(block.count)])
        case .lanbao:
            command = step % 5 == 4 ? 2 : 1
            bytes = Self.withCRC([0xfa,0x50,0x28,0xa0,0x15,0,9] + lanbaoMatch + [UInt8(command),0,UInt8(command == 1 ? 111 : 134)], polynomial: 0xc328, bigEndian: true) + [0xe5]
        }
        guard Self.permits(Data(bytes), family: family) else { halted = true; error = "只读命令校验失败"; return nil }
        pending = command; sentAt = now; nextAt = now + (family == .ant ? 1 : 0.3)
        buffer.removeAll(keepingCapacity: true)
        return Data(bytes)
    }
    /// Verify every outbound frame again at the BLE boundary.
    public static func permits(_ data: Data, family: BMSFamily) -> Bool {
        let b = [UInt8](data)
        switch family {
        case .ant: return data == ANTBMSProtocol.realtimeRequest
        case .jbd:
            if b.count == 7, b[0] == 0xdd, b[1] == 0xa5, (3...5).contains(b[2]) {
                return b == [0xdd,0xa5,b[2],0,0xff,UInt8(truncatingIfNeeded: -Int(b[2])),0x77]
            }
            guard b.count >= 5, b[0...1] == [0xff,0xaa], b.count == Int(b[3]) + 5,
                  b.dropFirst(2).dropLast().reduce(UInt8(0), &+) == b.last else { return false }
            return b[2] == 0x15 && b[3] == 6 && b[4..<10].allSatisfy { (32...126).contains($0) }
                || b[2] == 0x17 && b[3] == 0 || b[2] == 0x18 && b[3] == 6
        case .jikong: return b.count == 20 && [0x96,0x97].contains(b[4]) && b == jkRequest(b[4])
        case .luxing:
            return Self.luxingBlocks.contains { block in
                b == Self.withCRC([1, 3, UInt8(block.address >> 8), UInt8(block.address & 255), 0, UInt8(block.count)])
            }
        case .yanyang:
            guard b.count == 8, b[0] <= 247, b[1] == 3, Self.withCRC(Array(b.prefix(6))) == b else { return false }
            let x = BMSBytes(b), pair = (x.be16(2), x.be16(4))
            if b[0] == 0 { return pair == (0,1) }
            return [(63,4),(1,79),(80,80),(1,47),(48,42),(90,22)].contains { $0 == pair }
        case .lanbao:
            return b.count == 19 && Array(b.prefix(7)) == [0xfa,0x50,0x28,0xa0,0x15,0,9]
                && (b[13] == 1 && b[15] == 111 || b[13] == 2 && b[15] == 134) && b[14] == 0
                && Self.withCRC(Array(b.prefix(16)),polynomial:0xc328,bigEndian:true)+[0xe5] == b
        }
    }
    public func append(_ data: Data, now: TimeInterval) -> [ANTBMSReading] {
        if family == .ant {
            let result = ant.append(data)
            if !result.isEmpty { pending = nil; error = nil }
            return result
        }
        timedOut(now)
        guard family.supportsGATT, !halted else { return [] }
        lastFragment = now
        // Bounded parsing even for coalesced notifications; drain before accepting more.
        var result: [ANTBMSReading] = []
        for byte in data.suffix(8192) {
            if buffer.count >= 4096 { buffer.removeFirst(); error = "接收缓冲已满" }
            buffer.append(byte)
            // A rejected frame can leave noise before the next valid header.
            // Drain all proven-invalid prefixes now, even at the end of a notification.
            while !buffer.isEmpty {
                let previousCount = buffer.count
                result += drain(now: now)
                if buffer.count == previousCount { break }
            }
        }
        return result
    }
    func complete(now: Double) { pending = nil; error = nil; nextAt = now + 0.3 }
    func drain(now: Double) -> [ANTBMSReading] {
        switch family {
        case .jbd: return drainJBD(now)
        case .jikong: return drainJK(now)
        case .yanyang: return drainYY(now)
        case .lanbao: return drainLanbao(now)
        case .luxing: return drainLuXing(now)
        default: return []
        }
    }
}
