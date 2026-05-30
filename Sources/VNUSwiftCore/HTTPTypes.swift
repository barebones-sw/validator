import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var version: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, target: String, version: String = "HTTP/1.1", headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.target = target
        self.version = version
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public var path: String {
        URLComponents(string: target)?.path.nonEmpty ?? "/"
    }

    public var query: String {
        if let question = target.firstIndex(of: "?") {
            return String(target[target.index(after: question)...])
        }
        return ""
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var reasonPhrase: String
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int = 200, reasonPhrase: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase
        self.headers = headers
        self.body = body
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

