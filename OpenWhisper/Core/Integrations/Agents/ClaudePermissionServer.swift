import Foundation
import Network

/// The loopback endpoint Claude Code's PermissionRequest hook posts to (see README): the hook's
/// JSON comes in, the hook's answer goes back. An empty body leaves Claude's own prompt in
/// charge. When the hook gives up (the user clicked in Claude, or it timed out), the connection
/// closes and `onAbandoned` tells Jarvis to stop asking.
@MainActor
final class ClaudePermissionServer {
    static let port: UInt16 = 47823

    var onRequest: ((Data, UUID) async -> Data?)?
    var onAbandoned: ((UUID) -> Void)?
    private var listener: NWListener?

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port) else {
            owLog("[ClaudePermission] Could not listen on \(Self.port)")
            return
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { owLog("[ClaudePermission] Listener failed: \(error)") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        owLog("[ClaudePermission] Listening on 127.0.0.1:\(Self.port)")
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint, Self.isLoopback(host) else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): address == .loopback
        case .ipv6(let address): address == .loopback || address.asIPv4 == .loopback
        default: false
        }
    }

    /// Reads the headers and `Content-Length` bytes of body, then answers.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let body = Self.body(of: buffer) {
                    self.answer(body, on: connection)
                } else if isComplete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection, buffer: buffer)
                }
            }
        }
    }

    /// The body once the whole request is in; nil while more is coming.
    nonisolated static func body(of request: Data) -> Data? {
        guard let headerEnd = request.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(decoding: request[..<headerEnd.lowerBound], as: UTF8.self).lowercased()
        let length = headers.split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = request[headerEnd.upperBound...]
        return body.count >= length ? Data(body.prefix(length)) : nil
    }

    private func answer(_ body: Data, on connection: NWConnection) {
        let id = UUID()
        var finished = false
        // The hook sends nothing more; the read ends only when it hangs up.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
            MainActor.assumeIsolated {
                guard !finished else { return }
                finished = true
                owLog("[ClaudePermission] Hook hung up before an answer")
                self?.onAbandoned?(id)
            }
        }
        Task { @MainActor [weak self] in
            let reply = await self?.onRequest?(body, id) ?? nil
            guard !finished else { return }
            finished = true
            let payload = reply ?? Data()
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
