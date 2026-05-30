import Foundation

public struct ValidationMessage: Codable, Equatable, Sendable {
    public var type: String
    public var subType: String?
    public var lastLine: Int?
    public var lastColumn: Int?
    public var firstLine: Int?
    public var firstColumn: Int?
    public var url: String?
    public var message: String
    public var extract: String?
    public var hiliteStart: Int?
    public var hiliteLength: Int?

    public init(
        type: String,
        subType: String? = nil,
        message: String,
        location: SourceLocation? = nil,
        extract: SourceExtract? = nil,
        url: String? = nil
    ) {
        self.type = type
        self.subType = subType
        self.message = message
        self.url = url
        if let location {
            self.firstLine = location.firstLine == location.lastLine ? nil : location.firstLine
            self.firstColumn = location.firstColumn == location.lastColumn ? nil : location.firstColumn
            self.lastLine = location.lastLine
            self.lastColumn = location.lastColumn
        }
        if let extract {
            self.extract = extract.text
            self.hiliteStart = extract.hiliteStart
            self.hiliteLength = extract.hiliteLength
        }
    }

    public static func error(_ message: String, location: SourceLocation? = nil, extract: SourceExtract? = nil) -> ValidationMessage {
        ValidationMessage(type: "error", message: message, location: location, extract: extract)
    }

    public static func warning(_ message: String, location: SourceLocation? = nil, extract: SourceExtract? = nil) -> ValidationMessage {
        ValidationMessage(type: "info", subType: "warning", message: message, location: location, extract: extract)
    }

    public static func info(_ message: String, location: SourceLocation? = nil, extract: SourceExtract? = nil) -> ValidationMessage {
        ValidationMessage(type: "info", message: message, location: location, extract: extract)
    }

    public static func nonDocumentError(_ message: String, subType: String? = nil) -> ValidationMessage {
        ValidationMessage(type: "non-document-error", subType: subType, message: message)
    }
}

public struct ValidationSource: Codable, Equatable, Sendable {
    public var code: String
    public var type: String?
    public var encoding: String?
}

public struct ValidationResult: Codable, Equatable, Sendable {
    public var url: String?
    public var version: String?
    public var messages: [ValidationMessage]
    public var source: ValidationSource?
    public var language: String?

    public init(url: String? = nil, version: String? = "Swift Nu Validator", messages: [ValidationMessage], source: ValidationSource? = nil, language: String? = nil) {
        self.url = url
        self.version = version
        self.messages = messages
        self.source = source
        self.language = language
    }
}

