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

    private var messages: [ValidationMessage] = []
    private var idElementNames: [String: String] = [:]
    private var pendingInputListReferences: [PendingInputListReference] = []
    private var elementStack: [String] = []
    private var definitionListContexts: [DefinitionListContext] = []
    private var dtCaptures: [DTCapture] = []

    public func validate(data: Data, source: String) -> [ValidationMessage] {
        messages = []
        idElementNames = [:]
        pendingInputListReferences = []
        elementStack = []
        definitionListContexts = []
        dtCaptures = []
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
        elementStack.append(name)
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
        if let index = elementStack.lastIndex(of: name) {
            elementStack.removeSubrange(index...)
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in dtCaptures.indices {
            dtCaptures[index].text += string
        }
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        for reference in pendingInputListReferences where idElementNames[reference.value] != "datalist" {
            messages.append(.error(
                "The \u{201c}list\u{201d} attribute of the \u{201c}input\u{201d} element must refer to a \u{201c}datalist\u{201d} element.",
                location: reference.location
            ))
        }
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
