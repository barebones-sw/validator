import Foundation

public struct ParsedContentType: Equatable, Sendable {
    public var mediaType: String
    public var parameters: [String: String]

    public init(_ header: String?) {
        let parts = (header ?? "text/html; charset=utf-8")
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.mediaType = parts.first?.lowercased() ?? "text/html"
        var parsed: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 {
                parsed[String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                    String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        self.parameters = parsed
    }

    public var charset: String {
        parameters["charset"] ?? "utf-8"
    }

    public var isXML: Bool {
        mediaType == "application/xml" || mediaType == "text/xml" || mediaType.hasSuffix("+xml")
    }

    public var isCSS: Bool {
        mediaType == "text/css"
    }
}

public enum DocumentDecoder {
    public static func decode(_ input: DocumentInput) -> String {
        let contentType = ParsedContentType(input.contentType)
        let charset = contentType.charset.lowercased().replacingOccurrences(of: "_", with: "-")
        switch charset {
        case "utf-16", "utf-16le", "utf-16be":
            return String(data: input.data, encoding: .utf16) ?? String(decoding: input.data, as: UTF8.self)
        case "iso-8859-1", "latin1":
            return String(data: input.data, encoding: .isoLatin1) ?? String(decoding: input.data, as: UTF8.self)
        case "windows-1252":
            return String(data: input.data, encoding: .windowsCP1252) ?? String(decoding: input.data, as: UTF8.self)
        default:
            return String(data: input.data, encoding: .utf8) ?? String(decoding: input.data, as: UTF8.self)
        }
    }
}

