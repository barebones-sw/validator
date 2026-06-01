import Foundation

public final class HTMLValidator: Sendable {
    public init() {}

    private struct OpenElement {
        var name: String
        var offset: Int
    }

    public func validate(source: String) -> [ValidationMessage] {
        let locations = SourceLocationMap(source)
        let document = HTMLDocumentParser(source: source, locations: locations).parse()
        let tokens = document.tokens
        var messages: [ValidationMessage] = []
        var sawDoctype = false
        var sawStartTag = false
        var sawHTMLLang = false
        var sawClosedBody = false
        var ids: [String: Int] = [:]
        var metaCharsetCount = 0
        var stack: [OpenElement] = []
        appendSourcePatternDiagnostics(source: source, locations: locations, messages: &messages)

        for token in tokens {
            switch token {
            case let .doctype(offset, length):
                if !sawStartTag {
                    sawDoctype = true
                } else {
                    appendError("Stray doctype.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            case let .bogusMarkup(offset, length):
                appendError("Saw \u{201c}<\u{201d}. Probable cause: Unescaped \u{201c}<\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
            case let .parseError(message, offset, length):
                appendError(message, offset: offset, length: length, locations: locations, messages: &messages)
            case .text, .comment:
                continue
            case let .startTag(name, attributes, selfClosing, offset, length):
                if sawClosedBody, name != "html" {
                    appendError("Stray start tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                }
                sawStartTag = true
                if !sawDoctype {
                    appendError("Start tag seen without seeing a doctype first. Expected \u{201c}<!DOCTYPE html>\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    sawDoctype = true
                }
                validateStartTag(name: name, attributes: attributes, selfClosing: selfClosing, offset: offset, length: length, stack: stack, locations: locations, ids: &ids, metaCharsetCount: &metaCharsetCount, sawHTMLLang: &sawHTMLLang, messages: &messages)
                applyImplicitClosures(beforeStarting: name, stack: &stack)
                if !HTMLVocabulary.voidElements.contains(name) && !selfClosing {
                    stack.append(OpenElement(name: name, offset: offset))
                } else if selfClosing && HTMLVocabulary.voidElements.contains(name) {
                    appendInfo("Trailing slash on void elements has no effect and interacts badly with unquoted attribute values.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            case let .endTag(name, offset, length):
                if sawClosedBody, name != "html" {
                    appendError("Saw an end tag after \u{201c}body\u{201d} had been closed.", offset: offset, length: length, locations: locations, messages: &messages)
                    continue
                }
                if HTMLVocabulary.voidElements.contains(name) {
                    if name == "br" {
                        appendError("End tag \u{201c}br\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    } else {
                        appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    continue
                }
                guard let match = stack.lastIndex(where: { $0.name == name }) else {
                    if name == "p" {
                        appendError("No \u{201c}p\u{201d} element in scope but a \u{201c}p\u{201d} end tag seen.", offset: offset, length: length, locations: locations, messages: &messages)
                    } else {
                        appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    continue
                }
                if match != stack.index(before: stack.endIndex) {
                    appendError("End tag \u{201c}\(name)\u{201d} seen, but there were open elements.", offset: offset, length: length, locations: locations, messages: &messages)
                }
                stack.removeSubrange(match...)
                if name == "body" {
                    sawClosedBody = true
                }
            }
        }

        if stack.contains(where: { $0.name == "picture" }) {
            appendError("End of file seen and there were open elements.", offset: source.utf16.count, length: 1, locations: locations, messages: &messages)
        }

        messages.append(contentsOf: HTMLRequiredAttributeChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLURLAttributeChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLMicrodataAttributeChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLDefinitionListChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLGeneralAttributeChecker().validate(document: document, locations: locations))

        if sawStartTag, !sawHTMLLang {
            if let htmlToken = tokens.firstHTMLStart {
                appendWarning("Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document.", offset: htmlToken.offset, length: htmlToken.length, locations: locations, messages: &messages)
            }
        }
        return messages
    }

    private func validateStartTag(
        name: String,
        attributes: [HTMLAttribute],
        selfClosing: Bool,
        offset: Int,
        length: Int,
        stack: [OpenElement],
        locations: SourceLocationMap,
        ids: inout [String: Int],
        metaCharsetCount: inout Int,
        sawHTMLLang: inout Bool,
        messages: inout [ValidationMessage]
    ) {
        var seenAttributes: Set<String> = []
        var attr: [String: String] = [:]
        for attribute in attributes {
            if seenAttributes.contains(attribute.name) {
                appendError("Duplicate attribute \u{201c}\(attribute.name)\u{201d}.", offset: attribute.offset, length: max(1, attribute.name.utf16.count), locations: locations, messages: &messages)
            }
            seenAttributes.insert(attribute.name)
            attr[attribute.name] = decodeEntities(attribute.value ?? "")
        }

        if name == "html" {
            if let lang = attr["lang"], !lang.isEmpty {
                sawHTMLLang = true
                if !isPlausibleLanguageTag(lang) {
                    appendError("Bad value \u{201c}\(lang)\u{201d} for attribute \u{201c}lang\u{201d} on element \u{201c}html\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            }
            if let xmlLang = attr["xml:lang"], attr["lang"] != xmlLang {
                appendError("When the attribute \u{201c}xml:lang\u{201d} in no namespace is specified, the element must also have the attribute \u{201c}lang\u{201d} present with the same value.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }

        if let id = attr["id"], !id.isEmpty {
            if ids[id] != nil {
                appendError("Duplicate ID \u{201c}\(id)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
            } else {
                ids[id] = offset
            }
        }

        if name == "image" {
            appendError("Saw a start tag \u{201c}image\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "form", stack.contains(where: { $0.name == "form" }) {
            appendError("Saw a \u{201c}form\u{201d} start tag, but there was already an active \u{201c}form\u{201d} element. Nested forms are not allowed. Ignoring the tag.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if HTMLVocabulary.headingElements.contains(name), stack.contains(where: { HTMLVocabulary.headingElements.contains($0.name) }) {
            appendError("Heading cannot be a child of another heading.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "table", stack.contains(where: { $0.name == "table" }) {
            appendError("Start tag for \u{201c}table\u{201d} seen but the previous \u{201c}table\u{201d} is still open.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "select", stack.contains(where: { $0.name == "table" }) {
            appendError("Start tag \u{201c}select\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if HTMLVocabulary.obsoleteElements.contains(name) {
            if name == "frameset" {
                appendError("The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.", offset: offset, length: length, locations: locations, messages: &messages)
            } else {
                appendError("Element \u{201c}\(name)\u{201d} is obsolete. Use CSS instead.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        } else if !HTMLVocabulary.elements.contains(name), !name.contains("-") {
            let parent = stack.last?.name ?? "body"
            appendError("Element \u{201c}\(name)\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "img", attr["alt"] == nil {
            appendError("An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "input", attr["type"]?.lowercased() == "image", attr["alt"] == nil {
            appendError("Element \u{201c}input\u{201d} is missing required attribute \u{201c}alt\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "meta", attr["charset"] != nil {
            metaCharsetCount += 1
            if offset > 1024 {
                appendError("A \u{201c}charset\u{201d} attribute on a \u{201c}meta\u{201d} element found after the first 1024 bytes.", offset: offset, length: length, locations: locations, messages: &messages)
            }
            if metaCharsetCount > 1 {
                appendError("A document must not include more than one \u{201c}meta\u{201d} element with a \u{201c}charset\u{201d} attribute.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }

        if let impliedEndTagMessage = impliedEndTagMessage(beforeStarting: name, stack: stack) {
            appendError(impliedEndTagMessage, offset: offset, length: length, locations: locations, messages: &messages)
        }

        if let parentMessage = contentModelMessage(for: name, stack: stack) {
            appendError(parentMessage, offset: offset, length: length, locations: locations, messages: &messages)
        }

        if selfClosing && !HTMLVocabulary.voidElements.contains(name) {
            appendError("Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.", offset: offset, length: length, locations: locations, messages: &messages)
        }
    }

    private func contentModelMessage(for child: String, stack: [OpenElement]) -> String? {
        if child == "picture" {
            if stack.last?.name == "noscript", !stack.contains(where: { $0.name == "body" }) {
                return "Bad start tag in \u{201c}picture\u{201d} in \u{201c}noscript\u{201d} in \u{201c}head\u{201d}."
            }
            if let parent = stack.last?.name, Self.invalidPictureParents.contains(parent) {
                return "Element \u{201c}picture\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context."
            }
        }
        guard HTMLVocabulary.flowButNotPhrasing.contains(child) else { return nil }
        if let parent = stack.last?.name, HTMLVocabulary.phrasingOnlyContainers.contains(parent) {
            return "Element \u{201c}\(child)\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context."
        }
        if let transparentParent = stack.last(where: { HTMLVocabulary.transparentElements.contains($0.name) }),
           let inheritedParent = stack.reversed().first(where: { !HTMLVocabulary.transparentElements.contains($0.name) })?.name,
           HTMLVocabulary.phrasingOnlyContainers.contains(inheritedParent) {
            return "Element \u{201c}\(child)\u{201d} not allowed as child of \u{201c}\(transparentParent.name)\u{201d} in this context. Note: The \u{201c}\(transparentParent.name)\u{201d} element has a transparent content model; its allowed content is inherited from its parent element."
        }
        return nil
    }

    private func impliedEndTagMessage(beforeStarting child: String, stack: [OpenElement]) -> String? {
        guard HTMLVocabulary.flowButNotPhrasing.contains(child),
              let pIndex = stack.lastIndex(where: { $0.name == "p" }),
              pIndex != stack.index(before: stack.endIndex) else {
            return nil
        }
        return "End tag \u{201c}p\u{201d} implied, but there were open elements."
    }

    private func applyImplicitClosures(beforeStarting name: String, stack: inout [OpenElement]) {
        if name == "li" {
            closeLast("li", in: &stack)
        } else if name == "dt" || name == "dd" {
            closeLast("dt", in: &stack)
            closeLast("dd", in: &stack)
        } else if name == "p", stack.last?.name == "p" {
            _ = stack.popLast()
        } else if HTMLVocabulary.flowButNotPhrasing.contains(name),
                  let pIndex = stack.lastIndex(where: { $0.name == "p" }) {
            stack.removeSubrange(pIndex...)
        }
    }

    private func closeLast(_ name: String, in stack: inout [OpenElement]) {
        if let index = stack.lastIndex(where: { $0.name == name }) {
            stack.removeSubrange(index...)
        }
    }

    private func appendError(_ text: String, offset: Int, length: Int, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        messages.append(.error(text, location: locations.location(offset: offset, length: length), extract: locations.extract(offset: offset, length: length)))
    }

    private func appendWarning(_ text: String, offset: Int, length: Int, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        messages.append(.warning(text, location: locations.location(offset: offset, length: length), extract: locations.extract(offset: offset, length: length)))
    }

    private func appendInfo(_ text: String, offset: Int, length: Int, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        messages.append(.info(text, location: locations.location(offset: offset, length: length), extract: locations.extract(offset: offset, length: length)))
    }

    private func appendSourcePatternDiagnostics(source: String, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        func append(_ message: String, pattern: String) {
            if let range = source.range(of: pattern, options: [.caseInsensitive]) {
                appendError(message, offset: locations.offset(of: range.lowerBound), length: pattern.utf16.count, locations: locations, messages: &messages)
            }
        }

        append("Misplaced non-space characters inside a table.", pattern: "<table>text</table>")
        append("Non-space character after body.", pattern: "</body>text")
        append("Non-space character inside \u{201c}noscript\u{201d} inside \u{201c}head\u{201d}.", pattern: "<head><noscript>text</noscript></head>")
        append("The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.", pattern: "</frameset>\ntext")
    }

    private func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func isPlausibleLanguageTag(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#
        return value.range(of: pattern, options: .regularExpression) != nil && !value.contains("--") && !value.hasSuffix("-") && !value.hasPrefix("-")
    }

    private static let invalidPictureParents: Set<String> = [
        "dl", "hgroup", "rp", "ul"
    ]
}

private extension Array where Element == HTMLToken {
    var firstHTMLStart: (offset: Int, length: Int)? {
        for token in self {
            if case let .startTag(name, _, _, offset, length) = token, name == "html" {
                return (offset, length)
            }
        }
        return nil
    }
}

struct HTMLDefinitionListChecker {
    private enum DLMode {
        case undecided
        case directGroups
        case divGroups
    }

    private enum GroupState {
        case expectingTerm
        case readingTerms
        case readingDefinitions
    }

    private struct DLContext {
        var element: HTMLStartElement
        var depth: Int
        var mode: DLMode = .undecided
        var state: GroupState = .expectingTerm
        var termNames: Set<String> = []
        var sawTemplateWhileReadingTerms = false
    }

    private struct DivContext {
        var element: HTMLStartElement
        var depth: Int
        var state: GroupState = .expectingTerm
        var sawChild = false
    }

    private struct DTCapture {
        var element: HTMLStartElement
        var dlDepth: Int
        var text = ""
    }

    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []
        var stack: [String] = []
        var dlContexts: [DLContext] = []
        var divContexts: [DivContext] = []
        var dtCaptures: [DTCapture] = []

        for event in document.events {
            switch event {
            case let .startElement(element):
                appendDTDescendantMessage(for: element, stack: stack, locations: locations, messages: &messages)
                processStartElement(
                    element,
                    stack: stack,
                    locations: locations,
                    dlContexts: &dlContexts,
                    divContexts: &divContexts,
                    dtCaptures: &dtCaptures,
                    messages: &messages
                )
                stack.append(element.name)
            case let .characters(content, range):
                for index in dtCaptures.indices {
                    dtCaptures[index].text += content
                }
                guard content.contains(where: { !$0.isWhitespace }) else {
                    continue
                }
                if stack.last == "dl" {
                    messages.append(.error(
                        "Text not allowed in \u{201c}dl\u{201d} in this context.",
                        location: locations.location(offset: range.offset, length: range.length),
                        extract: locations.extract(offset: range.offset, length: range.length)
                    ))
                } else if isInsideDirectDLDiv(stack: stack, divContexts: divContexts) {
                    messages.append(.error(
                        "Text not allowed in \u{201c}div\u{201d} in this context.",
                        location: locations.location(offset: range.offset, length: range.length),
                        extract: locations.extract(offset: range.offset, length: range.length)
                    ))
                }
            case let .endElement(name, _, _):
                if name == "dt", let capture = dtCaptures.popLast() {
                    finishDTCapture(capture, dlContexts: &dlContexts, locations: locations, messages: &messages)
                }
                if name == "div", stack.count - 1 == divContexts.last?.depth, let context = divContexts.popLast() {
                    appendMissingMessages(for: context, locations: locations, messages: &messages)
                }
                if name == "dl", stack.count - 1 == dlContexts.last?.depth, let context = dlContexts.popLast() {
                    appendMissingMessages(for: context, locations: locations, messages: &messages)
                }
                if let index = stack.lastIndex(of: name) {
                    stack.removeSubrange(index...)
                }
            default:
                continue
            }
        }

        return messages
    }

    private func processStartElement(
        _ element: HTMLStartElement,
        stack: [String],
        locations: SourceLocationMap,
        dlContexts: inout [DLContext],
        divContexts: inout [DivContext],
        dtCaptures: inout [DTCapture],
        messages: inout [ValidationMessage]
    ) {
        if element.name == "dl" {
            if stack.last == "dl" || isInsideDirectDLDiv(stack: stack, divContexts: divContexts) {
                appendNotAllowed(element.name, parent: stack.last ?? "body", for: element, locations: locations, messages: &messages)
            }
            dlContexts.append(DLContext(element: element, depth: stack.count))
            return
        }

        if isDirectDLChild(stack: stack, dlContexts: dlContexts) {
            processDirectDLChild(element, locations: locations, dlContexts: &dlContexts, divContexts: &divContexts, dtCaptures: &dtCaptures, messages: &messages)
            return
        }

        if isInsideDirectDLDiv(stack: stack, divContexts: divContexts) {
            processDirectDLDivChild(element, locations: locations, divContexts: &divContexts, dlContexts: dlContexts, dtCaptures: &dtCaptures, messages: &messages)
        }
    }

    private func processDirectDLChild(
        _ element: HTMLStartElement,
        locations: SourceLocationMap,
        dlContexts: inout [DLContext],
        divContexts: inout [DivContext],
        dtCaptures: inout [DTCapture],
        messages: inout [ValidationMessage]
    ) {
        guard let index = dlContexts.indices.last else { return }
        switch element.name {
        case "script":
            return
        case "template":
            if dlContexts[index].state == .readingTerms {
                dlContexts[index].sawTemplateWhileReadingTerms = true
            }
        case "div":
            if dlContexts[index].mode == .directGroups {
                appendNotAllowed("div", parent: "dl", for: element, locations: locations, messages: &messages)
            } else {
                dlContexts[index].mode = .divGroups
            }
            divContexts.append(DivContext(element: element, depth: dlContexts[index].depth + 1))
        case "dt":
            if dlContexts[index].mode == .divGroups {
                appendNotAllowed("dt", parent: "dl", for: element, locations: locations, messages: &messages)
                return
            }
            dlContexts[index].mode = .directGroups
            dlContexts[index].state = .readingTerms
            dlContexts[index].sawTemplateWhileReadingTerms = false
            dtCaptures.append(DTCapture(element: element, dlDepth: dlContexts[index].depth))
        case "dd":
            if dlContexts[index].mode == .divGroups {
                appendNotAllowed("dd", parent: "dl", for: element, locations: locations, messages: &messages)
                return
            }
            dlContexts[index].mode = .directGroups
            if dlContexts[index].state == .expectingTerm {
                appendMissingDLTerm(for: dlContexts[index].element, locations: locations, messages: &messages)
            }
            dlContexts[index].state = .readingDefinitions
        default:
            appendNotAllowed(element.name, parent: "dl", for: element, locations: locations, messages: &messages)
        }
    }

    private func processDirectDLDivChild(
        _ element: HTMLStartElement,
        locations: SourceLocationMap,
        divContexts: inout [DivContext],
        dlContexts: [DLContext],
        dtCaptures: inout [DTCapture],
        messages: inout [ValidationMessage]
    ) {
        guard let index = divContexts.indices.last else { return }
        divContexts[index].sawChild = true
        switch element.name {
        case "script", "template":
            return
        case "dt":
            if divContexts[index].state == .readingDefinitions {
                appendNotAllowed("dt", parent: "div", for: element, locations: locations, messages: &messages)
            } else {
                divContexts[index].state = .readingTerms
                if let dlDepth = dlContexts.last?.depth {
                    dtCaptures.append(DTCapture(element: element, dlDepth: dlDepth))
                }
            }
        case "dd":
            if divContexts[index].state == .expectingTerm {
                appendMissingDivTerm(for: divContexts[index].element, locations: locations, messages: &messages)
            }
            divContexts[index].state = .readingDefinitions
        default:
            appendNotAllowed(element.name, parent: "div", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendDTDescendantMessage(
        for element: HTMLStartElement,
        stack: [String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let dtIndex = stack.lastIndex(of: "dt") else { return }
        if HTMLVocabulary.headingElements.contains(element.name),
           stack[stack.index(after: dtIndex)...].contains(where: { Self.dtSectioningElements.contains($0) }) {
            return
        }
        guard Self.dtForbiddenDescendants.contains(element.name) else { return }
        messages.append(.error(
            "The element \u{201c}\(element.name)\u{201d} must not appear as a descendant of the \u{201c}dt\u{201d} element.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func finishDTCapture(
        _ capture: DTCapture,
        dlContexts: inout [DLContext],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let name = normalizedText(capture.text)
        guard !name.isEmpty,
              let index = dlContexts.lastIndex(where: { $0.depth == capture.dlDepth }) else {
            return
        }
        if dlContexts[index].termNames.contains(name) {
            messages.append(.warning(
                "Duplicate \u{201c}dt\u{201d} name \u{201c}\(name)\u{201d} in \u{201c}dl\u{201d} element. Within a single \u{201c}dl\u{201d} element, there should not be more than one \u{201c}dt\u{201d} element for each name.",
                location: locations.location(offset: capture.element.range.offset, length: capture.element.range.length),
                extract: locations.extract(offset: capture.element.range.offset, length: capture.element.range.length)
            ))
        }
        dlContexts[index].termNames.insert(name)
    }

    private func appendMissingMessages(for context: DLContext, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        if context.mode == .directGroups, context.state == .readingTerms {
            let message = context.sawTemplateWhileReadingTerms
                ? "Element \u{201c}dl\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}dd\u{201d}."
                : "Element \u{201c}dl\u{201d} is missing a required instance of child element \u{201c}dd\u{201d}."
            messages.append(.error(
                message,
                location: locations.location(offset: context.element.range.offset, length: context.element.range.length),
                extract: locations.extract(offset: context.element.range.offset, length: context.element.range.length)
            ))
        }
    }

    private func appendMissingMessages(for context: DivContext, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        if context.state == .readingTerms || !context.sawChild {
            messages.append(.error(
                "Element \u{201c}div\u{201d} is missing a required instance of child element \u{201c}dd\u{201d}.",
                location: locations.location(offset: context.element.range.offset, length: context.element.range.length),
                extract: locations.extract(offset: context.element.range.offset, length: context.element.range.length)
            ))
        }
    }

    private func appendMissingDLTerm(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            "Element \u{201c}dl\u{201d} is missing a required child element.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendMissingDivTerm(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            "Element \u{201c}div\u{201d} is missing a required instance of child element \u{201c}dt\u{201d}.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendNotAllowed(
        _ elementName: String,
        parent: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            "Element \u{201c}\(elementName)\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func isDirectDLChild(stack: [String], dlContexts: [DLContext]) -> Bool {
        guard stack.last == "dl",
              stack.count - 1 == dlContexts.last?.depth else {
            return false
        }
        return true
    }

    private func isInsideDirectDLDiv(stack: [String], divContexts: [DivContext]) -> Bool {
        guard stack.last == "div",
              stack.count - 1 == divContexts.last?.depth else {
            return false
        }
        return true
    }

    private func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let dtSectioningElements: Set<String> = [
        "article", "nav", "section"
    ]

    private static let dtForbiddenDescendants: Set<String> = [
        "article", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "nav", "section"
    ]
}

enum HTMLVocabulary {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"
    ]

    static let obsoleteElements: Set<String> = [
        "acronym", "applet", "basefont", "bgsound", "big", "blink", "center",
        "font", "frame", "frameset", "marquee", "nobr", "noembed", "noframes",
        "plaintext", "rb", "rtc", "strike", "tt", "xmp"
    ]

    static let transparentElements: Set<String> = [
        "a", "audio", "canvas", "del", "ins", "map", "object", "video"
    ]

    static let phrasingOnlyContainers: Set<String> = [
        "a", "abbr", "b", "bdi", "bdo", "button", "cite", "code", "data",
        "del", "dfn", "em", "h1", "h2", "h3", "h4", "h5", "h6", "i", "ins",
        "kbd", "label", "mark", "p", "q", "s", "samp", "small", "span",
        "strong", "sub", "sup", "time", "u", "var"
    ]

    static let flowButNotPhrasing: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "dialog",
        "div", "dl", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr",
        "main", "menu", "nav", "ol", "p", "pre", "section", "table", "ul"
    ]

    static let headingElements: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6"
    ]

    static let elements: Set<String> = [
        "a", "abbr", "address", "area", "article", "aside", "audio", "b",
        "base", "bdi", "bdo", "blockquote", "body", "br", "button", "canvas",
        "caption", "cite", "code", "col", "colgroup", "data", "datalist",
        "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt", "em",
        "embed", "fieldset", "figcaption", "figure", "footer", "form", "h1",
        "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr",
        "html", "i", "iframe", "img", "input", "ins", "kbd", "label",
        "legend", "li", "link", "main", "map", "mark", "math", "menu",
        "meta", "meter", "nav", "noscript", "object", "ol", "optgroup",
        "option", "output", "p", "param", "picture", "pre", "progress", "q",
        "rp", "rt", "ruby", "s", "samp", "script", "search", "section",
        "select", "slot", "small", "source", "span", "strong", "style",
        "sub", "summary", "sup", "svg", "table", "tbody", "td", "template",
        "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track",
        "u", "ul", "var", "video", "wbr"
    ]
}
