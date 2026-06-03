import Darwin
import Foundation

public enum HTTPServerError: Error, CustomStringConvertible {
    case socketFailed(String)
    case bindFailed(String)
    case listenFailed(String)

    public var description: String {
        switch self {
        case let .socketFailed(message), let .bindFailed(message), let .listenFailed(message):
            return message
        }
    }
}

public struct HTTPRequestLog: Sendable, CustomStringConvertible {
    public var method: String
    public var target: String
    public var statusCode: Int
    public var bodyBytes: Int
    public var elapsedMilliseconds: Double

    public init(method: String, target: String, statusCode: Int, bodyBytes: Int, elapsedMilliseconds: Double) {
        self.method = method
        self.target = target
        self.statusCode = statusCode
        self.bodyBytes = bodyBytes
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    public var description: String {
        String(format: "%@ %@ -> %d, %d bytes, %.1f ms", method, target, statusCode, bodyBytes, elapsedMilliseconds)
    }
}

public final class HTTPServer {
    private let host: String
    private let port: UInt16
    private let service: NuHTTPService
    private let requestLogger: (@Sendable (HTTPRequestLog) -> Void)?

    public init(
        host: String = "127.0.0.1",
        port: UInt16 = 8888,
        service: NuHTTPService = NuHTTPService(),
        requestLogger: (@Sendable (HTTPRequestLog) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.service = service
        self.requestLogger = requestLogger
    }

    public func start() throws -> Never {
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw HTTPServerError.socketFailed(String(cString: strerror(errno)))
        }
        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        if host == "0.0.0.0" {
            address.sin_addr.s_addr = INADDR_ANY.bigEndian
        } else {
            inet_pton(AF_INET, host, &address.sin_addr)
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(serverFD)
            throw HTTPServerError.bindFailed(message)
        }

        guard listen(serverFD, SOMAXCONN) == 0 else {
            let message = String(cString: strerror(errno))
            close(serverFD)
            throw HTTPServerError.listenFailed(message)
        }

        print("Checker service started at http://\(host):\(port)/")
        while true {
            var clientAddress = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(serverFD, &clientAddress, &length)
            if clientFD >= 0 {
                handleClient(clientFD)
                close(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        let start = DispatchTime.now()
        guard let request = readRequest(from: fd) else { return }
        let response = service.response(for: request)
        write(response: response, to: fd)
        if let requestLogger {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            requestLogger(HTTPRequestLog(
                method: request.method,
                target: request.target,
                statusCode: response.statusCode,
                bodyBytes: response.body.count,
                elapsedMilliseconds: Double(elapsed) / 1_000_000.0
            ))
        }
    }

    private func readRequest(from fd: Int32) -> HTTPRequest? {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        let delimiter = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while headerEnd == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            data.append(buffer, count: count)
            headerEnd = data.range(of: delimiter)
            if data.count > 1_048_576 { return nil }
        }
        guard let headerRange = headerEnd else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while data.count - bodyStart < contentLength {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        let bodyEnd = min(data.count, bodyStart + contentLength)
        let body = data[bodyStart..<bodyEnd]
        return HTTPRequest(
            method: requestParts[0],
            target: requestParts[1],
            version: requestParts.count > 2 ? requestParts[2] : "HTTP/1.1",
            headers: headers,
            body: Data(body)
        )
    }

    private func write(response: HTTPResponse, to fd: Int32) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        var head = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\r\n"
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var output = Data(head.utf8)
        output.append(response.body)
        output.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < output.count {
                let count = Darwin.send(fd, base.advanced(by: sent), output.count - sent, 0)
                if count <= 0 { break }
                sent += count
            }
        }
    }
}
