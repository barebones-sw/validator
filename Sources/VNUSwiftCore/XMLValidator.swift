import Foundation

public final class XMLValidator: NSObject, XMLParserDelegate, @unchecked Sendable {
    private struct PendingInputListReference {
        var value: String
        var location: SourceLocation
    }

    private struct DefinitionListContext {
        var termNames: Set<String> = []
    }

    private struct DTCapture {
        var dlIndex: Int
        var text = ""
        var location: SourceLocation
    }

    private struct FigureContext {
        var depth: Int
        var sawFigcaption = false
    }

    private struct RubyContext {
        var location: SourceLocation
        var directChildNames: [String] = []
        var sawBaseContent = false
    }

    private var messages: [ValidationMessage] = []
    private var idElementNames: [String: String] = [:]
    private var pendingInputListReferences: [PendingInputListReference] = []
    private var elementStack: [String] = []
    private var anchorHrefStack: [Bool] = []
    private var definitionListContexts: [DefinitionListContext] = []
    private var dtCaptures: [DTCapture] = []
    private var figureContexts: [FigureContext] = []
    private var rubyContexts: [RubyContext] = []
    private var tableChecker = HTMLTableModelChecker(mode: .xhtml)

    public func validate(data: Data, source: String) -> [ValidationMessage] {
        messages = []
        idElementNames = [:]
        pendingInputListReferences = []
        elementStack = []
        anchorHrefStack = []
        definitionListContexts = []
        dtCaptures = []
        figureContexts = []
        rubyContexts = []
        tableChecker = HTMLTableModelChecker(mode: .xhtml)
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), messages.isEmpty {
            messages.append(.error("XML parser failed before reporting a specific well-formedness error."))
        }
        return messages
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        messages.append(.error(parseError.localizedDescription, location: location))
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        guard isXHTMLElement(namespaceURI) else {
            return
        }

        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        if let id = attributeDict["id"], idElementNames[id] == nil {
            idElementNames[id] = name
        }
        let normalizedAttributes = normalizedAttributes(attributeDict)
        tableChecker.startElement(HTMLTableElementInfo(
            name: name,
            attributes: normalizedAttributes,
            location: location,
            extract: nil
        ))
        if elementStack.last == "ruby", let index = rubyContexts.indices.last {
            rubyContexts[index].directChildNames.append(name)
            if !Self.xhtmlRubyAnnotationElements.contains(name) {
                rubyContexts[index].sawBaseContent = true
            }
        }
        appendXHTMLContentModelMessages(element: name, attributes: normalizedAttributes, location: location)
        appendGlobalAttributeMessages(element: name, attributes: attributeDict, location: location)
        if name == "base",
           attributeDict["href"] == nil,
           attributeDict["target"] == nil {
            messages.append(.error(
                "Element \u{201c}base\u{201d} is missing one or more of the following attributes: \u{201c}href\u{201d}, \u{201c}target\u{201d}.",
                location: location
            ))
        }
        if name == "script", attributeDict["language"] != nil {
            messages.append(.warning(
                "The \u{201c}language\u{201d} attribute on the \u{201c}script\u{201d} element is obsolete. Use the \u{201c}type\u{201d} attribute instead.",
                location: location
            ))
        }
        if name == "keygen" {
            messages.append(.error(
                "The \u{201c}keygen\u{201d} element is obsolete.",
                location: location
            ))
        }
        if name == "embed" {
            appendEmbedMessages(attributes: attributeDict, location: location)
        }
        if name == "img" {
            appendImageMessages(attributes: attributeDict, location: location)
        }
        if name == "meter" {
            appendMeterMessages(attributes: attributeDict, location: location)
        }
        if name == "progress" {
            appendProgressMessages(attributes: attributeDict, location: location)
        }
        if name == "link",
           attributeDict["href"] == nil,
           attributeDict["imagesrcset"] == nil {
            messages.append(.error(
                "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both.",
                location: location
            ))
        }
        if name == "input", let list = attributeDict["list"] {
            pendingInputListReferences.append(PendingInputListReference(value: list, location: location))
        }
        if name == "dl" {
            definitionListContexts.append(DefinitionListContext())
        } else if name == "dt", let dlIndex = definitionListContexts.indices.last {
            dtCaptures.append(DTCapture(dlIndex: dlIndex, location: location))
        }
        if name == "figure" {
            figureContexts.append(FigureContext(depth: elementStack.count))
        }
        if name == "ruby" {
            rubyContexts.append(RubyContext(location: location))
        }
        elementStack.append(name)
        anchorHrefStack.append(name == "a" && attributeDict["href"] != nil)
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        guard isXHTMLElement(namespaceURI) else {
            return
        }

        if name == "dt", let capture = dtCaptures.popLast() {
            finishDTCapture(capture)
        }
        if name == "dl", !definitionListContexts.isEmpty {
            _ = definitionListContexts.popLast()
        }
        if name == "figure", !figureContexts.isEmpty {
            _ = figureContexts.popLast()
        }
        if name == "ruby", let context = rubyContexts.popLast() {
            appendXHTMLRubyMessages(context)
        }
        tableChecker.endElement(name)
        if let index = elementStack.lastIndex(of: name) {
            elementStack.removeSubrange(index...)
            anchorHrefStack.removeSubrange(index...)
        }
    }

    private func appendXHTMLContentModelMessages(element name: String, attributes: [String: String], location: SourceLocation) {
        if attributes["contextmenu"] != nil {
            messages.append(.warning(
                "The \u{201c}contextmenu\u{201d} attribute is obsolete. Use script to handle \u{201c}contextmenu\u{201d} event instead.",
                location: location
            ))
        }
        if name == "menu", attributes["type"] != nil {
            messages.append(.warning(
                "The \u{201c}type\u{201d} attribute on the \u{201c}menu\u{201d} element is obsolete. Use script to handle \u{201c}contextmenu\u{201d} event instead.",
                location: location
            ))
        }
        if name == "a", attributes["name"] != nil {
            messages.append(.warning(
                "The \u{201c}name\u{201d} attribute on the \u{201c}a\u{201d} element is obsolete. Consider putting an \u{201c}id\u{201d} attribute on the nearest container instead.",
                location: location
            ))
        }
        if name == "footer" || name == "header",
           let ancestor = elementStack.last(where: { $0 == "footer" || $0 == "header" }) {
            messages.append(.error(
                "The element \u{201c}\(name)\u{201d} must not appear as a descendant of the \u{201c}\(ancestor)\u{201d} element.",
                location: location
            ))
        }

        if elementStack.last == "menu", !Self.xhtmlMenuChildElements.contains(name) {
            messages.append(.error(
                "Element \u{201c}\(name)\u{201d} not allowed as child of \u{201c}menu\u{201d} in this context.",
                location: location
            ))
        }

        if elementStack.last == "figure",
           let index = figureContexts.indices.last {
            if name == "figcaption" {
                figureContexts[index].sawFigcaption = true
            } else if figureContexts[index].sawFigcaption {
                messages.append(.error(
                    "Element \u{201c}\(name)\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context.",
                    location: location
                ))
            }
        }
    }

    private func appendGlobalAttributeMessages(element: String, attributes: [String: String], location: SourceLocation) {
        if let accesskey = attributes["accesskey"], !isValidAccesskeyValue(accesskey) {
            appendBadAttributeValue(accesskey, attribute: "accesskey", element: element, location: location)
        }
        if let spellcheck = attributes["spellcheck"], !isValidSpellcheckValue(spellcheck) {
            appendBadAttributeValue(spellcheck, attribute: "spellcheck", element: element, location: location)
        }
        if attributes.keys.contains(where: isInvalidXMLDataAttributeName) {
            messages.append(.error(
                "\u{201c}data-*\u{201d} attributes must not have characters from the range \u{201c}A\u{201d}\u{2026}\u{201c}Z\u{201d} in the name.",
                location: location
            ))
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in dtCaptures.indices {
            dtCaptures[index].text += string
        }
        guard string.contains(where: { !$0.isWhitespace }) else { return }
        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        if elementStack.last == "menu" {
            messages.append(.error("Text not allowed in \u{201c}menu\u{201d} in this context.", location: location))
        }
        if elementStack.contains("iframe") {
            messages.append(.error("Text not allowed in \u{201c}iframe\u{201d} in this context.", location: location))
        }
        if elementStack.last == "figure",
           let index = figureContexts.indices.last,
           figureContexts[index].sawFigcaption {
            messages.append(.error("Text not allowed in \u{201c}figure\u{201d} in this context.", location: location))
        }
        if elementStack.last == "ruby", let index = rubyContexts.indices.last {
            rubyContexts[index].sawBaseContent = true
        }
    }

    private func appendXHTMLRubyMessages(_ context: RubyContext) {
        if !context.sawBaseContent && context.directChildNames.isEmpty {
            messages.append(.error(
                "Element \u{201c}ruby\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}rp\u{201d}, \u{201c}rt\u{201d}, \u{201c}rtc\u{201d}.",
                location: context.location
            ))
        } else if !context.sawBaseContent && context.directChildNames.contains("rt") {
            messages.append(.error(
                "Element \u{201c}ruby\u{201d} is missing a required instance of child element \u{201c}rt\u{201d}.",
                location: context.location
            ))
        }
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        for diagnostic in tableChecker.finish() {
            if diagnostic.warning {
                messages.append(.warning(diagnostic.message, location: diagnostic.location, extract: diagnostic.extract))
            } else {
                messages.append(.error(diagnostic.message, location: diagnostic.location, extract: diagnostic.extract))
            }
        }
        for reference in pendingInputListReferences where idElementNames[reference.value] != "datalist" {
            messages.append(.error(
                "The \u{201c}list\u{201d} attribute of the \u{201c}input\u{201d} element must refer to a \u{201c}datalist\u{201d} element.",
                location: reference.location
            ))
        }
    }

    private func appendEmbedMessages(attributes: [String: String], location: SourceLocation) {
        for attribute in ["height", "width"] {
            if let value = attributes[attribute], !isValidNonNegativeInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, element: "embed", location: location)
            }
        }
        if let type = attributes["type"], !isValidMIMEType(type) {
            appendBadAttributeValue(type, attribute: "type", element: "embed", location: location)
        }
    }

    private func appendImageMessages(attributes: [String: String], location: SourceLocation) {
        for attribute in ["height", "width"] {
            if let value = attributes[attribute], !isValidNonNegativeInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, element: "img", location: location)
            }
        }
        if attributes["ismap"] != nil, !anchorHrefStack.contains(true) {
            messages.append(.error(
                "The \u{201c}img\u{201d} element with the \u{201c}ismap\u{201d} attribute set must have an \u{201c}a\u{201d} ancestor with the \u{201c}href\u{201d} attribute.",
                location: location
            ))
        }
        if attributes["usemap"] != nil, elementStack.contains("a") {
            messages.append(.error(
                "The element \u{201c}img\u{201d} with the attribute \u{201c}usemap\u{201d} must not appear as a descendant of the \u{201c}a\u{201d} element.",
                location: location
            ))
        }
    }

    private func appendMeterMessages(attributes: [String: String], location: SourceLocation) {
        guard let value = attributes["value"] else {
            messages.append(.error("Element \u{201c}meter\u{201d} is missing required attribute \u{201c}value\u{201d}.", location: location))
            return
        }
        guard let meterValue = validFloatingPointAttribute("value", value, element: "meter", location: location) else {
            return
        }
        let minValue = numberAttribute("min", attributes: attributes, defaultValue: 0, element: "meter", location: location)
        let maxValue = numberAttribute("max", attributes: attributes, defaultValue: 1, element: "meter", location: location)
        guard let minValue, let maxValue else { return }
        let lowValue = numberAttribute("low", attributes: attributes, defaultValue: minValue, element: "meter", location: location)
        let highValue = numberAttribute("high", attributes: attributes, defaultValue: maxValue, element: "meter", location: location)
        let optimumValue = optionalNumberAttribute("optimum", attributes: attributes, element: "meter", location: location)

        if attributes["min"] == nil, meterValue < 0 {
            messages.append(.error("The value of the \u{201c}value\u{201d} attribute must be greater than or equal to zero when the \u{201c}min\u{201d} attribute is absent.", location: location))
        }
        if attributes["max"] == nil, meterValue > 1 {
            messages.append(.error("The value of the \u{201c}value\u{201d} attribute must be less than or equal to one when the \u{201c}max\u{201d} attribute is absent.", location: location))
        }
        if minValue > meterValue {
            messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}value\u{201d} attribute.", location: location))
        }
        if meterValue > maxValue {
            messages.append(.error("The value of the \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
        }
        if let lowValue {
            if minValue > lowValue {
                messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}low\u{201d} attribute.", location: location))
            }
            if let highValue, lowValue > highValue {
                messages.append(.error("The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute.", location: location))
            }
            if lowValue > maxValue {
                messages.append(.error("The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
            }
        }
        if let highValue {
            if minValue > highValue {
                messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute.", location: location))
            }
            if highValue > maxValue {
                messages.append(.error("The value of the \u{201c}high\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
            }
        }
        if let optimumValue {
            if minValue > optimumValue {
                messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}optimum\u{201d} attribute.", location: location))
            }
            if optimumValue > maxValue {
                messages.append(.error("The value of the \u{201c}optimum\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
            }
        }
    }

    private func appendProgressMessages(attributes: [String: String], location: SourceLocation) {
        let maxValue = numberAttribute("max", attributes: attributes, defaultValue: 1, element: "progress", location: location)
        if let max = maxValue, max <= 0 {
            appendBadAttributeValue(attributes["max"] ?? "", attribute: "max", element: "progress", location: location)
        }
        guard let value = attributes["value"],
              let progressValue = validFloatingPointAttribute("value", value, element: "progress", location: location) else {
            return
        }
        if progressValue < 0 {
            appendBadAttributeValue(value, attribute: "value", element: "progress", location: location)
        }
        if attributes["max"] == nil, progressValue > 1 {
            messages.append(.error("The value of the  \u{201c}value\u{201d} attribute must be less than or equal to one when the \u{201c}max\u{201d} attribute is absent.", location: location))
        } else if let max = maxValue, progressValue > max {
            messages.append(.error("The value of the  \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
        }
    }

    private func validFloatingPointAttribute(_ attribute: String, _ value: String, element: String, location: SourceLocation) -> Double? {
        guard isValidFloatingPointNumber(value), let parsed = Double(value) else {
            appendBadAttributeValue(value, attribute: attribute, element: element, location: location)
            return nil
        }
        return parsed
    }

    private func optionalNumberAttribute(_ attribute: String, attributes: [String: String], element: String, location: SourceLocation) -> Double? {
        guard let value = attributes[attribute] else { return nil }
        return validFloatingPointAttribute(attribute, value, element: element, location: location)
    }

    private func numberAttribute(_ attribute: String, attributes: [String: String], defaultValue: Double, element: String, location: SourceLocation) -> Double? {
        guard let value = attributes[attribute] else { return defaultValue }
        return validFloatingPointAttribute(attribute, value, element: element, location: location)
    }

    private func isValidFloatingPointNumber(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: isASCIIWhitespace),
              let parsed = Double(value),
              parsed.isFinite else {
            return false
        }
        return true
    }

    private func isValidNonNegativeInteger(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy(isASCIIDigit) else { return false }
        return Int(value) != nil
    }

    private func isValidMIMEType(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return false
        }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case " ", "\t", "\n", "\r", "(", ")", "<", ">", "@", ",", ";", ":", "\\", "\"", "[", "]", "?":
                return false
            default:
                return scalar.value > 0x20 && scalar.value < 0x7f
            }
        }
    }

    private func isValidAccesskeyValue(_ value: String) -> Bool {
        var seen: Set<String> = []
        for token in value.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            guard token.count == 1, !seen.contains(token) else {
                return false
            }
            seen.insert(token)
        }
        return true
    }

    private func isValidSpellcheckValue(_ value: String) -> Bool {
        value.isEmpty || value.lowercased() == "true" || value.lowercased() == "false"
    }

    private func isInvalidXMLDataAttributeName(_ name: String) -> Bool {
        guard name.hasPrefix("data-"), name.count > "data-".count else { return false }
        return name.unicodeScalars.contains { scalar in
            scalar.value >= 65 && scalar.value <= 90
        }
    }

    private func appendBadAttributeValue(_ value: String, attribute: String, element: String, location: SourceLocation) {
        messages.append(.error(
            "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute)\u{201d} on element \u{201c}\(element)\u{201d}.",
            location: location
        ))
    }

    private func normalizedAttributes(_ attributes: [String: String]) -> [String: String] {
        Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
    }

    private func finishDTCapture(_ capture: DTCapture) {
        let name = normalizedText(capture.text)
        guard !name.isEmpty,
              definitionListContexts.indices.contains(capture.dlIndex) else {
            return
        }
        if definitionListContexts[capture.dlIndex].termNames.contains(name) {
            messages.append(.warning(
                "Duplicate \u{201c}dt\u{201d} name \u{201c}\(name)\u{201d} in \u{201c}dl\u{201d} element. Within a single \u{201c}dl\u{201d} element, there should not be more than one \u{201c}dt\u{201d} element for each name.",
                location: capture.location
            ))
        }
        definitionListContexts[capture.dlIndex].termNames.insert(name)
    }

    private func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func isXHTMLElement(_ namespaceURI: String?) -> Bool {
        namespaceURI == "http://www.w3.org/1999/xhtml" || namespaceURI == nil
    }

    private func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static let xhtmlMenuChildElements: Set<String> = [
        "li", "script", "template"
    ]

    private static let xhtmlRubyAnnotationElements: Set<String> = [
        "rp", "rt", "rtc"
    ]
}

public final class CSSValidator: Sendable {
    public init() {}

    public func validate(source: String) -> [ValidationMessage] {
        let locations = SourceLocationMap(source)
        var messages: [ValidationMessage] = []
        var stack: [(Character, Int)] = []
        for (offset, character) in source.utf16OffsetsAndCharacters() {
            switch character {
            case "{", "(", "[":
                stack.append((character, offset))
            case "}":
                close("{", actual: "}", offset: offset, locations: locations, stack: &stack, messages: &messages)
            case ")":
                close("(", actual: ")", offset: offset, locations: locations, stack: &stack, messages: &messages)
            case "]":
                close("[", actual: "]", offset: offset, locations: locations, stack: &stack, messages: &messages)
            default:
                break
            }
        }
        for (character, offset) in stack {
            messages.append(.error("CSS: Unclosed \u{201c}\(character)\u{201d}.", location: locations.location(offset: offset), extract: locations.extract(offset: offset)))
        }
        return messages
    }

    private func close(
        _ expected: Character,
        actual: Character,
        offset: Int,
        locations: SourceLocationMap,
        stack: inout [(Character, Int)],
        messages: inout [ValidationMessage]
    ) {
        guard let last = stack.popLast() else {
            messages.append(.error("CSS: Stray \u{201c}\(actual)\u{201d}.", location: locations.location(offset: offset), extract: locations.extract(offset: offset)))
            return
        }
        if last.0 != expected {
            messages.append(.error("CSS: Expected matching \u{201c}\(last.0)\u{201d} before \u{201c}\(actual)\u{201d}.", location: locations.location(offset: offset), extract: locations.extract(offset: offset)))
        }
    }
}

private extension String {
    func utf16OffsetsAndCharacters() -> [(Int, Character)] {
        var result: [(Int, Character)] = []
        var index = startIndex
        while index < endIndex {
            let utf16 = index.samePosition(in: self.utf16).map { self.utf16.distance(from: self.utf16.startIndex, to: $0) } ?? self.utf16.count
            result.append((utf16, self[index]))
            formIndex(after: &index)
        }
        return result
    }
}
