import Darwin
import Foundation

/// Owns the two inherited descriptors used by Electron's private DevTools pipe.
final class PrivateDevTools: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "com.cxartlab.antigravity-zh.devtools")
    private var nextID = 1
    private var received = Data()
    private static let maximumFrameSize = 2 * 1024 * 1024

    var isRunning: Bool { process.isRunning }

    init(executable: URL, arguments: [String] = []) throws {
        // Process supplies stdin/stdout. Move them to Chromium's reserved descriptors
        // before exec, so ordinary application logging cannot enter the protocol.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "exec 3<&0 4>&1; exec </dev/null >/dev/null; exec \"$@\"",
            "antigravity-devtools", executable.path, "--remote-debugging-pipe"
        ] + arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try Self.prepare(input.fileHandleForWriting, protectFromBrokenPipe: true)
        try Self.prepare(output.fileHandleForReading, protectFromBrokenPipe: false)
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    func request(_ method: String, params: [String: Any] = [:], sessionID: String? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.exchange(method, params: params, sessionID: sessionID))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func exchange(_ method: String, params: [String: Any], sessionID: String?) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var request: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionID { request["sessionId"] = sessionID }
        var packet = try JSONSerialization.data(withJSONObject: request)
        packet.append(0)

        let until = DispatchTime.now() + .seconds(4)
        try packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let fd = input.fileHandleForWriting.fileDescriptor
            var sent = 0
            while sent < bytes.count {
                try Self.wait(for: Int16(POLLOUT), on: fd, until: until)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count > 0 { sent += count }
                else if count == 0 || !Self.retryable { throw PipeError.disconnected }
            }
        }

        while true {
            while let end = received.firstIndex(of: 0) {
                let frame = received.prefix(upTo: end)
                received.removeSubrange(...end)
                guard let response = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                      response["id"] as? Int == id else { continue }
                if response["error"] != nil { throw PipeError.rejected(method) }
                guard let result = response["result"] as? [String: Any] else { throw PipeError.invalidMessage }
                return result
            }

            guard received.count < Self.maximumFrameSize else { throw PipeError.invalidMessage }
            let fd = output.fileHandleForReading.fileDescriptor
            try Self.wait(for: Int16(POLLIN), on: fd, until: until)
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 { received.append(contentsOf: chunk.prefix(count)) }
            else if count == 0 || !Self.retryable { throw PipeError.disconnected }
        }
    }

    private static func prepare(_ handle: FileHandle, protectFromBrokenPipe: Bool) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw PipeError.disconnected }
        if protectFromBrokenPipe && fcntl(fd, F_SETNOSIGPIPE, 1) < 0 { throw PipeError.disconnected }
    }

    private static var retryable: Bool { errno == EINTR || errno == EAGAIN }

    private static func wait(for events: Int16, on fd: Int32, until: DispatchTime) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < until.uptimeNanoseconds else { throw PipeError.timedOut }
            let milliseconds = Int32((until.uptimeNanoseconds - now + 999_999) / 1_000_000)
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, milliseconds)
            if result > 0 {
                if descriptor.revents & events != 0 { return }
                throw PipeError.disconnected
            }
            if result == 0 { throw PipeError.timedOut }
            if errno != EINTR { throw PipeError.disconnected }
        }
    }

    enum PipeError: LocalizedError {
        case disconnected
        case timedOut
        case invalidMessage
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .disconnected: return "Antigravity 的私有连接已关闭。"
            case .timedOut: return "等待 Antigravity 响应超时。"
            case .invalidMessage: return "Antigravity 的私有连接返回了无效响应。"
            case .rejected(let method): return "Antigravity 未接受 \(method) 请求。"
            }
        }
    }
}
