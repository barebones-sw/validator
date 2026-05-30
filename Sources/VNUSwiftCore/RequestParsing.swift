import Foundation

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

    public init(parameters: [String: [String]] = [:], documentData: Data? = nil, documentContentType: String? = nil) {
        self.parameters = parameters
        self.documentData = documentData
        self.documentContentType = documentContentType
    }
}

public enum MultipartParser {
    public static func parse(data: Data, contentType: String) -> MultipartResult {
        let parsed = ParsedContentType(contentType)
        guard let boundary = parsed.parameters["boundary"], !boundary.isEmpty else {
            return MultipartResult()
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return MultipartResult()
        }
        let delimiter = "--" + boundary
        var result = MultipartResult()
        for rawPart in text.components(separatedBy: delimiter) {
            let trimmed = rawPart.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if trimmed.isEmpty || trimmed == "--" { continue }
            let sections = trimmed.components(separatedBy: "\r\n\r\n")
            guard sections.count >= 2 else { continue }
            let headerText = sections[0]
            var content = sections.dropFirst().joined(separator: "\r\n\r\n")
            if content.hasSuffix("\r\n") {
                content.removeLast(2)
            }
            let headers = parsePartHeaders(headerText)
            guard let disposition = headers["content-disposition"],
                  let name = dispositionParameter("name", in: disposition) else {
                continue
            }
            let partContentType = headers["content-type"] ?? "text/html; charset=utf-8"
            if name == "content" || name == "uploaded_file" {
                result.documentData = Data(content.utf8)
                result.documentContentType = partContentType
            } else {
                result.parameters.appendParameter(name: name, value: content)
            }
        }
        return result
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

