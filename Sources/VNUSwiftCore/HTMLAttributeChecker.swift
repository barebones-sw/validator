import Foundation

struct HTMLURLAttributeChecker {
    private struct URLAttributeRule {
        var attributeName: String
        var requiresAbsoluteURL: Bool
        var requiresNonEmptyValue: Bool
    }

    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []

        for event in document.events {
            guard case let .startElement(element) = event else { continue }
            for rule in rules(for: element) {
                guard let value = element.attributeValue(rule.attributeName) else { continue }
                appendURLMessages(value: value, rule: rule, element: element, locations: locations, messages: &messages)
            }
        }

        return messages
    }

    private func rules(for element: HTMLStartElement) -> [URLAttributeRule] {
        var rules: [URLAttributeRule] = []

        switch element.name {
        case "a", "area", "base":
            rules.append(URLAttributeRule(attributeName: "href", requiresAbsoluteURL: false, requiresNonEmptyValue: false))
        case "link":
            rules.append(URLAttributeRule(attributeName: "href", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
        case "audio", "embed", "iframe", "img", "script", "source", "track", "video":
            rules.append(URLAttributeRule(attributeName: "src", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
        case "object":
            rules.append(URLAttributeRule(attributeName: "data", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
        case "form":
            rules.append(URLAttributeRule(attributeName: "action", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
        case "button":
            rules.append(URLAttributeRule(attributeName: "formaction", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
        case "blockquote", "del", "ins", "q":
            rules.append(URLAttributeRule(attributeName: "cite", requiresAbsoluteURL: false, requiresNonEmptyValue: false))
        default:
            break
        }

        if element.name == "input" {
            let type = element.attributeValue("type")?.lowercased()
            if type == "image" {
                rules.append(URLAttributeRule(attributeName: "src", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
            }
            if type == "image" || type == "submit" {
                rules.append(URLAttributeRule(attributeName: "formaction", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
            }
            if type == "url" {
                rules.append(URLAttributeRule(attributeName: "value", requiresAbsoluteURL: true, requiresNonEmptyValue: false))
            }
        }

        if element.name == "video" {
            rules.append(URLAttributeRule(attributeName: "poster", requiresAbsoluteURL: false, requiresNonEmptyValue: true))
        }

        if element.hasAttribute("itemid") {
            rules.append(URLAttributeRule(attributeName: "itemid", requiresAbsoluteURL: false, requiresNonEmptyValue: false))
        }
        if element.hasAttribute("itemtype") {
            rules.append(URLAttributeRule(attributeName: "itemtype", requiresAbsoluteURL: true, requiresNonEmptyValue: true))
        }

        return rules
    }

    private func appendURLMessages(
        value: String,
        rule: URLAttributeRule,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let codePoint = forbiddenCodePoint(in: value) {
            messages.append(.error(
                "Forbidden code point \(formatCodePoint(codePoint)).",
                location: locations.location(offset: element.range.offset, length: element.range.length),
                extract: locations.extract(offset: element.range.offset, length: element.range.length)
            ))
            return
        }

        if !isAcceptableURLValue(value, rule: rule) {
            let displayValue = value
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            messages.append(.error(
                "Bad value \u{201c}\(displayValue)\u{201d} for attribute \u{201c}\(rule.attributeName)\u{201d} on element \u{201c}\(element.name)\u{201d}.",
                location: locations.location(offset: element.range.offset, length: element.range.length),
                extract: locations.extract(offset: element.range.offset, length: element.range.length)
            ))
        }
    }

    private func isAcceptableURLValue(_ value: String, rule: URLAttributeRule) -> Bool {
        if value.isEmpty {
            return !rule.requiresNonEmptyValue && !rule.requiresAbsoluteURL
        }
        if rule.requiresNonEmptyValue && value.unicodeScalars.allSatisfy(isASCIIWhitespace) {
            return false
        }
        if value.unicodeScalars.contains(where: isASCIIWhitespace) {
            return false
        }
        if value.contains("\\") || value.contains("|") || value.contains("％") {
            return false
        }
        if hasMalformedPercentEscape(value) {
            return false
        }
        if value.filter({ $0 == "#" }).count > 1 {
            return false
        }

        let lowercasedValue = value.lowercased()
        if lowercasedValue.contains("%ef%bc%85") || lowercasedValue.contains("%ef%b7%90") {
            return false
        }

        guard let scheme = scheme(in: value) else {
            guard !rule.requiresAbsoluteURL else { return false }
            return !containsSquareBracket(value)
        }

        if scheme == "data" {
            return !lowercasedValue.hasPrefix("data:/") && !value.contains("#")
        }
        if scheme == "file" {
            return lowercasedValue.hasPrefix("file://")
        }
        if Self.specialSchemes.contains(scheme) {
            guard lowercasedValue.hasPrefix("\(scheme)://") else { return false }
            return hasValidSpecialAuthority(in: value, scheme: scheme)
        }
        if containsSquareBracket(value) {
            return false
        }

        return true
    }

    private func hasValidSpecialAuthority(in value: String, scheme: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else { return false }
        let authorityStart = value.index(colon, offsetBy: 3, limitedBy: value.endIndex) ?? value.endIndex
        let authorityEnd = value[authorityStart...].firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? value.endIndex
        let authority = String(value[authorityStart..<authorityEnd])
        guard !authority.isEmpty, !authority.contains("@") else { return false }

        if authority.first == "[" {
            guard let closeBracket = authority.firstIndex(of: "]") else { return false }
            let hostStart = authority.index(after: authority.startIndex)
            let host = authority[hostStart..<closeBracket]
            guard host.contains(":") else { return false }

            let restStart = authority.index(after: closeBracket)
            let rest = authority[restStart...]
            if rest.isEmpty {
                return true
            }
            guard rest.first == ":" else { return false }
            return isValidPort(String(rest.dropFirst()))
        }

        guard !containsSquareBracket(authority) else { return false }
        let colons = authority.filter { $0 == ":" }.count
        guard colons <= 1 else { return false }
        guard colons == 1 else { return true }

        let pieces = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty else { return false }
        return isValidPort(String(pieces[1]))
    }

    private func isValidPort(_ port: String) -> Bool {
        guard port.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) else {
            return false
        }
        let significantDigits = port.drop { $0 == "0" }
        guard !significantDigits.isEmpty else { return true }
        guard significantDigits.count <= 5 else { return false }
        return (Int(significantDigits) ?? Int.max) <= 65_535
    }

    private func scheme(in value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = value[..<colon]
        guard let first = candidate.unicodeScalars.first, isASCIILetter(first) else { return nil }
        guard candidate.unicodeScalars.allSatisfy({ isASCIILetter($0) || isASCIIDigit($0) || $0.value == 43 || $0.value == 45 || $0.value == 46 }) else {
            return nil
        }
        return candidate.lowercased()
    }

    private func hasMalformedPercentEscape(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index].value == 37 {
                guard index + 2 < scalars.count,
                      isASCIIHexDigit(scalars[index + 1]),
                      isASCIIHexDigit(scalars[index + 2]) else {
                    return true
                }
                index += 3
            } else {
                index += 1
            }
        }
        return false
    }

    private func forbiddenCodePoint(in value: String) -> UInt32? {
        value.unicodeScalars.first { scalar in
            scalar.value == 0x0091 || scalar.value == 0xFDD0
        }?.value
    }

    private func formatCodePoint(_ value: UInt32) -> String {
        "U+" + String(format: "%04x", value)
    }

    private func containsSquareBracket(_ value: some StringProtocol) -> Bool {
        value.contains("[") || value.contains("]")
    }

    private func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    private func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar)
            || (scalar.value >= 65 && scalar.value <= 70)
            || (scalar.value >= 97 && scalar.value <= 102)
    }

    private static let specialSchemes: Set<String> = ["ftp", "http", "https", "ws", "wss"]
}

struct HTMLMicrodataAttributeChecker {
    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []

        for event in document.events {
            guard case let .startElement(element) = event else { continue }
            appendMicrodataMessages(for: element, locations: locations, messages: &messages)
        }

        return messages
    }

    private func appendMicrodataMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.hasAttribute("itemtype"), !element.hasAttribute("itemscope") {
            appendMessage(
                "The \u{201c}itemtype\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("itemid"),
           !(element.hasAttribute("itemscope") && element.hasAttribute("itemtype")) {
            appendMessage(
                "The \u{201c}itemid\u{201d} attribute must not be specified on elements that do not have both an \u{201c}itemscope\u{201d} attribute and an \u{201c}itemtype\u{201d} attribute specified.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("itemref"), !element.hasAttribute("itemscope") {
            appendMessage(
                "The \u{201c}itemref\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendMessage(
        _ message: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            message,
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }
}

struct HTMLGeneralAttributeChecker {
    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []
        var stack: [String] = []
        var pictureStack: [PictureState] = []
        var mediaStack: [MediaState] = []
        var scriptContent: ScriptContentState?
        var titleCapture: TitleCapture?
        var sawTitle = false
        let idElementNames = idElementNames(in: document)

        for event in document.events {
            switch event {
            case let .startElement(element):
                let parent = stack.last
                appendDisallowedAttributeMessages(for: element, parent: parent, locations: locations, messages: &messages)
                appendLanguageAttributeMessages(for: element, locations: locations, messages: &messages)
                appendDateTimeAttributeMessages(for: element, locations: locations, messages: &messages)
                appendInputAttributeMessages(for: element, idElementNames: idElementNames, locations: locations, messages: &messages)
                appendEmbeddedContentMessages(for: element, locations: locations, messages: &messages)
                appendMeterMessages(for: element, locations: locations, messages: &messages)
                appendProgressMessages(for: element, locations: locations, messages: &messages)
                appendTextareaMessages(for: element, locations: locations, messages: &messages)
                appendTrackMessages(for: element, mediaStack: &mediaStack, locations: locations, messages: &messages)
                appendScriptAttributeMessages(for: element, locations: locations, messages: &messages)
                appendResponsiveImageMessages(for: element, stack: stack, locations: locations, messages: &messages)
                if parent == "picture", let pictureIndex = pictureStack.indices.last {
                    appendPictureChildMessages(for: element, state: &pictureStack[pictureIndex], locations: locations, messages: &messages)
                }
                if element.name == "audio" || element.name == "video" {
                    mediaStack.append(MediaState(element: element))
                }
                if element.name == "script" {
                    scriptContent = scriptContentState(for: element)
                }
                if element.name == "title" {
                    sawTitle = true
                    titleCapture = TitleCapture(element: element)
                }
                if element.name == "picture" {
                    pictureStack.append(PictureState(element: element))
                }
                stack.append(element.name)
            case let .endElement(name, _, _):
                if name == "script", let content = scriptContent {
                    appendScriptContentMessages(content, locations: locations, messages: &messages)
                    scriptContent = nil
                }
                if name == "picture", let state = pictureStack.popLast() {
                    appendPictureMessages(state, locations: locations, messages: &messages)
                }
                if name == "audio" || name == "video", !mediaStack.isEmpty {
                    _ = mediaStack.popLast()
                }
                if name == "title", let capture = titleCapture {
                    appendTitleMessages(capture, locations: locations, messages: &messages)
                    titleCapture = nil
                }
                if let index = stack.lastIndex(of: name) {
                    stack.removeSubrange(index...)
                }
            case let .characters(content, range):
                if scriptContent != nil {
                    scriptContent?.content += content
                }
                if stack.last == "picture", pictureStack.indices.last != nil, !content.unicodeScalars.allSatisfy(isASCIIWhitespace) {
                    appendMessage(
                        "Text not allowed in \u{201c}picture\u{201d} in this context.",
                        range: range,
                        locations: locations,
                        messages: &messages
                    )
                }
                if titleCapture != nil {
                    titleCapture?.text += content
                }
            default:
                continue
            }
        }

        if !sawTitle {
            messages.append(.error("Element \u{201c}head\u{201d} is missing a required instance of child element \u{201c}title\u{201d}."))
        }
        return messages
    }

    private func idElementNames(in document: HTMLParsedDocument) -> [String: String] {
        var result: [String: String] = [:]
        for event in document.events {
            guard case let .startElement(element) = event,
                  let id = element.attributeValue("id"),
                  !id.isEmpty,
                  result[id] == nil else {
                continue
            }
            result[id] = element.name
        }
        return result
    }

    private struct PictureState {
        var element: HTMLStartElement
        var sourcesMissingSizes: [HTMLStartElement] = []
        var sourcesWithAutoSizes: [HTMLStartElement] = []
        var sourceSelectionCandidates: [HTMLStartElement] = []
        var permitsSourceWidthWithoutSizes = false
        var sawImage = false
    }

    private struct MediaState {
        var element: HTMLStartElement
        var sawDefaultTrack = false
    }

    private struct TitleCapture {
        var element: HTMLStartElement
        var text = ""
    }

    private func appendPictureChildMessages(
        for element: HTMLStartElement,
        state: inout PictureState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let hasSrcset = element.hasAttribute("srcset")
        if hasSrcset, element.name == "source" || element.name == "img" {
            appendAlwaysMatchingSourceMessages(for: state.sourceSelectionCandidates, locations: locations, messages: &messages)
            state.sourceSelectionCandidates.removeAll()
        }

        switch element.name {
        case "script", "template":
            return
        case "source":
            if state.sawImage {
                appendElementNotAllowedInPictureMessage(for: element, locations: locations, messages: &messages)
                return
            }
            guard let srcset = element.attributeValue("srcset") else { return }
            if !element.hasAttribute("sizes"), hasWidthDescriptor(in: srcset) {
                state.sourcesMissingSizes.append(element)
            }
            if element.attributeValue("sizes")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("auto") == true {
                state.sourcesWithAutoSizes.append(element)
            }
            state.sourceSelectionCandidates.append(element)
        case "img":
            if state.sawImage {
                appendElementNotAllowedInPictureMessage(for: element, locations: locations, messages: &messages)
                return
            }
            state.sawImage = true
            if element.attributeValue("loading")?.lowercased() == "lazy" {
                state.permitsSourceWidthWithoutSizes = true
            }
        default:
            appendElementNotAllowedInPictureMessage(for: element, locations: locations, messages: &messages)
        }
    }

    private func appendPictureMessages(
        _ state: PictureState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if !state.sawImage {
            appendMessage(
                "Element \u{201c}picture\u{201d} is missing a required instance of child element \u{201c}img\u{201d}.",
                for: state.element,
                locations: locations,
                messages: &messages
            )
        }

        if !state.permitsSourceWidthWithoutSizes {
            for element in state.sourcesMissingSizes {
                appendMessage(
                    "When the \u{201c}srcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}sizes\u{201d} attribute must also be specified.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
            for element in state.sourcesWithAutoSizes {
                appendMessage(
                    "The \u{201c}sizes\u{201d} attribute value starting with \u{201c}auto\u{201d} is only valid for lazy-loaded images. The \u{201c}img\u{201d} element must have a \u{201c}loading\u{201d} attribute set to \u{201c}lazy\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        appendAlwaysMatchingSourceMessages(for: state.sourceSelectionCandidates, locations: locations, messages: &messages)
    }

    private func appendAlwaysMatchingSourceMessages(
        for sources: [HTMLStartElement],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        for element in sources {
            if element.hasAttribute("media") {
                let media = element.attributeValue("media") ?? ""
                let trimmed = media.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    appendMessage("Value of \u{201c}media\u{201d} attribute here must not be empty.", for: element, locations: locations, messages: &messages)
                } else if trimmed.lowercased() == "all" {
                    appendMessage("Value of \u{201c}media\u{201d} attribute here must not be \u{201c}all\u{201d}.", for: element, locations: locations, messages: &messages)
                }
            } else if !element.hasAttribute("type") {
                appendMessage(
                    "A \u{201c}source\u{201d} element that has a following sibling \u{201c}source\u{201d} element or \u{201c}img\u{201d} element with a \u{201c}srcset\u{201d} attribute must have a \u{201c}media\u{201d} attribute and/or \u{201c}type\u{201d} attribute.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }
    }

    private func appendElementNotAllowedInPictureMessage(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        appendMessage(
            "Element \u{201c}\(element.name)\u{201d} not allowed as child of \u{201c}picture\u{201d} in this context.",
            for: element,
            locations: locations,
            messages: &messages
        )
    }

    private func appendDisallowedAttributeMessages(
        for element: HTMLStartElement,
        parent: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let disallowed: Set<String>
        if element.name == "picture" {
            disallowed = Self.pictureDisallowedAttributes
        } else if element.name == "source", parent == "picture" {
            disallowed = Self.pictureSourceDisallowedAttributes
        } else if element.name == "img" {
            disallowed = element.hasAttribute("type") ? ["type"] : []
        } else if Self.srcsetDisallowedElements.contains(element.name), element.hasAttribute("srcset") {
            disallowed = ["srcset"]
        } else {
            disallowed = []
        }

        for attribute in element.attributes where disallowed.contains(attribute.name) {
            appendMessage(
                "Attribute \u{201c}\(attribute.name)\u{201d} not allowed on element \u{201c}\(element.name)\u{201d} at this point.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendLanguageAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let hreflang = element.attributeValue("hreflang"),
              !isPlausibleLanguageTag(hreflang) else {
            return
        }

        messages.append(.error(
            "Bad value \u{201c}\(hreflang)\u{201d} for attribute \u{201c}hreflang\u{201d} on element \u{201c}\(element.name)\u{201d}.",
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendAttributeNotAllowed(
        _ attribute: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        appendMessage(
            "Attribute \u{201c}\(attribute)\u{201d} not allowed on element \u{201c}\(element.name)\u{201d} at this point.",
            for: element,
            locations: locations,
            messages: &messages
        )
    }

    private func appendBadAttributeValue(
        _ value: String,
        attribute: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        appendMessage(
            "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute)\u{201d} on element \u{201c}\(element.name)\u{201d}.",
            for: element,
            locations: locations,
            messages: &messages
        )
    }

    private func appendDateTimeAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let value = element.attributeValue("datetime") else { return }

        let valid: Bool
        switch element.name {
        case "del", "ins":
            valid = isValidDateString(value) || isValidGlobalDateAndTimeString(value, strictTimeZone: true)
        case "time":
            valid = isValidTimeDateTimeString(value)
        default:
            return
        }

        if !valid {
            appendMessage(
                "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}datetime\u{201d} on element \u{201c}\(element.name)\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendInputAttributeMessages(
        for element: HTMLStartElement,
        idElementNames: [String: String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.name == "button" {
            appendButtonReferenceMessages(for: element, idElementNames: idElementNames, locations: locations, messages: &messages)
            return
        }
        guard element.name == "input" else { return }

        let type = inputType(for: element)
        appendInputAutocompleteMessages(for: element, type: type, locations: locations, messages: &messages)
        appendInputTypeAttributeMessages(for: element, type: type, locations: locations, messages: &messages)
        appendInputValueMessages(for: element, type: type, locations: locations, messages: &messages)
        appendInputReferenceMessages(for: element, type: type, idElementNames: idElementNames, locations: locations, messages: &messages)

        if element.attributeValue("name")?.lowercased() == "isindex" {
            appendMessage(
                "The value \u{201c}isindex\u{201d} for the \u{201c}name\u{201d} attribute of the \u{201c}input\u{201d} element is not allowed.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if type == "button", element.attributeValue("value")?.isEmpty != false {
            appendMessage(
                "Element \u{201c}input\u{201d} with attribute \u{201c}type\u{201d} whose value is \u{201c}button\u{201d} must have non-empty attribute \u{201c}value\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if type == "hidden", element.attributes.contains(where: { $0.name.hasPrefix("aria-") }) {
            appendMessage(
                "An \u{201c}input\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}hidden\u{201d} must not have any \u{201c}aria-*\u{201d} attributes.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if type == "checkbox",
           element.attributeValue("role")?.lowercased() == "button",
           !element.hasAttribute("aria-pressed") {
            appendMessage(
                "An \u{201c}input\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}checkbox\u{201d} and with a \u{201c}role\u{201d} attribute whose value is \u{201c}button\u{201d} must have an \u{201c}aria-pressed\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendInputAutocompleteMessages(
        for element: HTMLStartElement,
        type: String,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.hasAttribute("autocomplete") else { return }
        let value = element.attributeValue("autocomplete") ?? ""
        let lowercased = value.lowercased()
        if type == "hidden", lowercased == "on" || lowercased == "off" {
            appendMessage(
                "An \u{201c}input\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}hidden\u{201d} must not have an \u{201c}autocomplete\u{201d} attribute whose value is \u{201c}on\u{201d} or \u{201c}off\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        } else if !isValidAutocompleteValue(value) {
            appendBadAttributeValue(value, attribute: "autocomplete", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendInputTypeAttributeMessages(
        for element: HTMLStartElement,
        type: String,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.hasAttribute("readonly") {
            if type == "hidden" {
                appendAttributeNotAllowed("readonly", for: element, locations: locations, messages: &messages)
            } else if !Self.inputReadonlyTypes.contains(type) {
                appendMessage(
                    "Attribute \u{201c}readonly\u{201d} is only allowed when the input type is \u{201c}date\u{201d}, \u{201c}datetime-local\u{201d}, \u{201c}email\u{201d}, \u{201c}month\u{201d}, \u{201c}number\u{201d}, \u{201c}password\u{201d}, \u{201c}search\u{201d}, \u{201c}tel\u{201d}, \u{201c}text\u{201d}, \u{201c}time\u{201d}, \u{201c}url\u{201d}, or \u{201c}week\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if element.hasAttribute("required") {
            if type == "hidden" {
                appendAttributeNotAllowed("required", for: element, locations: locations, messages: &messages)
            } else if !Self.inputRequiredTypes.contains(type) {
                appendMessage(
                    "Attribute \u{201c}required\u{201d} is only allowed when the input type is \u{201c}checkbox\u{201d}, \u{201c}date\u{201d}, \u{201c}datetime-local\u{201d}, \u{201c}email\u{201d}, \u{201c}file\u{201d}, \u{201c}month\u{201d}, \u{201c}number\u{201d}, \u{201c}password\u{201d}, \u{201c}radio\u{201d}, \u{201c}search\u{201d}, \u{201c}tel\u{201d}, \u{201c}text\u{201d}, \u{201c}time\u{201d}, \u{201c}url\u{201d}, or \u{201c}week\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if element.hasAttribute("pattern") {
            if type == "hidden" {
                appendAttributeNotAllowed("pattern", for: element, locations: locations, messages: &messages)
            } else if !Self.inputPatternTypes.contains(type) {
                appendMessage(
                    "Attribute \u{201c}pattern\u{201d} is only allowed when the input type is \u{201c}email\u{201d}, \u{201c}password\u{201d}, \u{201c}search\u{201d}, \u{201c}tel\u{201d}, \u{201c}text\u{201d}, or \u{201c}url\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if element.hasAttribute("list"), !Self.inputListTypes.contains(type) {
            appendMessage(
                "Attribute \u{201c}list\u{201d} is only allowed when the input type is \u{201c}color\u{201d}, \u{201c}date\u{201d}, \u{201c}datetime-local\u{201d}, \u{201c}email\u{201d}, \u{201c}month\u{201d}, \u{201c}number\u{201d}, \u{201c}range\u{201d}, \u{201c}search\u{201d}, \u{201c}tel\u{201d}, \u{201c}text\u{201d}, \u{201c}time\u{201d}, \u{201c}url\u{201d}, or \u{201c}week\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("maxlength"), !Self.inputTextEntryTypes.contains(type) {
            appendMessage(
                "Attribute \u{201c}maxlength\u{201d} is only allowed when the input type is \u{201c}email\u{201d}, \u{201c}password\u{201d}, \u{201c}search\u{201d}, \u{201c}tel\u{201d}, \u{201c}text\u{201d}, or \u{201c}url\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        for attribute in ["accept"] where element.hasAttribute(attribute) && type != "file" {
            appendAttributeNotAllowed(attribute, for: element, locations: locations, messages: &messages)
        }
        for attribute in ["alt", "height", "src", "width"] where element.hasAttribute(attribute) && type != "image" {
            appendAttributeNotAllowed(attribute, for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("checked"), type != "checkbox" && type != "radio" {
            appendAttributeNotAllowed("checked", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("dirname"), type != "text" && type != "search" {
            appendAttributeNotAllowed("dirname", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("multiple"), type != "email" && type != "file" {
            appendAttributeNotAllowed("multiple", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("placeholder"), type == "hidden" {
            appendAttributeNotAllowed("placeholder", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("size"), !Self.inputTextEntryTypes.contains(type) {
            appendAttributeNotAllowed("size", for: element, locations: locations, messages: &messages)
        }
        for attribute in ["max", "min"] where element.hasAttribute(attribute) && !Self.inputMinMaxTypes.contains(type) {
            appendAttributeNotAllowed(attribute, for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("step"), !Self.inputStepTypes.contains(type) {
            appendAttributeNotAllowed("step", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendInputValueMessages(
        for element: HTMLStartElement,
        type: String,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if type == "color", let value = element.attributeValue("value"), !isValidColorInputValue(value) {
            appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
        }
        if type == "number", let value = element.attributeValue("value"), !value.isEmpty, !isValidFloatingPointNumber(value) {
            appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
        }
        if type == "range", let min = element.attributeValue("min"), !min.isEmpty, !isValidFloatingPointNumber(min) {
            appendBadAttributeValue(min, attribute: "min", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("size"), Self.inputTextEntryTypes.contains(type) {
            let size = element.attributeValue("size") ?? ""
            guard let value = Int(size), value > 0, String(value) == size else {
                appendBadAttributeValue(size, attribute: "size", for: element, locations: locations, messages: &messages)
                return
            }
        }
    }

    private func appendInputReferenceMessages(
        for element: HTMLStartElement,
        type: String,
        idElementNames: [String: String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let form = element.attributeValue("form"), idElementNames[form] != "form" {
            appendMessage("The \u{201c}form\u{201d} attribute must refer to a form element.", for: element, locations: locations, messages: &messages)
        }
        if Self.inputListTypes.contains(type),
           let list = element.attributeValue("list"),
           idElementNames[list] != "datalist" {
            appendMessage("The \u{201c}list\u{201d} attribute of the \u{201c}input\u{201d} element must refer to a \u{201c}datalist\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendButtonReferenceMessages(
        for element: HTMLStartElement,
        idElementNames: [String: String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let commandFor = element.attributeValue("commandfor"),
              idElementNames[commandFor] == nil else {
            return
        }
        appendMessage(
            "The value of the \u{201c}commandfor\u{201d} attribute of the \u{201c}button\u{201d} element must be the ID of an element in the same tree as the \u{201c}button\u{201d} with the \u{201c}commandfor\u{201d} attribute.",
            for: element,
            locations: locations,
            messages: &messages
        )
    }

    private func appendEmbeddedContentMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "embed" else { return }

        for attribute in ["height", "width"] {
            if let value = element.attributeValue(attribute), !isValidNonNegativeInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
            }
        }
        if let type = element.attributeValue("type"), !isValidMIMEType(type) {
            appendBadAttributeValue(type, attribute: "type", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendMeterMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "meter" else { return }

        if element.hasAttribute("aria-valuemax") {
            appendWarningMessage("The \u{201c}aria-valuemax\u{201d} attribute should not be used on a \u{201c}meter\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        guard let value = element.attributeValue("value") else {
            appendMessage("Element \u{201c}meter\u{201d} is missing required attribute \u{201c}value\u{201d}.", for: element, locations: locations, messages: &messages)
            return
        }
        guard let meterValue = validFloatingPointAttribute("value", value, for: element, locations: locations, messages: &messages) else {
            return
        }
        let minValue = numberAttribute("min", for: element, defaultValue: 0, locations: locations, messages: &messages)
        let maxValue = numberAttribute("max", for: element, defaultValue: 1, locations: locations, messages: &messages)
        guard let minValue, let maxValue else { return }
        let lowValue = numberAttribute("low", for: element, defaultValue: minValue, locations: locations, messages: &messages)
        let highValue = numberAttribute("high", for: element, defaultValue: maxValue, locations: locations, messages: &messages)
        let optimumValue = optionalNumberAttribute("optimum", for: element, locations: locations, messages: &messages)

        if !element.hasAttribute("min"), meterValue < 0 {
            appendMessage("The value of the \u{201c}value\u{201d} attribute must be greater than or equal to zero when the \u{201c}min\u{201d} attribute is absent.", for: element, locations: locations, messages: &messages)
        }
        if !element.hasAttribute("max"), meterValue > 1 {
            appendMessage("The value of the \u{201c}value\u{201d} attribute must be less than or equal to one when the \u{201c}max\u{201d} attribute is absent.", for: element, locations: locations, messages: &messages)
        }
        if minValue > meterValue {
            appendMessage("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}value\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
        if meterValue > maxValue {
            appendMessage("The value of the \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
        if let lowValue {
            if minValue > lowValue {
                appendMessage("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}low\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            if let highValue, lowValue > highValue {
                appendMessage("The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            if lowValue > maxValue {
                appendMessage("The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
        }
        if let highValue {
            if minValue > highValue {
                appendMessage("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            if highValue > maxValue {
                appendMessage("The value of the \u{201c}high\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
        }
        if let optimumValue {
            if minValue > optimumValue {
                appendMessage("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}optimum\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            if optimumValue > maxValue {
                appendMessage("The value of the \u{201c}optimum\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendProgressMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "progress" else { return }

        if element.hasAttribute("aria-valuemax") {
            appendWarningMessage("The \u{201c}aria-valuemax\u{201d} attribute should not be used on a \u{201c}progress\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        let maxValue = numberAttribute("max", for: element, defaultValue: 1, locations: locations, messages: &messages)
        if let max = maxValue, max <= 0 {
            appendBadAttributeValue(element.attributeValue("max") ?? "", attribute: "max", for: element, locations: locations, messages: &messages)
        }
        guard let value = element.attributeValue("value"),
              let progressValue = validFloatingPointAttribute("value", value, for: element, locations: locations, messages: &messages) else {
            return
        }
        if progressValue < 0 {
            appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
        }
        if !element.hasAttribute("max"), progressValue > 1 {
            appendMessage("The value of the  \u{201c}value\u{201d} attribute must be less than or equal to one when the \u{201c}max\u{201d} attribute is absent.", for: element, locations: locations, messages: &messages)
        } else if let max = maxValue, progressValue > max {
            appendMessage("The value of the  \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendTextareaMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "textarea" else { return }

        if let autocomplete = element.attributeValue("autocomplete"), !isValidAutocompleteValue(autocomplete) {
            appendBadAttributeValue(autocomplete, attribute: "autocomplete", for: element, locations: locations, messages: &messages)
        }
        for attribute in ["cols", "rows"] {
            if let value = element.attributeValue(attribute), !isValidPositiveInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendTrackMessages(
        for element: HTMLStartElement,
        mediaStack: inout [MediaState],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "track" else { return }

        if element.attributeValue("label") == "" {
            appendMessage("Attribute \u{201c}label\u{201d} for element \u{201c}track\u{201d} must have non-empty value.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("default"), let mediaIndex = mediaStack.indices.last {
            if mediaStack[mediaIndex].sawDefaultTrack {
                appendMessage("The \u{201c}default\u{201d} attribute must not occur on more than one \u{201c}track\u{201d} element within the same \u{201c}audio\u{201d} or \u{201c}video\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            mediaStack[mediaIndex].sawDefaultTrack = true
        }
    }

    private func appendTitleMessages(
        _ capture: TitleCapture,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard capture.text.isEmpty else { return }
        appendMessage("Element \u{201c}title\u{201d} must not be empty.", for: capture.element, locations: locations, messages: &messages)
    }

    private func inputType(for element: HTMLStartElement) -> String {
        let type = element.attributeValue("type")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return Self.inputTypes.contains(type) ? type : "text"
    }

    private func isValidAutocompleteValue(_ value: String) -> Bool {
        let tokens = value.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return false }
        if tokens.count == 1, tokens[0] == "on" || tokens[0] == "off" {
            return true
        }

        var remaining = tokens
        if remaining.last == "webauthn" {
            guard remaining.count > 1 else { return false }
            remaining.removeLast()
        } else if remaining.contains("webauthn") {
            return false
        }
        if remaining.first?.hasPrefix("section-") == true {
            guard remaining[0].count > "section-".count else { return false }
            remaining.removeFirst()
        }
        if let first = remaining.first, first == "billing" || first == "shipping" {
            remaining.removeFirst()
        }
        if let first = remaining.first, Self.autocompleteContactTokens.contains(first) {
            remaining.removeFirst()
            guard remaining.count == 1, Self.autocompleteContactFields.contains(remaining[0]) else {
                return false
            }
            return true
        }
        return remaining.count == 1 && Self.autocompleteFields.contains(remaining[0])
    }

    private func isValidColorInputValue(_ value: String) -> Bool {
        guard value.utf8.count == 7, value.first == "#" else { return false }
        return value.dropFirst().unicodeScalars.allSatisfy(isASCIIHexDigit)
    }

    private func isValidFloatingPointNumber(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: isASCIIWhitespace),
              let parsed = Double(value),
              parsed.isFinite else {
            return false
        }
        return true
    }

    private func validFloatingPointAttribute(
        _ attribute: String,
        _ value: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Double? {
        guard isValidFloatingPointNumber(value), let parsed = Double(value) else {
            appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
            return nil
        }
        return parsed
    }

    private func optionalNumberAttribute(
        _ attribute: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Double? {
        guard let value = element.attributeValue(attribute) else { return nil }
        return validFloatingPointAttribute(attribute, value, for: element, locations: locations, messages: &messages)
    }

    private func numberAttribute(
        _ attribute: String,
        for element: HTMLStartElement,
        defaultValue: Double,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Double? {
        guard let value = element.attributeValue(attribute) else { return defaultValue }
        return validFloatingPointAttribute(attribute, value, for: element, locations: locations, messages: &messages)
    }

    private func isValidNonNegativeInteger(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy(isASCIIDigit) else { return false }
        return Int(value) != nil
    }

    private func isValidPositiveInteger(_ value: String) -> Bool {
        guard let parsed = Int(value), String(parsed) == value else { return false }
        return parsed > 0
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

    private enum ScriptKind {
        case classic
        case module
        case importmap
        case speculationRules
        case dataBlock
    }

    private struct ScriptContentState {
        var element: HTMLStartElement
        var kind: ScriptKind
        var content = ""
    }

    private func scriptContentState(for element: HTMLStartElement) -> ScriptContentState? {
        guard !element.hasAttribute("src") else { return nil }
        let kind = scriptKind(for: element)
        guard kind == .importmap || kind == .speculationRules else { return nil }
        return ScriptContentState(element: element, kind: kind)
    }

    private func appendScriptContentMessages(
        _ state: ScriptContentState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        switch state.kind {
        case .importmap:
            appendImportMapMessages(content: state.content, element: state.element, locations: locations, messages: &messages)
        case .speculationRules:
            appendSpeculationRulesMessages(content: state.content, element: state.element, locations: locations, messages: &messages)
        default:
            break
        }
    }

    private func appendScriptAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "script" else { return }

        let kind = scriptKind(for: element)
        let inline = !element.hasAttribute("src")

        if let language = element.attributeValue("language") {
            appendWarningMessage(
                "The \u{201c}language\u{201d} attribute on the \u{201c}script\u{201d} element is obsolete. Use the \u{201c}type\u{201d} attribute instead.",
                for: element,
                locations: locations,
                messages: &messages
            )

            if language.lowercased() == "javascript",
               let type = element.attributeValue("type"),
               type.lowercased() != "text/javascript" {
                appendMessage(
                    "A \u{201c}script\u{201d} element with the \u{201c}language=\"JavaScript\"\u{201d} attribute set must not have a \u{201c}type\u{201d} attribute whose value is not \u{201c}text/javascript\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if element.attributeValue("type")?.lowercased() == "text/javascript" {
            appendWarningMessage(
                "The \u{201c}type\u{201d} attribute is unnecessary for JavaScript resources.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("charset") {
            if inline {
                appendMessage(
                    "Element \u{201c}script\u{201d} must not have attribute \u{201c}charset\u{201d} unless attribute \u{201c}src\u{201d} is also specified.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else if element.attributeValue("charset")?.lowercased() != "utf-8" {
                appendMessage(
                    "The only allowed value for the \u{201c}charset\u{201d} attribute for the \u{201c}script\u{201d} element is \u{201c}utf-8\u{201d}. (But the attribute is not needed and should be omitted altogether.)",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        switch kind {
        case .classic:
            appendInlineClassicScriptMessages(for: element, inline: inline, locations: locations, messages: &messages)
        case .module:
            appendModuleScriptMessages(for: element, inline: inline, locations: locations, messages: &messages)
        case .importmap:
            appendTypedScriptMessages(
                for: element,
                typeName: "importmap",
                invalidAttributes: Self.importMapInvalidAttributes,
                srcMessage: "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must not have a \u{201c}src\u{201d} attribute.",
                locations: locations,
                messages: &messages
            )
        case .speculationRules:
            appendTypedScriptMessages(
                for: element,
                typeName: "speculationrules",
                invalidAttributes: Self.speculationRulesInvalidAttributes,
                srcMessage: "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must not have a \u{201c}src\u{201d} attribute.",
                locations: locations,
                messages: &messages
            )
        case .dataBlock:
            appendDataBlockScriptMessages(for: element, locations: locations, messages: &messages)
        }
    }

    private func scriptKind(for element: HTMLStartElement) -> ScriptKind {
        guard let rawType = element.attributeValue("type") else { return .classic }
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type.isEmpty || Self.javaScriptMIMETypes.contains(type) {
            return .classic
        }
        if type == "module" {
            return .module
        }
        if type == "importmap" {
            return .importmap
        }
        if type == "speculationrules" {
            return .speculationRules
        }
        return .dataBlock
    }

    private func appendInlineClassicScriptMessages(
        for element: HTMLStartElement,
        inline: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard inline else { return }

        if element.hasAttribute("async") {
            appendMessage(
                "An inline classic \u{201c}script\u{201d} element (i.e., a \u{201c}script\u{201d} element without a \u{201c}src\u{201d} attribute and with a \u{201c}type\u{201d} attribute that is either unspecified, empty, or a JavaScript MIME type) must not have an \u{201c}async\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("blocking") {
            appendMessage(
                "An inline classic \u{201c}script\u{201d} element (i.e., a \u{201c}script\u{201d} element without a \u{201c}src\u{201d} attribute and with a \u{201c}type\u{201d} attribute that is either unspecified, empty, or a JavaScript MIME type) must not have a \u{201c}blocking\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("defer") {
            appendMessage(
                "An inline \u{201c}script\u{201d} element (i.e., a \u{201c}script\u{201d} element without a \u{201c}src\u{201d} attribute and with a \u{201c}type\u{201d} attribute that is either unspecified, empty, or a JavaScript MIME type) must not have a \u{201c}defer\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("fetchpriority") {
            appendMessage(
                "An inline classic \u{201c}script\u{201d} element (i.e., a \u{201c}script\u{201d} element without a \u{201c}src\u{201d} attribute and with a \u{201c}type\u{201d} attribute that is either unspecified, empty, or a JavaScript MIME type) must not have a \u{201c}fetchpriority\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("integrity") {
            appendMessage(
                "An inline classic \u{201c}script\u{201d} element (i.e., a \u{201c}script\u{201d} element without a \u{201c}src\u{201d} attribute and with a \u{201c}type\u{201d} attribute that is either unspecified, empty, or a JavaScript MIME type) must not have an \u{201c}integrity\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendModuleScriptMessages(
        for element: HTMLStartElement,
        inline: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.hasAttribute("defer") {
            appendMessage(
                "A \u{201c}script\u{201d} element with \u{201c}type=module\u{201d} must not have a \u{201c}defer\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("nomodule") {
            appendMessage(
                "A \u{201c}script\u{201d} element with a \u{201c}nomodule\u{201d} attribute must not have a \u{201c}type\u{201d} attribute with the value \u{201c}module\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        guard inline else { return }
        if element.hasAttribute("blocking") {
            appendMessage(
                "An inline \u{201c}script\u{201d} element with \u{201c}type=module\u{201d} must not have a \u{201c}blocking\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("fetchpriority") {
            appendMessage(
                "An inline \u{201c}script\u{201d} element with \u{201c}type=module\u{201d} must not have a \u{201c}fetchpriority\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("integrity") {
            appendMessage(
                "An inline \u{201c}script\u{201d} element with \u{201c}type=module\u{201d} must not have an \u{201c}integrity\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendTypedScriptMessages(
        for element: HTMLStartElement,
        typeName: String,
        invalidAttributes: Set<String>,
        srcMessage: String,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        for attribute in element.attributes where invalidAttributes.contains(attribute.name) {
            appendMessage(
                "A \u{201c}script\u{201d} element with \u{201c}type=\(typeName)\u{201d} must not have \(indefiniteArticle(for: attribute.name)) \u{201c}\(attribute.name)\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if element.hasAttribute("src") {
            appendMessage(srcMessage, for: element, locations: locations, messages: &messages)
        }
    }

    private func appendDataBlockScriptMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        for attribute in element.attributes where Self.dataBlockInvalidAttributes.contains(attribute.name) {
            appendMessage(
                "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is neither a JavaScript MIME type, \u{201c}module\u{201d}, \u{201c}importmap\u{201d}, nor \u{201c}speculationrules\u{201d} (i.e., a data block) must not have \(indefiniteArticle(for: attribute.name)) \u{201c}\(attribute.name)\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func indefiniteArticle(for attribute: String) -> String {
        switch attribute.first {
        case "a", "e", "i", "o", "u":
            return "an"
        default:
            return "a"
        }
    }

    private func appendResponsiveImageMessages(
        for element: HTMLStartElement,
        stack: [String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let parent = stack.last

        if element.name == "img" {
            if let srcset = element.attributeValue("srcset") {
                appendSrcsetMessages(srcset, attributeName: "srcset", element: element, requiresWidthDescriptors: element.hasAttribute("sizes"), locations: locations, messages: &messages)
            }

            if element.hasAttribute("sizes"), !element.hasAttribute("srcset") {
                appendMessage(
                    "The \u{201c}sizes\u{201d} attribute must only be specified if the \u{201c}srcset\u{201d} attribute is also specified.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }

            if let sizes = element.attributeValue("sizes") {
                appendSizesMessages(sizes, element: element, lazyLoadingApplies: element.attributeValue("loading")?.lowercased() == "lazy", locations: locations, messages: &messages)
            }

            if let srcset = element.attributeValue("srcset"),
               !element.hasAttribute("sizes"),
               element.attributeValue("loading")?.lowercased() != "lazy",
               hasWidthDescriptor(in: srcset) {
                appendMessage(
                    "When the \u{201c}srcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}sizes\u{201d} attribute must also be specified.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if element.name == "link" {
            appendLinkMessages(for: element, inBody: stack.contains("body"), locations: locations, messages: &messages)
        }

        if element.name == "source", parent == "picture", let srcset = element.attributeValue("srcset") {
            appendSrcsetMessages(srcset, attributeName: "srcset", element: element, requiresWidthDescriptors: element.hasAttribute("sizes"), locations: locations, messages: &messages)
        }

        if element.name == "source", let media = element.attributeValue("media"), media.contains("(min-width:)") {
            appendMessage(
                "Bad value \u{201c}\(media)\u{201d} for attribute \u{201c}media\u{201d} on element \u{201c}source\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.name == "source", parent != "picture" {
            if let attribute = element.attributes.first(where: { $0.name == "srcset" || $0.name == "sizes" }) {
                appendMessage(
                    "Attribute \u{201c}\(attribute.name)\u{201d} not allowed on element \u{201c}source\u{201d} at this point.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }
    }

    private func appendLinkMessages(
        for element: HTMLStartElement,
        inBody: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let relTokens = relTokens(for: element)

        if !element.hasAttribute("rel"), !element.hasAttribute("itemprop"), !element.hasAttribute("property") {
            appendMessage(
                "Element \u{201c}link\u{201d} is missing one or more of the following attributes: \u{201c}itemprop\u{201d}, \u{201c}property\u{201d}, \u{201c}rel\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("itemprop"), element.hasAttribute("rel") {
            appendMessage(
                "Attribute \u{201c}rel\u{201d} not allowed on element \u{201c}link\u{201d} at this point.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("as"), !relTokens.contains("preload"), !relTokens.contains("modulepreload") {
            appendMessage(
                "A \u{201c}link\u{201d} element with an \u{201c}as\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}preload\u{201d} or the value \u{201c}modulepreload\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if relTokens.contains("alternate"), relTokens.contains("stylesheet"), element.attributeValue("title")?.isEmpty != false {
            appendMessage(
                "A \u{201c}link\u{201d} element with a \u{201c}rel\u{201d} attribute that contains both the values \u{201c}alternate\u{201d} and \u{201c}stylesheet\u{201d} must have a \u{201c}title\u{201d} attribute with a non-empty value.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("blocking"), relTokens != ["stylesheet"] {
            appendMessage(
                "A \u{201c}link\u{201d} element with a \u{201c}blocking\u{201d} attribute must have a \u{201c}rel\u{201d} attribute whose value is \u{201c}stylesheet\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("color"), !relTokens.contains("mask-icon") {
            appendMessage(
                "A \u{201c}link\u{201d} element with a \u{201c}color\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}mask-icon\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("disabled"), !relTokens.contains("stylesheet") {
            appendMessage(
                "A \u{201c}link\u{201d} element with a \u{201c}disabled\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}stylesheet\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("integrity"), relTokens.isDisjoint(with: Self.integrityRelTokens) {
            appendMessage(
                "A \u{201c}link\u{201d} element with an \u{201c}integrity\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}stylesheet\u{201d} or the value \u{201c}preload\u{201d} or the value \u{201c}modulepreload\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if element.hasAttribute("sizes"), relTokens.isDisjoint(with: Self.iconRelTokens) {
            appendMessage(
                "A \u{201c}link\u{201d} element with a \u{201c}sizes\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}icon\u{201d} or the value \u{201c}apple-touch-icon\u{201d} or the value \u{201c}apple-touch-icon-precomposed\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if inBody, !element.hasAttribute("itemprop"), relTokens.isDisjoint(with: Self.bodyLinkRelTokens) {
            appendMessage(
                "A \u{201c}link\u{201d} element must not appear as a descendant of a \u{201c}body\u{201d} element unless the \u{201c}link\u{201d} element has an \u{201c}itemprop\u{201d} attribute or has a \u{201c}rel\u{201d} attribute whose value contains \u{201c}dns-prefetch\u{201d}, \u{201c}modulepreload\u{201d}, \u{201c}pingback\u{201d}, \u{201c}preconnect\u{201d}, \u{201c}prefetch\u{201d}, \u{201c}preload\u{201d}, \u{201c}prerender\u{201d}, or \u{201c}stylesheet\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        appendLinkPreloadMessages(for: element, relTokens: relTokens, locations: locations, messages: &messages)
        appendLinkImageCandidateMessages(for: element, relTokens: relTokens, locations: locations, messages: &messages)
    }

    private func appendLinkPreloadMessages(
        for element: HTMLStartElement,
        relTokens: Set<String>,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if relTokens.contains("preload") {
            if let asValue = element.attributeValue("as")?.lowercased() {
                if !Self.preloadDestinations.contains(asValue) {
                    appendMessage(
                        "The value \u{201c}\(asValue)\u{201d} is not a valid value for the \u{201c}as\u{201d} attribute of a \u{201c}link\u{201d} element with \u{201c}rel=preload\u{201d}.",
                        for: element,
                        locations: locations,
                        messages: &messages
                    )
                }
            } else {
                appendMessage(
                    "A \u{201c}link\u{201d} element with a \u{201c}rel\u{201d} attribute that contains the value \u{201c}preload\u{201d} must have an \u{201c}as\u{201d} attribute.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        } else if relTokens.contains("modulepreload"),
                  let asValue = element.attributeValue("as")?.lowercased(),
                  !Self.modulepreloadDestinations.contains(asValue) {
            appendMessage(
                "The value \u{201c}\(asValue)\u{201d} is not a valid value for the \u{201c}as\u{201d} attribute of a \u{201c}link\u{201d} element with \u{201c}rel=modulepreload\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendLinkImageCandidateMessages(
        for element: HTMLStartElement,
        relTokens: Set<String>,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.hasAttribute("imagesizes"), !element.hasAttribute("imagesrcset") {
            appendMessage(
                "The \u{201c}imagesizes\u{201d} attribute must only be specified if the \u{201c}imagesrcset\u{201d} attribute is also specified.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }

        if let imagesrcset = element.attributeValue("imagesrcset") {
            if !relTokens.contains("preload") && !relTokens.contains("modulepreload") {
                appendMessage(
                    relTokens.contains("stylesheet")
                        ? "A \u{201c}link\u{201d} element with an \u{201c}imagesrcset\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}preload\u{201d}."
                        : "A \u{201c}link\u{201d} element with an \u{201c}as\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}preload\u{201d} or the value \u{201c}modulepreload\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else if element.attributeValue("as")?.lowercased() != "image" {
                appendMessage(
                    "A \u{201c}link\u{201d} element with an \u{201c}imagesrcset\u{201d} attribute must have an \u{201c}as\u{201d} attribute with value \u{201c}image\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else if !element.hasAttribute("imagesizes"), hasWidthDescriptor(in: imagesrcset) {
                appendMessage(
                    "When the \u{201c}imagesrcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}imagesizes\u{201d} attribute must also be specified.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }
    }

    private func appendImportMapMessages(
        content: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let object = parseJSONObject(
            content,
            invalidMessage: "A script \u{201c}script\u{201d} with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must have valid JSON content.",
            element: element,
            locations: locations,
            messages: &messages
        ) else { return }

        if object.keys.contains(where: { !Self.importMapTopLevelKeys.contains($0) }) {
            appendMessage(
                "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must contain a JSON object with no properties other than \u{201c}imports\u{201d}, \u{201c}scopes\u{201d}, and \u{201c}integrity\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
            return
        }

        if let imports = object["imports"] {
            guard let map = imports as? [String: Any] else {
                appendMessage(
                    "The value of the \u{201c}imports\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must be a JSON object.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return
            }
            if appendSpecifierMapMessages(map, owner: "imports", element: element, locations: locations, messages: &messages) {
                return
            }
        }

        guard let scopes = object["scopes"] else { return }
        guard let scopeMap = scopes as? [String: Any] else {
            appendMessage(
                "The value of the \u{201c}scopes\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must be a JSON object whose values are also JSON objects.",
                for: element,
                locations: locations,
                messages: &messages
            )
            return
        }

        for (scope, value) in scopeMap {
            guard isImportMapURL(scope) else {
                appendMessage(
                    "The value of the \u{201c}scopes\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must be a JSON object whose keys are valid URL strings.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return
            }
            guard let map = value as? [String: Any] else {
                appendMessage(
                    "The value of the \u{201c}scopes\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must be a JSON object whose values are also JSON objects.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return
            }
            if appendSpecifierMapMessages(map, owner: "scopes", element: element, locations: locations, messages: &messages) {
                return
            }
        }
    }

    @discardableResult
    private func appendSpecifierMapMessages(
        _ map: [String: Any],
        owner: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        for (key, value) in map {
            guard !key.isEmpty else {
                appendMessage(
                    "A specifier map defined in a \u{201c}\(owner)\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must only contain non-empty keys.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return true
            }
            guard let stringValue = value as? String else {
                appendMessage(
                    "A specifier map defined in a \u{201c}\(owner)\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must only contain string values.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return true
            }
            if key.hasSuffix("/"), !stringValue.hasSuffix("/") {
                appendMessage(
                    "A specifier map defined in a \u{201c}\(owner)\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must have values that end with \u{201c}/\u{201d} when its corresponding key ends with \u{201c}/\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return true
            }
            if owner == "scopes", !isImportMapURL(stringValue) {
                appendMessage(
                    "A specifier map defined in a \u{201c}scopes\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must only contain valid URL values.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return true
            }
        }
        return false
    }

    private func appendSpeculationRulesMessages(
        content: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let object = parseJSONObject(
            content,
            invalidMessage: "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must have valid JSON content.",
            nonObjectMessage: "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must contain a JSON object.",
            element: element,
            locations: locations,
            messages: &messages
        ) else { return }

        let ruleKeys = object.keys.filter { Self.speculationRuleTopLevelKeys.contains($0) }
        guard !ruleKeys.isEmpty else {
            appendMessage(
                "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must contain a JSON object with at least one of the properties \u{201c}prefetch\u{201d} or \u{201c}prerender\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
            return
        }

        if object.keys.contains(where: { !Self.speculationRuleTopLevelKeys.contains($0) }) {
            appendMessage(
                "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must contain a JSON object with only \u{201c}prefetch\u{201d} and/or \u{201c}prerender\u{201d} as properties.",
                for: element,
                locations: locations,
                messages: &messages
            )
            return
        }

        for key in ["prefetch", "prerender"] where object[key] != nil {
            guard let rules = object[key] as? [Any] else {
                appendMessage(
                    "The \u{201c}\(key)\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must be a JSON array.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return
            }
            if appendSpeculationRuleArrayMessages(rules, key: key, element: element, locations: locations, messages: &messages) {
                return
            }
        }
    }

    @discardableResult
    private func appendSpeculationRuleArrayMessages(
        _ rules: [Any],
        key: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        for ruleValue in rules {
            guard let rule = ruleValue as? [String: Any] else {
                appendMessage(
                    "Each item in the \u{201c}\(key)\u{201d} array within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}speculationrules\u{201d} must be a JSON object.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
                return true
            }
            if appendSpeculationRuleMessages(rule, key: key, element: element, locations: locations, messages: &messages) {
                return true
            }
        }
        return false
    }

    @discardableResult
    private func appendSpeculationRuleMessages(
        _ rule: [String: Any],
        key: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        if rule.keys.contains(where: { !Self.speculationRuleKeys.contains($0) }) {
            appendMessage(
                "Each rule in the \u{201c}\(key)\u{201d} array must only contain the properties \u{201c}source\u{201d}, \u{201c}urls\u{201d}, \u{201c}where\u{201d}, and \u{201c}eagerness\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
            return true
        }

        if let eagerness = rule["eagerness"] {
            guard let value = eagerness as? String else {
                appendMessage("The \u{201c}eagerness\u{201d} property in a speculation rule must be a string.", for: element, locations: locations, messages: &messages)
                return true
            }
            guard Self.speculationRuleEagernessValues.contains(value) else {
                appendMessage("The \u{201c}eagerness\u{201d} property in a speculation rule must be one of \u{201c}eager\u{201d}, \u{201c}moderate\u{201d}, or \u{201c}conservative\u{201d}.", for: element, locations: locations, messages: &messages)
                return true
            }
        }

        let source: String?
        if let sourceValue = rule["source"] {
            guard let string = sourceValue as? String else {
                appendMessage("The \u{201c}source\u{201d} property in a speculation rule must be a string.", for: element, locations: locations, messages: &messages)
                return true
            }
            guard string == "list" || string == "document" else {
                appendMessage("The \u{201c}source\u{201d} property in a speculation rule must be either \u{201c}list\u{201d} or \u{201c}document\u{201d}.", for: element, locations: locations, messages: &messages)
                return true
            }
            source = string
        } else if rule["urls"] != nil {
            source = "list"
        } else if rule["where"] != nil {
            source = "document"
        } else {
            source = nil
        }

        guard let source else {
            appendMessage("A speculation rule must have a \u{201c}source\u{201d} property, or a \u{201c}urls\u{201d} property (for list rules), or a \u{201c}where\u{201d} property (for document rules).", for: element, locations: locations, messages: &messages)
            return true
        }

        if source == "list" {
            if rule["where"] != nil {
                appendMessage("A speculation rule with \u{201c}source\u{201d} set to \u{201c}list\u{201d} must not have a \u{201c}where\u{201d} property.", for: element, locations: locations, messages: &messages)
                return true
            }
            guard let urls = rule["urls"] else {
                appendMessage("A speculation rule with \u{201c}source\u{201d} set to \u{201c}list\u{201d} must have a \u{201c}urls\u{201d} property.", for: element, locations: locations, messages: &messages)
                return true
            }
            return appendURLArrayMessages(urls, element: element, locations: locations, messages: &messages)
        }

        if rule["urls"] != nil {
            appendMessage("A speculation rule with \u{201c}source\u{201d} set to \u{201c}document\u{201d} must not have a \u{201c}urls\u{201d} property.", for: element, locations: locations, messages: &messages)
            return true
        }
        guard let whereValue = rule["where"] else {
            appendMessage("A speculation rule with \u{201c}source\u{201d} set to \u{201c}document\u{201d} must have a \u{201c}where\u{201d} property.", for: element, locations: locations, messages: &messages)
            return true
        }
        guard let predicate = whereValue as? [String: Any] else {
            appendMessage("The \u{201c}where\u{201d} property in a speculation rule must be a JSON object.", for: element, locations: locations, messages: &messages)
            return true
        }
        return appendDocumentRulePredicateMessages(predicate, element: element, locations: locations, messages: &messages)
    }

    @discardableResult
    private func appendURLArrayMessages(
        _ value: Any,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        guard let urls = value as? [Any] else {
            appendMessage("The \u{201c}urls\u{201d} property in a speculation rule must be a JSON array.", for: element, locations: locations, messages: &messages)
            return true
        }
        guard !urls.isEmpty else {
            appendMessage("The \u{201c}urls\u{201d} property in a speculation rule must contain at least one URL.", for: element, locations: locations, messages: &messages)
            return true
        }
        for url in urls {
            guard let string = url as? String else {
                appendMessage("Each item in the \u{201c}urls\u{201d} array must be a string.", for: element, locations: locations, messages: &messages)
                return true
            }
            guard !string.isEmpty else {
                appendMessage("Each URL in the \u{201c}urls\u{201d} array must be a non-empty string.", for: element, locations: locations, messages: &messages)
                return true
            }
        }
        return false
    }

    @discardableResult
    private func appendDocumentRulePredicateMessages(
        _ predicate: [String: Any],
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        let predicateKeys = predicate.keys.filter { Self.documentRulePredicateKeys.contains($0) }
        guard !predicateKeys.isEmpty else {
            appendMessage("A document rule predicate must have one of the properties \u{201c}and\u{201d}, \u{201c}or\u{201d}, \u{201c}not\u{201d}, \u{201c}href_matches\u{201d}, or \u{201c}selector_matches\u{201d}.", for: element, locations: locations, messages: &messages)
            return true
        }
        guard predicateKeys.count == 1 else {
            appendMessage("A document rule predicate must have only one of the properties \u{201c}and\u{201d}, \u{201c}or\u{201d}, \u{201c}not\u{201d}, \u{201c}href_matches\u{201d}, or \u{201c}selector_matches\u{201d}.", for: element, locations: locations, messages: &messages)
            return true
        }

        let key = predicateKeys[0]
        switch key {
        case "and", "or":
            guard let predicates = predicate[key] as? [Any] else {
                appendMessage("The \u{201c}\(key)\u{201d} property in a document rule must be a JSON array.", for: element, locations: locations, messages: &messages)
                return true
            }
            guard !predicates.isEmpty else {
                appendMessage("The \u{201c}\(key)\u{201d} property in a document rule must contain at least one item.", for: element, locations: locations, messages: &messages)
                return true
            }
            for item in predicates {
                guard let nested = item as? [String: Any] else { continue }
                if appendDocumentRulePredicateMessages(nested, element: element, locations: locations, messages: &messages) {
                    return true
                }
            }
        case "not":
            if let nested = predicate[key] as? [String: Any] {
                return appendDocumentRulePredicateMessages(nested, element: element, locations: locations, messages: &messages)
            }
        case "href_matches", "selector_matches":
            return appendStringOrStringArrayPredicateMessage(predicate[key] as Any, key: key, element: element, locations: locations, messages: &messages)
        default:
            break
        }
        return false
    }

    @discardableResult
    private func appendStringOrStringArrayPredicateMessage(
        _ value: Any,
        key: String,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        if let string = value as? String {
            guard !string.isEmpty else {
                appendMessage("The \u{201c}\(key)\u{201d} property in a document rule must be a non-empty string.", for: element, locations: locations, messages: &messages)
                return true
            }
            return false
        }

        if let array = value as? [Any] {
            guard !array.isEmpty else {
                appendMessage("The \u{201c}\(key)\u{201d} property in a document rule must contain at least one pattern.", for: element, locations: locations, messages: &messages)
                return true
            }
            for item in array where !(item is String) {
                appendMessage("The \u{201c}\(key)\u{201d} property in a document rule must be a string or an array of strings.", for: element, locations: locations, messages: &messages)
                return true
            }
            return false
        }

        appendMessage("The \u{201c}\(key)\u{201d} property in a document rule must be a string or an array of strings.", for: element, locations: locations, messages: &messages)
        return true
    }

    private func parseJSONObject(
        _ content: String,
        invalidMessage: String,
        nonObjectMessage: String? = nil,
        element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> [String: Any]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            appendMessage(invalidMessage, for: element, locations: locations, messages: &messages)
            return nil
        }
        guard let object = json as? [String: Any] else {
            appendMessage(nonObjectMessage ?? invalidMessage, for: element, locations: locations, messages: &messages)
            return nil
        }
        return object
    }

    private func isImportMapURL(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains("..."),
              !value.unicodeScalars.contains(where: { $0.value <= 0x20 }) else {
            return false
        }
        if value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") {
            return true
        }
        guard let colon = value.firstIndex(of: ":") else { return false }
        return value[..<colon].unicodeScalars.first?.properties.isAlphabetic == true
    }

    private func relTokens(for element: HTMLStartElement) -> Set<String> {
        Set((element.attributeValue("rel") ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    private func appendSizesMessages(
        _ value: String,
        element: HTMLStartElement,
        lazyLoadingApplies: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("auto"), !lazyLoadingApplies {
            appendMessage(
                "The \u{201c}sizes\u{201d} attribute value starting with \u{201c}auto\u{201d} is only valid for lazy-loaded images. Add \u{201c}loading=\u{201d}\u{201c}lazy\u{201d} to this element.",
                for: element,
                locations: locations,
                messages: &messages
            )
            return
        }

        if !isValidSourceSizeList(trimmed) {
            appendMessage(
                "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}sizes\u{201d} on element \u{201c}\(element.name)\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendSrcsetMessages(
        _ value: String,
        attributeName: String,
        element: HTMLStartElement,
        requiresWidthDescriptors: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let analysis = analyzeSrcset(value, requiresWidthDescriptors: requiresWidthDescriptors)
        if !analysis.isValid {
            appendMessage(
                "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attributeName)\u{201d} on element \u{201c}\(element.name)\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private struct SrcsetAnalysis {
        var isValid: Bool
        var hasWidthDescriptor: Bool
    }

    private enum ImageDescriptor: Hashable {
        case width(Int)
        case density(Double)
        case omitted
    }

    private func analyzeSrcset(_ value: String, requiresWidthDescriptors: Bool) -> SrcsetAnalysis {
        guard !value.isEmpty,
              !value.hasPrefix(","),
              !value.hasSuffix(",") else {
            return SrcsetAnalysis(isValid: false, hasWidthDescriptor: false)
        }

        var descriptors: [ImageDescriptor] = []
        var hasWidthDescriptor = false
        for rawCandidate in value.split(separator: ",", omittingEmptySubsequences: false) {
            let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else {
                return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
            }

            let fields = candidate.split(whereSeparator: { $0.isWhitespace })
            guard let url = fields.first, !url.isEmpty else {
                return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
            }
            guard url != "http:" else {
                return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
            }
            guard fields.count <= 2 else {
                return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
            }

            let descriptor: ImageDescriptor
            if fields.count == 1 {
                descriptor = .omitted
            } else if let parsed = parseImageDescriptor(String(fields[1])) {
                descriptor = parsed
            } else {
                return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
            }

            if case .width = descriptor {
                hasWidthDescriptor = true
            }
            descriptors.append(descriptor)
        }

        let hasDensityDescriptor = descriptors.contains {
            if case .density = $0 { return true }
            return false
        }
        if hasWidthDescriptor && hasDensityDescriptor {
            return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
        }
        if requiresWidthDescriptors, descriptors.contains(where: { descriptor in
            if case .width = descriptor { return false }
            return true
        }) {
            return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
        }

        var explicitDescriptors: Set<ImageDescriptor> = []
        var sawOmittedDescriptor = false
        for descriptor in descriptors {
            switch descriptor {
            case .omitted:
                sawOmittedDescriptor = true
            case .density(1.0) where sawOmittedDescriptor:
                return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
            default:
                if explicitDescriptors.contains(descriptor) {
                    return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
                }
                explicitDescriptors.insert(descriptor)
            }
        }
        if sawOmittedDescriptor, explicitDescriptors.contains(.density(1.0)) {
            return SrcsetAnalysis(isValid: false, hasWidthDescriptor: hasWidthDescriptor)
        }

        return SrcsetAnalysis(isValid: true, hasWidthDescriptor: hasWidthDescriptor)
    }

    private func parseImageDescriptor(_ value: String) -> ImageDescriptor? {
        guard !value.contains("/**/"), !value.isEmpty else { return nil }
        if value.hasSuffix("w") {
            let number = value.dropLast()
            guard !number.isEmpty,
                  number.allSatisfy(\.isNumber),
                  let width = Int(number),
                  width > 0 else {
                return nil
            }
            return .width(width)
        }
        if value.hasSuffix("x") {
            let number = value.dropLast()
            guard !number.hasPrefix("+"),
                  !number.hasPrefix("-"),
                  let density = Double(number),
                  density.isFinite,
                  density > 0 else {
                return nil
            }
            return .density(density)
        }
        return nil
    }

    private func isValidSourceSizeList(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let lowercased = value.lowercased()
        guard !lowercased.contains("(min-width:)") else { return false }
        guard !lowercased.hasPrefix("all ") && !lowercased.hasPrefix("all and ") else { return false }
        guard !lowercased.hasPrefix("min-width:") else { return false }
        guard !lowercased.contains("(})") && !lowercased.contains("(123)") else { return false }
        guard !["badvalue", "default", "inherit", "initial", "foo-bar"].contains(lowercased) else { return false }

        let components = value.split(separator: ",", omittingEmptySubsequences: false)
        let lastIndex = components.index(before: components.endIndex)
        var sawDefaultSize = false
        for (index, component) in components.enumerated() {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            if trimmed.lowercased() == "auto" {
                if sawDefaultSize || index != lastIndex {
                    return false
                }
                sawDefaultSize = true
                continue
            }
            guard let sizeToken = trimmed.split(whereSeparator: { $0.isWhitespace }).last else {
                return false
            }
            let isDefaultSize = trimmed.split(whereSeparator: { $0.isWhitespace }).count == 1
            if isDefaultSize {
                if sawDefaultSize || index != lastIndex {
                    return false
                }
                sawDefaultSize = true
            }
            guard isValidSourceSizeValue(String(sizeToken)) else { return false }
        }
        return true
    }

    private func isValidSourceSizeValue(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        if lowercased == "0" || lowercased == "-0" {
            return true
        }
        if lowercased.hasPrefix("calc(") || lowercased.hasPrefix("min(") || lowercased.hasPrefix("max(") || lowercased.hasPrefix("clamp(") {
            return lowercased.hasSuffix(")")
        }

        let allowedUnits = ["px", "em", "ex", "ch", "rem", "vw", "vh", "vmin", "vmax", "cm", "mm", "q", "in", "pc", "pt"]
        guard let unit = allowedUnits.first(where: { lowercased.hasSuffix($0) }) else { return false }
        let number = lowercased.dropLast(unit.count)
        guard !number.isEmpty, let value = Double(number), value >= 0 else {
            return false
        }
        return true
    }

    private func hasWidthDescriptor(in srcset: String) -> Bool {
        analyzeSrcset(srcset, requiresWidthDescriptors: false).hasWidthDescriptor
    }

    private func isValidTimeDateTimeString(_ value: String) -> Bool {
        isValidDateString(value)
            || isValidTimeString(value)
            || isValidLocalDateAndTimeString(value)
            || isValidGlobalDateAndTimeString(value, strictTimeZone: false)
    }

    private func isValidDateString(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == Self.hyphen,
              bytes[7] == Self.hyphen,
              let year = parseASCIIInteger(bytes, in: 0..<4),
              let month = parseASCIIInteger(bytes, in: 5..<7),
              let day = parseASCIIInteger(bytes, in: 8..<10),
              year >= 1000,
              month >= 1,
              month <= 12 else {
            return false
        }

        return day >= 1 && day <= daysInMonth(month, year: year)
    }

    private func isValidLocalDateAndTimeString(_ value: String) -> Bool {
        splitDateAndTime(value).contains { datePart, timePart in
            isValidDateString(datePart) && isValidTimeString(timePart)
        }
    }

    private func isValidGlobalDateAndTimeString(_ value: String, strictTimeZone: Bool) -> Bool {
        splitDateAndTime(value).contains { datePart, timeAndZone in
            guard isValidDateString(datePart),
                  let split = splitTimeAndTimeZone(timeAndZone) else {
                return false
            }
            return isValidTimeString(split.time)
                && isValidTimeZoneOffset(split.timeZone, strict: strictTimeZone)
        }
    }

    private func splitDateAndTime(_ value: String) -> [(date: String, time: String)] {
        ["T", " "].compactMap { separator in
            guard let range = value.range(of: separator) else { return nil }
            return (
                date: String(value[..<range.lowerBound]),
                time: String(value[range.upperBound...])
            )
        }
    }

    private func splitTimeAndTimeZone(_ value: String) -> (time: String, timeZone: String)? {
        if value.hasSuffix("Z") {
            return (String(value.dropLast()), "Z")
        }

        guard let offsetStart = value.firstIndex(where: { $0 == "+" || $0 == "-" }),
              offsetStart != value.startIndex else {
            return nil
        }
        return (String(value[..<offsetStart]), String(value[offsetStart...]))
    }

    private func isValidTimeString(_ value: String) -> Bool {
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 || pieces.count == 3,
              let hour = twoDigitInteger(String(pieces[0])),
              let minute = twoDigitInteger(String(pieces[1])),
              hour <= 23,
              minute <= 59 else {
            return false
        }

        guard pieces.count == 3 else { return true }
        let secondsAndFraction = pieces[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondsAndFraction.count == 1 || secondsAndFraction.count == 2,
              let seconds = twoDigitInteger(String(secondsAndFraction[0])),
              seconds <= 59 else {
            return false
        }

        if secondsAndFraction.count == 2 {
            let fraction = secondsAndFraction[1]
            guard (1...3).contains(fraction.count),
                  fraction.utf8.allSatisfy(isASCIIDigit) else {
                return false
            }
        }
        return true
    }

    private func isValidTimeZoneOffset(_ value: String, strict: Bool) -> Bool {
        if value == "Z" {
            return true
        }

        let bytes = Array(value.utf8)
        guard bytes.count == 5 || bytes.count == 6,
              bytes[0] == Self.plus || bytes[0] == Self.hyphen else {
            return false
        }

        let hourRange = 1..<3
        let minuteRange: Range<Int>
        if bytes.count == 6 {
            guard bytes[3] == Self.colon else { return false }
            minuteRange = 4..<6
        } else {
            minuteRange = 3..<5
        }

        guard let hour = parseASCIIInteger(bytes, in: hourRange),
              let minute = parseASCIIInteger(bytes, in: minuteRange),
              minute <= 59 else {
            return false
        }

        if strict {
            return hour <= 12 && [0, 30, 45].contains(minute)
        }
        return hour <= 23
    }

    private func twoDigitInteger(_ value: String) -> Int? {
        let bytes = Array(value.utf8)
        guard bytes.count == 2 else { return nil }
        return parseASCIIInteger(bytes, in: 0..<2)
    }

    private func parseASCIIInteger(_ bytes: [UInt8], in range: Range<Int>) -> Int? {
        var value = 0
        for index in range {
            guard isASCIIDigit(bytes[index]) else { return nil }
            value = value * 10 + Int(bytes[index] - Self.zero)
        }
        return value
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= Self.zero && byte <= UInt8(ascii: "9")
    }

    private func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12:
            return 31
        case 4, 6, 9, 11:
            return 30
        case 2:
            return isLeapYear(year) ? 29 : 28
        default:
            return 0
        }
    }

    private func isLeapYear(_ year: Int) -> Bool {
        year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    }

    private static let bodyLinkRelTokens: Set<String> = [
        "dns-prefetch", "modulepreload", "pingback", "preconnect", "prefetch", "preload", "prerender", "stylesheet"
    ]

    private static let iconRelTokens: Set<String> = [
        "icon", "apple-touch-icon", "apple-touch-icon-precomposed"
    ]

    private static let integrityRelTokens: Set<String> = [
        "stylesheet", "preload", "modulepreload"
    ]

    private static let preloadDestinations: Set<String> = [
        "audio", "document", "embed", "fetch", "font", "image", "object", "script", "style", "track", "video"
    ]

    private static let modulepreloadDestinations: Set<String> = [
        "json", "script", "style", "worker"
    ]

    private static let pictureDisallowedAttributes: Set<String> = [
        "align", "alt", "border", "crossorigin", "height", "hspace", "ismap", "longdesc", "lowsrc",
        "media", "name", "role", "sizes", "src", "srcset", "usemap", "vspace", "width"
    ]

    private static let pictureSourceDisallowedAttributes: Set<String> = [
        "align", "alt", "border", "crossorigin", "hspace", "ismap", "longdesc", "role", "src",
        "usemap", "vspace"
    ]

    private static let srcsetDisallowedElements: Set<String> = [
        "audio", "image", "input", "link", "object", "track", "video"
    ]

    private static let inputTypes: Set<String> = [
        "button", "checkbox", "color", "date", "datetime-local", "email", "file", "hidden", "image",
        "month", "number", "password", "radio", "range", "reset", "search", "submit", "tel", "text",
        "time", "url", "week"
    ]

    private static let inputReadonlyTypes: Set<String> = [
        "date", "datetime-local", "email", "month", "number", "password", "search", "tel", "text", "time", "url", "week"
    ]

    private static let inputRequiredTypes: Set<String> = [
        "checkbox", "date", "datetime-local", "email", "file", "month", "number", "password", "radio", "search", "tel", "text", "time", "url", "week"
    ]

    private static let inputPatternTypes: Set<String> = [
        "email", "password", "search", "tel", "text", "url"
    ]

    private static let inputTextEntryTypes: Set<String> = [
        "email", "password", "search", "tel", "text", "url"
    ]

    private static let inputListTypes: Set<String> = [
        "color", "date", "datetime-local", "email", "month", "number", "range", "search", "tel", "text", "time", "url", "week"
    ]

    private static let inputMinMaxTypes: Set<String> = [
        "date", "datetime-local", "month", "number", "range", "time", "week"
    ]

    private static let inputStepTypes: Set<String> = [
        "date", "datetime-local", "month", "number", "range", "time", "week"
    ]

    private static let autocompleteContactTokens: Set<String> = [
        "home", "work", "mobile", "fax", "pager"
    ]

    private static let autocompleteContactFields: Set<String> = [
        "tel", "tel-country-code", "tel-national", "tel-area-code", "tel-local", "tel-local-prefix",
        "tel-local-suffix", "tel-extension", "email", "impp"
    ]

    private static let autocompleteFields: Set<String> = [
        "name", "honorific-prefix", "given-name", "additional-name", "family-name", "honorific-suffix",
        "nickname", "username", "new-password", "current-password", "one-time-code", "organization-title",
        "organization", "street-address", "address-line1", "address-line2", "address-line3",
        "address-level4", "address-level3", "address-level2", "address-level1", "country",
        "country-name", "postal-code", "cc-name", "cc-given-name", "cc-additional-name",
        "cc-family-name", "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year", "cc-csc",
        "cc-type", "transaction-currency", "transaction-amount", "language", "bday", "bday-day",
        "bday-month", "bday-year", "sex", "url", "photo", "email", "impp", "tel",
        "tel-country-code", "tel-national", "tel-area-code", "tel-local", "tel-local-prefix",
        "tel-local-suffix", "tel-extension"
    ]

    private static let javaScriptMIMETypes: Set<String> = [
        "application/ecmascript",
        "application/javascript",
        "application/x-ecmascript",
        "application/x-javascript",
        "text/ecmascript",
        "text/javascript",
        "text/javascript1.0",
        "text/javascript1.1",
        "text/javascript1.2",
        "text/javascript1.3",
        "text/javascript1.4",
        "text/javascript1.5",
        "text/jscript",
        "text/livescript",
        "text/x-ecmascript",
        "text/x-javascript"
    ]

    private static let dataBlockInvalidAttributes: Set<String> = [
        "async", "blocking", "crossorigin", "defer", "fetchpriority", "integrity", "nomodule", "referrerpolicy", "src"
    ]

    private static let importMapInvalidAttributes: Set<String> = [
        "async", "blocking", "crossorigin", "defer", "fetchpriority", "integrity", "nomodule", "referrerpolicy"
    ]

    private static let speculationRulesInvalidAttributes: Set<String> = [
        "async", "blocking", "crossorigin", "defer", "fetchpriority", "integrity", "nomodule", "referrerpolicy"
    ]

    private static let importMapTopLevelKeys: Set<String> = [
        "imports", "scopes", "integrity"
    ]

    private static let speculationRuleTopLevelKeys: Set<String> = [
        "prefetch", "prerender"
    ]

    private static let speculationRuleKeys: Set<String> = [
        "source", "urls", "where", "eagerness"
    ]

    private static let speculationRuleEagernessValues: Set<String> = [
        "eager", "moderate", "conservative"
    ]

    private static let documentRulePredicateKeys: Set<String> = [
        "and", "or", "not", "href_matches", "selector_matches"
    ]

    private static let zero = UInt8(ascii: "0")
    private static let plus = UInt8(ascii: "+")
    private static let colon = UInt8(ascii: ":")
    private static let hyphen = UInt8(ascii: "-")

    private func appendMessage(
        _ message: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            message,
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func appendMessage(
        _ message: String,
        range: HTMLSourceRange,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.error(
            message,
            location: locations.location(offset: range.offset, length: range.length),
            extract: locations.extract(offset: range.offset, length: range.length)
        ))
    }

    private func appendWarningMessage(
        _ message: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.warning(
            message,
            location: locations.location(offset: element.range.offset, length: element.range.length),
            extract: locations.extract(offset: element.range.offset, length: element.range.length)
        ))
    }

    private func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    private func isASCIIHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 70)
            || (scalar.value >= 97 && scalar.value <= 102)
    }

    private func isPlausibleLanguageTag(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
            && !value.contains("--")
            && !value.hasSuffix("-")
            && !value.hasPrefix("-")
    }
}
