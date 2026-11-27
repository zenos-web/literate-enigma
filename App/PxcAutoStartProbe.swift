import Foundation

/// Opt-in foreground discovery. An open port alone is never accepted as a PXC instrument.
enum PxcAutoStartProbe {
    static func verify(localIP: String, targetIP: String, port: UInt16 = 10930) -> Bool {
        do {
            let socket = try TailingSocket.create()
            defer { socket.close() }
            try socket.connect(localIP: localIP, remoteIP: targetIP, port: port, timeout: 0.6)
            let payload = try TailingProtocol.json(["phoneType": "Android", "packageName": Bundle.main.bundleIdentifier ?? "CarWithin"])
            try socket.write(TailingProtocol.control(0x70000010, payload: payload))
            let reply = try TailingProtocol.readControl { count in
                guard count <= 1024 else { throw TailingError.protocolFailure("探测应答过长") }
                return try socket.readExactly(count, timeout: 0.6)
            }
            let status = try TailingProtocol.object(reply.payload)["status"] as? Bool
            return reply.command == 0x70000011 && status == true
        } catch { return false }
    }
}
