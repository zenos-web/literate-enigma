import Foundation

func pxcAutoStartProbeSmoke() throws {
    for (command, status, expected) in [(UInt32(0x70000011), true, true), (0x70000011, false, false), (0x10001, true, false)] {
        let listener = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
        let port = try listener.localPort
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                let socket = try listener.accept(remoteIP: "127.0.0.1"); defer { socket.close() }
                let request = try TailingProtocol.readControl { try socket.readExactly($0, timeout: 1) }
                guard request.command == 0x70000010 else { return }
                try socket.write(TailingProtocol.control(command, payload: TailingProtocol.json(["status": status])))
            } catch { }
        }
        let result = PxcAutoStartProbe.verify(localIP: "127.0.0.1", targetIP: "127.0.0.1", port: port)
        precondition(result == expected)
        precondition(done.wait(timeout: .now() + 3) == .success)
        listener.close()
    }
    // A TCP server without a valid protocol response must not start CarPlay.
    let listener = try TailingSocket.listening(localIP: "127.0.0.1", port: 0)
    let port = try listener.localPort
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { done.signal() }
        if let socket = try? listener.accept(remoteIP: "127.0.0.1") {
            try? socket.write(Data("HTTP/1.1 200 OK\r\n\r\n".utf8)); socket.close()
        }
    }
    precondition(!PxcAutoStartProbe.verify(localIP: "127.0.0.1", targetIP: "127.0.0.1", port: port))
    precondition(done.wait(timeout: .now() + 3) == .success)
    listener.close()
    print("PASS: automatic start requires a valid PXC acknowledgement; rejection, unrelated command and open HTTP port do not trigger")
}
