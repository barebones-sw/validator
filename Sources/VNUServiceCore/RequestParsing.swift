import Foundation
import VNUCore

public enum QueryParser {
    public static func parse(_ query: String) -> [String: [String]] {
        var parameters: [String: [String]] = [:]
        guard !query.isEmpty else { return parameters }
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = parts.first.map(String.init) ?? ""
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            let name = percentDecode(rawName).lowercased()
            guard !name.isEmpty else { continue }
            parameters[name, default: []].append(percentDecode(rawValue))
        }
        return parameters
    }

    public static func percentDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }
}

public struct MultipartResult: Sendable {
    public var parameters: [String: [String]]
    public var documentData: Data?
    public var documentContentType: String?
    public var documentFieldName: String?
    public var documentFilename: String?

    public init(
        parameters: [String: [String]] = [:],
        documentData: Data? = nil,
        documentContentType: String? = nil,
        documentFieldName: String? = nil,
        documentFilename: String? = nil
    ) {
        self.parameters = parameters
        self.documentData = documentData
        self.documentContentType = documentContentType
        self.documentFieldName = documentFieldName
        self.documentFilename = documentFilename
    }
}

public enum MultipartParser {
    public static func parse(data: Data, contentType: String) -> MultipartResult {
        let parsed = ParsedContentType(contentType)
        guard let boundary = parsed.parameters["boundary"], !boundary.isEmpty else {
            return MultipartResult()
        }
        let delimiter = Data("--\(boundary)".utf8)
        var result = MultipartResult()
        for rawPart in split(data, by: delimiter) {
            let part = normalizedPart(rawPart)
            if part.isEmpty || String(data: part.prefix(2), encoding: .ascii) == "--" { continue }
            guard let headerRange = part.range(of: Data("\r\n\r\n".utf8)) ?? part.range(of: Data("\n\n".utf8)) else { continue }
            let separatorLength = part[headerRange].count
            let headerData = part[..<headerRange.lowerBound]
            let bodyStart = part.index(headerRange.lowerBound, offsetBy: separatorLength)
            let content = Data(part[bodyStart...])
            guard let headerText = String(data: headerData, encoding: .isoLatin1) else { continue }
            let headers = parsePartHeaders(headerText)
            guard let disposition = headers["content-disposition"],
                  let name = dispositionParameter("name", in: disposition) else {
                continue
            }
            let filename = dispositionParameter("filename", in: disposition)
            let partContentType = headers["content-type"] ?? "text/html; charset=utf-8"
            if name == "content" || name == "uploaded_file" || name == "file" {
                result.documentData = content
                result.documentContentType = partContentType
                result.documentFieldName = name
                result.documentFilename = filename?.nonEmpty
            } else {
                let value = String(data: content, encoding: .utf8) ?? String(data: content, encoding: .isoLatin1) ?? ""
                result.parameters.appendParameter(name: name, value: value)
            }
        }
        return result
    }

    private static func split(_ data: Data, by delimiter: Data) -> [Data] {
        var parts: [Data] = []
        var searchStart = data.startIndex
        var partStart: Data.Index?
        while let range = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            if let start = partStart {
                parts.append(Data(data[start..<range.lowerBound]))
            }
            partStart = range.upperBound
            searchStart = range.upperBound
        }
        if let start = partStart, start < data.endIndex {
            parts.append(Data(data[start..<data.endIndex]))
        }
        return parts
    }

    private static func normalizedPart(_ part: Data) -> Data {
        var bytes = Array(part)
        if bytes.starts(with: [13, 10]) {
            bytes.removeFirst(2)
        } else if bytes.first == 10 {
            bytes.removeFirst()
        }
        if bytes.suffix(2) == [13, 10] {
            bytes.removeLast(2)
        } else if bytes.last == 10 {
            bytes.removeLast()
        }
        return Data(bytes)
    }

    private static func parsePartHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            headers[String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return headers
    }

    private static func dispositionParameter(_ name: String, in header: String) -> String? {
        for part in header.components(separatedBy: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key == name {
                return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}
