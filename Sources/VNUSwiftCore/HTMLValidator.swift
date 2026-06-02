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
        var firstStartTag: (offset: Int, length: Int)?
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
                if firstStartTag == nil {
                    firstStartTag = (offset, length)
                }
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
        messages.append(contentsOf: HTMLMetaChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLDefinitionListChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLTableChecker().validate(document: document, locations: locations))
        messages.append(contentsOf: HTMLGeneralAttributeChecker().validate(document: document, locations: locations))

        if sawStartTag, !sawHTMLLang {
            if let htmlToken = tokens.firstHTMLStart {
                appendWarning("Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document.", offset: htmlToken.offset, length: htmlToken.length, locations: locations, messages: &messages)
            } else if let firstStartTag {
                appendWarning("Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document.", offset: firstStartTag.offset, length: firstStartTag.length, locations: locations, messages: &messages)
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

        if name == "basefont" {
            appendError("Element \u{201c}basefont\u{201d} not allowed as child of \u{201c}head\u{201d} in this context.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "head", attr["profile"] != nil {
            appendWarning("The \u{201c}profile\u{201d} attribute on the \u{201c}head\u{201d} element is obsolete. To declare which \u{201c}meta\u{201d} terms are used in the document, instead register the names as meta extensions. To trigger specific UA behaviors, use a \u{201c}link\u{201d} element instead.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if HTMLVocabulary.headingElements.contains(name), stack.contains(where: { HTMLVocabulary.headingElements.contains($0.name) }) {
            appendError("Heading cannot be a child of another heading.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "table", stack.contains(where: { $0.name == "table" }) {
            appendError("Start tag for \u{201c}table\u{201d} seen but the previous \u{201c}table\u{201d} is still open.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if (name == "input" || name == "select"), stack.last?.name == "table" {
            appendError("Start tag \u{201c}\(name)\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if HTMLVocabulary.obsoleteElements.contains(name) {
            if let obsoleteMessage = obsoleteElementMessage(for: name) {
                appendError(obsoleteMessage, offset: offset, length: length, locations: locations, messages: &messages)
            } else if name == "keygen" {
                appendError("The \u{201c}keygen\u{201d} element is obsolete.", offset: offset, length: length, locations: locations, messages: &messages)
            } else {
                appendError("The \u{201c}\(name)\u{201d} element is obsolete. Use CSS instead.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        } else if name.contains("-") {
            if !isValidAutonomousCustomElementName(name) {
                appendError("Element \u{201c}\(name)\u{201d} not allowed.", offset: offset, length: length, locations: locations, messages: &messages)
            }
            if attr["is"] != nil {
                appendError("Autonomous custom elements must not specify the \u{201c}is\u{201d} attribute.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        } else if !HTMLVocabulary.elements.contains(name) {
            let currentParent = stack.last?.name
            let parent = currentParent == nil || currentParent == "html" ? "body" : currentParent!
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
        if child == "li" {
            let parent = stack.last?.name
            if parent != "ol" && parent != "ul" && parent != "menu" {
                let parentName = parent == nil || parent == "html" ? "body" : parent!
                return "Element \u{201c}li\u{201d} not allowed as child of \u{201c}\(parentName)\u{201d} in this context."
            }
        }
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

    private func isValidAutonomousCustomElementName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        guard lowercased.contains("-"), !Self.reservedCustomElementNames.contains(lowercased) else {
            return false
        }
        let pattern = #"^[a-z][.0-9_a-z-]*-[.0-9_a-z-]*$"#
        return lowercased.range(of: pattern, options: .regularExpression) != nil
    }

    private func obsoleteElementMessage(for name: String) -> String? {
        switch name {
        case "acronym":
            return "The \u{201c}acronym\u{201d} element is obsolete. Use the \u{201c}abbr\u{201d} element instead."
        case "applet":
            return "The \u{201c}applet\u{201d} element is obsolete. Use \u{201c}embed\u{201d} or \u{201c}object\u{201d} element instead."
        case "dir":
            return "The \u{201c}dir\u{201d} element is obsolete. Use the \u{201c}ul\u{201d} element instead."
        case "frameset", "noframes":
            return "The \u{201c}\(name)\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."
        case "strike":
            return "The \u{201c}strike\u{201d} element is obsolete. Use \u{201c}del\u{201d} or \u{201c}s\u{201d} element instead."
        default:
            return nil
        }
    }

    private static let invalidPictureParents: Set<String> = [
        "dl", "hgroup", "rp", "ul"
    ]

    private static let reservedCustomElementNames: Set<String> = [
        "annotation-xml", "color-profile", "font-face", "font-face-src",
        "font-face-uri", "font-face-format", "font-face-name", "missing-glyph"
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

struct HTMLMetaChecker {
    private struct CSPIssue {
        var warning: Bool
    }

    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        let elements = metaElements(in: document)
        var messages: [ValidationMessage] = []
        var sawCharset = false
        var sawContentType = false
        var sawDescription = false

        for element in elements {
            let charset = normalizedValue(element.attributeValue("charset"))
            let name = normalizedValue(element.attributeValue("name"))
            let httpEquiv = normalizedValue(element.attributeValue("http-equiv"))
            let content = element.attributeValue("content") ?? ""

            if let charset {
                sawCharset = true
                if element.hasAttribute("content") {
                    appendError("Attribute \u{201c}content\u{201d} not allowed on element \u{201c}meta\u{201d} at this point.", for: element, locations: locations, messages: &messages)
                }
                if charset != "utf-8" {
                    appendError("Internal encoding declaration \u{201c}\(element.attributeValue("charset") ?? "")\u{201d} disagrees with the actual encoding of the document (\u{201c}utf-8\u{201d}).", for: element, locations: locations, messages: &messages)
                }
            }

            if httpEquiv == "content-type" {
                sawContentType = true
            }
            if sawCharset, sawContentType {
                appendError("A document must not include both a \u{201c}meta\u{201d} element with an \u{201c}http-equiv\u{201d} attribute whose value is \u{201c}content-type\u{201d}, and a \u{201c}meta\u{201d} element with a \u{201c}charset\u{201d} attribute.", for: element, locations: locations, messages: &messages)
                sawContentType = false
            }

            if name == "description" {
                if sawDescription {
                    appendError("A document must not include more than one \u{201c}meta\u{201d} element with its \u{201c}name\u{201d} attribute set to the value \u{201c}description\u{201d}.", for: element, locations: locations, messages: &messages)
                }
                sawDescription = true
            }

            if element.hasAttribute("itemprop"), element.hasAttribute("name") {
                appendError("Attribute \u{201c}itemprop\u{201d} not allowed on element \u{201c}meta\u{201d} at this point.", for: element, locations: locations, messages: &messages)
            }
            if element.hasAttribute("media"), name != "theme-color" {
                appendError("A \u{201c}meta\u{201d} element with a \u{201c}media\u{201d} attribute must have a \u{201c}name\u{201d} attribute whose value is \u{201c}theme-color\u{201d}.", for: element, locations: locations, messages: &messages)
            }

            appendHTTPEquivMessages(httpEquiv: httpEquiv, content: content, element: element, locations: locations, messages: &messages)
            appendViewportMessages(name: name, content: content, element: element, locations: locations, messages: &messages)
        }

        return messages
    }

    private func metaElements(in document: HTMLParsedDocument) -> [HTMLStartElement] {
        document.events.compactMap { event in
            guard case let .startElement(element) = event, element.name == "meta" else {
                return nil
            }
            return element
        }
    }

    private func appendHTTPEquivMessages(
        httpEquiv: String?,
        content: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        switch httpEquiv {
        case "content-language":
            appendError("Using the \u{201c}meta\u{201d} element to specify the document-wide default language is obsolete. Consider specifying the language on the root element instead.", for: element, locations: locations, messages: &messages)
        case "content-type":
            appendContentTypeEncodingMessages(content: content, element: element, locations: locations, messages: &messages)
        case "refresh":
            if !isValidRefresh(content) {
                appendError("Bad value \u{201c}\(content)\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        case "x-ua-compatible":
            if content.lowercased() != "ie=edge" {
                appendError("A \u{201c}meta\u{201d} element with an \u{201c}http-equiv\u{201d} attribute whose value is \u{201c}X-UA-Compatible\u{201d} must have a \u{201c}content\u{201d} attribute with the value \u{201c}IE=edge\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        case "content-security-policy":
            if let issue = cspIssue(in: content) {
                let message = "Bad value \u{201c}\(content)\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}."
                if issue.warning {
                    appendWarning(message, for: element, locations: locations, messages: &messages)
                } else {
                    appendError(message, for: element, locations: locations, messages: &messages)
                }
            }
        default:
            break
        }
    }

    private func appendContentTypeEncodingMessages(
        content: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let charsetRange = content.range(of: "charset=", options: [.caseInsensitive]) else {
            return
        }
        let charset = content[charsetRange.upperBound...]
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !charset.isEmpty else {
            appendError("Bad value \u{201c}\(content)\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}.", for: element, locations: locations, messages: &messages)
            return
        }

        let normalized = charset.lowercased()
        guard normalized != "utf-8" else { return }
        if Self.supportedEncodingLabels.contains(normalized) {
            appendError("Internal encoding declaration \u{201c}\(charset)\u{201d} disagrees with the actual encoding of the document (\u{201c}utf-8\u{201d}).", for: element, locations: locations, messages: &messages)
        } else {
            appendError("Internal encoding declaration named an unsupported chararacter encoding \u{201c}\(charset)\u{201d}.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendViewportMessages(
        name: String?,
        content: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard name == "viewport" else { return }
        let components = content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        if components.contains(where: { $0.replacingOccurrences(of: " ", with: "") == "user-scalable=no" }) {
            appendWarning("Consider avoiding viewport values that prevent users from resizing documents.", for: element, locations: locations, messages: &messages)
        }
    }

    private func isValidRefresh(_ value: String) -> Bool {
        let pattern = #"^\s*[0-9]+(?:\.[0-9]+)?\s*(?:;\s+url=[^'"\s].*)?\s*$"#
        return value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func cspIssue(in value: String) -> CSPIssue? {
        if value.unicodeScalars.contains(where: { $0.value > 127 }) {
            return CSPIssue(warning: false)
        }
        for policy in value.split(separator: ",", omittingEmptySubsequences: false) {
            for rawDirective in policy.split(separator: ";", omittingEmptySubsequences: false) {
                let parts = rawDirective.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let directive = parts.first?.lowercased(), !directive.isEmpty else {
                    continue
                }
                if !Self.cspDirectives.contains(directive) {
                    return CSPIssue(warning: true)
                }
                for source in parts.dropFirst() where isInvalidQuotedCSPSource(source) {
                    return CSPIssue(warning: false)
                }
            }
        }
        return nil
    }

    private func isInvalidQuotedCSPSource(_ source: String) -> Bool {
        guard source.hasPrefix("'"), source.hasSuffix("'") else {
            return false
        }
        let inner = String(source.dropFirst().dropLast()).lowercased()
        return !Self.cspQuotedSources.contains(inner)
            && !inner.hasPrefix("nonce-")
            && !inner.hasPrefix("sha256-")
            && !inner.hasPrefix("sha384-")
            && !inner.hasPrefix("sha512-")
    }

    private func normalizedValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private func appendError(_ message: String, for element: HTMLStartElement, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        messages.append(.error(
            message,
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendWarning(_ message: String, for element: HTMLStartElement, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        messages.append(.warning(
            message,
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private static let cspDirectives: Set<String> = [
        "base-uri", "block-all-mixed-content", "child-src", "connect-src", "default-src",
        "font-src", "form-action", "frame-ancestors", "frame-src", "img-src", "manifest-src",
        "media-src", "object-src", "prefetch-src", "require-trusted-types-for", "sandbox",
        "script-src", "script-src-attr", "script-src-elem", "style-src", "style-src-attr",
        "style-src-elem", "trusted-types", "upgrade-insecure-requests", "worker-src"
    ]

    private static let cspQuotedSources: Set<String> = [
        "allow-duplicates", "none", "report-sample", "script", "self", "strict-dynamic",
        "unsafe-eval", "unsafe-hashes", "unsafe-inline", "wasm-unsafe-eval"
    ]

    private static let supportedEncodingLabels: Set<String> = [
        "utf-8", "utf8", "us-ascii", "iso-8859-1", "windows-1252"
    ]
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

struct HTMLTableElementInfo {
    var name: String
    var attributes: [String: String]
    var location: SourceLocation
    var extract: SourceExtract?
}

struct HTMLTableDiagnostic {
    var message: String
    var location: SourceLocation
    var extract: SourceExtract?
    var warning = false
}

struct HTMLTableChecker {
    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var checker = HTMLTableModelChecker(mode: .html)

        for event in document.events {
            switch event {
            case let .startElement(element):
                checker.startElement(info(for: element, locations: locations))
            case let .endElement(name, _, _):
                checker.endElement(name)
            default:
                continue
            }
        }

        return checker.finish().map { diagnostic in
            if diagnostic.warning {
                return .warning(diagnostic.message, location: diagnostic.location, extract: diagnostic.extract)
            }
            return .error(diagnostic.message, location: diagnostic.location, extract: diagnostic.extract)
        }
    }

    private func info(for element: HTMLStartElement, locations: SourceLocationMap) -> HTMLTableElementInfo {
        var attributes: [String: String] = [:]
        for attribute in element.attributes {
            attributes[attribute.name] = attribute.value ?? ""
        }
        return HTMLTableElementInfo(
            name: element.name,
            attributes: attributes,
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        )
    }
}

struct HTMLTableModelChecker {
    enum Mode {
        case html
        case xhtml
    }

    private struct TableState {
        var element: HTMLTableElementInfo
        var role: String?
        var columnMarkupCount = 0
        var globalRowCount = 0
        var rows: [TableRow] = []
        var cellEstablishedColumns: Set<Int> = []
        var cellStartColumns: Set<Int> = []
        var thIDs: Set<String> = []
        var pendingHeaderReferences: [HeaderReference] = []
        var rowGroup: RowGroupState?
        var row: ActiveRow?
        var colgroupCountsChildren = false
    }

    private struct RowGroupState {
        var name: String?
        var rows: [TableRow] = []
        var openSpans: [OpenSpan] = []
    }

    private struct ActiveRow {
        var globalNumber: Int
        var numberInGroup: Int
        var occupiedColumns: Set<Int>
        var startColumns: Set<Int> = []
        var sourceCellCount = 0
        var width: Int
        var element: HTMLTableElementInfo
    }

    private struct TableRow {
        var width: Int
        var startCellCount: Int
        var numberInGroup: Int
        var groupName: String?
        var element: HTMLTableElementInfo
    }

    private struct OpenSpan {
        var columns: Range<Int>
        var endRow: Int?
        var groupName: String?
        var cell: HTMLTableElementInfo
    }

    private struct HeaderReference {
        var cellName: String
        var id: String
        var cell: HTMLTableElementInfo
    }

    private let mode: Mode
    private var elementStack: [String] = []
    private var tableStack: [TableState] = []
    private var diagnostics: [HTMLTableDiagnostic] = []
    private var sawRootElement = false

    init(mode: Mode) {
        self.mode = mode
    }

    mutating func startElement(_ element: HTMLTableElementInfo) {
        if mode == .xhtml, !sawRootElement {
            sawRootElement = true
            if element.name == "table" {
                append("Element \u{201c}table\u{201d} not allowed in this context.", at: element)
            }
        }

        if element.name == "table" {
            let role = normalizedRole(element.attributes["role"])
            tableStack.append(TableState(element: element, role: role))
            elementStack.append(element.name)
            return
        }

        if !tableStack.isEmpty {
            processTableElement(element)
        }
        elementStack.append(element.name)
    }

    mutating func endElement(_ name: String) {
        if name == "tr" {
            finishCurrentRow()
        } else if Self.rowGroupElements.contains(name) {
            finishCurrentRow()
            finishCurrentRowGroup()
        } else if name == "colgroup", !tableStack.isEmpty {
            tableStack[tableStack.index(before: tableStack.endIndex)].colgroupCountsChildren = false
        } else if name == "table", !tableStack.isEmpty {
            finishCurrentRow()
            finishCurrentRowGroup()
            finishCurrentTable()
        }

        if let index = elementStack.lastIndex(of: name) {
            elementStack.removeSubrange(index...)
        }
    }

    mutating func finish() -> [HTMLTableDiagnostic] {
        while !tableStack.isEmpty {
            finishCurrentRow()
            finishCurrentRowGroup()
            finishCurrentTable()
        }
        return diagnostics
    }

    private mutating func processTableElement(_ element: HTMLTableElementInfo) {
        switch element.name {
        case "input", "select":
            if mode == .html, elementStack.last == "table" {
                append("Start tag \u{201c}\(element.name)\u{201d} seen in \u{201c}table\u{201d}.", at: element)
            }
        case "colgroup":
            finishCurrentRowGroup()
            processColgroup(element)
        case "col":
            processCol(element)
        case "tbody", "thead", "tfoot":
            finishCurrentRow()
            finishCurrentRowGroup()
            currentTable.rowGroup = RowGroupState(name: element.name)
        case "tr":
            startRow(element)
        case "td", "th":
            startCell(element)
        default:
            break
        }
    }

    private mutating func processColgroup(_ element: HTMLTableElementInfo) {
        if let spanValue = element.attributes["span"] {
            let span = tableSpan(spanValue, attribute: "span", element: element)
            currentTable.columnMarkupCount += span
            currentTable.colgroupCountsChildren = false
        } else {
            currentTable.colgroupCountsChildren = true
        }
    }

    private mutating func processCol(_ element: HTMLTableElementInfo) {
        if mode == .xhtml, elementStack.last == "table" {
            append("Element \u{201c}col\u{201d} not allowed as child of \u{201c}table\u{201d} in this context.", at: element)
        }

        if mode == .html || currentTable.colgroupCountsChildren || elementStack.last == "table" {
            currentTable.columnMarkupCount += tableSpan(element.attributes["span"], attribute: "span", element: element)
        }
    }

    private mutating func startRow(_ element: HTMLTableElementInfo) {
        if currentTable.row != nil {
            finishCurrentRow()
        }
        if currentTable.rowGroup == nil {
            currentTable.rowGroup = RowGroupState(name: nil)
        }

        currentTable.globalRowCount += 1
        let globalNumber = currentTable.globalRowCount
        var occupied: Set<Int> = []
        if let group = currentTable.rowGroup {
            for span in group.openSpans {
                if span.endRow == nil || globalNumber < span.endRow! {
                    for column in span.columns {
                        occupied.insert(column)
                    }
                }
            }
        }
        let initialWidth = (occupied.max() ?? -1) + 1
        let numberInGroup = (currentTable.rowGroup?.rows.count ?? 0) + 1
        currentTable.row = ActiveRow(
            globalNumber: globalNumber,
            numberInGroup: numberInGroup,
            occupiedColumns: occupied,
            width: max(0, initialWidth),
            element: element
        )
    }

    private mutating func startCell(_ element: HTMLTableElementInfo) {
        if currentTable.row == nil {
            startRow(element)
        }

        if element.name == "th", let id = element.attributes["id"], !id.isEmpty {
            currentTable.thIDs.insert(id)
        }
        if let headers = element.attributes["headers"] {
            for id in headers.split(whereSeparator: { $0.isWhitespace }).map(String.init) where !id.isEmpty {
                currentTable.pendingHeaderReferences.append(HeaderReference(cellName: element.name, id: id, cell: element))
            }
        }
        if element.name == "td",
           element.attributes["role"] != nil,
           currentTable.role == nil || Self.tableCellRoleBlockingTableRoles.contains(currentTable.role ?? "") {
            append("The \u{201c}role\u{201d} attribute must not be used on a \u{201c}td\u{201d} element which has a \u{201c}table\u{201d} ancestor with no \u{201c}role\u{201d} attribute, or with a \u{201c}role\u{201d} attribute whose value is \u{201c}table\u{201d}, \u{201c}grid\u{201d}, or \u{201c}treegrid\u{201d}.", at: element)
        }

        let colspan = cellColspan(for: element)
        let rowspan = cellRowspan(for: element)
        guard colspan > 0 else { return }

        var row = currentTable.row!
        var startColumn = 0
        while row.occupiedColumns.contains(startColumn) {
            startColumn += 1
        }
        let columns = startColumn..<(startColumn + colspan)
        if columns.contains(where: { row.occupiedColumns.contains($0) }) {
            append("Table cell is overlapped by later table cell.", at: element)
        }

        for column in columns {
            row.occupiedColumns.insert(column)
            currentTable.cellEstablishedColumns.insert(column)
        }
        row.startColumns.insert(startColumn)
        row.sourceCellCount += 1
        row.width = max(row.width, columns.upperBound)
        currentTable.cellStartColumns.insert(startColumn)

        if rowspan > 1 || rowspan == 0 {
            let groupName = currentTable.rowGroup?.name
            currentTable.rowGroup?.openSpans.append(OpenSpan(
                columns: columns,
                endRow: rowspan == 0 ? nil : row.globalNumber + rowspan,
                groupName: groupName,
                cell: element
            ))
        }

        currentTable.row = row
    }

    private mutating func finishCurrentRow() {
        guard var row = currentTable.row else { return }
        if let group = currentTable.rowGroup {
            let activeSpans = group.openSpans.filter { span in
                span.endRow == nil || row.globalNumber < span.endRow!
            }
            for span in activeSpans {
                row.width = max(row.width, span.columns.upperBound)
            }
        }

        if row.sourceCellCount == 0 {
            append(
                rowNoCellsMessage(row.numberInGroup, groupName: currentTable.rowGroup?.name),
                at: row.element
            )
        }

        let tableRow = TableRow(
            width: row.width,
            startCellCount: row.sourceCellCount,
            numberInGroup: row.numberInGroup,
            groupName: currentTable.rowGroup?.name,
            element: row.element
        )
        currentTable.rows.append(tableRow)
        currentTable.rowGroup?.rows.append(tableRow)
        currentTable.row = nil
    }

    private mutating func finishCurrentRowGroup() {
        guard let group = currentTable.rowGroup else { return }
        let rowCount = currentTable.globalRowCount
        for span in group.openSpans {
            if let endRow = span.endRow, endRow > rowCount {
                append(
                    "Table cell spans past the end of its row group established by \(rowGroupDescription(span.groupName)); clipped to the end of the row group.",
                    at: span.cell
                )
            }
        }
        currentTable.rowGroup = nil
    }

    private mutating func finishCurrentTable() {
        var table = tableStack.removeLast()

        for reference in table.pendingHeaderReferences where !table.thIDs.contains(reference.id) {
            append(
                "The \u{201c}headers\u{201d} attribute on the element \u{201c}\(reference.cellName)\u{201d} refers to the ID \u{201c}\(reference.id)\u{201d}, but there is no \u{201c}th\u{201d} element with that ID in the same table.",
                at: reference.cell
            )
        }

        appendRowWidthMessages(for: table)
        appendColumnStartMessages(for: table)
        table.rows.removeAll()
    }

    private mutating func appendRowWidthMessages(for table: TableState) {
        if table.columnMarkupCount > 0 {
            for row in table.rows where row.startCellCount > 0 {
                if row.width > table.columnMarkupCount {
                    append(
                        "A table row was \(row.width) columns wide and exceeded the column count established using column markup (\(table.columnMarkupCount)).",
                        at: row.element
                    )
                } else if row.width < table.columnMarkupCount {
                    append(
                        "A table row was \(row.width) columns wide, which is less than the column count established using column markup (\(table.columnMarkupCount)).",
                        at: row.element
                    )
                }
            }
            return
        }

        guard let firstWidth = table.rows.first(where: { $0.width > 0 })?.width else { return }
        for row in table.rows.dropFirst() where row.startCellCount > 0 {
            if row.width > firstWidth {
                append(
                    "A table row was \(row.width) columns wide and exceeded the column count established by the first row (\(firstWidth)).",
                    at: row.element,
                    warning: true
                )
            } else if row.width < firstWidth {
                append(
                    "A table row was \(row.width) columns wide, which is less than the column count established by the first row (\(firstWidth)).",
                    at: row.element,
                    warning: true
                )
            }
        }
    }

    private mutating func appendColumnStartMessages(for table: TableState) {
        let missing = table.cellEstablishedColumns
            .filter { !table.cellStartColumns.contains($0) }
            .sorted()
        guard !missing.isEmpty else { return }

        for range in consecutiveRanges(missing) {
            if range.count == 1, let column = range.first {
                append(
                    "Table column \(column + 1) established by element \u{201c}td\u{201d} has no cells beginning in it.",
                    at: table.element
                )
            } else if let first = range.first, let last = range.last {
                append(
                    "Table columns in range \(first + 1)\u{2026}\(last + 1) established by element \u{201c}td\u{201d} have no cells beginning in them.",
                    at: table.element
                )
            }
        }
    }

    private func consecutiveRanges(_ values: [Int]) -> [[Int]] {
        var ranges: [[Int]] = []
        for value in values {
            if let last = ranges.indices.last, ranges[last].last == value - 1 {
                ranges[last].append(value)
            } else {
                ranges.append([value])
            }
        }
        return ranges
    }

    private mutating func cellColspan(for element: HTMLTableElementInfo) -> Int {
        guard let value = element.attributes["colspan"] else { return 1 }
        guard let colspan = validInteger(value) else {
            appendBadValue(value, attribute: "colspan", element: element)
            return 1
        }
        if colspan == 0 {
            appendBadValue(value, attribute: "colspan", element: element)
            return 1
        }
        if colspan > 1000 {
            append("The value of the \u{201c}colspan\u{201d} attribute must be less than or equal to 1000.", at: element)
        }
        return max(1, min(colspan, 1000))
    }

    private mutating func cellRowspan(for element: HTMLTableElementInfo) -> Int {
        guard let value = element.attributes["rowspan"] else { return 1 }
        guard let rowspan = validInteger(value) else {
            appendBadValue(value, attribute: "rowspan", element: element)
            return 1
        }
        if rowspan > 65534 {
            append("The value of the \u{201c}rowspan\u{201d} attribute must be less than or equal to 65534.", at: element)
        }
        return max(0, min(rowspan, 65534))
    }

    private mutating func tableSpan(_ value: String?, attribute: String, element: HTMLTableElementInfo) -> Int {
        guard let value else { return 1 }
        guard let span = validInteger(value), span > 0 else {
            appendBadValue(value, attribute: attribute, element: element)
            return 1
        }
        if span > 1000 {
            append("The value of the \u{201c}\(attribute)\u{201d} attribute must be less than or equal to 1000.", at: element)
        }
        return max(1, min(span, 1000))
    }

    private func validInteger(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return Int(trimmed)
    }

    private func normalizedRole(_ value: String?) -> String? {
        value?.split(whereSeparator: { $0.isWhitespace }).first.map { String($0).lowercased() }
    }

    private func rowGroupDescription(_ name: String?) -> String {
        if let name {
            return "a \u{201c}\(name)\u{201d} element"
        }
        return mode == .html ? "a \u{201c}tbody\u{201d} element" : "an implicit row group"
    }

    private func rowNoCellsMessage(_ rowNumber: Int, groupName: String?) -> String {
        if mode == .xhtml, groupName == nil {
            return "Row \(rowNumber) of an implicit row group has no cells beginning on it."
        }
        return "Row \(rowNumber) of a row group established by \(rowGroupDescription(groupName)) has no cells beginning on it."
    }

    private mutating func appendBadValue(_ value: String, attribute: String, element: HTMLTableElementInfo) {
        append("Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute)\u{201d} on element \u{201c}\(element.name)\u{201d}.", at: element)
    }

    private mutating func append(_ message: String, at element: HTMLTableElementInfo, warning: Bool = false) {
        diagnostics.append(HTMLTableDiagnostic(
            message: message,
            location: element.location,
            extract: element.extract,
            warning: warning
        ))
    }

    private var currentTable: TableState {
        get { tableStack[tableStack.index(before: tableStack.endIndex)] }
        set { tableStack[tableStack.index(before: tableStack.endIndex)] = newValue }
    }

    private static let rowGroupElements: Set<String> = ["tbody", "thead", "tfoot"]
    private static let tableCellRoleBlockingTableRoles: Set<String> = ["table", "grid", "treegrid"]
}

enum HTMLVocabulary {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"
    ]

    static let obsoleteElements: Set<String> = [
        "acronym", "applet", "basefont", "bgsound", "big", "blink", "center", "dir",
        "font", "frame", "frameset", "keygen", "marquee", "nobr", "noembed",
        "noframes", "plaintext", "rb", "rtc", "strike", "tt", "xmp"
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
