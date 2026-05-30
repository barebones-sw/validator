import Foundation

public final class XMLValidator: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var messages: [ValidationMessage] = []

    public func validate(data: Data, source: String) -> [ValidationMessage] {
        messages = []
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
