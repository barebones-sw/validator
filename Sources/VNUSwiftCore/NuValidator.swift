import Foundation

public final class NuValidator: Sendable {
    private let htmlValidator = HTMLValidator()
    private let xmlValidator = XMLValidator()
    private let cssValidator = CSSValidator()

    public init() {}

    public func check(input: DocumentInput, options: CheckerOptions) -> ValidationResult {
        let contentType = ParsedContentType(input.contentType)
        let source = DocumentDecoder.decode(input)
        let sourceInfo = options.showSource ? ValidationSource(
            code: source,
            type: contentType.mediaType,
            encoding: contentType.charset
        ) : nil

        var messages: [ValidationMessage]
        if contentType.isCSS {
            messages = cssValidator.validate(source: source)
        } else if options.parser == "xml" || options.parser == "xmldtd" || contentType.isXML {
            messages = xmlValidator.validate(data: input.data, source: source)
        } else {
            messages = htmlValidator.validate(source: source)
        }

        messages = filter(messages: messages, level: options.reportLevel)
        return ValidationResult(url: input.url, messages: messages, source: sourceInfo)
    }

    private func filter(messages: [ValidationMessage], level: ReportLevel) -> [ValidationMessage] {
        switch level {
        case .all:
            return messages
        case .warning:
            return messages.filter { $0.type != "info" || $0.subType == "warning" }
        case .error:
            return messages.filter { $0.type != "info" }
        }
    }
}

