import Foundation

public enum OutputFormat: String, Sendable {
    case html
    case xhtml
    case xml
    case json
    case gnu
    case text
}

public enum ReportLevel: Sendable {
    case all
    case warning
    case error
}

public struct CheckerOptions: Sendable {
    public var outputFormat: OutputFormat
    public var showSource: Bool
    public var reportLevel: ReportLevel
    public var callback: String?
    public var asciiQuotes: Bool
    public var parser: String?

    public init(parameters: [String: [String]]) {
        let out = parameters.firstValue("out")?.lowercased() ?? ""
        self.outputFormat = OutputFormat(rawValue: out).map { $0 == .html ? .html : $0 } ?? .html
        self.showSource = parameters.firstValue("showsource")?.lowercased() == "yes"
        switch parameters.firstValue("level")?.lowercased() {
        case "warning":
            self.reportLevel = .warning
        case "error":
            self.reportLevel = .error
        default:
            self.reportLevel = .all
        }
        self.callback = parameters.firstValue("callback")
        self.asciiQuotes = parameters.firstValue("asciiquotes")?.lowercased() == "yes"
        self.parser = parameters.firstValue("parser")?.lowercased()
    }
}

extension Dictionary where Key == String, Value == [String] {
    func firstValue(_ key: String) -> String? {
        self[key]?.first ?? self[key.lowercased()]?.first
    }

    mutating func appendParameter(name: String, value: String) {
        self[name.lowercased(), default: []].append(value)
    }
}

public struct DocumentInput: Sendable {
    public var data: Data
    public var contentType: String
    public var url: String?

    public init(data: Data, contentType: String, url: String? = nil) {
        self.data = data
        self.contentType = contentType
        self.url = url
    }
}

