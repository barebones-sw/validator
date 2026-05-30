import Foundation

public final class HTMLValidator: Sendable {
    public init() {}

    private struct OpenElement {
        var name: String
        var offset: Int
    }

    public func validate(source: String) -> [ValidationMessage] {
        let locations = SourceLocationMap(source)
        let tokens = HTMLTokenizer(source: source, locations: locations).tokenize()
        var messages: [ValidationMessage] = []
        var sawDoctype = false
        var sawStartTag = false
        var sawHTMLLang = false
        var ids: [String: Int] = [:]
        var metaCharsetCount = 0
        var stack: [OpenElement] = []

        for token in tokens {
            switch token {
            case .doctype:
                if !sawStartTag {
                    sawDoctype = true
                }
            case let .bogusMarkup(offset, length):
                appendError("Saw \u{201c}<\u{201d}. Probable cause: Unescaped \u{201c}<\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
            case let .startTag(name, attributes, selfClosing, offset, length):
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
                if HTMLVocabulary.voidElements.contains(name) {
                    appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    continue
                }
                guard let match = stack.lastIndex(where: { $0.name == name }) else {
                    appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    continue
                }
                if match != stack.index(before: stack.endIndex) {
                    appendError("End tag \u{201c}\(name)\u{201d} seen, but there were open elements.", offset: offset, length: length, locations: locations, messages: &messages)
                }
                stack.removeSubrange(match...)
            }
        }

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

        if HTMLVocabulary.obsoleteElements.contains(name) {
            appendError("Element \u{201c}\(name)\u{201d} is obsolete. Use CSS instead.", offset: offset, length: length, locations: locations, messages: &messages)
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
            if metaCharsetCount > 1 {
                appendError("A document must not include more than one \u{201c}meta\u{201d} element with a \u{201c}charset\u{201d} attribute.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }

        if let parentMessage = contentModelMessage(for: name, stack: stack) {
            appendError(parentMessage, offset: offset, length: length, locations: locations, messages: &messages)
        }

        if selfClosing && !HTMLVocabulary.voidElements.contains(name) {
            appendError("Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.", offset: offset, length: length, locations: locations, messages: &messages)
        }
    }

    private func contentModelMessage(for child: String, stack: [OpenElement]) -> String? {
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

    private func applyImplicitClosures(beforeStarting name: String, stack: inout [OpenElement]) {
        if name == "li" {
            closeLast("li", in: &stack)
        } else if name == "dt" || name == "dd" {
            closeLast("dt", in: &stack)
            closeLast("dd", in: &stack)
        } else if name == "p", stack.last?.name == "p" {
            _ = stack.popLast()
        } else if HTMLVocabulary.flowButNotPhrasing.contains(name), stack.last?.name == "p" {
            _ = stack.popLast()
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

