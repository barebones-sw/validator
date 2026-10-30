import Foundation
import VNUCore

struct HTMLURLAttributeChecker {
    private struct URLAttributeRule {
        var attributeName: String
        var requiresAbsoluteURL: Bool
        var requiresNonEmptyValue: Bool
    }

    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []

        for event in document.events {
            // Review item A2 (U16): these are HTML's URL attributes; an SVG
            // <a href> or <image href> isn't checked by these rules upstream.
            guard case let .startElement(element) = event, .html == element.namespace else { continue }
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
        // Review item A15: whether an empty value is allowed is now up to
        // requiresNonEmptyValue alone. It used to be refused whenever an
        // absolute URL was required too, but the only such rule that allows
        // empty is input type=url's value, whose schema (web-forms2.rnc) is
        // `"" | common.data.uri.absolute`: WordPress's comment form, for
        // one, has <input type="url" value="">. (itemtype, the other
        // absolute-URL rule, still requires a value.)
        if value.isEmpty {
            return !rule.requiresNonEmptyValue
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
                // Review item A2 (U16): microdata is an HTML feature; upstream's
                // MicrodataChecker ignores elements in other namespaces.
                if .html == element.namespace {
                    appendMicrodataMessages(
                        for: element,
                        hasItemAncestor: itemScopeStack.contains(true),
                        idValues: idValues,
                        referencedItemIDs: referencedItemIDs,
                        locations: locations,
                        messages: &messages
                    )
                }
                itemScopeStack.append(.html == element.namespace && element.hasAttribute("itemscope"))
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

/// Review item 3: what upstream's text-alternative rules for an <img>
/// (Assertions.java) look at, taken once so that HTMLValidator, which reports
/// a missing alt where upstream does (as it reads the tag), and
/// HTMLGeneralAttributeChecker, which reports the rest and the figure case,
/// can't disagree. For duplicate attributes the first counts, as the parser
/// keeps only that one, and a valueless attribute's value is empty.
struct ImageTextAlternativeFacts {
    /// nil when there's no alt attribute at all.
    let alt: String?
    let hasAriaLabel: Bool
    let hasAriaLabelledby: Bool
    let hasRole: Bool
    /// The role attribute as written ("" when there's none).
    let role: String
    /// Any other aria-* attribute with a value, aria-hidden aside.
    let hasOtherARIA: Bool
    /// The title attribute ("" when there's none).
    let title: String

    init(attributes: [HTMLAttribute]) {
        var seen: Set<String> = []
        var alt: String?
        var role: String?
        var title: String?
        var hasOtherARIA = false
        for attribute in attributes where seen.insert(attribute.name).inserted {
            let value = attribute.value ?? ""
            switch attribute.name {
            case "alt":
                alt = value
            case "role":
                role = value
            case "title":
                title = value
            default:
                if attribute.name.hasPrefix("aria-"), "aria-hidden" != attribute.name, "aria-label" != attribute.name,
                   "aria-labelledby" != attribute.name, !value.isEmpty {
                    hasOtherARIA = true
                }
            }
        }
        self.alt = alt
        self.hasAriaLabel = seen.contains("aria-label")
        self.hasAriaLabelledby = seen.contains("aria-labelledby")
        self.hasRole = nil != role
        self.role = role ?? ""
        // (aria-label and aria-labelledby are aria-* attributes too, but
        // they're only looked at when neither is there.)
        self.hasOtherARIA = hasOtherARIA
        self.title = title ?? ""
    }

    /// No alt, aria-label or aria-labelledby attribute: upstream's first case.
    var lacksTextAlternativeAttributes: Bool {
        nil == alt && !hasAriaLabel && !hasAriaLabelledby
    }

    /// Upstream's "An “img” element must have an “alt” attribute, except under
    /// certain conditions": none of those, no role, no other aria-* attribute
    /// with a value, and no title (or an empty one).
    var needsAlt: Bool {
        lacksTextAlternativeAttributes && !hasRole && !hasOtherARIA && title.isEmpty
    }

    /// The message, which HTMLValidator and HTMLGeneralAttributeChecker both
    /// give (one copy, so that they can't drift apart).
    static let missingAltMessage = "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."
}

struct HTMLGeneralAttributeChecker {
    func validate(document: HTMLParsedDocument, locations: SourceLocationMap) -> [ValidationMessage] {
        var messages: [ValidationMessage] = []
        var stack: [String] = []
        // Review item A2 (U16): each open element's namespace, kept beside
        // `stack` (pushed and popped with it).
        var namespaceStack: [HTMLNamespace] = []
        // Review item A2: for each open element, kept beside `stack` like
        // namespaceStack, whether it's in content upstream's schema accepts
        // unchecked (anything in an SVG <desc>; a non-MathML element in a
        // MathML <annotation-xml>, and everything in it), inside a <template>
        // (where upstream checks nothing at all), and whether it's a foreign
        // element the schema rejects, or inside one (where upstream's schema
        // reports nothing more). HTMLValidator's OpenElement keeps the same
        // flags.
        var anyElementContentStack: [Bool] = []
        var templateContentsStack: [Bool] = []
        var rejectedForeignStack: [Bool] = []
        // Review item A2: the open MathML <annotation-xml> elements whose
        // content upstream's schema checks (see the .characters case).
        var annotationXMLStack: [AnnotationXMLState] = []
        var roleStack: [String?] = []
        var anchorHrefStack: [Bool] = []
        var labelStack: [LabelState] = []
        var pictureStack: [PictureState] = []
        var mediaStack: [MediaState] = []
        var selectStack: [SelectState] = []
        var optionStack: [OptionState] = []
        // Review item 3: upstream's bookkeeping for <img> elements without a
        // text alternative inside a <figure> (see FigureAltRecord): every
        // figure's record, in the order the figures start; for each depth of
        // the stack, the record of the figure last opened at that depth (nil
        // once another element has been opened there), which mirrors
        // upstream's stack array, whose slots keep the last element pushed;
        // the depth of the figure most recently opened (upstream's
        // currentFigurePtr, which a figure's end doesn't reset); and, for each
        // open element, where it is (see FigureAltContext).
        var figureAltRecords: [FigureAltRecord] = []
        var figureAltSlots: [Int?] = []
        var currentFigureAltDepth: Int?
        var figureAltContextStack: [FigureAltContext] = []
        var detailsStack: [DetailsState] = []
        var sectioningStack: [SectioningState] = []
        // Case 554591 (item 3): upstream's bookkeeping for "Empty heading."
        // (Assertions.java), which, like its figure bookkeeping above, works
        // on its stack array's slots: every heading's record, in the order
        // the headings start, with whether text or an <img> has been noted
        // on it (see HeadingContentRecord); for each depth of the stack, the
        // record of the heading last opened at that depth (nil once another
        // element has been opened there), beside figureAltSlots; and the
        // depth of the heading most recently opened (upstream's
        // currentHeadingPtr, which a heading's end doesn't reset), whose
        // slot the text and images in any heading are noted on. Upstream
        // notes them on whatever node is in that slot, and its figure
        // bookkeeping notes an <img> the same way through currentFigurePtr,
        // so a heading that has taken a figure's slot gets the figure's
        // <img> (see the figure bookkeeping). (Upstream also notes a
        // heading's text and images on a figure that has taken the heading's
        // slot, which this leaves out, as it never shows: such a figure is
        // open only when they're in it, and then, being in a heading, its
        // caption's text never counts as a caption's, so it reports its
        // images without an alt anyway.) Nothing inside a
        // <template> is noted, or checked, as upstream's checker skips
        // template contents. So in <h1><span><h2>b</h2></span>c</h1>,
        // both the b and the c are noted on the <h2>, and the <h1> is "Empty
        // heading.", as vnu.jar reports it. The port used to give every open
        // heading all the text inside it, which counted text in a nested
        // heading or a template and no image, and made a document of nested
        // headings quadratic in time and memory (P1 item 3: every open heading
        // kept a copy of the text). So <h1><img src=logo.png alt=Company></h1>
        // was "Empty heading.", where vnu.jar reports nothing.
        var headingRecords: [HeadingContentRecord] = []
        var headingSlots: [Int?] = []
        var currentHeadingDepth: Int?
        // Case 554591 (item 3): upstream's HeadingHierarchyChecker, which
        // sees every element (in templates too): for each open element, its
        // heading offset as that checker computes it (see
        // cumulativeHeadingOffset), kept beside `stack`; and every heading,
        // in the order the headings start, with its computed level. The port
        // used to note a heading's level when it ended, in that order, and
        // only if it wasn't empty, and took no account of headingoffset, so
        // <h1></h1><h2>Title</h2> had "none of them has a computed heading
        // level of 1", and <div headingoffset=1><h1>…</h1></div><h3>…</h3> a
        // skipped level.
        var headingOffsetStack: [Int32] = []
        var headings: [HeadingInfo] = []
        // Case 554591 (A20): upstream's TextContentChecker, which checks the
        // text of a <time> without a datetime attribute against TimeDatetime
        // (see HTMLDatetimeDatatype), inside templates too, as it doesn't
        // skip them: the open ones, each with its depth and where its text
        // starts in timeText; and timeText, the text since the outermost of
        // them started, as upstream's checker sees it. (One buffer for all of
        // them, where upstream gives each its own, so nested ones don't each
        // keep a copy of the text inside them.) The port never checked it, so
        // <time>January 15, 2024</time> went unreported.
        var openTimeTexts: [(element: HTMLStartElement, depth: Int, textStart: Int)] = []
        var timeText: [Unicode.Scalar] = []
        // Case 554591 (A20): the next of the tokens that closed an element
        // implicitly (see HTMLParsedDocument.implicitEndCauses), for where a
        // <time>'s text message goes when its end is implied.
        var nextImplicitEndCause = 0
        var rubyStack: [RubyState] = []
        var optgroupStack: [OptgroupState] = []
        var mathArityStack: [MathArityState] = []
        var svgSequenceStack: [SVGChildSequenceState] = []
        var scriptContent: ScriptContentState?
        var styleContent: StyleContentState?
        var titleCapture: TitleCapture?
        var htmlElement: HTMLStartElement?
        var languageCounts = LanguageCounts()
        // Review item A2 (U16): text waiting for the end of its element; see
        // the .endElement case.
        var pendingLanguageText = ""
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
        var cspState = CSPState()

        for (eventIndex, event) in document.events.enumerated() {
            switch event {
            case let .startElement(element):
                let parent = stack.last
                let role = firstRoleToken(for: element)
                // Review item A2 (U16): most of these checks are HTML's (in
                // upstream, its Assertions checker runs them for HTML elements
                // only), and elements inside inline SVG or MathML used to get
                // them too: SVG <a>, <title>, <style> and <script> share HTML's
                // names, and lang, target, event handlers and so on were all
                // judged by HTML's rules. Foreign elements now get only the
                // namespace-neutral checks and their own SVG or MathML rules.
                let isHTML = .html == element.namespace
                // The parent's namespace: the name-keyed state machines below
                // (ruby, picture, figure, details, optgroup...) are HTML's, and
                // an SVG element named, say, option or picture isn't part of
                // them (review item A2).
                let parentIsHTML = .html == (namespaceStack.last ?? .html)
                // Review item A2: see anyElementContentStack. The SVG and MathML
                // rules below are the schema's (path data, child counts and
                // order, required attributes, role), so they apply only where
                // upstream's schema checks this element.
                let parentNamespace = namespaceStack.last ?? .html
                let inAnyElementContent = (anyElementContentStack.last ?? false)
                    || (.svg == parentNamespace && "desc" == parent)
                    || (.mathML == parentNamespace && "annotation-xml" == parent && .mathML != element.namespace)
                let inTemplateContents = (templateContentsStack.last ?? false) || (.html == parentNamespace && "template" == parent)
                // (Inside a rejected element, everything is, HTML included, as
                // with Jing's suppressDepth; see HTMLValidator's
                // OpenElement.Flags.inRejectedSubtree. An HTML element, or an
                // <svg>, can be rejected too, in a MathML token element; see
                // HTMLForeignContent.tokenElementRejects. A MathML child of
                // one is mglyph or malignmark, or a <math>, which
                // schemaRejects judges.)
                let isRejectedForeign = (rejectedForeignStack.last ?? false)
                    || (.html != element.namespace && HTMLForeignContent.schemaRejects(element.name, namespace: element.namespace, parent: parent, parentNamespace: parentNamespace))
                    || (.mathML != element.namespace && HTMLForeignContent.tokenElementRejects(element.name, parent: parent, parentNamespace: parentNamespace))
                let foreignSchemaChecksApply = !inAnyElementContent && !inTemplateContents && !isRejectedForeign
                if element.name == "html" {
                    htmlElement = element
                }
                if isHTML {
                    updateCSPState(from: element, state: &cspState)
                    appendCSPMessages(for: element, state: cspState, locations: locations, messages: &messages)
                }
                if role == "tab", normalizedAttributeValue("aria-selected", for: element) == "true" {
                    activeRoleTabElement = element
                }
                if role == "tabpanel" {
                    sawRoleTabpanel = true
                }
                if isHTML, Self.sectioningHeadingElements.contains(element.name) {
                    for index in sectioningStack.indices {
                        sectioningStack[index].hasHeading = true
                    }
                }
                // Case 554591 (item 3): see headingOffsetStack. (Pushed with
                // the element, below.)
                let headingOffset = Self.cumulativeHeadingOffset(for: element, parentOffset: headingOffsetStack.last ?? 0)
                if isHTML, let level = Self.headingLevel(for: element.name) {
                    headings.append(HeadingInfo(element: element, level: Self.computedHeadingLevel(level, offset: headingOffset)))
                }
                // Case 554591 (A20): see openTimeTexts. (Only without the
                // attribute: an empty datetime is the attribute's problem.)
                if isHTML, "time" == element.name, !element.hasAttribute("datetime") {
                    openTimeTexts.append((element, stack.count, timeText.count))
                }
                if let rubyIndex = rubyStack.indices.last, parentIsHTML, parent == "ruby" {
                    rubyStack[rubyIndex].directChildNames.append(element.name)
                    if !Self.rubyAnnotationElements.contains(element.name) {
                        rubyStack[rubyIndex].sawBaseContent = true
                    }
                }
                if isHTML, parentIsHTML, parent == "optgroup", element.name == "legend", let optgroupIndex = optgroupStack.indices.last {
                    optgroupStack[optgroupIndex].sawLegend = true
                }
                // (Review item A2: for an SVG element, srcset on <image> is the
                // one disallowed attribute, a schema rule; see
                // foreignSchemaChecksApply.)
                if isHTML || foreignSchemaChecksApply {
                    appendDisallowedAttributeMessages(for: element, parent: parent, locations: locations, messages: &messages)
                }
                appendRoleTokenMessages(for: element, parent: parent, stack: stack, foreignSchemaChecksApply: foreignSchemaChecksApply, inTemplateContents: inTemplateContents, locations: locations, messages: &messages)
                if isHTML {
                    appendDatatypeAttributeMessages(for: element, locations: locations, messages: &messages)
                    appendGlobalAttributeMessages(for: element, locations: locations, messages: &messages)
                    // (Case 554591, item 4: where a <base> in the body is,
                    // as its message names it, and whether that message is
                    // this rule's to give: not where upstream's schema
                    // checks nothing, nor where another rule already gives
                    // it, in a <dl>, a <div> in one or a <picture> (see
                    // HTMLDefinitionListChecker and appendPictureChildMessages),
                    // or in a MathML token element (see HTMLValidator).)
                    let parentIsDivInDL = parentIsHTML && "div" == parent && stack.count >= 2 && "dl" == stack[stack.count - 2] && .html == namespaceStack[stack.count - 2]
                    let baseMisplacementIsReported = !inTemplateContents && !inAnyElementContent && !isRejectedForeign
                        && !(parentIsHTML && ("dl" == parent || "picture" == parent)) && !parentIsDivInDL
                    appendBaseMessages(for: element, parent: parent.map { HTMLForeignContent.displayName($0, namespace: parentNamespace) }, reportsMisplacement: baseMisplacementIsReported, sawBodyContentBeforeBase: sawBodyContentBeforeBase, sawBaseBlockingElement: sawBaseBlockingElement, locations: locations, messages: &messages)
                    appendStructuralAssertionMessages(for: element, stack: stack, mapNames: mapNames, locations: locations, messages: &messages)
                    appendElementSpecificMessages(for: element, stack: stack, locations: locations, messages: &messages)
                }
                appendForeignContentMessages(
                    for: element,
                    parent: parent,
                    hasSVGAncestorA: "a" == element.name && .svg == element.namespace && zip(stack, namespaceStack).contains { "a" == $0.0 && .svg == $0.1 },
                    foreignSchemaChecksApply: foreignSchemaChecksApply,
                    inTemplateContents: inTemplateContents,
                    locations: locations,
                    messages: &messages
                )
                if isHTML {
                    appendLabelForReferenceMessages(for: element, idLabelableElementNames: idLabelableElementNames, locations: locations, messages: &messages)
                    appendAutofocusMessages(for: element, autofocusCount: &autofocusCount, locations: locations, messages: &messages)
                }
                // (Review item A2: on an SVG or MathML element, these are the
                // schema's, so not where it checks nothing; see
                // foreignSchemaChecksApply. vnu.jar reports nothing for
                // aria-checked on a <g role="img"> in an SVG <desc>.)
                if isHTML || foreignSchemaChecksApply {
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
                }
                if isHTML {
                    appendLanguageAttributeMessages(for: element, locations: locations, messages: &messages)
                    // (Case 554591, A20: the date and time values are the
                    // schema's to check, so they're checked only where it
                    // checks this element: not in template contents, which it
                    // never sees, nor in an SVG desc's or a MathML
                    // annotation-xml's any-element content, nor inside an
                    // element it rejected in foreign content. That's
                    // foreignSchemaChecksApply, which for all its name holds
                    // for HTML elements too; with only the template gate,
                    // <svg><desc><time datetime="bad"> got a Bad value that
                    // vnu.jar doesn't give.)
                    if foreignSchemaChecksApply {
                        appendDateTimeAttributeMessages(for: element, locations: locations, messages: &messages)
                    }
                    appendInputAttributeMessages(for: element, idElementNames: idElementNames, schemaChecksApply: foreignSchemaChecksApply, locations: locations, messages: &messages)
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
                }
                if parentIsHTML, parent == "picture", let pictureIndex = pictureStack.indices.last {
                    appendPictureChildMessages(for: element, state: &pictureStack[pictureIndex], locations: locations, messages: &messages)
                }
                // (Case 554591, item 4: a figure's content model, which this
                // used to check here, is HTMLValidator's now, as it's a schema
                // rule; see its FigureContent. A figure's role and table
                // caption rules are checked when it ends; see
                // appendFigureEndMessages.)
                if isHTML, element.name == "audio" || element.name == "video" {
                    mediaStack.append(MediaState(element: element))
                }
                if isHTML, element.name == "select" {
                    selectStack.append(SelectState(element: element))
                }
                if isHTML, element.name == "option", let selectIndex = selectStack.indices.last {
                    selectStack[selectIndex].optionCount += 1
                    if element.hasAttribute("selected") {
                        selectStack[selectIndex].selectedOptionCount += 1
                    }
                    if selectStack[selectIndex].optionCount == 1 {
                        selectStack[selectIndex].firstOptionValue = element.attributeValue("value")
                    }
                }
                if isHTML, element.name == "option" {
                    optionStack.append(OptionState(element: element, hasLabel: element.hasAttribute("label")))
                }
                if parentIsHTML, parent == "details", let detailsIndex = detailsStack.indices.last {
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
                // (HTML elements only: an SVG <title> isn't the document's title,
                // so it used to hide a missing one, and an empty one was an
                // error; SVG <script> and <style> aren't HTML's either.)
                if isHTML, element.name == "script" {
                    scriptContent = scriptContentState(for: element)
                }
                if isHTML, element.name == "style" {
                    styleContent = StyleContentState(element: element)
                }
                if isHTML, element.name == "title" {
                    sawTitle = true
                    titleCapture = TitleCapture(element: element)
                }
                if isHTML, element.name == "picture" {
                    pictureStack.append(PictureState(element: element))
                }
                if isHTML, element.name == "details" {
                    detailsStack.append(DetailsState(element: element))
                }
                if isHTML, element.name == "ruby" {
                    rubyStack.append(RubyState(element: element))
                }
                if isHTML, element.name == "optgroup" {
                    optgroupStack.append(OptgroupState(element: element, hasLabel: element.hasAttribute("label")))
                }
                if isHTML, element.name == "article" || element.name == "section" {
                    sectioningStack.append(SectioningState(element: element))
                }
                if isHTML, element.name == "label" {
                    labelStack.append(LabelState(
                        element: element,
                        forValue: element.attributeValue("for"),
                        hasRole: element.hasAttribute("role"),
                        hasAriaLabel: element.hasAttribute("aria-label"),
                        hasAriaHidden: element.hasAttribute("aria-hidden")
                    ))
                }
                // Review item A2: a child the schema rejects (reported by
                // HTMLValidator) doesn't count toward its parent's children or
                // their order: Jing goes on as if it weren't there. Counting it
                // gave a false "not allowed" for the next child, hid a missing
                // one, and reported the rejected child twice.
                let childIsRejected = .html != element.namespace && HTMLForeignContent.schemaRejects(element.name, namespace: element.namespace, parent: parent, parentNamespace: parentNamespace)
                if !childIsRejected, let index = mathArityStack.indices.last, mathArityStack[index].stackIndex == stack.count - 1 {
                    mathArityStack[index].childCount += 1
                    if mathArityStack[index].childCount > mathArityStack[index].arity, !mathArityStack[index].reportedExtraChild {
                        appendMessage(HTMLVocabulary.notAllowedAsChildMessage(element.displayName, parent: mathArityStack[index].element.name), for: element, locations: locations, messages: &messages)
                        mathArityStack[index].reportedExtraChild = true
                    }
                }
                if foreignSchemaChecksApply, .mathML == element.namespace, let arity = Self.mathElementArity[element.name] {
                    mathArityStack.append(MathArityState(element: element, arity: arity, stackIndex: stack.count))
                }
                if !childIsRejected, let index = svgSequenceStack.indices.last, svgSequenceStack[index].stackIndex == stack.count - 1 {
                    appendSVGSequenceMessages(forChild: element, state: &svgSequenceStack[index], locations: locations, messages: &messages)
                }
                if foreignSchemaChecksApply, .svg == element.namespace, "fecomponenttransfer" == element.name || "font" == element.name {
                    svgSequenceStack.append(SVGChildSequenceState(element: element, stackIndex: stack.count, position: ("font" == element.name) ? 0 : -1))
                }
                if foreignSchemaChecksApply, .mathML == element.namespace, "annotation-xml" == element.name {
                    annotationXMLStack.append(AnnotationXMLState(stackIndex: stack.count))
                }
                // Review item 3: upstream's text-alternative rules for <img>
                // (Assertions.java), and its figure bookkeeping, which keeps an
                // <img> without one inside a <figure> back until the figure
                // ends: a caption can stand in for it then. Nothing inside a
                // <template>, where upstream checks nothing. (The port used to
                // report every <img> without an alt attribute, whatever its
                // title, ARIA label or figure, and in templates too.)
                let parentFigureContext = figureAltContextStack.last ?? FigureAltContext()
                var figureContext = FigureAltContext(child: element, parent: parentFigureContext)
                if isHTML, !inTemplateContents {
                    // (The figure that upstream's currentFigurePtr names now:
                    // nil when another element has taken its place in the
                    // stack, which loses what's noted here, as upstream does.)
                    let currentFigure = currentFigureAltDepth.flatMap { $0 < figureAltSlots.count ? figureAltSlots[$0] : nil }
                    if parentFigureContext.isInFigure, let currentFigure {
                        // A second <img>, or other embedded content, keeps a
                        // caption from standing in for an <img>'s alt.
                        if "img" == element.name {
                            if figureAltRecords[currentFigure].imgFound {
                                figureAltRecords[currentFigure].embeddedContentFound = true
                            } else {
                                figureAltRecords[currentFigure].imgFound = true
                            }
                        } else if Self.figureEmbeddedContentElements.contains(element.name) {
                            figureAltRecords[currentFigure].embeddedContentFound = true
                        }
                    } else if parentFigureContext.isInFigure, "img" == element.name, let depth = currentFigureAltDepth,
                              depth < headingSlots.count, let heading = headingSlots[depth] {
                        // Case 554591 (item 3): where a heading has taken the
                        // place of the figure upstream's currentFigurePtr
                        // names, the <img> is noted on the heading's node, as
                        // upstream's flags are the node's, whatever it is: the
                        // heading has an image now (see headingSlots), so it
                        // isn't "Empty heading.", as in
                        // <figure><figure></figure><h2><img src=b></h2></figure>.
                        headingRecords[heading].imgFound = true
                    }
                    // (Outside a figure, HTMLValidator reports the missing
                    // alt itself, as it reads the tag, which keeps the message
                    // in its place among that checker's; see
                    // ImageTextAlternativeFacts.)
                    if "img" == element.name, appendImageTextAlternativeMessages(for: element, locations: locations, messages: &messages),
                       parentFigureContext.isInFigure, let currentFigure {
                        figureAltRecords[currentFigure].figcaptionNeeded = true
                        figureAltRecords[currentFigure].imagesLackingAlt.append(element)
                    }
                    if "figure" == element.name {
                        figureAltRecords.append(FigureAltRecord(figure: element))
                        figureContext.record = figureAltRecords.count - 1
                        currentFigureAltDepth = stack.count
                    }
                    // Case 554591 (item 4): an HTML child of a figure, which
                    // upstream collects for its table caption rule (see
                    // appendFigureEndMessages); and a <caption> of a table
                    // that's one of them, which upstream notes on the figure,
                    // the last one winning. (Only a figure has a record, so
                    // the parent's, or the table's parent's, is a figure's.)
                    if let record = parentFigureContext.record {
                        figureAltRecords[record].htmlChildCount += 1
                        if "figcaption" == element.name {
                            figureAltRecords[record].hasFigcaptionChild = true
                        } else if "table" == element.name {
                            figureAltRecords[record].hasTableChild = true
                        }
                    }
                    if "caption" == element.name, parentIsHTML, "table" == parent, figureAltContextStack.count >= 2,
                       let record = figureAltContextStack[figureAltContextStack.count - 2].record {
                        figureAltRecords[record].nestedTableCaption = element
                    }
                }
                updateBaseState(afterStarting: element, sawBodyContentBeforeBase: &sawBodyContentBeforeBase, sawBaseBlockingElement: &sawBaseBlockingElement)
                // Case 554591 (item 3): "Empty heading." (see headingSlots).
                // An HTML <img> in a heading with an alt attribute that isn't
                // empty (a space will do) is noted on the heading in the
                // current heading's slot, before the <img> takes a slot of
                // its own; a heading becomes the current heading, at the
                // depth it's about to take, with a new record. Nothing in a
                // template. (Its raw value will do for the alt: a reference
                // never decodes to nothing.)
                var headingRecord: Int?
                if !inTemplateContents {
                    if isHTML, "img" == element.name, parentFigureContext.isInHeading, let depth = currentHeadingDepth, depth < headingSlots.count,
                       let heading = headingSlots[depth], let alt = element.attributeValue("alt"), !alt.isEmpty {
                        headingRecords[heading].imgFound = true
                    }
                    if isHTML, Self.headingElements.contains(element.name) {
                        headingRecords.append(HeadingContentRecord(element: element))
                        headingRecord = headingRecords.count - 1
                        currentHeadingDepth = stack.count
                    }
                    while headingSlots.count < stack.count {
                        headingSlots.append(nil)
                    }
                    if headingSlots.count == stack.count {
                        headingSlots.append(headingRecord)
                    } else {
                        headingSlots[stack.count] = headingRecord
                    }
                }
                // (Elements in a template aren't in upstream's stack at all, so
                // they take no slot; see figureAltSlots.)
                if !inTemplateContents {
                    while figureAltSlots.count < stack.count {
                        figureAltSlots.append(nil)
                    }
                    if figureAltSlots.count == stack.count {
                        figureAltSlots.append(figureContext.record)
                    } else {
                        figureAltSlots[stack.count] = figureContext.record
                    }
                }
                figureAltContextStack.append(figureContext)
                headingOffsetStack.append(headingOffset)
                stack.append(element.name)
                namespaceStack.append(element.namespace)
                anyElementContentStack.append(inAnyElementContent)
                templateContentsStack.append(inTemplateContents)
                rejectedForeignStack.append(isRejectedForeign)
                roleStack.append(role)
                anchorHrefStack.append(isHTML && "a" == element.name && element.hasAttribute("href"))
            case let .endElement(name, endRange, implicit):
                // Review item A2: whether the element ending is HTML, for the
                // name-keyed state below, which only HTML elements start.
                let endedIsHTML = stack.lastIndex(of: name).map { .html == namespaceStack[$0] } ?? true
                if endedIsHTML, name == "script", let content = scriptContent {
                    appendScriptContentMessages(content, locations: locations, messages: &messages)
                    scriptContent = nil
                }
                if endedIsHTML, name == "style", let content = styleContent {
                    appendStyleContentMessages(content, locations: locations, messages: &messages)
                    styleContent = nil
                }
                if endedIsHTML, name == "select", let state = selectStack.popLast() {
                    appendSelectMessages(state, locations: locations, messages: &messages)
                }
                if endedIsHTML, name == "option", let state = optionStack.popLast() {
                    appendOptionMessages(state, locations: locations, messages: &messages)
                }
                if endedIsHTML, name == "picture", let state = pictureStack.popLast() {
                    appendPictureMessages(state, locations: locations, messages: &messages)
                }
                if endedIsHTML, name == "audio" || name == "video", !mediaStack.isEmpty {
                    _ = mediaStack.popLast()
                }
                if endedIsHTML, name == "details", let state = detailsStack.popLast(), state.sawNonSummaryChild, !state.sawSummary, !state.reportedMissingSummary {
                    appendMessage("Element \u{201c}details\u{201d} is missing a required instance of child element \u{201c}summary\u{201d}.", for: state.element, locations: locations, messages: &messages)
                }
                if endedIsHTML, (name == "article" || name == "section"), let state = sectioningStack.popLast(), !state.hasHeading {
                    appendSectioningHeadingWarning(for: state.element, locations: locations, messages: &messages)
                }
                // Case 554591 (item 3): a heading with no text or image noted
                // on it is "Empty heading." (see headingSlots). Its slot holds
                // its record while it's open; one in a template has none.
                // (Its level was noted when it started; see `headings`.) From
                // item 3's review: not a heading with a popover attribute,
                // which upstream's checker treats first as an autofocus
                // scoping root, a branch of the same chain of tests at an
                // element's end, which then skips the heading's.
                if endedIsHTML, Self.headingElements.contains(name), let index = stack.lastIndex(of: name), !templateContentsStack[index],
                   index < headingSlots.count, let heading = headingSlots[index],
                   !headingRecords[heading].textNodeFound, !headingRecords[heading].imgFound,
                   !headingRecords[heading].element.hasAttribute("popover") {
                    appendWarningMessage("Empty heading.", for: headingRecords[heading].element, locations: locations, messages: &messages)
                }
                // Case 554591 (A20): a <time>'s text, checked as it ends (see
                // openTimeTexts), with upstream's messages, which give the
                // reason, and at upstream's place: the end tag, or the token
                // that closed the <time> implicitly (whose end event carries
                // the start tag's range).
                if endedIsHTML, "time" == name, let index = stack.lastIndex(of: name), let open = openTimeTexts.last, index == open.depth {
                    openTimeTexts.removeLast()
                    var place = endRange
                    if implicit {
                        while nextImplicitEndCause < document.implicitEndCauses.count, document.implicitEndCauses[nextImplicitEndCause].index < eventIndex {
                            nextImplicitEndCause += 1
                        }
                        if nextImplicitEndCause < document.implicitEndCauses.count, eventIndex == document.implicitEndCauses[nextImplicitEndCause].index {
                            place = document.implicitEndCauses[nextImplicitEndCause].range
                        }
                    }
                    switch HTMLDatetimeDatatype.checkTimeDatetime(timeText[open.textStart...]) {
                    case .valid:
                        break
                    case let .error(reason):
                        appendMessage("The text content of element \u{201c}time\u{201d} was not in the required format: \(reason)", range: place, locations: locations, messages: &messages)
                    case let .warning(reason):
                        appendWarningMessage("Double-check the text content of element \u{201c}time\u{201d}: \(reason)", range: place, locations: locations, messages: &messages)
                    }
                    if openTimeTexts.isEmpty {
                        timeText.removeAll(keepingCapacity: true)
                    }
                }
                if endedIsHTML, name == "ruby", let state = rubyStack.popLast() {
                    appendRubyMessages(state, locations: locations, messages: &messages)
                }
                if endedIsHTML, name == "optgroup", let state = optgroupStack.popLast() {
                    appendOptgroupMessages(state, locations: locations, messages: &messages)
                }
                if endedIsHTML, name == "title", let capture = titleCapture {
                    appendTitleMessages(capture, locations: locations, messages: &messages)
                    titleCapture = nil
                }
                if endedIsHTML, name == "label", !labelStack.isEmpty {
                    _ = labelStack.popLast()
                }
                if let state = svgSequenceStack.last, state.element.name == name, stack.lastIndex(of: name) == state.stackIndex {
                    svgSequenceStack.removeLast()
                    if "font" == name, state.position < 1 {
                        appendMessage(fontMissingChildMessage("font-face"), for: state.element, locations: locations, messages: &messages)
                    }
                    if "font" == name, state.position < 2 {
                        appendMessage(fontMissingChildMessage("missing-glyph"), for: state.element, locations: locations, messages: &messages)
                    }
                }
                if let state = mathArityStack.last, state.element.name == name, stack.lastIndex(of: name) == state.stackIndex {
                    mathArityStack.removeLast()
                    if state.childCount < state.arity {
                        appendMessage(mathMissingChildrenMessage(for: state.element.name), for: state.element, locations: locations, messages: &messages)
                    }
                }
                // Review item A2 (U16): as in upstream's LanguageDetectingChecker,
                // text collected since the last end tag counts when an HTML
                // element ends and is dropped when a foreign one does. So text
                // in an SVG <text>, directly in a <foreignObject>, or just before
                // an </svg> doesn't count, while a <p> inside a <foreignObject>
                // does (both as vnu.jar reports them).
                if let index = stack.lastIndex(of: name), .html != namespaceStack[index] {
                    pendingLanguageText = ""
                } else {
                    languageCounts.add(pendingLanguageText)
                    pendingLanguageText = ""
                }
                if let index = stack.lastIndex(of: name) {
                    // Review item 3: a figure that ends reports the <img>
                    // elements without a text alternative it kept back, unless
                    // its caption stands in for them (see FigureAltRecord).
                    // (Case 554591, item 4: and its role and table caption,
                    // where upstream reports the first at the figure's end:
                    // this event's end tag, for the element that's ending.)
                    for position in (index..<stack.count).reversed() {
                        if let record = figureAltContextStack[position].record {
                            appendFigureEndMessages(figureAltRecords[record], endRange: (position == index) ? endRange : nil, locations: locations, messages: &messages)
                        }
                    }
                    figureAltContextStack.removeSubrange(index...)
                    headingOffsetStack.removeSubrange(index...)
                    // (Case 554591, A20: a <time> closed with no end event of
                    // its own, which the tree builder never does, isn't
                    // checked; see openTimeTexts.)
                    while let open = openTimeTexts.last, open.depth >= index {
                        openTimeTexts.removeLast()
                    }
                    if openTimeTexts.isEmpty {
                        timeText.removeAll(keepingCapacity: true)
                    }
                    stack.removeSubrange(index...)
                    namespaceStack.removeSubrange(index...)
                    anyElementContentStack.removeSubrange(index...)
                    templateContentsStack.removeSubrange(index...)
                    rejectedForeignStack.removeSubrange(index...)
                    annotationXMLStack.removeAll { $0.stackIndex >= index }
                    roleStack.removeSubrange(index...)
                    anchorHrefStack.removeSubrange(index...)
                }
            case let .characters(content, range):
                // Review item 3: text in a figure or in its caption, for
                // upstream's figure bookkeeping (see FigureAltRecord). Caption
                // text lets the caption stand in for an <img>'s alt, and any
                // other text in the figure doesn't; either way, it counts as
                // text for the figures below the current one in the stack.
                // Text in a heading counts as neither, as upstream has it.
                // (Upstream's tokenizer decodes character references only in
                // ordinary text and RCDATA, not in raw text or a CDATA
                // section, and its tree builder drops a NUL wherever an HTML
                // element would take it; see FigureAltContext.)
                let textIsInTemplateContents = (templateContentsStack.last ?? false) || (.html == namespaceStack.last && "template" == stack.last)
                if !textIsInTemplateContents, let context = figureAltContextStack.last, !context.isInHeading,
                   context.isInFigcaption || context.isInFigure,
                   Self.containsFigureText(content, decodingReferences: context.textDecodesReferences && !Self.isCDATASection(range, locations: locations), droppingNUL: context.textDropsNUL) {
                    let currentFigure = currentFigureAltDepth.flatMap { $0 < figureAltSlots.count ? figureAltSlots[$0] : nil }
                    if context.isInFigcaption {
                        // (The text's own element counts as a figure here: a
                        // node's ancestor mask in upstream includes the node.)
                        if context.isInFigure, let currentFigure {
                            figureAltRecords[currentFigure].figcaptionContentFound = true
                        }
                    } else if let currentFigure {
                        figureAltRecords[currentFigure].textNodeFound = true
                    }
                    if let depth = currentFigureAltDepth {
                        for case let record? in figureAltSlots.prefix(depth) {
                            figureAltRecords[record].textNodeFound = true
                        }
                    }
                }
                if scriptContent != nil {
                    scriptContent?.content += content
                }
                if styleContent != nil {
                    styleContent?.content += content
                }
                if scriptContent == nil, styleContent == nil {
                    appendNormalizationWarningIfNeeded(content, range: range, locations: locations, messages: &messages)
                }
                // Review item A2 (U16): held until its element ends (see the
                // .endElement case), so that text in inline SVG or MathML
                // doesn't sway the language guess.
                if stack.contains("body"), !stack.contains("pre"), scriptContent == nil, styleContent == nil {
                    pendingLanguageText += content
                }
                if let selectIndex = selectStack.indices.last,
                   selectStack[selectIndex].optionCount == 1,
                   stack.contains("option") {
                    selectStack[selectIndex].firstOptionText += content
                }
                if let optionIndex = optionStack.indices.last {
                    optionStack[optionIndex].text += content
                }
                // Review item A2: one message for each piece of the text that
                // upstream's schema validator sees (see nonSpaceTextPieces).
                // This used to be one per element, however many pieces.
                // (Case 554591, item 4: a NUL in MathML is foreign content's,
                // which upstream's tree builder turns into U+FFFD.)
                if let index = mathArityStack.indices.last, mathArityStack[index].stackIndex == stack.count - 1 {
                    for piece in Self.nonSpaceTextPieces(in: content, droppingNUL: false) {
                        appendMessage("Text not allowed in \u{201c}\(mathArityStack[index].element.name)\u{201d} in this context.", range: HTMLSourceRange(offset: range.offset + piece.lowerBound, length: piece.count), locations: locations, messages: &messages)
                    }
                }
                // Review item A2: text directly in a MathML <annotation-xml>,
                // whatever its encoding: MathML 3's annotation-xml.model is
                // MathML expressions or (non-MathML) elements, never text, so
                // upstream's schema reports it, for each piece as above. The
                // port accepted it.
                if let index = annotationXMLStack.indices.last, annotationXMLStack[index].stackIndex == stack.count - 1 {
                    for piece in Self.nonSpaceTextPieces(in: content, droppingNUL: false) {
                        appendMessage("Text not allowed in \u{201c}annotation-xml\u{201d} in this context.", range: HTMLSourceRange(offset: range.offset + piece.lowerBound, length: piece.count), locations: locations, messages: &messages)
                    }
                }
                // Case 554591 (item 3): text in a heading, or in an element
                // inside one, is noted on the heading in the current heading's
                // slot (see headingSlots), if it's text by the rules of the
                // figure bookkeeping above, which are upstream's for both:
                // anything but space, tab, CR and LF, as its checker sees the
                // text. Not in a template. (This replaces a copy of the text
                // for every open heading; see P1 item 3. The figure
                // bookkeeping's text never reaches a heading this way: its
                // current figure's slot can hold a heading that's still open
                // only when the text is in that heading, which makes it a
                // heading's text, here.)
                if !textIsInTemplateContents, let context = figureAltContextStack.last, context.isInHeading,
                   let depth = currentHeadingDepth, depth < headingSlots.count, let heading = headingSlots[depth], !headingRecords[heading].textNodeFound,
                   Self.containsFigureText(content, decodingReferences: context.textDecodesReferences && !Self.isCDATASection(range, locations: locations), droppingNUL: context.textDropsNUL) {
                    headingRecords[heading].textNodeFound = true
                }
                // Case 554591 (A20): text for the open <time>s' checks (see
                // openTimeTexts), as upstream's checker sees it (see
                // FigureAltContext): references decoded where its tokenizer
                // decodes them (a form feed's as a space, as in an attribute
                // value), and without the NULs its tree builder drops.
                if !openTimeTexts.isEmpty, let context = figureAltContextStack.last {
                    // (From A20's review: upstream's tree builder drops a line
                    // feed that comes first in a <pre>, <listing> or
                    // <textarea> (TreeBuilder.needToDropLF). No other check
                    // could tell, as the line feed is white space, but in a
                    // <time>'s text it splits the value, so the text of
                    // <time>2024-<pre>\n01</pre>-15</time> read "2024-\n01-15",
                    // a bad value that vnu.jar doesn't report. Upstream drops
                    // it only from the text right after the start tag: any
                    // other token clears its flag first, a stray end tag, an
                    // ignored start tag or a comment too, which leave no event
                    // here. So it's dropped here only when the event before
                    // this text is that start tag and the text begins where
                    // the tag ends, with nothing between them but "</>"s,
                    // which upstream's tokenizer reports and drops without
                    // handing its tree builder anything.)
                    var written = content
                    if eventIndex > 0, case let .startElement(previous) = document.events[eventIndex - 1], .html == previous.namespace,
                       Self.lineFeedDroppingElements.contains(previous.name) {
                        let tagEnd = previous.range.offset + previous.range.length
                        if tagEnd == range.offset || (tagEnd < range.offset && 0 == (range.offset - tagEnd) % 3
                            && Self.isOnlyEmptyEndTags(locations.extract(offset: tagEnd, length: range.offset - tagEnd, context: 0).text)) {
                            written = Self.droppingLeadingLineFeed(content)
                        }
                    }
                    let seen = context.textDecodesReferences && !Self.isCDATASection(range, locations: locations) ? HTMLCharacterReferences.decodeAttributeValue(written) : written
                    timeText.append(contentsOf: seen.unicodeScalars.lazy.filter { !(context.textDropsNUL && "\u{0}" == $0) })
                }
                let currentIsHTML = .html == (namespaceStack.last ?? .html)
                if currentIsHTML, stack.last == "ruby", !content.unicodeScalars.allSatisfy(isASCIIWhitespace), let rubyIndex = rubyStack.indices.last {
                    rubyStack[rubyIndex].sawBaseContent = true
                }
                if currentIsHTML, stack.last == "picture", pictureStack.indices.last != nil, !content.unicodeScalars.allSatisfy(isASCIIWhitespace) {
                    appendMessage(
                        "Text not allowed in \u{201c}picture\u{201d} in this context.",
                        range: range,
                        locations: locations,
                        messages: &messages
                    )
                }
                if zip(stack, namespaceStack).contains(where: { "iframe" == $0.0 && .html == $0.1 }), !content.unicodeScalars.allSatisfy(isASCIIWhitespace) {
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
        appendHeadingHierarchyMessages(headings, locations: locations, messages: &messages)
        languageCounts.add(pendingLanguageText)
        appendLanguageDetectionWarning(htmlElement: htmlElement, counts: languageCounts, locations: locations, messages: &messages)
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

    private func updateCSPState(from element: HTMLStartElement, state: inout CSPState) {
        guard element.name == "meta",
              normalizedAttributeValue("http-equiv", for: element) == "content-security-policy",
              let content = element.attributeValue("content") else {
            return
        }

        let directives = cspDirectives(from: content)
        if let directive = inlineBlockingCSPDirective(["script-src", "default-src"], directives: directives) {
            state.inlineScriptBlockingDirective = directive
        }
        if let directive = inlineBlockingCSPDirective(["style-src", "default-src"], directives: directives) {
            state.inlineStyleBlockingDirective = directive
        }
    }

    private func appendCSPMessages(
        for element: HTMLStartElement,
        state: CSPState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        if let directive = state.inlineScriptBlockingDirective {
            for attribute in element.attributes where attribute.name.hasPrefix("on") {
                appendWarningMessage(
                    "Event handler attribute \u{201c}\(attribute.name)\u{201d} violates Content Security Policy (meta tag): blocked by \u{201c}\(directive)\u{201d} directive.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
            if element.name == "script", !element.hasAttribute("src"), !element.hasAttribute("nonce") {
                appendWarningMessage(
                    "Inline script violates Content Security Policy (meta tag): blocked by \u{201c}\(directive)\u{201d} directive (missing \u{201c}\u{2018}unsafe-inline\u{2019}\u{201d} or nonce/hash).",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if let directive = state.inlineStyleBlockingDirective {
            if element.hasAttribute("style") {
                appendWarningMessage(
                    "The \u{201c}style\u{201d} attribute violates Content Security Policy (meta tag): blocked by \u{201c}\(directive)\u{201d} directive.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
            if element.name == "style", !element.hasAttribute("nonce") {
                appendWarningMessage(
                    "Inline style violates Content Security Policy (meta tag): blocked by \u{201c}\(directive)\u{201d} directive (missing \u{201c}\u{2018}unsafe-inline\u{2019}\u{201d} or nonce/hash).",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }
    }

    private func cspDirectives(from content: String) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for rawDirective in content.split(separator: ";", omittingEmptySubsequences: true) {
            let tokens = rawDirective.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
            guard let name = tokens.first, result[name] == nil else { continue }
            result[name] = Set(tokens.dropFirst())
        }
        return result
    }

    private func inlineBlockingCSPDirective(_ names: [String], directives: [String: Set<String>]) -> String? {
        for name in names {
            guard let tokens = directives[name] else { continue }
            if !tokens.contains("'unsafe-inline'") {
                return name
            }
        }
        return nil
    }

    private func appendNormalizationWarningIfNeeded(
        _ content: String,
        range: HTMLSourceRange,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let decoded = decodedTextForNormalization(content)
        guard decoded.unicodeScalars.contains(where: { !isASCIIWhitespace($0) }) else { return }
        let normalized = decoded.precomposedStringWithCanonicalMapping
        guard Array(normalized.unicodeScalars) != Array(decoded.unicodeScalars) else { return }
        var replacement = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if replacement.hasSuffix(" ?") {
            replacement.removeLast()
        }
        appendWarningMessage(
            "Text run is not in Unicode Normalization Form C. Should instead be \u{201c}\(replacement)\u{201d}. (Copy and paste that into your source document to replace the un-normalized text.)",
            range: range,
            locations: locations,
            messages: &messages
        )
    }

    private func decodedTextForNormalization(_ content: String) -> String {
        let scalars = Array(content.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        while index < scalars.count {
            if let decoded = decodedNumericCharacterReference(in: scalars, index: index) {
                output.append(decoded.scalar)
                index = decoded.endIndex
            } else {
                output.append(scalars[index])
                index += 1
            }
        }

        return String(output)
    }

    private func decodedNumericCharacterReference(
        in scalars: [Unicode.Scalar],
        index: Int
    ) -> (scalar: Unicode.Scalar, endIndex: Int)? {
        guard index + 3 < scalars.count,
              scalars[index].value == 38,
              scalars[index + 1].value == 35 else {
            return nil
        }

        var cursor = index + 2
        let isHexadecimal: Bool
        if scalars[cursor].value == 120 || scalars[cursor].value == 88 {
            isHexadecimal = true
            cursor += 1
        } else {
            isHexadecimal = false
        }

        var value: UInt32 = 0
        var sawDigit = false
        while cursor < scalars.count, scalars[cursor].value != 59 {
            let digit: UInt32?
            if isHexadecimal {
                digit = hexadecimalValue(of: scalars[cursor])
            } else if scalars[cursor].value >= 48, scalars[cursor].value <= 57 {
                digit = scalars[cursor].value - 48
            } else {
                digit = nil
            }
            guard let digit else { return nil }
            // A reference of 2^32 or more (e.g. `&#4294967296;`) used to
            // overflow this UInt32 and trap, crashing the XPC service (in
            // BBEdit 16.1, a hang; see review item A10). Anything past
            // U+10FFFF is out of range, so Unicode.Scalar(value) below
            // rejects it anyway: stop accumulating once past that limit
            // (further digits can't bring it back into range), and the
            // result is unchanged for every reference that didn't overflow.
            if value <= 0x10FFFF {
                value = value * (isHexadecimal ? 16 : 10) + digit
            }
            sawDigit = true
            cursor += 1
        }

        guard sawDigit,
              cursor < scalars.count,
              scalars[cursor].value == 59,
              let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return (scalar, cursor + 1)
    }

    private func hexadecimalValue(of scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 48...57:
            return scalar.value - 48
        case 65...70:
            return scalar.value - 55
        case 97...102:
            return scalar.value - 87
        default:
            return nil
        }
    }

    private func appendForeignContentMessages(
        for element: HTMLStartElement,
        parent: String?,
        hasSVGAncestorA: Bool,
        foreignSchemaChecksApply: Bool,
        inTemplateContents: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A2: by namespace now. These used to go by whether an
        // <svg> or <math> was open anywhere above, so HTML inside
        // <foreignObject> or <mtext> got SVG's or MathML's rules, and the
        // RDFa and col/dt rules below applied to SVG's elements too.
        switch element.namespace {
        case .html:
            appendRDFaAttributeMessages(for: element, locations: locations, messages: &messages)
            // (Case 554591, item 12: a col in a colgroup, which was reported
            // here for every colgroup, is HTMLValidator's now, and reported
            // only when the colgroup has a span; see its
            // colgroupContentModelMessage.)
            if parent == "dialog", element.name == "dt" {
                appendMessage("Element \u{201c}dt\u{201d} not allowed as child of \u{201c}dialog\u{201d} in this context.", for: element, locations: locations, messages: &messages)
            }
        case .svg:
            appendSVGMessages(for: element, parent: parent, hasSVGAncestorA: hasSVGAncestorA, foreignSchemaChecksApply: foreignSchemaChecksApply, inTemplateContents: inTemplateContents, locations: locations, messages: &messages)
            if foreignSchemaChecksApply {
                appendForeignIDMessages(for: element, locations: locations, messages: &messages)
            }
        case .mathML:
            // (All of these are the schema's; see foreignSchemaChecksApply.)
            if foreignSchemaChecksApply {
                appendMathMessages(for: element, parent: parent, locations: locations, messages: &messages)
                appendForeignIDMessages(for: element, locations: locations, messages: &messages)
            }
        }
    }

    /// Review item A2: an SVG or MathML element's id, which upstream's SVG and
    /// MathML schemas type as an XML 1.0 name (vnu.jar's xml-name datatype),
    /// not as HTML's "anything but whitespace": "1icon", "-a" and "a b" are
    /// all bad values there. Since A2 the HTML id check covers HTML elements
    /// only, so a bad SVG or MathML id went unreported (before A2, HTML's rule
    /// applied to them, which caught a space but not a leading digit). The
    /// value is checked as the schema sees it, character references decoded.
    private func appendForeignIDMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (A valueless id is an empty one, which isn't a name either.)
        guard element.hasAttribute("id") else { return }
        let value = HTMLCharacterReferences.decode(element.attributeValue("id") ?? "")
        if !Self.isXMLName(value) {
            appendBadAttributeValue(value, attribute: "id", for: element, locations: locations, messages: &messages)
        }
    }

    /// Review item A2: whether `value` is an XML 1.0 name, after the fourth
    /// edition's character tables, as upstream's XmlName datatype has them.
    /// ASCII follows the tables exactly: a letter, "_" or ":" first, and then
    /// also digits, "." and "-". Beyond ASCII, the tables' classes are
    /// approximated with Unicode's general categories: letters (and letter
    /// numbers) first, and then also marks, decimal digits and the two
    /// extenders that aren't letters (U+00B7 and U+0387). That may accept a
    /// name the tables reject, such as one with a letter newer than they are,
    /// but rejects spaces and punctuation, NBSP included, as they do.
    private static func isXMLName(_ value: String) -> Bool {
        let isNameStart: (Unicode.Scalar) -> Bool = { scalar in
            if scalar.isASCII {
                return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || "_" == scalar || ":" == scalar
            }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .letterNumber:
                return true
            default:
                return false
            }
        }
        let isNameTrail: (Unicode.Scalar) -> Bool = { scalar in
            if isNameStart(scalar) {
                return true
            }
            if scalar.isASCII {
                return ("0"..."9").contains(scalar) || "." == scalar || "-" == scalar
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber:
                return true
            default:
                return "\u{00B7}" == scalar || "\u{0387}" == scalar
            }
        }
        guard let first = value.unicodeScalars.first, isNameStart(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy(isNameTrail)
    }

    private func appendRDFaAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (Review item A2: "xmlns:" attributes are now checked, by namespace,
        // in HTMLValidator.validateNamespaceDeclarations.)
        let rdfaDisallowed: [String: Set<String>] = [
            "a": ["src"],
            "div": ["href"],
            "html": ["xml:base"],
            "img": ["href"],
            "p": ["href"]
        ]
        if let disallowed = rdfaDisallowed[element.name] {
            for attribute in element.attributes where disallowed.contains(attribute.name) {
                appendMessage(
                    "Attribute \u{201c}\(attribute.name)\u{201d} not allowed on element \u{201c}\(element.name)\u{201d} at this point.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        if let prefix = element.attributeValue("prefix"), !isValidRDFaPrefix(prefix) {
            appendBadAttributeValue(prefix, attribute: "prefix", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendSVGMessages(
        for element: HTMLStartElement,
        parent: String?,
        hasSVGAncestorA: Bool,
        foreignSchemaChecksApply: Bool,
        inTemplateContents: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (Review item A2: xmlns and xmlns:xlink are now checked by namespace in
        // HTMLValidator.validateNamespaceDeclarations; these checks applied the
        // SVG rule to HTML inside <foreignObject> too.)
        //
        // Review item A2: an SVG <a> inside another is upstream's Assertions
        // check, which applies everywhere but in a <template>; the rest are
        // its schema's, which apply only where it checks this element at all
        // (not in an SVG <desc> or a MathML <annotation-xml>, a template, or
        // an element it has rejected; see foreignSchemaChecksApply).
        // (Only SVG <a> ancestors count, as in upstream's
        // numberOfSvgAelementsDeep; an HTML <a> around an SVG used to.)
        if !inTemplateContents, "a" == element.name, hasSVGAncestorA {
            appendMessage("The SVG element \u{201c}a\u{201d} must not appear as a descendant of another SVG element \u{201c}a\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        guard foreignSchemaChecksApply else { return }
        let disallowedAttributes: [String: Set<String>] = [
            "circle": ["foo"],
            "clippath": ["x"],
            "filter": ["filterprimitiveunits"],
            "g": ["marker"],
            "image": ["fill", "xml:base"],
            "path": [],
            "rect": ["stop-color", "xml:id"],
            "svg": ["contentscripttype", "externalresourcesrequired"],
            "tspan": ["line-height"]
        ]
        if let disallowed = disallowedAttributes[element.name] {
            for attribute in element.attributes where disallowed.contains(attribute.name) {
                appendMessage(
                    "Attribute \u{201c}\(attribute.name)\u{201d} not allowed on element \u{201c}\(svgDisplayName(element.name))\u{201d} at this point.",
                    for: element,
                    locations: locations,
                    messages: &messages
                )
            }
        }

        // (Review item A2/U19: feComponentTransfer's and font's children are
        // now checked in order as they arrive; see SVGChildSequenceState.
        // These rules reported every feFuncR in a feComponentTransfer, and
        // every font as missing its missing-glyph.)
        if element.name == "feconvolvematrix", !element.hasAttribute("order") {
            appendMessage("Element \u{201c}feConvolveMatrix\u{201d} is missing required attribute \u{201c}order\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if element.name == "font" {
            if !element.hasAttribute("horiz-adv-x") {
                appendMessage("Element \u{201c}font\u{201d} is missing required attribute \u{201c}horiz-adv-x\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        // Review item A2/U19: d on path, and on SVG fonts' glyph and
        // missing-glyph, is upstream's SVG path data datatype. It's decoded
        // first, as upstream's value is, so that d="M0 0&#10;L1 1" parses and a
        // bad value is shown as vnu.jar shows it ("M0 0 & L1 1", not "&amp;").
        if ["path", "glyph", "missing-glyph"].contains(element.name), let d = element.attributeValue("d").map(HTMLCharacterReferences.decode), !SVGPathData.isValid(d) {
            appendBadAttributeValue(d, attribute: "d", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendMathMessages(
        for element: HTMLStartElement,
        parent: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A2: "HTML start tag ... in a foreign namespace context"
        // is now reported by HTMLValidator, where a breakout tag actually ends
        // foreign content. This check reported any HTML-named element inside
        // <math>, including the HTML that <mtext> may contain.
        // (A2 removed a rule that reported "Stray end tag “head”" for a
        // <math> with <head> open: in the head, a <math> start tag now implies
        // </head> in both element stacks, as upstream's does. Inside
        // <head><noscript>, though, upstream reports "Bad start tag in “math”
        // in “noscript” in “head”" and the stray end tags that follow, as it
        // does for an <img>, <iframe> or <div> there. The port doesn't model
        // that insertion mode for any element (an existing gap), and the old
        // rule only ever gave one of those four errors, for <math> alone.)
        if element.name == "math", let display = element.attributeValue("display"), display != "block" && display != "inline" {
            appendBadAttributeValue(display, attribute: "display", for: element, locations: locations, messages: &messages)
        }
        if element.name == "math", let overflow = element.attributeValue("overflow"), overflow == "wrap" {
            appendBadAttributeValue(overflow, attribute: "overflow", for: element, locations: locations, messages: &messages)
        }
        // (Review item A2/U19: the fixed-arity elements' child counts are now
        // checked as their children arrive and when they end; see
        // MathArityState. This used to report every mfrac, msup and so on
        // as missing its children, however many it had.)
    }

    private func appendLanguageDetectionWarning(
        htmlElement: HTMLStartElement?,
        counts: LanguageCounts,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let htmlElement else { return }
        let detected: String?
        if counts.hebrew > 120, counts.hebrew > counts.cjk {
            detected = "he"
        } else if counts.kana > 40 {
            detected = "ja"
        } else if counts.cjk > 200 {
            detected = "zh-hant"
        } else {
            detected = nil
        }

        guard let detected else { return }
        let lang = htmlElement.attributeValue("lang")?.lowercased()
        let dir = htmlElement.attributeValue("dir")?.lowercased()
        if detected == "he", dir == "ltr", lang == "he" {
            appendWarningMessage("This document appears to be written in Hebrew but the \u{201c}html\u{201d} start tag has \u{201c}dir=\"ltr\"\u{201d}. Consider using \u{201c}dir=\"rtl\"\u{201d} instead.", for: htmlElement, locations: locations, messages: &messages)
        } else if detected == "he", lang != "he" {
            appendWarningMessage("This document appears to be written in Hebrew but the \u{201c}html\u{201d} start tag has \u{201c}lang=\"\(lang ?? "")\"\u{201d}. Consider using \u{201c}lang=\"he\"\u{201d} (or variant) instead.", for: htmlElement, locations: locations, messages: &messages)
        } else if detected == "ja", lang != "ja" {
            appendWarningMessage("This document appears to be written in Japanese but the \u{201c}html\u{201d} start tag has \u{201c}lang=\"\(lang ?? "")\"\u{201d}. Consider using \u{201c}lang=\"ja\"\u{201d} (or variant) instead.", for: htmlElement, locations: locations, messages: &messages)
        } else if detected == "zh-hant", lang != "zh-hant" {
            appendWarningMessage("This document appears to be written in Traditional Chinese but the \u{201c}html\u{201d} start tag has \u{201c}lang=\"\(lang ?? "")\"\u{201d}. Consider using \u{201c}lang=\"zh-hant\"\u{201d} (or variant) instead.", for: htmlElement, locations: locations, messages: &messages)
        }
    }

    private func isValidRDFaPrefix(_ value: String) -> Bool {
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty, tokens.count.isMultiple(of: 2) else { return false }
        for index in stride(from: 0, to: tokens.count, by: 2) {
            let prefix = tokens[index]
            guard prefix.last == ":",
                  prefix.dropLast().unicodeScalars.first?.properties.isAlphabetic == true,
                  prefix.dropLast().unicodeScalars.allSatisfy({ $0.properties.isAlphabetic || $0.properties.isMath || $0.value == 45 || $0.value == 95 }) else {
                return false
            }
            guard isAbsoluteURLToken(tokens[index + 1]) else { return false }
        }
        return true
    }

    private func isAbsoluteURLToken(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil
    }

    private func svgDisplayName(_ name: String) -> String {
        // Review item A2 (U18): the full table, rather than the four names
        // this checker used to list.
        HTMLForeignContent.displayName(name, namespace: .svg)
    }

    private func mathMissingChildrenMessage(for elementName: String) -> String {
        let childList = Self.mathRequiredChildren.map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")
        return "Element \u{201c}\(elementName)\u{201d} is missing a required instance of one or more of the following child elements: \(childList)."
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

    /// Review item 3: one <figure>, as upstream's bookkeeping for <img>
    /// elements without a text alternative sees it (Assertions.java's figure
    /// StackNode): whether it has an <img>, a second one or other embedded
    /// content, text outside its caption, and text in its caption, and the
    /// <img> elements it keeps back until it ends (appendFigureAltMessages).
    ///
    /// Case 554591 (item 4): also what upstream's other figure rules look at
    /// when the figure ends (see appendFigureEndMessages): the figure itself,
    /// for its role; its HTML child elements (upstream's collectedChildren),
    /// counted, and whether they include a figcaption and a table; and the
    /// last <caption> of a table that's one of those children.
    private struct FigureAltRecord {
        var figure: HTMLStartElement
        var imgFound = false
        var embeddedContentFound = false
        var textNodeFound = false
        var figcaptionNeeded = false
        var figcaptionContentFound = false
        var imagesLackingAlt: [HTMLStartElement] = []
        var htmlChildCount = 0
        var hasFigcaptionChild = false
        var hasTableChild = false
        var nestedTableCaption: HTMLStartElement?

        init(figure: HTMLStartElement) {
            self.figure = figure
        }
    }

    /// Review item 3: where an open element is, for upstream's figure
    /// bookkeeping: in a heading, a figcaption or a figure (the element
    /// itself, or an ancestor, as upstream's ancestor masks include the
    /// element's own bit); its figure record, for a figure; and how text
    /// directly in it reaches upstream's checker: with character references
    /// decoded (not in raw text: script, style, xmp, iframe, noembed,
    /// noframes, plaintext), and without a NUL, which upstream's tree builder
    /// drops in an HTML element (not in raw text or RCDATA) or an integration
    /// point, and turns into U+FFFD elsewhere.
    private struct FigureAltContext {
        var isInHeading = false
        var isInFigcaption = false
        var isInFigure = false
        var record: Int?
        var textDecodesReferences = true
        var textDropsNUL = true

        init() {}

        init(child element: HTMLStartElement, parent: FigureAltContext) {
            let isHTML = .html == element.namespace
            isInHeading = parent.isInHeading || (isHTML && HTMLVocabulary.headingElements.contains(element.name))
            isInFigcaption = parent.isInFigcaption || (isHTML && "figcaption" == element.name)
            isInFigure = parent.isInFigure || (isHTML && "figure" == element.name)
            let isRawText = isHTML && HTMLGeneralAttributeChecker.rawTextElements.contains(element.name)
            textDecodesReferences = !isRawText
            textDropsNUL = isHTML ? !(isRawText || "title" == element.name || "textarea" == element.name)
                : HTMLForeignContent.childrenAreHTML(element.name, namespace: element.namespace, attributes: element.attributes)
        }
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

    /// Case 554591 (item 3): a heading, for upstream's "Empty heading." (see
    /// headingSlots): its start tag, where the warning goes, and the two flags
    /// of upstream's node that decide it: text found, and an <img> found
    /// (which its figure bookkeeping can set too).
    private struct HeadingContentRecord {
        var element: HTMLStartElement
        var textNodeFound = false
        var imgFound = false

        init(element: HTMLStartElement) {
            self.element = element
        }
    }

    /// Case 554591 (item 3): a heading, for upstream's HeadingHierarchyChecker
    /// (see `headings`): its start tag, where its messages go, and its
    /// computed level (see computedHeadingLevel).
    private struct HeadingInfo {
        var element: HTMLStartElement
        var level: Int32
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

    /// Review item A2/U19: an open SVG element whose children must come in a
    /// set order (upstream's svg11 schema): feComponentTransfer takes at most
    /// one each of feFuncR, feFuncG, feFuncB and feFuncA, in that order, and
    /// nothing else; font takes desc, title or metadata, then a required
    /// font-face, then a required missing-glyph, then glyph, hkern or vkern.
    /// A child out of place is "not allowed as child"; a required child that
    /// was skipped is "missing", where the next child shows it or when the
    /// element ends (all as vnu.jar reports them).
    private struct SVGChildSequenceState {
        var element: HTMLStartElement
        /// Where the element sits in the checker's stack of open elements.
        var stackIndex: Int
        /// feComponentTransfer: the rank of the last feFunc child (R 0, G 1,
        /// B 2, A 3). font: 0 before font-face, 1 before missing-glyph, 2 after.
        var position: Int
    }

    private static let feFuncRanks: [String: Int] = ["fefuncr": 0, "fefuncg": 1, "fefuncb": 2, "fefunca": 3]
    private static let svgDescriptiveElements: Set<String> = ["desc", "title", "metadata"]
    private static let svgGlyphElements: Set<String> = ["glyph", "hkern", "vkern"]

    private func fontMissingChildMessage(_ child: String) -> String {
        "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}\(child)\u{201d}."
    }

    /// Checks the next child of a feComponentTransfer or font.
    private func appendSVGSequenceMessages(
        forChild child: HTMLStartElement,
        state: inout SVGChildSequenceState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let notAllowed = HTMLVocabulary.notAllowedAsChildMessage(child.displayName, parent: state.element.displayName)
        if "fecomponenttransfer" == state.element.name {
            if let rank = Self.feFuncRanks[child.name], rank > state.position {
                state.position = rank
            } else {
                appendMessage(notAllowed, for: child, locations: locations, messages: &messages)
            }
            return
        }
        // font
        switch (state.position, child.name) {
        case (0, let name) where Self.svgDescriptiveElements.contains(name):
            break
        case (0, "font-face"):
            state.position = 1
        case (0, "missing-glyph"):
            appendMessage(fontMissingChildMessage("font-face"), for: state.element, locations: locations, messages: &messages)
            state.position = 2
        case (0, let name) where Self.svgGlyphElements.contains(name):
            // Only the first required child that was skipped is reported here,
            // as Jing does when a child from a later group arrives (vnu.jar
            // gives just the font-face message for <font><glyph/></font>); at
            // the end of the element, both missing children are reported
            // (<font></font>). This used to add the missing-glyph message too.
            appendMessage(fontMissingChildMessage("font-face"), for: state.element, locations: locations, messages: &messages)
            state.position = 2
        case (1, "missing-glyph"):
            state.position = 2
        case (1, let name) where Self.svgGlyphElements.contains(name):
            appendMessage(fontMissingChildMessage("missing-glyph"), for: state.element, locations: locations, messages: &messages)
            state.position = 2
        case (2, let name) where Self.svgGlyphElements.contains(name):
            break
        default:
            appendMessage(notAllowed, for: child, locations: locations, messages: &messages)
        }
    }

    /// Review item A2/U19: an open MathML element that takes a fixed number of
    /// child elements (mfrac, msup, ...). Too few is reported when it ends,
    /// with upstream's "missing a required instance" message; the first child
    /// too many is "not allowed as child", and text directly inside it is "not
    /// allowed" either (all as vnu.jar reports them).
    /// Review item A2: see annotationXMLStack.
    private struct AnnotationXMLState {
        /// Where the element sits in the checker's stack of open elements.
        var stackIndex: Int
    }

    /// Review item A2: the pieces of non-space text upstream's schema
    /// validator sees in `text` (as UTF-16 offsets into it), for "Text not
    /// allowed", which it reports for each piece. Upstream's tokenizer hands
    /// text on in pieces, splitting it at every "&" and at a "<" that doesn't
    /// start a tag: the text before it, the character reference (or what it
    /// tried as one, or the "<") and the text after it reach the validator
    /// separately (its tree builder passes each piece straight on), and a
    /// piece that's all XML whitespace (a reference to a space or line break
    /// included) is fine. So vnu.jar reports "a&amp;b" in an <msub> three
    /// times, and the port reported it once. (Upstream also splits text at
    /// its input buffer's boundaries, and after the longest name it knows
    /// in an unterminated reference such as "&notit;"; this follows neither,
    /// nor its exact split of a name that isn't a reference at all.)
    /// (Case 554591, item 4: not private, as HTMLValidator's figure rules
    /// report text the same way. Also, as upstream's tokenizer has it: a
    /// reference to a form feed is a space, not text, since the tokenizer
    /// turns it into one (a form feed written as such is still text); and a
    /// NUL ends a piece too, as the tokenizer hands on the text before it
    /// separately, and is then dropped where `droppingNUL` (in an HTML
    /// element, whose tree builder ignores it) or a piece of its own (in
    /// foreign content, where it becomes U+FFFD). This used to count "&#12;"
    /// as text, which in a figure made the caption after it the last child,
    /// and took a NUL for part of the text around it.)
    static func nonSpaceTextPieces(in text: String, droppingNUL: Bool) -> [Range<Int>] {
        let scalars = Array(text.unicodeScalars)
        // Each scalar's UTF-16 offset, and the text's length at the end.
        var offsets = [0]
        offsets.reserveCapacity(scalars.count + 1)
        for scalar in scalars {
            offsets.append(offsets[offsets.count - 1] + UTF16.width(scalar))
        }
        let isXMLSpace: (Unicode.Scalar) -> Bool = { " " == $0 || "\t" == $0 || "\n" == $0 || "\r" == $0 }
        var pieces: [Range<Int>] = []
        var pieceStart = 0
        var index = 0
        while index <= scalars.count {
            guard index < scalars.count, "&" != scalars[index], "<" != scalars[index], "\u{0}" != scalars[index] else {
                // The end of a piece of ordinary text.
                if scalars[pieceStart..<index].contains(where: { !isXMLSpace($0) }) {
                    pieces.append(offsets[pieceStart]..<offsets[index])
                }
                guard index < scalars.count else {
                    break
                }
                // Then the reference (or the "&", "<" or NUL) as a piece of
                // its own.
                let end = ("&" == scalars[index]) ? referencePieceEnd(in: scalars, at: index) : index + 1
                if "\u{0}" == scalars[index] {
                    if !droppingNUL {
                        pieces.append(offsets[index]..<offsets[end])
                    }
                } else {
                    var piece = String.UnicodeScalarView()
                    piece.append(contentsOf: scalars[index..<end])
                    if !HTMLCharacterReferences.decode(String(piece)).unicodeScalars.allSatisfy({ isXMLSpace($0) || ("&" == scalars[index] && "\u{0C}" == $0) }) {
                        pieces.append(offsets[index]..<offsets[end])
                    }
                }
                index = end
                pieceStart = end
                continue
            }
            index += 1
        }
        return pieces
    }

    /// Review item A2: where the piece of text that upstream's tokenizer
    /// makes of the "&" at `start` ends (see nonSpaceTextPieces): past a
    /// numeric reference and its semicolon, or past the "&#" or "&#x" alone
    /// when no digits follow (and its semicolon, if that comes next); past a
    /// name and its semicolon; and otherwise just past the "&".
    private static func referencePieceEnd(in scalars: [Unicode.Scalar], at start: Int) -> Int {
        let isDigit: (Unicode.Scalar, Bool) -> Bool = { scalar, hexadecimal in
            ("0"..."9").contains(scalar) || (hexadecimal && (("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)))
        }
        let isAlphanumeric: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
        var cursor = start + 1
        guard cursor < scalars.count else {
            return cursor
        }
        if "#" == scalars[cursor] {
            cursor += 1
            let hexadecimal = cursor < scalars.count && ("x" == scalars[cursor] || "X" == scalars[cursor])
            if hexadecimal {
                cursor += 1
            }
            while cursor < scalars.count, isDigit(scalars[cursor], hexadecimal) {
                cursor += 1
            }
            // (Case 554591, item 4: the semicolon is the piece's even with no
            // digits before it, as upstream's tokenizer takes "&#;" and
            // "&#x;": this split them in two, so text written that way was
            // reported twice, in a figure and in MathML.)
            if cursor < scalars.count, ";" == scalars[cursor] {
                cursor += 1
            }
            return cursor
        }
        guard isAlphanumeric(scalars[cursor]) else {
            return cursor
        }
        while cursor < scalars.count, isAlphanumeric(scalars[cursor]) {
            cursor += 1
        }
        if cursor < scalars.count, ";" == scalars[cursor] {
            cursor += 1
        }
        return cursor
    }

    private struct MathArityState {
        var element: HTMLStartElement
        var arity: Int
        /// Where the element sits in the checker's stack of open elements.
        var stackIndex: Int
        var childCount = 0
        var reportedExtraChild = false
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

    private struct CSPState {
        var inlineScriptBlockingDirective: String?
        var inlineStyleBlockingDirective: String?
    }

    private struct LanguageCounts {
        var cjk = 0
        var kana = 0
        var hebrew = 0

        mutating func add(_ text: String) {
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x0590...0x05FF:
                    hebrew += 1
                case 0x3040...0x30FF, 0x31F0...0x31FF:
                    kana += 1
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                    cjk += 1
                default:
                    continue
                }
            }
        }
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
        let disallowed = disallowedAttributes(for: element, parent: parent)
        for attribute in element.attributes where disallowed.contains(attribute.name) {
            appendMessage(
                "Attribute \u{201c}\(attribute.name)\u{201d} not allowed on element \u{201c}\(element.name)\u{201d} at this point.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    // Attributes the schema doesn't allow on this element here. (Also used by
    // appendRoleTokenMessages: where role isn't allowed at all, the schema
    // never judges its value.)
    private func disallowedAttributes(for element: HTMLStartElement, parent: String?) -> Set<String> {
        // Review item A2 (U16): these are HTML's rules. The one that matters
        // in SVG is srcset, which SVG's <image> doesn't have (an HTML <image>
        // start tag is parsed as <img>, so srcsetDisallowedElements's "image"
        // was really about SVG all along).
        guard .html == element.namespace else {
            return ("image" == element.name && element.hasAttribute("srcset")) ? ["srcset"] : []
        }
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
        return disallowed
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

    /// Case 554591 (item 3): upstream's HeadingHierarchyChecker, at the end
    /// of the document: each heading that's more than one level below the
    /// heading before it, in the order they start, is an error (with
    /// "levels" for more than one), and then, if no heading has a computed
    /// level of 1, the first one gets a warning. Every heading counts, an
    /// empty one too. (The port checked each heading as it ended, in that
    /// order, leaving out empty ones, and always said "level"; vnu.jar's
    /// "skipping 2 heading levels." was a mismatch on 12 pages of the
    /// website. It also named the previous heading by its level, as
    /// "h\(level)", rather than by its name.) Upstream's arithmetic is a Java
    /// int's, which these Int32 operations keep.
    private func appendHeadingHierarchyMessages(
        _ headings: [HeadingInfo],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let first = headings.first else { return }
        var previous: HeadingInfo?
        var hasTopLevelHeading = false
        for heading in headings {
            if 1 == heading.level {
                hasTopLevelHeading = true
            }
            if let previous, heading.level > previous.level &+ 1 {
                let skipped = heading.level &- previous.level &- 1
                appendMessage("The heading \u{201c}\(heading.element.name)\u{201d} (with computed level \(heading.level)) follows the heading \u{201c}\(previous.element.name)\u{201d} (with computed level \(previous.level)), skipping \(skipped) heading level\(skipped > 1 ? "s" : "").", for: heading.element, locations: locations, messages: &messages)
            }
            previous = heading
        }
        if !hasTopLevelHeading {
            appendWarningMessage("This document has heading elements but none of them has a computed heading level of 1.", for: first.element, locations: locations, messages: &messages)
        }
    }

    /// Case 554591 (item 3): an element's heading offset as upstream's
    /// HeadingHierarchyChecker computes it for a heading (its
    /// computeHeadingOffset): the headingoffset values (see
    /// headingOffsetValue) of the element and its ancestors, added up from the
    /// element outward until one with a headingreset attribute, whose value
    /// is the last added. Kept for each open element, this is the element's
    /// own value, plus, unless it has headingreset, its parent's offset. (A
    /// foreign element has neither attribute, as far as that checker is
    /// concerned.) Upstream walks every ancestor for each heading, which for
    /// deeply nested headings would be quadratic. (The value is decoded
    /// first, as upstream's tokenizer hands it on: see
    /// HTMLCharacterReferences.decodeAttributeValue.)
    private static func cumulativeHeadingOffset(for element: HTMLStartElement, parentOffset: Int32) -> Int32 {
        guard .html == element.namespace else {
            return parentOffset
        }
        let own = element.attributeValue("headingoffset").map { headingOffsetValue(HTMLCharacterReferences.decodeAttributeValue($0)) } ?? 0
        return element.hasAttribute("headingreset") ? own : own &+ parentOffset
    }

    /// Case 554591 (item 3): a heading's computed level, as upstream's
    /// HeadingHierarchyChecker has it: the number in its name plus its
    /// heading offset, at most 9.
    private static func computedHeadingLevel(_ level: Int, offset: Int32) -> Int32 {
        min(Int32(level) &+ offset, 9)
    }

    /// Case 554591 (item 3): a headingoffset attribute's value as upstream's
    /// HeadingHierarchyChecker reads it (parseNonNegativeInteger): Java's
    /// String.trim, which strips the UTF-16 units up to U+0020 from both ends,
    /// then Integer.parseInt, which takes an optional sign and decimal digits
    /// of any script (Character.digit, which knows no surrogate pairs) into
    /// a 32-bit int; 0 for a negative value or for anything parseInt rejects,
    /// including an overflow. (The attribute's own error, for a value other
    /// than 0 to 8, is isValidHeadingOffset's; vnu.jar takes "1 " and
    /// "１", a fullwidth 1, as 1 here.) From item 3's review: a NUL makes it
    /// 0 wherever it is, as upstream's tokenizer turns it into U+FFFD, which
    /// is neither trimmed nor a digit (this took "2<NUL>" as 2); and ASCII
    /// digits are read directly, before any look-up of Unicode's properties,
    /// from the UTF-16 view itself, not a copy (a long value cost a quarter
    /// as much again as the rest of checking the page).
    private static func headingOffsetValue(_ value: String) -> Int32 {
        var units = value.utf16[...]
        if units.contains(0) {
            return 0
        }
        while let first = units.first, first <= 0x20 {
            units.removeFirst()
        }
        while let last = units.last, last <= 0x20 {
            units.removeLast()
        }
        // (A minus sign gives either a negative number or an error, and both
        // are 0.)
        guard let first = units.first, 0x2D != first else {
            return 0
        }
        if 0x2B == first {
            units.removeFirst()
        }
        guard !units.isEmpty else {
            return 0
        }
        var result: Int64 = 0
        for unit in units {
            let digit: Int64
            if 0x30 <= unit, 0x39 >= unit {
                digit = Int64(unit - 0x30)
            } else if let scalar = Unicode.Scalar(unit), .decimalNumber == scalar.properties.generalCategory,
                      let numeric = scalar.properties.numericValue {
                digit = Int64(numeric)
            } else {
                return 0
            }
            result = result * 10 + digit
            if result > Int64(Int32.max) {
                return 0
            }
        }
        return Int32(result)
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
        // (Case 554591, item 3: the value as upstream's checker sees it, its
        // character references decoded, as the heading levels now read it
        // too; see cumulativeHeadingOffset. So headingoffset="&#50;" is 2,
        // and fine, where the port reported it as no number from 0 to 8.)
        if let headingOffset = element.attributeValue("headingoffset"), !isValidHeadingOffset(HTMLCharacterReferences.decodeAttributeValue(headingOffset)) {
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
        parent: String?,
        reportsMisplacement: Bool,
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
        // (Case 554591, item 4: naming the element it's in, as upstream's
        // schema does; this always said "body", so a <base> in a <figure> or
        // a <div> got a message vnu.jar doesn't give, instead of its own. The
        // figure rules leave a <base> to this. And only where it's this
        // rule's to give; see the caller.)
        if sawBodyContentBeforeBase {
            if reportsMisplacement {
                let parentName = (nil == parent || "html" == parent) ? "body" : parent!
                appendMessage(HTMLVocabulary.notAllowedAsChildMessage("base", parent: parentName), for: element, locations: locations, messages: &messages)
            }
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
            // (Review item A2: displayName spells SVG names as upstream does.)
            "Attribute \u{201c}\(attribute)\u{201d} not allowed on element \u{201c}\(element.displayName)\u{201d} at this point.",
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
            "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute)\u{201d} on element \u{201c}\(element.displayName)\u{201d}.",
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
        appendRoleEffectMessages(for: element, role: role, locations: locations, messages: &messages)
        appendUnnecessaryRoleMessages(for: element, role: role, locations: locations, messages: &messages)
        if .html == element.namespace {
            appendARIANamingMessages(for: element, locations: locations, messages: &messages)
        }
        appendSelectRoleMessages(for: element, stack: stack, locations: locations, messages: &messages)
        appendSummaryARIAMessages(for: element, stack: stack, locations: locations, messages: &messages)
        appendARIAPropertyMessages(for: element, role: role, idElementNames: idElementNames, locations: locations, messages: &messages)
        appendLabelARIAAssociationMessages(for: element, idElementNames: idElementNames, labelStack: labelStack, locations: locations, messages: &messages)
        appendARIAStructureMessages(for: element, role: role, stack: stack, roleStack: roleStack, locations: locations, messages: &messages)

        if .html == element.namespace, element.name == "main", !isHidden(element) {
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
        parent: String?,
        stack: [String],
        foreignSchemaChecksApply: Bool,
        inTemplateContents: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A13: this now mirrors upstream's two stages. The role
        // filter (RoleAttributeFilteringContentHandlerWrapper) reports
        // unrecognized and superfluous tokens and passes on a single value,
        // and the schema then judges that value. The port used to report
        // every unrecognized token on its own, even when no token was
        // recognized (where upstream gives the schema's "Bad value" instead),
        // lowercased tokens that upstream matches case-sensitively, and was
        // missing 46 of upstream's roles (heading, tooltip, columnheader,
        // rowheader, every doc-* role and the graphics-* roles), so footnote
        // markup from goldmark and kramdown, tooltips and ARIA headings were
        // all reported as errors. It runs right after the disallowed-attribute
        // check because these are the schema's messages, which upstream
        // reports before its other checks' messages for the same element.
        // Where each stage applies was matched against vnu.jar:
        guard let rawValue = roleAttributeValue(for: element) else { return }
        // - Nothing at all inside a template's contents. (Review item A2: an
        //   HTML template's; an SVG element named template is no such
        //   thing, and this used to go by the name alone.)
        guard !inTemplateContents else { return }
        let inSVG = .svg == element.namespace
        // - MathML isn't filtered: the math element may have exactly
        //   role="math" (appendUnnecessaryRoleMessages warns that it's not
        //   needed), so anything else is a "Bad value" as written, and the
        //   elements inside it may not have a role at all.
        //   (Review item A2: these are the schema's, so not in an SVG <desc>
        //   or a MathML <annotation-xml>, or in a rejected element; see
        //   foreignSchemaChecksApply.)
        if .mathML == element.namespace {
            guard foreignSchemaChecksApply else { return }
            if element.name == "math" {
                if rawValue != "math" {
                    appendBadAttributeValue(rawValue, attribute: "role", for: element, locations: locations, messages: &messages)
                }
            } else {
                appendAttributeNotAllowed("role", for: element, locations: locations, messages: &messages)
            }
            return
        }
        // - Nothing for an autonomous custom element in HTML. (SVG elements
        //   with hyphens in their names, such as missing-glyph, are filtered.)
        guard inSVG || !element.name.contains("-"), let filtered = filteredRole(for: element) else { return }
        if filtered.roleValue != nil, !filtered.unrecognized.isEmpty {
            appendMessage(
                "Discarding unrecognized\(renderedRoleTokenList(filtered.unrecognized)) from value of attribute \u{201c}role\u{201d}. Browsers ignore any token that is not a defined ARIA non-abstract role.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        if filtered.roleValue != nil, !filtered.superfluous.isEmpty {
            appendInfoMessage(
                "Discarding superfluous\(renderedRoleTokenList(filtered.superfluous)) from value of attribute \u{201c}role\u{201d}. Browsers only process the first token found that is a defined ARIA non-abstract role.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
        // - The schema judges the value only on elements it knows, and where
        //   role is allowed at all: not on obsolete or unknown HTML elements,
        //   and not where appendDisallowedAttributeMessages reports role as
        //   not allowed.
        // - On an SVG element, the schema judges nothing where it doesn't
        //   check the element at all: an unknown one, one inside an element
        //   it has rejected, or one in an SVG <desc> or a MathML
        //   <annotation-xml> (see foreignSchemaChecksApply). This used to give
        //   "Bad value" for role on an unknown SVG element (review item A2).
        // - On an SVG element that doesn't take ARIA attributes (in upstream's
        //   svg11 schema, only the 19 in svgARIAElements do), the schema's
        //   error is that role isn't allowed at all (review item A2).
        if inSVG {
            guard foreignSchemaChecksApply else { return }
            if !Self.svgARIAElements.contains(element.name) {
                appendAttributeNotAllowed("role", for: element, locations: locations, messages: &messages)
                return
            }
        }
        let schemaKnowsElement = inSVG || (HTMLVocabulary.elements.contains(element.name) && !HTMLVocabulary.obsoleteElements.contains(element.name))
        guard schemaKnowsElement, !disallowedAttributes(for: element, parent: parent).contains("role") else { return }
        if filtered.roleValue == "directory" {
            // Deprecated in ARIA 1.2: upstream's schema no longer lists it,
            // and upstream (MessageEmitterAdapter) reports the resulting
            // "Bad value" as a warning.
            appendWarningMessage("Bad value \u{201c}directory\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}\(element.name)\u{201d}.", for: element, locations: locations, messages: &messages)
        } else if !Self.schemaARIARoles.contains(filtered.schemaValue) {
            // No token was recognized and the value as a whole isn't one the
            // schema accepts (an unknown role, several tokens, an empty
            // value, or a CURIE or URL as in RDFa): the schema's error.
            appendBadAttributeValue(filtered.schemaValue, attribute: "role", for: element, locations: locations, messages: &messages)
        }
    }

    /// What upstream's role filter makes of an element's role attribute.
    private struct FilteredRole {
        /// The first token that's a non-abstract ARIA role, as written.
        var roleValue: String?
        /// Tokens that aren't non-abstract ARIA roles, in order.
        var unrecognized: [String]
        /// Non-abstract roles after the first, except "presentation".
        var superfluous: [String]
        /// The value the schema sees: roleValue, or else the whole trimmed
        /// attribute value.
        var schemaValue: String
    }

    /// Review item A13: RoleAttributeFilteringContentHandlerWrapper's
    /// getFirstMatchingAriaRoleFromTokenList. The value is trimmed as Java's
    /// String.trim() does (every character up to U+0020), split on space,
    /// tab, line feed and carriage return only, and matched case-sensitively.
    /// Upstream's other role checks (Assertions) work from the unfiltered
    /// value instead (some from the string as written, some from its
    /// lowercased tokens); the port's checks for those use roleTokens(for:)
    /// and firstRoleToken(for:), which A13 leaves alone.
    private func filteredRole(for element: HTMLStartElement) -> FilteredRole? {
        guard let value = roleAttributeValue(for: element) else { return nil }
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
              let last = scalars.lastIndex(where: { $0.value > 0x20 }) else {
            return FilteredRole(roleValue: nil, unrecognized: [], superfluous: [], schemaValue: "")
        }
        let trimmed = String(Substring(scalars[first...last]))
        let tokens = trimmed.unicodeScalars
            .split(whereSeparator: { [" ", "\t", "\n", "\r"].contains($0) })
            .map { String(Substring($0)) }
        var filtered = FilteredRole(roleValue: nil, unrecognized: [], superfluous: [], schemaValue: trimmed)
        for token in tokens {
            if !Self.nonAbstractARIARoles.contains(token) {
                filtered.unrecognized.append(token)
            } else if filtered.roleValue == nil {
                filtered.roleValue = token
            } else if token != "presentation" {
                filtered.superfluous.append(token)
            }
        }
        if let roleValue = filtered.roleValue {
            filtered.schemaValue = roleValue
        }
        return filtered
    }

    /// The role attribute's value, "" for a valueless one (<div role>), as
    /// upstream sees it; nil when there's no role attribute.
    private func roleAttributeValue(for element: HTMLStartElement) -> String? {
        guard element.hasAttribute("role") else { return nil }
        return element.attributeValue("role") ?? ""
    }

    /// The schema's view of an element's role, for the checks that stand in
    /// for the schema's per-element role lists: nil when there's no role
    /// attribute, or when its value isn't one the schema knows at all
    /// (appendRoleTokenMessages has reported "Bad value" for that already).
    private func knownSchemaRole(for element: HTMLStartElement) -> String? {
        guard let schemaValue = filteredRole(for: element)?.schemaValue,
              Self.schemaARIARoles.contains(schemaValue) else { return nil }
        return schemaValue
    }

    /// Upstream's renderTokenList: " token “a”" or " tokens “a”, “b”".
    private func renderedRoleTokenList(_ tokens: [String]) -> String {
        (tokens.count > 1 ? " tokens " : " token ") + tokens.map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")
    }

    private func appendRoleEffectMessages(
        for element: HTMLStartElement,
        role: String?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A2 (U16): not for MathML; and on SVG elements, only a
        // non-empty aria-* value counts (both as vnu.jar reports them).
        guard role == "none" || role == "presentation", .mathML != element.namespace else { return }
        let hasTabindex = element.hasAttribute("tabindex")
        let hasGlobalARIA = element.attributes.contains { attribute in
            attribute.name.hasPrefix("aria-") && attribute.name != "aria-hidden" && (.html == element.namespace || !(attribute.value ?? "").isEmpty)
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
        // Review item A13: for math and select, upstream compares the role
        // attribute as written, so role="MATH" or role="listbox foo" isn't
        // "unnecessary" (the first is a "Bad value", and the second gets the
        // select error instead; see appendRoleTokenMessages and
        // appendSelectRoleMessages).
        if element.name == "math" {
            if "math" == element.attributeValue("role") {
                appendWarningMessage("Element \u{201c}math\u{201d} does not need a \u{201c}role\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            return
        }
        // Review item A2 (U16): the rest are about HTML elements (an SVG <a
        // href> isn't a "link" by default the way HTML's is).
        guard .html == element.namespace else { return }
        if let expected = unnecessaryRole(for: element), expected == role,
           element.name != "select" || expected == element.attributeValue("role") {
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
            } else if "img" == element.name,
                      "img" != element.attributeValue("role") || (element.hasAttribute("alt") && (element.attributeValue("alt") ?? "").isEmpty) {
                // Review item 3: upstream calls role="img" unnecessary on an
                // <img> only when the attribute is exactly "img" (not "IMG",
                // " img " or "img button"; it compares the attribute as
                // written), and not when the <img>'s alt is empty (its own
                // role would be presentation then).
            } else {
                appendWarningMessage("The \u{201c}\(role)\u{201d} role is unnecessary for element \u{201c}\(element.name)\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
    }

    private func appendARIANamingMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A3: this mirrors upstream's isProhibitedFromBeingNamed
        // (Assertions.java). Links and image-map areas with an href are
        // interactive, so ARIA lets authors name them; upstream prohibits a
        // name on "a" and "area" only when there's no href. The port used to
        // prohibit them unconditionally, so every icon, logo, social or
        // pagination link with an aria-label was reported as an error (15
        // errors in 8 of 50 real-world pages). "body" and "rt" were missing
        // from the port's list; they're in upstream's.
        let isNameProhibitedElement: Bool
        switch element.name {
        case "a", "area":
            isNameProhibitedElement = !element.hasAttribute("href")
        default:
            isNameProhibitedElement = Self.ariaNamingProhibitedElements.contains(element.name) || element.name.contains("-")
        }
        guard isNameProhibitedElement else { return }
        // Upstream splits the whole role attribute into lowercase tokens and
        // keeps the prohibition only if ANY token is a role that can't be
        // named; a role attribute with no such token (including an empty one)
        // lifts it. The port used to look only at the first token, and
        // treated an empty role as no role at all, so `role="none
        // presentation"` escaped the error and `role=""` drew one.
        if element.hasAttribute("role") {
            guard roleTokens(for: element).contains(where: { Self.ariaNamingProhibitedRoles.contains($0) }) else {
                return
            }
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
        stack: [String],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A13: upstream's Assertions judge a select's role from
        // the raw attribute value (case-sensitive and untrimmed): with
        // multiple, or a size above 1, any role but listbox is an error (and
        // listbox is merely unnecessary, a warning that
        // appendUnnecessaryRoleMessages gives on the same exact match);
        // otherwise any role but
        // combobox (also unnecessary) and menu is an error. The port used to
        // report other roles on a multiple select as "Bad value" against the
        // first token, which upstream never says here, and checked only
        // listbox on a drop-down select.
        guard element.name == "select", !stack.contains("template"), let rawRole = roleAttributeValue(for: element) else { return }
        // Separately, upstream's schema (web-forms.rnc) allows only these
        // roles on a select, judged as the schema sees the value (see
        // filteredRole(for:)); unknown values got their "Bad value" from
        // appendRoleTokenMessages. (Upstream reports none of this inside a
        // template's contents.)
        if let schemaRole = knownSchemaRole(for: element), !Self.selectSchemaRoles.contains(schemaRole) {
            appendBadAttributeValue(schemaRole, attribute: "role", for: element, locations: locations, messages: &messages)
        }
        if allowsMultipleSelection(element) {
            if rawRole != "listbox" {
                appendMessage("A \u{201c}select\u{201d} element with a \u{201c}multiple\u{201d} attribute or with a \u{201c}size\u{201d} attribute whose value is greater than 1 must not have any \u{201c}role\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
        } else if rawRole != "combobox", rawRole != "menu" {
            appendMessage("The \u{201c}\(rawRole)\u{201d} role is not allowed for element \u{201c}select\u{201d} without a \u{201c}multiple\u{201d} attribute and without a \u{201c}size\u{201d} attribute whose value is greater than 1.", for: element, locations: locations, messages: &messages)
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
        // Review item A13: the schema's value (case-sensitive), so that
        // role="Separator" gets only appendRoleTokenMessages's "Bad value".
        if (element.name == "br" || element.name == "wbr"), knownSchemaRole(for: element) == "separator" {
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

    /// Review item 3: upstream's rules for an <img>'s text alternative
    /// (Assertions.java), in its order (see ImageTextAlternativeFacts). With
    /// no alt, aria-label or aria-labelledby attribute: a role is "must also
    /// have an accessible name"; otherwise any other aria-* attribute with a
    /// value is the ARIA version of that; otherwise a non-empty title is
    /// enough, and without one the <img> needs an alt attribute, which this
    /// returns true for. With one of them and a role: an empty alt is an
    /// error, and so is a role of none or presentation with any other. The
    /// port used to report a missing alt regardless, and to count title (but
    /// not an empty alt) as an accessible name for the role and ARIA
    /// messages, which upstream doesn't.
    private func appendImageTextAlternativeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) -> Bool {
        // Review item A13: this stands in for the schema's list of img
        // roles, so it judges the value the schema sees (the first
        // recognized role), not the first token: role="foo img" is an img.
        // Values the schema doesn't know at all are reported (once) by
        // appendRoleTokenMessages.
        if let schemaRole = knownSchemaRole(for: element), !Self.imgAllowedRoles.contains(schemaRole) {
            appendBadAttributeValue(schemaRole, attribute: "role", for: element, locations: locations, messages: &messages)
        }
        let facts = ImageTextAlternativeFacts(attributes: element.attributes)
        if facts.lacksTextAlternativeAttributes {
            if facts.hasRole {
                appendMessage("An \u{201c}img\u{201d} element with a \u{201c}role\u{201d} attribute must also have an accessible name (e.g., an \u{201c}alt\u{201d} attribute).", for: element, locations: locations, messages: &messages)
            } else if facts.hasOtherARIA {
                appendMessage("An \u{201c}img\u{201d} element with any \u{201c}aria-*\u{201d} attributes other than \u{201c}aria-hidden\u{201d} must also have an accessible name. (e.g., an \u{201c}alt\u{201d} attribute).", for: element, locations: locations, messages: &messages)
            }
            return facts.needsAlt
        }
        if facts.hasRole {
            if "" == facts.alt {
                appendMessage("An \u{201c}img\u{201d} element with a \u{201c}role\u{201d} attribute must not have an \u{201c}alt\u{201d} attribute whose value is the empty string.", for: element, locations: locations, messages: &messages)
            } else {
                // (Upstream's own wording, without a final period, for each
                // token of the role as written, as Java's role.trim()
                // .toLowerCase().split("\\s+") makes them: every code point
                // up to U+0020 off both ends, then split at runs of space,
                // tab, LF, VT, FF and CR, scalar by scalar, so that "\r\n",
                // one Character in Swift, separates too.)
                let scalars = facts.role.unicodeScalars
                let trimmed = scalars.firstIndex(where: { $0.value > 0x20 }).flatMap { first in
                    scalars.lastIndex(where: { $0.value > 0x20 }).map { String(Substring(scalars[first...$0])) }
                } ?? ""
                let tokens = trimmed.lowercased().unicodeScalars
                    .split { " " == $0 || "\t" == $0 || "\n" == $0 || "\r" == $0 || "\u{0B}" == $0 || "\u{0C}" == $0 }
                    .map { String(Substring($0)) }
                for token in tokens where "none" == token || "presentation" == token {
                    appendMessage("Bad value \u{201c}\(token)\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}img\u{201d}", for: element, locations: locations, messages: &messages)
                }
            }
        }
        return false
    }

    /// Case 554591 (item 4): a figure's end, as upstream's Assertions checker
    /// has it, in its order: the role rule, the <img> elements the figure
    /// kept back (see appendFigureAltMessages), and the table caption rule.
    ///
    /// A figure with text in a figcaption (see FigureAltRecord) may have no
    /// role but figure or doc-example, compared as written once its
    /// references are decoded (role="FIGURE" or "figure " won't do). This is
    /// reported at the figure's end tag, as upstream reports it (at its start
    /// tag when the end is implied, as the event has no other place). It used
    /// to be reported as soon as a figcaption started, at the figure, for any
    /// role, whatever was in the caption: role="figure" and
    /// role="doc-example" were errors, and so was a role with an empty
    /// caption.
    ///
    /// And when a figure's HTML children are a figcaption and a table with a
    /// <caption>, and nothing else, that caption should be left out in favor
    /// of the figcaption: a warning, at the caption. It used to be given for
    /// any caption of any table anywhere in a figure, whatever else it had.
    private func appendFigureEndMessages(
        _ record: FigureAltRecord,
        endRange: HTMLSourceRange?,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (A role attribute with no value is an empty role, as upstream reads
        // it.)
        if record.figcaptionContentFound, record.figure.hasAttribute("role") {
            let role = HTMLCharacterReferences.decode(record.figure.attributeValue("role") ?? "")
            if "figure" != role, "doc-example" != role {
                appendMessage("A \u{201c}figure\u{201d} element with a \u{201c}figcaption\u{201d} descendant must not have a \u{201c}role\u{201d} attribute.", range: endRange ?? record.figure.range, locations: locations, messages: &messages)
            }
        }
        appendFigureAltMessages(record, locations: locations, messages: &messages)
        if let caption = record.nestedTableCaption, 2 == record.htmlChildCount, record.hasFigcaptionChild, record.hasTableChild {
            appendWarningMessage("When a \u{201c}table\u{201d} element is the only content in a \u{201c}figure\u{201d} element other than the \u{201c}figcaption\u{201d}, the \u{201c}caption\u{201d} element should be omitted in favor of the \u{201c}figcaption\u{201d}.", for: caption, locations: locations, messages: &messages)
        }
    }

    /// Review item 3: a figure's end, as upstream has it: the <img>
    /// elements without a text alternative that the figure kept back are
    /// reported, at each <img>, unless the figure's caption has text and
    /// nothing else in it (other text, a second <img>, other embedded
    /// content) does.
    private func appendFigureAltMessages(
        _ record: FigureAltRecord,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard (record.figcaptionNeeded && !record.figcaptionContentFound) || record.textNodeFound || record.embeddedContentFound else { return }
        for image in record.imagesLackingAlt {
            appendMessage(ImageTextAlternativeFacts.missingAltMessage, for: image, locations: locations, messages: &messages)
        }
    }

    /// Review item 3: whether text counts as text for upstream's figure
    /// bookkeeping: anything but its whitespace (space, tab, CR and LF), as
    /// upstream's checker sees it (see FigureAltContext): with character
    /// references decoded where its tokenizer decodes them, and without a NUL
    /// where its tree builder drops one. A form feed counts, but one written
    /// as a reference doesn't: upstream's tokenizer turns that into a space.
    private static func containsFigureText(_ text: String, decodingReferences: Bool, droppingNUL: Bool) -> Bool {
        if text.unicodeScalars.contains("\u{0C}") {
            return true
        }
        let seen = decodingReferences ? HTMLCharacterReferences.decode(text) : text
        return seen.unicodeScalars.contains { !(" " == $0 || "\t" == $0 || "\r" == $0 || "\n" == $0 || "\u{0C}" == $0 || (droppingNUL && "\u{0}" == $0)) }
    }

    /// Review item 3: whether text is a CDATA section's (in SVG or MathML),
    /// which the tokenizer hands on as text starting right after the
    /// "<![CDATA[" (see HTMLTokenizer.tokenizeAndBuildTree); upstream reads
    /// it as written.
    private static func isCDATASection(_ range: HTMLSourceRange, locations: SourceLocationMap) -> Bool {
        range.offset >= 9 && "<![CDATA[" == locations.extract(offset: range.offset - 9, length: 9, context: 0).text
    }

    /// Review item 3: the HTML elements whose text upstream's tokenizer reads
    /// as raw text (or script data), with no character references.
    static let rawTextElements: Set<String> = ["iframe", "noembed", "noframes", "plaintext", "script", "style", "xmp"]

    /// Case 554591 (A20, from its review): the HTML elements whose start tag
    /// makes upstream's tree builder drop a line feed at the start of the
    /// text that follows it (see the <time> text check in the .characters
    /// case).
    private static let lineFeedDroppingElements: Set<String> = ["listing", "pre", "textarea"]

    /// Case 554591 (A20, from its review): whether `text` is nothing but
    /// "</>"s, which upstream's tokenizer reports ("End tag had no name.")
    /// and drops, so that its tree builder never sees them (see the <time>
    /// text check's line feed in the .characters case).
    private static func isOnlyEmptyEndTags(_ text: String) -> Bool {
        var rest = Substring(text)
        while rest.hasPrefix("</>") {
            rest = rest.dropFirst(3)
        }
        return rest.isEmpty
    }

    /// Case 554591 (A20, from its review): text, as written, that starts a
    /// <pre>, <listing> or <textarea>, without the line feed upstream's tree
    /// builder drops there: an LF, a CRLF or a CR (which upstream's input
    /// stream reads as an LF), or a character reference to U+000A (though
    /// not one to U+000D, which upstream keeps). It may come after NULs,
    /// which reach upstream's tree builder another way and so don't stop the
    /// drop; they stay, for the caller to drop or keep as it does any NUL.
    private static func droppingLeadingLineFeed(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        while start < scalars.count, "\u{0}" == scalars[start] {
            start += 1
        }
        guard start < scalars.count else {
            return text
        }
        let end: Int
        if "\r" == scalars[start] {
            end = start + 1 < scalars.count && "\n" == scalars[start + 1] ? start + 2 : start + 1
        } else if "\n" == scalars[start] {
            end = start + 1
        } else if "&" == scalars[start], let reference = HTMLCharacterReferences.reference(in: scalars, at: start), "\n" == reference.scalar {
            end = reference.next
        } else {
            return text
        }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[..<start])
        kept.append(contentsOf: scalars[end...])
        return String(kept)
    }

    /// Review item 3: the embedded content that keeps a figure's caption from
    /// standing in for an <img>'s alt (upstream's list also names math and
    /// svg, which are never HTML elements).
    private static let figureEmbeddedContentElements: Set<String> = ["audio", "canvas", "embed", "iframe", "object", "video"]

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
        // Review item A13: a schema rule (aria.rnc), so it applies to the
        // schema's value, case-sensitively: not to role="COMBOBOX".
        if element.name == "select", knownSchemaRole(for: element) == "combobox", !element.hasAttribute("aria-expanded") {
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
        // Review item A2 (U16): the option, cell and row rules apply in every
        // namespace, as vnu.jar applies them; the others are about HTML
        // elements (and HTML headings), so a foreign element skips them.
        let isHTML = .html == element.namespace
        if isHTML, "a" == element.name, element.hasAttribute("href"),
           let ancestorRole = roleStack.compactMap({ $0 }).last(where: { Self.prohibitedInteractiveAncestorRoles.contains($0) }) {
            appendMessage("The element \u{201c}a\u{201d} with the attribute \u{201c}href\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=\(ancestorRole)\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if isHTML, element.hasAttribute("tabindex"),
           let ancestorRole = roleStack.compactMap({ $0 }).last(where: { $0 == "option" || $0 == "tab" }) {
            appendMessage("An element with the attribute \u{201c}tabindex\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=\(ancestorRole)\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        if isHTML, let role, Self.headingProhibitedRoles.contains(role), stack.contains(where: { Self.headingElements.contains($0) }) {
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
        if isHTML, role == "group", roleStack.last == "list" {
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
        if isHTML, roleStack.last == "group", let role {
            if roleStack.contains(where: { $0 == "menu" || $0 == "menubar" }),
               !["menuitem", "menuitemcheckbox", "menuitemradio"].contains(role) {
                appendMessage("An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=menu\u{201d} or \u{201c}role=menubar\u{201d} must contain only elements with \u{201c}role=menuitem\u{201d}, \u{201c}role=menuitemcheckbox\u{201d}, or \u{201c}role=menuitemradio\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if roleStack.contains(where: { $0 == "tree" }), role != "treeitem" {
                appendMessage("An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=tree\u{201d} must contain only elements with \u{201c}role=treeitem\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        if isHTML, roleStack.last == "rowgroup", role != "row" {
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
        // (Case 554591, A20: an attribute written with no value is an empty
        // one, which is a bad value; this let it through.)
        guard element.hasAttribute("datetime") else { return }
        let rawValue = element.attributeValue("datetime") ?? ""

        // Case 554591 (A20): upstream's datatypes (see HTMLDatetimeDatatype):
        // a <time>'s is TimeDatetime, an ins's or del's DatetimeTz or Date.
        // The value as upstream sees it, its references decoded: the port
        // judged the written value, so datetime="&#50;024" was a bad value.
        let value = HTMLCharacterReferences.decodeAttributeValue(rawValue)
        let outcome: HTMLDatetimeDatatype.Outcome
        switch element.name {
        case "del", "ins":
            outcome = HTMLDatetimeDatatype.checkDatetimeTzOrDate(value)
        case "time":
            outcome = HTMLDatetimeDatatype.checkTimeDatetime(value)
        default:
            return
        }
        appendDatetimeAttributeMessage(outcome, value: value, attribute: "datetime", for: element, locations: locations, messages: &messages)
    }

    /// Case 554591 (A20): a date or time attribute's message, for what
    /// HTMLDatetimeDatatype found: "Bad value …" for an error, and the same
    /// words as a warning for a warning. The words are TestRunner's, which
    /// the upstream fixtures and the ratchet expect, and which the port uses
    /// for its other datatype warnings (a deprecated language subtag); vnu.jar
    /// shows a warning as "Potentially bad value …", and both with the reason
    /// after a colon. (The port gave every warning as an error.)
    private func appendDatetimeAttributeMessage(
        _ outcome: HTMLDatetimeDatatype.Outcome,
        value: String,
        attribute: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        switch outcome {
        case .valid:
            return
        case .error:
            appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
        case .warning:
            appendWarningMessage(
                "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute)\u{201d} on element \u{201c}\(element.displayName)\u{201d}.",
                for: element,
                locations: locations,
                messages: &messages
            )
        }
    }

    private func appendInputAttributeMessages(
        for element: HTMLStartElement,
        idElementNames: [String: String],
        schemaChecksApply: Bool,
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
        appendInputValueMessages(for: element, type: type, schemaChecksApply: schemaChecksApply, locations: locations, messages: &messages)
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
        schemaChecksApply: Bool,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A15: the schema's color value is `"" | form.data.color`
        // (web-forms2.rnc), so an empty value is valid, as it already was for
        // number.
        if type == "color", let value = element.attributeValue("value"), !value.isEmpty, !isValidColorInputValue(value) {
            appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
        }
        if type == "number", let value = element.attributeValue("value"), !value.isEmpty, !isValidFloatingPointNumber(value) {
            appendBadAttributeValue(value, attribute: "value", for: element, locations: locations, messages: &messages)
        }
        // For range, though, min, max and value are all plain
        // common.data.float, with no empty alternative. The port checked only
        // min, and let an empty one through, so it missed errors upstream
        // reports, such as <input type=range value="">.
        if type == "range" {
            for attribute in ["min", "max", "value"] {
                if let value = element.attributeValue(attribute), !isValidFloatingPointNumber(value) {
                    appendBadAttributeValue(value, attribute: attribute, for: element, locations: locations, messages: &messages)
                }
            }
        }
        // (Case 554591, A20: only where the schema checks the element, as
        // for a <time>'s datetime; see foreignSchemaChecksApply. The other
        // value checks here still run everywhere.)
        if schemaChecksApply {
            appendInputDateTimeValueMessages(for: element, type: type, locations: locations, messages: &messages)
        }
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
        // Case 554591 (A20): upstream's datatypes for these input types
        // (form-datatypes.rnc; see HTMLDatetimeDatatype), with their warnings,
        // on the values as upstream sees them, their references decoded. The
        // port took only a four-digit year from 1000 on, so a date of
        // 0999-12-31 was an error where vnu.jar only warns; and it took week
        // 53 of any year, where upstream's Week takes it only in a year that
        // has one.
        let check: (String) -> HTMLDatetimeDatatype.Outcome
        switch type {
        case "date":
            check = HTMLDatetimeDatatype.checkDate
        case "datetime-local":
            check = HTMLDatetimeDatatype.checkDatetimeLocal
        case "month":
            check = HTMLDatetimeDatatype.checkMonth
        case "time":
            check = HTMLDatetimeDatatype.checkTime
        case "week":
            check = HTMLDatetimeDatatype.checkWeek
        default:
            return
        }

        // (min and max may not be empty, so one written with no value is a
        // bad value; this let it through.)
        for attribute in ["min", "max"] where element.hasAttribute(attribute) {
            let value = HTMLCharacterReferences.decodeAttributeValue(element.attributeValue(attribute) ?? "")
            appendDatetimeAttributeMessage(check(value), value: value, attribute: attribute, for: element, locations: locations, messages: &messages)
        }
        // (An empty value is allowed: the schema's w:string "" alternative.)
        if let rawValue = element.attributeValue("value"), !rawValue.isEmpty {
            let value = HTMLCharacterReferences.decodeAttributeValue(rawValue)
            appendDatetimeAttributeMessage(check(value), value: value, attribute: "value", for: element, locations: locations, messages: &messages)
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
                // Review item A4: with upstream's Note when the parent is transparent.
                HTMLVocabulary.notAllowedAsChildMessage("style", parent: parent),
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

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= Self.zero && byte <= UInt8(ascii: "9")
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

    // Review item A2: the SVG elements whose attribute lists include ARIA's
    // (common.attrs.aria) in upstream's svg11 schema, lowercased as the
    // tokenizer produces them.
    private static let svgARIAElements: Set<String> = [
        "a", "altglyph", "circle", "ellipse", "foreignobject", "g", "glyph", "glyphref", "image",
        "line", "path", "polygon", "polyline", "rect", "svg", "symbol", "text", "tspan", "use"
    ]

    // Review item A2/U19: how many child elements these MathML elements take
    // (upstream's mathml3-presentation.rnc).
    private static let mathElementArity: [String: Int] = [
        "mfrac": 2, "mover": 2, "mroot": 2, "msub": 2, "msup": 2, "munder": 2,
        "msubsup": 3, "munderover": 3
    ]

    private static let mathRequiredChildren: [String] = [
        "abs", "and", "apply", "approx", "arccos", "arccosh", "arccot", "arccoth",
        "arccsc", "arccsch", "arcsec", "arcsech", "arcsin", "arcsinh", "arctan", "arctanh",
        "arg", "bind", "card", "cartesianproduct", "cbytes", "ceiling", "cerror", "ci",
        "cn", "codomain", "complexes", "compose", "conjugate", "cos", "cosh", "cot",
        "coth", "cs", "csc", "csch", "csymbol", "curl", "declare", "determinant",
        "diff", "divergence", "divide", "domain", "emptyset", "eq", "equivalent", "eulergamma",
        "exists", "exp", "exponentiale", "factorial", "factorof", "false", "floor", "fn",
        "forall", "gcd", "geq", "grad", "gt", "ident", "image", "imaginary",
        "imaginaryi", "implies", "in", "infinity", "int", "integers", "intersect", "interval",
        "inverse", "lambda", "laplacian", "lcm", "leq", "limit", "list", "ln",
        "log", "lt", "maction", "maligngroup", "malignmark", "matrix", "matrixrow", "max",
        "mean", "median", "menclose", "merror", "mfenced", "mfrac", "mi", "min",
        "minus", "mlongdiv", "mmultiscripts", "mn", "mo", "mode", "moment", "mover",
        "mpadded", "mphantom", "mroot", "mrow", "ms", "mspace", "msqrt", "mstack",
        "mstyle", "msub", "msubsup", "msup", "mtable", "mtext", "munder", "munderover",
        "naturalnumbers", "neq", "not", "notanumber", "notin", "notprsubset", "notsubset", "or",
        "outerproduct", "partialdiff", "pi", "piecewise", "plus", "power", "primes", "product",
        "prsubset", "quotient", "rationals", "real", "reals", "reln", "rem", "root",
        "scalarproduct", "sdev", "sec", "sech", "selector", "semantics", "set", "setdiff",
        "share", "sin", "sinh", "subset", "sum", "tan", "tanh", "tendsto",
        "times", "transpose", "true", "union", "variance", "vector", "vectorproduct", "xor"
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

    // Review item A13: upstream's NON_ABSTRACT_ARIA_ROLES
    // (RoleAttributeFilteringContentHandlerWrapper.java), exactly. A role
    // attribute's first token from this set is the role browsers use.
    private static let nonAbstractARIARoles: Set<String> = [
        "alert", "alertdialog", "application", "article", "banner", "button", "cell",
        "checkbox", "columnheader", "combobox", "complementary", "contentinfo", "definition",
        "dialog", "directory", "doc-abstract", "doc-acknowledgments", "doc-afterword",
        "doc-appendix", "doc-backlink", "doc-biblioentry", "doc-bibliography", "doc-biblioref",
        "doc-chapter", "doc-colophon", "doc-conclusion", "doc-cover", "doc-credit",
        "doc-credits", "doc-dedication", "doc-endnote", "doc-endnotes", "doc-epigraph",
        "doc-epilogue", "doc-errata", "doc-example", "doc-footnote", "doc-foreword",
        "doc-glossary", "doc-glossref", "doc-index", "doc-introduction", "doc-noteref",
        "doc-notice", "doc-pagebreak", "doc-pagelist", "doc-part", "doc-preface",
        "doc-prologue", "doc-pullquote", "doc-qna", "doc-subtitle", "doc-tip", "doc-toc",
        "document", "feed", "figure", "form", "graphics-document", "graphics-object",
        "graphics-symbol", "grid", "gridcell", "group", "heading", "img", "link", "list",
        "listbox", "listitem", "log", "main", "marquee", "math", "menu", "menubar", "menuitem",
        "menuitemcheckbox", "menuitemradio", "navigation", "none", "note", "option",
        "presentation", "progressbar", "radio", "radiogroup", "region", "row", "rowgroup",
        "rowheader", "scrollbar", "search", "searchbox", "separator", "slider", "spinbutton",
        "status", "switch", "tab", "table", "tablist", "tabpanel", "term", "textbox", "timer",
        "toolbar", "tooltip", "tree", "treegrid", "treeitem"
    ]

    // Every role value upstream's schema (schema/html5/*.rnc) accepts for
    // some element: the set above less "directory" (deprecated), plus
    // roles that browsers don't treat as non-abstract but the schema still
    // allows on their own, such as paragraph, code, meter and time.
    private static let schemaARIARoles: Set<String> = [
        "alert", "alertdialog", "application", "article", "banner", "blockquote", "button",
        "caption", "cell", "checkbox", "code", "columnheader", "combobox", "complementary",
        "contentinfo", "definition", "deletion", "dialog", "doc-abstract",
        "doc-acknowledgments", "doc-afterword", "doc-appendix", "doc-backlink",
        "doc-biblioentry", "doc-bibliography", "doc-biblioref", "doc-chapter", "doc-colophon",
        "doc-conclusion", "doc-cover", "doc-credit", "doc-credits", "doc-dedication",
        "doc-endnote", "doc-endnotes", "doc-epigraph", "doc-epilogue", "doc-errata",
        "doc-example", "doc-footnote", "doc-foreword", "doc-glossary", "doc-glossref",
        "doc-index", "doc-introduction", "doc-noteref", "doc-notice", "doc-pagebreak",
        "doc-pagelist", "doc-part", "doc-preface", "doc-prologue", "doc-pullquote", "doc-qna",
        "doc-subtitle", "doc-tip", "doc-toc", "document", "emphasis", "feed", "figure", "form",
        "graphics-document", "graphics-object", "graphics-symbol", "grid", "gridcell", "group",
        "heading", "image", "img", "insertion", "link", "list", "listbox", "listitem", "log",
        "main", "marquee", "math", "menu", "menubar", "menuitem", "menuitemcheckbox",
        "menuitemradio", "meter", "navigation", "none", "note", "option", "paragraph",
        "presentation", "progressbar", "radio", "radiogroup", "region", "row", "rowgroup",
        "rowheader", "scrollbar", "search", "searchbox", "separator", "slider", "spinbutton",
        "status", "strong", "subscript", "superscript", "switch", "tab", "table", "tablist",
        "tabpanel", "term", "textbox", "time", "timer", "toolbar", "tooltip", "tree",
        "treegrid", "treeitem"
    ]

    // Upstream's isProhibitedFromBeingNamed list, less "a" and "area", which
    // are prohibited only without an href (see appendARIANamingMessages).
    private static let ariaNamingProhibitedElements: Set<String> = [
        "abbr", "b", "bdi", "bdo", "body", "caption", "cite", "code", "data", "del",
        "div", "em", "figcaption", "i", "ins", "kbd", "legend", "mark", "p", "pre", "q",
        "rp", "rt", "s", "samp", "small", "span", "strong", "sub", "sup", "time", "u", "var"
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

    // select.attrs in upstream's web-forms.rnc.
    private static let selectSchemaRoles: Set<String> = ["combobox", "listbox", "menu"]

    // img.attrs in upstream's embed.rnc. (Review item 3: math, none,
    // presentation, radio and doc-cover were missing, so the very common
    // <img alt="" role="presentation"> was a "Bad value".)
    private static let imgAllowedRoles: Set<String> = [
        "button", "checkbox", "doc-cover", "img", "link", "math", "menuitem", "menuitemcheckbox",
        "menuitemradio", "none", "option", "presentation", "progressbar", "radio", "scrollbar",
        "separator", "slider", "switch", "tab", "treeitem"
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

    /// The number in a heading's name, for an HTML h1–h6 only. (Case 554591,
    /// item 3, from its review: upstream's HeadingHierarchyChecker knows only
    /// those six names. This took "h" and any one character Unicode gives
    /// a value of 1 to 6, so unknown elements such as <h١> (an Arabic-Indic
    /// 1), <h¹> and <h１> counted as headings once item 3 began noting every
    /// heading's level as it starts.)
    private static func headingLevel(for name: String) -> Int? {
        guard headingElements.contains(name), let digit = name.utf8.last else {
            return nil
        }
        return Int(digit - UInt8(ascii: "0"))
    }

    private static let zero = UInt8(ascii: "0")

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

    private func appendWarningMessage(
        _ message: String,
        range: HTMLSourceRange,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        messages.append(.warning(
            message,
            location: locations.location(offset: range.offset, length: range.length),
            extract: locations.extract(offset: range.offset, length: range.length)
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

/// Review item A2/U19: SVG path data, accepted and rejected as upstream's
/// SvgPathData datatype does (it follows Batik's path parser). The port used
/// a pattern fitted to a few fixtures, which rejected any arc whose radius
/// or rotation had a digit from 2 to 9 ("A 5 5 0 0 1 20 50"), so ordinary
/// icons were errors, and accepted most malformed data.
///
/// The rules: commands may come in any order, separated by whitespace (space,
/// tab, CR, LF); Z takes no arguments; every other command takes one or more
/// groups of arguments (M, L, T: 2; H, V: 1; Q, S: 4; C: 6; A: rx, ry,
/// rotation, two flags, x, y). Arguments are separated by whitespace and at
/// most one comma; after a group, a comma means another group must follow.
/// A number is an optional sign, then digits with an optional fraction
/// ("1." is fine) or a fraction alone (".5"), then an optional exponent; one
/// number can end where the next begins ("1-2", "0.5.5"). An arc flag is a
/// single "0" or "1". The empty string is valid. (And one quirk: see
/// parseNumber.)
enum SVGPathData {
    static func isValid(_ value: String) -> Bool {
        var parser = Parser(scalars: Array(value.unicodeScalars))
        return parser.parse()
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        private var current: Unicode.Scalar? {
            index < scalars.count ? scalars[index] : nil
        }

        private static func isSpace(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return " " == scalar || "\t" == scalar || "\r" == scalar || "\n" == scalar
        }

        private static func isDigit(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return ("0"..."9").contains(scalar)
        }

        private static func startsNumber(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar else { return false }
            return isDigit(scalar) || "+" == scalar || "-" == scalar || "." == scalar
        }

        /// How many arguments one group of each command has, with the arc
        /// flags' positions marked.
        private static let groupSizes: [Unicode.Scalar: Int] = [
            "m": 2, "l": 2, "t": 2, "h": 1, "v": 1, "q": 4, "s": 4, "c": 6, "a": 7
        ]

        mutating func parse() -> Bool {
            while let scalar = current {
                if Self.isSpace(scalar) || "z" == scalar || "Z" == scalar {
                    index += 1
                } else if scalar.isASCII, let size = Self.groupSizes[Unicode.Scalar(UInt8(scalar.value) | 0x20)] {
                    index += 1
                    guard parseGroups(size: size, isArc: 7 == size) else { return false }
                } else {
                    return false
                }
            }
            return true
        }

        /// One or more groups of a command's arguments.
        private mutating func parseGroups(size: Int, isArc: Bool) -> Bool {
            skipSpaces()
            var expectGroup = true
            while true {
                guard Self.startsNumber(current) else { return !expectGroup }
                for argument in 0..<size {
                    if isArc, 3 == argument || 4 == argument {
                        guard let flag = current, "0" == flag || "1" == flag else { return false }
                        index += 1
                    } else {
                        guard parseNumber() else { return false }
                    }
                    if argument < size - 1 {
                        _ = skipCommaSpaces()
                    }
                }
                expectGroup = skipCommaSpaces()
            }
        }

        private mutating func skipSpaces() {
            while Self.isSpace(current) {
                index += 1
            }
        }

        /// Whitespace and at most one comma; returns whether there was a comma.
        private mutating func skipCommaSpaces() -> Bool {
            skipSpaces()
            guard "," == current else { return false }
            index += 1
            skipSpaces()
            return true
        }

        private mutating func parseNumber() -> Bool {
            if "+" == current || "-" == current {
                index += 1
            }
            var sawIntegerDigits = false
            var sawFractionDigits = false
            var fractionIsAllZeros = true
            while Self.isDigit(current) {
                index += 1
                sawIntegerDigits = true
            }
            if "." == current {
                index += 1
                while let digit = current, Self.isDigit(digit) {
                    if "0" != digit {
                        fractionIsAllZeros = false
                    }
                    index += 1
                    sawFractionDigits = true
                }
            }
            guard sawIntegerDigits || sawFractionDigits else { return false }
            // Batik's quirk, which upstream keeps: a fraction made only of
            // zeros, with no integer part (".0"), ends the number before any
            // exponent, so ".0e1" is invalid while "0.0e1" and ".5e1" are fine.
            if !sawIntegerDigits, fractionIsAllZeros {
                return true
            }
            if "e" == current || "E" == current {
                index += 1
                if "+" == current || "-" == current {
                    index += 1
                }
                guard Self.isDigit(current) else { return false }
                while Self.isDigit(current) {
                    index += 1
                }
            }
            return true
        }
    }
}

/// Case 554591 (A20): upstream's date and time datatypes, as vnu.jar runs
/// them (nu.validator.datatype). TimeDatetime is for a <time>'s datetime
/// attribute, and for the text of a <time> without one; DatetimeTz or Date is
/// what an ins or del datetime may be; and Date, DatetimeLocal, Month, Week
/// and Time are for those input types' min, max and value. TimeDatetime,
/// Date, DatetimeTz and DatetimeLocal share AbstractDatetime's checks, with
/// the warnings vnu.jar's command line turns on (nu.validator.datatype.warn,
/// which TestRunner sets too); Time, Month and Week have their own checks,
/// and give no warnings.
///
/// The port's checks were a subset. A <time datetime> took only a date, a
/// time, or a local or global date and time, with a four-digit year from 1000
/// on. So durations (PT15M, schema.org's Recipe example, P2D and 1h 30m),
/// years (2024), months (2024-05), weeks (2024-W18), yearless dates (05-17)
/// and time-zone offsets (+05:30) were bad values: 13 of the real pages'
/// false errors. And what upstream only warns about was an error: a year
/// before 1000 or from 3000 on, and, for ins and del, an offset outside
/// UTC−12 to UTC+12 or with minutes other than 00, 30 or 45. Values are
/// decoded first, as upstream's tokenizer hands them on (see
/// HTMLCharacterReferences.decodeAttributeValue).
///
/// Each pattern here is ASCII, and in each a run of digits is followed by
/// something that isn't a digit, so taking a whole run, as the scanner does,
/// is what the regular expressions' backtracking ends up with; and their
/// alternatives are anchored at both ends and never overlap, so trying each
/// in turn on the whole value finds the one upstream's would.
enum HTMLDatetimeDatatype {
    /// What a value is: valid, or one of upstream's errors or warnings, with
    /// its reason (in vnu.jar, the text after "Bad value “…” for attribute
    /// “…” on element “…”:"). The port's attribute messages leave the reason
    /// out, as TestRunner's and the upstream fixtures' do; a <time>'s text
    /// content messages give it, as both of upstream's do.
    enum Outcome: Equatable {
        case valid
        case error(String)
        case warning(String)

        /// This, or if it's valid, `next`: upstream throws at the first
        /// problem, a warning too, so nothing after one is checked.
        func then(_ next: () -> Outcome) -> Outcome {
            .valid == self ? next() : self
        }
    }

    // MARK: The datatypes

    /// TimeDatetime ("time-datetime"): THE_PATTERN, in its order, inside
    /// optional space, tab, CR, LF or form feed at either end; and
    /// AbstractDatetime.checkValid's checks for whichever alternative
    /// matched.
    static func checkTimeDatetime(_ value: String) -> Outcome {
        checkTimeDatetime(Array(value.unicodeScalars)[...])
    }

    /// The same, for a <time>'s text, which HTMLGeneralAttributeChecker keeps
    /// as scalars (see its openTimeTexts).
    static func checkTimeDatetime(_ value: ArraySlice<Unicode.Scalar>) -> Outcome {
        var scalars = value
        while let first = scalars.first, isSpace(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, isSpace(last) {
            scalars.removeLast()
        }
        let alternatives: [(inout Reader) -> Outcome?] = [
            monthAlternative, dateAlternative, yearlessDateAlternative, timeAlternative,
            localDateAndTimeAlternative, zoneAlternative, globalDateAndTimeAlternative,
            weekAlternative, yearAlternative, isoDurationAlternative, durationComponentsAlternative
        ]
        for alternative in alternatives {
            var reader = Reader(scalars)
            if let outcome = alternative(&reader) {
                return outcome
            }
        }
        return .error("The literal did not satisfy the time-datetime format.")
    }

    /// Date ("date"): [0-9]{4,}-[0-9]{2}-[0-9]{2}, AbstractDatetime's checks.
    static func checkDate(_ value: String) -> Outcome {
        var reader = Reader(Array(value.unicodeScalars)[...])
        guard let date = scanDate(&reader), reader.atEnd else {
            return .error("The literal did not satisfy the date format.")
        }
        return check(date, reader)
    }

    /// DatetimeTz ("datetime with timezone"): a date, T or a space, a time
    /// with any number of fraction digits (AbstractDatetime then allows
    /// three), and Z or an offset.
    static func checkDatetimeTz(_ value: String) -> Outcome {
        var reader = Reader(Array(value.unicodeScalars)[...])
        guard let date = scanDate(&reader), reader.take("T") || reader.take(" "),
              let time = scanTime(&reader, fractionLimit: nil), let zone = scanZone(&reader), reader.atEnd else {
            return .error("The literal did not satisfy the datetime with timezone format.")
        }
        return check(date, reader).then { check(time, reader) }.then { check(zone, reader) }
    }

    /// DatetimeLocal ("local datetime"): a date, T or a space, and a time
    /// with at most three fraction digits (by the pattern, so more are a
    /// mismatch, not AbstractDatetime's error).
    static func checkDatetimeLocal(_ value: String) -> Outcome {
        var reader = Reader(Array(value.unicodeScalars)[...])
        guard let date = scanDate(&reader), reader.take("T") || reader.take(" "),
              let time = scanTime(&reader, fractionLimit: 3), reader.atEnd else {
            return .error("The literal did not satisfy the local datetime format.")
        }
        return check(date, reader).then { check(time, reader) }
    }

    /// ins and del (revision.rnc: common.data.datetime | common.data.date):
    /// valid if either datatype accepts the value. Otherwise upstream's
    /// message is a warning if either gave a warning (MessageEmitterAdapter
    /// makes it "Potentially bad value", and TestRunner a warning), and an
    /// error if both gave errors. Its reason joins both datatypes' reasons,
    /// in Java's HashMap order; only one is kept here, as the port's
    /// attribute messages don't give them.
    static func checkDatetimeTzOrDate(_ value: String) -> Outcome {
        let datetimeTz = checkDatetimeTz(value)
        let date = checkDate(value)
        if .valid == datetimeTz || .valid == date {
            return .valid
        }
        if case .warning = date {
            return date
        }
        return datetimeTz
    }

    /// Time ("time", for input type=time): its own pattern, with at most
    /// three fraction digits, and its own checks of the hour, minute and
    /// second (none of the fraction).
    static func checkTime(_ value: String) -> Outcome {
        var reader = Reader(Array(value.unicodeScalars)[...])
        guard let time = scanTime(&reader, fractionLimit: 3), reader.atEnd else {
            return .error("The literal did not satisfy the format for time.")
        }
        return checkHour(time.hour, reader).then { checkMinute(time.minute, reader) }.then {
            time.second.map { checkSecond($0, reader) } ?? .valid
        }
    }

    /// Month ("month", for input type=month): its own checks, the year
    /// first, and no warnings. (Upstream's parseInt has no catch here, so a
    /// year past a Java int's range throws out of vnu.jar, which then fails
    /// on the document; this calls it an error.)
    static func checkMonth(_ value: String) -> Outcome {
        var reader = Reader(Array(value.unicodeScalars)[...])
        guard let year = reader.digits(atLeast: 4), reader.take("-"), let month = reader.digits(exactly: 2), reader.atEnd else {
            return .error("The literal did not satisfy the format for month.")
        }
        guard let yearValue = reader.javaInt(year) else {
            return .error("Year or month out of range.")
        }
        let monthValue = reader.javaInt(month) ?? 0
        if yearValue < 1 {
            return .error("Year cannot be less than 1.")
        }
        if monthValue < 1 {
            return .error("Month cannot be less than 1.")
        }
        if monthValue > 12 {
            return .error("Month cannot be greater than 12.")
        }
        return .valid
    }

    /// Week ("week", for input type=week): its own checks, and no warnings.
    /// Week 53 is valid only in the years that have one, which repeat every
    /// 400 years (Week.SPECIAL_YEARS). (A year past a Java int's range: see
    /// checkMonth.)
    static func checkWeek(_ value: String) -> Outcome {
        var reader = Reader(Array(value.unicodeScalars)[...])
        guard let year = reader.digits(atLeast: 4), reader.take("-"), reader.take("W"), let week = reader.digits(exactly: 2), reader.atEnd else {
            return .error("The literal did not satisfy the format for week.")
        }
        guard let yearValue = reader.javaInt(year) else {
            return .error("Year or week out of range.")
        }
        let weekValue = reader.javaInt(week) ?? 0
        if yearValue < 1 {
            return .error("Year cannot be less than 1.")
        }
        if weekValue < 1 {
            return .error("Week cannot be less than 1.")
        }
        if 53 == weekValue ? !weekFiftyThreeYears.contains(yearValue % 400) : weekValue > 53 {
            return .error("Week out of range.")
        }
        return .valid
    }

    /// Week.SPECIAL_YEARS: the years, counted within a 400-year cycle, that
    /// have an ISO week 53.
    private static let weekFiftyThreeYears: Set<Int> = [
        4, 9, 15, 20, 26, 32, 37, 43, 48, 54, 60, 65, 71, 76, 82, 88, 93, 99, 105, 111, 116, 122, 128,
        133, 139, 144, 150, 156, 161, 167, 172, 178, 184, 189, 195, 201, 207, 212, 218, 224, 229, 235,
        240, 246, 252, 257, 263, 268, 274, 280, 285, 291, 296, 303, 308, 314, 320, 325, 331, 336, 342,
        348, 353, 359, 364, 370, 376, 381, 387, 392, 398
    ]

    // MARK: TimeDatetime's alternatives (each nil when it doesn't match)

    /// [0-9]{4,}-[0-9]{2}: a month (groups 1 and 2).
    private static func monthAlternative(_ reader: inout Reader) -> Outcome? {
        guard let year = reader.digits(atLeast: 4), reader.take("-"), let month = reader.digits(exactly: 2), reader.atEnd else {
            return nil
        }
        return checkMonth(year: year, month: month, reader)
    }

    /// A date (groups 3 to 5).
    private static func dateAlternative(_ reader: inout Reader) -> Outcome? {
        guard let date = scanDate(&reader), reader.atEnd else {
            return nil
        }
        return check(date, reader)
    }

    /// [0-9]{2}-[0-9]{2}: a yearless date (groups 6 and 7). Upstream checks
    /// its day only against 1, so 02-30 is fine.
    private static func yearlessDateAlternative(_ reader: inout Reader) -> Outcome? {
        guard let month = reader.digits(exactly: 2), reader.take("-"), let day = reader.digits(exactly: 2), reader.atEnd else {
            return nil
        }
        let monthValue = reader.javaInt(month) ?? 0
        if monthValue < 1 {
            return .error("Month cannot be less than 1.")
        }
        if monthValue > 12 {
            return .error("Month cannot be greater than 12.")
        }
        if (reader.javaInt(day) ?? 0) < 1 {
            return .error("Day cannot be less than 1.")
        }
        return .valid
    }

    /// A time, with any number of fraction digits (groups 8 to 11).
    private static func timeAlternative(_ reader: inout Reader) -> Outcome? {
        guard let time = scanTime(&reader, fractionLimit: nil), reader.atEnd else {
            return nil
        }
        return check(time, reader)
    }

    /// A date, T or a space, and a time (groups 12 to 18).
    private static func localDateAndTimeAlternative(_ reader: inout Reader) -> Outcome? {
        guard let date = scanDate(&reader), reader.take("T") || reader.take(" "),
              let time = scanTime(&reader, fractionLimit: nil), reader.atEnd else {
            return nil
        }
        return check(date, reader).then { check(time, reader) }
    }

    /// Z or an offset (groups 19 and 20).
    private static func zoneAlternative(_ reader: inout Reader) -> Outcome? {
        guard let zone = scanZone(&reader), reader.atEnd else {
            return nil
        }
        return check(zone, reader)
    }

    /// A date, T or a space, a time, and Z or an offset (groups 21 to 29).
    private static func globalDateAndTimeAlternative(_ reader: inout Reader) -> Outcome? {
        guard let date = scanDate(&reader), reader.take("T") || reader.take(" "),
              let time = scanTime(&reader, fractionLimit: nil), let zone = scanZone(&reader), reader.atEnd else {
            return nil
        }
        return check(date, reader).then { check(time, reader) }.then { check(zone, reader) }
    }

    /// [0-9]{4,}-W[0-9]{2}: a week (groups 30 and 31), with
    /// AbstractDatetime's checks, not Week's: any week up to 53.
    private static func weekAlternative(_ reader: inout Reader) -> Outcome? {
        guard let year = reader.digits(atLeast: 4), reader.take("-"), reader.take("W"), let week = reader.digits(exactly: 2), reader.atEnd else {
            return nil
        }
        guard let yearValue = reader.javaInt(year) else {
            return .error("Year or week out of range.")
        }
        let weekValue = reader.javaInt(week) ?? 0
        if weekValue < 1 {
            return .error("Week cannot be less than 1.")
        }
        if weekValue > 53 {
            return .error("Week cannot be greater than 53.")
        }
        return checkYear(yearValue)
    }

    /// [0-9]{4,}: a year (group 32).
    private static func yearAlternative(_ reader: inout Reader) -> Outcome? {
        guard let year = reader.digits(atLeast: 4), reader.atEnd else {
            return nil
        }
        guard let yearValue = reader.javaInt(year) else {
            return .error("Year out of range.")
        }
        return checkYear(yearValue)
    }

    /// P, then either days alone or days (optional) and T with hours,
    /// minutes and seconds, each optional but at least one, in that order:
    /// ISO 8601's duration as HTML takes it (no years, months or weeks). The
    /// seconds' fraction (group 33) is checked.
    private static func isoDurationAlternative(_ reader: inout Reader) -> Outcome? {
        guard reader.take("P") else {
            return nil
        }
        let hasDays = reader.component("D")
        if reader.atEnd {
            return hasDays ? .valid : nil
        }
        guard reader.take("T") else {
            return nil
        }
        var fraction: Range<Int>?
        let hasHours = reader.component("H")
        let hasMinutes = reader.component("M")
        let hasSeconds = reader.seconds(fraction: &fraction)
        guard hasHours || hasMinutes || hasSeconds, reader.atEnd else {
            return nil
        }
        return fraction.map { checkFraction($0) } ?? .valid
    }

    /// One or more components, each optional whitespace, digits, then
    /// optional whitespace and a unit (w, d, h or m, either case), or an
    /// optional fraction, optional whitespace and s: "1h 30m", "4h 18m 3s",
    /// "1.5s". As in Java, the fraction group (34) keeps the last fraction
    /// any component had, and only that one is checked, so "1.1234s 1.5s"
    /// is fine and "1.5s 1.1234s" isn't.
    private static func durationComponentsAlternative(_ reader: inout Reader) -> Outcome? {
        var components = 0
        var lastFraction: Range<Int>?
        while true {
            let start = reader.index
            reader.skipSpaces()
            guard nil != reader.digits(atLeast: 1) else {
                reader.index = start
                break
            }
            let afterDigits = reader.index
            reader.skipSpaces()
            if let unit = reader.current, "wWdDhHmM".unicodeScalars.contains(unit) {
                reader.index += 1
                components += 1
                continue
            }
            reader.index = afterDigits
            var fraction: Range<Int>?
            let beforeFraction = reader.index
            if reader.take(".") {
                if let digits = reader.digits(atLeast: 1) {
                    fraction = digits
                } else {
                    reader.index = beforeFraction
                }
            }
            reader.skipSpaces()
            guard reader.take("s") || reader.take("S") else {
                reader.index = start
                break
            }
            if let fraction {
                lastFraction = fraction
            }
            components += 1
        }
        guard components > 0, reader.atEnd else {
            return nil
        }
        return lastFraction.map { checkFraction($0) } ?? .valid
    }

    // MARK: Pieces of the patterns

    private struct DateParts {
        var year: Range<Int>
        var month: Range<Int>
        var day: Range<Int>
    }

    private struct TimeParts {
        var hour: Range<Int>
        var minute: Range<Int>
        var second: Range<Int>?
        var fraction: Range<Int>?
    }

    private enum Zone {
        case utc
        /// The hours with their sign, and the minutes.
        case offset(negative: Bool, hours: Range<Int>, minutes: Range<Int>)
    }

    /// [0-9]{4,}-[0-9]{2}-[0-9]{2}
    private static func scanDate(_ reader: inout Reader) -> DateParts? {
        guard let year = reader.digits(atLeast: 4), reader.take("-"), let month = reader.digits(exactly: 2),
              reader.take("-"), let day = reader.digits(exactly: 2) else {
            return nil
        }
        return DateParts(year: year, month: month, day: day)
    }

    /// [0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?, with at most `fractionLimit`
    /// fraction digits where the pattern says so ({1,3}). (A colon or point
    /// that its part doesn't follow is left over, and none of these patterns
    /// can take it, so the time can fail at once.)
    private static func scanTime(_ reader: inout Reader, fractionLimit: Int?) -> TimeParts? {
        guard let hour = reader.digits(exactly: 2), reader.take(":"), let minute = reader.digits(exactly: 2) else {
            return nil
        }
        var time = TimeParts(hour: hour, minute: minute, second: nil, fraction: nil)
        guard reader.take(":") else {
            return time
        }
        guard let second = reader.digits(exactly: 2) else {
            return nil
        }
        time.second = second
        guard reader.take(".") else {
            return time
        }
        guard let fraction = reader.digits(atLeast: 1), fractionLimit.map({ fraction.count <= $0 }) ?? true else {
            return nil
        }
        time.fraction = fraction
        return time
    }

    /// Z|[+-][0-9]{2}:?[0-9]{2}
    private static func scanZone(_ reader: inout Reader) -> Zone? {
        if reader.take("Z") {
            return .utc
        }
        let negative = reader.take("-")
        guard negative || reader.take("+"), let hours = reader.digits(exactly: 2) else {
            return nil
        }
        _ = reader.take(":")
        guard let minutes = reader.digits(exactly: 2) else {
            return nil
        }
        return .offset(negative: negative, hours: hours, minutes: minutes)
    }

    // MARK: AbstractDatetime's checks

    /// Days in each month of a year that isn't a leap year.
    private static let daysInMonths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// checkYear, with WARN on.
    private static func checkYear(_ year: Int) -> Outcome {
        if year < 1 {
            return .error("Year cannot be less than 1.")
        }
        if year < 1000 || year >= 3000 {
            return .warning("Year may be mistyped.")
        }
        return .valid
    }

    /// checkMonth: the month, then the year.
    private static func checkMonth(year: Range<Int>, month: Range<Int>, _ reader: Reader) -> Outcome {
        guard let yearValue = reader.javaInt(year) else {
            return .error("Year or month out of range.")
        }
        let monthValue = reader.javaInt(month) ?? 0
        if monthValue < 1 {
            return .error("Month cannot be less than 1.")
        }
        if monthValue > 12 {
            return .error("Month cannot be greater than 12.")
        }
        return checkYear(yearValue)
    }

    /// checkDate: the month, the day (29 February only in a leap year), then
    /// the year.
    private static func check(_ date: DateParts, _ reader: Reader) -> Outcome {
        guard let year = reader.javaInt(date.year) else {
            return .error("Year, month, or day out of range.")
        }
        let month = reader.javaInt(date.month) ?? 0
        let day = reader.javaInt(date.day) ?? 0
        if month < 1 {
            return .error("Month cannot be less than 1.")
        }
        if month > 12 {
            return .error("Month cannot be greater than 12.")
        }
        if day < 1 {
            return .error("Day cannot be less than 1.")
        }
        if day > daysInMonths[month - 1], !(29 == day && 2 == month && (year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100)))) {
            return .error("Day out of range.")
        }
        return checkYear(year)
    }

    /// checkHour, checkMinute, checkSecond and checkMilliSecond, in that
    /// order.
    private static func check(_ time: TimeParts, _ reader: Reader) -> Outcome {
        checkHour(time.hour, reader).then { checkMinute(time.minute, reader) }.then {
            time.second.map { checkSecond($0, reader) } ?? .valid
        }.then {
            time.fraction.map { checkFraction($0) } ?? .valid
        }
    }

    private static func checkHour(_ hour: Range<Int>, _ reader: Reader) -> Outcome {
        (reader.javaInt(hour) ?? 0) > 23 ? .error("Hour cannot be greater than 23.") : .valid
    }

    private static func checkMinute(_ minute: Range<Int>, _ reader: Reader) -> Outcome {
        (reader.javaInt(minute) ?? 0) > 59 ? .error("Minute cannot be greater than 59.") : .valid
    }

    private static func checkSecond(_ second: Range<Int>, _ reader: Reader) -> Outcome {
        (reader.javaInt(second) ?? 0) > 59 ? .error("Second cannot be greater than 59.") : .valid
    }

    /// checkMilliSecond: one to three digits.
    private static func checkFraction(_ fraction: Range<Int>) -> Outcome {
        fraction.count > 3 ? .error("A fraction of a second must be one, two, or three digits.") : .valid
    }

    /// checkTzd, with WARN on: a minus sign on a zero offset, and hours and
    /// minutes out of range, are errors; hours outside −12 to +14, and
    /// minutes other than 00, 30 or 45, are warnings, in that order. (The
    /// odd quotes and missing period are upstream's.)
    private static func check(_ zone: Zone, _ reader: Reader) -> Outcome {
        guard case let .offset(negative, hoursRange, minutesRange) = zone else {
            return .valid
        }
        let magnitude = reader.javaInt(hoursRange) ?? 0
        let hours = negative ? -magnitude : magnitude
        let minutes = reader.javaInt(minutesRange) ?? 0
        if negative, 0 == hours, 0 == minutes {
            return .error("Minus sign not allowed in time zone designator when offset is zero. Use plus sign instead.")
        }
        if hours < -23 || hours > 23 {
            return .error("Hours out of range in time zone designator.")
        }
        if minutes > 59 {
            return .error("Minutes out of range in time zone designator.")
        }
        if hours < -12 || hours > 14 {
            return .warning("Hours in time zone designator should be from \u{201c}-12:00\u{201d} to \u{201d}+14:00\u{201d}")
        }
        if 0 != minutes, 30 != minutes, 45 != minutes {
            return .warning("Minutes in time zone designator should be either \u{201c}00\u{201d}, \u{201c}30\u{201d}, or \u{201c}45\u{201d}.")
        }
        return .valid
    }

    // MARK: The reader

    /// The space, tab, CR, LF and form feed of THE_PATTERN's [ \t\r\n\f].
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        " " == scalar || "\t" == scalar || "\r" == scalar || "\n" == scalar || "\u{0C}" == scalar
    }

    private struct Reader {
        let scalars: ArraySlice<Unicode.Scalar>
        var index: Int

        init(_ scalars: ArraySlice<Unicode.Scalar>) {
            self.scalars = scalars
            self.index = scalars.startIndex
        }

        var atEnd: Bool {
            scalars.endIndex == index
        }

        var current: Unicode.Scalar? {
            index < scalars.endIndex ? scalars[index] : nil
        }

        /// Takes `scalar` if it's next.
        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard scalar == current else {
                return false
            }
            index += 1
            return true
        }

        /// All the ASCII digits from here, if there are at least `minimum`.
        mutating func digits(atLeast minimum: Int) -> Range<Int>? {
            let start = index
            while let scalar = current, ("0"..."9").contains(scalar) {
                index += 1
            }
            guard index - start >= minimum else {
                index = start
                return nil
            }
            return start..<index
        }

        /// Exactly `count` ASCII digits from here.
        mutating func digits(exactly count: Int) -> Range<Int>? {
            let start = index
            for _ in 0..<count {
                guard let scalar = current, ("0"..."9").contains(scalar) else {
                    index = start
                    return nil
                }
                index += 1
            }
            return start..<index
        }

        mutating func skipSpaces() {
            while let scalar = current, HTMLDatetimeDatatype.isSpace(scalar) {
                index += 1
            }
        }

        /// A duration component, [0-9]+ and `unit`, taken if it's next.
        mutating func component(_ unit: Unicode.Scalar) -> Bool {
            let start = index
            guard nil != digits(atLeast: 1), take(unit) else {
                index = start
                return false
            }
            return true
        }

        /// The seconds of an ISO duration, [0-9]+(\.([0-9]+))?S, taken if
        /// they're next, with their fraction.
        mutating func seconds(fraction: inout Range<Int>?) -> Bool {
            let start = index
            guard nil != digits(atLeast: 1) else {
                return false
            }
            var digitsAfterPoint: Range<Int>?
            if take(".") {
                guard let digits = digits(atLeast: 1) else {
                    index = start
                    return false
                }
                digitsAfterPoint = digits
            }
            guard take("S") else {
                index = start
                return false
            }
            fraction = digitsAfterPoint
            return true
        }

        /// Integer.parseInt of a run of ASCII digits: nil past a Java int's
        /// range, where upstream catches a NumberFormatException.
        func javaInt(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                value = value * 10 + Int(scalars[index].value - 0x30)
                if value > Int(Int32.max) {
                    return nil
                }
            }
            return value
        }
    }
}
