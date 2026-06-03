import Foundation
import VNUCore

struct HTMLSourceRange: Equatable, Sendable {
    var offset: Int
    var length: Int
}

struct HTMLStartElement: Equatable, Sendable {
    var name: String
    var attributes: [HTMLAttribute]
    var selfClosing: Bool
    var range: HTMLSourceRange

    func attributeValue(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    func hasAttribute(_ name: String) -> Bool {
        attributes.contains { $0.name == name }
    }
}

enum HTMLDocumentEvent: Equatable, Sendable {
    case startDocument
    case endDocument
    case doctype(range: HTMLSourceRange)
    case startElement(HTMLStartElement)
    case endElement(name: String, range: HTMLSourceRange, implicit: Bool)
    case characters(String, range: HTMLSourceRange)
    case comment(String, range: HTMLSourceRange)
}

struct HTMLParsedDocument: Equatable, Sendable {
    var tokens: [HTMLToken]
    var events: [HTMLDocumentEvent]
}

struct HTMLDocumentParser {
    private let source: String
    private let locations: SourceLocationMap

    init(source: String, locations: SourceLocationMap) {
        self.source = source
        self.locations = locations
    }

    func parse() -> HTMLParsedDocument {
        let tokens = HTMLTokenizer(source: source, locations: locations).tokenize()
        let events = HTMLTreeEventBuilder(tokens: tokens).build()
        return HTMLParsedDocument(tokens: tokens, events: events)
    }
}

private struct HTMLTreeEventBuilder {
    private struct OpenElement {
        var name: String
        var range: HTMLSourceRange
    }

    private let tokens: [HTMLToken]

    init(tokens: [HTMLToken]) {
        self.tokens = tokens
    }

    func build() -> [HTMLDocumentEvent] {
        var events: [HTMLDocumentEvent] = [.startDocument]
        var stack: [OpenElement] = []

        for token in tokens {
            switch token {
            case let .doctype(offset, length):
                events.append(.doctype(range: HTMLSourceRange(offset: offset, length: length)))
            case let .startTag(name, attributes, selfClosing, offset, length):
                closeImplicitElements(beforeStarting: name, stack: &stack, events: &events)
                let range = HTMLSourceRange(offset: offset, length: length)
                let element = HTMLStartElement(name: name, attributes: attributes, selfClosing: selfClosing, range: range)
                events.append(.startElement(element))

                if HTMLVocabulary.voidElements.contains(name) {
                    events.append(.endElement(name: name, range: range, implicit: true))
                } else {
                    stack.append(OpenElement(name: name, range: range))
                }
            case let .endTag(name, offset, length):
                closeElements(forEndTag: name, range: HTMLSourceRange(offset: offset, length: length), stack: &stack, events: &events)
            case let .text(content, offset, length):
                guard !content.isEmpty else { continue }
                events.append(.characters(content, range: HTMLSourceRange(offset: offset, length: length)))
            case let .comment(content, offset, length):
                events.append(.comment(content, range: HTMLSourceRange(offset: offset, length: length)))
            case .bogusMarkup, .parseError:
                continue
            }
        }

        while let element = stack.popLast() {
            events.append(.endElement(name: element.name, range: element.range, implicit: true))
        }
        events.append(.endDocument)
        return events
    }

    private func closeImplicitElements(
        beforeStarting name: String,
        stack: inout [OpenElement],
        events: inout [HTMLDocumentEvent]
    ) {
        if name == "li" {
            closeLast("li", stack: &stack, events: &events)
        } else if name == "dt" || name == "dd" {
            closeLast("dt", stack: &stack, events: &events)
            closeLast("dd", stack: &stack, events: &events)
        } else if name == "p", stack.last?.name == "p" {
            closeTop(stack: &stack, events: &events)
        } else if HTMLVocabulary.flowButNotPhrasing.contains(name), stack.last?.name == "p" {
            closeTop(stack: &stack, events: &events)
        }
    }

    private func closeLast(_ name: String, stack: inout [OpenElement], events: inout [HTMLDocumentEvent]) {
        guard let index = stack.lastIndex(where: { $0.name == name }) else { return }
        while stack.count > index {
            closeTop(stack: &stack, events: &events)
        }
    }

    private func closeTop(stack: inout [OpenElement], events: inout [HTMLDocumentEvent]) {
        guard let element = stack.popLast() else { return }
        events.append(.endElement(name: element.name, range: element.range, implicit: true))
    }

    private func closeElements(
        forEndTag name: String,
        range: HTMLSourceRange,
        stack: inout [OpenElement],
        events: inout [HTMLDocumentEvent]
    ) {
        guard !HTMLVocabulary.voidElements.contains(name),
              let match = stack.lastIndex(where: { $0.name == name }) else {
            return
        }

        while stack.count - 1 > match {
            closeTop(stack: &stack, events: &events)
        }
        _ = stack.popLast()
        events.append(.endElement(name: name, range: range, implicit: false))
    }
}

struct HTMLRequiredAttributeChecker {
    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []
        var stack: [String] = []

        for event in document.events {
            switch event {
            case let .startElement(element):
                appendRequiredAttributeMessages(for: element, parent: stack.last, locations: locations, messages: &messages)
                stack.append(element.name)
            case let .endElement(name, _, _):
                if let index = stack.lastIndex(of: name) {
                    stack.removeSubrange(index...)
                }
            default:
                continue
            }
        }

        return messages
    }

    private func appendRequiredAttributeMessages(
        for element: HTMLStartElement,
        parent: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        switch element.name {
        case "a":
            if !element.hasAttribute("href"),
               element.hasAttribute("download") || element.hasAttribute("ping") {
                appendMissingAttribute("href", for: element, locations: locations, messages: &messages)
            }
        case "area":
            appendAreaRequiredAttributeMessages(for: element, locations: locations, messages: &messages)
        case "img":
            if !element.hasAttribute("src"), !element.hasAttribute("srcset") {
                appendOneOrMoreMissingAttributes(["src", "srcset"], for: element, locations: locations, messages: &messages)
            }
        case "object":
            if !element.hasAttribute("data") {
                appendMissingAttribute("data", for: element, locations: locations, messages: &messages)
            }
        case "link":
            if !element.hasAttribute("href"), !element.hasAttribute("imagesrcset") {
                appendLinkURLMissingMessage(for: element, locations: locations, messages: &messages)
            }
        case "source":
            if parent == "picture", !element.hasAttribute("srcset") {
                appendMissingAttribute("srcset", for: element, locations: locations, messages: &messages)
            }
        default:
            break
        }
    }

    private func appendAreaRequiredAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard !element.hasAttribute("href") else { return }
        if element.hasAttribute("alt") || element.hasAttribute("download") {
            appendMissingAttribute("href", for: element, locations: locations, messages: &messages)
            return
        }

        let attributesRequiringHref: Set<String> = ["hreflang", "ping", "rel", "target", "type"]
        if element.attributes.contains(where: { attributesRequiringHref.contains($0.name) }) {
            appendMissingAttribute("alt", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendMissingAttribute(
        _ attribute: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            "Element \u{201c}\(element.name)\u{201d} is missing required attribute \u{201c}\(attribute)\u{201d}.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendOneOrMoreMissingAttributes(
        _ attributes: [String],
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let list = attributes.map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")
        messages.append(.error(
            "Element \u{201c}\(element.name)\u{201d} is missing one or more of the following attributes: \(list).",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendLinkURLMissingMessage(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }
}
