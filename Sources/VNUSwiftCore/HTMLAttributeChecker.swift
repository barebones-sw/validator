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
        var itemScopeStack: [Bool] = []
        let idValues = idValues(in: document)
        let referencedItemIDs = referencedItemIDs(in: document)

        for event in document.events {
            switch event {
            case let .startElement(element):
                appendMicrodataMessages(
                    for: element,
                    hasItemAncestor: itemScopeStack.contains(true),
                    idValues: idValues,
                    referencedItemIDs: referencedItemIDs,
                    locations: locations,
                    messages: &messages
                )
                itemScopeStack.append(element.hasAttribute("itemscope"))
            case .endElement:
                if !itemScopeStack.isEmpty {
                    _ = itemScopeStack.popLast()
                }
            default:
                continue
            }
        }

        return messages
    }

    private func idValues(in document: HTMLParsedDocument) -> Set<String> {
        var result: Set<String> = []
        for event in document.events {
            guard case let .startElement(element) = event,
                  let id = element.attributeValue("id"),
                  !id.isEmpty else {
                continue
            }
            result.insert(id)
        }
        return result
    }

    private func referencedItemIDs(in document: HTMLParsedDocument) -> Set<String> {
        var result: Set<String> = []
        for event in document.events {
            guard case let .startElement(element) = event,
                  let itemref = element.attributeValue("itemref") else {
                continue
            }
            for token in microdataTokens(itemref) {
                result.insert(token)
            }
        }
        return result
    }

    private func appendMicrodataMessages(
        for element: HTMLStartElement,
        hasItemAncestor: Bool,
        idValues: Set<String>,
        referencedItemIDs: Set<String>,
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

        if let itemref = element.attributeValue("itemref") {
            if !element.hasAttribute("itemscope") {
                appendMessage(
                    "The \u{201c}itemref\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
            let tokens = microdataTokens(itemref)
            if Set(tokens).count < tokens.count {
                appendMessage(
                    "The \u{201c}itemref\u{201d} attribute contained redundant references.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
            if let missing = tokens.first(where: { !idValues.contains($0) }) {
                appendMessage(
                    "The \u{201c}itemref\u{201d} attribute referenced \u{201c}\(missing)\u{201d}, but there is no element with an \u{201c}id\u{201d} attribute with that value.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        let isReferencedProperty = element.attributeValue("id").map { referencedItemIDs.contains($0) } ?? false
        if element.hasAttribute("itemprop"),
           !hasItemAncestor,
           !isReferencedProperty {
            appendMessage(
                "The \u{201c}itemprop\u{201d} attribute was specified, but the element is not a property of any item.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func microdataTokens(_ value: String) -> [String] {
        value.split { scalar in
            scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}"
        }.map(String.init)
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
        var roleStack: [String?] = []
        var anchorHrefStack: [Bool] = []
        var labelStack: [LabelState] = []
        var pictureStack: [PictureState] = []
        var mediaStack: [MediaState] = []
        var selectStack: [SelectState] = []
        var optionStack: [OptionState] = []
        var figureStack: [FigureState] = []
        var detailsStack: [DetailsState] = []
        var sectioningStack: [SectioningState] = []
        var headingStack: [HeadingState] = []
        var headingLevels: [Int] = []
        var firstHeadingElement: HTMLStartElement?
        var rubyStack: [RubyState] = []
        var optgroupStack: [OptgroupState] = []
        var scriptContent: ScriptContentState?
        var styleContent: StyleContentState?
        var titleCapture: TitleCapture?
        var sawTitle = false
        var activeRoleTabElement: HTMLStartElement?
        var sawRoleTabpanel = false
        var sawBaseBlockingElement = false
        var sawBodyContentBeforeBase = false
        var autofocusCount = 0
        var visibleMainCount = 0
        var visibleRoleMainCount = 0
        let idElementNames = idElementNames(in: document)
        let idLabelableElementNames = idLabelableElementNames(in: document)
        let mapNames = mapNames(in: document)

        for event in document.events {
            switch event {
            case let .startElement(element):
                let parent = stack.last
                let role = firstRoleToken(for: element)
                if role == "tab", normalizedAttributeValue("aria-selected", for: element) == "true" {
                    activeRoleTabElement = element
                }
                if role == "tabpanel" {
                    sawRoleTabpanel = true
                }
                if Self.sectioningHeadingElements.contains(element.name) {
                    for index in sectioningStack.indices {
                        sectioningStack[index].hasHeading = true
                    }
                }
                if let level = Self.headingLevel(for: element.name) {
                    headingStack.append(HeadingState(element: element, level: level))
                }
                if let rubyIndex = rubyStack.indices.last, parent == "ruby" {
                    rubyStack[rubyIndex].directChildNames.append(element.name)
                    if !Self.rubyAnnotationElements.contains(element.name) {
                        rubyStack[rubyIndex].sawBaseContent = true
                    }
                }
                if parent == "optgroup", element.name == "legend", let optgroupIndex = optgroupStack.indices.last {
                    optgroupStack[optgroupIndex].sawLegend = true
                }
                appendDisallowedAttributeMessages(for: element, parent: parent, locations: locations, messages: &messages)
                appendDatatypeAttributeMessages(for: element, locations: locations, messages: &messages)
                appendGlobalAttributeMessages(for: element, locations: locations, messages: &messages)
                appendBaseMessages(for: element, sawBodyContentBeforeBase: sawBodyContentBeforeBase, sawBaseBlockingElement: sawBaseBlockingElement, locations: locations, messages: &messages)
                appendStructuralAssertionMessages(for: element, stack: stack, mapNames: mapNames, locations: locations, messages: &messages)
                appendElementSpecificMessages(for: element, stack: stack, locations: locations, messages: &messages)
                appendLabelForReferenceMessages(for: element, idLabelableElementNames: idLabelableElementNames, locations: locations, messages: &messages)
                appendAutofocusMessages(for: element, autofocusCount: &autofocusCount, locations: locations, messages: &messages)
                appendARIAAttributeMessages(
                    for: element,
                    role: role,
                    idElementNames: idElementNames,
                    stack: stack,
                    roleStack: roleStack,
                    labelStack: labelStack,
                    visibleMainCount: &visibleMainCount,
                    visibleRoleMainCount: &visibleRoleMainCount,
                    locations: locations,
                    messages: &messages
                )
                appendLanguageAttributeMessages(for: element, locations: locations, messages: &messages)
                appendDateTimeAttributeMessages(for: element, locations: locations, messages: &messages)
                appendInputAttributeMessages(for: element, idElementNames: idElementNames, locations: locations, messages: &messages)
                appendImageMessages(for: element, stack: stack, anchorHrefStack: anchorHrefStack, mapNames: mapNames, locations: locations, messages: &messages)
                appendEmbeddedContentMessages(for: element, locations: locations, messages: &messages)
                appendMeterMessages(for: element, locations: locations, messages: &messages)
                appendProgressMessages(for: element, locations: locations, messages: &messages)
                appendTextareaMessages(for: element, locations: locations, messages: &messages)
                appendSelectAttributeMessages(for: element, locations: locations, messages: &messages)
                appendSelectChildMessages(for: element, parent: parent, selectStack: selectStack, locations: locations, messages: &messages)
                appendTrackMessages(for: element, mediaStack: &mediaStack, locations: locations, messages: &messages)
                appendScriptAttributeMessages(for: element, locations: locations, messages: &messages)
                appendStyleElementMessages(for: element, parent: parent, locations: locations, messages: &messages)
                appendMediaAttributeMessages(for: element, locations: locations, messages: &messages)
                appendResponsiveImageMessages(for: element, stack: stack, locations: locations, messages: &messages)
                appendLabelDescendantMessages(for: element, labelStack: &labelStack, locations: locations, messages: &messages)
                if parent == "picture", let pictureIndex = pictureStack.indices.last {
                    appendPictureChildMessages(for: element, state: &pictureStack[pictureIndex], locations: locations, messages: &messages)
                }
                if element.name == "figcaption", let figureIndex = figureStack.indices.last {
                    if figureStack[figureIndex].figcaptionCount > 0 {
                        appendMessage("Element \u{201c}figcaption\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context.", for: element, locations: locations, messages: &messages)
                    }
                    figureStack[figureIndex].figcaptionCount += 1
                    figureStack[figureIndex].sawFigcaption = true
                    if figureStack[figureIndex].hasRole, !figureStack[figureIndex].reportedRoleWithFigcaption {
                        appendMessage("A \u{201c}figure\u{201d} element with a \u{201c}figcaption\u{201d} descendant must not have a \u{201c}role\u{201d} attribute.", for: figureStack[figureIndex].element, locations: locations, messages: &messages)
                        figureStack[figureIndex].reportedRoleWithFigcaption = true
                    }
                } else if parent == "figure", let figureIndex = figureStack.indices.last, figureStack[figureIndex].sawFigcaption {
                    appendMessage("Element \u{201c}\(element.name)\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context.", for: element, locations: locations, messages: &messages)
                }
                if element.name == "caption", stack.contains("figure"), stack.contains("table") {
                    appendWarningMessage("When a \u{201c}table\u{201d} element is the only content in a \u{201c}figure\u{201d} element other than the \u{201c}figcaption\u{201d}, the \u{201c}caption\u{201d} element should be omitted in favor of the \u{201c}figcaption\u{201d}.", for: element, locations: locations, messages: &messages)
                }
                if element.name == "audio" || element.name == "video" {
                    mediaStack.append(MediaState(element: element))
                }
                if element.name == "select" {
                    selectStack.append(SelectState(element: element))
                }
                if element.name == "option", let selectIndex = selectStack.indices.last {
                    selectStack[selectIndex].optionCount += 1
                    if element.hasAttribute("selected") {
                        selectStack[selectIndex].selectedOptionCount += 1
                    }
                    if selectStack[selectIndex].optionCount == 1 {
                        selectStack[selectIndex].firstOptionValue = element.attributeValue("value")
                    }
                }
                if element.name == "option" {
                    optionStack.append(OptionState(element: element, hasLabel: element.hasAttribute("label")))
                }
                if parent == "details", let detailsIndex = detailsStack.indices.last {
                    if element.name == "summary" {
                        if detailsStack[detailsIndex].sawSummary {
                            appendMessage("Element \u{201c}summary\u{201d} not allowed as child of \u{201c}details\u{201d} in this context.", for: element, locations: locations, messages: &messages)
                        } else if detailsStack[detailsIndex].sawNonSummaryChild, !detailsStack[detailsIndex].reportedMissingSummary {
                            appendMessage("Element \u{201c}details\u{201d} is missing a required instance of child element \u{201c}summary\u{201d}.", for: detailsStack[detailsIndex].element, locations: locations, messages: &messages)
                            detailsStack[detailsIndex].reportedMissingSummary = true
                        }
                        detailsStack[detailsIndex].sawSummary = true
                    } else if !Self.metadataElements.contains(element.name) {
                        detailsStack[detailsIndex].sawNonSummaryChild = true
                    }
                }
                if element.name == "script" {
                    scriptContent = scriptContentState(for: element)
                }
                if element.name == "style" {
                    styleContent = StyleContentState(element: element)
                }
                if element.name == "title" {
                    sawTitle = true
                    titleCapture = TitleCapture(element: element)
                }
                if element.name == "picture" {
                    pictureStack.append(PictureState(element: element))
                }
                if element.name == "figure" {
                    figureStack.append(FigureState(element: element, hasRole: element.hasAttribute("role")))
                }
                if element.name == "details" {
                    detailsStack.append(DetailsState(element: element))
                }
                if element.name == "ruby" {
                    rubyStack.append(RubyState(element: element))
                }
                if element.name == "optgroup" {
                    optgroupStack.append(OptgroupState(element: element, hasLabel: element.hasAttribute("label")))
                }
                if element.name == "article" || element.name == "section" {
                    sectioningStack.append(SectioningState(element: element))
                }
                if element.name == "label" {
                    labelStack.append(LabelState(
                        element: element,
                        forValue: element.attributeValue("for"),
                        hasRole: element.hasAttribute("role"),
                        hasAriaLabel: element.hasAttribute("aria-label"),
                        hasAriaHidden: element.hasAttribute("aria-hidden")
                    ))
                }
                updateBaseState(afterStarting: element, sawBodyContentBeforeBase: &sawBodyContentBeforeBase, sawBaseBlockingElement: &sawBaseBlockingElement)
                stack.append(element.name)
                roleStack.append(role)
                anchorHrefStack.append(element.name == "a" && element.hasAttribute("href"))
            case let .endElement(name, _, _):
                if name == "script", let content = scriptContent {
                    appendScriptContentMessages(content, locations: locations, messages: &messages)
                    scriptContent = nil
                }
                if name == "style", let content = styleContent {
                    appendStyleContentMessages(content, locations: locations, messages: &messages)
                    styleContent = nil
                }
                if name == "select", let state = selectStack.popLast() {
                    appendSelectMessages(state, locations: locations, messages: &messages)
                }
                if name == "option", let state = optionStack.popLast() {
                    appendOptionMessages(state, locations: locations, messages: &messages)
                }
                if name == "picture", let state = pictureStack.popLast() {
                    appendPictureMessages(state, locations: locations, messages: &messages)
                }
                if name == "figure", !figureStack.isEmpty {
                    _ = figureStack.popLast()
                }
                if name == "audio" || name == "video", !mediaStack.isEmpty {
                    _ = mediaStack.popLast()
                }
                if name == "details", let state = detailsStack.popLast(), state.sawNonSummaryChild, !state.sawSummary, !state.reportedMissingSummary {
                    appendMessage("Element \u{201c}details\u{201d} is missing a required instance of child element \u{201c}summary\u{201d}.", for: state.element, locations: locations, messages: &messages)
                }
                if (name == "article" || name == "section"), let state = sectioningStack.popLast(), !state.hasHeading {
                    appendSectioningHeadingWarning(for: state.element, locations: locations, messages: &messages)
                }
                if Self.headingElements.contains(name), let state = headingStack.popLast() {
                    appendHeadingMessages(state, headingLevels: &headingLevels, firstHeadingElement: &firstHeadingElement, locations: locations, messages: &messages)
                }
                if name == "ruby", let state = rubyStack.popLast() {
                    appendRubyMessages(state, locations: locations, messages: &messages)
                }
                if name == "optgroup", let state = optgroupStack.popLast() {
                    appendOptgroupMessages(state, locations: locations, messages: &messages)
                }
                if name == "title", let capture = titleCapture {
                    appendTitleMessages(capture, locations: locations, messages: &messages)
                    titleCapture = nil
                }
                if name == "label", !labelStack.isEmpty {
                    _ = labelStack.popLast()
                }
                if let index = stack.lastIndex(of: name) {
                    stack.removeSubrange(index...)
                    roleStack.removeSubrange(index...)
                    anchorHrefStack.removeSubrange(index...)
                }
            case let .characters(content, range):
                if scriptContent != nil {
                    scriptContent?.content += content
                }
                if styleContent != nil {
                    styleContent?.content += content
                }
                if let selectIndex = selectStack.indices.last,
                   selectStack[selectIndex].optionCount == 1,
                   stack.contains("option") {
                    selectStack[selectIndex].firstOptionText += content
                }
                if let optionIndex = optionStack.indices.last {
                    optionStack[optionIndex].text += content
                }
                for index in headingStack.indices {
                    headingStack[index].text += content
                }
                if stack.last == "ruby", !content.unicodeScalars.allSatisfy(isASCIIWhitespace), let rubyIndex = rubyStack.indices.last {
                    rubyStack[rubyIndex].sawBaseContent = true
                }
                if stack.last == "picture", pictureStack.indices.last != nil, !content.unicodeScalars.allSatisfy(isASCIIWhitespace) {
                    appendMessage(
                        "Text not allowed in \u{201c}picture\u{201d} in this context.",
                        range: range,
                        locations: locations,
                        messages: &messages
                    )
                }
                if stack.last == "figure", let figureIndex = figureStack.indices.last,
                   figureStack[figureIndex].sawFigcaption,
                   !content.unicodeScalars.allSatisfy(isASCIIWhitespace) {
                    appendMessage(
                        "Text not allowed in \u{201c}figure\u{201d} in this context.",
                        range: range,
                        locations: locations,
                        messages: &messages
                    )
                }
                if stack.contains("iframe"), !content.unicodeScalars.allSatisfy(isASCIIWhitespace) {
                    appendMessage(
                        "Text not allowed in \u{201c}iframe\u{201d} in this context.",
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
        if let activeRoleTabElement, !sawRoleTabpanel {
            appendMessage("Every active \u{201c}role=tab\u{201d} element must have a corresponding \u{201c}role=tabpanel\u{201d} element.", for: activeRoleTabElement, locations: locations, messages: &messages)
        }
        if !headingLevels.isEmpty, !headingLevels.contains(1), let firstHeadingElement {
            appendWarningMessage("This document has heading elements but none of them has a computed heading level of 1.", for: firstHeadingElement, locations: locations, messages: &messages)
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

    private func idLabelableElementNames(in document: HTMLParsedDocument) -> [String: String] {
        var result: [String: String] = [:]
        for event in document.events {
            guard case let .startElement(element) = event,
                  let id = element.attributeValue("id"),
                  !id.isEmpty,
                  isLabelableElement(element) else {
                continue
            }
            result[id] = element.name
        }
        return result
    }

    private func mapNames(in document: HTMLParsedDocument) -> Set<String> {
        var result: Set<String> = []
        for event in document.events {
            guard case let .startElement(element) = event,
                  element.name == "map",
                  let name = element.attributeValue("name"),
                  !name.isEmpty else {
                continue
            }
            result.insert(name)
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

    private struct SelectState {
        var element: HTMLStartElement
        var optionCount = 0
        var selectedOptionCount = 0
        var firstOptionValue: String?
        var firstOptionText = ""
    }

    private struct OptionState {
        var element: HTMLStartElement
        var hasLabel: Bool
        var text = ""
    }

    private struct FigureState {
        var element: HTMLStartElement
        var hasRole: Bool
        var figcaptionCount = 0
        var sawFigcaption = false
        var reportedRoleWithFigcaption = false
    }

    private struct DetailsState {
        var element: HTMLStartElement
        var sawSummary = false
        var sawNonSummaryChild = false
        var reportedMissingSummary = false
    }

    private struct SectioningState {
        var element: HTMLStartElement
        var hasHeading = false
    }

    private struct HeadingState {
        var element: HTMLStartElement
        var level: Int
        var text = ""
    }

    private struct RubyState {
        var element: HTMLStartElement
        var directChildNames: [String] = []
        var sawBaseContent = false
    }

    private struct OptgroupState {
        var element: HTMLStartElement
        var hasLabel: Bool
        var sawLegend = false
    }

    private struct LabelState {
        var element: HTMLStartElement
        var forValue: String?
        var hasRole: Bool
        var hasAriaLabel: Bool
        var hasAriaHidden: Bool
        var labelableDescendantCount = 0
        var reportedMultipleDescendants = false
        var reportedForMismatch = false
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
        } else if element.name == "a", element.hasAttribute("media") {
            disallowed = ["media"]
        } else if element.name == "area" {
            var attributes: Set<String> = []
            if element.hasAttribute("media") {
                attributes.insert("media")
            }
            if normalizedAttributeValue("shape", for: element) == "default", element.hasAttribute("coords") {
                attributes.insert("coords")
            }
            disallowed = attributes
        } else if element.name == "iframe" {
            disallowed = Set(["allowpaymentrequest", "seamless"].filter { element.hasAttribute($0) })
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

    private func appendElementSpecificMessages(
        for element: HTMLStartElement,
        stack: [String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.name == "a", element.hasAttribute("name") {
            appendWarningMessage("The \u{201c}name\u{201d} attribute on the \u{201c}a\u{201d} element is obsolete. Consider putting an \u{201c}id\u{201d} attribute on the nearest container instead.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "a", element.hasAttribute("href"), stack.contains("button") {
            appendMessage("The element \u{201c}a\u{201d} with the attribute \u{201c}href\u{201d} must not appear as a descendant of the \u{201c}button\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "area", let type = element.attributeValue("type"), !isValidMIMEType(type) {
            appendBadAttributeValue(type, attribute: "type", for: element, locations: locations, messages: &messages)
        }
        if element.name == "link", let type = element.attributeValue("type"), !isValidMIMEType(type) {
            appendBadAttributeValue(type, attribute: "type", for: element, locations: locations, messages: &messages)
        }
        if element.name == "audio", let loading = element.attributeValue("loading"), loading.lowercased() != "lazy" {
            appendBadAttributeValue(loading, attribute: "loading", for: element, locations: locations, messages: &messages)
        }
        if element.name == "video", let loading = element.attributeValue("loading"), loading.lowercased() != "lazy" {
            appendBadAttributeValue(loading, attribute: "loading", for: element, locations: locations, messages: &messages)
        }
        if element.name == "audio", element.hasAttribute("controls"), stack.contains("button") {
            appendMessage("The element \u{201c}audio\u{201d} with the attribute \u{201c}controls\u{201d} must not appear as a descendant of the \u{201c}button\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "form", let acceptCharset = element.attributeValue("accept-charset"), acceptCharset.lowercased() != "utf-8" {
            appendMessage("The only allowed value for the \u{201c}accept-charset\u{201d} attribute for the \u{201c}form\u{201d} element is \u{201c}utf-8\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "ol", let start = element.attributeValue("start"), !isValidInteger(start) {
            appendBadAttributeValue(start, attribute: "start", for: element, locations: locations, messages: &messages)
        }
        if element.name == "rb" {
            appendInfoMessage("Not all browsers position items appropriately when \"tabular markup\" is used with the \u{201c}rb\u{201d} element. See https://www.w3.org/International/articles/ruby/markup.en.html#visual for more guidance.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "rtc" {
            appendInfoMessage("Not all browsers position items appropriately when the \u{201c}rtc\u{201d} element is used. See https://www.w3.org/International/articles/ruby/markup.en.html#visual for more guidance.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "template",
           let assignment = element.attributeValue("shadowrootslotassignment"),
           !Self.shadowRootSlotAssignmentValues.contains(assignment.lowercased()) {
            appendBadAttributeValue(assignment, attribute: "shadowrootslotassignment", for: element, locations: locations, messages: &messages)
        }
        if element.name == "address", stack.contains("address") {
            appendMessage("The element \u{201c}address\u{201d} must not appear as a descendant of the \u{201c}address\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        if element.name.contains("-"), element.hasAttribute("is") {
            appendMessage("Autonomous custom elements must not specify the \u{201c}is\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "footer" || element.name == "header",
           let ancestor = stack.last(where: { $0 == "footer" || $0 == "header" }) {
            appendMessage("The element \u{201c}\(element.name)\u{201d} must not appear as a descendant of the \u{201c}\(ancestor)\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendHeadingMessages(
        _ state: HeadingState,
        headingLevels: inout [Int],
        firstHeadingElement: inout HTMLStartElement?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let trimmedText = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty {
            appendWarningMessage("Empty heading.", for: state.element, locations: locations, messages: &messages)
            return
        }

        if firstHeadingElement == nil {
            firstHeadingElement = state.element
        }
        if let previousLevel = headingLevels.last, state.level > previousLevel + 1 {
            appendMessage("The heading \u{201c}\(state.element.name)\u{201d} (with computed level \(state.level)) follows the heading \u{201c}h\(previousLevel)\u{201d} (with computed level \(previousLevel)), skipping \(state.level - previousLevel - 1) heading level.", for: state.element, locations: locations, messages: &messages)
        }
        headingLevels.append(state.level)
    }

    private func appendRubyMessages(
        _ state: RubyState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if !state.sawBaseContent && state.directChildNames.isEmpty {
            appendMessage("Element \u{201c}ruby\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}rp\u{201d}, \u{201c}rt\u{201d}, \u{201c}rtc\u{201d}.", for: state.element, locations: locations, messages: &messages)
        } else if !state.sawBaseContent && state.directChildNames.contains("rt") {
            appendMessage("Element \u{201c}ruby\u{201d} is missing a required instance of child element \u{201c}rt\u{201d}.", for: state.element, locations: locations, messages: &messages)
        }
    }

    private func appendOptgroupMessages(
        _ state: OptgroupState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if !state.hasLabel && !state.sawLegend {
            appendMessage("An \u{201c}optgroup\u{201d} element with no child \u{201c}legend\u{201d} element must have a \u{201c}label\u{201d} attribute.", for: state.element, locations: locations, messages: &messages)
        }
    }

    private func appendSectioningHeadingWarning(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.name == "article" {
            appendWarningMessage("Article lacks heading. Consider using \u{201c}h2\u{201d}-\u{201c}h6\u{201d} elements to add identifying headings to all articles.", for: element, locations: locations, messages: &messages)
        } else if element.name == "section" {
            appendWarningMessage("Section lacks heading. Consider using \u{201c}h2\u{201d}-\u{201c}h6\u{201d} elements to add identifying headings to all sections, or else use a \u{201c}div\u{201d} element instead for any cases where no heading is needed.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendLanguageAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let lang = element.attributeValue("lang") {
            if lang.isEmpty {
                // The empty string is an allowed language value.
            } else if Self.deprecatedLanguageTags.contains(lang.lowercased()) {
                appendWarningMessage(
                    "Bad value \u{201c}\(lang)\u{201d} for attribute \u{201c}lang\u{201d} on element \u{201c}\(element.name)\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else if Self.invalidLanguageTags.contains(lang.lowercased()) || !isPlausibleLanguageTag(lang) {
                appendBadAttributeValue(lang, attribute: "lang", for: element, locations: locations, messages: &messages)
            } else if lang.lowercased() == "ja-jpan" {
                appendWarningMessage(
                    "Bad value \u{201c}\(lang)\u{201d} for attribute \u{201c}lang\u{201d} on element \u{201c}\(element.name)\u{201d}.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if let hreflang = element.attributeValue("hreflang"), !isPlausibleLanguageTag(hreflang) {
            appendBadAttributeValue(hreflang, attribute: "hreflang", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendDatatypeAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let id = element.attributeValue("id"), !isValidIDValue(id) {
            appendBadAttributeValue(id, attribute: "id", for: element, locations: locations, messages: &messages)
        }

        if Self.browsingContextTargetElements.contains(element.name),
           let target = element.attributeValue("target"),
           !isValidBrowsingContextNameOrKeyword(target) {
            appendBadAttributeValue(target, attribute: "target", for: element, locations: locations, messages: &messages)
        }

        if let customElementName = element.attributeValue("is"),
           !isValidCustomElementName(customElementName) {
            appendBadAttributeValue(customElementName, attribute: "is", for: element, locations: locations, messages: &messages)
        }

        if element.name == "iframe", let sandbox = element.attributeValue("sandbox") {
            appendSandboxMessages(sandbox, for: element, locations: locations, messages: &messages)
        }
    }

    private func appendGlobalAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let accesskey = element.attributeValue("accesskey"), !isValidAccesskeyValue(accesskey) {
            appendBadAttributeValue(accesskey, attribute: "accesskey", for: element, locations: locations, messages: &messages)
        }
        if element.attributes.contains(where: { $0.name == "data-" }) {
            appendAttributeNotAllowed("data-", for: element, locations: locations, messages: &messages)
        }
        if element.name == "div", element.hasAttribute("name") {
            appendAttributeNotAllowed("name", for: element, locations: locations, messages: &messages)
        }
        if let enterkeyhint = element.attributeValue("enterkeyhint"),
           !Self.enterKeyHintValues.contains(enterkeyhint.lowercased()) {
            appendBadAttributeValue(enterkeyhint, attribute: "enterkeyhint", for: element, locations: locations, messages: &messages)
        }
        if let headingOffset = element.attributeValue("headingoffset"), !isValidHeadingOffset(headingOffset) {
            appendMessage(
                "The value of the \u{201c}headingoffset\u{201d} attribute must be a number between \u{201c}0\u{201d} and \u{201c}8\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if let popover = element.attributeValue("popover"), !isValidPopoverValue(popover) {
            appendBadAttributeValue(popover, attribute: "popover", for: element, locations: locations, messages: &messages)
        }
        if let spellcheck = element.attributeValue("spellcheck"), !isValidSpellcheckValue(spellcheck) {
            appendBadAttributeValue(spellcheck, attribute: "spellcheck", for: element, locations: locations, messages: &messages)
        }
        appendRelTypoMessages(for: element, locations: locations, messages: &messages)
    }

    private func appendBaseMessages(
        for element: HTMLStartElement,
        sawBodyContentBeforeBase: Bool,
        sawBaseBlockingElement: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "base" else { return }
        if !element.hasAttribute("href"), !element.hasAttribute("target") {
            appendMessage(
                "Element \u{201c}base\u{201d} is missing one or more of the following attributes: \u{201c}href\u{201d}, \u{201c}target\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if sawBodyContentBeforeBase {
            appendMessage("Element \u{201c}base\u{201d} not allowed as child of \u{201c}body\u{201d} in this context.", for: element, locations: locations, messages: &messages)
        } else if sawBaseBlockingElement {
            appendMessage("The \u{201c}base\u{201d} element must come before any \u{201c}link\u{201d} or \u{201c}script\u{201d} elements in the document.", for: element, locations: locations, messages: &messages)
        }
    }

    private func updateBaseState(
        afterStarting element: HTMLStartElement,
        sawBodyContentBeforeBase: inout Bool,
        sawBaseBlockingElement: inout Bool
    ) {
        if element.name == "link" || element.name == "script" {
            sawBaseBlockingElement = true
        }
        if startsBodyContentBeforeBase(element) {
            sawBodyContentBeforeBase = true
        }
    }

    private func startsBodyContentBeforeBase(_ element: HTMLStartElement) -> Bool {
        !Self.headLikeElementsBeforeBase.contains(element.name)
    }

    private func appendStructuralAssertionMessages(
        for element: HTMLStartElement,
        stack: [String],
        mapNames: Set<String>,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        switch element.name {
        case "area":
            if !stack.contains("map") {
                appendMessage("The \u{201c}area\u{201d} element must have a \u{201c}map\u{201d} ancestor.", for: element, locations: locations, messages: &messages)
            }
        case "bdo":
            let dir = element.attributeValue("dir")?.lowercased()
            if dir == nil {
                appendMessage("Element \u{201c}bdo\u{201d} must have attribute \u{201c}dir\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if dir == "auto" {
                appendMessage("The value of \u{201c}dir\u{201d} attribute for the \u{201c}bdo\u{201d} element must not be \u{201c}auto\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        case "input":
            if inputType(for: element) == "file", element.hasAttribute("value") {
                appendAttributeNotAllowed("value", for: element, locations: locations, messages: &messages)
            }
        case "li":
            appendListItemMessages(for: element, parent: stack.last, locations: locations, messages: &messages)
        case "main":
            if let prohibitedAncestor = stack.reversed().first(where: { Self.mainProhibitedAncestors.contains($0) }) {
                appendMessage("The \u{201c}main\u{201d} element must not appear as a descendant of the \u{201c}\(prohibitedAncestor)\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
        case "map":
            if let id = element.attributeValue("id"),
               let name = element.attributeValue("name"),
               id != name {
                appendMessage("The \u{201c}id\u{201d} attribute on a \u{201c}map\u{201d} element must have an the same value as the \u{201c}name\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
        default:
            break
        }
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

    private func appendARIAAttributeMessages(
        for element: HTMLStartElement,
        role: String?,
        idElementNames: [String: String],
        stack: [String],
        roleStack: [String?],
        labelStack: [LabelState],
        visibleMainCount: inout Int,
        visibleRoleMainCount: inout Int,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        appendRoleTokenMessages(for: element, locations: locations, messages: &messages)
        appendRoleEffectMessages(for: element, role: role, locations: locations, messages: &messages)
        appendUnnecessaryRoleMessages(for: element, role: role, locations: locations, messages: &messages)
        appendARIANamingMessages(for: element, role: role, locations: locations, messages: &messages)
        appendSelectRoleMessages(for: element, role: role, locations: locations, messages: &messages)
        appendSummaryARIAMessages(for: element, stack: stack, locations: locations, messages: &messages)
        appendARIAPropertyMessages(for: element, role: role, idElementNames: idElementNames, locations: locations, messages: &messages)
        appendImageARIAMessages(for: element, role: role, locations: locations, messages: &messages)
        appendLabelARIAAssociationMessages(for: element, idElementNames: idElementNames, labelStack: labelStack, locations: locations, messages: &messages)
        appendARIAStructureMessages(for: element, role: role, stack: stack, roleStack: roleStack, locations: locations, messages: &messages)

        if element.name == "main", !isHidden(element) {
            visibleMainCount += 1
            if visibleMainCount > 1 {
                appendMessage("A document must not include more than one visible \u{201c}main\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            if visibleRoleMainCount > 0 {
                appendWarningMessage("A document should not include more than one visible element with \u{201c}role=main\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        if role == "main", !isHidden(element) {
            visibleRoleMainCount += 1
            if visibleRoleMainCount > 1 || element.name == "main" || visibleMainCount > 0 {
                appendWarningMessage("A document should not include more than one visible element with \u{201c}role=main\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendRoleTokenMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let tokens = roleTokens(for: element)
        guard !tokens.isEmpty else { return }
        var sawRecognized = false
        for token in tokens {
            if !Self.nonAbstractARIARoles.contains(token) {
                appendMessage(
                    "Discarding unrecognized token \u{201c}\(token)\u{201d} from value of attribute \u{201c}role\u{201d}. Browsers ignore any token that is not a defined ARIA non-abstract role.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else if sawRecognized {
                appendInfoMessage(
                    "Discarding superfluous token \u{201c}\(token)\u{201d} from value of attribute \u{201c}role\u{201d}. Browsers only process the first token found that is a defined ARIA non-abstract role.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else {
                sawRecognized = true
            }
        }
        if tokens.first == "directory" {
            appendWarningMessage("Bad value \u{201c}directory\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}\(element.name)\u{201d}.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendRoleEffectMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard role == "none" || role == "presentation" else { return }
        let hasTabindex = element.hasAttribute("tabindex")
        let hasGlobalARIA = element.attributes.contains { attribute in
            attribute.name.hasPrefix("aria-") && attribute.name != "aria-hidden"
        }
        guard hasTabindex || hasGlobalARIA else { return }

        if hasTabindex, hasGlobalARIA {
            appendWarningMessage("The \u{201c}\(role ?? "")\u{201d} role does not affect elements that have a \u{201c}tabindex\u{201d} attribute and global ARIA attributes.", for: element, locations: locations, messages: &messages)
        } else if hasTabindex {
            appendWarningMessage("The \u{201c}\(role ?? "")\u{201d} role does not affect elements that have a \u{201c}tabindex\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        } else {
            appendWarningMessage("The \u{201c}\(role ?? "")\u{201d} role does not affect elements that have global ARIA attributes.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendUnnecessaryRoleMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let role else { return }
        if element.name == "math", role == "math" {
            appendWarningMessage("Element \u{201c}math\u{201d} does not need a \u{201c}role\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            return
        }
        if let expected = unnecessaryRole(for: element), expected == role {
            if element.name == "a", role == "link" {
                appendWarningMessage("The \u{201c}link\u{201d} role is unnecessary for element \u{201c}a\u{201d} with attribute \u{201c}href\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if element.name == "select", role == "listbox" {
                appendWarningMessage("The \u{201c}listbox\u{201d} role is unnecessary for element \u{201c}select\u{201d} with a \u{201c}multiple\u{201d} attribute or with a \u{201c}size\u{201d} attribute whose value is greater than 1.", for: element, locations: locations, messages: &messages)
            } else if element.name == "select", role == "combobox" {
                appendWarningMessage("The \u{201c}combobox\u{201d} role is unnecessary for element \u{201c}select\u{201d} without a \u{201c}multiple\u{201d} attribute and without a \u{201c}size\u{201d} attribute whose value is greater than 1.", for: element, locations: locations, messages: &messages)
            } else if element.name == "input", role == "textbox" || role == "searchbox" {
                appendWarningMessage("The \u{201c}\(role)\u{201d} role is unnecessary for an \u{201c}input\u{201d} element that has no \u{201c}list\u{201d} attribute and whose type is \u{201c}\(inputType(for: element))\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if element.name == "input", role == "spinbutton" {
                appendWarningMessage("The \u{201c}spinbutton\u{201d} role is unnecessary for element \u{201c}input\u{201d} whose type is \u{201c}number\u{201d}.", for: element, locations: locations, messages: &messages)
            } else {
                appendWarningMessage("The \u{201c}\(role)\u{201d} role is unnecessary for element \u{201c}\(element.name)\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendARIANamingMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let isNameProhibitedElement = Self.ariaNamingProhibitedElements.contains(element.name) || element.name.contains("-")
        guard isNameProhibitedElement else { return }
        if let role, !Self.ariaNamingProhibitedRoles.contains(role) {
            return
        }
        for attribute in ["aria-label", "aria-labelledby", "aria-braillelabel"] where element.hasAttribute(attribute) {
            appendMessage(
                "The \u{201c}\(attribute)\u{201d} attribute must not be specified on any \u{201c}\(element.name)\u{201d} element unless the element has a \u{201c}role\u{201d} value other than \u{201c}caption\u{201d}, \u{201c}code\u{201d}, \u{201c}deletion\u{201d}, \u{201c}emphasis\u{201d}, \u{201c}generic\u{201d}, \u{201c}insertion\u{201d}, \u{201c}paragraph\u{201d}, \u{201c}presentation\u{201d}, \u{201c}strong\u{201d}, \u{201c}subscript\u{201d}, or \u{201c}superscript\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendSelectRoleMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "select", let role else { return }
        if allowsMultipleSelection(element), role != "listbox" {
            appendBadAttributeValue(role, attribute: "role", for: element, locations: locations, messages: &messages)
        } else if isDropDownSelect(element), role == "listbox" {
            appendMessage("The \u{201c}listbox\u{201d} role is not allowed for element \u{201c}select\u{201d} without a \u{201c}multiple\u{201d} attribute and without a \u{201c}size\u{201d} attribute whose value is greater than 1.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendSummaryARIAMessages(
        for element: HTMLStartElement,
        stack: [String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "summary", stack.last == "details" else { return }
        if element.hasAttribute("role") {
            appendMessage("The \u{201c}role\u{201d} attribute must not be used on any \u{201c}summary\u{201d} element that is a summary for its parent \u{201c}details\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-expanded") {
            appendMessage("Element \u{201c}summary\u{201d} is missing one or more of the following attributes: \u{201c}aria-checked\u{201d}, \u{201c}aria-level\u{201d}, \u{201c}role\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-pressed") {
            appendMessage("Element \u{201c}summary\u{201d} is missing required attribute \u{201c}role\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-selected") {
            appendMessage("Element \u{201c}summary\u{201d} is missing one or more of the following attributes: \u{201c}aria-checked\u{201d}, \u{201c}role\u{201d}.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendARIAPropertyMessages(
        for element: HTMLStartElement,
        role: String?,
        idElementNames: [String: String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.name == "meta", element.hasAttribute("aria-hidden") {
            appendAttributeNotAllowed("aria-hidden", for: element, locations: locations, messages: &messages)
        }
        if (element.name == "br" || element.name == "wbr"), element.hasAttribute("aria-atomic") {
            appendAttributeNotAllowed("aria-atomic", for: element, locations: locations, messages: &messages)
        }
        if (element.name == "br" || element.name == "wbr"), role == "separator" {
            appendBadAttributeValue("separator", attribute: "role", for: element, locations: locations, messages: &messages)
        }
        if element.name == "body", normalizedAttributeValue("aria-hidden", for: element) == "true" {
            appendMessage("\u{201c}aria-hidden=true\u{201d} must not be used on the \u{201c}body\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        if normalizedAttributeValue("aria-hidden", for: element) == "true",
           normalizedAttributeValue("hidden", for: element) == "until-found" {
            appendMessage("Attribute \u{201c}aria-hidden\u{201d} with value \u{201c}true\u{201d} must not be specified on elements with \u{201c}hidden\u{201d} attribute value \u{201c}until-found\u{201d}. This combination prevents content from being accessible to assistive technology when revealed through search.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "input", inputType(for: element) == "hidden", element.hasAttribute("aria-hidden") {
            appendMessage("The \u{201c}aria-hidden\u{201d} attribute must not be specified on an \u{201c}input\u{201d} element whose \u{201c}type\u{201d} attribute has the value \u{201c}hidden\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-expanded"), element.hasAttribute("command") {
            appendMessage("The \u{201c}aria-expanded\u{201d} attribute must not be used on any element which has a \u{201c}command\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-expanded"), element.hasAttribute("popovertarget") {
            appendMessage("The \u{201c}aria-expanded\u{201d} attribute must not be used on any element which has a \u{201c}popovertarget\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
        if normalizedAttributeValue("aria-disabled", for: element) == "true", element.hasAttribute("disabled") {
            appendWarningMessage("Attribute \u{201c}aria-disabled\u{201d} is unnecessary for elements that have attribute \u{201c}disabled\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "a", element.hasAttribute("href"), normalizedAttributeValue("aria-disabled", for: element) == "true" {
            appendWarningMessage("An \u{201c}aria-disabled\u{201d} attribute whose value is \u{201c}true\u{201d} should not be specified on an \u{201c}a\u{201d} element that has an \u{201c}href\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-dropeffect") {
            appendWarningMessage("The \u{201c}aria-dropeffect\u{201d} attribute is deprecated and should not be used. Support for it is poor and is unlikely to improve.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-grabbed") {
            appendWarningMessage("The \u{201c}aria-grabbed\u{201d} attribute is deprecated and should not be used. Support for it is poor and is unlikely to improve.", for: element, locations: locations, messages: &messages)
        }
        if let active = element.attributeValue("aria-activedescendant"), idElementNames[active] == nil {
            appendMessage("The \u{201c}aria-activedescendant\u{201d} attribute references \u{201c}\(active)\u{201d}, which is not the ID of any element in this document.", for: element, locations: locations, messages: &messages)
        }
        appendARIAWidgetPropertyMessages(for: element, role: role, locations: locations, messages: &messages)
    }

    private func appendImageMessages(
        for element: HTMLStartElement,
        stack: [String],
        anchorHrefStack: [Bool],
        mapNames: Set<String>,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "img" else { return }

        for attribute in ["height", "width"] {
            if let value = element.attributeValue(attribute), !isValidNonNegativeInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
            }
        }

        if element.hasAttribute("border") {
            appendWarningMessage("The \u{201c}border\u{201d} attribute on the \u{201c}img\u{201d} element is obsolete. Consider specifying \u{201c}img { border: 0; }\u{201d} in CSS instead.", for: element, locations: locations, messages: &messages)
        }

        if element.hasAttribute("controls") {
            let controls = element.attributeValue("controls") ?? ""
            if !controls.isEmpty && controls.lowercased() != "controls" {
                appendBadAttributeValue(controls, attribute: "controls", for: element, locations: locations, messages: &messages)
            }
            if element.attributeValue("alt")?.isEmpty != false {
                appendMessage("The \u{201c}controls\u{201d} attribute must not be specified on an \u{201c}img\u{201d} element that does not have an \u{201c}alt\u{201d} attribute, or whose \u{201c}alt\u{201d} attribute\u{2019}s value is the empty string.", for: element, locations: locations, messages: &messages)
            }
        }

        if element.hasAttribute("ismap"), !anchorHrefStack.contains(true) {
            appendMessage("The \u{201c}img\u{201d} element with the \u{201c}ismap\u{201d} attribute set must have an \u{201c}a\u{201d} ancestor with the \u{201c}href\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        }

        if let usemap = element.attributeValue("usemap") {
            if stack.contains("a") {
                appendMessage("The element \u{201c}img\u{201d} with the attribute \u{201c}usemap\u{201d} must not appear as a descendant of the \u{201c}a\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            if !usemap.hasPrefix("#") || usemap == "#" {
                appendBadAttributeValue(usemap, attribute: "usemap", for: element, locations: locations, messages: &messages)
            } else {
                let name = String(usemap.dropFirst())
                if !mapNames.contains(name) {
                    appendMessage("The hash-name reference in attribute \u{201c}usemap\u{201d} referred to \u{201c}\(name)\u{201d}, but there is no \u{201c}map\u{201d} element with a \u{201c}name\u{201d} attribute with that value.", for: element, locations: locations, messages: &messages)
                }
            }
        }
    }

    private func appendImageARIAMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "img" else { return }

        if element.hasAttribute("role"), element.attributeValue("alt") == "" {
            appendMessage("An \u{201c}img\u{201d} element with a \u{201c}role\u{201d} attribute must not have an \u{201c}alt\u{201d} attribute whose value is the empty string.", for: element, locations: locations, messages: &messages)
        }

        if let role, !Self.imgAllowedRoles.contains(role) {
            appendBadAttributeValue(role, attribute: "role", for: element, locations: locations, messages: &messages)
        }

        if element.hasAttribute("role"), !hasAccessibleName(element) {
            appendMessage("An \u{201c}img\u{201d} element with a \u{201c}role\u{201d} attribute must also have an accessible name (e.g., an \u{201c}alt\u{201d} attribute).", for: element, locations: locations, messages: &messages)
        }

        let hasRelevantARIA = element.attributes.contains { attribute in
            attribute.name.hasPrefix("aria-") && attribute.name != "aria-hidden"
        }
        if hasRelevantARIA, !hasAccessibleName(element) {
            appendMessage("An \u{201c}img\u{201d} element with any \u{201c}aria-*\u{201d} attributes other than \u{201c}aria-hidden\u{201d} must also have an accessible name. (e.g., an \u{201c}alt\u{201d} attribute).", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendLabelARIAAssociationMessages(
        for element: HTMLStartElement,
        idElementNames: [String: String],
        labelStack: [LabelState],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if isLabelableElement(element), let label = labelStack.last {
            if label.hasRole {
                appendMessage("The \u{201c}role\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element.", for: label.element, locations: locations, messages: &messages)
            }
            if label.hasAriaLabel {
                appendMessage("The \u{201c}aria-label\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element.", for: label.element, locations: locations, messages: &messages)
            }
        }

        if element.name == "label",
           let id = element.attributeValue("for"),
           let referencedElementName = idElementNames[id],
           isLabelableElement(name: referencedElementName) {
            if element.hasAttribute("role") {
                appendMessage("The \u{201c}role\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is associated with a labelable element.", for: element, locations: locations, messages: &messages)
            }
            if element.hasAttribute("aria-label") {
                appendMessage("The \u{201c}aria-label\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is associated with a labelable element.", for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendLabelForReferenceMessages(
        for element: HTMLStartElement,
        idLabelableElementNames: [String: String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "label",
              let forValue = element.attributeValue("for"),
              idLabelableElementNames[forValue] == nil else {
            return
        }
        appendMessage(
            "The value of the \u{201c}for\u{201d} attribute of the \u{201c}label\u{201d} element must be the ID of a non-hidden form control.",
            for: element,
            locations: locations,
            messages: &messages
        )
    }

    private func appendLabelDescendantMessages(
        for element: HTMLStartElement,
        labelStack: inout [LabelState],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard isLabelableElement(element),
              let index = labelStack.indices.last else {
            return
        }

        if labelStack[index].hasRole {
            appendMessage("The \u{201c}role\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element.", for: labelStack[index].element, locations: locations, messages: &messages)
        }
        if labelStack[index].hasAriaLabel {
            appendMessage("The \u{201c}aria-label\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element.", for: labelStack[index].element, locations: locations, messages: &messages)
        }
        if labelStack[index].hasAriaHidden {
            appendMessage("The \u{201c}aria-hidden\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element.", for: labelStack[index].element, locations: locations, messages: &messages)
        }

        labelStack[index].labelableDescendantCount += 1
        if labelStack[index].labelableDescendantCount > 1, !labelStack[index].reportedMultipleDescendants {
            appendMessage(
                "The \u{201c}label\u{201d} element may contain at most one \u{201c}button\u{201d}, \u{201c}input\u{201d}, \u{201c}meter\u{201d}, \u{201c}output\u{201d}, \u{201c}progress\u{201d}, \u{201c}select\u{201d}, or \u{201c}textarea\u{201d} descendant.",
                for: labelStack[index].element,
                locations: locations,
                messages: &messages
            )
            labelStack[index].reportedMultipleDescendants = true
        }

        if let forValue = labelStack[index].forValue,
           element.name == "input",
           element.attributeValue("id") != forValue,
           !labelStack[index].reportedForMismatch {
            appendMessage(
                "Any \u{201c}input\u{201d} descendant of a \u{201c}label\u{201d} element with a \u{201c}for\u{201d} attribute must have an ID value that matches that \u{201c}for\u{201d} attribute.",
                for: element,
                locations: locations,
                messages: &messages
            )
            labelStack[index].reportedForMismatch = true
        }
    }

    private func appendARIAWidgetPropertyMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.hasAttribute("aria-checked") {
            if element.name == "input", inputType(for: element) == "checkbox" || inputType(for: element) == "radio" {
                appendMessage("The \u{201c}aria-checked\u{201d} attribute must not be used on an \u{201c}input\u{201d} element which has a \u{201c}type\u{201d} attribute whose value is \u{201c}\(inputType(for: element))\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if role == nil || !Self.ariaCheckedRoles.contains(role ?? "") {
                appendAttributeNotAllowed("aria-checked", for: element, locations: locations, messages: &messages)
            }
        }
        if element.hasAttribute("aria-placeholder") {
            if element.hasAttribute("placeholder") {
                appendMessage("The \u{201c}aria-placeholder\u{201d} attribute must not be specified on elements that have a \u{201c}placeholder\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            } else if role != "textbox" && role != "searchbox" {
                appendAttributeNotAllowed("aria-placeholder", for: element, locations: locations, messages: &messages)
            }
        }
        if element.name == "output", element.hasAttribute("aria-pressed"), role == nil {
            appendMessage("Element \u{201c}output\u{201d} is missing required attribute \u{201c}role\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if normalizedAttributeValue("aria-readonly", for: element) == "true", role == nil {
            appendMessage("Element \u{201c}\(element.name)\u{201d} is missing one or more of the following attributes: \u{201c}aria-checked\u{201d}, \u{201c}aria-expanded\u{201d}, \u{201c}aria-valuenow\u{201d}, \u{201c}role\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-readonly"), role == nil || !Self.ariaReadonlyRoles.contains(role ?? "") {
            appendAttributeNotAllowed("aria-readonly", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("aria-selected") {
            if element.name == "option" {
                appendWarningMessage("The \u{201c}aria-selected\u{201d} attribute should not be used on the \u{201c}option\u{201d} element.", for: element, locations: locations, messages: &messages)
            } else if role == nil || !Self.ariaSelectedRoles.contains(role ?? "") {
                appendAttributeNotAllowed("aria-selected", for: element, locations: locations, messages: &messages)
            }
        }
        if element.hasAttribute("aria-multiselectable") {
            if element.name == "select" {
                appendWarningMessage("The \u{201c}aria-multiselectable\u{201d} attribute should not be used with the \u{201c}select \u{201d} element.", for: element, locations: locations, messages: &messages)
            } else if role == nil || !Self.ariaMultiselectableRoles.contains(role ?? "") {
                appendAttributeNotAllowed("aria-multiselectable", for: element, locations: locations, messages: &messages)
            }
        }
        if element.hasAttribute("aria-valuemin"), element.hasAttribute("min") {
            appendMessage("The \u{201c}aria-valuemin\u{201d} attribute must not be used on an element which has a \u{201c}min\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        } else if element.hasAttribute("aria-valuemin") {
            if element.name == "meter" {
                appendWarningMessage("The \u{201c}aria-valuemin\u{201d} attribute should not be used on a \u{201c}meter\u{201d} element.", for: element, locations: locations, messages: &messages)
            } else if element.name == "input", inputType(for: element) == "number" {
                appendWarningMessage("The \u{201c}aria-valuemin\u{201d} attribute should not be used on an \u{201c}input\u{201d} element which has a \u{201c}type\u{201d} attribute whose value is \u{201c}number\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if role == nil || !Self.ariaRangeRoles.contains(role ?? "") {
                appendAttributeNotAllowed("aria-valuemin", for: element, locations: locations, messages: &messages)
            }
        }
        if element.hasAttribute("aria-valuemax"), element.hasAttribute("max") {
            appendMessage("The \u{201c}aria-valuemax\u{201d} attribute must not be used on an element which has a \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        } else if element.hasAttribute("aria-valuemax") {
            if element.name == "input", inputType(for: element) == "number" {
                appendWarningMessage("The \u{201c}aria-valuemax\u{201d} attribute should not be used on an \u{201c}input\u{201d} element which has a \u{201c}type\u{201d} attribute whose value is \u{201c}number\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if role == nil || !Self.ariaRangeRoles.contains(role ?? "") {
                appendAttributeNotAllowed("aria-valuemax", for: element, locations: locations, messages: &messages)
            }
        }
        if role == "main" {
            for attribute in ["aria-disabled", "aria-haspopup", "aria-invalid"] where element.hasAttribute(attribute) {
                appendWarningMessage("The \u{201c}\(attribute)\u{201d} attribute should not be used on any element which has \u{201c}role=main\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        if role == "listbox", element.hasAttribute("aria-expanded") {
            appendAttributeNotAllowed("aria-expanded", for: element, locations: locations, messages: &messages)
        }
        if role == "listitem", element.hasAttribute("aria-level") {
            appendWarningMessage("The \u{201c}aria-level\u{201d} attribute should not be used on any element which has \u{201c}role=listitem\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "input",
           inputType(for: element) == "text",
           element.hasAttribute("list"),
           element.hasAttribute("aria-haspopup") {
            appendWarningMessage("The \u{201c}aria-haspopup\u{201d} attribute should not be used on an \u{201c}input\u{201d} element that has a \u{201c}list\u{201d} attribute and whose type is \u{201c}text\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "select", role == "combobox", !element.hasAttribute("aria-expanded") {
            appendMessage("Element \u{201c}select\u{201d} is missing required attribute \u{201c}aria-expanded\u{201d}.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendARIAStructureMessages(
        for element: HTMLStartElement,
        role: String?,
        stack: [String],
        roleStack: [String?],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if element.name == "a", element.hasAttribute("href"),
           let ancestorRole = roleStack.compactMap({ $0 }).last(where: { Self.prohibitedInteractiveAncestorRoles.contains($0) }) {
            appendMessage("The element \u{201c}a\u{201d} with the attribute \u{201c}href\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=\(ancestorRole)\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("tabindex"),
           let ancestorRole = roleStack.compactMap({ $0 }).last(where: { $0 == "option" || $0 == "tab" }) {
            appendMessage("An element with the attribute \u{201c}tabindex\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=\(ancestorRole)\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if let role, Self.headingProhibitedRoles.contains(role), stack.contains(where: { Self.headingElements.contains($0) }) {
            appendMessage("An element with the attribute \u{201c}role=\(role)\u{201d} must not appear as a descendant of an \u{201c}h1\u{201d}, \u{201c}h2\u{201d}, \u{201c}h3\u{201d}, \u{201c}h4\u{201d}, \u{201c}h5\u{201d}, or \u{201c}h6\u{201d} element.", for: element, locations: locations, messages: &messages)
        }
        if role == "option", !roleStack.contains(where: { $0 == "listbox" }) {
            appendMessage("An element with \u{201c}role=option\u{201d} must be contained in, or owned by, an element with the \u{201c}role\u{201d} value \u{201c}listbox\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if role == "cell", !roleStack.contains(where: { $0 == "row" }) {
            appendMessage("An element with \u{201c}role=cell\u{201d} must be contained in, or owned by, an element with the \u{201c}role\u{201d} value \u{201c}row\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if role == "row", !roleStack.contains(where: { $0 == "treegrid" || $0 == "grid" || $0 == "rowgroup" || $0 == "table" }) {
            appendMessage("An element with \u{201c}role=row\u{201d} must be contained in, or owned by, an element with the \u{201c}role\u{201d} value \u{201c}treegrid\u{201d}, \u{201c}grid\u{201d}, \u{201c}rowgroup\u{201d}, or \u{201c}table\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if role == "group", roleStack.last == "list" {
            appendMessage("An element with \u{201c}role=group\u{201d} must not be a child of an element with \u{201c}role=list\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "div", stack.last == "dl", let role, role != "presentation", role != "none" {
            appendMessage("A \u{201c}div\u{201d} child of a \u{201c}dl\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}presentation\u{201d} or \u{201c}none\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "li", let role {
            if roleStack.contains(where: { $0 == "listbox" || $0 == "list" }), role != "group", role != "option" {
                appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=listbox\u{201d} element or \u{201c}role=list\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}group\u{201d} or \u{201c}option\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if roleStack.contains(where: { $0 == "menu" || $0 == "menubar" }), !["group", "menuitem", "menuitemcheckbox", "menuitemradio", "separator"].contains(role) {
                appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=menu\u{201d} element or \u{201c}role=menubar\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}group\u{201d}, \u{201c}menuitem\u{201d}, \u{201c}menuitemcheckbox\u{201d}, \u{201c}menuitemradio\u{201d}, or \u{201c}separator\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if roleStack.contains(where: { $0 == "tablist" }), role != "tab" {
                appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=tablist\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}tab\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if roleStack.contains(where: { $0 == "tree" }), role != "treeitem" {
                appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=tree\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}treeitem\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        if roleStack.last == "group", let role {
            if roleStack.contains(where: { $0 == "menu" || $0 == "menubar" }),
               !["menuitem", "menuitemcheckbox", "menuitemradio"].contains(role) {
                appendMessage("An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=menu\u{201d} or \u{201c}role=menubar\u{201d} must contain only elements with \u{201c}role=menuitem\u{201d}, \u{201c}role=menuitemcheckbox\u{201d}, or \u{201c}role=menuitemradio\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if roleStack.contains(where: { $0 == "tree" }), role != "treeitem" {
                appendMessage("An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=tree\u{201d} must contain only elements with \u{201c}role=treeitem\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        if roleStack.last == "rowgroup", role != "row" {
            appendMessage("An element that is a child of an element with \u{201c}role=rowgroup\u{201d} must have \u{201c}role=row\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if let ancestorRole = roleStack.compactMap({ $0 }).last(where: { ["button", "img", "math", "progressbar", "separator", "slider"].contains($0) }) {
            if ancestorRole == "button", Self.headingElements.contains(element.name) {
                appendMessage("The element \u{201c}\(element.name)\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=button\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if ancestorRole == "button", isLabelableElement(element) {
                appendMessage("The element \u{201c}\(element.name)\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=button\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if ancestorRole == "img", element.name == "button" {
                appendMessage("The element \u{201c}button\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=img\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if ["img", "math", "progressbar", "separator", "slider"].contains(ancestorRole), element.name == "label" {
                appendMessage("The element \u{201c}label\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=\(ancestorRole)\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        if element.name == "button", stack.last == "select" {
            if element.hasAttribute("role") {
                appendMessage("The \u{201c}role\u{201d} attribute must not be used on a \u{201c}button\u{201d} element that is a child of a \u{201c}select\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            if element.hasAttribute("aria-label") {
                appendMessage("The \u{201c}aria-label\u{201d} attribute must not be used on a \u{201c}button\u{201d} element that is a child of a \u{201c}select\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
        }
        if element.name == "selectedcontent", stack.last == "button", stack.contains("select") {
            if element.hasAttribute("aria-hidden") {
                appendMessage("The \u{201c}aria-hidden\u{201d} attribute must not be used on a \u{201c}selectedcontent\u{201d} element inside the \u{201c}button\u{201d} part of a customizable \u{201c}select\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            if element.hasAttribute("role") {
                appendMessage("The \u{201c}role\u{201d} attribute must not be used on a \u{201c}selectedcontent\u{201d} element inside the \u{201c}button\u{201d} part of a customizable \u{201c}select\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
        }
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

        if let name = element.attributeValue("name"), name.isEmpty {
            appendBadAttributeValue(name, attribute: "name", for: element, locations: locations, messages: &messages)
        }
        if let placeholder = element.attributeValue("placeholder"), containsLineBreak(placeholder) {
            appendBadAttributeValue(placeholder, attribute: "placeholder", for: element, locations: locations, messages: &messages)
        }
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
        appendInputDateTimeValueMessages(for: element, type: type, locations: locations, messages: &messages)
        if Self.inputStepTypes.contains(type), let step = element.attributeValue("step"), !isValidStepValue(step) {
            appendBadAttributeValue(step, attribute: "step", for: element, locations: locations, messages: &messages)
        }
        if element.hasAttribute("size"), Self.inputTextEntryTypes.contains(type) {
            let size = element.attributeValue("size") ?? ""
            guard let value = Int(size), value > 0, String(value) == size else {
                appendBadAttributeValue(size, attribute: "size", for: element, locations: locations, messages: &messages)
                return
            }
        }
    }

    private func appendInputDateTimeValueMessages(
        for element: HTMLStartElement,
        type: String,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let validator: (String) -> Bool
        switch type {
        case "date":
            validator = isValidDateString
        case "datetime-local":
            validator = isValidLocalDateAndTimeString
        case "month":
            validator = isValidMonthString
        case "time":
            validator = isValidTimeString
        case "week":
            validator = isValidWeekString
        default:
            return
        }

        for attribute in ["min", "max"] {
            guard let value = element.attributeValue(attribute), !validator(value) else { continue }
            appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
        }
        if let value = element.attributeValue("value"), !value.isEmpty, !validator(value) {
            appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
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
        guard element.name == "embed" || element.name == "object" else { return }

        if element.name == "embed" {
            for attribute in ["height", "width"] {
                if let value = element.attributeValue(attribute), !isValidNonNegativeInteger(value) {
                    appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
                }
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

    private func appendSelectAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "select" else { return }

        if let autocomplete = element.attributeValue("autocomplete") {
            let tokens = autocomplete.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if tokens.contains("webauthn") {
                appendMessage("The value of the \u{201c}autocomplete\u{201d} attribute for the \u{201c}select\u{201d} element must not contain \u{201c}webauthn\u{201d}.", for: element, locations: locations, messages: &messages)
            } else if !isValidAutocompleteValue(autocomplete) {
                appendBadAttributeValue(autocomplete, attribute: "autocomplete", for: element, locations: locations, messages: &messages)
            }
        }

        if let size = element.attributeValue("size"), !isValidPositiveInteger(size) {
            appendBadAttributeValue(size, attribute: "size", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendSelectChildMessages(
        for element: HTMLStartElement,
        parent: String?,
        selectStack: [SelectState],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "button",
              parent == "select",
              let select = selectStack.last,
              !isDropDownSelect(select.element) else {
            return
        }
        appendMessage("A \u{201c}button\u{201d} element is only allowed as a child of a \u{201c}select\u{201d} element that is a drop-down box (one without a \u{201c}size\u{201d} attribute greater than 1 and without a \u{201c}multiple\u{201d} attribute).", for: element, locations: locations, messages: &messages)
    }

    private func appendSelectMessages(
        _ state: SelectState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if !allowsMultipleSelection(state.element), state.selectedOptionCount > 1 {
            appendMessage("The \u{201c}select\u{201d} element cannot have more than one selected \u{201c}option\u{201d} descendant unless the \u{201c}multiple\u{201d} attribute is specified.", for: state.element, locations: locations, messages: &messages)
        }

        guard state.element.hasAttribute("required"),
              isDropDownSelect(state.element) else {
            return
        }
        if state.optionCount == 0 {
            appendMessage("A \u{201c}select\u{201d} element with a \u{201c}required\u{201d} attribute, and without a \u{201c}multiple\u{201d} attribute, and without a \u{201c}size\u{201d} attribute whose value is greater than \u{201c}1\u{201d}, must have a child \u{201c}option\u{201d} element.", for: state.element, locations: locations, messages: &messages)
        } else if state.firstOptionValue != "" && !state.firstOptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendMessage("The first child \u{201c}option\u{201d} element of a \u{201c}select\u{201d} element with a \u{201c}required\u{201d} attribute, and without a \u{201c}multiple\u{201d} attribute, and without a \u{201c}size\u{201d} attribute whose value is greater than \u{201c}1\u{201d}, must have either an empty \u{201c}value\u{201d} attribute, or must have no text content. Consider either adding a placeholder option label, or adding a \u{201c}size\u{201d} attribute with a value equal to the number of \u{201c}option\u{201d} elements.", for: state.element, locations: locations, messages: &messages)
        }
    }

    private func appendOptionMessages(
        _ state: OptionState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let label = state.element.attributeValue("label"), label.isEmpty {
            appendBadAttributeValue(label, attribute: "label", for: state.element, locations: locations, messages: &messages)
        }
        if !state.hasLabel, state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendMessage("Element \u{201c}option\u{201d} without attribute \u{201c}label\u{201d} must not be empty.", for: state.element, locations: locations, messages: &messages)
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

    private func isValidInteger(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let scalars = Array(value.unicodeScalars)
        let digitStart = scalars.first?.value == 43 || scalars.first?.value == 45 ? 1 : 0
        guard digitStart < scalars.count else { return false }
        return scalars[digitStart...].allSatisfy { scalar in
            scalar.value >= 48 && scalar.value <= 57
        }
    }

    private func isValidPositiveInteger(_ value: String) -> Bool {
        guard let parsed = Int(value), String(parsed) == value else { return false }
        return parsed > 0
    }

    private func isValidMIMEType(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value else { return false }
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

    private func roleTokens(for element: HTMLStartElement) -> [String] {
        element.attributeValue("role")?
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init) ?? []
    }

    private func firstRoleToken(for element: HTMLStartElement) -> String? {
        roleTokens(for: element).first
    }

    private func normalizedAttributeValue(_ attribute: String, for element: HTMLStartElement) -> String? {
        element.attributeValue(attribute)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func isValidHeadingOffset(_ value: String) -> Bool {
        guard let intValue = Int(value), String(intValue) == value else {
            return false
        }
        return intValue >= 0 && intValue <= 8
    }

    private func isValidPopoverValue(_ value: String) -> Bool {
        value.isEmpty || value.lowercased() == "auto" || value.lowercased() == "manual"
    }

    private func isValidSpellcheckValue(_ value: String) -> Bool {
        value.isEmpty || value.lowercased() == "true" || value.lowercased() == "false"
    }

    private func appendRelTypoMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard Self.relAttributeElements.contains(element.name),
              let rel = element.attributeValue("rel") else {
            return
        }
        for token in rel.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            guard let correction = Self.relTypoCorrections[token] else { continue }
            appendInfoMessage(
                "Bad value \u{201c}\(token)\u{201d} for attribute \u{201c}rel\u{201d} on element \u{201c}\(element.name)\u{201d}: Bad list of link-type keywords:  Typo for \u{201c}\(correction)\u{201d}?",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func isValidIDValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains(where: isASCIIWhitespace)
    }

    private func isValidBrowsingContextNameOrKeyword(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.hasPrefix("_") else { return true }
        return Self.browsingContextKeywords.contains(value.lowercased())
    }

    private func isValidCustomElementName(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.contains("-"),
              value == value.lowercased(),
              !Self.reservedCustomElementNames.contains(value) else {
            return false
        }
        guard let first = value.unicodeScalars.first,
              first.value >= 97,
              first.value <= 122 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "-"
                || scalar == "."
                || scalar == "_"
        }
    }

    private func appendSandboxMessages(
        _ value: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let tokens = value.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var seen: Set<String> = []
        for token in tokens {
            guard Self.sandboxTokens.contains(token), !seen.contains(token) else {
                appendBadAttributeValue(value, attribute: "sandbox", for: element, locations: locations, messages: &messages)
                return
            }
            seen.insert(token)
        }
        if seen.contains("allow-scripts"), seen.contains("allow-same-origin") {
            appendWarningMessage(
                "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}sandbox\u{201d} on element \u{201c}iframe\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func containsLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    private func isValidStepValue(_ value: String) -> Bool {
        if value.lowercased() == "any" {
            return true
        }
        guard isValidFloatingPointNumber(value), let parsed = Double(value) else {
            return false
        }
        return parsed > 0
    }

    private func isValidIntegrityMetadata(_ value: String) -> Bool {
        let tokens = value.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return false }
        for token in tokens {
            let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  Self.integrityAlgorithms.contains(String(parts[0]).lowercased()),
                  !parts[1].isEmpty,
                  parts[1].unicodeScalars.allSatisfy(isIntegrityDigestScalar) else {
                return false
            }
        }
        return true
    }

    private func isIntegrityDigestScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || scalar == "+"
            || scalar == "/"
            || scalar == "="
    }

    private func appendListItemMessages(
        for element: HTMLStartElement,
        parent: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let value = element.attributeValue("value") {
            if parent != "ol" {
                appendAttributeNotAllowed("value", for: element, locations: locations, messages: &messages)
            } else if Int(value) == nil {
                appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendAutofocusMessages(
        for element: HTMLStartElement,
        autofocusCount: inout Int,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.hasAttribute("autofocus") else { return }
        autofocusCount += 1
        if autofocusCount > 1 {
            appendMessage(
                "There must not be two elements with the same \"nearest ancestor autofocus scoping root element\" that both have the \u{201c}autofocus\u{201d} attribute specified.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func isHidden(_ element: HTMLStartElement) -> Bool {
        element.hasAttribute("hidden")
    }

    private func isDropDownSelect(_ element: HTMLStartElement) -> Bool {
        !allowsMultipleSelection(element)
    }

    private func allowsMultipleSelection(_ element: HTMLStartElement) -> Bool {
        if element.hasAttribute("multiple") {
            return true
        }
        if let size = element.attributeValue("size"), let value = Int(size), value > 1 {
            return true
        }
        return false
    }

    private func hasAccessibleName(_ element: HTMLStartElement) -> Bool {
        if let alt = element.attributeValue("alt"), !alt.isEmpty {
            return true
        }
        return ["aria-label", "aria-labelledby", "title"].contains { element.hasAttribute($0) }
    }

    private func isLabelableElement(_ element: HTMLStartElement) -> Bool {
        if element.name == "input", inputType(for: element) == "hidden" {
            return false
        }
        return isLabelableElement(name: element.name)
    }

    private func isLabelableElement(name: String) -> Bool {
        Self.labelableElements.contains(name)
    }

    private func unnecessaryRole(for element: HTMLStartElement) -> String? {
        switch element.name {
        case "a":
            return element.hasAttribute("href") ? "link" : nil
        case "article":
            return "article"
        case "aside":
            return "complementary"
        case "button":
            return "button"
        case "dd":
            return "definition"
        case "details":
            return "group"
        case "dialog":
            return "dialog"
        case "dt":
            return "term"
        case "figure":
            return "figure"
        case "footer":
            return "contentinfo"
        case "form":
            return "form"
        case "header":
            return "banner"
        case "hr":
            return "separator"
        case "img":
            return "img"
        case "input":
            let type = inputType(for: element)
            if type == "number" {
                return "spinbutton"
            }
            if type == "search", !element.hasAttribute("list") {
                return "searchbox"
            }
            if type == "text", !element.hasAttribute("list") {
                return "textbox"
            }
            return nil
        case "li":
            return "listitem"
        case "main":
            return "main"
        case "nav":
            return "navigation"
        case "output":
            return "status"
        case "progress":
            return "progressbar"
        case "s":
            return "deletion"
        case "section":
            return element.hasAttribute("aria-label") || element.hasAttribute("aria-labelledby") ? "region" : nil
        case "select":
            if element.hasAttribute("multiple") {
                return "listbox"
            }
            if let size = element.attributeValue("size"), let value = Int(size), value > 1 {
                return "listbox"
            }
            return "combobox"
        case "table":
            return "table"
        case "tbody":
            return "rowgroup"
        case "ul", "ol":
            return "list"
        default:
            return nil
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

    private struct StyleContentState {
        var element: HTMLStartElement
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

    private func appendStyleElementMessages(
        for element: HTMLStartElement,
        parent: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard element.name == "style" else { return }

        if let type = element.attributeValue("type") {
            if type.lowercased() == "text/css" {
                appendWarningMessage(
                    "The \u{201c}type\u{201d} attribute for the \u{201c}style\u{201d} element is not needed and should be omitted.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            } else {
                appendMessage(
                    "The only allowed value for the \u{201c}type\u{201d} attribute for the \u{201c}style\u{201d} element is \u{201c}text/css\u{201d} (with no parameters). (But the attribute is not needed and should be omitted altogether.)",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        guard element.hasAttribute("scoped") else { return }
        if let parent, parent != "head" {
            appendMessage(
                "Element \u{201c}style\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context.",
                for: element,
                locations: locations,
                messages: &messages
            )
        } else {
            appendAttributeNotAllowed("scoped", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendStyleContentMessages(
        _ state: StyleContentState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard state.content.range(
            of: #"(^|[^A-Za-z-])colr\s*:"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return
        }

        appendMessage(
            "CSS: \u{201c}colr\u{201d}: Property \u{201c}colr\u{201d} doesn't exist.",
            for: state.element,
            locations: locations,
            messages: &messages
        )
    }

    private func appendMediaAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard Self.mediaAttributeElements.contains(element.name),
              let media = element.attributeValue("media"),
              !isValidMediaQueryList(media) else {
            return
        }

        appendBadAttributeValue(media, attribute: "media", for: element, locations: locations, messages: &messages)
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

        if !inline, let integrity = element.attributeValue("integrity"), !isValidIntegrityMetadata(integrity) {
            appendBadAttributeValue(integrity, attribute: "integrity", for: element, locations: locations, messages: &messages)
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

    private func isValidMediaQueryList(_ value: String) -> Bool {
        let queries = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !queries.isEmpty else { return false }
        return queries.allSatisfy { isValidMediaQuery(String($0)) }
    }

    private func isValidMediaQuery(_ value: String) -> Bool {
        var remainder = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return false }

        let prefix = consumeMediaIdentifier(from: remainder).lowercased()
        if prefix == "not" || prefix == "only" {
            remainder.removeFirst(prefix.count)
            guard remainder.first?.isWhitespace == true else { return false }
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let mediaType = consumeMediaIdentifier(from: remainder).lowercased()
        guard Self.mediaTypes.contains(mediaType) else { return false }
        remainder.removeFirst(mediaType.count)
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return true }

        while !remainder.isEmpty {
            guard remainder.lowercased().hasPrefix("and") else { return false }
            let afterAnd = remainder.index(remainder.startIndex, offsetBy: 3)
            guard afterAnd < remainder.endIndex,
                  remainder[afterAnd].isWhitespace else {
                return false
            }
            remainder = String(remainder[afterAnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainder.first == "(",
                  let close = remainder.firstIndex(of: ")") else {
                return false
            }
            let featureStart = remainder.index(after: remainder.startIndex)
            guard isValidMediaFeature(String(remainder[featureStart..<close])) else {
                return false
            }
            remainder = String(remainder[remainder.index(after: close)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return true
    }

    private func consumeMediaIdentifier(from value: String) -> String {
        String(value.prefix { scalar in
            scalar.isASCII && (scalar.isLetter || scalar.isNumber || scalar == "-")
        })
    }

    private func isValidMediaFeature(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(";") else { return false }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }

        let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let featureValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "min-width", "max-width":
            return isValidMediaLength(featureValue)
        case "color":
            return isValidMediaInteger(featureValue)
        case "min-resolution":
            return isValidMediaResolution(featureValue)
        default:
            return false
        }
    }

    private func isValidMediaLength(_ value: String) -> Bool {
        if isValidCSSNumber(value), Double(value) == 0 {
            return true
        }
        guard value.hasSuffix("px") else { return false }
        let number = String(value.dropLast(2))
        return isValidCSSNumber(number) && (Double(number) ?? -1) >= 0
    }

    private func isValidMediaResolution(_ value: String) -> Bool {
        guard value.hasSuffix("dpi") else { return false }
        let number = String(value.dropLast(3))
        return isValidCSSNumber(number) && (Double(number) ?? 0) > 0
    }

    private func isValidMediaInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy(isASCIIDigit)
    }

    private func isValidCSSNumber(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var sawDigit = false
        var sawDot = false
        for scalar in value.unicodeScalars {
            if scalar == "." {
                guard !sawDot else { return false }
                sawDot = true
            } else if scalar.value >= 48 && scalar.value <= 57 {
                sawDigit = true
            } else {
                return false
            }
        }
        return sawDigit
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

    private func isValidMonthString(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7,
              bytes[4] == Self.hyphen,
              let year = parseASCIIInteger(bytes, in: 0..<4),
              let month = parseASCIIInteger(bytes, in: 5..<7),
              year >= 1000 else {
            return false
        }
        return month >= 1 && month <= 12
    }

    private func isValidWeekString(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 8,
              bytes[4] == Self.hyphen,
              bytes[5] == UInt8(ascii: "W"),
              let year = parseASCIIInteger(bytes, in: 0..<4),
              let week = parseASCIIInteger(bytes, in: 6..<8),
              year >= 1000 else {
            return false
        }
        return week >= 1 && week <= 53
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

    private static let browsingContextTargetElements: Set<String> = [
        "a", "area", "base", "form"
    ]

    private static let browsingContextKeywords: Set<String> = [
        "_blank", "_self", "_parent", "_top", "_unfencedtop"
    ]

    private static let deprecatedLanguageTags: Set<String> = [
        "mo"
    ]

    private static let enterKeyHintValues: Set<String> = [
        "enter", "done", "go", "next", "previous", "search", "send"
    ]

    private static let headLikeElementsBeforeBase: Set<String> = [
        "base", "html", "head", "link", "meta", "script", "style", "template", "title"
    ]

    private static let iconRelTokens: Set<String> = [
        "icon", "apple-touch-icon", "apple-touch-icon-precomposed"
    ]

    private static let invalidLanguageTags: Set<String> = [
        "bat-smg", "chu", "zzz"
    ]

    private static let integrityAlgorithms: Set<String> = [
        "sha256", "sha384", "sha512"
    ]

    private static let integrityRelTokens: Set<String> = [
        "stylesheet", "preload", "modulepreload"
    ]

    private static let mediaAttributeElements: Set<String> = [
        "link", "meta", "source", "style"
    ]

    private static let mediaTypes: Set<String> = [
        "all", "print", "screen"
    ]

    private static let metadataElements: Set<String> = [
        "link", "meta", "noscript", "script", "style", "template"
    ]

    private static let mainProhibitedAncestors: Set<String> = [
        "article", "aside", "footer", "header", "nav"
    ]

    private static let relAttributeElements: Set<String> = [
        "a", "area", "link"
    ]

    private static let relTypoCorrections: [String: String] = [
        "alternat": "alternate",
        "authr": "author",
        "canonicl": "canonical",
        "styleshet": "stylesheet"
    ]

    private static let reservedCustomElementNames: Set<String> = [
        "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri",
        "font-face-format", "font-face-name", "missing-glyph"
    ]

    private static let sandboxTokens: Set<String> = [
        "allow-downloads", "allow-downloads-without-user-activation", "allow-forms",
        "allow-modals", "allow-orientation-lock", "allow-pointer-lock", "allow-popups",
        "allow-popups-to-escape-sandbox", "allow-presentation", "allow-same-origin",
        "allow-scripts", "allow-storage-access-by-user-activation", "allow-top-navigation",
        "allow-top-navigation-by-user-activation", "allow-top-navigation-to-custom-protocols"
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

    private static let nonAbstractARIARoles: Set<String> = [
        "alert", "alertdialog", "application", "article", "banner", "button", "caption",
        "cell", "checkbox", "code", "combobox", "complementary", "contentinfo", "definition",
        "deletion", "dialog", "directory", "document", "emphasis", "feed", "figure", "form",
        "generic", "grid", "gridcell", "group", "img", "insertion", "link", "list", "listbox",
        "listitem", "log", "main", "marquee", "math", "menu", "menubar", "menuitem",
        "menuitemcheckbox", "menuitemradio", "navigation", "none", "note", "option",
        "paragraph", "presentation", "progressbar", "radio", "radiogroup", "region", "row", "rowgroup",
        "scrollbar", "search", "searchbox", "separator", "slider", "spinbutton", "status",
        "strong", "subscript", "superscript", "switch", "tab", "table", "tablist", "tabpanel",
        "term", "textbox", "timer", "toolbar", "tree", "treegrid", "treeitem"
    ]

    private static let ariaNamingProhibitedElements: Set<String> = [
        "a", "abbr", "area", "b", "bdi", "bdo", "caption", "cite", "code", "data", "del",
        "div", "em", "figcaption", "i", "ins", "kbd", "legend", "mark", "p", "pre", "q",
        "rp", "s", "samp", "small", "span", "strong", "sub", "sup", "time", "u", "var"
    ]

    private static let ariaNamingProhibitedRoles: Set<String> = [
        "caption", "code", "deletion", "emphasis", "generic", "insertion", "paragraph",
        "presentation", "strong", "subscript", "superscript"
    ]

    private static let ariaCheckedRoles: Set<String> = [
        "checkbox", "menuitemcheckbox", "menuitemradio", "option", "radio", "switch"
    ]

    private static let ariaReadonlyRoles: Set<String> = [
        "checkbox", "combobox", "grid", "gridcell", "listbox", "radiogroup", "slider",
        "spinbutton", "textbox"
    ]

    private static let ariaSelectedRoles: Set<String> = [
        "gridcell", "option", "row", "tab"
    ]

    private static let ariaMultiselectableRoles: Set<String> = [
        "grid", "listbox", "tablist", "tree"
    ]

    private static let ariaRangeRoles: Set<String> = [
        "meter", "scrollbar", "separator", "slider", "spinbutton"
    ]

    private static let imgAllowedRoles: Set<String> = [
        "button", "checkbox", "img", "link", "menuitem", "menuitemcheckbox", "menuitemradio",
        "option", "progressbar", "scrollbar", "separator", "slider", "switch", "tab",
        "treeitem"
    ]

    private static let labelableElements: Set<String> = [
        "button", "input", "meter", "output", "progress", "select", "textarea"
    ]

    private static let prohibitedInteractiveAncestorRoles: Set<String> = [
        "checkbox", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio",
        "switch", "tab"
    ]

    private static let headingElements: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6"
    ]

    private static let sectioningHeadingElements: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "hgroup"
    ]

    private static let rubyAnnotationElements: Set<String> = [
        "rp", "rt", "rtc"
    ]

    private static let shadowRootSlotAssignmentValues: Set<String> = [
        "manual", "named"
    ]

    private static let headingProhibitedRoles: Set<String> = [
        "alert", "alertdialog", "application", "dialog", "document", "feed", "listbox", "log",
        "marquee", "math", "note", "status", "tabpanel", "timer", "toolbar"
    ]

    private static func headingLevel(for name: String) -> Int? {
        guard name.count == 2,
              name.first == "h",
              let digit = name.last?.wholeNumberValue,
              (1...6).contains(digit) else {
            return nil
        }
        return digit
    }

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

    private func appendInfoMessage(
        _ message: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.info(
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
