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
        // Case 554591 (A14/A16): the open elements as upstream's Assertions
        // keeps them for its ARIA rules (see ARIANode), parallel to stack.
        // (roleStack keeps each element's first lowercased token as written,
        // in any namespace, which the other role rules still go by.)
        var ariaNodeStack: [ARIANode] = []
        // Case 554591 (A14): the rest of those rules' state (see
        // ARIAContextState).
        var ariaContext = ARIAContextState()
        var anchorHrefStack: [Bool] = []
        var labelStack: [LabelState] = []
        var pictureStack: [PictureState] = []
        // Case 554591 (A5's review): the sources upstream's rules for a
        // source that would always match will report, at any picture's
        // following sibling with a srcset (see appendPictureChildMessages).
        // Upstream keeps one list for the whole document (Assertions'
        // siblingSources) and clears it at the end of every picture, so a
        // srcset in a picture inside another picture's rejected child judges
        // the outer picture's sources too; the port kept one list per picture.
        // Each source is judged once, as it's added, and only those with
        // something to report are kept, so a picture with many good sources
        // costs nothing more; one with many empty or "all" ones, each before
        // a srcset sibling, gets a message per pair, n(n-1)/2 of them, as in
        // vnu.jar.
        var alwaysMatchingSources: [AlwaysMatchingSource] = []
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
        let idElementNames = idElementNames(in: document)
        let idLabelableElementNames = idLabelableElementNames(in: document)
        let mapNames = mapNames(in: document)
        var cspState = CSPState()

        // Case 554591 (A14 second review): where the table parts the parser
        // implied end, for ariaNodeStack's record of them (see
        // impliedTableParts): the next of HTMLParsedDocument's
        // impliedColgroupEnds and impliedTablePartEnds to apply.
        var nextImpliedColgroupEnd = 0
        var nextImpliedTablePartEnd = 0

        for (eventIndex, event) in document.events.enumerated() {
            // (Case 554591, A14 second review: those that end before this
            // event, as HTMLValidator's table bookkeeping applies them.)
            while nextImpliedColgroupEnd < document.impliedColgroupEnds.count, document.impliedColgroupEnds[nextImpliedColgroupEnd] <= eventIndex {
                Self.endImpliedColgroup(in: &ariaNodeStack)
                nextImpliedColgroupEnd += 1
            }
            while nextImpliedTablePartEnd < document.impliedTablePartEnds.count, document.impliedTablePartEnds[nextImpliedTablePartEnd].index <= eventIndex {
                Self.endImpliedTablePart(document.impliedTablePartEnds[nextImpliedTablePartEnd].name, in: &ariaNodeStack)
                nextImpliedTablePartEnd += 1
            }
            switch event {
            case let .startElement(element):
                let parent = stack.last
                let role = firstRoleToken(for: element)
                // Case 554591 (A14/A16): see ariaNodeStack. (A14 review: with
                // the table parts the parser implied between this HTML element
                // and its HTML parent; see impliedTableParts.)
                let impliedParts = Self.impliedTableParts(for: element, in: &ariaNodeStack)
                let ariaNode = Self.ariaNode(for: element, parent: ariaNodeStack.last, implied: impliedParts, index: ariaNodeStack.count)
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
                // foreignSchemaChecksApply. Case 554591, A5's review: every
                // entry is the schema's for an HTML element too, so none
                // applies where the schema checks nothing: in template
                // contents, in an SVG desc's or a MathML annotation-xml's
                // any-element content, or inside an element it rejected.
                // <template><a href=x media=print> got "Attribute “media” not
                // allowed on element “a” at this point.", which vnu.jar doesn't
                // give.)
                if foreignSchemaChecksApply {
                    appendDisallowedAttributeMessages(for: element, parent: parent, locations: locations, messages: &messages)
                }
                appendRoleTokenMessages(for: element, parent: parent, stack: stack, foreignSchemaChecksApply: foreignSchemaChecksApply, inTemplateContents: inTemplateContents, locations: locations, messages: &messages)
                // Case 554591 (A14): the schema's judgment of the element's
                // ARIA states and properties (see HTMLARIASchema), right after
                // its judgment of the role, as vnu.jar orders them, and only
                // where the schema checks the element at all (see
                // foreignSchemaChecksApply). (A14's third review: with the
                // attributes written "x=>"; see
                // HTMLParsedDocument.attributesEndedByTag.)
                if foreignSchemaChecksApply {
                    appendARIASchemaMessages(for: element, parent: parentIsHTML ? parent : nil, attributesEndedByTag: document.attributesEndedByTag, locations: locations, messages: &messages)
                }
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
                    // (Case 554591, A14's third review: or once the body has
                    // started, by the parser's model, which some tokens that
                    // start it leave no start tag to show; see
                    // HTMLParsedDocument.bodyStartEvent.)
                    let bodyStartedBefore = document.bodyStartEvent.map { $0 <= eventIndex } ?? false
                    appendBaseMessages(for: element, parent: parent.map { HTMLForeignContent.displayName($0, namespace: parentNamespace) }, reportsMisplacement: baseMisplacementIsReported, sawBodyContentBeforeBase: sawBodyContentBeforeBase || bodyStartedBefore, sawBaseBlockingElement: sawBaseBlockingElement, locations: locations, messages: &messages)
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
                // (Case 554591, A14: and not in template contents, which
                // neither upstream's schema nor its Assertions checker ever
                // sees. These ran there; once role values were decoded, a
                // <figure role="&#102;igure"> in a template got an
                // "unnecessary role" warning that vnu.jar doesn't give.)
                if isHTML || foreignSchemaChecksApply, !inTemplateContents {
                    appendARIAAttributeMessages(
                        for: element,
                        role: role,
                        idElementNames: idElementNames,
                        attributesEndedByTag: document.attributesEndedByTag,
                        stack: stack,
                        roleStack: roleStack,
                        labelStack: labelStack,
                        locations: locations,
                        messages: &messages
                    )
                }
                // Case 554591 (A14/A16): upstream's Assertions rules for ARIA
                // that this unit ports (see appendARIAContextMessages); its
                // checker never sees template contents.
                if !inTemplateContents {
                    appendARIAContextMessages(for: element, node: ariaNode, ancestors: ariaNodeStack, state: &ariaContext, locations: locations, messages: &messages)
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
                    // (Case 554591, A5: a media value is the schema's to check,
                    // so, as with the date and time values above, only where
                    // it checks this element (foreignSchemaChecksApply: not in
                    // template contents, nor in any-element content, nor
                    // inside an element it rejected in foreign content), and
                    // only as the pattern that matches has it; see
                    // schemaMediaRule. The theme-color rule is upstream's
                    // Assertions', which see every HTML element but those in
                    // template contents, after the schema's messages; see
                    // appendMetaMediaNameMessages.)
                    if foreignSchemaChecksApply, element.hasAttribute("media") {
                        // (In the head by the parser's model: a child of the
                        // head, or of the root, or of nothing, as the children
                        // of an implied head, or of the head reopened after
                        // </head>, have no head start in the port's events;
                        // and in any case before the body starts. A5's review:
                        // the port's tree keeps the head open after the
                        // Facebook pixel's <noscript><img …></noscript> in the
                        // head, where upstream's img ends the head and starts
                        // the body, which the port's sections do note; so a
                        // theme-color meta after it, a child of the head in
                        // the port's tree, is in the body for upstream, which
                        // says its media isn't allowed.)
                        let bodyStarted = document.bodyStartEvent.map { $0 <= eventIndex } ?? false
                        let inHead = parentIsHTML && !bodyStarted && ("head" == parent || "html" == parent || nil == parent)
                        let rule = Self.schemaMediaRule(
                            for: element,
                            parent: parentIsHTML ? parent : nil,
                            inHead: inHead,
                            bodyStarted: bodyStarted,
                            mediaElement: mediaStack.last?.element,
                            pictureSawImage: pictureStack.last?.sawImage ?? false
                        )
                        switch rule {
                        case .value:
                            appendMediaAttributeMessages(for: element, locations: locations, messages: &messages)
                        case .notAllowed:
                            appendAttributeNotAllowed("media", for: element, locations: locations, messages: &messages)
                        case .unchecked:
                            break
                        }
                    }
                    if !inTemplateContents {
                        appendMetaMediaNameMessages(for: element, locations: locations, messages: &messages)
                    }
                    appendResponsiveImageMessages(for: element, stack: stack, locations: locations, messages: &messages)
                    appendLabelDescendantMessages(for: element, labelStack: &labelStack, locations: locations, messages: &messages)
                }
                if parentIsHTML, parent == "picture", let pictureIndex = pictureStack.indices.last {
                    appendPictureChildMessages(for: element, state: &pictureStack[pictureIndex], alwaysMatchingSources: &alwaysMatchingSources, locations: locations, messages: &messages)
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
                    pictureStack.append(PictureState(element: element, inTemplateContents: inTemplateContents))
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
                ariaNodeStack.append(ariaNode)
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
                    // (Case 554591, A5's review: upstream forgets every
                    // picture's sources at the end of any picture
                    // (Assertions.java:2003-2004), but not at one in template
                    // contents, which its Assertions never sees.)
                    if !state.inTemplateContents {
                        alwaysMatchingSources.removeAll()
                    }
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
                    // Case 554591 (A14): an HTML option that ends marks its
                    // parent as having had one (upstream's setOptionFound),
                    // for the option aria-selected rule in
                    // appendARIAContextMessages.
                    // (A14 review: not one with a popover attribute; see
                    // ARIANode.hasPopover.)
                    for position in index..<stack.count where position > 0 && "option" == stack[position] && .html == namespaceStack[position] && !ariaNodeStack[position].hasPopover {
                        ariaNodeStack[position - 1].optionChildEnded = true
                    }
                    stack.removeSubrange(index...)
                    namespaceStack.removeSubrange(index...)
                    anyElementContentStack.removeSubrange(index...)
                    templateContentsStack.removeSubrange(index...)
                    rejectedForeignStack.removeSubrange(index...)
                    annotationXMLStack.removeAll { $0.stackIndex >= index }
                    roleStack.removeSubrange(index...)
                    ariaNodeStack.removeSubrange(index...)
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
        // Case 554591 (A14): upstream's endDocument ARIA checks, in its
        // order: the aria-activedescendant IDREFs that name no element
        // outside template contents (the port checked each as the element
        // started, whole and empty values too, against IDs in template
        // contents as well), then the elements still missing their required
        // context (see appendARIAContextMessages), unless an element with one
        // of the roles they need owns them through aria-owns.
        for reference in ariaContext.references where !ariaContext.ids.contains(ExactID(reference.id)) {
            appendMessage("The \u{201c}aria-activedescendant\u{201d} attribute references \u{201c}\(reference.id)\u{201d}, which is not the ID of any element in this document.", for: reference.element, locations: locations, messages: &messages)
        }
        for subject in ariaContext.deferred {
            let roles = Self.requiredContextRoles[subject.role]?.roles ?? []
            if !roles.contains(where: { ariaContext.owners[$0]?.contains(ExactID(subject.id)) ?? false }) {
                appendRequiredContextMessage(role: subject.role, for: subject.element, locations: locations, messages: &messages)
            }
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
        /// Case 554591 (A5): whether this picture is in template contents,
        /// where upstream's Assertions, and so its rules for sources that
        /// would always match, never look (see appendPictureChildMessages).
        var inTemplateContents: Bool
        var sourcesMissingSizes: [HTMLStartElement] = []
        var sourcesWithAutoSizes: [HTMLStartElement] = []
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
        alwaysMatchingSources: inout [AlwaysMatchingSource],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Case 554591 (A5, and review item A27): upstream's rules for a
        // source that would always match run as an img, a source or a link
        // with a srcset (a link's is imagesrcset) starts, over every source
        // before it in any picture still on the list (Assertions.java:
        // 2873-2883, 2946-2975); then a source joins them (:3071-3078),
        // whether or not it has a srcset, and after the img too; and the end
        // of any picture just forgets them (:2003-2004; see the caller's
        // alwaysMatchingSources). The port used to judge only the sources
        // with a srcset, forget them after one srcset sibling, so each
        // message came once where upstream repeats the empty and "all" ones
        // at every later srcset sibling, and judge whatever was left at the
        // end of the picture too, which reported a last <source srcset> with
        // no media or type although nothing after it had a srcset (A27).
        // None of it applies in template contents, which upstream's
        // Assertions never sees.
        let srcsetName = "link" == element.name ? "imagesrcset" : "srcset"
        if "img" == element.name || "source" == element.name || "link" == element.name,
           element.hasAttribute(srcsetName), !state.inTemplateContents {
            appendAlwaysMatchingSourceMessages(for: &alwaysMatchingSources, srcsetName: srcsetName, locations: locations, messages: &messages)
        }
        if "source" == element.name, !state.inTemplateContents, let source = alwaysMatchingSource(element) {
            alwaysMatchingSources.append(source)
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
        // (Case 554591, A27: the sources still waiting here are judged by
        // nothing; upstream's end of a picture only forgets them. This used
        // to judge them as if a srcset sibling followed; see
        // appendPictureChildMessages.)
    }

    /// Case 554591 (A5): a picture's source that upstream's rules for a
    /// source that would always match report (Assertions.java:2946-2975), and
    /// for what.
    private struct AlwaysMatchingSource {
        enum Problem {
            /// Neither media nor type: reported once, at the first following
            /// sibling with a srcset (upstream then removes it from its list).
            case noMediaOrType
            /// A media value that's empty, or "all", once trimmed: reported at
            /// every following sibling with a srcset (upstream keeps it).
            case emptyMedia
            case allMedia
        }

        var element: HTMLStartElement
        var problem: Problem
    }

    /// Case 554591 (A5): what upstream's rules for a source that would always
    /// match will report about this source, in their order: no media and no
    /// type; or a media value, as upstream's tokenizer decoded it, that once
    /// trimmed of ASCII whitespace (trimSpaces, :114-143) is empty, or is
    /// "all" in any ASCII case. nil if nothing. The port used to read the raw
    /// text, trim Unicode whitespace and lowercase it, so media="&#97;ll"
    /// wasn't "all", while media="\u{2003}all" (an em space) was.
    private func alwaysMatchingSource(_ element: HTMLStartElement) -> AlwaysMatchingSource? {
        guard element.hasAttribute("media") else {
            return element.hasAttribute("type") ? nil : AlwaysMatchingSource(element: element, problem: .noMediaOrType)
        }
        let media = trimmingASCIIWhitespace(HTMLCharacterReferences.decodeAttributeValue(element.attributeValue("media") ?? ""))
        if media.isEmpty {
            return AlwaysMatchingSource(element: element, problem: .emptyMedia)
        }
        if Self.equalsIgnoringASCIICase(media, "all") {
            return AlwaysMatchingSource(element: element, problem: .allMedia)
        }
        return nil
    }

    /// Case 554591 (A5): upstream's rules for the sources that would always
    /// match, as a following sibling with `srcsetName` starts (see
    /// AlwaysMatchingSource), each source's message at the source. (The port's
    /// message named the srcset even for a link's imagesrcset.)
    private func appendAlwaysMatchingSourceMessages(
        for sources: inout [AlwaysMatchingSource],
        srcsetName: String,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        for source in sources {
            switch source.problem {
            case .noMediaOrType:
                appendMessage(
                    "A \u{201c}source\u{201d} element that has a following sibling \u{201c}source\u{201d} element or \u{201c}img\u{201d} element with a \u{201c}\(srcsetName)\u{201d} attribute must have a \u{201c}media\u{201d} attribute and/or \u{201c}type\u{201d} attribute.",
                    for: source.element,
                    locations: locations,
                    messages: &messages
                )
            case .emptyMedia:
                appendMessage("Value of \u{201c}media\u{201d} attribute here must not be empty.", for: source.element, locations: locations, messages: &messages)
            case .allMedia:
                appendMessage("Value of \u{201c}media\u{201d} attribute here must not be \u{201c}all\u{201d}.", for: source.element, locations: locations, messages: &messages)
            }
        }
        sources.removeAll { .noMediaOrType == $0.problem }
    }

    /// Case 554591 (A5): `value` without the ASCII whitespace (space, tab,
    /// line feed, form feed and carriage return) at either end, as
    /// upstream's Assertions.trimSpaces trims it.
    private func trimmingASCIIWhitespace(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isASCIIWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isASCIIWhitespace($0) }) else {
            return ""
        }
        return String(Substring(scalars[first...last]))
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
        attributesEndedByTag: Set<Int>,
        stack: [String],
        roleStack: [String?],
        labelStack: [LabelState],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        appendRoleEffectMessages(for: element, locations: locations, messages: &messages)
        appendUnnecessaryRoleMessages(for: element, locations: locations, messages: &messages)
        if .html == element.namespace {
            appendARIANamingMessages(for: element, locations: locations, messages: &messages)
        }
        appendSelectRoleMessages(for: element, stack: stack, locations: locations, messages: &messages)
        appendSummaryARIAMessages(for: element, stack: stack, locations: locations, messages: &messages)
        appendARIAPropertyMessages(for: element, role: role, idElementNames: idElementNames, attributesEndedByTag: attributesEndedByTag, locations: locations, messages: &messages)
        appendLabelARIAAssociationMessages(for: element, idElementNames: idElementNames, labelStack: labelStack, locations: locations, messages: &messages)
        appendARIAStructureMessages(for: element, role: role, stack: stack, roleStack: roleStack, locations: locations, messages: &messages)
        // (Case 554591, A14: the main element and role=main counts are now
        // appendARIAContextMessages's, in upstream's order.)
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
    /// upstream sees it; nil when there's no role attribute. (Case 554591,
    /// A14: decoded, as upstream's tokenizer hands it on: role="tab&#108;ist"
    /// is tablist, where the port gave it a false "Bad value"; and, A14
    /// review, with a literal U+0000 made U+FFFD, as it hands that on: see
    /// assertionValue.)
    private func roleAttributeValue(for element: HTMLStartElement) -> String? {
        guard element.hasAttribute("role") else { return nil }
        return Self.assertionValue(element.attributeValue("role") ?? "")
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
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // Review item A2 (U16): not for MathML; and on SVG elements, only a
        // non-empty aria-* value counts (both as vnu.jar reports them).
        // (Case 554591, A14: the role exactly as written, decoded, as
        // upstream compares it, not its first lowercased token: role="NONE"
        // and role="none foo" are neither, and once role values were decoded,
        // role="none&#32;" would have been.)
        guard let role = roleAttributeValue(for: element), "none" == role || "presentation" == role, .mathML != element.namespace else { return }
        let hasTabindex = element.hasAttribute("tabindex")
        let hasGlobalARIA = element.attributes.contains { attribute in
            attribute.name.hasPrefix("aria-") && attribute.name != "aria-hidden" && (.html == element.namespace || !(attribute.value ?? "").isEmpty)
        }
        guard hasTabindex || hasGlobalARIA else { return }

        if hasTabindex, hasGlobalARIA {
            appendWarningMessage("The \u{201c}\(role)\u{201d} role does not affect elements that have a \u{201c}tabindex\u{201d} attribute and global ARIA attributes.", for: element, locations: locations, messages: &messages)
        } else if hasTabindex {
            appendWarningMessage("The \u{201c}\(role)\u{201d} role does not affect elements that have a \u{201c}tabindex\u{201d} attribute.", for: element, locations: locations, messages: &messages)
        } else {
            appendWarningMessage("The \u{201c}\(role)\u{201d} role does not affect elements that have global ARIA attributes.", for: element, locations: locations, messages: &messages)
        }
    }

    private func appendUnnecessaryRoleMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (Case 554591, A14: upstream compares the role exactly as written,
        // decoded, in every one of these ("figure".equals(role)), not its
        // first lowercased token, so role="FIGURE" and role="figure foo" aren't
        // unnecessary on a figure. Once role values were decoded, the first
        // token made role="figure&#32;" unnecessary too.)
        guard let role = roleAttributeValue(for: element) else { return }
        // Review item A13: for math and select, upstream compares the role
        // attribute as written, so role="MATH" or role="listbox foo" isn't
        // "unnecessary" (the first is a "Bad value", and the second gets the
        // select error instead; see appendRoleTokenMessages and
        // appendSelectRoleMessages).
        if element.name == "math" {
            if "math" == role {
                appendWarningMessage("Element \u{201c}math\u{201d} does not need a \u{201c}role\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            return
        }
        // Review item A2 (U16): the rest are about HTML elements (an SVG <a
        // href> isn't a "link" by default the way HTML's is).
        guard .html == element.namespace else { return }
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
            } else if "img" == element.name,
                      "img" != role || (element.hasAttribute("alt") && (element.attributeValue("alt") ?? "").isEmpty) {
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
        // (Case 554591, A14: aria-selected is HTMLARIASchema's now, which
        // gives the same message, for any summary, as the schema does. A14
        // review: and so are aria-expanded and aria-pressed here, whose
        // hand-written stand-ins for the schema's message ignored the role,
        // so <summary role="button" aria-expanded="false"> was missing one;
        // see ariaSchemaJudgedAttributes.)
    }

    private func appendARIAPropertyMessages(
        for element: HTMLStartElement,
        role: String?,
        idElementNames: [String: String],
        attributesEndedByTag: Set<Int>,
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
        // (Case 554591, A14: the aria-activedescendant IDREF check is at the
        // end of the document now, as upstream's is.)
        appendARIAWidgetPropertyMessages(for: element, role: role, attributesEndedByTag: attributesEndedByTag, locations: locations, messages: &messages)
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
        attributesEndedByTag: Set<Int>,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (Case 554591, A14: whether aria-checked, aria-placeholder,
        // aria-readonly, aria-selected, aria-multiselectable, aria-valuemin
        // and aria-valuemax are allowed at all is the schema's judgment now,
        // HTMLARIASchema's, which goes by aria.rnc and implicit roles; their
        // Assertions rules are appendARIAContextMessages's. The role sets that
        // stood in for the schema here missed progressbar's aria-valuemin and
        // aria-valuemax and treeitem's aria-selected and aria-checked, among
        // others, and knew no implicit roles.)
        // (Case 554591, A14 review: an output's aria-pressed is
        // HTMLARIASchema's now, whose message this stood in for, ignoring the
        // role: <output role="" aria-pressed="true"> was missing one. See
        // ariaSchemaJudgedAttributes.)
        if role == "main" {
            for attribute in ["aria-disabled", "aria-haspopup", "aria-invalid"] where element.hasAttribute(attribute) {
                appendWarningMessage("The \u{201c}\(attribute)\u{201d} attribute should not be used on any element which has \u{201c}role=main\u{201d}.", for: element, locations: locations, messages: &messages)
            }
        }
        // (Case 554591, A14: a schema rule, so the schema's role value, which
        // role="listbox foo" is and role="foo listbox" isn't (that's the
        // role filter's "Discarding unrecognized token" instead).)
        if "listbox" == knownSchemaRole(for: element), element.hasAttribute("aria-expanded") {
            appendAttributeNotAllowed("aria-expanded", for: element, locations: locations, messages: &messages)
        }
        if role == "listitem", element.hasAttribute("aria-level") {
            appendWarningMessage("The \u{201c}aria-level\u{201d} attribute should not be used on any element which has \u{201c}role=listitem\u{201d}.", for: element, locations: locations, messages: &messages)
        }
        // (Case 554591, A14: the input aria-haspopup rule is
        // appendARIAContextMessages's now, with upstream's input types.)
        // Review item A13: a schema rule (aria.rnc), so it applies to the
        // schema's value, case-sensitively: not to role="COMBOBOX".
        // (Case 554591, A14 review: by the attributes the schema sees, so an
        // aria-expanded that upstream drops is missing, as vnu.jar says.)
        if "select" == element.name, "combobox" == knownSchemaRole(for: element), !HTMLARIASchema.schemaSees("aria-expanded", in: Self.ariaSchemaAttributes(of: element, endedByTag: attributesEndedByTag)) {
            appendMessage("Element \u{201c}select\u{201d} is missing required attribute \u{201c}aria-expanded\u{201d}.", for: element, locations: locations, messages: &messages)
        }
    }

    /// Case 554591 (A14/A16): an open element as upstream's Assertions keeps
    /// it (its StackNode) for its ARIA rules: the element's name, whether
    /// it's HTML, its role attribute's value as the parser hands it on
    /// (decoded, a literal U+0000 made U+FFFD, untrimmed, case as written; nil
    /// with none; see assertionValue), and, for an HTML element with a role,
    /// upstream's `roles` (see assertionRoleTokens). The port's rules used
    /// roleStack instead, the first lowercased token as written in any
    /// namespace, which these rules don't go by: they look at every token
    /// ("foo tablist" is a tablist), match some roles exactly as written,
    /// count role="" as a role, and count an SVG or MathML element's role only
    /// as written, for the required-context rule, never its tokens.
    struct ARIANode {
        let name: String
        let isHTML: Bool
        let rawRole: String?
        let tokens: [String]?
        /// The owned-child rules' roles among its tokens (an HTML element's
        /// with a role), so that those rules cost the same however many
        /// tokens a parent's role has. (A14 review: they searched the role
        /// parent's and grandparent's tokens for every child, in time growing
        /// with tokens times children.)
        let ownedChildRoles: OwnedChildRoles
        /// Whether it has a popover attribute. (An option with one never
        /// marks its parent as having had an option: upstream's endElement
        /// takes it as an autofocus scoping root first, in an else-if chain
        /// that never gets to setOptionFound.)
        let hasPopover: Bool
        /// Its parent's role as upstream's stack has it, for the
        /// required-context rule's presentation exemption: nil for a parent
        /// the parser implied (see impliedTableParts), which has no role.
        let parentRole: String?
        /// What its open ancestors, with the table parts the parser implied
        /// above it, give the rules for it (see ARIASummary).
        let ancestry: ARIASummary
        /// The same with the element itself: what its descendants' ancestry
        /// starts from.
        let summary: ARIASummary
        /// Whether one of its HTML option children has ended (upstream's
        /// setOptionFound; see appendARIAContextMessages).
        var optionChildEnded = false
        /// For an HTML table or row group: the table parts the parser has
        /// implied in it that are still open, outermost first (see
        /// impliedTableParts).
        var openImplied: [String] = []
    }

    /// Case 554591 (A14/A16 review): what an element's open ancestors give
    /// upstream's rules for it, kept as each element starts, from its
    /// parent's, so that each rule costs the same however deep the element
    /// is. (The rules walked every ancestor, and every token of each, for
    /// every element: a long list of nested role="group" elements, say, took
    /// time growing with the square of its depth.)
    struct ARIASummary {
        /// The li rules' roles among the tokens of the HTML ancestors that
        /// have a role attribute, and whether there are any.
        var liRoles: LIRoles = []
        /// The required-context rule's owner roles an ancestor has, as
        /// written (in any namespace) or implicitly (an HTML element's), as
        /// requiredContextOwnerBits' bits.
        var contextRoles: UInt16 = 0
        /// The index in the stack of open elements of the nearest HTML
        /// ancestor with a role attribute, for the owned-child rules.
        var nearestRoleNode: Int?
        /// The group-in-list rule's answer: whether the nearest HTML
        /// ancestor with a role, explicit or implicit, is a list (nil: none
        /// has one).
        var listDecision: Bool?

        /// With an implied element (see impliedTableParts) below the others:
        /// an HTML element with no role attribute.
        mutating func add(implied name: String) {
            guard let implicit = HTMLGeneralAttributeChecker.elementsWithImplicitRole[name] else {
                return
            }
            contextRoles |= HTMLGeneralAttributeChecker.requiredContextOwnerBits[implicit] ?? 0
            listDecision = "list" == implicit
        }

        /// With an element below the others, at `index` in the stack.
        mutating func add(_ node: (name: String, isHTML: Bool, rawRole: String?, tokens: [String]?), index: Int) {
            // (A foreign element's role counts as written, as upstream's
            // getRole() has it; only an HTML element has a name there, and so
            // an implicit role, and tokens.)
            if let rawRole = node.rawRole {
                contextRoles |= HTMLGeneralAttributeChecker.requiredContextOwnerBits[rawRole] ?? 0
            }
            guard node.isHTML else {
                return
            }
            let implicit = HTMLGeneralAttributeChecker.elementsWithImplicitRole[node.name]
            if let implicit {
                contextRoles |= HTMLGeneralAttributeChecker.requiredContextOwnerBits[implicit] ?? 0
            }
            if let tokens = node.tokens {
                liRoles.insert(.any)
                for token in tokens {
                    liRoles.formUnion(LIRoles(token: token))
                }
                nearestRoleNode = index
                listDecision = tokens.contains("list")
            } else if let implicit {
                listDecision = "list" == implicit
            }
        }
    }

    /// Case 554591 (A14 review): the role tokens upstream's owned-child rules
    /// look for in the nearest HTML ancestors with a role (see
    /// ARIANode.ownedChildRoles).
    struct OwnedChildRoles: OptionSet {
        let rawValue: UInt8

        static let rowgroup = OwnedChildRoles(rawValue: 1 << 0)
        static let group = OwnedChildRoles(rawValue: 1 << 1)
        static let menu = OwnedChildRoles(rawValue: 1 << 2)
        static let menubar = OwnedChildRoles(rawValue: 1 << 3)
        static let tree = OwnedChildRoles(rawValue: 1 << 4)

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Those among a role's tokens.
        init(tokens: [String]) {
            var roles: OwnedChildRoles = []
            for token in tokens {
                switch token {
                case "rowgroup":
                    roles.insert(.rowgroup)
                case "group":
                    roles.insert(.group)
                case "menu":
                    roles.insert(.menu)
                case "menubar":
                    roles.insert(.menubar)
                case "tree":
                    roles.insert(.tree)
                default:
                    break
                }
            }
            self = roles
        }
    }

    /// Case 554591 (A14/A16 review): the role tokens upstream's li rules look
    /// for among the ancestors' (see ARIASummary.liRoles).
    struct LIRoles: OptionSet {
        let rawValue: UInt8

        /// Some HTML ancestor has a role attribute.
        static let any = LIRoles(rawValue: 1 << 0)
        static let list = LIRoles(rawValue: 1 << 1)
        static let tablist = LIRoles(rawValue: 1 << 2)
        static let tree = LIRoles(rawValue: 1 << 3)
        static let listbox = LIRoles(rawValue: 1 << 4)
        static let menu = LIRoles(rawValue: 1 << 5)
        static let menubar = LIRoles(rawValue: 1 << 6)

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// The one for a token, if it's one of these roles.
        init(token: String) {
            switch token {
            case "list":
                self = .list
            case "tablist":
                self = .tablist
            case "tree":
                self = .tree
            case "listbox":
                self = .listbox
            case "menu":
                self = .menu
            case "menubar":
                self = .menubar
            default:
                self = []
            }
        }
    }

    /// Case 554591 (A14): the document-wide state of upstream's ARIA rules
    /// that appendARIAContextMessages ports.
    struct ARIAContextState {
        /// ariaOwnsIdsByRole: by owner role (exactly as written), the IDs its
        /// elements list in aria-owns.
        var owners: [String: Set<ExactID>] = [:]
        /// needsAriaOwner: elements with an id whose role is missing its
        /// required context, checked against owners at the end.
        var deferred: [(element: HTMLStartElement, role: String, id: String)] = []
        /// ariaReferences: the IDs aria-activedescendant attributes name.
        var references: [(element: HTMLStartElement, id: String)] = []
        /// allIds: the IDs of the elements outside template contents.
        var ids: Set<ExactID> = []
        /// hasVisibleMain and hasVisibleMainRole.
        var hasVisibleMain = false
        var hasVisibleMainRole = false
    }

    /// Case 554591 (A14 review): an ID as upstream's Java strings compare it,
    /// code unit by code unit, for ARIAContextState's sets. Swift's String
    /// equality is canonical equivalence (a KELVIN SIGN equals K, a decomposed
    /// é equals é), so aria-owns="caf<e, U+0301>" owned the element with
    /// id="café", which upstream's HashMap doesn't, and the element's missing
    /// context went unreported. (Swift strings are always valid Unicode, so
    /// equal UTF-8 is equal UTF-16.)
    struct ExactID: Hashable {
        let bytes: [UInt8]

        init(_ value: String) {
            bytes = Array(value.utf8)
        }
    }

    /// Case 554591 (A14/A16): an element's ARIANode, from its parent's (nil
    /// for the root), with the table parts the parser implied between them
    /// (see impliedTableParts), for the element at `index` in the stack of
    /// open elements.
    private static func ariaNode(for element: HTMLStartElement, parent: ARIANode?, implied: [String], index: Int) -> ARIANode {
        let isHTML = .html == element.namespace
        let rawRole = element.hasAttribute("role") ? assertionValue(element.attributeValue("role") ?? "") : nil
        let tokens = isHTML ? rawRole.map(assertionRoleTokens) : nil
        var ancestry = parent?.summary ?? ARIASummary()
        for name in implied {
            ancestry.add(implied: name)
        }
        var summary = ancestry
        summary.add((element.name, isHTML, rawRole, tokens), index: index)
        return ARIANode(
            name: element.name,
            isHTML: isHTML,
            rawRole: rawRole,
            tokens: tokens,
            ownedChildRoles: tokens.map(OwnedChildRoles.init(tokens:)) ?? [],
            hasPopover: element.hasAttribute("popover"),
            parentRole: implied.isEmpty ? parent?.rawRole : nil,
            ancestry: ancestry,
            summary: summary
        )
    }

    /// Case 554591 (A14/A16 review): the table parts upstream's parser
    /// implied between an HTML element and its parent in the port's events,
    /// an HTML table or row group (the last of `nodes`), outermost first,
    /// keeping track of which are still open in that parent (its
    /// openImplied). HTMLDocumentParser keeps them out of the events, but
    /// they're on upstream's stack, with their implicit roles, for the ARIA
    /// rules. So a cell written straight in a table is in an implied tbody's
    /// implied tr, which gives a role=gridcell in it its row; a <tr
    /// role="option"> in a <table role="presentation"> has the implied tbody
    /// for its parent, not the presentation table; and the implied tbody, a
    /// rowgroup, is what a role=group tr in a role=list table is in. (Second
    /// review: they stay open after the row or cell, so a script, style,
    /// template, form or hidden input that comes next goes in them, as in
    /// upstream's "in table" insertion mode; the parser's records of where
    /// they end are applied as the events go; see validate.)
    private static func impliedTableParts(for element: HTMLStartElement, in nodes: inout [ARIANode]) -> [String] {
        guard .html == element.namespace, let index = nodes.indices.last, nodes[index].isHTML else {
            return []
        }
        switch nodes[index].name {
        case "table":
            switch element.name {
            case "tr":
                nodes[index].openImplied = ["tbody"]
                return ["tbody"]
            case "td", "th":
                nodes[index].openImplied = ["tbody", "tr"]
                return ["tbody", "tr"]
            case "col":
                nodes[index].openImplied = ["colgroup"]
                return ["colgroup"]
            case "caption", "colgroup", "tbody", "thead", "tfoot":
                // (Each closes what's implied: a row group or caption starts
                // in the table itself.)
                nodes[index].openImplied = []
                return []
            default:
                return goesInCurrentTablePart(element) ? nodes[index].openImplied : []
            }
        case "tbody", "thead", "tfoot":
            switch element.name {
            case "td", "th":
                nodes[index].openImplied = ["tr"]
                return ["tr"]
            case "tr":
                nodes[index].openImplied = []
                return []
            default:
                return goesInCurrentTablePart(element) ? nodes[index].openImplied : []
            }
        default:
            return []
        }
    }

    /// Case 554591 (A14 second review): whether upstream's "in table"
    /// insertion mode puts an element in the current node (an implied tbody,
    /// tr or colgroup, if one is open) rather than before the table: a
    /// script, style, template or form, or an input whose type is hidden.
    /// (After an implied colgroup only a template goes in it; the others end
    /// it first, which the parser records; see validate.)
    private static func goesInCurrentTablePart(_ element: HTMLStartElement) -> Bool {
        switch element.name {
        case "script", "style", "template", "form":
            return true
        case "input":
            let type = HTMLCharacterReferences.decodeAttributeValue(element.attributeValue("type") ?? "")
            return "hidden" == String(String.UnicodeScalarView(type.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar(UInt8(truncatingIfNeeded: $0.value + 0x20)) : $0 }))
        default:
            return false
        }
    }

    /// Case 554591 (A14 second review): the innermost HTML table's index in
    /// `nodes`, if it's the innermost of the HTML tables, templates and html
    /// element there, as the parser has it for the table parts it implied
    /// (HTMLDocumentParser.closesImpliedTablePart).
    private static func innermostTable(in nodes: [ARIANode]) -> Int? {
        guard let boundary = nodes.lastIndex(where: { $0.isHTML && ("table" == $0.name || "template" == $0.name || "html" == $0.name) }),
              "table" == nodes[boundary].name else {
            return nil
        }
        return boundary
    }

    /// Case 554591 (A14 second review): an implied colgroup ending (see
    /// HTMLParsedDocument.impliedColgroupEnds).
    private static func endImpliedColgroup(in nodes: inout [ARIANode]) {
        if let table = innermostTable(in: nodes), ["colgroup"] == nodes[table].openImplied {
            nodes[table].openImplied = []
        }
    }

    /// Case 554591 (A14 second review): a </tr> or </tbody> ending implied
    /// table parts (see HTMLParsedDocument.impliedTablePartEnds): </tbody> the
    /// implied tbody and its tr; </tr> the implied tr, in the table or in a
    /// row group directly in it.
    private static func endImpliedTablePart(_ name: String, in nodes: inout [ARIANode]) {
        guard let table = innermostTable(in: nodes) else {
            return
        }
        if "tbody" == name {
            nodes[table].openImplied = []
        } else if "tr" == nodes[table].openImplied.last {
            nodes[table].openImplied.removeLast()
        } else if table + 1 < nodes.count, nodes[table + 1].isHTML, ["tbody", "thead", "tfoot"].contains(nodes[table + 1].name),
                  ["tr"] == nodes[table + 1].openImplied {
            nodes[table + 1].openImplied = []
        }
    }

    /// Case 554591 (A14 review): an attribute's value as upstream's tokenizer
    /// hands it on to its checkers: character references decoded, and a
    /// literal U+0000 made U+FFFD. (The port's tokenizer keeps a U+0000 as
    /// written, which Java's trim() would then take away: role="tab\0" was a
    /// tab, where upstream's "tab\u{FFFD}" is no role it knows.)
    static func assertionValue(_ raw: String) -> String {
        let decoded = HTMLCharacterReferences.decodeAttributeValue(raw)
        // (In the UTF-8 bytes, where a zero byte can only be U+0000.)
        guard decoded.utf8.contains(0) else {
            return decoded
        }
        return String(String.UnicodeScalarView(decoded.unicodeScalars.map { "\u{0}" == $0 ? "\u{FFFD}" : $0 }))
    }

    /// Case 554591 (A14/A16): upstream's `roles` for a role value,
    /// role.trim().toLowerCase().split("\\s+"): trimmed of every character up
    /// to U+0020 (Java's trim()), lowercased, and split at runs of space,
    /// tab, line feed, vertical tab, form feed or carriage return (Java's
    /// \s). An empty or blank value is one empty token, as Java's split
    /// makes it.
    private static func assertionRoleTokens(_ value: String) -> [String] {
        // The usual case, one role written in lowercase ASCII with nothing
        // to trim or split ("option", "doc-noteref"): itself, with no copy.
        // (A14 review: every element with a role made several new strings
        // here, which took a good part of the time the ARIA rules added.)
        if !value.isEmpty, value.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) || UInt8(ascii: "-") == $0 }) {
            return [value]
        }
        let scalars = value.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0.value > 0x20 }),
              let last = scalars.lastIndex(where: { $0.value > 0x20 }) else {
            return [""]
        }
        let trimmed = String(String.UnicodeScalarView(scalars[first...last])).lowercased()
        return trimmed.unicodeScalars
            .split(whereSeparator: { " " == $0 || "\t" == $0 || "\n" == $0 || "\u{0B}" == $0 || "\u{0C}" == $0 || "\r" == $0 })
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Case 554591 (A14): an attribute value's whitespace-separated tokens,
    /// as upstream's AttributeUtil.split takes them: at space, tab, line feed
    /// and carriage return only. (A14 review: not at a literal form feed,
    /// where the port split them, so aria-owns="x\u{0C}y" owned an x; a &#12;
    /// is a space by the time upstream's tokenizer hands the value on, as
    /// HTMLCharacterReferences.decodeAttributeValue has it.)
    private static func htmlWhitespaceTokens(_ value: String) -> [String] {
        value.unicodeScalars
            .split(whereSeparator: { " " == $0 || "\t" == $0 || "\n" == $0 || "\r" == $0 })
            .map { String(String.UnicodeScalarView($0)) }
    }

    /// Case 554591 (A14 review): an element's attributes as HTMLARIASchema
    /// takes them. (A14's third review: one written with an "=" and then the
    /// tag's end, as in <div aria-checked=>, without a value, as upstream's
    /// tokenizer gives it, for the ARIA dropping wrapper; see
    /// HTMLParsedDocument.attributesEndedByTag. The check after it reads the
    /// value "" there, as for an attribute with no value at all.)
    private static func ariaSchemaAttributes(of element: HTMLStartElement, endedByTag: Set<Int>) -> [HTMLARIASchema.Attribute] {
        if endedByTag.isEmpty {
            return element.attributes.map { HTMLARIASchema.Attribute(name: $0.name, value: $0.value) }
        }
        return element.attributes.map { HTMLARIASchema.Attribute(name: $0.name, value: endedByTag.contains($0.offset) ? nil : $0.value) }
    }

    /// Case 554591 (A14): the schema's messages for an element's ARIA states
    /// and properties (see HTMLARIASchema), on the role as the schema sees it:
    /// for HTML and SVG, what upstream's role filter passes on; for MathML,
    /// the value as written.
    private func appendARIASchemaMessages(
        for element: HTMLStartElement,
        parent: String?,
        attributesEndedByTag: Set<Int>,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (A14 review: only an element with one of the attributes
        // HTMLARIASchema judges can get a message from it, so every other
        // one, nearly every element, stops here, before the role filter.)
        let judged = Self.ariaSchemaJudgedAttributes(for: element, parent: parent)
        guard element.attributes.contains(where: { judged.contains($0.name) }) else {
            return
        }
        let schemaRole: String?
        if .mathML == element.namespace {
            schemaRole = roleAttributeValue(for: element)
        } else {
            schemaRole = filteredRole(for: element)?.schemaValue
        }
        let attributes = Self.ariaSchemaAttributes(of: element, endedByTag: attributesEndedByTag)
        let reportedElsewhere = requiredAttributesReportedElsewhere(for: element, attributesEndedByTag: attributesEndedByTag)
        for message in HTMLARIASchema.messages(element: element.name, namespace: element.namespace, parent: parent, attributes: attributes, schemaRole: schemaRole, reportedElsewhere: reportedElsewhere, judged: judged) {
            switch message {
            case let .notAllowed(attribute):
                appendAttributeNotAllowed(attribute, for: element, locations: locations, messages: &messages)
            case let .missingRequired(attribute):
                appendMessage("Element \u{201c}\(element.displayName)\u{201d} is missing required attribute \u{201c}\(attribute)\u{201d}.", for: element, locations: locations, messages: &messages)
            case let .missingOneOf(attributes):
                appendMessage("Element \u{201c}\(element.displayName)\u{201d} is missing one or more of the following attributes: \(attributes.map { "\u{201c}\($0)\u{201d}" }.joined(separator: ", ")).", for: element, locations: locations, messages: &messages)
            }
        }
    }

    /// Case 554591 (A14 review): the states and properties HTMLARIASchema
    /// reports on for an element (`parent` is an HTML parent's name): the
    /// seven it judges, and, where the port had hand-written stand-ins for
    /// the schema's message about them, an output's aria-pressed and a
    /// details element's summary's aria-expanded and aria-pressed, which it
    /// now judges as the schema does. (The stand-ins ignored the role, so
    /// <summary role="button" aria-expanded="false"> and <output role=""
    /// aria-pressed="true"> were missing one, and gave "missing" where vnu.jar
    /// says "not allowed".)
    private static func ariaSchemaJudgedAttributes(for element: HTMLStartElement, parent: String?) -> Set<String> {
        guard .html == element.namespace else {
            return HTMLARIASchema.judgedAttributes
        }
        if "output" == element.name {
            return outputJudgedAttributes
        }
        if "summary" == element.name, "details" == parent {
            return summaryJudgedAttributes
        }
        return HTMLARIASchema.judgedAttributes
    }

    /// Case 554591 (A14 review): see ariaSchemaJudgedAttributes.
    static let outputJudgedAttributes = HTMLARIASchema.judgedAttributes.union(["aria-pressed"])
    static let summaryJudgedAttributes = HTMLARIASchema.judgedAttributes.union(["aria-expanded", "aria-pressed"])

    /// Case 554591 (A14 review): the attributes another of the port's
    /// checkers reports missing on an element, on the same conditions, which
    /// the schema's end-of-tag message from HTMLARIASchema mustn't name again
    /// (vnu.jar's one message names them with the role, a later unit's): an
    /// a's href with a download or ping (HTMLRequiredAttributeChecker), an
    /// img's src and srcset, an object's data, an input type=image's alt
    /// (HTMLValidator), a meter's value (appendMeterMessages), and the
    /// aria-expanded of a select with role=combobox
    /// (appendARIAWidgetPropertyMessages).
    private func requiredAttributesReportedElsewhere(for element: HTMLStartElement, attributesEndedByTag: Set<Int>) -> Set<String> {
        guard .html == element.namespace else {
            return []
        }
        switch element.name {
        case "a":
            if !element.hasAttribute("href"), element.hasAttribute("download") || element.hasAttribute("ping") {
                return ["href"]
            }
        case "img":
            if !element.hasAttribute("src"), !element.hasAttribute("srcset") {
                return ["src", "srcset"]
            }
        case "object":
            if !element.hasAttribute("data") {
                return ["data"]
            }
        case "input":
            // (Decoded, as HTMLValidator's attribute values are: A14 review,
            // type="imag&#101;" got its alt message twice.)
            if "image" == element.attributeValue("type").map({ HTMLCharacterReferences.decode($0).lowercased() }), !element.hasAttribute("alt") {
                return ["alt"]
            }
        case "meter":
            if nil == element.attributeValue("value") {
                return ["value"]
            }
        case "select":
            if "combobox" == knownSchemaRole(for: element), !HTMLARIASchema.schemaSees("aria-expanded", in: Self.ariaSchemaAttributes(of: element, endedByTag: attributesEndedByTag)) {
                return ["aria-expanded"]
            }
        default:
            break
        }
        return []
    }

    /// Case 554591 (A14/A16): upstream's Assertions rules for ARIA structure
    /// and for the ARIA states and properties HTMLARIASchema judges, with its
    /// role model (see ARIANode), in its order. `ancestors` are the element's
    /// open ancestors' nodes, nearest last; what the rules need from them is
    /// in the node's ancestry. (Never in template contents, which upstream's
    /// checker never sees.)
    private func appendARIAContextMessages(
        for element: HTMLStartElement,
        node: ARIANode,
        ancestors: [ARIANode],
        state: inout ARIAContextState,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let isHTML = node.isHTML
        // IDs, and the IDs aria-activedescendant names (checked at the end,
        // as upstream's MUST_NOT_DANGLE_IDREFS are): a non-empty value's
        // tokens, in any namespace. (A14 review: with a literal U+0000 as
        // upstream's tokenizer hands it on, U+FFFD; see assertionValue.)
        if let id = element.attributeValue("id").map(Self.assertionValue), !id.isEmpty {
            state.ids.insert(ExactID(id))
        }
        if let active = element.attributeValue("aria-activedescendant").map(Self.assertionValue), !active.isEmpty {
            for token in Self.htmlWhitespaceTokens(active) {
                state.references.append((element, token))
            }
        }
        // An owner: an HTML element whose role is exactly one of the roles
        // the required-context rule asks for registers the IDs in its
        // aria-owns, for the elements that rule defers (see the end of
        // validate).
        if isHTML, let rawRole = node.rawRole, Self.requiredContextOwnerRoles.contains(rawRole),
           let owns = element.attributeValue("aria-owns").map(Self.assertionValue) {
            state.owners[rawRole, default: []].formUnion(Self.htmlWhitespaceTokens(owns).map(ExactID.init))
        }

        // The judged ARIA states' and properties' own rules (Assertions),
        // most only for a non-empty value. An input's type here is its value
        // lowercased ("text" when there's no type attribute; A14 review: ""
        // for one with no value, as upstream has it, which no input-type rule
        // takes, where the port made it "text" and warned about an
        // aria-haspopup with a list).
        if isHTML {
            let type = element.hasAttribute("type") ? HTMLCharacterReferences.decodeAttributeValue(element.attributeValue("type") ?? "").lowercased() : "text"
            func nonEmpty(_ attribute: String) -> Bool {
                !(element.attributeValue(attribute) ?? "").isEmpty
            }
            if "input" == element.name, "radio" == type || "checkbox" == type, nonEmpty("aria-checked") {
                appendMessage("The \u{201c}aria-checked\u{201d} attribute must not be used on an \u{201c}input\u{201d} element which has a \u{201c}type\u{201d} attribute whose value is \u{201c}\(type)\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if "input" == element.name, Self.inputTypesWithARIARange.contains(type) {
                for (aria, native) in [("aria-valuemin", "min"), ("aria-valuemax", "max")] where nonEmpty(aria) {
                    if element.hasAttribute(native) {
                        appendMessage("The \u{201c}\(aria)\u{201d} attribute must not be used on an element which has a \u{201c}\(native)\u{201d} attribute.", for: element, locations: locations, messages: &messages)
                    } else {
                        appendWarningMessage("The \u{201c}\(aria)\u{201d} attribute should not be used on an \u{201c}input\u{201d} element which has a \u{201c}type\u{201d} attribute whose value is \u{201c}\(type)\u{201d}.", for: element, locations: locations, messages: &messages)
                    }
                }
            }
            if "input" == element.name, Self.inputTypesWithListPopup.contains(type), element.hasAttribute("list"), nonEmpty("aria-haspopup") {
                appendWarningMessage("The \u{201c}aria-haspopup\u{201d} attribute should not be used on an \u{201c}input\u{201d} element that has a \u{201c}list\u{201d} attribute and whose type is \u{201c}\(type)\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if "progress" == element.name, nonEmpty("aria-valuemax") {
                if element.hasAttribute("max") {
                    appendMessage("The \u{201c}aria-valuemax\u{201d} attribute must not be used on an element which has a \u{201c}max\u{201d} attribute.", for: element, locations: locations, messages: &messages)
                } else {
                    appendWarningMessage("The \u{201c}aria-valuemax\u{201d} attribute should not be used on a \u{201c}progress\u{201d} element.", for: element, locations: locations, messages: &messages)
                }
            }
            if "meter" == element.name {
                for (aria, native) in [("aria-valuemin", "min"), ("aria-valuemax", "max")] where nonEmpty(aria) {
                    if element.hasAttribute(native) {
                        appendMessage("The \u{201c}\(aria)\u{201d} attribute must not be used on an element which has a \u{201c}\(native)\u{201d} attribute.", for: element, locations: locations, messages: &messages)
                    } else {
                        appendWarningMessage("The \u{201c}\(aria)\u{201d} attribute should not be used on a \u{201c}meter\u{201d} element.", for: element, locations: locations, messages: &messages)
                    }
                }
            }
            // (Only until the parent's first option child ends.)
            if "option" == element.name, !(ancestors.last?.optionChildEnded ?? false), nonEmpty("aria-selected") {
                appendWarningMessage("The \u{201c}aria-selected\u{201d} attribute should not be used on the \u{201c}option\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            if "select" == element.name, element.hasAttribute("aria-multiselectable") {
                appendWarningMessage("The \u{201c}aria-multiselectable\u{201d} attribute should not be used with the \u{201c}select \u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            // (A14 review: the value decoded, as upstream compares it, so
            // aria-readonly="&#116;rue" counts.)
            if element.hasAttribute("contenteditable"), "true" == element.attributeValue("aria-readonly").map(HTMLCharacterReferences.decodeAttributeValue) {
                appendMessage("The \u{201c}aria-readonly\u{201d} attribute must only be specified with a value of \u{201c}false\u{201d} on elements that have a \u{201c}contenteditable\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
            if element.hasAttribute("aria-placeholder"), element.hasAttribute("placeholder") {
                appendMessage("The \u{201c}aria-placeholder\u{201d} attribute must not be specified on elements that have a \u{201c}placeholder\u{201d} attribute.", for: element, locations: locations, messages: &messages)
            }
        }

        // role=main, then a main element (which counts as one), as upstream
        // checks them: so <main role="main"> on its own gets nothing, where
        // the port warned that it was a second role=main.
        if isHTML, let tokens = node.tokens, !(node.rawRole ?? "").isEmpty, tokens.contains("main"), !isHidden(element) {
            if state.hasVisibleMainRole {
                appendWarningMessage("A document should not include more than one visible element with \u{201c}role=main\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            state.hasVisibleMainRole = true
        }
        if isHTML, "main" == element.name, !isHidden(element) {
            if state.hasVisibleMain {
                appendMessage("A document must not include more than one visible \u{201c}main\u{201d} element.", for: element, locations: locations, messages: &messages)
            }
            state.hasVisibleMain = true
            state.hasVisibleMainRole = true
        }

        // An li with a role (Assertions.java:3312-3376), by the roles of its
        // HTML ancestors that have one: every token of each (A14 review: as
        // the ancestry keeps them, ARIASummary.liRoles, rather than gathered
        // from every ancestor for every li). The last four rules don't apply
        // to an li that's none, presentation or generic (the guard the port
        // lacked, so Bootstrap's <li role="presentation"> in a role=tablist
        // <ul> and the ARIA authoring practices' <li role="none"> in a
        // menubar were errors).
        if isHTML, "li" == element.name, let tokens = node.tokens {
            let ancestorRoles = node.ancestry.liRoles
            if !ancestorRoles.contains(.any) || ancestorRoles.contains(.list), !tokens.contains("listitem") {
                appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}ul\u{201d}, \u{201c}ol\u{201d}, or \u{201c}menu\u{201d} element with no explicit \u{201c}role\u{201d} value, or a descendant of a \u{201c}role=list\u{201d} element, must not have any \u{201c}role\u{201d} value other than \u{201c}listitem\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if !tokens.contains(where: Self.presentationalRoleTokens.contains) {
                if ancestorRoles.contains(.tablist), !tokens.contains("tab") {
                    appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=tablist\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}tab\u{201d}.", for: element, locations: locations, messages: &messages)
                }
                if ancestorRoles.contains(.tree), !tokens.contains("treeitem") {
                    appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=tree\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}treeitem\u{201d}.", for: element, locations: locations, messages: &messages)
                }
                if !ancestorRoles.isDisjoint(with: [.listbox, .list]), !tokens.contains("group"), !tokens.contains("option") {
                    appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=listbox\u{201d} element or \u{201c}role=list\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}group\u{201d} or \u{201c}option\u{201d}.", for: element, locations: locations, messages: &messages)
                }
                if !ancestorRoles.isDisjoint(with: [.menu, .menubar]),
                   !tokens.contains(where: ["group", "menuitem", "menuitemcheckbox", "menuitemradio", "separator"].contains) {
                    appendMessage("An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=menu\u{201d} element or \u{201c}role=menubar\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}group\u{201d}, \u{201c}menuitem\u{201d}, \u{201c}menuitemcheckbox\u{201d}, \u{201c}menuitemradio\u{201d}, or \u{201c}separator\u{201d}.", for: element, locations: locations, messages: &messages)
                }
            }
        }

        // Required context (Assertions.java:4806-4822), for an element in any
        // namespace whose role is exactly one of the 13 that need one: an
        // open ancestor with one of the roles it needs, exactly as written,
        // or whose element has one implicitly (even with a role of its own),
        // unless its parent's role is exactly presentation. The port knew 3
        // of the roles, matched first tokens, and counted no implicit role,
        // so a role=cell in a <tr> was an error. With an id, the element may
        // be owned instead, which is known only at the end. (A14 review: the
        // ancestors' roles as the ancestry keeps them, contextRoles, the
        // parser's implied table parts among them, so a cell straight in a
        // table has its implied tr's row, and a tr's parent there is the
        // implied tbody, never a presentation table; only an HTML ancestor
        // has an implicit role, as upstream's foreign stack nodes have no
        // name. And th's two implicit roles, columnheader and rowheader, are
        // no role this rule asks for.)
        if let rawRole = node.rawRole, let required = Self.requiredContextMasks[rawRole],
           "presentation" != node.parentRole,
           "tbody" != element.name, "tfoot" != element.name, "thead" != element.name {
            if 0 == node.ancestry.contextRoles & required {
                if let id = element.attributeValue("id").map(Self.assertionValue), !id.isEmpty {
                    state.deferred.append((element, rawRole, id))
                } else {
                    appendRequiredContextMessage(role: rawRole, for: element, locations: locations, messages: &messages)
                }
            }
        }

        // Owned children (Assertions.java:4824-4877): an HTML element with a
        // role (but none, presentation or generic), by its nearest HTML
        // ancestor with a role and the one above that; the port looked at the
        // parent's first token and any ancestor's. (A14 review: found through
        // the ancestry's nearestRoleNode, the role parent's own giving the
        // one above it, and their roles through ownedChildRoles.)
        if isHTML, let tokens = node.tokens, !tokens.contains(where: Self.presentationalRoleTokens.contains),
           let parentIndex = node.ancestry.nearestRoleNode {
            let roleParent = ancestors[parentIndex].ownedChildRoles
            if roleParent.contains(.rowgroup), !tokens.contains("row") {
                appendMessage("An element that is a child of an element with \u{201c}role=rowgroup\u{201d} must have \u{201c}role=row\u{201d}.", for: element, locations: locations, messages: &messages)
            }
            if roleParent.contains(.group), let grandparentIndex = ancestors[parentIndex].ancestry.nearestRoleNode {
                let roleGrandparent = ancestors[grandparentIndex].ownedChildRoles
                if !roleGrandparent.isDisjoint(with: [.menu, .menubar]),
                   !tokens.contains(where: ["menuitem", "menuitemcheckbox", "menuitemradio"].contains) {
                    appendMessage("An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=menu\u{201d} or \u{201c}role=menubar\u{201d} must contain only elements with \u{201c}role=menuitem\u{201d}, \u{201c}role=menuitemcheckbox\u{201d}, or \u{201c}role=menuitemradio\u{201d}.", for: element, locations: locations, messages: &messages)
                }
                if roleGrandparent.contains(.tree), !tokens.contains("treeitem") {
                    appendMessage("An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=tree\u{201d} must contain only elements with \u{201c}role=treeitem\u{201d}.", for: element, locations: locations, messages: &messages)
                }
            }
        }

        // A group in a list (Assertions.java:4879-4916): the nearest HTML
        // ancestor with a role decides, or failing that one with an implicit
        // role (ul and ol are lists); other elements don't count. The port
        // looked at the parent's explicit role only. (A14 review: the
        // ancestry's listDecision has the answer, with the parser's implied
        // tbody and tr, a rowgroup and a row, deciding for what's in them.)
        if isHTML, let tokens = node.tokens, tokens.contains("group"), true == node.ancestry.listDecision {
            appendMessage("An element with \u{201c}role=group\u{201d} must not be a child of an element with \u{201c}role=list\u{201d}.", for: element, locations: locations, messages: &messages)
        }
    }

    /// Case 554591 (A14): upstream's errContainedInOrOwnedBy.
    private func appendRequiredContextMessage(
        role: String,
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let required = Self.requiredContextRoles[role] else { return }
        appendMessage("An element with \u{201c}role=\(role)\u{201d} must be contained in, or owned by, an element with the \u{201c}role\u{201d} value \(required.rendered).", for: element, locations: locations, messages: &messages)
    }

    /// Case 554591 (A14): upstream's REQUIRED_ROLE_ANCESTOR_BY_DESCENDANT: the
    /// roles an element with each of these roles needs as an ancestor's (or
    /// an owner's), and how its message names them (renderRoleSet, in the
    /// order of Java's HashSet of them).
    static let requiredContextRoles: [String: (roles: Set<String>, rendered: String)] = [
        "option": (["listbox"], "\u{201c}listbox\u{201d}"),
        "tab": (["tablist"], "\u{201c}tablist\u{201d}"),
        "menuitem": (["menubar", "menu"], "\u{201c}menubar\u{201d}, or \u{201c}menu\u{201d}"),
        "menuitemcheckbox": (["menubar", "menu"], "\u{201c}menubar\u{201d}, or \u{201c}menu\u{201d}"),
        "menuitemradio": (["menubar", "menu", "group"], "\u{201c}menubar\u{201d}, \u{201c}menu\u{201d}, or \u{201c}group\u{201d}"),
        "treeitem": (["tree", "group"], "\u{201c}tree\u{201d}, or \u{201c}group\u{201d}"),
        "listitem": (["list", "group"], "\u{201c}list\u{201d}, or \u{201c}group\u{201d}"),
        "cell": (["row"], "\u{201c}row\u{201d}"),
        "gridcell": (["row"], "\u{201c}row\u{201d}"),
        "columnheader": (["row"], "\u{201c}row\u{201d}"),
        "rowheader": (["row"], "\u{201c}row\u{201d}"),
        "row": (["treegrid", "grid", "rowgroup", "table"], "\u{201c}treegrid\u{201d}, \u{201c}grid\u{201d}, \u{201c}rowgroup\u{201d}, or \u{201c}table\u{201d}"),
        "rowgroup": (["treegrid", "grid", "table"], "\u{201c}treegrid\u{201d}, \u{201c}grid\u{201d}, or \u{201c}table\u{201d}"),
    ]

    /// Case 554591 (A14): the roles of requiredContextRoles's ancestors,
    /// whose elements can own an element through aria-owns.
    static let requiredContextOwnerRoles: Set<String> = [
        "grid", "group", "list", "listbox", "menu", "menubar", "row", "rowgroup", "table", "tablist", "tree", "treegrid"
    ]

    /// Case 554591 (A14/A16 review): a bit for each of
    /// requiredContextOwnerRoles, for ARIASummary.contextRoles.
    static let requiredContextOwnerBits: [String: UInt16] = Dictionary(
        uniqueKeysWithValues: requiredContextOwnerRoles.sorted().enumerated().map { ($1, UInt16(1) << UInt16($0)) }
    )

    /// Case 554591 (A14/A16 review): requiredContextRoles's roles as
    /// requiredContextOwnerBits' bits.
    static let requiredContextMasks: [String: UInt16] = requiredContextRoles.mapValues { required in
        required.roles.reduce(0) { $0 | (requiredContextOwnerBits[$1] ?? 0) }
    }

    /// Case 554591 (A14): upstream's ELEMENTS_WITH_IMPLICIT_ROLE. (th, which
    /// has two in ELEMENTS_WITH_IMPLICIT_ROLES, columnheader and rowheader,
    /// needn't be here: no rule that uses these asks for either.)
    static let elementsWithImplicitRole: [String: String] = [
        "article": "article", "aside": "complementary", "body": "document", "button": "button", "datalist": "listbox",
        "dd": "definition", "details": "group", "dialog": "dialog", "dfn": "term", "dt": "term", "fieldset": "group",
        "figure": "figure", "form": "form", "h1": "heading", "h2": "heading", "h3": "heading", "h4": "heading",
        "h5": "heading", "h6": "heading", "hr": "separator", "img": "img", "li": "listitem", "link": "link",
        "main": "main", "nav": "navigation", "ol": "list", "output": "status", "progress": "progressbar",
        "section": "region", "summary": "button", "s": "deletion", "table": "table", "tbody": "rowgroup",
        "textarea": "textbox", "tfoot": "rowgroup", "thead": "rowgroup", "td": "cell", "tr": "row", "ul": "list"
    ]

    /// Case 554591 (A14/A16): the role tokens upstream's li and owned-child
    /// rules exempt.
    static let presentationalRoleTokens: Set<String> = ["none", "presentation", "generic"]

    /// Case 554591 (A14): the input types whose aria-valuemin and
    /// aria-valuemax upstream checks against min and max.
    static let inputTypesWithARIARange: Set<String> = ["date", "month", "week", "time", "datetime-local", "number", "range"]

    /// Case 554591 (A14): the input types whose aria-haspopup upstream warns
    /// about with a list attribute.
    static let inputTypesWithListPopup: Set<String> = ["email", "search", "tel", "text", "url"]

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
        // (Case 554591, A14/A16: the required-context, li, owned-child and
        // group-in-list rules are appendARIAContextMessages's now, with
        // upstream's role model.)
        if element.name == "div", stack.last == "dl", let role, role != "presentation", role != "none" {
            appendMessage("A \u{201c}div\u{201d} child of a \u{201c}dl\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}presentation\u{201d} or \u{201c}none\u{201d}.", for: element, locations: locations, messages: &messages)
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

        // (Case 554591, A14: the aria-valuemin and aria-valuemax rules are
        // appendARIAContextMessages's now, with upstream's conditions.)
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

        // (Case 554591, A14: the aria-valuemax rule is
        // appendARIAContextMessages's now, with upstream's conditions.)
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

    /// (Case 554591, A14 review: as written, undecoded, as the rules that use
    /// it have always had it: decoding it reached first-token rules that
    /// upstream applies otherwise, giving custom elements false positives and
    /// losing the div-in-dl error. The rules this unit ports have their own
    /// role model; see ARIANode.)
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

    /// Case 554591 (A5): a media attribute's value, judged as upstream's
    /// schema judges it, by its media-query datatype (common.data.mediaquery,
    /// which is nu.validator.datatype.MediaQuery; see HTMLMediaQueryDatatype),
    /// on the value as upstream's tokenizer hands it on: a literal CR or CRLF
    /// is an LF, and character references are decoded (a reference to a form
    /// feed being a space; see HTMLCharacterReferences.decodeAttributeValue).
    /// The message shows that decoded value, as vnu.jar's does.
    ///
    /// This used to run a subset parser (an optional not or only, then all,
    /// print or screen, then "and (feature: value)" with four features) on
    /// the raw text. So nearly every real media query was a bad value: a bare
    /// condition such as "(min-width: 40em)", em widths, dppx resolutions,
    /// orientation, prefers-color-scheme and hover, range syntax such as
    /// "(width >= 600px)", vendor features such as
    /// "(-webkit-min-device-pixel-ratio: 2)", and "&#115;creen". And media=""
    /// was a bad value, where upstream accepts an empty list, while a bare
    /// media attribute (the same empty value) wasn't. A valueless attribute
    /// (attributeValue gives nil) is the empty value, which is valid, so it
    /// has nothing to report.
    private func appendMediaAttributeMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let raw = element.attributeValue("media") else {
            return
        }
        // (The input stream's newline normalization first, so that a CR
        // written as &#13; stays one, as it does in vnu.jar, where the CSS
        // validator then rejects it; a literal one is a line feed there. And
        // upstream's tokenizer turns a literal NUL in an attribute value into
        // U+FFFD ("Saw U+0000 in stream."), which the CSS validator takes as
        // a name character, where a NUL matches no token at all: A5's review
        // found "(foo: a\0)" valid in vnu.jar but a Bad value in the port.)
        let media = HTMLCharacterReferences.decodeAttributeValue(
            raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
        )
        guard case .error = HTMLMediaQueryDatatype.checkMediaQueryList(media) else {
            return
        }
        appendBadAttributeValue(media, attribute: "media", for: element, locations: locations, messages: &messages)
    }

    /// Case 554591 (A5): what upstream's schema does with an HTML element's
    /// media attribute (see schemaMediaRule).
    private enum SchemaMediaRule {
        /// A pattern with media (common.data.mediaquery) matches the element
        /// where it stands: the value is checked.
        case value
        /// The pattern that matches has no media: "Attribute “media” not
        /// allowed on element “…” at this point.", and the value isn't checked.
        case notAllowed
        /// The element is rejected where it stands, and Jing checks nothing
        /// on it ("not allowed as child of … in this context. (Suppressing
        /// further errors from this subtree.)"), or this is an element whose
        /// media another rule reports (a, area and picture; see
        /// disallowedAttributes) or that the port doesn't judge yet.
        case unchecked
    }

    /// Case 554591 (A5): what upstream's schema does with this HTML
    /// element's media attribute: it checks the value only where one of its
    /// patterns with media matches the element where it stands. The port used
    /// to check media on link, meta, source and style wherever they stood,
    /// and on nothing else. `parent` is the parent's name when it's an HTML
    /// element (else nil), `inHead` whether the element is a child of the
    /// head, explicit or implied, and `bodyStarted` whether the body has
    /// started by the parser's model (see HTMLParsedDocument.bodyStartEvent).
    ///
    /// The port doesn't model every content model these patterns use (review
    /// item MM7's wider problem), so where it can't tell, this leans toward
    /// checking the value, as before: a link is checked wherever it is,
    /// though upstream rejects one in, say, a <ul>; and so is a source in a
    /// video or audio after a track or other content, which upstream rejects.
    /// Nor does the port have an attribute list for every element (MM9):
    /// vnu.jar's "Attribute “media” not allowed" on, say, an img or a div
    /// is still missing.
    private static func schemaMediaRule(
        for element: HTMLStartElement,
        parent: String?,
        inHead: Bool,
        bodyStarted: Bool,
        mediaElement: HTMLStartElement?,
        pictureSawImage: Bool
    ) -> SchemaMediaRule {
        switch element.name {
        case "link":
            // shared-hyperlink.attrs.media (phrase.rnc:92-95), which every
            // link pattern has, in the head and in the body (meta.rnc:162,
            // microdata.rnc:57, rdfa.rnc:209 and :244).
            return .value
        case "style":
            // style.elem is metadata content (meta.rnc:254-261): a child of
            // the head, or of a noscript in it (one before the body starts).
            // vnu.jar rejects a style in the body, or in a noscript there, so
            // it doesn't judge its media, which the port used to.
            return (inHead || ("noscript" == parent && !bodyStarted)) ? .value : .unchecked
        case "source":
            switch parent {
            case "picture":
                // embed.rnc:143-153: the sources come before the img; one
                // after it is rejected (see appendPictureChildMessages).
                return pictureSawImage ? .unchecked : .value
            case "video", "audio":
                // media.rnc:47-60 and 112-151: sources only in a media
                // element with no src.
                return (mediaElement?.hasAttribute("src") ?? false) ? .unchecked : .value
            default:
                // A source anywhere else is rejected.
                return .unchecked
            }
        case "meta":
            // Only meta.name has media (meta.rnc:270-283), and only as
            // metadata content, a child of the head: a noscript in the head
            // takes only a meta http-equiv, and the body only a meta with
            // itemprop or property, so there vnu.jar says media isn't
            // allowed. (A meta whose parent rejects it outright, a <ul>,
            // say, gets that message here where vnu.jar rejects the meta.)
            // In the head, it depends on the meta's other attributes; see
            // metaNarrowingKeepsName. vnu.jar 26.10.27 confirms each case.
            //
            // But a meta whose parent is a noscript before the body starts
            // isn't judged at all (A5's review): upstream's "in head
            // noscript" mode, which the port's parser doesn't model, ends the
            // noscript at any start tag but link, meta, style and a few
            // others, so after <noscript><script></script> (or a title, base
            // or template) the meta is the head's, and its media is checked,
            // while the port still sees it in the noscript. Leaving it alone
            // misses vnu.jar's "not allowed" for a meta that really is in a
            // head noscript, rather than giving that error where there's none.
            if "noscript" == parent, !bodyStarted {
                return .unchecked
            }
            // Nor is a meta whose parent can't hold one at all (a list, a
            // table part, a select, a picture, ...): upstream rejects the
            // meta itself there ("Element “meta” not allowed as child of …"),
            // so Jing checks none of its attributes. (A5's review: the port
            // said media wasn't allowed there instead.)
            if let parent, Self.metaRejectingParents.contains(parent) {
                return .unchecked
            }
            guard inHead else {
                return .notAllowed
            }
            return Self.metaNarrowingKeepsName(element) ? .value : .notAllowed
        default:
            return .unchecked
        }
    }

    /// Case 554591 (A5): a meta with media must be a theme-color
    /// (Assertions.java:4284-4292). This was HTMLMetaChecker's, which runs
    /// before this checker, so for a meta with a bad media value it gave this
    /// message before the Bad value, where vnu.jar's schema, which runs
    /// before its Assertions, gives the Bad value first. And as upstream
    /// has it: the name as the tokenizer decoded it, compared ignoring ASCII
    /// case only (HTMLMetaChecker trimmed it and took "theme_color" too, so
    /// name=" theme-color" and name="theme_color" got no error), and not in
    /// template contents, which Assertions never sees (see the caller).
    private func appendMetaMediaNameMessages(
        for element: HTMLStartElement,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard "meta" == element.name, element.hasAttribute("media") else {
            return
        }
        // (Upstream's is Java's equalsIgnoreCase, but no other character's
        // case mapping gives one of theme-color's letters, so ASCII case is
        // the same test. A valueless name is nil here and "" there; neither
        // is theme-color.)
        if let name = element.attributeValue("name"),
           Self.equalsIgnoringASCIICase(HTMLCharacterReferences.decodeAttributeValue(name), "theme-color") {
            return
        }
        appendMessage(
            "A \u{201c}meta\u{201d} element with a \u{201c}media\u{201d} attribute must have a \u{201c}name\u{201d} attribute whose value is \u{201c}theme-color\u{201d}.",
            for: element,
            locations: locations,
            messages: &messages
        )
    }

    /// Case 554591 (A5): whether `value` is `lowercaseLiteral` but for ASCII
    /// case, as upstream's AttributeUtil.lowerCaseLiteralEqualsIgnoreAsciiCaseString
    /// compares a picture source's media with "all" (lowercased() would also
    /// map other letters, such as U+212A KELVIN SIGN to "k", which upstream
    /// doesn't). The theme-color rule uses it too: upstream's comparison
    /// there is Java's equalsIgnoreCase, which for "theme-color" gives the
    /// same answer, since no other character's case mapping gives one of its
    /// letters.
    private static func equalsIgnoringASCIICase(_ value: String, _ lowercaseLiteral: String) -> Bool {
        lowercaseLiteral.utf8.count == value.utf8.count
            && zip(value.utf8, lowercaseLiteral.utf8).allSatisfy { ((65...90).contains($0) ? $0 | 0x20 : $0) == $1 }
    }

    /// Case 554591 (A5's review): HTML elements whose content model takes no
    /// meta, not even the itemprop or property one that flow and phrasing
    /// content allow: their children are lists' items, table parts, options,
    /// a picture's sources and img, and so on.
    private static let metaRejectingParents: Set<String> = [
        "ul", "ol", "menu", "dl", "table", "thead", "tbody", "tfoot", "tr", "colgroup",
        "select", "optgroup", "option", "picture", "hgroup", "frameset"
    ]

    /// Case 554591 (A5): meta's patterns in the head (meta.rnc:269-295,
    /// microdata.rnc:79-98, rdfa.rnc:209-289), as Jing narrows them: meta.name
    /// (the only one with media), meta.property (RDFa), meta.itemprop
    /// (microdata), meta.charset and the meta.http-equiv patterns.
    private struct MetaPatterns: OptionSet {
        let rawValue: UInt8

        static let name = MetaPatterns(rawValue: 1)
        static let property = MetaPatterns(rawValue: 2)
        static let itemprop = MetaPatterns(rawValue: 4)
        static let charset = MetaPatterns(rawValue: 8)
        static let httpEquiv = MetaPatterns(rawValue: 16)
        static let all: MetaPatterns = [.name, .property, .itemprop, .charset, .httpEquiv]
    }

    /// Case 554591 (A5): which of meta's patterns take each attribute that
    /// tells them apart. Any other attribute is either common to all of them
    /// or allowed by none, so it narrows nothing (and the content, which only
    /// meta.charset lacks, comes after the media in Jing's order). meta.name
    /// adds RDFa's no-content-noproperty attributes (rdfa.rnc:159-167, :289),
    /// so it shares those with meta.property, and the microdata ones with
    /// meta.itemprop.
    private static let metaPatternsTaking: [String: MetaPatterns] = [
        "name": [.name, .property],
        "media": [.name],
        "property": [.property],
        "itemprop": [.itemprop],
        "charset": [.charset],
        "http-equiv": [.httpEquiv],
        "itemref": [.name, .itemprop], "itemscope": [.name, .itemprop], "itemtype": [.name, .itemprop], "itemid": [.name, .itemprop],
        "about": [.name, .property], "prefix": [.name, .property], "typeof": [.name, .property], "vocab": [.name, .property],
        "datatype": [.name, .property], "resource": [.name, .property], "inlist": [.name, .property],
    ]

    /// Case 554591 (A5, and its review): whether meta.name is still one of a
    /// head meta's possible patterns when Jing reaches its media, so that
    /// Jing checks the value; otherwise media isn't allowed. Jing takes the
    /// attributes in the document's order, but for the content, which it's
    /// given last (HTMLARIASchema.permute), and only the first of each name;
    /// each narrows the patterns still possible to those that take it, and
    /// one that none of them takes is "not allowed" and changes nothing
    /// (PatternValidator, ImpossibleAttributeIgnored). So a name first leaves
    /// meta.name and meta.property, and a property after it leaves only
    /// meta.property, which has no media; but after an itemref, a charset is
    /// taken by neither meta.name nor meta.itemprop, so it's ignored and the
    /// media is still checked. (The port first let the first of name, media,
    /// charset, http-equiv, itemprop and property decide, which the review
    /// found wrong for both of those.)
    private static func metaNarrowingKeepsName(_ element: HTMLStartElement) -> Bool {
        var live = MetaPatterns.all
        var seen: Set<String> = []
        for attribute in element.attributes where seen.insert(attribute.name).inserted {
            if "media" == attribute.name {
                return live.contains(.name)
            }
            guard let taking = metaPatternsTaking[attribute.name] else {
                continue
            }
            let narrowed = live.intersection(taking)
            if !narrowed.isEmpty {
                live = narrowed
            }
        }
        return live.contains(.name)
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

/// Case 554591 (A5): upstream's media query datatypes (nu.validator.datatype
/// MediaQuery, for media attributes, and MediaCondition, for the conditions
/// in sizes), as vnu.jar runs them. Upstream doesn't parse media queries
/// itself: it hands "@media " + value + " {}" (MediaCondition: "@media all
/// and " + value + " {}") to the W3C CSS validator bundled in vnu.jar, as a
/// whole style sheet with the css3svg profile and vendor extensions and CSS
/// hacks as warnings (MediaQuery.java:46-63), and the first error that
/// validator records with a message that isn't empty is the reason the value
/// is bad (MediaQuery.java:64-94).
///
/// The port used to accept only an optional not or only, then all, print or
/// screen, then "and (feature: value)" with four features: min-width and
/// max-width in px (or 0), color as digits, and min-resolution in dpi. So
/// media queries that begin with a condition ("(min-width: 40em)"), every
/// other feature (prefers-color-scheme, orientation, hover, aspect-ratio,
/// ...), other units (em, rem, dppx), "not (color)", range syntax
/// ("(width >= 600px)"), unknown and vendor features
/// ("(-webkit-min-device-pixel-ratio: 2)"), comments, and an empty value,
/// which upstream accepts as an empty list, were all false errors.
///
/// What's here mirrors the CSS validator's layers, so values nobody tried
/// behave as vnu.jar does: the UnescapeFilterReader pass over the style
/// sheet; the JavaCC token manager's rules (CssParser.jj:529-835); the
/// parser's productions for @media, with their lookaheads, as the generated
/// CssParser.java runs them (CssParser.jj:1115-1260, 3354-3700); AtRuleMedia's
/// media types; CssPropertyFactory's feature-name dispatch and the 35
/// feature classes' checks; the value classes' parse-time checks; and the
/// swallowed exceptions of media()'s `finally { return newRule; }`, after
/// which the rest of the text is parsed as more style sheet. Paths are
/// relative to /Users/siegel/git/bbsw/validator/css-validator/org/w3c/css
/// unless noted.
///
/// Deliberate differences, each where upstream needs machinery far outside
/// media queries or would misbehave (see the comments where they apply),
/// and each erring toward calling a value valid, never toward a false
/// error:
/// - Declarations in a rule the value injects ("screen {} a { color:
///   red }") are parsed for their syntax, but their properties aren't
///   checked (that needs the CSS property database), so a bad property
///   there isn't reported, and a NullPointerException there is reported
///   as "null" rather than with the JDK's helpful message. Selectors there
///   are read leniently: pseudo-class and pseudo-element names are
///   checked, functional pseudo-classes, attribute selectors and
///   namespaces aren't.
/// - The other at-rules such a value injects (@page, @font-face,
///   @supports, @layer, @keyframes and the rest; not @media, @viewport or
///   an unknown one) are skipped to the end of their block unchecked,
///   where upstream parses each with its own production, so their syntax
///   errors, and media queries nested in them, aren't reported. A lexical
///   error while skipping one escapes as it would from those productions.
/// - Of the color and image functions, rgb(), rgba(), hsl(), hsla() and
///   image() are checked as upstream checks them, but relative colors
///   ("rgb(from …)"), hwb(), lab(), lch(), oklab(), oklch(), device-cmyk(),
///   light-dark(), color-mix() and the gradients are taken on trust (but
///   for a gradient of one value), also as an env() fallback.
/// - A number whose plain form would spell out more than 64 zeros is
///   quoted as written, not as BigDecimal.toPlainString() would (a
///   "1e+999999" would otherwise make a megabyte of reason), while where
///   upstream can't print a number at all (its plain form past what a Java
///   array or string can hold) the port fails as upstream does there,
///   taking upstream's heap to be large enough for anything short of those
///   limits.
/// - The style sheet is filtered as UnescapeFilterReader's first read
///   (4,096 characters) filters it; a value where a later read would
///   differ (a lone CR, FF or NUL whose cascade starts there, or a read
///   that runs over) is given up on as valid.
/// - Nesting deeper than `depthLimit` is given up on as valid rather than
///   risking the stack.
enum HTMLMediaQueryDatatype {
    /// Valid, or bad with upstream's reason: the text vnu.jar shows after
    /// "Bad value “…” for attribute “…” on element “…”: ", before
    /// MessageEmitterAdapter's scrub of control characters and NFC. The
    /// port's attribute messages leave the reason out, as TestRunner's do.
    enum Outcome: Equatable {
        case valid
        case error(String)
    }

    /// MediaQuery ("media query", for the media attribute).
    static func checkMediaQueryList(_ value: String) -> Outcome {
        check(prefix: "@media ", value)
    }

    /// MediaCondition (MediaCondition.java: isMediaCondition() is true), for
    /// the conditions of a sizes attribute: the same machinery, on "@media
    /// all and " + value + " {}" (MediaQuery.java:57-58).
    static func checkMediaCondition(_ value: String) -> Outcome {
        check(prefix: "@media all and ", value)
    }

    /// How deep values and conditions may nest (parentheses, functions,
    /// calc() sums, weighted as Parser.enter says) before the port gives
    /// up. Upstream recurses until Java's stack overflows, which media()'s
    /// finally block swallows like any other throwable; the port's checks
    /// run on a background thread whose stack may be 512 KiB, so it stops
    /// well short of that (at this limit no value needs more than 192 KiB)
    /// and calls such a value valid: 400 nested parentheses, 200 in a
    /// calc(), 133 nested functions, or a calc() sum or product of 400
    /// terms. vnu.jar accepts 200 nested parentheses.
    private static let depthLimit = 400

    /// String.format("@media %s %s", literal, "{}") (MediaQuery.java:57-61),
    /// as UTF-16 code units, since the CSS validator works on Java chars;
    /// then UnescapeFilterReader's pass (StyleSheetParser.java:302-304) and
    /// the parse.
    private static func check(prefix: String, _ value: String) -> Outcome {
        var units = Array(prefix.utf16)
        units.append(contentsOf: value.utf16)
        units.append(contentsOf: " {}".utf16)
        guard let filtered = unescapeFilter(units) else {
            // a CR, FF or NUL cascade in a later read than the first, whose
            // extent upstream's buffer state decides (see unescapeFilter)
            return .valid
        }
        let parser = Parser(text: filtered)
        return parser.run()
    }

    // MARK: - UnescapeFilterReader

    /// The characters JavaCC's SimpleCharStream asks its first read for
    /// (its default buffer size, SimpleCharStream.java:263-282).
    private static let firstRead = 4096

    /// UnescapeFilterReader.read(char[], int, int) (util/UnescapeFilterReader
    /// .java:85-203), which the CSS validator reads every CSS2-or-later style
    /// sheet through. It turns a hex escape whose value is an ASCII letter
    /// into the letter (eating one space, tab or line feed after it), drops
    /// the backslash before any other ASCII letter that isn't a hex digit,
    /// and leaves every other escape alone, so escaped letters act as plain
    /// text in keywords, units and function names.
    ///
    /// It also "pre-processes" CR, FF and NUL, writing the replacement into
    /// the buffer and then falling through to the code that copies the
    /// current character, which copies again: while nothing earlier in the
    /// read has shortened the text, the copy overwrites the next character
    /// with the replacement, and so every later character of the read
    /// becomes a line feed (or U+FFFD). CR followed by LF is harmless.
    ///
    /// The cascade lasts only to the end of a read (Case 554591 review):
    /// read() fills at most len characters, and the next read starts again
    /// from the original text (in.reset(); in.skip(i)). JavaCC's first read
    /// asks for 4,096 characters, from up to 4,104 of input, and that one is
    /// reproduced exactly; so " {}" survives a CR, FF or NUL in a long
    /// value's first read. Later reads are sized by SimpleCharStream.FillBuff
    /// from its buffer state, which isn't modeled: the rest is filtered in
    /// one piece, and a cascade that would start there gives up (nil, so
    /// the value is called valid), as does a read that would overflow its
    /// buffer (a CR, FF or NUL written as its 4,096th character makes
    /// upstream copy 4,097 into a 4,096-character array).
    private static func unescapeFilter(_ input: [UInt16]) -> [UInt16]? {
        let first = filterPiece(input, from: 0, len: firstRead, count: min(firstRead + 8, input.count))
        if first.overflow {
            return nil
        }
        if first.next >= input.count {
            return first.out
        }
        let rest = filterPiece(input, from: first.next, len: Int.max, count: input.count - first.next)
        if rest.cascade || rest.overflow {
            return nil
        }
        return first.out + rest.out
    }

    /// One read() over input[from ..< from + count], writing at most len
    /// characters: what it writes, where the next read starts, whether a
    /// CR/FF/NUL cascade began in it, and whether it wrote past len.
    private static func filterPiece(_ input: [UInt16], from: Int, len: Int, count l: Int)
        -> (out: [UInt16], next: Int, cascade: Bool, overflow: Bool) {
        // Java's buffer is len + 8 characters long; the cascade can write
        // one character past what it read.
        var chars = Array(input[from..<(from + l)]) + [UInt16](repeating: 0, count: 8)
        var i = 0
        var j = 0
        var cascade = false
        func isLetterValue(_ v: Int) -> Bool {
            (v > 96 && v < 123) || (v > 64 && v < 91)
        }
        while i < l && j < len {
            // pre-processing (UnescapeFilterReader.java:97-108)
            if 0x0D == chars[i] {
                let lone = !(i + 1 < l && 0x0A == chars[i + 1])
                if lone && j == i {
                    cascade = true
                }
                chars[j] = 0x0A
                j += 1
                if !lone {
                    i += 1
                }
            } else if 0x0C == chars[i] {
                if j == i {
                    cascade = true
                }
                chars[j] = 0x0A
                j += 1
            } else if 0 == chars[i] {
                if j == i {
                    cascade = true
                }
                chars[j] = 0xFFFD
                j += 1
            }
            // escaping (UnescapeFilterReader.java:111-189)
            if 0x5C == chars[i] {
                var val = 0
                var escaped = false
                var ignoreEscape = false
                var k = 1
                while k < 7 && k + i < l {
                    let cki = Int(chars[k + i])
                    if cki > 47 && cki < 58 {
                        val = (val << 4) + (cki - 48)
                    } else if cki > 64 && cki < 71 {
                        val = (val << 4) + (cki - 55)
                    } else if cki > 96 && cki < 103 {
                        val = (val << 4) + (cki - 87)
                    } else if 10 == cki || 9 == cki || 32 == cki {
                        if isLetterValue(val) {
                            chars[j] = UInt16(val)
                            j += 1
                            escaped = true
                            i += k
                        } else {
                            escaped = true
                            ignoreEscape = true
                        }
                        break
                    } else {
                        if 0 == val && isLetterValue(cki) {
                            // a backslash before a plain letter: drop it
                            i += 1
                            ignoreEscape = true
                            break
                        }
                        if isLetterValue(val) {
                            chars[j] = UInt16(val)
                            j += 1
                            escaped = true
                            i += k - 1
                        } else {
                            ignoreEscape = true
                        }
                        break
                    }
                    k += 1
                }
                if !ignoreEscape {
                    if 7 == k && !escaped {
                        if isLetterValue(val) {
                            chars[j] = UInt16(val)
                            j += 1
                            i += k - 1
                            if i + 1 < l {
                                let cki = chars[i + 1]
                                if 10 == cki || 9 == cki || 32 == cki {
                                    i += 1
                                }
                            }
                        } else {
                            chars[j] = chars[i]
                            j += 1
                        }
                    } else if !escaped {
                        // the buffer ended inside the escape: upstream ends
                        // the read here when it has written anything, and
                        // the next read starts at the backslash
                        if 0 != j {
                            return (Array(chars[0..<j]), from + i, cascade, j > len)
                        }
                        chars[j] = chars[i]
                        j += 1
                    }
                } else {
                    chars[j] = chars[i]
                    j += 1
                }
            } else {
                chars[j] = chars[i]
                j += 1
            }
            i += 1
        }
        return (Array(chars[0..<j]), from + i, cascade, j > len)
    }

    // MARK: - Tokens

    /// The token kinds of CssParserConstants.java that matter, with their
    /// numbers, since JavaCC breaks a tie between two equally long matches
    /// in favor of the kind declared first (the lower number).
    private enum T {
        static let eof = 0
        static let s = 21
        static let sco = 22
        static let cdo = 23
        static let cdc = 24
        static let includes = 25
        static let dashMatch = 26
        static let lbrace = 27
        static let plus = 28
        static let minus = 29
        static let greater = 30
        static let greaterEq = 31
        static let comma = 32
        static let tilde = 33
        static let twoPipes = 34
        static let and = 35
        static let or = 36
        static let only = 37
        static let not = 38
        static let string = 39
        static let invalid = 40
        static let ident = 41
        static let hashIdent = 42
        static let hash = 43
        static let progid = 44
        static let dashedIdent = 45
        static let rbrace = 46
        static let prefixMatch = 47
        static let suffixMatch = 48
        static let substringMatch = 49
        static let eq = 50
        static let semicolon = 51
        static let div = 52
        static let lbracket = 53
        static let rbracket = 54
        static let any = 55
        static let dot = 56
        static let rparen = 57
        static let lparen = 58
        static let colon = 59
        static let url = 60
        static let relFontLength = 61
        static let relViewLength = 62
        static let absolutLength = 63
        static let flex = 64
        static let angle = 65
        static let spl = 66
        static let st = 67
        static let time = 68
        static let freq = 69
        static let resolution = 70
        static let an = 71
        static let dimen9 = 72
        static let dimen = 73
        static let percentage = 74
        static let number = 75
        static let importantSym = 76
        static let importantNot = 77
        static let pseudoElement = 78
        static let charsetSym = 79
        static let pageSym = 80
        static let fontFaceSym = 97
        static let fontFeatureValuesSym = 98
        static let fontPaletteValuesSym = 99
        static let importSym = 107
        static let namespaceSym = 108
        static let mediaSym = 109
        static let keyframesSym = 110
        static let prefSym = 111
        static let colorProfile = 112
        static let counterStyleSym = 114
        static let layerSym = 115
        static let phoneticAlphabetSym = 116
        static let supportsSym = 117
        static let viewportSym = 118
        static let atKeyword = 119
        static let unicodeRange = 129
        static let functionNot = 144
        static let functionCalc = 145
        static let functionMathN = 146
        static let functionMath1 = 147
        static let functionMath2 = 148
        static let functionRound = 149
        static let functionClamp = 150
        static let functionAttr = 151
        static let functionVar = 152
        static let functionEnv = 153
        static let function = 157
        static let htmlStartTag = 158
        static let htmlEndTag = 159
        static let bang = 161
        static let dollar = 162
        static let percent = 163
        static let ampersand = 164
        static let backquote = 165
        static let question = 166
        static let less = 167
        static let pipe = 168
        static let lessEq = 169

        /// The at-rule keywords (CssParser.jj:708-765), all of which tie with
        /// ATKEYWORD ("@" IDENT) and so win when the keyword is the whole
        /// at-keyword. "@charset" (CssParser.jj:708-710) sits in a block
        /// without [IGNORE_CASE], but the options block's IGNORE_CASE = true
        /// (CssParser.jj:11) covers it too, so "@CHARSET" is CHARSET_SYM
        /// (Case 554591 review).
        static let atRules: [(String, Int)] = [
            ("@page", 80), ("@top-left-corner", 81), ("@top-left", 82), ("@top-center", 83),
            ("@top-right", 84), ("@top-right-corner", 85), ("@bottom-left-corner", 86),
            ("@bottom-left", 87), ("@bottom-center", 88), ("@bottom-right", 89),
            ("@bottom-right-corner", 90), ("@left-top", 91), ("@left-middle", 92),
            ("@left-bottom", 93), ("@right-top", 94), ("@right-middle", 95), ("@right-bottom", 96),
            ("@font-face", 97), ("@font-feature-values", 98), ("@font-palette-values", 99),
            ("@stylistic", 100), ("@historical-forms", 101), ("@styleset", 102),
            ("@character-variant", 103), ("@swash", 104), ("@ornaments", 105),
            ("@annotation", 106), ("@import", 107), ("@namespace", 108), ("@media", 109),
            ("@keyframes", 110), ("@preference", 111), ("@color-profile", 112),
            ("@counter", 113), ("@counter-style", 114), ("@layer", 115),
            ("@phonetic-alphabet", 116), ("@supports", 117), ("@viewport", 118)
        ]

        /// The function keywords (CssParser.jj:785-815), IGNORE_CASE, all of
        /// which tie with FUNCTION (IDENT "(") and so win.
        static let functions: [(String, Int)] = [
            ("lang(", 130), ("dir(", 131), ("is(", 132), ("where(", 133), ("has(", 134),
            ("slotted(", 135), ("host(", 136), ("host-context(", 137), ("nth-child(", 138),
            ("nth-last-child(", 139), ("nth-col(", 140), ("nth-last-col(", 141),
            ("nth-of-type(", 142), ("nth-last-of-type(", 143), ("not(", 144),
            ("calc(", 145), ("-moz-calc(", 145), ("-webkit-calc(", 145),
            ("min(", 146), ("max(", 146), ("hypot(", 146),
            ("sin(", 147), ("cos(", 147), ("tan(", 147), ("asin(", 147), ("acos(", 147),
            ("atan(", 147), ("sqrt(", 147), ("exp(", 147), ("abs(", 147), ("sign(", 147),
            ("mod(", 148), ("rem(", 148), ("atan2(", 148), ("pow(", 148), ("log(", 148),
            ("round(", 149), ("clamp(", 150), ("attr(", 151), ("var(", 152), ("env(", 153),
            ("layer(", 154), ("selector(", 155), ("at-rule(", 156)
        ]

        /// The unit tokens (CssParser.jj:654-689), in their declaration
        /// order, each NUM followed by one of its units (IGNORE_CASE).
        static let units: [(Int, [String])] = [
            (61, ["em", "ex", "cap", "ch", "ic", "lh", "rem", "rex", "rcap", "rch", "ric", "rlh"]),
            (62, ["vw", "vh", "vi", "vb", "vmin", "vmax", "svw", "svh", "svi", "svb", "svmin", "svmax",
                  "lvw", "lvh", "lvi", "lvb", "lvmin", "lvmax", "dvw", "dvh", "dvi", "dvb", "dvmin", "dvmax"]),
            (63, ["cm", "mm", "q", "in", "pt", "pc", "px"]),
            (64, ["fr"]),
            (65, ["deg", "grad", "rad", "turn"]),
            (66, ["db"]),
            (67, ["st"]),
            (68, ["ms", "s"]),
            (69, ["hz", "khz"]),
            (70, ["dpi", "dpcm", "dppx", "x"]),
            (71, ["n"])
        ]
    }

    /// A token: its kind and where its image is in the filtered text.
    private struct Token {
        var kind: Int
        var start: Int
        var end: Int
    }

    // MARK: - Characters

    private static func isSpace(_ c: UInt16) -> Bool {
        0x20 == c || 0x09 == c || 0x0A == c || 0x0D == c || 0x0C == c
    }

    private static func isDigit(_ c: UInt16) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private static func isHex(_ c: UInt16) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }

    private static func isASCIILetter(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func asciiLower(_ c: UInt16) -> UInt16 {
        (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c
    }

    private static func string(_ units: ArraySlice<UInt16>) -> String {
        String(decoding: units, as: UTF16.self)
    }

    /// Java's String.toLowerCase() (Locale.ROOT behavior, as vnu.jar ran):
    /// each code point's full Unicode lowercase mapping (U+0130 becomes
    /// "i̇", as in Java); lone surrogates stay as they are. GREEK CAPITAL
    /// LETTER SIGMA becomes the final ς as ConditionalSpecialCasing
    /// .isFinalCased decides: by the JDK's own isCased, within the JDK's
    /// word segment, so "A1Σ", "A_Σ" and "A-Σ" end in ς and "A·Σ" in σ
    /// (Case 554591 review: the port once used Unicode's Final_Sigma
    /// context, which skips case-ignorables instead, and differed there;
    /// since identEquals hashes the lowercased name, a name built to
    /// collide with a keyword through its sigma could flip a verdict).
    private static func javaLowercase(_ units: [UInt16]) -> [UInt16] {
        var isASCII = true
        for c in units where c >= 0x80 {
            isASCII = false
            break
        }
        if isASCII {
            return units.map(asciiLower)
        }
        // decode code points, keeping lone surrogates
        var points = [UInt32]()
        points.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            let c = units[i]
            if c >= 0xD800 && c <= 0xDBFF && i + 1 < units.count && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF {
                points.append(0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00))
                i += 2
            } else {
                points.append(UInt32(c))
                i += 1
            }
        }
        func scalar(_ p: UInt32) -> Unicode.Scalar? {
            Unicode.Scalar(p)
        }
        // the word segments, found only when a sigma needs them
        var boundary: [Bool]?
        var out = [UInt16]()
        out.reserveCapacity(units.count)
        for (index, p) in points.enumerated() {
            if 0x3A3 == p {
                let segments = boundary ?? jdkWordBoundaries(points)
                boundary = segments
                out.append(isFinalCased(points, index, segments) ? 0x3C2 : 0x3C3)
                continue
            }
            guard let s = scalar(p) else {
                out.append(UInt16(truncatingIfNeeded: p))
                continue
            }
            if p < 0x80 {
                out.append(asciiLower(UInt16(p)))
                continue
            }
            out.append(contentsOf: s.properties.lowercaseMapping.utf16)
        }
        return out
    }

    /// Unicode decimal digits (general category Nd) of the BMP as ASCII
    /// digits, as Character.digit(char, 10) reads them for BigDecimal; a
    /// digit outside the BMP is a surrogate pair to Java, and no digit.
    private static func asciiDigits(_ units: [UInt16]) -> [UInt16] {
        var out = units
        for (index, c) in units.enumerated() where c >= 0x80 {
            guard !(c >= 0xD800 && c <= 0xDFFF), let scalar = Unicode.Scalar(UInt32(c)),
                  .decimal == scalar.properties.numericType, let value = scalar.properties.numericValue,
                  value >= 0 && value <= 9 else {
                continue
            }
            out[index] = 0x30 + UInt16(value)
        }
        return out
    }

    /// Java's String.hashCode(), over UTF-16 code units, wrapping.
    private static func javaHash(_ units: [UInt16]) -> Int32 {
        var h: Int32 = 0
        for c in units {
            h = h &* 31 &+ Int32(c)
        }
        return h
    }

    /// CssIdent.equals (values/CssIdent.java:124-145): the hashes of both
    /// names lowercased, so hash collisions match too. The keyword is
    /// lowercased here as well, as CssIdent.hashCode lowercases both: the
    /// camel-case "currentColor" once never matched (Case 554591 review).
    private static func identEquals(_ value: [UInt16], _ keyword: String) -> Bool {
        javaHash(javaLowercase(value)) == javaHash(javaLowercase(Array(keyword.utf16)))
    }

    /// Character.toUpperCase(char), then toLowerCase(char): Java's simple
    /// one-to-one case mappings on one UTF-16 unit.
    private static func javaUpper(_ c: UInt16) -> UInt16 {
        guard let s = Unicode.Scalar(UInt32(c)) else {
            return c
        }
        let mapped = Array(s.properties.uppercaseMapping.utf16)
        return 1 == mapped.count ? mapped[0] : c
    }

    private static func javaLower(_ c: UInt16) -> UInt16 {
        guard let s = Unicode.Scalar(UInt32(c)) else {
            return c
        }
        let mapped = Array(s.properties.lowercaseMapping.utf16)
        return 1 == mapped.count ? mapped[0] : c
    }

    /// String.equalsIgnoreCase (regionMatches(true, …)): unit by unit,
    /// equal as they are, or uppercased, or lowercased after that. So
    /// "tranſparent" (U+017F) equals "transparent", as CssDump agrees.
    private static func javaEqualsIgnoreCase(_ value: [UInt16], _ keyword: String) -> Bool {
        let other = Array(keyword.utf16)
        guard value.count == other.count else {
            return false
        }
        for (a, b) in zip(value, other) where a != b {
            let ua = javaUpper(a)
            let ub = javaUpper(b)
            if ua != ub && javaLower(ua) != javaLower(ub) {
                return false
            }
        }
        return true
    }

    // MARK: - Final sigma

    /// The general category of a code point, as Character.getType sees it
    /// (a lone surrogate is Cs).
    private static func category(_ p: UInt32) -> Unicode.GeneralCategory {
        Unicode.Scalar(p)?.properties.generalCategory ?? .surrogate
    }

    /// ConditionalSpecialCasing.isCased (JDK 27, java/lang/
    /// ConditionalSpecialCasing.java:363-400): Lu, Ll and Lt, and a fixed
    /// list of Other_Lowercase and Other_Uppercase ranges (so ª, Lo to
    /// Java, isn't cased, and ʰ is).
    private static func isJavaCased(_ p: UInt32) -> Bool {
        switch category(p) {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter:
            return true
        default:
            return (p >= 0x02B0 && p <= 0x02B8) || (p >= 0x02C0 && p <= 0x02C1) || (p >= 0x02E0 && p <= 0x02E4)
                || 0x0345 == p || 0x037A == p || (p >= 0x1D2C && p <= 0x1D61) || (p >= 0x2160 && p <= 0x217F)
                || (p >= 0x24B6 && p <= 0x24E9)
        }
    }

    /// The character classes of the JDK's word rules (sun/text/resources/
    /// BreakIteratorRules.java:69-146).
    private static func isKanji(_ p: UInt32) -> Bool {
        0x3005 == p || (p >= 0x4E00 && p <= 0x9FA5) || (p >= 0xF900 && p <= 0xFA2D)
    }

    private static func isKata(_ p: UInt32) -> Bool {
        (p >= 0x30A1 && p <= 0x30FA) || 0x30FD == p || 0x30FE == p
    }

    private static func isHira(_ p: UInt32) -> Bool {
        (p >= 0x3041 && p <= 0x3094) || 0x309D == p || 0x309E == p
    }

    private static func isCJKDiacritic(_ p: UInt32) -> Bool {
        (p >= 0x3099 && p <= 0x309C) || 0x30FB == p || 0x30FC == p
    }

    private static func isEnclosing(_ p: UInt32) -> Bool {
        let c = category(p)
        return .nonspacingMark == c || .enclosingMark == c
    }

    /// <letter-base>: [:L::Mc:] but the kanji, kana and CJK diacritics.
    private static func isLetterBase(_ p: UInt32) -> Bool {
        switch category(p) {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .spacingMark:
            return !(isKanji(p) || isKata(p) || isHira(p) || isCJKDiacritic(p))
        default:
            return false
        }
    }

    /// <digit-base>: [:N:].
    private static func isDigitBase(_ p: UInt32) -> Bool {
        switch category(p) {
        case .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// <mid-word>: [:Pd::Pc:] U+00AD U+2027 " ' and ".".
    private static func isMidWord(_ p: UInt32) -> Bool {
        let c = category(p)
        return .dashPunctuation == c || .connectorPunctuation == c || 0xAD == p || 0x2027 == p || 0x22 == p
            || 0x27 == p || 0x2E == p
    }

    /// <mid-num>: " ' , U+066B and ".".
    private static func isMidNum(_ p: UInt32) -> Bool {
        0x22 == p || 0x27 == p || 0x2C == p || 0x066B == p || 0x2E == p
    }

    /// <pre-num>: [:Sc:] "#" and "." but the cent sign.
    private static func isPreNum(_ p: UInt32) -> Bool {
        (.currencySymbol == category(p) && 0xA2 != p) || 0x23 == p || 0x2E == p
    }

    /// <post-num>: % & ¢ U+066A U+2030 U+2031.
    private static func isPostNum(_ p: UInt32) -> Bool {
        0x25 == p || 0x26 == p || 0xA2 == p || 0x066A == p || 0x2030 == p || 0x2031 == p
    }

    /// <ignore>: the format characters (Cf), but the soft hyphen, which
    /// <mid-word> names and which so behaves as one ("AⅣ\u{AD}Σ" breaks
    /// after the numeral, as vnu.jar's JDK does).
    private static func isIgnorable(_ p: UInt32) -> Bool {
        0xAD != p && .format == category(p)
    }

    /// The JDK word BreakIterator's boundaries in a string of code points,
    /// as its forward rules find them (RuleBasedBreakIterator.handleNext:
    /// the longest match of any rule, at least one character, from each
    /// boundary on). Ignorable characters are transparent within a match,
    /// and one right after it belongs to it.
    private static func jdkWordBoundaries(_ points: [UInt32]) -> [Bool] {
        var boundary = [Bool](repeating: false, count: points.count + 1)
        boundary[0] = true
        boundary[points.count] = true
        // the significant (not Cf) characters and where they are, found
        // once, so the segmenting stays linear
        var positions = [Int]()
        var significant = [UInt32]()
        for (index, p) in points.enumerated() where !isIgnorable(p) {
            positions.append(index)
            significant.append(p)
        }
        var p = 0
        var q = 0
        while p < points.count {
            while q < positions.count && positions[q] < p {
                q += 1
            }
            var end = p + 1
            if q < positions.count {
                let last = jdkWordMatch(significant, q)
                end = max(end, positions[last - 1] + 1)
                // an ignorable right after the match keeps it accepting
                while end < points.count && isIgnorable(points[end]) {
                    end += 1
                }
            }
            boundary[end] = true
            p = end
        }
        return boundary
    }

    /// Where the longest match of the word rules (BreakIteratorRules.java:
    /// 118-146) at s[start] ends (exclusive, at least start + 1).
    private static func jdkWordMatch(_ s: [UInt32], _ start: Int) -> Int {
        let m = s.count
        // <let>=(<letter-base><enclosing>*), <dgt>=(<digit-base><enclosing>*)
        func run(_ j: Int, _ base: (UInt32) -> Bool) -> Int {
            var j = j
            while j < m && base(s[j]) {
                j += 1
                while j < m && isEnclosing(s[j]) {
                    j += 1
                }
            }
            return j
        }
        // <word>=((<let><let>*(<mid-word><let><let>*)*){<danda>})
        func word(_ i: Int) -> Int? {
            guard i < m, isLetterBase(s[i]) else {
                return nil
            }
            var j = run(i, isLetterBase)
            while j + 1 < m && isMidWord(s[j]) && isLetterBase(s[j + 1]) {
                j = run(j + 1, isLetterBase)
            }
            if j < m && (0x0964 == s[j] || 0x0965 == s[j]) {
                j += 1
            }
            return j
        }
        // <number>=(<dgt><dgt>*(<mid-num><dgt><dgt>*)*)
        func number(_ i: Int) -> Int? {
            guard i < m, isDigitBase(s[i]) else {
                return nil
            }
            var j = run(i, isDigitBase)
            while j + 1 < m && isMidNum(s[j]) && isDigitBase(s[j + 1]) {
                j = run(j + 1, isDigitBase)
            }
            return j
        }
        // (<number><word>)*{<number>{<post-num>}} from i
        func numbersAndWords(_ i: Int) -> Int {
            var j = i
            while let n = number(j) {
                if let w = word(n) {
                    j = w
                    continue
                }
                j = n
                if j < m && isPostNum(s[j]) {
                    j += 1
                }
                break
            }
            return j
        }
        // ".": any character
        var best = start + 1
        // {<word>}(<number><word>)*{<number>{<post-num>}}
        best = max(best, numbersAndWords(word(start) ?? start))
        // <pre-num>(<number><word>)*{<number>{<post-num>}}
        if isPreNum(s[start]) {
            best = max(best, numbersAndWords(start + 1))
        }
        // <ws>*{\r}{<ls>}
        var j = run(start, { 0x09 == $0 || .spaceSeparator == category($0) })
        if j < m && 0x0D == s[j] {
            j += 1
        }
        if j < m && (0x0A == s[j] || 0x0C == s[j] || 0x2028 == s[j] || 0x2029 == s[j]) {
            j += 1
        }
        best = max(best, j)
        // runs of katakana, of hiragana (each with CJK diacritics), and of
        // kanji
        j = start
        while j < m && (isKata(s[j]) || isCJKDiacritic(s[j])) {
            j += 1
        }
        best = max(best, j)
        j = start
        while j < m && (isHira(s[j]) || isCJKDiacritic(s[j])) {
            j += 1
        }
        best = max(best, j)
        j = start
        while j < m && isKanji(s[j]) {
            j += 1
        }
        best = max(best, j)
        // <base><enclosing><enclosing>*: any but Cc, Cf, Zl, Zp and the
        // enclosing marks, then those marks
        switch category(s[start]) {
        case .control, .format, .lineSeparator, .paragraphSeparator, .nonspacingMark, .enclosingMark:
            break
        default:
            j = start + 1
            while j < m && isEnclosing(s[j]) {
                j += 1
            }
            if j > start + 1 {
                best = max(best, j)
            }
        }
        return best
    }

    /// ConditionalSpecialCasing.isFinalCased (JDK 27, :193-222): within
    /// the word segment holding the sigma at `index`, a cased character
    /// comes before it and none after. The segment's ends are where
    /// isBoundary says so, which is also right after any supplementary
    /// character but one that starts the text: isBoundary(i) asks
    /// following(i - 1), and i - 1 is then the character's low surrogate,
    /// which the iterator steps over as a character of its own ("A𝐀Σ"
    /// lowercases to "a𝐀σ", "𝐀Σ" to "𝐀ς").
    private static func isFinalCased(_ points: [UInt32], _ index: Int, _ boundary: [Bool]) -> Bool {
        func isBoundary(_ i: Int) -> Bool {
            boundary[i] || (i >= 2 && points[i - 1] >= 0x10000)
        }
        var i = index
        while i > 0 && !isBoundary(i) {
            if isJavaCased(points[i - 1]) {
                var k = index + 1
                while k < points.count && !isBoundary(k) {
                    if isJavaCased(points[k]) {
                        return false
                    }
                    k += 1
                }
                return true
            }
            i -= 1
        }
        return false
    }

    // MARK: - convertIdent

    /// StringUtils.convertStringIndex(s, 0, len, false) (util/StringUtils
    /// .java:16-180), as convertIdent runs it on an identifier's image: a hex
    /// escape from 32 to 254 becomes its character (after a backslash unless
    /// it's [A-Za-z0-9_-]); any other is re-escaped as lowercase hex, padded
    /// to six digits once any escape so far ended in whitespace (the flag is
    /// never reset); a backslash before other characters stays. The digit
    /// count's quirk (a seventh hex digit makes it seven) is kept.
    private static func convertIdent(_ s: [UInt16]) -> [UInt16] {
        if !s.contains(0x5C) {
            return s
        }
        let len = s.count
        let maxCount = 6
        var buf = [UInt16]()
        buf.reserveCapacity(len)
        var index = 0
        var gotWhiteSpace = false
        let hexdigits: [UInt16] = Array("0123456789abcdef".utf16)
        while index < len {
            var c = s[index]
            if 0x5C == c {
                index += 1
                if index < len {
                    c = s[index]
                    if isHex(c) {
                        var numValue = Int(hexValue(c))
                        var count = 1
                        while index + 1 < len {
                            c = s[index + 1]
                            // Character.digit(c, 16), unlike the switch on
                            // the first digit, takes any Unicode decimal
                            // digit and fullwidth A-F and a-f, so "\6" and a
                            // fullwidth 1 make "a" (Case 554591 review)
                            let t = javaHexDigit(c)
                            var digit = false
                            if -1 != t {
                                // `count++ < maxCount`, evaluated only for a
                                // hex digit
                                digit = count < maxCount
                                count += 1
                            }
                            if digit {
                                numValue = (numValue << 4) | t
                                index += 1
                            } else {
                                if 0x20 == c || 0x09 == c || 0x0A == c || 0x0C == c {
                                    index += 1
                                    gotWhiteSpace = true
                                } else if 0x0D == c {
                                    index += 1
                                    gotWhiteSpace = true
                                    if index + 1 < len && 0x0A == s[index + 1] {
                                        index += 1
                                    }
                                }
                                break
                            }
                        }
                        if numValue < 255 && numValue > 31 {
                            let keep = (numValue > 96 && numValue < 123) || (numValue > 64 && numValue < 91)
                                || (numValue > 47 && numValue < 58) || 95 == numValue || 45 == numValue
                            if !keep {
                                buf.append(0x5C)
                            }
                            buf.append(UInt16(numValue))
                        } else {
                            var t = gotWhiteSpace ? maxCount : count
                            var b = [UInt16](repeating: 0x30, count: t)
                            var v = numValue
                            while t > 0 {
                                t -= 1
                                b[t] = hexdigits[v & 0xF]
                                v >>= 4
                            }
                            buf.append(0x5C)
                            buf.append(contentsOf: b)
                        }
                    } else if 0x0A == c || 0x0C == c {
                        // an escaped line break is dropped
                    } else if 0x0D == c {
                        if index + 1 < len && 0x0A == s[index + 1] {
                            index += 1
                        }
                    } else if 0x2D == c || 0x5F == c || isASCIILetter(c) {
                        buf.append(c)
                    } else {
                        buf.append(0x5C)
                        buf.append(c)
                    }
                } else {
                    // A trailing backslash throws "unrecognize"; an IDENT
                    // never ends in one, so keep it.
                    buf.append(0x5C)
                }
            } else {
                buf.append(c)
            }
            index += 1
        }
        return buf
    }

    /// Character.digit(char, 16): an ASCII hex digit; a Unicode decimal
    /// digit (Nd) of the BMP, as its value; or a fullwidth A-F or a-f
    /// (U+FF21-FF26, U+FF41-FF46), as 10-15; otherwise -1.
    private static func javaHexDigit(_ c: UInt16) -> Int {
        if isHex(c) {
            return Int(hexValue(c))
        }
        if c >= 0xFF21 && c <= 0xFF26 {
            return Int(c - 0xFF21) + 10
        }
        if c >= 0xFF41 && c <= 0xFF46 {
            return Int(c - 0xFF41) + 10
        }
        guard c >= 0x80, let scalar = Unicode.Scalar(UInt32(c)), .decimal == scalar.properties.numericType,
              let value = scalar.properties.numericValue, value >= 0 && value <= 9 else {
            return -1
        }
        return Int(value)
    }

    private static func hexValue(_ c: UInt16) -> UInt16 {
        if c <= 0x39 {
            return c - 0x30
        }
        if c <= 0x46 {
            return c - 0x41 + 10
        }
        return c - 0x61 + 10
    }

    // MARK: - The token manager

    /// CssParserTokenManager, as CssParser.jj declares its tokens: at each
    /// position the longest match wins, and of equally long ones the kind
    /// declared first. COMMENT is a special token, skipped. A character no
    /// token can start raises TokenMgrError; upstream then backs up to the
    /// character its automaton died on, which is where the next attempt
    /// starts (`resume`).
    private struct Lexer {
        let t: [UInt16]
        /// Where the last "*/" and the last ")" are, so an unclosed comment
        /// or PROGID is known at once, not by a scan to the end each time
        /// (which made "/* /* /* …" quadratic).
        let lastCommentClose: Int
        let lastParen: Int

        init(t: [UInt16]) {
            self.t = t
            var close = -1
            var paren = -1
            var k = t.count - 1
            while k >= 0 && (close < 0 || paren < 0) {
                if paren < 0 && 0x29 == t[k] {
                    paren = k
                }
                if close < 0 && k + 1 < t.count && 0x2A == t[k] && 0x2F == t[k + 1] {
                    close = k
                }
                k -= 1
            }
            lastCommentClose = close
            lastParen = paren
        }

        enum Result {
            case token(Int, Int)
            case comment(Int)
            case eof
            case failure(Int)
        }

        /// Whether the text at i starts with `s` (ASCII), ignoring ASCII
        /// case when `ignoreCase`.
        private func startsWith(_ s: String, at i: Int, ignoreCase: Bool) -> Bool {
            var k = i
            for u in s.utf16 {
                guard k < t.count else {
                    return false
                }
                let c = ignoreCase ? HTMLMediaQueryDatatype.asciiLower(t[k]) : t[k]
                if c != u {
                    return false
                }
                k += 1
            }
            return true
        }

        /// COMMENT (CssParser.jj:532): "/*" … "*/", ending at the first
        /// "*/"; nil when it isn't closed.
        private func comment(_ i: Int) -> Int? {
            guard i + 1 < t.count, 0x2F == t[i], 0x2A == t[i + 1], lastCommentClose >= i + 2 else {
                return nil
            }
            var k = i + 2
            while k + 1 < t.count {
                if 0x2A == t[k] && 0x2F == t[k + 1] {
                    return k + 2
                }
                k += 1
            }
            return nil
        }

        /// _S (CssParser.jj:557): a whitespace character, then any run of
        /// whitespace and complete comments.
        private func whitespace(_ i: Int) -> Int? {
            guard i < t.count, HTMLMediaQueryDatatype.isSpace(t[i]) else {
                return nil
            }
            var k = i + 1
            while k < t.count {
                if HTMLMediaQueryDatatype.isSpace(t[k]) {
                    k += 1
                } else if let e = comment(k) {
                    k = e
                } else {
                    break
                }
            }
            return k
        }

        /// ( <S> )*: any number of _S runs.
        private func spaces(_ i: Int) -> Int {
            var k = i
            while let e = whitespace(k) {
                k = e
            }
            return k
        }

        /// ESCAPE (CssParser.jj:540-542): a backslash and one to six hex
        /// digits with an optional whitespace (CR LF counting as one), or a
        /// backslash and any character but CR, LF, FF and the hex digits.
        func escape(_ i: Int) -> Int? {
            guard i + 1 < t.count, 0x5C == t[i] else {
                return nil
            }
            let c = t[i + 1]
            if HTMLMediaQueryDatatype.isHex(c) {
                var k = i + 1
                var n = 0
                while k < t.count && n < 6 && HTMLMediaQueryDatatype.isHex(t[k]) {
                    k += 1
                    n += 1
                }
                if k < t.count {
                    if 0x0D == t[k] && k + 1 < t.count && 0x0A == t[k + 1] {
                        k += 2
                    } else if HTMLMediaQueryDatatype.isSpace(t[k]) {
                        k += 1
                    }
                }
                return k
            }
            if 0x0D == c || 0x0A == c || 0x0C == c {
                return nil
            }
            return i + 2
        }

        /// NMSTART (CssParser.jj:543).
        private func nameStart(_ i: Int) -> Int? {
            guard i < t.count else {
                return nil
            }
            let c = t[i]
            if HTMLMediaQueryDatatype.isASCIILetter(c) || 0x5F == c || c >= 0x80 {
                return i + 1
            }
            if 0x5C == c {
                return escape(i)
            }
            return nil
        }

        /// NMCHAR (CssParser.jj:544).
        private func nameChar(_ i: Int) -> Int? {
            guard i < t.count else {
                return nil
            }
            let c = t[i]
            if HTMLMediaQueryDatatype.isASCIILetter(c) || HTMLMediaQueryDatatype.isDigit(c) || 0x2D == c
                || 0x5F == c || c >= 0x80 {
                return i + 1
            }
            if 0x5C == c {
                return escape(i)
            }
            return nil
        }

        /// NMCHAR*, and where the last escape in the run began.
        private func nameChars(_ i: Int) -> (end: Int, lastEscape: Int) {
            var k = i
            var lastEscape = -1
            while let e = nameChar(k) {
                if 0x5C == t[k] {
                    lastEscape = k
                }
                k = e
            }
            return (k, lastEscape)
        }

        /// _IDENT (CssParser.jj:550): "-"? NMSTART NMCHAR*.
        func ident(_ i: Int) -> Int? {
            var k = i
            if k < t.count && 0x2D == t[k] {
                k += 1
            }
            guard let e = nameStart(k) else {
                return nil
            }
            return nameChars(e).end
        }

        /// NUM (CssParser.jj:552): where it may end at i, shortest first:
        /// after the integer digits, after the fraction, after an exponent.
        private func numberEnds(_ i: Int) -> [Int] {
            var ends = [Int]()
            var k = i
            while k < t.count && HTMLMediaQueryDatatype.isDigit(t[k]) {
                k += 1
            }
            if k > i {
                ends.append(k)
            }
            if k + 1 < t.count && 0x2E == t[k] && HTMLMediaQueryDatatype.isDigit(t[k + 1]) {
                k += 1
                while k < t.count && HTMLMediaQueryDatatype.isDigit(t[k]) {
                    k += 1
                }
                ends.append(k)
            }
            guard let mantissa = ends.last else {
                return ends
            }
            if mantissa < t.count && 0x65 == HTMLMediaQueryDatatype.asciiLower(t[mantissa]) {
                var e = mantissa + 1
                if e < t.count && (0x2B == t[e] || 0x2D == t[e]) {
                    e += 1
                }
                if e < t.count && HTMLMediaQueryDatatype.isDigit(t[e]) {
                    while e < t.count && HTMLMediaQueryDatatype.isDigit(t[e]) {
                        e += 1
                    }
                    ends.append(e)
                }
            }
            return ends
        }

        /// The STRING (closed) or INVALID (unclosed) token at i
        /// (CssParser.jj:545-548).
        private func quoted(_ i: Int) -> (end: Int, closed: Bool) {
            let quote = t[i]
            var k = i + 1
            while k < t.count {
                let c = t[k]
                if c == quote {
                    return (k + 1, true)
                }
                if 0x0A == c || 0x0D == c || 0x0C == c {
                    return (k, false)
                }
                if 0x5C == c {
                    guard k + 1 < t.count else {
                        return (k, false)
                    }
                    let d = t[k + 1]
                    if 0x0A == d || 0x0C == d {
                        k += 2
                    } else if 0x0D == d {
                        k += 2
                        if k < t.count && 0x0A == t[k] {
                            k += 1
                        }
                    } else if let e = escape(k) {
                        k = e
                    } else {
                        k += 2
                    }
                    continue
                }
                k += 1
            }
            return (k, false)
        }

        /// URL (CssParser.jj:651-653): "url(" S* ( STRING | _URL ) S* ")".
        private func url(_ i: Int) -> Int? {
            guard startsWith("url(", at: i, ignoreCase: true) else {
                return nil
            }
            var k = spaces(i + 4)
            if k < t.count && (0x22 == t[k] || 0x27 == t[k]) {
                let q = quoted(k)
                guard q.closed else {
                    return nil
                }
                k = q.end
            } else {
                while k < t.count {
                    let c = t[k]
                    if 0x21 == c || (c >= 0x23 && c <= 0x26) || (c >= 0x2A && c <= 0x5B) || (c >= 0x5D && c <= 0x7E)
                        || c >= 0x80 {
                        k += 1
                    } else if 0x5C == c, let e = escape(k) {
                        k = e
                    } else {
                        break
                    }
                }
            }
            k = spaces(k)
            guard k < t.count, 0x29 == t[k] else {
                return nil
            }
            return k + 1
        }

        /// UNICODERANGE (CssParser.jj:768-781): "U+" with one to six hex
        /// digits and question marks (six at most), or a hex range.
        private func unicodeRange(_ i: Int) -> Int? {
            guard i + 1 < t.count, 0x75 == HTMLMediaQueryDatatype.asciiLower(t[i]), 0x2B == t[i + 1] else {
                return nil
            }
            var best: Int?
            var k = i + 2
            var h = 0
            while k < t.count && h < 6 && HTMLMediaQueryDatatype.isHex(t[k]) {
                k += 1
                h += 1
            }
            var q = 0
            while k < t.count && h + q < 6 && 0x3F == t[k] {
                k += 1
                q += 1
            }
            if h + q > 0 {
                best = k
            }
            if h > 0 {
                var e = i + 2 + h
                if e < t.count && 0x2D == t[e] {
                    e += 1
                    var h2 = 0
                    while e < t.count && h2 < 6 && HTMLMediaQueryDatatype.isHex(t[e]) {
                        e += 1
                        h2 += 1
                    }
                    if h2 > 0 && e > (best ?? 0) {
                        best = e
                    }
                }
            }
            return best
        }

        /// PROGID (CssParser.jj:576): "progid:DXImageTransform.Microsoft."
        /// [a-z]+ ~[")"]+ ")".
        private func progid(_ i: Int) -> Int? {
            let prefix = "progid:dximagetransform.microsoft."
            guard startsWith(prefix, at: i, ignoreCase: true) else {
                return nil
            }
            var k = i + prefix.utf16.count
            guard k < t.count, HTMLMediaQueryDatatype.isASCIILetter(t[k]) else {
                return nil
            }
            k += 1
            guard k < t.count, 0x29 != t[k], lastParen > k else {
                return nil
            }
            while k < t.count && 0x29 != t[k] {
                k += 1
            }
            return k < t.count ? k + 1 : nil
        }

        /// HTMLSTARTTAG and HTMLENDTAG (CssParser.jj:826-833), with each
        /// identifier taken whole.
        private func htmlTag(_ i: Int) -> (Int, Int)? {
            guard i < t.count, 0x3C == t[i] else {
                return nil
            }
            if i + 1 < t.count && 0x2F == t[i + 1] {
                var k = spaces(i + 2)
                guard let e = ident(k) else {
                    return nil
                }
                k = spaces(e)
                guard k < t.count, 0x3E == t[k] else {
                    return nil
                }
                return (T.htmlEndTag, k + 1)
            }
            var k = i + 1
            if startsWith("!doctype", at: k, ignoreCase: true) {
                k += 8
            }
            k = spaces(k)
            guard let e = ident(k) else {
                return nil
            }
            k = spaces(e)
            while true {
                guard let a = ident(k), a < t.count, 0x3D == t[a] else {
                    break
                }
                var v = a + 1
                if let e2 = ident(v) {
                    v = e2
                } else if v < t.count && (0x22 == t[v] || 0x27 == t[v]) {
                    let q = quoted(v)
                    guard q.closed else {
                        break
                    }
                    v = q.end
                } else {
                    break
                }
                k = spaces(v)
            }
            guard k < t.count, 0x3E == t[k] else {
                return nil
            }
            return (T.htmlStartTag, k + 1)
        }

        func lex(_ p: Int) -> Result {
            guard p < t.count else {
                return .eof
            }
            let c = t[p]
            var bestKind = -1
            var bestEnd = p
            func offer(_ kind: Int, _ end: Int?) {
                guard let e = end, e > p else {
                    return
                }
                if e > bestEnd || (e == bestEnd && kind < bestKind) {
                    bestKind = kind
                    bestEnd = e
                }
            }
            func next(_ k: Int) -> UInt16? {
                k < t.count ? t[k] : nil
            }
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
                // S, and the tokens that begin with optional whitespace
                // (CssParser.jj:589-599)
                let w = whitespace(p) ?? p + 1
                offer(T.s, w)
                if let d = next(w) {
                    switch d {
                    case 0x7B:
                        offer(T.lbrace, w + 1)
                    case 0x2B:
                        offer(T.plus, w + 1)
                    case 0x3E:
                        offer(T.greater, w + 1)
                        if 0x3D == next(w + 1) {
                            offer(T.greaterEq, w + 2)
                        }
                    case 0x2C:
                        offer(T.comma, w + 1)
                    case 0x7E:
                        offer(T.tilde, w + 1)
                        if 0x3D == next(w + 1) {
                            offer(T.includes, w + 2)
                        }
                    case 0x7C:
                        if 0x7C == next(w + 1) {
                            offer(T.twoPipes, w + 2)
                        }
                    default:
                        break
                    }
                }
            case 0x2F:
                if let e = comment(p) {
                    return .comment(e)
                }
                if 0x2A == next(p + 1) {
                    offer(T.sco, p + 2)
                }
                offer(T.div, p + 1)
            case 0x7B:
                offer(T.lbrace, p + 1)
            case 0x7D:
                offer(T.rbrace, p + 1)
            case 0x2B:
                offer(T.plus, p + 1)
            case 0x3E:
                offer(T.greater, p + 1)
                if 0x3D == next(p + 1) {
                    offer(T.greaterEq, p + 2)
                }
            case 0x2C:
                offer(T.comma, p + 1)
            case 0x7E:
                offer(T.tilde, p + 1)
                if 0x3D == next(p + 1) {
                    offer(T.includes, p + 2)
                }
            case 0x7C:
                offer(T.pipe, p + 1)
                if 0x3D == next(p + 1) {
                    offer(T.dashMatch, p + 2)
                }
                if 0x7C == next(p + 1) {
                    offer(T.twoPipes, p + 2)
                }
            case 0x5E:
                if 0x3D == next(p + 1) {
                    offer(T.prefixMatch, p + 2)
                }
            case 0x24:
                offer(T.dollar, p + 1)
                if 0x3D == next(p + 1) {
                    offer(T.suffixMatch, p + 2)
                }
            case 0x2A:
                offer(T.any, p + 1)
                if 0x3D == next(p + 1) {
                    offer(T.substringMatch, p + 2)
                }
            case 0x3D:
                offer(T.eq, p + 1)
            case 0x3B:
                offer(T.semicolon, p + 1)
            case 0x5B:
                offer(T.lbracket, p + 1)
            case 0x5D:
                offer(T.rbracket, p + 1)
            case 0x28:
                offer(T.lparen, p + 1)
            case 0x29:
                offer(T.rparen, p + 1)
            case 0x3A:
                offer(T.colon, p + 1)
                if 0x3A == next(p + 1) {
                    offer(T.pseudoElement, p + 2)
                }
            case 0x25:
                offer(T.percent, p + 1)
            case 0x26:
                offer(T.ampersand, p + 1)
            case 0x60:
                offer(T.backquote, p + 1)
            case 0x3F:
                offer(T.question, p + 1)
            case 0x22, 0x27:
                let q = quoted(p)
                offer(q.closed ? T.string : T.invalid, q.end)
            case 0x21:
                // "!", IMPORTANT_SYM and IMPORTANT_NOT (CssParser.jj:692-696)
                offer(T.bang, p + 1)
                let k = spaces(p + 1)
                if startsWith("important", at: k, ignoreCase: true) {
                    offer(T.importantSym, k + 9)
                }
                if startsWith("ie", at: k, ignoreCase: true) {
                    var e = k + 2
                    if let d = next(e), 0x37 == d || 0x39 == d {
                        e += 1
                    }
                    offer(T.importantNot, e)
                }
            case 0x3C:
                offer(T.less, p + 1)
                if 0x3D == next(p + 1) {
                    offer(T.lessEq, p + 2)
                }
                if startsWith("<!--", at: p, ignoreCase: false) {
                    offer(T.cdo, p + 4)
                }
                if let (kind, e) = htmlTag(p) {
                    offer(kind, e)
                }
            case 0x40:
                // the at-rule keywords and ATKEYWORD (CssParser.jj:705-765)
                if let e = ident(p + 1) {
                    offer(T.atKeyword, e)
                    if startsWith("@charset", at: p, ignoreCase: true) {
                        offer(T.charsetSym, p + 8)
                    }
                    for (keyword, kind) in T.atRules where startsWith(keyword, at: p, ignoreCase: true) {
                        offer(kind, p + keyword.utf16.count)
                    }
                }
            case 0x23:
                // HASHIDENT and HASH (CssParser.jj:574-575)
                offer(T.hashIdent, ident(p + 1))
                let n = nameChars(p + 1).end
                if n > p + 1 {
                    offer(T.hash, n)
                }
            case 0x2E, 0x30...0x39:
                lexNumber(p, offer)
                if 0x2E == c {
                    offer(T.dot, p + 1)
                }
            default:
                break
            }
            // identifiers, and what begins like one (CssParser.jj:563-603,
            // 783-821)
            if HTMLMediaQueryDatatype.isASCIILetter(c) || 0x5F == c || 0x5C == c || 0x2D == c || c >= 0x80 {
                if 0x2D == c {
                    offer(T.minus, p + 1)
                    if 0x2D == next(p + 1) {
                        // DASHED_IDENT (CssParser.jj:580)
                        if let s = nameStart(p + 2) {
                            offer(T.dashedIdent, nameChars(s).end)
                        } else {
                            offer(T.dashedIdent, p + 2)
                        }
                        if 0x3E == next(p + 2) {
                            offer(T.cdc, p + 3)
                        }
                    }
                }
                if let e = ident(p) {
                    offer(T.ident, e)
                    let n = e - p
                    if 3 == n && startsWith("and", at: p, ignoreCase: true) {
                        offer(T.and, e)
                    } else if 2 == n && startsWith("or", at: p, ignoreCase: true) {
                        offer(T.or, e)
                    } else if 4 == n && startsWith("only", at: p, ignoreCase: true) {
                        offer(T.only, e)
                    } else if 3 == n && startsWith("not", at: p, ignoreCase: true) {
                        offer(T.not, e)
                    }
                    if 0x28 == next(e) {
                        offer(T.function, e + 1)
                        for (keyword, kind) in T.functions
                        where keyword.utf16.count == e + 1 - p && startsWith(keyword, at: p, ignoreCase: true) {
                            offer(kind, e + 1)
                        }
                        offer(T.url, url(p))
                    }
                    if 0x75 == HTMLMediaQueryDatatype.asciiLower(c) {
                        offer(T.unicodeRange, unicodeRange(p))
                    }
                    if 0x70 == HTMLMediaQueryDatatype.asciiLower(c) {
                        offer(T.progid, progid(p))
                    }
                } else if 0x75 == HTMLMediaQueryDatatype.asciiLower(c) {
                    offer(T.unicodeRange, unicodeRange(p))
                }
            }
            if bestKind >= 0 {
                return .token(bestKind, bestEnd)
            }
            return .failure(failurePoint(p))
        }

        /// The NUM-based tokens at p (CssParser.jj:654-689): each unit token
        /// with the longest NUM it can follow, DIMEN_9 when DIMEN's match
        /// ends in exactly "\9", PERCENTAGE and NUMBER.
        private func lexNumber(_ p: Int, _ offer: (Int, Int?) -> Void) {
            let ends = numberEnds(p)
            guard !ends.isEmpty else {
                return
            }
            for e in ends {
                for (kind, units) in T.units {
                    for unit in units where startsWith(unit, at: e, ignoreCase: true) {
                        offer(kind, e + unit.utf16.count)
                    }
                }
                if let s = nameStart(e) {
                    // DIMEN_9's "\\9" follows NMSTART NMCHAR*, so it has to
                    // be an escape of the NMCHAR run, not the NMSTART
                    let run = nameChars(s)
                    offer(T.dimen, run.end)
                    let lastEscape = run.lastEscape
                    if lastEscape >= 0 && lastEscape + 2 == run.end && 0x39 == t[lastEscape + 1] {
                        offer(T.dimen9, run.end)
                    }
                }
                if e < t.count && 0x25 == t[e] {
                    offer(T.percentage, e + 1)
                }
                offer(T.number, e)
            }
        }

        /// Where upstream's automaton died on a character no token starts
        /// with, which is where its stream is left (the error handling in
        /// CssParserTokenManager.getNextToken backs up to it): the character
        /// itself when nothing can start there, else the one after the live
        /// prefix ("@ ", "# ", "^x", a backslash before a line break).
        private func failurePoint(_ p: Int) -> Int {
            let c = t[p]
            /// After "#", "@" or "@-", a backslash keeps HASH's, HASHIDENT's
            /// or ATKEYWORD's ESCAPE alive, and only the line break after it
            /// kills the automaton (Case 554591 review): resuming on the
            /// backslash failed a second time where upstream goes on.
            func afterEscapeStart(_ k: Int) -> Int {
                if k + 1 < t.count && 0x5C == t[k] && (0x0A == t[k + 1] || 0x0D == t[k + 1] || 0x0C == t[k + 1]) {
                    return k + 1
                }
                return min(k, t.count)
            }
            switch c {
            case 0x40:
                var k = p + 1
                if k < t.count && 0x2D == t[k] {
                    k += 1
                }
                return afterEscapeStart(k)
            case 0x23:
                return afterEscapeStart(p + 1)
            case 0x5E, 0x5C:
                return min(p + 1, t.count)
            default:
                return p
            }
        }
    }

    // MARK: - Numbers

    /// A java.math.BigDecimal as BigDecimal(String) builds it from a token:
    /// the unscaled value's digits and the scale. Exponents are kept as the
    /// scale, never multiplied out, so "1e+999999" costs nothing.
    private struct Num {
        var negative: Bool
        /// The unscaled value's digits without leading zeros: empty for zero.
        var digits: [UInt8]
        var scale: Int
        /// The text it was made from, for quoting a number whose plain form
        /// would be huge.
        var source: String

        /// BigDecimal(String) on [+-]?digits(.digits)?(e[+-]?digits)?; nil
        /// for its NumberFormatException, which in the JDK vnu.jar runs on
        /// comes from more than ten exponent digits after its leading
        /// zeros, or a scale (fraction digits less the exponent) beyond a
        /// Java int: so 1e+2147483648 is a number (its scale is
        /// Integer.MIN_VALUE) and 1e+2147483649 isn't, as runs confirm.
        static func parse(_ s: [UInt16]) -> Num? {
            var i = 0
            var negative = false
            if i < s.count && (0x2D == s[i] || 0x2B == s[i]) {
                negative = 0x2D == s[i]
                i += 1
            }
            var digits = [UInt8]()
            var fraction = 0
            var sawDigit = false
            var sawPoint = false
            while i < s.count {
                let c = s[i]
                if isDigit(c) {
                    sawDigit = true
                    if !digits.isEmpty || 0x30 != c {
                        digits.append(UInt8(c - 0x30))
                    }
                    if sawPoint {
                        fraction += 1
                    }
                } else if 0x2E == c && !sawPoint {
                    sawPoint = true
                } else {
                    break
                }
                i += 1
            }
            guard sawDigit else {
                return nil
            }
            var exponent = 0
            if i < s.count {
                guard 0x65 == asciiLower(s[i]) else {
                    return nil
                }
                i += 1
                var expNegative = false
                if i < s.count && (0x2D == s[i] || 0x2B == s[i]) {
                    expNegative = 0x2D == s[i]
                    i += 1
                }
                let allDigits = s[i...]
                guard !allDigits.isEmpty, allDigits.allSatisfy(isDigit) else {
                    return nil
                }
                // parseExp skips leading zeros while more than ten digits
                // remain; by index, since removeFirst() on each made a
                // million zeros quadratic (Case 554591 review)
                var firstDigit = allDigits.startIndex
                while allDigits.endIndex - firstDigit > 10 && 0x30 == allDigits[firstDigit] {
                    firstDigit += 1
                }
                let expDigits = allDigits[firstDigit...]
                if expDigits.count > 10 {
                    return nil
                }
                var e: Int64 = 0
                for d in expDigits {
                    e = e * 10 + Int64(d - 0x30)
                }
                if expNegative {
                    e = -e
                }
                exponent = Int(e)
            }
            let scale = Int64(fraction) - Int64(exponent)
            guard scale >= Int64(Int32.min) && scale <= Int64(Int32.max) else {
                return nil
            }
            return Num(negative: negative && !digits.isEmpty, digits: digits, scale: Int(scale),
                       source: HTMLMediaQueryDatatype.string(s[...]))
        }

        var isZero: Bool {
            digits.isEmpty
        }

        /// The message of the NumberFormatException BigDecimal(String)
        /// throws where parse returns nil, as JDK 27 words it (CssDump
        /// shows "Exponent overflow." for a scale past an int and "Too many
        /// nonzero exponent digits." for more than ten): upstream records it
        /// for a value in a declaration.
        static func failure(_ s: [UInt16]) -> String {
            var i = 0
            if i < s.count && (0x2D == s[i] || 0x2B == s[i]) {
                i += 1
            }
            var sawPoint = false
            while i < s.count {
                let c = s[i]
                if isDigit(c) {
                    i += 1
                    continue
                }
                if 0x2E == c && !sawPoint {
                    sawPoint = true
                    i += 1
                    continue
                }
                if 0x65 == asciiLower(c) {
                    var k = i + 1
                    if k < s.count && (0x2D == s[k] || 0x2B == s[k]) {
                        k += 1
                    }
                    let exponent = s[k...]
                    if exponent.isEmpty {
                        return "No exponent digits."
                    }
                    if !exponent.allSatisfy(isDigit) {
                        return "Not a digit."
                    }
                    var first = exponent.startIndex
                    while exponent.endIndex - first > 10 && 0x30 == exponent[first] {
                        first += 1
                    }
                    if exponent.endIndex - first > 10 {
                        return "Too many nonzero exponent digits."
                    }
                    return "Exponent overflow."
                }
                let character = HTMLMediaQueryDatatype.string(s[i...i])
                return "Character \(character) is neither a decimal digit number, decimal point, nor \"e\" notation exponential mark."
            }
            return "No digits found."
        }

        /// Whether a number is greater than a small positive integer,
        /// without multiplying out its exponent.
        static func greaterThan(_ n: Num, _ limit: Int) -> Bool {
            if n.negative || n.digits.isEmpty {
                return false
            }
            // the integer part's digit count
            let integerDigits = n.digits.count - n.scale
            let limitDigits = String(limit).count
            if integerDigits > limitDigits {
                return true
            }
            if integerDigits < limitDigits {
                return false
            }
            // same magnitude: compare the integer part, then any fraction;
            // with a negative scale the integer part ends in zeros the
            // digits don't hold (Case 554591 review: 3e+2 compared as 3)
            var integer = 0
            for index in 0..<integerDigits {
                integer = integer * 10 + (index < n.digits.count ? Int(n.digits[index]) : 0)
            }
            if integer != limit {
                return integer > limit
            }
            return n.digits.dropFirst(integerDigits).contains(where: { 0 != $0 })
        }

        var signum: Int {
            digits.isEmpty ? 0 : (negative ? -1 : 1)
        }

        /// Whether BigDecimal.toPlainString() throws rather than return: the
        /// StringBuilder it sizes for the digits and zeros is past what a
        /// Java array can be (its int size overflows, or exceeds the VM's
        /// limit), or the zeros' count isn't an int (checkScaleNonZero's
        /// ArithmeticException). Upstream then fails wherever it prints the
        /// number: (width: 1e+2147483647px) is a Parse Error, as media()
        /// prints its features, and (orientation: 1e+2147483647) is valid,
        /// as building the error message throws inside the feature's
        /// constructor. (A plain form of a billion characters is merely
        /// slow upstream, and is taken to succeed.)
        var plainThrows: Bool {
            // HotSpot's largest byte[]: a vnu.jar run with a big heap
            // printed a number of 2,147,483,621 characters
            let limit = Int64(Int32.max) - 2
            if scale < 0 {
                if digits.isEmpty {
                    return false
                }
                let zeros = -Int64(scale)
                if zeros > Int64(Int32.max) {
                    return true
                }
                let capacity = (digits.count <= 18 ? 20 : Int64(digits.count)) + zeros
                return capacity > limit
            }
            if scale > 0 {
                // getValueString's "0.000…" buffer, 3 + the zeros + the digits
                let body = Int64(max(1, digits.count))
                return Int64(scale) - body + 3 + body > limit
            }
            return false
        }

        /// How long BigDecimal.toPlainString() is, which can be far longer
        /// than the text the number came from.
        var plainLength: Int64 {
            let sign: Int64 = negative ? 1 : 0
            if digits.isEmpty {
                return scale > 0 ? 2 + Int64(scale) : 1
            }
            if scale <= 0 {
                return sign + Int64(digits.count) - Int64(scale)
            }
            if digits.count > scale {
                return sign + Int64(digits.count) + 1
            }
            return sign + 2 + Int64(scale)
        }

        /// Whether a float of this number is infinite (it's past
        /// Float.MAX_VALUE, 3.4028235e38), as RGB's and HSL's filters
        /// compute it.
        var floatOverflows: Bool {
            guard !digits.isEmpty else {
                return false
            }
            let magnitude = Int64(digits.count) - Int64(scale)
            if 39 != magnitude {
                return magnitude > 39
            }
            let leading = digits.prefix(9).reduce(0) { $0 * 10 + Int($1) }
            let padded = leading * Int(pow(10.0, Double(9 - min(9, digits.count))))
            return padded > 340282356
        }

        /// BigDecimal.toPlainString(), unless that would spell out more
        /// than 64 zeros: then the number as written, so a value like
        /// 1e+999999 can't make a megabyte of reason. (Upstream spells them
        /// all out.)
        var plain: String {
            // toPlainString's signum() == 0 branch: a zero with a negative
            // scale has no zeros to spell out, so the 64-zero limit below
            // doesn't apply (Case 554591 review: "0e+70" was quoted as
            // written)
            if digits.isEmpty && scale < 0 {
                return "0"
            }
            if scale < -64 || scale > 64 + digits.count {
                var text = source
                if text.hasPrefix("+") {
                    text.removeFirst()
                }
                return text
            }
            var out = negative ? "-" : ""
            let body = digits.isEmpty ? [UInt8]([0]) : digits
            if scale <= 0 {
                for d in body {
                    out.append(Character(Unicode.Scalar(0x30 + d)))
                }
                if !digits.isEmpty {
                    out.append(String(repeating: "0", count: -scale))
                }
                return out
            }
            if body.count > scale {
                for (index, d) in body.enumerated() {
                    if index == body.count - scale {
                        out.append(".")
                    }
                    out.append(Character(Unicode.Scalar(0x30 + d)))
                }
            } else {
                out.append("0.")
                out.append(String(repeating: "0", count: scale - body.count))
                for d in body {
                    out.append(Character(Unicode.Scalar(0x30 + d)))
                }
            }
            return out
        }

        /// BigDecimal.intValueExact(): nil when the value has a fraction or
        /// doesn't fit a Java int.
        var intValueExact: Int32? {
            if digits.isEmpty {
                return 0
            }
            // digits beyond the point must be zeros
            var integral = digits
            if scale > 0 {
                guard scale <= integral.count else {
                    return nil
                }
                let fractionDigits = integral.suffix(scale)
                guard fractionDigits.allSatisfy({ 0 == $0 }) else {
                    return nil
                }
                integral.removeLast(scale)
            } else if scale < 0 {
                guard -scale <= 10 else {
                    return nil
                }
                integral.append(contentsOf: [UInt8](repeating: 0, count: -scale))
            }
            let significant = integral.drop(while: { 0 == $0 })
            guard significant.count <= 10 else {
                return nil
            }
            var v: Int64 = 0
            for d in significant {
                v = v * 10 + Int64(d)
            }
            if negative {
                v = -v
            }
            guard v >= Int64(Int32.min) && v <= Int64(Int32.max) else {
                return nil
            }
            return Int32(v)
        }
    }

    // MARK: - Values

    /// CssTypes (values/CssTypes.java).
    private enum CssType {
        static let unknown = -1
        static let ident = 0
        static let string = 1
        static let url = 2
        static let color = 3
        static let percentage = 4
        static let number = 5
        static let length = 6
        static let angle = 7
        static let time = 8
        static let frequency = 9
        static let resolution = 10
        static let function = 11
        static let unicodeRange = 12
        static let ratio = 13
        static let switchValue = 14
        static let hashIdent = 15
        static let image = 16
        static let volume = 17
        static let semitone = 18
        static let calc = 19
        static let attr = 20
        static let flex = 21
        static let bracket = 22
        static let comparator = 23
        static let mathFunction = 24
        static let variable = 25
        static let env = 27
        static let dashedIdent = 28
    }

    /// A CssExpression: values, each with the operator after it (' ' or
    /// ','), and the flags the grammar marks.
    private final class Expression {
        var values = [Value]()
        var operators = [UInt16]()
        var hasVariable = false

        var count: Int {
            values.count
        }

        /// addValue, with the marks the parser's setValue (CssParser.jj:
        /// 402-447) adds as it hands a value over: besides a var() itself,
        /// an env() still of type env, a calc() that holds a variable, and a
        /// function, image or color whose arguments do. The color and image
        /// classes skip their checks for a marked expression (Case 554591
        /// review).
        func add(_ value: Value) {
            switch value {
            case .variable:
                hasVariable = true
            case .env(_, let type, _):
                if CssType.env == type {
                    hasVariable = true
                }
            case .calc(let c):
                if c.containsVariable {
                    hasVariable = true
                }
            case .function(_, let args), .image(_, let args):
                if args.hasVariable {
                    hasVariable = true
                }
            case .color(let c):
                if c.marked {
                    hasVariable = true
                }
            default:
                break
            }
            values.append(value)
            operators.append(0x20)
        }

        func setOperator(_ op: UInt16) {
            if !operators.isEmpty {
                operators[operators.count - 1] = op
            }
        }

        /// The values with ", " where a comma was, as the color and image
        /// classes print their arguments.
        var spacedText: String {
            var out = ""
            for (index, value) in values.enumerated() {
                if index > 0 {
                    out += 0x2C == operators[index - 1] ? ", " : " "
                }
                out.append(value.text)
            }
            return out
        }

        /// toStringFromStart(): each value and its operator, without the
        /// last operator.
        var text: String {
            var out = ""
            for (index, value) in values.enumerated() {
                if index > 0 {
                    out.append(Character(Unicode.Scalar(operators[index - 1]) ?? " "))
                }
                out.append(value.text)
            }
            return out
        }
    }

    /// A CssCalc (values/CssCalc.java): one value, or two with an operator,
    /// its computed type, and whether it's an explicit calc().
    private final class Calc {
        var val1: Value
        var val2: Value?
        var op: UInt16 = 0x20
        var computedType: Int
        var hasParen = false
        var implicitFunction = true
        var containsVariable = false

        init(_ value: Value) {
            val1 = value
            if case .calc(let c) = value {
                containsVariable = c.containsVariable
            } else if CssType.variable == value.type {
                containsVariable = true
            }
            computedType = value.type
        }

        var type: Int {
            CssType.calc == computedType ? CssType.calc : computedType
        }

        /// toStringUnprefixed().
        var unprefixed: String {
            var out = hasParen ? "(" : ""
            if case .calc(let c) = val1, c.implicitFunction {
                out += c.unprefixed
            } else {
                out += val1.text
            }
            if let v2 = val2 {
                out += " " + String(Character(Unicode.Scalar(op) ?? " ")) + " "
                if case .calc(let c) = v2, c.implicitFunction {
                    out += c.unprefixed
                } else {
                    out += v2.text
                }
            }
            if hasParen {
                out += ")"
            }
            return out
        }

        var text: String {
            implicitFunction ? unprefixed : "calc(" + unprefixed + ")"
        }
    }

    /// A CssMathFunction (values/CssMathFunction.java).
    private final class MathFunction {
        let prefix: String
        var values = [Value]()
        var computedType = CssType.unknown
        var hasVariable = false
        /// The list functions' type fold (min, max, hypot, clamp), kept
        /// between calls: upstream folds the whole list again at every
        /// addValue, which is quadratic, and a fold of a prefix doesn't
        /// depend on what follows, so carrying it on gives the same types
        /// and the same first error.
        var listType = CssType.mathFunction
        var listFirst = true
        var listPrevious: Value?
        var listFolded = 0

        init(prefix: String) {
            self.prefix = prefix
        }

        var type: Int {
            CssType.mathFunction == computedType ? CssType.mathFunction : computedType
        }

        var unprefixed: String {
            values.map { $0.text }.joined(separator: ", ")
        }

        var text: String {
            prefix + unprefixed + ")"
        }
    }

    /// A CssColor's toString, built when a message needs it: RGBA's
    /// modern "rgb(r g b / a)" or legacy "rgba(r, g, b, a)" form
    /// (values/color/RGBA.java:511-537), HSL's "hsl(h s l / a)", or a color
    /// function this port doesn't take apart, as written. The parts are
    /// the values as the color keeps them, after its filters' clamping.
    private final class ColorText {
        enum Form {
            case modernRGB
            case legacyRGB
            case hsl(String)
            case asWritten(String)
            case relative(String)
        }

        let form: Form
        let printedParts: [Value]
        let printedAlpha: Value?
        let expression: Expression?

        init(_ form: Form, _ parts: [Value], alpha: Value?, expression: Expression?) {
            self.form = form
            printedParts = parts
            printedAlpha = alpha
            self.expression = expression
        }

        /// CssColor.hasCssVariable: RGBA, HSL and the other color parsers
        /// mark the color when their arguments hold a variable;
        /// LightDark only when one of its colors is marked, and ColorMix
        /// never (Case 554591 review).
        var marked: Bool {
            guard let e = expression else {
                return false
            }
            if case .asWritten(let name) = form {
                switch name.lowercased() {
                case "color-mix":
                    return false
                case "light-dark":
                    return e.values.contains { v in
                        if case .color(let c) = v {
                            return c.marked
                        }
                        return false
                    }
                default:
                    return e.hasVariable
                }
            }
            return e.hasVariable
        }

        /// One of the color functions function() takes on trust
        /// (colorOrFunction), or a relative color; not hsl() kept as
        /// written for a variable.
        var isOnTrust: Bool {
            switch form {
            case .relative:
                return true
            case .asWritten(let name):
                return ["hwb", "lab", "lch", "oklab", "oklch", "device-cmyk", "light-dark", "color-mix"]
                    .contains(name.lowercased())
            default:
                return false
            }
        }

        /// Whether the text is the arguments as written, rather than the
        /// filtered parts.
        var printsExpression: Bool {
            switch form {
            case .asWritten, .relative:
                return true
            default:
                return false
            }
        }

        var text: String {
            switch form {
            case .modernRGB:
                return "rgb(" + printedParts.map { $0.text }.joined(separator: " ")
                    + (printedAlpha.map { " / " + $0.text } ?? "") + ")"
            case .legacyRGB:
                return "rgba(" + printedParts.map { $0.text }.joined(separator: ", ")
                    + (printedAlpha.map { ", " + $0.text } ?? "") + ")"
            case .hsl(let name):
                return name + "(" + printedParts.map { $0.text }.joined(separator: " ")
                    + (printedAlpha.map { " / " + $0.text } ?? "") + ")"
            case .asWritten(let name):
                return name + "(" + (expression?.spacedText ?? "") + ")"
            case .relative(let name):
                // RGBA's and HSL's toString for a relative color put "from
                // <color> " before the function (RGBA.java:515-517)
                guard let e = expression, e.count >= 2 else {
                    return name + "()"
                }
                let rest = e.values.dropFirst(2)
                var inner = [String]()
                var slash = false
                for v in rest {
                    if case .switchValue = v {
                        slash = true
                        continue
                    }
                    inner.append((slash ? "/ " : "") + v.text)
                    slash = false
                }
                return "from " + e.values[1].text + " " + name + "(" + inner.joined(separator: " ") + ")"
            }
        }
    }

    /// A CSS value, as the validator's CssValue subclasses hold it.
    private indirect enum Value {
        case number(Num, isInt: Bool, special: String?)
        case percentage(Num)
        case length(Num, String)
        case flex(Num)
        case angle(Num, String)
        case time(Num, String)
        case frequency(Num, String)
        case resolution(Num, String)
        case semitone(Num)
        case volume(Num)
        case ratio(Num, Num)
        case ident([UInt16])
        case string(String)
        case hashIdent(String)
        case url(String)
        case unicodeRange(String)
        case dashedIdent(String)
        case switchValue
        case bracket(String)
        case function(String, Expression)
        case color(ColorText)
        case image(String, Expression)
        case calc(Calc)
        case math(MathFunction)
        /// var(), env() and attr(): the text up to their fallback or
        /// declaration, their type, and that expression, printed when a
        /// message needs it.
        case variable(String, Int, Expression?)
        case env(String, Int, Expression?)
        case attr(String, Int, Expression?)
        case comparator(String, Expression)

        /// getType().
        var type: Int {
            switch self {
            case .number:
                return CssType.number
            case .percentage:
                return CssType.percentage
            case .length:
                return CssType.length
            case .flex:
                return CssType.flex
            case .angle:
                return CssType.angle
            case .time:
                return CssType.time
            case .frequency:
                return CssType.frequency
            case .resolution:
                return CssType.resolution
            case .semitone:
                return CssType.semitone
            case .volume:
                return CssType.volume
            case .ratio:
                return CssType.ratio
            case .ident:
                return CssType.ident
            case .string:
                return CssType.string
            case .hashIdent:
                return CssType.hashIdent
            case .url:
                return CssType.url
            case .unicodeRange:
                return CssType.unicodeRange
            case .dashedIdent:
                return CssType.dashedIdent
            case .switchValue:
                return CssType.switchValue
            case .bracket:
                return CssType.bracket
            case .function:
                return CssType.function
            case .color:
                return CssType.color
            case .image:
                return CssType.image
            case .calc(let c):
                return c.type
            case .math(let m):
                return m.type
            case .variable(_, let t, _), .env(_, let t, _), .attr(_, let t, _):
                return t
            case .comparator:
                return CssType.comparator
            }
        }

        /// getIdent() as each class answers it: an identifier is itself; a
        /// var() or env() of identifier type gives its one fallback value's
        /// (CssVariable.java:361-367, CssEnv.java:458-464); anything else,
        /// such as abs(var(--x, a)), whose type is that fallback's,
        /// throws ClassCastException (CssValue.java:89-91), nil here.
        var javaIdent: [UInt16]? {
            if case .ident(let units)? = javaIdentValue {
                return units
            }
            return nil
        }

        /// The identifier getIdent() answers with, as a value (for its text).
        var javaIdentValue: Value? {
            switch self {
            case .ident:
                return self
            case .variable(_, let type, let fallback), .env(_, let type, let fallback):
                guard CssType.ident == type, let f = fallback, 1 == f.count else {
                    return nil
                }
                return f.values[0].javaIdentValue
            default:
                return nil
            }
        }

        /// getRawType().
        var rawType: Int {
            switch self {
            case .calc:
                return CssType.calc
            case .math:
                return CssType.mathFunction
            case .variable:
                return CssType.variable
            case .env:
                return CssType.env
            case .attr:
                return CssType.attr
            default:
                return type
            }
        }

        /// toString().
        var text: String {
            switch self {
            case .number(let n, _, let special):
                return special ?? n.plain
            case .percentage(let n):
                return n.plain + "%"
            case .length(let n, let unit):
                return n.isZero ? "0" : n.plain + unit
            case .flex(let n):
                return n.isZero ? "0" : n.plain + "fr"
            case .angle(let n, let unit):
                return n.plain + (n.isZero ? "deg" : unit)
            case .time(let n, let unit):
                return n.plain + (n.isZero ? "s" : unit)
            case .frequency(let n, let unit):
                return n.isZero ? "0" : n.plain + unit
            case .resolution(let n, let unit):
                return n.plain + (n.isZero ? "dpi" : unit)
            case .semitone(let n):
                return n.plain + "st"
            case .volume(let n):
                return n.plain + "db"
            case .ratio(let w, let h):
                return w.plain + "/" + h.plain
            case .string(let s), .hashIdent(let s), .url(let s), .unicodeRange(let s),
                 .dashedIdent(let s), .bracket(let s):
                return s
            case .color(let c):
                return c.text
            case .image(let name, let args):
                return name + "(" + args.spacedText + ")"
            case .ident(let units):
                return HTMLMediaQueryDatatype.string(units[...])
            case .switchValue:
                return "/"
            case .function(let name, let args):
                return name + "(" + args.text + ")"
            case .calc(let c):
                return c.text
            case .math(let m):
                return m.text
            case .variable(let head, _, let tail), .env(let head, _, let tail), .attr(let head, _, let tail):
                return head + (tail.map { ", " + $0.text } ?? "") + ")"
            case .comparator(let symbol, _):
                return symbol
            }
        }

        /// How long Java's toString() of this value is (saturating), for
        /// knowing whether it, or a message holding it, can be built.
        var textLength: Int64 {
            func add(_ a: Int64, _ b: Int64) -> Int64 {
                let (sum, overflow) = a.addingReportingOverflow(b)
                return overflow ? Int64.max / 2 : min(sum, Int64.max / 2)
            }
            func sum(_ values: [Value]) -> Int64 {
                values.reduce(Int64(0)) { add(add($0, $1.textLength), 2) }
            }
            switch self {
            case .number(let n, _, let special):
                return special.map { Int64($0.utf16.count) } ?? n.plainLength
            case .length(let n, let unit), .frequency(let n, let unit):
                return n.isZero ? 1 : add(n.plainLength, Int64(unit.utf16.count))
            case .flex(let n):
                return n.isZero ? 1 : add(n.plainLength, 2)
            case .percentage(let n):
                return add(n.plainLength, 1)
            case .angle(let n, _), .time(let n, _), .resolution(let n, _), .semitone(let n), .volume(let n):
                return add(n.plainLength, 4)
            case .ratio(let w, let h):
                return add(add(w.plainLength, h.plainLength), 1)
            case .function(let name, let args), .image(let name, let args):
                return add(Int64(name.utf16.count) + 2, sum(args.values))
            case .color(let c):
                return add(add(sum(c.printedParts), c.printedAlpha?.textLength ?? 0),
                           add(16, sum(c.printsExpression ? c.expression?.values ?? [] : [])))
            case .calc(let c):
                return add(add(c.val1.textLength, c.val2?.textLength ?? 0), 8)
            case .math(let m):
                return add(Int64(m.prefix.utf16.count) + 1, sum(m.values))
            case .variable(let head, _, let tail), .env(let head, _, let tail), .attr(let head, _, let tail):
                return add(Int64(head.utf16.count) + 3, sum(tail?.values ?? []))
            case .ident(let units):
                return Int64(units.count)
            default:
                return Int64(text.utf16.count)
            }
        }

        /// Whether a message that quotes this value can be built: the
        /// curly quotes make it UTF-16, whose Java strings stop at
        /// 1,073,741,823 characters (StringUTF16.MAX_LENGTH).
        var messageThrows: Bool {
            textThrows || textLength + 64 > Int64(Int32.max >> 1)
        }

        /// Whether Java's toString() of this value throws, as a number in it
        /// can't be printed (Num.plainThrows) or the whole is past a Java
        /// string's length: zero lengths, flexes and frequencies print as
        /// "0" without printing the number.
        var textThrows: Bool {
            if textLength > Int64(Int32.max) - 2 {
                return true
            }
            switch self {
            case .number(let n, _, let special):
                return nil == special && n.plainThrows
            case .length(let n, _), .flex(let n), .frequency(let n, _):
                return !n.isZero && n.plainThrows
            case .percentage(let n), .angle(let n, _), .time(let n, _), .resolution(let n, _), .semitone(let n),
                 .volume(let n):
                return n.plainThrows
            case .ratio(let w, let h):
                return w.plainThrows || h.plainThrows
            case .function(_, let args), .image(_, let args):
                return args.values.contains { $0.textThrows }
            case .color(let c):
                return c.printedParts.contains { $0.textThrows } || (c.printedAlpha?.textThrows ?? false)
                    || (c.printsExpression && (c.expression?.values.contains { $0.textThrows } ?? false))
            case .calc(let c):
                return c.val1.textThrows || (c.val2?.textThrows ?? false)
            case .math(let m):
                return m.values.contains { $0.textThrows }
            case .variable(_, _, let tail), .env(_, _, let tail), .attr(_, _, let tail):
                return tail?.values.contains { $0.textThrows } ?? false
            default:
                return false
            }
        }

        /// A color or gradient the port takes on trust (hwb(), lab(),
        /// light-dark(), color-mix(), a relative color, the gradients): its
        /// arguments may well be ones upstream's parser throws on, which a
        /// caller that swallows a ParseException (env()'s and var()'s
        /// fallbacks) would then never see as a value at all.
        var isOnTrust: Bool {
            switch self {
            case .color(let c):
                return c.isOnTrust
            case .image(let name, _):
                return "image" != name.lowercased()
            default:
                return false
            }
        }

        /// getCheckableValue().isZero() as each class answers it: a calc()
        /// always is (CssCalc.java:315-318), a math function never is, and a
        /// var() or env() is when its one fallback value is
        /// (CssVariable.java:274-283, CssEnv.java:358-368).
        var checkableIsZero: Bool {
            switch self {
            case .calc:
                return true
            case .math:
                return false
            case .variable(_, let type, let fallback), .env(_, let type, let fallback):
                let checkable: Set<Int> = [CssType.angle, CssType.flex, CssType.frequency, CssType.length,
                                           CssType.number, CssType.percentage, CssType.semitone, CssType.time,
                                           CssType.volume]
                guard checkable.contains(type), let f = fallback, 1 == f.count else {
                    return false
                }
                return f.values[0].checkableIsZero
            default:
                return isZero
            }
        }

        /// getCheckableValue().isZero() where a feature asks.
        var isZero: Bool {
            switch self {
            case .number(let n, _, _), .percentage(let n), .length(let n, _), .flex(let n), .angle(let n, _),
                 .time(let n, _), .frequency(let n, _), .resolution(let n, _), .semitone(let n), .volume(let n):
                return n.isZero
            case .calc:
                // CssCalc.isZero() is always true (CssCalc.java:244-247)
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Control flow

    /// How a Java throwable leaves a production.
    private enum Interrupt: Error {
        /// A ParseException (InvalidParamException and WarningParamException
        /// are ones too): what media()'s catch records, after skipStatement.
        case parse(Failure)
        /// Any other RuntimeException (NullPointerException, ClassCastException,
        /// NumberFormatException), with its message where the port knows it
        /// (BigDecimal's): discarded by media()'s finally block, but
        /// recorded by declaration()'s catch, which names the property
        /// (Case 554591 review).
        case runtime(String?)
        /// TokenMgrError, which parserUnit, ruleSet and skipStatement catch
        /// (besides media()'s finally): where the token began, and the
        /// character the token manager's automaton died on.
        case tokenMgr(start: Int, kill: Int)
        /// JavaCC's LookaheadSuccess.
        case lookaheadSuccess
        /// The first error with a message has been recorded: it is the
        /// reason, and nothing after it matters (MediaQuery.java:66-94).
        case finished(String)
        /// Nesting beyond depthLimit.
        case tooDeep
    }

    /// A ParseException's message and whether its error type is
    /// "generator.unrecognize" (any ParseException that isn't an
    /// InvalidParamException, CssParseException.getErrorType).
    private struct Failure {
        var message: String?
        var generic: Bool

        /// A JavaCC syntax error: no message (CssParseException.getMessage
        /// is null for one), so MediaQuery says "Parse Error".
        static let syntax = Failure(message: nil, generic: true)

        /// An InvalidParamException from Messages.properties.en's
        /// "error." + key.
        static func invalid(_ message: String?) -> Failure {
            Failure(message: message, generic: false)
        }

        /// new ParseException(message).
        static func plain(_ message: String) -> Failure {
            Failure(message: message, generic: true)
        }
    }

    /// The messages (util/Messages.properties.en), filled in as
    /// InvalidParamException.processError does.
    private enum Message {
        static func value(_ v: String, _ f: String) -> String {
            "“\(v)” is not a “\(f)” value"
        }
        static let unrecognize = "Too many values or values are not recognized"
        static func fewValue(_ f: String) -> String {
            "too few values for the property “\(f)”"
        }
        static let zero = "only “0” can be a “unit”. You must put a unit after your number"
        static let integer = "This number should be an integer."
        static func noModifierMedia(_ f: String) -> String {
            "The media feature “\(f)” does not support prefixes"
        }
        static let noModifierRange = "No prefixes are allowed for range media features"
        static let noModifierShort = "No prefixes are allowed for media features with no value"
        static let grid = "Only “0” and “1” are acceptable values for grid"
        static func deprecatedMedia(_ m: String) -> String {
            "The media “\(m)” has been deprecated"
        }
        static func media(_ m: String) -> String {
            "unrecognized media “\(m)”"
        }
        static func deprecatedFeature(_ f: String) -> String {
            "Deprecated media feature “\(f)”. For guidance, see the Deprecated Media Features section in the current Media Queries specification."
        }
        static func comparator(_ a: String, _ b: String) -> String {
            "The “\(a)” and “\(b)” comparators are not compatible in a media feature of type “range”"
        }
        static func unit(_ u: String) -> String {
            "“\(u)” is an incorrect unit"
        }
        static func strictlyPositive(_ s: String) -> String {
            "“\(s)” is not valid, only values greater than “0” allowed."
        }
        static let invalidNumber = "can't find the error message for invalid-number"
        static let unknownDimension = "Unknown dimension"
        static func semicolon(_ s: String) -> String {
            "Missing a semicolon before the property name “\(s)”"
        }
        static let calcWhitespace = "Whitespace is required on both sides of the “+” or “-” operators"
        static let divZero = "Division by zero"
        static let divisorType = "The divisor must be a number"
        static func typeValueMismatch(_ v: String, _ t: String) -> String {
            "The value “\(v)” is incompatible with its type definition <“\(t)”>"
        }
        static let operandNumber = "One operand must be a number"
        static let incompatibleTypes = "The types are incompatible"
        static func invalidType(_ s: String) -> String {
            "Invalid type: “\(s)”"
        }
        static let parseError = "Parse Error"
        static let invalidColor = "Invalid RGB function"
        /// error.colorfunc ("“%s1” is not a valid %s2 color"); RGBA's
        /// function name is always "rgba", as parseModernRGBA sets it only
        /// when it was given none.
        static func colorFunction(_ s: String, _ f: String) -> String {
            "“\(s)” is not a valid \(f) color"
        }
        static func rgb(_ s: String) -> String {
            "“\(s)” is not a valid color 3 or 6 hexadecimals numbers"
        }
        static func incorrectOperator(_ s: String) -> String {
            "“\(s)” is an incorrect operator"
        }
        static func url(_ s: String) -> String {
            "“\(s)” is an incorrect URL"
        }
        static func onlyATSC(_ s: String) -> String {
            "“\(s)” this function is only for the atsc-tv medium"
        }
        static let charset = "The @charset rule may only occur at the start of the style sheet. Please check that there are no spaces before it."
        static let importNotAllowed = "@import are not allowed after any valid statement other than @charset and @import."
        static func unrecognizedAtRule(_ s: String) -> String {
            "Unrecognized at-rule “\(s)”"
        }
        static let dontMixHTML = "Parse Error. Style sheets should not include HTML syntax."
        static func oldClass(_ name: String, _ escaped: String) -> String {
            "In CSS1, a class name could start with a digit (\".55ft\"), unless it was a dimension (\".55in\"). "
                + "In CSS2, such classes are parsed as unknown dimensions (to allow for future additions of new units) "
                + "To make “\(name)” a valid class, CSS2 requires the first digit to be escaped: “\(escaped)”"
        }
    }

    // MARK: - java.net.URL

    /// The handlers a style sheet's url() can reach (JDK 27 java/net/URL
    /// .java:1329-1352, DefaultFactory, by the protocol's exact lowercased
    /// name; vnu.jar ships no URLStreamHandlerProvider). All but jar: and
    /// mailto: parse with URLStreamHandler.parseURL itself.
    private enum URLHandler {
        case generic
        case jar
        case mailto
    }

    /// Whether new URL(context, spec) succeeds (JDK 27 java/net/URL.java:
    /// 661-769), as CssURL.set builds it (values/CssURL.java:122-127, by
    /// util/HTTPURL.java:148-152): the context is the style sheet's
    /// file://localhost/StyleElement (MediaQuery.java:54 sets it as the
    /// fake URL, StyleSheetParser.parseStyleSheet uses it), or, for the
    /// address inside a jar: URL, none (jar/Handler.java:268-270). The
    /// constructor wraps whatever the handler throws in a
    /// MalformedURLException, and CssURL.set reports any of them as "url".
    /// Case 554591 review: the port once checked only the scheme, so a bad
    /// port, IPv6 literal or host character, and an empty mailto:, slipped
    /// through.
    private static func isJavaURL(_ spec: [UInt16], _ withContext: Bool) -> Bool {
        // controls and spaces around the address don't count; neither does
        // a leading "url:"
        var limit = spec.count
        while limit > 0 && spec[limit - 1] <= 0x20 {
            limit -= 1
        }
        var start = 0
        while start < limit && spec[start] <= 0x20 {
            start += 1
        }
        if regionMatchesIgnoreCase(spec, start, "url:") {
            start += 4
        }
        // the scheme: the text before the first ":", if no "/" comes
        // first, lowercased (Locale.ROOT) and valid as isValidProtocol
        // judges it; a leading "#" makes the whole address a fragment
        let aRef = start < spec.count && 0x23 == spec[start]
        var scheme: [UInt16]?
        if !aRef {
            var i = start
            while i < limit && 0x2F != spec[i] {
                if 0x3A == spec[i] {
                    let candidate = javaLowercase(Array(spec[start..<i]))
                    if isValidProtocol(candidate) {
                        scheme = candidate
                        start = i + 1
                    }
                    break
                }
                i += 1
            }
        }
        // No scheme, or the context's own (equalsIgnoreCase, so "fıle"
        // with a dotless i counts), resolves against the context with its
        // file: handler; otherwise the scheme needs a handler of its own.
        var relative = false
        var handler = URLHandler.generic
        if withContext && (nil == scheme || javaEqualsIgnoreCase(scheme ?? [], "file")) {
            relative = true
        } else {
            // "no protocol" without a context, "unknown protocol" without
            // a handler
            guard let name = scheme else {
                return false
            }
            switch string(name[...]) {
            case "file", "ftp", "http", "https", "jmod", "jrt":
                handler = .generic
            case "jar":
                handler = .jar
            case "mailto":
                handler = .mailto
            default:
                return false
            }
        }
        // the fragment is cut off before the handler parses the rest
        if let hash = spec[start...].firstIndex(of: 0x23), hash < limit {
            limit = hash
        }
        switch handler {
        case .generic:
            return parseHierarchicalURL(spec, start, limit, relative)
        case .jar:
            return parseJarURL(spec, start, limit)
        case .mailto:
            // mailto/Handler.java:36-52: "No email address" when the
            // address is empty or Character.isWhitespace throughout
            // (String.isBlank), as for "mailto:#x" once "#x" is cut
            for c in spec[start..<limit] where !isJavaWhitespace(c) {
                return true
            }
            return false
        }
    }

    /// URLStreamHandler.parseURL (JDK 27 java/net/URLStreamHandler.java:
    /// 151-339), for what can throw: an authority after "//" (unless the
    /// address starts "////") splits at a single "@" into user-info and
    /// host; a host in brackets must be an IPv6 literal followed by nothing
    /// or ":" and a port ("Invalid host", "Invalid authority field"); any
    /// other host's port follows its first ":"; a port is read with
    /// Integer.parseInt and must not be below -1. Then setURL (:534-556)
    /// checks the host, the user-info and the authority under the JDK's
    /// default early URL parsing (IPAddressUtil.checkHostString,
    /// checkUserInfo, checkAuth). An address relative to the context keeps
    /// the context's authority and host, "localhost", unless it has an
    /// authority of its own.
    private static func parseHierarchicalURL(_ spec: [UInt16], _ start: Int, _ limit: Int, _ relative: Bool) -> Bool {
        var start = start
        var limit = limit
        // the query: from the address's first "?" (indexOf('?') over the
        // whole spec, which in practice comes after the scheme)
        if start < limit, let query = spec.firstIndex(of: 0x3F), query < limit {
            limit = query
        }
        var authority: [UInt16]? = relative ? Array("localhost".utf16) : nil
        var userInfo: [UInt16]?
        var host: [UInt16]? = relative ? Array("localhost".utf16) : nil
        let isUNCName = start <= limit - 4 && 0x2F == spec[start] && 0x2F == spec[start + 1]
            && 0x2F == spec[start + 2] && 0x2F == spec[start + 3]
        if !isUNCName && start <= limit - 2 && 0x2F == spec[start] && 0x2F == spec[start + 1] {
            start += 2
            let end = spec[start..<limit].firstIndex(of: 0x2F) ?? limit
            let field = Array(spec[start..<end])
            authority = field
            userInfo = nil
            host = field
            if let at = field.firstIndex(of: 0x40) {
                if at != field.lastIndex(of: 0x40) {
                    // more than one "@": not server-based, no host or port
                    host = nil
                } else {
                    userInfo = Array(field[..<at])
                    host = Array(field[(at + 1)...])
                }
            }
            if let name = host {
                if let first = name.first, 0x5B == first {
                    // RFC 2732: "[" IPv6 literal "]", then ":" port or
                    // nothing; indexOf(']') must be past index 2
                    guard let close = name.firstIndex(of: 0x5D), close > 2 else {
                        return false
                    }
                    guard isIPv6LiteralAddress(Array(name[1..<close])) else {
                        return false
                    }
                    host = Array(name[...close])
                    if name.count > close + 1 {
                        guard 0x3A == name[close + 1] else {
                            return false
                        }
                        if name.count > close + 2 {
                            guard let port = javaParseInt(Array(name[(close + 2)...])), port >= -1 else {
                                return false
                            }
                        }
                    }
                } else if let colon = name.firstIndex(of: 0x3A) {
                    // "port can be null according to RFC2396": a bare ":"
                    // is fine
                    if name.count > colon + 1 {
                        guard let port = javaParseInt(Array(name[(colon + 1)...])), port >= -1 else {
                            return false
                        }
                    }
                    host = Array(name[..<colon])
                }
            } else {
                host = []
            }
        }
        // setURL's checks; the path itself is never rejected
        if let name = host, !isAllowedHost(name) {
            return false
        }
        if let info = userInfo, nil != scanMask(info, userInfoMask, nil) {
            return false
        }
        if let field = authority, nil != scanMask(field, authorityMask, nil) {
            return false
        }
        return true
    }

    /// jar/Handler.java:135-193 (parseURL, checkNestedProtocol,
    /// parseAbsoluteSpec): the address after "jar:" mustn't start with
    /// "jar:" again, needs a "!/" (the last one counts), and what comes
    /// before that "!" must itself be a URL, made without a context. The
    /// handler decides "absolute" from the spec's first four characters,
    /// so after a leading "url:" the jar: URL is relative, and
    /// parseContextSpec reads the new URL's still-null file: a
    /// NullPointerException, unless the address is a bare fragment
    /// ("url:jar:#x"), which skips that. Every NPE becomes "url".
    private static func parseJarURL(_ spec: [UInt16], _ start: Int, _ limit: Int) -> Bool {
        let refOnly = start == limit && limit < spec.count && 0x23 == spec[limit]
        let absoluteSpec = regionMatchesIgnoreCase(spec, 0, "jar:")
        let body = Array(spec[start..<limit])
        if regionMatchesIgnoreCase(body, 0, "jar:") {
            // "Nested JAR URLs are not supported"
            return false
        }
        guard absoluteSpec else {
            return refOnly
        }
        // indexOfBangSlash: the last "!" followed by "/"
        var bang = body.count - 2
        while bang >= 0 && !(0x21 == body[bang] && 0x2F == body[bang + 1]) {
            bang -= 1
        }
        guard bang >= 0 else {
            // "no !/ in spec"
            return false
        }
        // the inner URL can't hold a "#" (the outer one cut it off), so an
        // inner jar: URL is never a bare fragment, and it fails in turn
        return isJavaURL(Array(body[..<bang]), false)
    }

    /// String.regionMatches(true, offset, literal, 0, literal.length):
    /// false when the region runs past the end; otherwise unit by unit,
    /// ignoring case as String.equalsIgnoreCase does.
    private static func regionMatchesIgnoreCase(_ units: [UInt16], _ offset: Int, _ literal: String) -> Bool {
        let other = Array(literal.utf16)
        guard offset >= 0, offset + other.count <= units.count else {
            return false
        }
        return javaEqualsIgnoreCase(Array(units[offset..<(offset + other.count)]), literal)
    }

    /// URL.isValidProtocol (java/net/URL.java:874-889): a letter, then
    /// letters, digits, "." "+" or "-", as Character.isLetter and
    /// isLetterOrDigit judge single UTF-16 units: any Unicode letter or
    /// decimal digit, so "é:x" names a scheme, which no handler serves.
    private static func isValidProtocol(_ s: [UInt16]) -> Bool {
        guard let first = s.first, isJavaLetter(first) else {
            return false
        }
        for c in s.dropFirst() where !(isJavaLetter(c) || isJavaDigit(c) || 0x2E == c || 0x2B == c || 0x2D == c) {
            return false
        }
        return true
    }

    /// Character.isLetter(char): general categories Lu, Ll, Lt, Lm and Lo;
    /// a surrogate (Cs) is none.
    private static func isJavaLetter(_ c: UInt16) -> Bool {
        if c < 0x80 {
            return isASCIILetter(c)
        }
        guard let scalar = Unicode.Scalar(UInt32(c)) else {
            return false
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// Character.isDigit(char): general category Nd.
    private static func isJavaDigit(_ c: UInt16) -> Bool {
        if c < 0x80 {
            return isDigit(c)
        }
        guard let scalar = Unicode.Scalar(UInt32(c)) else {
            return false
        }
        return .decimalNumber == scalar.properties.generalCategory
    }

    /// Character.isWhitespace(char): the space, line and paragraph
    /// separators but the no-break spaces U+00A0, U+2007 and U+202F, and
    /// U+0009-U+000D and U+001C-U+001F. (No separator lies outside the
    /// BMP, so a surrogate unit is never whitespace.)
    private static func isJavaWhitespace(_ c: UInt16) -> Bool {
        if (c >= 0x09 && c <= 0x0D) || (c >= 0x1C && c <= 0x1F) {
            return true
        }
        if 0xA0 == c || 0x2007 == c || 0x202F == c {
            return false
        }
        guard let scalar = Unicode.Scalar(UInt32(c)) else {
            return false
        }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// Integer.parseInt(CharSequence, begin, end, 10) for a port: an
    /// optional "+" or "-" (not alone), then at least one decimal digit as
    /// Character.digit(char, 10) reads it, any Unicode Nd digit of the BMP
    /// included, within Int32's range; nil where it throws
    /// NumberFormatException.
    private static func javaParseInt(_ units: [UInt16]) -> Int64? {
        guard let first = units.first else {
            return nil
        }
        var i = 0
        var negative = false
        if first < 0x30 {
            if 0x2D == first {
                negative = true
            } else if 0x2B != first {
                return nil
            }
            i = 1
            if i == units.count {
                return nil
            }
        }
        let bound: Int64 = negative ? 2_147_483_648 : 2_147_483_647
        var result: Int64 = 0
        while i < units.count {
            guard let digit = javaDecimalDigit(units[i]) else {
                return nil
            }
            result = result * 10 + digit
            // stop at the first digit past the range, as parseInt does, so
            // a long run of digits never overflows here
            if result > bound {
                return nil
            }
            i += 1
        }
        return negative ? -result : result
    }

    /// Character.digit(char, 10): an ASCII digit, or any other decimal
    /// digit (Nd) of the BMP.
    private static func javaDecimalDigit(_ c: UInt16) -> Int64? {
        if isDigit(c) {
            return Int64(c - 0x30)
        }
        guard c >= 0x80, let scalar = Unicode.Scalar(UInt32(c)), .decimal == scalar.properties.numericType,
              let value = scalar.properties.numericValue, value >= 0 && value <= 9 else {
            return nil
        }
        return Int64(value)
    }

    /// IPAddressUtil's ASCII-only hex digit (parseAsciiHexDigit, as
    /// IPAddressUtil.digit reads digits unless
    /// jdk.net.allowAmbiguousIPAddressLiterals is set).
    private static func asciiHexValue(_ c: UInt16) -> Int {
        if isDigit(c) {
            return Int(c - 0x30)
        }
        if c >= 0x61 && c <= 0x66 {
            return Int(c - 0x61) + 10
        }
        if c >= 0x41 && c <= 0x46 {
            return Int(c - 0x41) + 10
        }
        return -1
    }

    /// IPAddressUtil.textToNumericFormatV6 (sun/net/util/IPAddressUtil
    /// .java:180-291) as a yes or no: at least two characters; a "%" scope
    /// must not end the text, and is not parsed here; eight groups of up
    /// to four hex digits (none above 0xFFFF), or fewer with one "::", and
    /// possibly a dotted IPv4 tail.
    private static func isIPv6LiteralAddress(_ src: [UInt16]) -> Bool {
        if src.count < 2 {
            return false
        }
        var length = src.count
        if let percent = src.firstIndex(of: 0x25) {
            if src.count - 1 == percent {
                return false
            }
            length = percent
        }
        var colonp = -1
        var i = 0
        var j = 0
        // a leading "::" needs both colons
        if 0x3A == src[i] {
            i += 1
            if 0x3A != src[i] {
                return false
            }
        }
        var curtok = i
        var sawXDigit = false
        var value = 0
        while i < length {
            let ch = src[i]
            i += 1
            let digit = asciiHexValue(ch)
            if -1 != digit {
                value = (value << 4) | digit
                if value > 0xFFFF {
                    return false
                }
                sawXDigit = true
                continue
            }
            if 0x3A == ch {
                curtok = i
                if !sawXDigit {
                    if -1 != colonp {
                        return false
                    }
                    colonp = j
                    continue
                } else if i == length {
                    return false
                }
                if j + 2 > 16 {
                    return false
                }
                j += 2
                sawXDigit = false
                value = 0
                continue
            }
            if 0x2E == ch && j + 4 <= 16 {
                // a dotted IPv4 tail: exactly three dots, then
                // textToNumericFormatV4
                let tail = Array(src[curtok..<length])
                guard 3 == tail.filter({ 0x2E == $0 }).count, isIPv4LiteralAddress(tail) else {
                    return false
                }
                j += 4
                sawXDigit = false
                break
            }
            return false
        }
        if sawXDigit {
            if j + 2 > 16 {
                return false
            }
            j += 2
        }
        if -1 != colonp {
            if 16 == j {
                return false
            }
            j = 16
        }
        return 16 == j
    }

    /// IPAddressUtil.textToNumericFormatV4 (:56-140) as a yes or no: up to
    /// 15 characters of ASCII digits and dots, no empty part, each part
    /// before the last at most 255, and the last within the bytes left.
    private static func isIPv4LiteralAddress(_ src: [UInt16]) -> Bool {
        if src.isEmpty || src.count > 15 {
            return false
        }
        var part: Int64 = 0
        var currByte = 0
        var newOctet = true
        for c in src {
            if 0x2E == c {
                if newOctet || part > 0xFF || 3 == currByte {
                    return false
                }
                currByte += 1
                part = 0
                newOctet = true
            } else {
                guard isDigit(c) else {
                    return false
                }
                part = part * 10 + Int64(c - 0x30)
                newOctet = false
            }
        }
        return !newOctet && part < (Int64(1) << ((4 - currByte) * 8))
    }

    /// A pair of IPAddressUtil masks: bit n of `low` marks character n
    /// below 64, bit n of `high` character 64 + n below 128; nothing past
    /// ASCII (IPAddressUtil.match, :462-468).
    private struct CharacterMask {
        let low: UInt64
        let high: UInt64
    }

    /// IPAddressUtil's masks (:423-455), as the JDK's default early URL
    /// parsing combines them (MASKS, :929-955).
    /// checkUserInfo: L_EXCLUDE & ~L_COLON, H_EXCLUDE & ~H_COLON.
    private static let userInfoMask = CharacterMask(low: 0x8400_8008_FFFF_FFFF & ~0x0400_0000_0000_0000,
                                                    high: 0x8000_0000_3800_0001)
    /// checkAuth: L_EXCLUDE & ~L_AUTH_DELIMS, H_EXCLUDE & ~H_AUTH_DELIMS.
    private static let authorityMask = CharacterMask(low: 0x8400_8008_FFFF_FFFF & ~0x0400_0000_0000_0000,
                                                     high: 0x8000_0000_3800_0001 & ~0x2800_0001)
    /// checkHost: L_EXCLUDE | L_NON_PRINTABLE | L_SLASH | L_UNWISE |
    /// L_EXCLUDED_DELIMS, and the same for H_.
    private static let hostMask = CharacterMask(low: 0x8400_8008_FFFF_FFFF | 0xFFFF_FFFF | 0x8000_0000_0000 | 0x5000_0005_0000_0000,
                                                high: 0x8000_0000_3800_0001 | 0x8000_0000_0000_0000 | 0x3800_0001_7800_0000)
    /// checkHost's scope: L_NON_PRINTABLE | L_IPV6_DELIMS | L_SLASH |
    /// L_BACKSLASH | L_FRAGMENT | L_QUERY, and the same for H_.
    private static let scopeMask = CharacterMask(low: 0xFFFF_FFFF | 0x8000_0000_0000 | 0x0000_0008_0000_0000 | 0x8000_0000_0000_0000,
                                                 high: 0x8000_0000_0000_0000 | 0x2800_0000 | 0x1000_0000)
    /// IPAddressUtil.OTHERS (:457-460): look-alikes of the delimiters
    /// (⁇ ⁈ ⁉ ℀ ℁ ℅ ℆ ⩴ ﹕ ﹖ ﹟ ﹫ ＃ ／ ： ？ ＠), which a host mustn't hold.
    private static let hostLookAlikes: Set<UInt16> = [8263, 8264, 8265, 8448, 8449, 8453, 8454, 10868,
                                                      65109, 65110, 65119, 65131, 65283, 65295, 65306, 65311, 65312]

    /// IPAddressUtil.scan (:470-496): the first character the mask (or the
    /// look-alikes) marks, if any.
    private static func scanMask(_ s: [UInt16], _ mask: CharacterMask, _ others: Set<UInt16>?) -> Int? {
        for (index, c) in s.enumerated() {
            if c < 64 {
                if 0 != (mask.low & (UInt64(1) << UInt64(c))) {
                    return index
                }
            } else if c < 128 {
                if 0 != (mask.high & (UInt64(1) << UInt64(c - 64))) {
                    return index
                }
            } else if let set = others, set.contains(c) {
                return index
            }
        }
        return nil
    }

    /// IPAddressUtil.checkHost (:523-549) under early parsing: a bracketed
    /// host must be an IPv6 literal whose scope (from its "%") holds no
    /// control, "#", "/", "?", "[", "\", "]" or DEL; any other host no
    /// control, space, DEL or one of " # / : < > ? @ [ \ ] ^ ` { | }, nor a
    /// look-alike of one.
    private static func isAllowedHost(_ host: [UInt16]) -> Bool {
        if let first = host.first, let last = host.last, 0x5B == first && 0x5D == last && host.count >= 2 {
            let literal = Array(host[1..<(host.count - 1)])
            guard isIPv6LiteralAddress(literal) else {
                // "Unrecognized IPv6 address format"
                return false
            }
            if let percent = literal.firstIndex(of: 0x25) {
                return nil == scanMask(Array(literal[percent...]), scopeMask, nil)
            }
            return true
        }
        return nil == scanMask(host, hostMask, hostLookAlikes)
    }

    // MARK: - The parser

    /// CssParser, as JavaCC generated it from CssParser.jj, for what a media
    /// attribute can reach: the token chain, getToken, jj_ntk and
    /// jj_consume_token; the lookahead scans (jj_2_*/jj_3_*), which try each
    /// alternative in order and succeed once the k-th token has matched;
    /// and the productions, which peek and consume tokens in the same order
    /// as the generated code, since when a bad character's TokenMgrError
    /// strikes decides which errors were recorded before it.
    private final class Parser {
        var skippingAtRule = false
        let text: [UInt16]
        let lexer: Lexer
        /// The token chain; index 0 is the token JavaCC starts with.
        var tokens = [Token(kind: -1, start: 0, end: 0)]
        /// `token`: the last token consumed.
        var current = 0
        /// Where the token manager reads next.
        var position = 0
        /// The scan position and limit of the lookahead being evaluated.
        var scanPosition = 0
        var scanLimit = 0
        var depth = 0

        init(text: [UInt16]) {
            self.text = text
            lexer = Lexer(t: text)
        }

        func run() -> Outcome {
            do {
                try parserUnit()
                return .valid
            } catch Interrupt.finished(let message) {
                return .error(message)
            } catch Interrupt.runtime(let message) {
                // A RuntimeException out of parserUnit: parseStyle wraps it
                // in a RuntimeException of its message, which
                // StyleSheetParser.parseStyleElement records (StyleSheetParser
                // .java:363-367), dropping the errors before it (none had a
                // message, or the parse would have finished); a null message
                // is skipped (Case 554591 review).
                if let m = message, !m.isEmpty {
                    return .error(m + ".")
                }
                return .valid
            } catch {
                // Nesting beyond depthLimit, or what can't happen: nothing
                // the port can't parse is called bad.
                return .valid
            }
        }

        // MARK: Recording errors

        /// The values the features of the @media rule being parsed keep,
        /// for media()'s getAtRule().toString().
        var featureValues = [Value]()

        /// The property of the declaration being parsed (CssParser
        /// .currentProperty, CssParser.jj:2265-2460): the errors addError
        /// records meanwhile name it.
        var currentProperty: String?

        /// addError for a ParseException (CssParser.jj:477-510): a
        /// CssParseException, which MediaQuery.checkValid (MediaQuery.java:
        /// 72-87) reports as its message with "." added, a generic one
        /// without a message as "Parse Error.", after “property”: when a
        /// declaration is being parsed; an empty message, or none on an
        /// InvalidParamException, is skipped.
        func record(_ failure: Failure) throws {
            var text: String
            if let message = failure.message {
                text = message
            } else if failure.generic {
                text = Message.parseError
            } else {
                return
            }
            if text.isEmpty {
                return
            }
            if let property = currentProperty {
                text = "“\(property)”: " + text
            }
            throw Interrupt.finished(text + ".")
        }

        /// ac.getFrame().addError(new CssError(InvalidParamException)): a
        /// plain error, reported as its message is, even a null one (as an
        /// empty reason).
        func recordPlain(_ message: String?) throws {
            if let m = message, m.isEmpty {
                return
            }
            throw Interrupt.finished(message ?? "")
        }

        // MARK: Tokens

        func image(_ token: Token) -> ArraySlice<UInt16> {
            text[token.start..<token.end]
        }

        func imageString(_ token: Token) -> String {
            HTMLMediaQueryDatatype.string(image(token))
        }

        /// The token manager's getNextToken: special tokens skipped, a
        /// TokenMgrError for a character nothing starts with.
        func fetch() throws {
            while true {
                switch lexer.lex(position) {
                case .eof:
                    tokens.append(Token(kind: T.eof, start: text.count, end: text.count))
                    return
                case .comment(let end):
                    position = end
                case .token(let kind, let end):
                    tokens.append(Token(kind: kind, start: position, end: end))
                    position = end
                    return
                case .failure(let resume):
                    let start = position
                    position = resume
                    throw Interrupt.tokenMgr(start: start, kill: resume)
                }
            }
        }

        /// The token at an index of the chain, fetching as needed.
        func token(at index: Int) throws -> Token {
            while tokens.count <= index {
                try fetch()
            }
            return tokens[index]
        }

        /// jj_ntk: the next token's kind.
        func next() throws -> Int {
            try token(at: current + 1).kind
        }

        /// getToken(i).
        func peek(_ i: Int) throws -> Token {
            try token(at: current + i)
        }

        /// jj_consume_token: a syntax error, with nothing consumed, when the
        /// next token isn't of the kind.
        @discardableResult
        func consume(_ kind: Int) throws -> Token {
            let t = try token(at: current + 1)
            guard t.kind == kind else {
                throw Interrupt.parse(.syntax)
            }
            current += 1
            return t
        }

        /// getNextToken.
        @discardableResult
        func advance() throws -> Token {
            let t = try token(at: current + 1)
            current += 1
            return t
        }

        func skipSpaces() throws {
            while T.s == (try next()) {
                try consume(T.s)
            }
        }

        // MARK: Lookahead

        /// jj_2_*: scan from the current token, succeeding as soon as the
        /// k-th token has matched (jj_scan_token throws LookaheadSuccess),
        /// or when the expansion matched with fewer tokens.
        func lookahead(_ k: Int, _ scan: () throws -> Bool) throws -> Bool {
            let savedPosition = scanPosition
            let savedLimit = scanLimit
            defer {
                scanPosition = savedPosition
                scanLimit = savedLimit
            }
            scanPosition = current
            scanLimit = current + k
            do {
                return try scan()
            } catch Interrupt.lookaheadSuccess {
                return true
            }
        }

        /// jj_scan_token: whether the next scanned token is of the kind.
        func scan(_ kind: Int) throws -> Bool {
            scanPosition += 1
            let t = try token(at: scanPosition)
            guard t.kind == kind else {
                return false
            }
            if scanPosition == scanLimit {
                throw Interrupt.lookaheadSuccess
            }
            return true
        }

        /// One of several kinds, tried in order.
        func scan(any kinds: [Int]) throws -> Bool {
            let saved = scanPosition
            for kind in kinds {
                scanPosition = saved
                if try scan(kind) {
                    return true
                }
            }
            scanPosition = saved
            return false
        }

        /// ( <S> )*.
        func scanSpaces() throws {
            while true {
                let saved = scanPosition
                if !(try scan(T.s)) {
                    scanPosition = saved
                    return
                }
            }
        }

        /// An optional part.
        func scanOptional(_ part: () throws -> Bool) throws {
            let saved = scanPosition
            if !(try part()) {
                scanPosition = saved
            }
        }

        /// Alternatives, the first that matches winning.
        func scanFirst(_ alternatives: [() throws -> Bool]) throws -> Bool {
            let saved = scanPosition
            for alternative in alternatives {
                scanPosition = saved
                if try alternative() {
                    return true
                }
            }
            scanPosition = saved
            return false
        }

        /// A level of nesting, weighted by the stack its productions take:
        /// measured on a 512 KiB thread, a parenthesized condition takes
        /// about 350 bytes a level, a calc() parenthesis 900, a function
        /// 1,000 and a min() 1,100, so that at depthLimit no shape uses
        /// more than about 190 KiB.
        func enter(_ weight: Int) throws {
            depth += weight
            if depth > HTMLMediaQueryDatatype.depthLimit {
                throw Interrupt.tooDeep
            }
        }

        func leave(_ weight: Int) {
            depth -= weight
        }

        // MARK: Style sheet level

        /// parserUnit (CssParser.jj:851-872): the text begins "@media ", so
        /// the HTML-tag, charset, import and namespace loops never run; a
        /// TokenMgrError anywhere is recorded as "Parse Error".
        func parserUnit() throws {
            do {
                while true {
                    let k = try next()
                    guard T.htmlStartTag == k || T.htmlEndTag == k else {
                        break
                    }
                    try advance()
                    try record(.plain(Message.dontMixHTML))
                }
                try afterImportDeclaration()
                try consume(T.eof)
            } catch Interrupt.tokenMgr {
                try record(.plain(Message.parseError))
            }
        }

        static let ruleSetStarts: Set<Int> = [
            T.and, T.or, T.only, T.not, T.ident, T.hashIdent, T.hash, T.lbracket, T.any, T.dot, T.colon,
            T.relFontLength, T.relViewLength, T.absolutLength, T.angle, T.time, T.freq, T.resolution, T.dimen,
            T.pseudoElement, T.pipe
        ]

        static let atRuleStarts: Set<Int> = [
            T.pageSym, T.fontFaceSym, T.fontFeatureValuesSym, T.fontPaletteValuesSym, T.mediaSym, T.keyframesSym,
            T.prefSym, T.colorProfile, T.counterStyleSym, T.layerSym, T.phoneticAlphabetSym, T.supportsSym,
            T.viewportSym, T.atKeyword
        ]

        /// afterImportDeclaration (CssParser.jj:923-960).
        func afterImportDeclaration() throws {
            while true {
                let k = try next()
                let before = current
                if Parser.ruleSetStarts.contains(k) {
                    try ruleSet()
                    if before == current {
                        // can't happen (a rule consumes its first token),
                        // but never loop on it
                        return
                    }
                } else if Parser.atRuleStarts.contains(k) {
                    try nestedAtRules()
                    if before == current {
                        return
                    }
                } else {
                    guard let ret = try skipStatement(), !ret.isEmpty else {
                        return
                    }
                    if ret.hasPrefix("@charset") {
                        try record(.plain(Message.charset))
                    } else if ret.hasPrefix("@import") {
                        try record(.plain(Message.importNotAllowed))
                    } else if !ret.hasPrefix("/*") {
                        try record(.plain(Message.parseError))
                    } else {
                        // an unterminated comment: read to the end
                        while T.eof != (try peek(0)).kind {
                            try advance()
                        }
                    }
                }
                try ignoreStatement()
            }
        }

        /// ignoreStatement (CssParser.jj:962-966).
        func ignoreStatement() throws {
            while true {
                let k = try next()
                guard T.cdo == k || T.cdc == k else {
                    return
                }
                try advance()
                try skipSpaces()
            }
        }

        /// skipStatement (CssParser.jj:4137-4196): the last token's image
        /// and every token up to a block, a "}" or a ";" (a TokenMgrError
        /// costs one character), or to the end after an unclosed comment;
        /// nil when the text had already ended.
        func skipStatement() throws -> String? {
            var s = [UInt16]()
            let first0 = tokens[current]
            if first0.kind >= 0 {
                s.append(contentsOf: image(first0))
            }
            var first = true
            var tok = first0
            loop: while true {
                do {
                    tok = try peek(1)
                    if T.eof == tok.kind {
                        if first {
                            return nil
                        }
                        break loop
                    }
                    if T.lbrace == tok.kind {
                        s.append(contentsOf: image(tok))
                        try advance()
                        s.append(contentsOf: try skipToMatchingBrace())
                        try advance()
                        tok = try peek(1)
                        break loop
                    } else if T.rbrace == tok.kind || T.semicolon == tok.kind {
                        s.append(contentsOf: image(tok))
                        try advance()
                        tok = try peek(1)
                        break loop
                    } else if T.sco == tok.kind {
                        repeat {
                            tok = try advance()
                        } while T.eof != tok.kind
                        break loop
                    } else {
                        s.append(contentsOf: image(tok))
                    }
                    try advance()
                } catch Interrupt.tokenMgr(let start, let kill) {
                    if skippingAtRule {
                        throw Interrupt.tokenMgr(start: start, kill: kill)
                    }
                    // jj_input_stream.readChar(): the character the token
                    // manager stopped at
                    guard position < text.count else {
                        return trimmed(s)
                    }
                    s.append(text[position])
                    position += 1
                    continue loop
                }
                first = false
            }
            while T.s == tok.kind {
                try advance()
                tok = try peek(1)
            }
            return trimmed(s)
        }

        /// String.trim(): code units up to U+0020 off both ends.
        func trimmed(_ s: [UInt16]) -> String {
            var a = 0
            var b = s.count
            while a < b && s[a] <= 0x20 {
                a += 1
            }
            while b > a && s[b - 1] <= 0x20 {
                b -= 1
            }
            return HTMLMediaQueryDatatype.string(s[a..<b])
        }

        /// skip_to_matching_brace (CssParser.jj:4198-4231).
        func skipToMatchingBrace() throws -> [UInt16] {
            var s = [UInt16]()
            var nesting = 1
            while true {
                let tok = try peek(1)
                if T.eof == tok.kind {
                    break
                }
                if T.lbrace == tok.kind {
                    nesting += 1
                } else if T.rbrace == tok.kind {
                    nesting -= 1
                    if 0 == nesting {
                        s.append(contentsOf: image(tok))
                        break
                    }
                }
                s.append(contentsOf: image(tok))
                try advance()
            }
            return s
        }

        /// nested_at_rules (CssParser.jj:951-956), for what can follow a
        /// value that closed its @media rule early.
        func nestedAtRules() throws {
            let k = try next()
            if T.mediaSym == k {
                try media()
            } else if T.atKeyword == k {
                try atRuleDeclaration()
            } else if T.viewportSym == k {
                try viewport()
            } else {
                try otherAtRule()
            }
        }

        // MARK: @media

        /// media() (CssParser.jj:1115-1170). A ParseException is recorded
        /// after skipStatement; anything else is discarded by the finally
        /// block's `return newRule`, and parsing goes on from wherever it
        /// stopped, at the style sheet level.
        func media() throws {
            // Case 554591 review: media() → blockContents() → nestedAtRules()
            // → media() is a recursion of its own, as deep as the value
            // nests "@media" blocks ("all{@media all{@media …"), about 224
            // bytes of stack a level; counted against depthLimit like every
            // other nesting, so a deeply nested value is given up on as
            // valid instead of overflowing a 512 KiB stack. (Upstream's own
            // StackOverflowError would be swallowed by this production's
            // finally block too.) The count is outside the do/catch, so
            // Interrupt.tooDeep reaches run().
            try enter(1)
            defer {
                leave(1)
            }
            // each @media rule has its own features (newRule)
            let outerFeatureValues = featureValues
            featureValues = []
            defer {
                featureValues = outerFeatureValues
            }
            do {
                try consume(T.mediaSym)
                try skipSpaces()
                let k = try next()
                if T.only == k || T.not == k || T.ident == k || T.lparen == k {
                    try mediaQueryList()
                    // `String media = getAtRule().toString();` prints every
                    // feature's values: a number Java can't print, or a
                    // rule too long for a Java string, throws here, into
                    // the finally
                    var total: Int64 = 0
                    for v in featureValues {
                        if v.textThrows {
                            throw Interrupt.runtime(nil)
                        }
                        total = min(Int64.max / 2, total + min(Int64.max / 4, v.textLength) + 2)
                    }
                    // and "@media (width: " and the like around them
                    if total + 16 > Int64(Int32.max) - 2 {
                        throw Interrupt.runtime(nil)
                    }
                }
                try consume(T.lbrace)
                try skipSpaces()
                try blockContents()
                try consume(T.rbrace)
                try skipSpaces()
            } catch Interrupt.parse(let failure) {
                do {
                    _ = try skipStatement()
                } catch Interrupt.tokenMgr {
                    // thrown from skipStatement's last loop, outside its
                    // catch: out of media(), into the finally
                    return
                } catch Interrupt.runtime {
                    return
                }
                try record(failure)
            } catch Interrupt.runtime {
                // finally { return newRule; }
            } catch Interrupt.tokenMgr {
                // finally { return newRule; }
            }
        }

        /// ( ruleSet() | nested_at_rules() )* inside a block.
        func blockContents() throws {
            while true {
                let k = try next()
                let before = current
                if Parser.ruleSetStarts.contains(k) {
                    try ruleSet()
                } else if Parser.atRuleStarts.contains(k) {
                    try nestedAtRules()
                } else {
                    return
                }
                if before == current {
                    // never loop on a rule that consumed nothing
                    return
                }
            }
        }

        /// mediaquerylist (CssParser.jj:1186-1192).
        func mediaQueryList() throws {
            try mediaQuery()
            while T.comma == (try next()) {
                try consume(T.comma)
                try skipSpaces()
                try mediaQuery()
            }
        }

        /// mediaquery (CssParser.jj:1194-1202).
        func mediaQuery() throws {
            if try lookahead(3, { try self.scanMediaCondition() }) {
                try mediaCondition(defaultMedia: true)
                return
            }
            let k = try next()
            guard T.only == k || T.not == k || T.ident == k else {
                throw Interrupt.parse(.syntax)
            }
            if T.only == k || T.not == k {
                try advance()
                try skipSpaces()
            }
            let n = try consume(T.ident)
            try addMedia(convertIdent(Array(image(n))))
            try skipSpaces()
            if T.and == (try next()) {
                try consume(T.and)
                try skipSpaces()
                try mediaConditionWithoutOr(defaultMedia: false)
            }
        }

        /// AtRuleMedia.addMedia (atrules/css3/AtRuleMedia.java:36-74): the
        /// type lowercased with Java's toLowerCase.
        func addMedia(_ name: [UInt16]) throws {
            let medium = HTMLMediaQueryDatatype.string(javaLowercase(name)[...])
            if "all" == medium || "print" == medium || "screen" == medium {
                return
            }
            let deprecated = ["aural", "braille", "embossed", "handheld", "projection", "speech", "tty", "tv"]
            if deprecated.contains(medium) {
                try recordPlain(Message.deprecatedMedia(medium))
                return
            }
            throw Interrupt.parse(.invalid(Message.media(medium)))
        }

        /// mediacondition (CssParser.jj:1204-1212).
        func mediaCondition(defaultMedia: Bool) throws {
            let k = try next()
            if T.not == k {
                try consume(T.not)
                try skipSpaces()
                try mediaInParens(defaultMedia: defaultMedia)
                return
            }
            guard T.lparen == k else {
                throw Interrupt.parse(.syntax)
            }
            try mediaInParens(defaultMedia: defaultMedia)
            let k2 = try next()
            if T.and == k2 || T.or == k2 {
                repeat {
                    try consume(k2)
                    try skipSpaces()
                    try mediaInParens(defaultMedia: false)
                } while k2 == (try next())
            }
        }

        /// mediaconditionwithoutor (CssParser.jj:1214-1222).
        func mediaConditionWithoutOr(defaultMedia: Bool) throws {
            let k = try next()
            if T.not == k {
                try consume(T.not)
                try skipSpaces()
                try mediaInParens(defaultMedia: defaultMedia)
                return
            }
            guard T.lparen == k else {
                throw Interrupt.parse(.syntax)
            }
            try mediaInParens(defaultMedia: defaultMedia)
            while T.and == (try next()) {
                try consume(T.and)
                try skipSpaces()
                try mediaInParens(defaultMedia: defaultMedia)
            }
        }

        /// mediainparens (CssParser.jj:1224-1232).
        func mediaInParens(defaultMedia: Bool) throws {
            try enter(1)
            defer {
                leave(1)
            }
            if try lookahead(4, { try self.scanParenthesizedCondition() }) {
                try consume(T.lparen)
                try skipSpaces()
                try mediaCondition(defaultMedia: defaultMedia)
                try consume(T.rparen)
                try skipSpaces()
            } else if try lookahead(5, { try self.scanMediaRange() }) {
                try mediaRange(defaultMedia: defaultMedia)
            } else {
                guard T.lparen == (try next()) else {
                    throw Interrupt.parse(.syntax)
                }
                try mediaExpression(defaultMedia: defaultMedia)
            }
        }

        /// mediaexpression (CssParser.jj:1234-1259).
        func mediaExpression(defaultMedia: Bool) throws {
            try consume(T.lparen)
            try skipSpaces()
            let n = try consume(T.ident)
            let name = convertIdent(Array(image(n)))
            try skipSpaces()
            var value: Expression?
            if T.colon == (try next()) {
                try consume(T.colon)
                try skipSpaces()
                value = try mediaExpr()
            }
            try consume(T.rparen)
            try skipSpaces()
            _ = try handleMediaFeature(name, value)
        }

        static let comparators: [Int] = [T.greater, T.greaterEq, T.eq, T.less, T.lessEq]

        /// mediarange (CssParser.jj:3354-3399).
        func mediaRange(defaultMedia: Bool) throws {
            try consume(T.lparen)
            try skipSpaces()
            let n: Token
            var c1: Token
            var c2: Token?
            var val1: Expression
            var val2: Expression?
            if try lookahead(3, { try self.scanNameFirstRange() }) {
                n = try identToken()
                try skipSpaces()
                c1 = try comparatorToken()
                try skipSpaces()
                val1 = try mediaExpr()
            } else {
                val1 = try mediaExpr()
                c1 = try comparatorToken()
                try skipSpaces()
                n = try identToken()
                try skipSpaces()
                if Parser.comparators.contains(try next()) {
                    c2 = try advance()
                    try skipSpaces()
                    val2 = try mediaExpr()
                }
            }
            try consume(T.rparen)
            try skipSpaces()
            // the action
            let name = T.ident == n.kind ? convertIdent(Array(image(n))) : Array(image(n))
            let expression = Expression()
            expression.add(try comparator(c1, val1))
            if let c = c2, let v = val2 {
                expression.add(try comparator(c, v))
            }
            let feature = try handleMediaFeature(name, expression)
            // ((MediaRangeFeature) mf).comparatorNameFirst = …: a null
            // feature, or one that isn't a range feature, throws
            if case .range = feature {
                return
            }
            throw Interrupt.runtime(nil)
        }

        /// CssComparator.set (values/CssComparator.java:79-88): the image
        /// trimmed must be a comparator; " /**/>=" isn't.
        func comparator(_ c: Token, _ value: Expression) throws -> Value {
            let symbol = trimmed(Array(image(c)))
            guard [">=", "<=", ">", "<", "="].contains(symbol) else {
                throw Interrupt.parse(.invalid("“\(imageString(c))” is not a “” value"))
            }
            return .comparator(symbol, value)
        }

        func comparatorToken() throws -> Token {
            guard Parser.comparators.contains(try next()) else {
                throw Interrupt.parse(.syntax)
            }
            return try advance()
        }

        /// ident() (CssParser.jj:876-882): IDENT and the keywords.
        func identToken() throws -> Token {
            let k = try next()
            guard T.ident == k || T.and == k || T.or == k || T.not == k || T.only == k else {
                throw Interrupt.parse(.syntax)
            }
            return try advance()
        }

        // MARK: Lookahead scans

        /// jj_3R_mediacondition: NOT S* in-parens | in-parens ( (AND S*
        /// in-parens)+ | (OR S* in-parens)+ )?.
        func scanMediaCondition() throws -> Bool {
            try scanFirst([
                {
                    guard try self.scan(T.not) else {
                        return false
                    }
                    try self.scanSpaces()
                    return try self.scanMediaInParens()
                },
                {
                    guard try self.scanMediaInParens() else {
                        return false
                    }
                    for keyword in [T.and, T.or] {
                        let saved = self.scanPosition
                        if try self.scan(keyword) {
                            try self.scanSpaces()
                            guard try self.scanMediaInParens() else {
                                return false
                            }
                            while true {
                                let again = self.scanPosition
                                if !(try self.scan(keyword)) {
                                    self.scanPosition = again
                                    break
                                }
                                try self.scanSpaces()
                                guard try self.scanMediaInParens() else {
                                    return false
                                }
                            }
                            return true
                        }
                        self.scanPosition = saved
                    }
                    return true
                }
            ])
        }

        /// jj_3_2: "(" S* mediacondition ")" S*.
        func scanParenthesizedCondition() throws -> Bool {
            guard try scan(T.lparen) else {
                return false
            }
            try scanSpaces()
            guard try scanMediaCondition() else {
                return false
            }
            guard try scan(T.rparen) else {
                return false
            }
            try scanSpaces()
            return true
        }

        /// jj_3R_mediainparens: the three alternatives, the first two by
        /// their lookahead expansions.
        func scanMediaInParens() throws -> Bool {
            try scanFirst([
                { try self.scanParenthesizedCondition() },
                { try self.scanMediaRange() },
                { try self.scanMediaExpression() }
            ])
        }

        /// jj_3R_mediaexpression: "(" S* IDENT S* ( ":" S* mediaexpr )? ")".
        func scanMediaExpression() throws -> Bool {
            guard try scan(T.lparen) else {
                return false
            }
            try scanSpaces()
            guard try scan(T.ident) else {
                return false
            }
            try scanSpaces()
            try scanOptional {
                guard try self.scan(T.colon) else {
                    return false
                }
                try self.scanSpaces()
                return try self.scanMediaExpr()
            }
            return try scan(T.rparen)
        }

        /// jj_3R_mediarange: "(" S* ( name-first | value-first ) ")".
        func scanMediaRange() throws -> Bool {
            guard try scan(T.lparen) else {
                return false
            }
            try scanSpaces()
            let matched = try scanFirst([
                { try self.scanNameFirstRange() },
                {
                    guard try self.scanMediaExpr() else {
                        return false
                    }
                    guard try self.scan(any: Parser.comparators) else {
                        return false
                    }
                    try self.scanSpaces()
                    guard try self.scanIdent() else {
                        return false
                    }
                    try self.scanSpaces()
                    try self.scanOptional {
                        guard try self.scan(any: Parser.comparators) else {
                            return false
                        }
                        try self.scanSpaces()
                        return try self.scanMediaExpr()
                    }
                    return true
                }
            ])
            guard matched else {
                return false
            }
            return try scan(T.rparen)
        }

        /// jj_3_21: ident S* comparator S* mediaexpr.
        func scanNameFirstRange() throws -> Bool {
            guard try scanIdent() else {
                return false
            }
            try scanSpaces()
            guard try scan(any: Parser.comparators) else {
                return false
            }
            try scanSpaces()
            return try scanMediaExpr()
        }

        func scanIdent() throws -> Bool {
            try scan(any: [T.ident, T.and, T.or, T.not, T.only])
        }

        /// jj_3R_mediaexpr: mediaterm ( operator mediaterm )*.
        func scanMediaExpr() throws -> Bool {
            guard try scanMediaTerm() else {
                return false
            }
            while true {
                let saved = scanPosition
                if !(try scanOperatorTerm()) {
                    scanPosition = saved
                    return true
                }
            }
        }

        /// jj_3_22: operator mediaterm.
        func scanOperatorTerm() throws -> Bool {
            try scanOptional {
                guard try self.scan(T.comma) else {
                    return false
                }
                try self.scanSpaces()
                return true
            }
            return try scanMediaTerm()
        }

        static let unitKinds: [Int] = [
            T.percentage, T.relFontLength, T.relViewLength, T.absolutLength, T.flex, T.angle, T.time, T.freq,
            T.resolution, T.st, T.spl, T.dimen, T.importantNot, T.dimen9
        ]

        /// jj_3R_mediaterm (CssParser.jj:3517-3603).
        func scanMediaTerm() throws -> Bool {
            try scanFirst([
                {
                    try self.scanOptional { try self.scan(any: [T.minus, T.plus]) }
                    let matched = try self.scanFirst([
                        {
                            // LOOKAHEAD( <NUMBER> ( <S> )* "/" ) ratio | NUMBER
                            try self.scanFirst([
                                {
                                    guard try self.scan(T.number) else {
                                        return false
                                    }
                                    try self.scanSpaces()
                                    return try self.scan(T.div)
                                },
                                { try self.scan(T.number) }
                            ])
                        },
                        { try self.scan(any: Parser.unitKinds) },
                        { try self.scanFunction() },
                        { try self.scanMathCalc() },
                        { try self.scanMathFunction() },
                        { try self.scanMathClamp() }
                    ])
                    guard matched else {
                        return false
                    }
                    try self.scanSpaces()
                    return true
                },
                {
                    guard try self.scan(any: [T.string, T.ident, T.and, T.or, T.not, T.only, T.hashIdent, T.hash,
                                              T.url, T.unicodeRange]) else {
                        return false
                    }
                    try self.scanSpaces()
                    return true
                }
            ])
        }

        /// The function productions' scans, far enough for the budgets of
        /// 3 to 5 tokens that reach them: the opening token and what can
        /// follow it.
        func scanFunction() throws -> Bool {
            guard try scan(T.function) else {
                return false
            }
            try scanSpaces()
            return try scanFirst([
                {
                    try self.scanOptional { try self.scanExpr() }
                    return try self.scan(T.rparen)
                },
                {
                    guard try self.scanIdent() else {
                        return false
                    }
                    guard try self.scan(T.eq) else {
                        return false
                    }
                    guard try self.scan(T.number) else {
                        return false
                    }
                    return try self.scan(T.rparen)
                }
            ])
        }

        func scanMathCalc() throws -> Bool {
            guard try scan(T.functionCalc) else {
                return false
            }
            try scanSpaces()
            guard try scanMathSum() else {
                return false
            }
            try scanSpaces()
            return try scan(T.rparen)
        }

        func scanMathFunction() throws -> Bool {
            try scanFirst([
                {
                    guard try self.scan(T.functionMath1) else {
                        return false
                    }
                    try self.scanSpaces()
                    guard try self.scanMathSum() else {
                        return false
                    }
                    try self.scanSpaces()
                    return try self.scan(T.rparen)
                },
                {
                    guard try self.scan(T.functionMath2) else {
                        return false
                    }
                    try self.scanSpaces()
                    guard try self.scanMathSum() else {
                        return false
                    }
                    try self.scanSpaces()
                    try self.scanOptional {
                        guard try self.scan(T.comma) else {
                            return false
                        }
                        try self.scanSpaces()
                        guard try self.scanMathSum() else {
                            return false
                        }
                        try self.scanSpaces()
                        return true
                    }
                    return try self.scan(T.rparen)
                },
                {
                    guard try self.scan(T.functionMathN) else {
                        return false
                    }
                    try self.scanSpaces()
                    guard try self.scanMathSum() else {
                        return false
                    }
                    try self.scanSpaces()
                    while true {
                        let saved = self.scanPosition
                        let more = try self.scanFirst([{
                            guard try self.scan(T.comma) else {
                                return false
                            }
                            try self.scanSpaces()
                            guard try self.scanMathSum() else {
                                return false
                            }
                            try self.scanSpaces()
                            return true
                        }])
                        if !more {
                            self.scanPosition = saved
                            break
                        }
                    }
                    return try self.scan(T.rparen)
                },
                {
                    guard try self.scan(T.functionRound) else {
                        return false
                    }
                    try self.scanSpaces()
                    let first = try self.scanFirst([
                        {
                            guard try self.scan(T.ident) else {
                                return false
                            }
                            return true
                        },
                        { try self.scanMathSum() }
                    ])
                    guard first else {
                        return false
                    }
                    try self.scanSpaces()
                    while true {
                        let saved = self.scanPosition
                        let more = try self.scanFirst([{
                            guard try self.scan(T.comma) else {
                                return false
                            }
                            try self.scanSpaces()
                            guard try self.scanMathSum() else {
                                return false
                            }
                            try self.scanSpaces()
                            return true
                        }])
                        if !more {
                            self.scanPosition = saved
                            break
                        }
                    }
                    return try self.scan(T.rparen)
                }
            ])
        }

        func scanMathClamp() throws -> Bool {
            guard try scan(T.functionClamp) else {
                return false
            }
            try scanSpaces()
            for index in 0..<3 {
                guard try scanMathSum() else {
                    return false
                }
                try scanSpaces()
                if index < 2 {
                    guard try scan(T.comma) else {
                        return false
                    }
                    try scanSpaces()
                }
            }
            return try scan(T.rparen)
        }

        /// mathsum's scan: product ( (PLUS | S* MINUS) S+ product )*.
        func scanMathSum() throws -> Bool {
            guard try scanMathProduct() else {
                return false
            }
            while true {
                let saved = scanPosition
                let more = try scanFirst([{
                    let op = try self.scanFirst([
                        { try self.scan(T.plus) },
                        {
                            try self.scanSpaces()
                            return try self.scan(T.minus)
                        }
                    ])
                    guard op else {
                        return false
                    }
                    guard try self.scan(T.s) else {
                        return false
                    }
                    try self.scanSpaces()
                    return try self.scanMathProduct()
                }])
                if !more {
                    scanPosition = saved
                    return true
                }
            }
        }

        func scanMathProduct() throws -> Bool {
            guard try scanMathUnit() else {
                return false
            }
            while true {
                let saved = scanPosition
                let more = try scanFirst([{
                    try self.scanSpaces()
                    return try self.scanFirst([
                        {
                            guard try self.scan(T.any) else {
                                return false
                            }
                            try self.scanSpaces()
                            return try self.scanMathUnit()
                        },
                        {
                            guard try self.scan(T.div) else {
                                return false
                            }
                            try self.scanSpaces()
                            return try self.scanFirst([
                                { try self.scanCalcNumberValue() },
                                { try self.scanVar() },
                                { try self.scanEnv() }
                            ])
                        }
                    ])
                }])
                if !more {
                    scanPosition = saved
                    return true
                }
            }
        }

        func scanCalcNumberValue() throws -> Bool {
            try scanFirst([
                {
                    try self.scanOptional { try self.scan(any: [T.minus, T.plus]) }
                    return try self.scan(any: [T.number, T.ident])
                },
                {
                    guard try self.scan(T.lparen) else {
                        return false
                    }
                    try self.scanSpaces()
                    guard try self.scanMathSum() else {
                        return false
                    }
                    try self.scanSpaces()
                    return try self.scan(T.rparen)
                }
            ])
        }

        func scanMathUnit() throws -> Bool {
            try scanFirst([
                {
                    try self.scanOptional { try self.scan(any: [T.minus, T.plus]) }
                    return try self.scan(any: [T.number, T.ident, T.percentage, T.relFontLength, T.relViewLength,
                                               T.absolutLength, T.flex, T.angle, T.time, T.freq])
                },
                {
                    guard try self.scan(T.lparen) else {
                        return false
                    }
                    try self.scanSpaces()
                    guard try self.scanMathSum() else {
                        return false
                    }
                    try self.scanSpaces()
                    return try self.scan(T.rparen)
                },
                { try self.scanMathCalc() },
                { try self.scanMathFunction() },
                { try self.scanMathClamp() },
                { try self.scanAttr() },
                { try self.scanVar() },
                { try self.scanEnv() }
            ])
        }

        /// jj_3R_attr_3925_5_424: attr( ident S* ( ident | "%" )? ","? ")".
        /// The scans of attr(), var() and env() are JavaCC's, truncated
        /// where the lookahead budgets that reach them run out; they must
        /// go on past the name (Case 554591 review), or the comma of
        /// "(calc(var(--bp, 768px)) <= width)" fails a range upstream takes.
        func scanAttr() throws -> Bool {
            guard try scan(T.functionAttr) else {
                return false
            }
            try scanSpaces()
            guard try scanIdent() else {
                return false
            }
            try scanSpaces()
            try scanOptional { try self.scan(any: [T.ident, T.and, T.or, T.not, T.only, T.percent]) }
            try scanOptional { try self.scan(T.comma) }
            return try scan(T.rparen)
        }

        /// jj_3R_functionvar_3977_3_404: var( S* --name ","* S* ")".
        func scanVar() throws -> Bool {
            guard try scan(T.functionVar) else {
                return false
            }
            try scanSpaces()
            guard try scan(T.dashedIdent) else {
                return false
            }
            while true {
                let saved = scanPosition
                if !(try scan(T.comma)) {
                    scanPosition = saved
                    break
                }
            }
            try scanSpaces()
            return try scan(T.rparen)
        }

        /// jj_3R_functionenv_3946_3_405: env( S* name S* term* ","? ")".
        func scanEnv() throws -> Bool {
            guard try scan(T.functionEnv) else {
                return false
            }
            try scanSpaces()
            guard try scan(T.ident) else {
                return false
            }
            try scanSpaces()
            while true {
                let saved = scanPosition
                if !(try scanTerm()) {
                    scanPosition = saved
                    break
                }
            }
            try scanOptional { try self.scan(T.comma) }
            return try scan(T.rparen)
        }

        /// expr's scan: term ( operator term )*.
        func scanExpr() throws -> Bool {
            guard try scanTerm() else {
                return false
            }
            while true {
                let saved = scanPosition
                let more = try scanFirst([{
                    try self.scanOptional {
                        guard try self.scan(T.comma) else {
                            return false
                        }
                        try self.scanSpaces()
                        return true
                    }
                    return try self.scanTerm()
                }])
                if !more {
                    scanPosition = saved
                    return true
                }
            }
        }

        /// term's scan (CssParser.jj:3416-3512).
        func scanTerm() throws -> Bool {
            let matched = try scanFirst([
                {
                    try self.scanOptional { try self.scan(any: [T.minus, T.plus]) }
                    return try self.scan(any: [T.number, T.percentage, T.relFontLength, T.relViewLength,
                                               T.absolutLength, T.flex, T.angle, T.time, T.freq, T.resolution,
                                               T.st, T.spl, T.dimen, T.progid, T.importantNot, T.dimen9])
                },
                { try self.scanMathCalc() },
                { try self.scanMathFunction() },
                { try self.scanMathClamp() },
                { try self.scanAttr() },
                { try self.scanVar() },
                { try self.scanEnv() },
                { try self.scanFunction() },
                {
                    try self.scan(any: [T.string, T.div, T.rbracket, T.lbracket, T.ident, T.and, T.or, T.not, T.only,
                                        T.dashedIdent, T.hashIdent, T.hash, T.url, T.unicodeRange])
                }
            ])
            guard matched else {
                return false
            }
            try scanSpaces()
            return true
        }

        // MARK: Media features

        enum FeatureResult {
            case none
            case range
            case plain
        }

        /// CssFouffa.handleMediaFeature (parser/CssFouffa.java:637-667)
        /// with CssPropertyFactory.createMediaFeature
        /// (parser/CssPropertyFactory.java:109-174): the name's escapes
        /// decoded (convertIdent, already), its first "-" found, then
        /// lowercased; a "-" first is a vendor feature, and "min"/"max"
        /// before the first "-" a prefix; a name CSS3Properties doesn't list
        /// is only a warning (vendor extensions are warnings), so no feature
        /// at all.
        func handleMediaFeature(_ name: [UInt16], _ expression: Expression?) throws -> FeatureResult {
            let dash = name.firstIndex(of: 0x2D)
            var feature = javaLowercase(name)
            var modifier: String?
            if let dashpos = dash {
                if 0 == dashpos {
                    return .none
                }
                // substrings of the lowercased name at the original index
                guard dashpos < feature.count else {
                    throw Interrupt.parse(.invalid(nil))
                }
                let candidate = HTMLMediaQueryDatatype.string(feature[0..<dashpos])
                if "min" == candidate || "max" == candidate {
                    modifier = candidate
                    feature = Array(feature[(dashpos + 1)...])
                }
            }
            let featureName = HTMLMediaQueryDatatype.string(javaLowercase(feature)[...])
            guard let kind = HTMLMediaQueryDatatype.features[featureName] else {
                return .none
            }
            let checker = FeatureCheck(name: featureName, modifier: modifier, expression: expression)
            switch checker.run(kind) {
            case .valid(let isRange, let stored):
                featureValues.append(contentsOf: stored)
                return isRange ? .range : .plain
            case .error(let message):
                try recordPlain(message)
                return .none
            case .exception:
                // a ClassCastException out of the constructor:
                // handleMediaFeature throws InvalidParamException with a
                // null message, which media() records (skipped) after
                // skipStatement
                throw Interrupt.parse(.invalid(nil))
            }
        }

        // MARK: Values

        /// mediaexpr (CssParser.jj:3404-3410).
        func mediaExpr() throws -> Expression {
            let values = Expression()
            try mediaTerm(values)
            while try lookahead(2, { try self.scanOperatorTerm() }) {
                try operatorProduction(values)
                try mediaTerm(values)
            }
            return values
        }

        /// operator (CssParser.jj:2182-2187).
        func operatorProduction(_ expression: Expression) throws {
            if T.comma == (try next()) {
                try consume(T.comma)
                if expression.count > 0 {
                    expression.setOperator(0x2C)
                }
                try skipSpaces()
            }
        }

        /// unaryOperator: '-' or '+', or a space when there's none.
        func unaryOperator() throws -> UInt16 {
            let k = try next()
            if T.minus == k {
                try advance()
                return 0x2D
            }
            if T.plus == k {
                try advance()
                return 0x2B
            }
            return 0x20
        }

        /// addOperator: the sign before the image.
        func signed(_ op: UInt16, _ token: Token) -> [UInt16] {
            0x20 == op ? Array(image(token)) : [op] + Array(image(token))
        }

        /// mediaterm (CssParser.jj:3517-3603).
        func mediaTerm(_ exp: Expression) throws {
            let k = try next()
            if [T.string, T.ident, T.and, T.or, T.not, T.only, T.hashIdent, T.hash, T.url, T.unicodeRange].contains(k) {
                try plainTerm(exp, k)
                try skipSpaces()
                return
            }
            let op = try unaryOperator()
            let k2 = try next()
            switch k2 {
            case T.number:
                if try lookahead(Int.max / 4, { try self.scanRatioStart() }) {
                    try ratio(exp, op)
                } else {
                    let n = try advance()
                    exp.add(try numberValue(signed(op, n)))
                }
            case T.dimen:
                let n = try advance()
                if "0\\0" == trimmed(Array(image(n))) {
                    // a CSS hack warning: no value
                } else {
                    try record(.plain(Message.unknownDimension))
                }
            case T.importantNot:
                try advance()
                // WarningParamException("css-hack", …): getMessage() is
                // the bare key
                throw Interrupt.parse(Failure(message: "css-hack", generic: false))
            case T.dimen9:
                try advance()
            case T.function:
                exp.add(try function())
            case T.functionCalc:
                exp.add(try mathCalc())
            case T.functionMath1, T.functionMath2, T.functionMathN, T.functionRound:
                exp.add(.math(try mathFunction()))
            case T.functionClamp:
                exp.add(.math(try mathClamp()))
            default:
                guard let value = try unitValue(k2, op) else {
                    throw Interrupt.parse(.syntax)
                }
                exp.add(value)
            }
            try skipSpaces()
        }

        /// The ident-and-friends alternative of mediaterm and term:
        /// STRING, ident() (with the missing-semicolon check), a hash, a
        /// url() or a unicode range.
        func plainTerm(_ exp: Expression, _ k: Int) throws {
            let n = try advance()
            switch k {
            case T.string:
                exp.add(.string(imageString(n)))
            case T.hashIdent, T.hash:
                exp.add(.hashIdent(imageString(n)))
            case T.url:
                exp.add(.url(try url(n)))
            case T.unicodeRange:
                exp.add(.unicodeRange(imageString(n)))
            default:
                if T.colon == (try peek(1)).kind {
                    try record(.plain(Message.semicolon(imageString(n))))
                }
                let units = T.ident == n.kind ? convertIdent(Array(image(n))) : Array(image(n))
                exp.add(.ident(units))
            }
        }

        /// CssURL.set and toString (values/CssURL.java:90-131, 175-186):
        /// the address trimmed, its quotes noted and dropped, < and >
        /// percent-escaped; and, unless it holds "data:", made into a
        /// java.net.URL against the style sheet's file: URL, whose
        /// MalformedURLException is "url" (isJavaURL has what throws).
        func url(_ n: Token) throws -> String {
            let units = Array(image(n))
            guard let open = units.firstIndex(of: 0x28), units.count >= open + 2 else {
                return imageString(n)
            }
            var inner = Array(units[(open + 1)..<(units.count - 1)])
            var a = 0
            var b = inner.count
            while a < b && inner[a] <= 0x20 {
                a += 1
            }
            while b > a && inner[b - 1] <= 0x20 {
                b -= 1
            }
            inner = Array(inner[a..<b])
            var quoted = false
            if let first = inner.first, 0x22 == first || 0x27 == first {
                guard inner.count >= 2, first == inner[inner.count - 1] else {
                    throw Interrupt.parse(.invalid(Message.url(imageString(n))))
                }
                inner = Array(inner[1..<(inner.count - 1)])
                quoted = true
            }
            var value = [UInt16]()
            for c in inner {
                if 0x3C == c {
                    value.append(contentsOf: "%3c".utf16)
                } else if 0x3E == c {
                    value.append(contentsOf: "%3e".utf16)
                } else {
                    value.append(c)
                }
            }
            let text = HTMLMediaQueryDatatype.string(value[...])
            // CssURL.set skips a URL holding "data:" (in the unescaped name),
            // and otherwise makes java.net.URL from the escaped value, so
            // "http://a<b/" (host "a%3cb") passes (Case 554591 review)
            if !HTMLMediaQueryDatatype.string(inner[...]).contains("data:") && !HTMLMediaQueryDatatype.isJavaURL(value, true) {
                throw Interrupt.parse(.invalid(Message.url(imageString(n))))
            }
            return quoted ? "url(\"" + text + "\")" : "url(" + text + ")"
        }

        /// LOOKAHEAD( <NUMBER> ( <S> )* "/" ).
        func scanRatioStart() throws -> Bool {
            guard try scan(T.number) else {
                return false
            }
            try scanSpaces()
            return try scan(T.div)
        }

        /// ratio (CssParser.jj:1172-1184) and CssRatio.set
        /// (values/CssRatio.java): both numbers strictly positive.
        func ratio(_ exp: Expression, _ op: UInt16) throws {
            let w = try consume(T.number)
            try skipSpaces()
            try consume(T.div)
            try skipSpaces()
            let h = try consume(T.number)
            var s = Array(image(w)) + [0x2F] + Array(image(h))
            if 0x20 != op {
                s.insert(op, at: 0)
            }
            let text = HTMLMediaQueryDatatype.string(s[...])
            let wn = signedNumber(op, w)
            guard let wv = wn else {
                throw Interrupt.parse(.invalid(Message.value(text, "")))
            }
            if 1 != wv.signum {
                throw Interrupt.parse(.invalid(Message.strictlyPositive(text)))
            }
            guard let hv = Num.parse(Array(image(h))) else {
                throw Interrupt.parse(.invalid(Message.value(text, "")))
            }
            if 1 != hv.signum {
                throw Interrupt.parse(.invalid(Message.strictlyPositive(text)))
            }
            exp.add(.ratio(wv, hv))
        }

        func signedNumber(_ op: UInt16, _ token: Token) -> Num? {
            Num.parse(signed(op, token))
        }

        /// CssNumber.set (values/CssNumber.java): a NumberFormatException
        /// is a RuntimeException (media()'s finally swallows it).
        func numberValue(_ s: [UInt16]) throws -> Value {
            guard let n = Num.parse(s) else {
                throw Interrupt.runtime(Num.failure(s))
            }
            var body = s[...]
            if let first = body.first, 0x2D == first || 0x2B == first {
                body = body.dropFirst()
            }
            return .number(n, isInt: !body.contains(0x2E), special: nil)
        }

        /// The unit tokens' values and their set() checks (CssLength,
        /// CssAngle, CssTime, CssFrequency, CssResolution,
        /// CssFlexibleLength, CssSemitone, CssVolume, CssPercentage): the
        /// unit is the trailing run of [a-z] of the lowercased image, which
        /// must be in CssUnitsCSS3's table (where dvmin is misspelled
        /// "dvnim", CssUnitsCSS3.java:25), and the number before it must
        /// parse.
        func unitValue(_ kind: Int, _ op: UInt16) throws -> Value? {
            switch kind {
            case T.percentage, T.relFontLength, T.relViewLength, T.absolutLength, T.flex, T.angle, T.time, T.freq,
                 T.resolution, T.st, T.spl:
                break
            default:
                return nil
            }
            let n = try advance()
            let s = signed(op, n)
            if T.percentage == kind {
                guard let v = Num.parse(Array(s.dropLast())) else {
                    throw Interrupt.runtime(Num.failure(Array(s.dropLast())))
                }
                return .percentage(v)
            }
            let lower = s.map(asciiLower)
            var unitIndex = lower.count - 1
            var c = lower[unitIndex]
            while unitIndex > 0 && c <= 0x7A && c >= 0x61 {
                unitIndex -= 1
                c = lower[unitIndex]
            }
            unitIndex += 1
            let unit = HTMLMediaQueryDatatype.string(lower[unitIndex...])
            let numberText = Array(lower[0..<unitIndex])
            let table: [String]
            switch kind {
            case T.relFontLength, T.relViewLength, T.absolutLength:
                table = HTMLMediaQueryDatatype.lengthUnits
            case T.flex:
                table = ["fr"]
            case T.angle:
                table = ["deg", "grad", "rad", "turn"]
            case T.time:
                table = ["ms", "s"]
            case T.freq:
                table = ["khz", "hz"]
            case T.resolution:
                table = ["dpi", "dpcm", "dppx", "x"]
            case T.st:
                table = ["st"]
            default:
                table = ["db"]
            }
            guard table.contains(unit) else {
                throw Interrupt.parse(.invalid(Message.unit(unit)))
            }
            guard let v = Num.parse(numberText) else {
                throw Interrupt.parse(.invalid(Message.invalidNumber))
            }
            switch kind {
            case T.relFontLength, T.relViewLength, T.absolutLength:
                return .length(v, unit)
            case T.flex:
                return .flex(v)
            case T.angle:
                return .angle(v, unit)
            case T.time:
                return .time(v, unit)
            case T.freq:
                return .frequency(v, unit)
            case T.resolution:
                return .resolution(v, unit)
            case T.st:
                return .semitone(v)
            default:
                return .volume(v)
            }
        }

        // MARK: Functions

        /// function() (CssParser.jj:4013-4117): FUNCTION S* ( expr? ")" |
        /// ident "=" NUMBER ")" ), then the color and image functions'
        /// checks, or a CssFunction.
        func function() throws -> Value {
            try enter(3)
            defer {
                leave(3)
            }
            let n = try consume(T.function)
            try skipSpaces()
            let nameUnits = Array(image(n).dropLast())
            let name = HTMLMediaQueryDatatype.string(nameUnits[...])
            if try lookahead(2, {
                try self.scanOptional { try self.scanExpr() }
                return try self.scan(T.rparen)
            }) {
                var exp = Expression()
                if T.rparen != (try next()) {
                    exp = try expr()
                }
                try consume(T.rparen)
                let funcname = HTMLMediaQueryDatatype.string(javaLowercase(Array(image(n)))[...])
                return try colorOrFunction(funcname, name, exp)
            }
            // ident "=" NUMBER, a vendor extension such as alpha(opacity=50)
            let p = try identToken()
            try consume(T.eq)
            let q = try consume(T.number)
            try consume(T.rparen)
            let exp = Expression()
            exp.add(.ident(T.ident == p.kind ? convertIdent(Array(image(p))) : Array(image(p))))
            exp.setOperator(0x3D)
            exp.add(try numberValue(Array(image(q))))
            return .function(name, exp)
        }

        /// The color and image functions of function() (CssParser.jj:
        /// 4021-4094). rgb()/rgba() and hsl()/hsla() are checked as RGBA
        /// .parseModernRGBA and HSL.parseHSL do, and image() as CssImage
        /// .setImageList; the other color functions, the relative colors
        /// ("from …") and the gradients, whose classes are far outside media
        /// queries, are taken on trust, but for a gradient of a single value
        /// (too few values).
        func colorOrFunction(_ funcname: String, _ name: String, _ exp: Expression) throws -> Value {
            switch funcname {
            case "rgb(", "rgba(":
                return try rgbColor(name, exp)
            case "hsl(", "hsla(":
                return try hslColor(String(funcname.dropLast()), name, exp)
            case "hwb(", "lab(", "lch(", "oklab(", "oklch(", "device-cmyk(", "light-dark(", "color-mix(":
                return .color(ColorText(.asWritten(name), [], alpha: nil, expression: exp))
            case "image(":
                try imageList(exp)
                return .image(name, exp)
            case "linear-gradient(", "repeating-linear-gradient(", "radial-gradient(", "repeating-radial-gradient(",
                 "conic-gradient(", "repeating-conic-gradient(":
                if 0 == exp.count {
                    // the gradient code reads a value that isn't there
                    throw Interrupt.runtime(nil)
                }
                if exp.count < 2 && !exp.hasVariable {
                    throw Interrupt.parse(.invalid(Message.fewValue(String(funcname.dropLast()))))
                }
                return .image(name, exp)
            case "atsc-rgba(":
                // @media atsc-tv can't be (atsc-tv is an unknown type),
                // so always the error, recorded with addError
                try record(.invalid(Message.onlyATSC("")))
                return .function(name, exp)
            default:
                return .function(name, exp)
            }
        }

        /// Whether a value is the identifier `keyword` (CssIdent's hash
        /// equality).
        func isIdent(_ value: Value?, _ keyword: String) -> Bool {
            if case .ident(let units)? = value {
                return identEquals(units, keyword)
            }
            return false
        }

        /// A CssNumber of a small integer, as the color filters make.
        func smallNumber(_ v: UInt8) -> Value {
            .number(Num(negative: false, digits: 0 == v ? [] : String(v).utf8.map { $0 - 0x30 }, scale: 0,
                        source: String(v)), isInt: true, special: nil)
        }

        /// A warning that prints the value (toString()): it's thrown away,
        /// but printing a number Java can't print throws.
        func printForWarning(_ v: Value) throws {
            if v.textThrows {
                throw Interrupt.runtime(nil)
            }
        }

        /// RGB.filterValue (values/color/RGB.java:28-75): a negative channel
        /// warns (printing it) and is 0, a number over 255 is 255, a
        /// percentage over 100 is 100%.
        func rgbFilter(_ v: Value) throws -> Value {
            switch v {
            case .number(let n, _, nil):
                if n.negative {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                if n.floatOverflows || Num.greaterThan(n, 255) {
                    return smallNumber(255)
                }
                return v
            case .percentage(let n):
                if n.negative {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                if n.floatOverflows || Num.greaterThan(n, 100) {
                    return .percentage(Num(negative: false, digits: [1, 0, 0], scale: 0, source: "100"))
                }
                return v
            default:
                return v
            }
        }

        /// RGBA.filterAlpha (values/color/RGBA.java:63-105): out of 0 to 1
        /// (0% to 100%) warns, printing the value, and is clamped; a math
        /// function isn't positive, so it warns and is 0.
        func alphaFilter(_ v: Value) throws -> Value {
            switch v {
            case .number(let n, _, nil):
                if n.negative {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                if Num.greaterThan(n, 1) {
                    try printForWarning(v)
                    return smallNumber(1)
                }
                return v
            case .percentage(let n):
                if n.negative {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                if n.floatOverflows || Num.greaterThan(n, 100) {
                    try printForWarning(v)
                    return .percentage(Num(negative: false, digits: [1, 0, 0], scale: 0, source: "100"))
                }
                return v
            case .math:
                if CssType.number == v.type || CssType.percentage == v.type {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                return v
            default:
                return v
            }
        }

        /// HSL.filterHue (values/color/HSL.java:325-375) for a number: a
        /// negative one warns, printing it; one a float can't hold is
        /// normalized to NaN, which BigDecimal refuses (a
        /// NumberFormatException media() swallows).
        func hueFilter(_ v: Value) throws -> Value {
            if case .number(let n, _, nil) = v {
                if n.negative {
                    try printForWarning(v)
                }
                if n.floatOverflows {
                    throw Interrupt.runtime(nil)
                }
            }
            return v
        }

        /// HSL.filterValue (values/color/HSL.java:295-323) for saturation
        /// and lightness: a negative value warns (printing it) and is 0, a
        /// percentage over 100 is 100%, a number over 100 warns, printing
        /// it.
        func hslFilter(_ v: Value) throws -> Value {
            switch v {
            case .number(let n, _, nil):
                if n.negative {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                if n.floatOverflows || Num.greaterThan(n, 100) {
                    try printForWarning(v)
                }
                return v
            case .percentage(let n):
                if n.negative {
                    try printForWarning(v)
                    return smallNumber(0)
                }
                if n.floatOverflows || Num.greaterThan(n, 100) {
                    return .percentage(Num(negative: false, digits: [1, 0, 0], scale: 0, source: "100"))
                }
                return v
            default:
                return v
            }
        }

        /// RGBA.parseModernRGBA (values/color/RGBA.java:192-412): three
        /// numbers or three percentages, separated by spaces (modern: the
        /// first separator decides) or commas (legacy), "none" allowed in
        /// the modern syntax; then an optional alpha, after " / " or ",".
        /// Values after the alpha aren't looked at. With a var() in it the
        /// checks are off, and a missing value is a NullPointerException,
        /// which media() swallows (so rgb(var(--x)) is a Parse Error).
        func rgbColor(_ name: String, _ exp: Expression) throws -> Value {
            let variable = exp.hasVariable
            func value(_ i: Int) -> Value? {
                i < exp.count ? exp.values[i] : nil
            }
            func op(_ i: Int) -> UInt16 {
                i < exp.count ? exp.operators[i] : 0x20
            }
            guard let first = value(0) else {
                // val == null: invalid-color, or with a variable the
                // getType() on null
                throw variable ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.invalidColor))
            }
            if isIdent(first, "from") {
                // a relative color: taken on trust
                return .color(ColorText(.relative("rgb"), [], alpha: nil, expression: exp))
            }
            let modern = 0x20 == op(0)
            var gotNumber = false
            var gotPercentage = false
            func channel(_ v: Value) throws {
                switch v.type {
                case CssType.variable, CssType.number:
                    if gotPercentage {
                        throw v.messageThrows ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.colorFunction(v.text, "rgba")))
                    }
                    gotNumber = true
                case CssType.percentage:
                    if gotNumber {
                        throw v.messageThrows ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.colorFunction(v.text, "rgba")))
                    }
                    gotPercentage = true
                case CssType.ident where modern && isIdent(v, "none"):
                    break
                default:
                    if !variable {
                        throw v.messageThrows ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.colorFunction(v.text, "rgba")))
                    }
                }
            }
            // R: the first value's own separator only sets the style
            try channel(first)
            let red = try rgbFilter(first)
            // G
            let green = value(1)
            if (nil == green || (modern && 0x20 != op(1)) || (!modern && 0x2C != op(1))) && !variable {
                throw Interrupt.parse(.invalid(Message.invalidColor))
            }
            guard let g = green else {
                throw Interrupt.runtime(nil)
            }
            try channel(g)
            let greenValue = try rgbFilter(g)
            // B: only the value
            let blue = value(2)
            if nil == blue && !variable {
                throw Interrupt.parse(.invalid(Message.invalidColor))
            }
            guard let b = blue else {
                throw Interrupt.runtime(nil)
            }
            try channel(b)
            let blueValue = try rgbFilter(b)
            var alpha: Value?
            if exp.count > 3 {
                if ((modern && 0x20 != op(2)) || (!modern && 0x2C != op(2))) && !variable {
                    throw Interrupt.parse(.invalid(Message.invalidColor))
                }
                var index = 3
                if modern {
                    let slash = exp.values[3]
                    if CssType.switchValue != slash.type && !variable {
                        // RGBA.java:372 names LCH
                        throw slash.messageThrows ? Interrupt.runtime(nil)
                            : Interrupt.parse(.invalid(Message.colorFunction(slash.text, "LCH")))
                    }
                    if 0x20 != op(3) && !variable {
                        throw Interrupt.parse(.invalid(Message.invalidColor))
                    }
                    index = 4
                }
                guard let a = value(index) else {
                    throw Interrupt.runtime(nil)
                }
                switch a.type {
                case CssType.variable, CssType.number, CssType.percentage:
                    break
                case CssType.ident where modern && isIdent(a, "none"):
                    break
                default:
                    if !variable {
                        throw a.messageThrows ? Interrupt.runtime(nil)
                            : Interrupt.parse(.invalid(Message.colorFunction(a.text, "rgba")))
                    }
                }
                alpha = try alphaFilter(a)
            }
            let parts = [red, greenValue, blueValue]
            return .color(ColorText(modern ? .modernRGB : .legacyRGB, parts, alpha: alpha, expression: exp))
        }

        /// HSL.parseHSL (values/color/HSL.java:75-290), with its cursor: a
        /// hue (number or angle, or "none" in the modern syntax), then
        /// saturation and lightness (percentages, or numbers in the modern
        /// syntax), then an optional alpha after "," (legacy) or " / ", and
        /// nothing more. With a var() and fewer than three values it gives
        /// up quietly; with a var(), a saturation, lightness or legacy alpha
        /// it doesn't take is tolerated after exp.starts(), which rewinds
        /// the cursor, so the reads after it start again at the second value
        /// (Case 554591 review: "hsl(var(--x) 1 / 1)" is valid that way).
        func hslColor(_ function: String, _ name: String, _ exp: Expression) throws -> Value {
            let variable = exp.hasVariable
            var index = 0
            // getValue(), getOperator() and next() of CssExpression
            func value() -> Value? {
                index < exp.count ? exp.values[index] : nil
            }
            func op() -> UInt16 {
                index < exp.count ? exp.operators[index] : 0x20
            }
            func advanceCursor() {
                if index < exp.count {
                    index += 1
                }
            }
            func colorError(_ v: Value?) -> Interrupt {
                (v?.messageThrows ?? false) ? Interrupt.runtime(nil)
                    : Interrupt.parse(.invalid(Message.colorFunction(v?.text ?? "null", "HSL")))
            }
            let invalid = Interrupt.parse(.invalid(Message.invalidColor))
            if variable && exp.count < 3 {
                return .color(ColorText(.asWritten(name), [], alpha: nil, expression: exp))
            }
            // what the color keeps, "null" where nothing was set
            let unset = Value.ident(Array("null".utf16))
            var parts = [unset, unset, unset]
            var val = value()
            var o = op()
            let space = 0x20 == o
            if nil == val || (!space && 0x2C != o) {
                if !variable {
                    throw invalid
                }
            }
            guard let hue = val else {
                // val.getType() on null
                throw Interrupt.runtime(nil)
            }
            if isIdent(hue, "from") {
                return .color(ColorText(.relative(function), [], alpha: nil, expression: exp))
            }
            // the hue's default branch doesn't rewind
            switch hue.type {
            case CssType.angle, CssType.number, CssType.variable:
                parts[0] = try hueFilter(hue)
            case CssType.ident where space && isIdent(hue, "none"):
                parts[0] = hue
            default:
                if !variable {
                    throw colorError(hue)
                }
            }
            advanceCursor()
            // saturation and lightness
            func component(_ v: Value, _ part: Int) throws {
                switch v.type {
                case CssType.number:
                    // checked even with a var()
                    if !space {
                        throw colorError(v)
                    }
                    parts[part] = try hslFilter(v)
                case CssType.percentage, CssType.variable:
                    parts[part] = try hslFilter(v)
                case CssType.ident where space && isIdent(v, "none"):
                    parts[part] = v
                default:
                    index = 0
                    if !variable {
                        throw colorError(v)
                    }
                }
            }
            val = value()
            o = op()
            if nil == val || (space && 0x20 != o) || (!space && 0x2C != o) {
                if !variable {
                    throw invalid
                }
            }
            guard let saturation = val else {
                throw Interrupt.runtime(nil)
            }
            try component(saturation, 1)
            advanceCursor()
            val = value()
            o = op()
            if nil == val && !variable {
                throw invalid
            }
            guard let lightness = val else {
                throw Interrupt.runtime(nil)
            }
            try component(lightness, 2)
            advanceCursor()
            var alpha: Value?
            if index < exp.count {
                if 0x2C == o && !space {
                    // the legacy alpha
                    if let a = value() {
                        switch a.type {
                        case CssType.number, CssType.percentage, CssType.variable:
                            alpha = try alphaFilter(a)
                        default:
                            index = 0
                            if !variable {
                                throw colorError(a)
                            }
                        }
                    }
                } else {
                    if 0x20 != o && !variable {
                        throw invalid
                    }
                    let slash = value()
                    o = op()
                    if CssType.switchValue != slash?.type && !variable {
                        throw colorError(slash)
                    }
                    if 0x20 != o && !variable {
                        throw invalid
                    }
                    advanceCursor()
                    if index >= exp.count && !variable {
                        throw colorError(nil)
                    }
                    guard let a = value() else {
                        throw Interrupt.runtime(nil)
                    }
                    switch a.type {
                    case CssType.number, CssType.percentage, CssType.variable:
                        alpha = try alphaFilter(a)
                    case CssType.ident where 0x2C != o && isIdent(a, "none"):
                        alpha = a
                    default:
                        if !variable {
                            throw colorError(a)
                        }
                    }
                }
                advanceCursor()
                if index < exp.count && !variable {
                    throw colorError(value())
                }
            }
            return .color(ColorText(.hsl(function), parts, alpha: alpha, expression: exp))
        }

        /// CssImage.setImageList (values/CssImage.java:137-208): URLs and
        /// strings, then at most one color, last, comma-separated.
        func imageList(_ exp: Expression) throws {
            let variable = exp.hasVariable
            var gotColor = false
            for (index, v) in exp.values.enumerated() {
                if gotColor && !variable {
                    throw v.messageThrows ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.value(v.text, "image()")))
                }
                switch v.type {
                case CssType.url, CssType.string:
                    break
                case CssType.hashIdent:
                    // RGBA.parseShortRGBColor: # and 3, 4, 6 or 8 hex digits
                    let units = Array(v.text.utf16)
                    let digits = units.dropFirst()
                    if ![3, 4, 6, 8].contains(digits.count) || !digits.allSatisfy(HTMLMediaQueryDatatype.isHex) {
                        throw Interrupt.parse(.invalid(Message.rgb(v.text)))
                    }
                    gotColor = true
                case CssType.color:
                    gotColor = true
                case CssType.ident:
                    // currentColor.equals(val.getIdent()), else
                    // setIdentColor(val.getIdent().toString()): a var() or
                    // env() answers with its identifier fallback, which must
                    // be a color too; a value of identifier type without
                    // getIdent() throws ClassCastException (Case 554591
                    // review: the port once checked plain identifiers alone)
                    guard let ident = v.javaIdentValue, case .ident(let units) = ident else {
                        throw Interrupt.runtime(nil)
                    }
                    if !HTMLMediaQueryDatatype.isColorIdent(units) {
                        throw Interrupt.parse(.invalid(Message.value(ident.text, "color")))
                    }
                    gotColor = true
                default:
                    if !variable {
                        throw v.messageThrows ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.value(v.text, "image()")))
                    }
                }
                if index + 1 < exp.count && 0x2C != exp.operators[index] && !variable {
                    throw Interrupt.parse(.invalid(Message.incorrectOperator(String(Character(Unicode.Scalar(exp.operators[index]) ?? " ")))))
                }
            }
        }

        /// expr (CssParser.jj:3337-3349), whose catch turns a
        /// WarningParamException into a warning, ending the expression.
        func expr() throws -> Expression {
            let values = Expression()
            do {
                try term(values)
                while try lookahead(2, {
                    try self.scanOptional {
                        guard try self.scan(T.comma) else {
                            return false
                        }
                        try self.scanSpaces()
                        return true
                    }
                    return try self.scanTerm()
                }) {
                    try operatorProduction(values)
                    try term(values)
                }
            } catch Interrupt.parse(let failure) where isWarning(failure) {
                // a warning
            }
            return values
        }

        func isWarning(_ failure: Failure) -> Bool {
            !failure.generic && ("css-hack" == failure.message || "vendor-extension" == failure.message)
        }

        /// term (CssParser.jj:3416-3512).
        func term(_ exp: Expression) throws {
            let k = try next()
            switch k {
            case T.string, T.ident, T.and, T.or, T.not, T.only, T.hashIdent, T.hash, T.url, T.unicodeRange:
                try plainTerm(exp, k)
            case T.div:
                try advance()
                exp.add(.switchValue)
            case T.rbracket, T.lbracket:
                let n = try advance()
                exp.add(.bracket(imageString(n)))
            case T.dashedIdent:
                let n = try advance()
                exp.add(.dashedIdent(imageString(n)))
            case T.functionCalc:
                exp.add(try mathCalc())
            case T.functionMath1, T.functionMath2, T.functionMathN, T.functionRound:
                exp.add(.math(try mathFunction()))
            case T.functionClamp:
                exp.add(.math(try mathClamp()))
            case T.functionAttr:
                let a = try attr()
                // setValue's FUNCTION branch casts a CSS_COLOR value to
                // CssColor (CssParser.jj:426-430): a ClassCastException for
                // an attr() of color type
                if CssType.color == a.type {
                    throw Interrupt.runtime(nil)
                }
                exp.add(a)
            case T.functionVar:
                exp.add(try functionVar())
            case T.functionEnv:
                exp.add(try functionEnv())
            case T.function:
                exp.add(try function())
            default:
                let op = try unaryOperator()
                let k2 = try next()
                switch k2 {
                case T.number:
                    let n = try advance()
                    exp.add(try numberValue(signed(op, n)))
                case T.dimen:
                    let n = try advance()
                    if "0\\0" != trimmed(Array(image(n))) {
                        try record(.plain(Message.unknownDimension))
                    }
                case T.progid:
                    try advance()
                    throw Interrupt.parse(Failure(message: "vendor-extension", generic: false))
                case T.importantNot:
                    try advance()
                    throw Interrupt.parse(Failure(message: "css-hack", generic: false))
                case T.dimen9:
                    try advance()
                default:
                    guard let value = try unitValue(k2, op) else {
                        throw Interrupt.parse(.syntax)
                    }
                    exp.add(value)
                }
            }
            // ( LOOKAHEAD(2) <S> )*
            while T.s == (try next()) {
                try consume(T.s)
            }
        }

        /// attr() (CssParser.jj:3912-3931): attr( ident ( ident | "%" )? (
        /// "," term )? ), then CssAttr.setValue (values/CssAttr.java:100-
        /// 179), ported for the Case 554591 review: the type is string, or
        /// what typeMap gives the type-or-unit identifier (CssIdent
        /// equality, so any case), and a fallback must fit it. An unknown
        /// identifier makes _checkType build its exception with CssAttr's
        /// own ac field, which is never set: a NullPointerException, which
        /// media() swallows (so "Parse Error.").
        func attr() throws -> Value {
            try enter(2)
            defer {
                leave(2)
            }
            try consume(T.functionAttr)
            try skipSpaces()
            let n = try identToken()
            try skipSpaces()
            let name = T.ident == n.kind ? convertIdent(Array(image(n))) : Array(image(n))
            var text = "attr(" + HTMLMediaQueryDatatype.string(name[...])
            var typeName: [UInt16]?
            let k = try next()
            if [T.ident, T.and, T.or, T.not, T.only, T.percent].contains(k) {
                let u = try advance()
                let units = T.ident == u.kind ? convertIdent(Array(image(u))) : Array(image(u))
                typeName = units
                text += " " + HTMLMediaQueryDatatype.string(units[...])
                try skipSpaces()
            }
            var fallback: Expression?
            if T.comma == (try next()) {
                try consume(T.comma)
                try skipSpaces()
                let e = Expression()
                try term(e)
                fallback = e
            }
            try consume(T.rparen)
            var computed = CssType.string
            if let t = typeName {
                guard let mapped = Parser.attrTypes.first(where: { identEquals(t, $0.0) })?.1 else {
                    throw Interrupt.runtime(nil)
                }
                computed = mapped
            }
            if let fb = fallback?.values.first, fb.type != computed {
                let fbType = fb.type
                if CssType.number == fbType {
                    // checkEqualsZero(ac, ""): a CssNumber prints itself into
                    // the message's arguments, then must be zero; a calc() is
                    // zero; a math function only warns
                    switch fb {
                    case .number(let num, _, _):
                        if fb.textThrows {
                            throw Interrupt.runtime(nil)
                        }
                        if !num.isZero {
                            throw Interrupt.parse(.invalid(Message.zero))
                        }
                    case .calc:
                        if fb.textThrows {
                            throw Interrupt.runtime(nil)
                        }
                    case .variable(_, _, let f), .env(_, _, let f):
                        if let v = f?.values.first, 1 == f?.count, !v.isZero {
                            throw Interrupt.parse(.invalid(Message.zero))
                        }
                    default:
                        break
                    }
                }
                let numeric = [CssType.length, CssType.angle, CssType.frequency, CssType.number, CssType.time]
                if !((CssType.percentage == fbType || CssType.number == fbType) && numeric.contains(computed)) {
                    if fb.messageThrows {
                        throw Interrupt.runtime(nil)
                    }
                    let definition = typeName.map { HTMLMediaQueryDatatype.string($0[...]) } ?? "null"
                    throw Interrupt.parse(.invalid(Message.typeValueMismatch(fb.text, definition)))
                }
            }
            return .attr(text, computed, fallback)
        }

        /// CssAttr.typeMap (values/CssAttr.java:27-60).
        static let attrTypes: [(String, Int)] = {
            var table: [(String, Int)] = [("color", CssType.color), ("string", CssType.string), ("url", CssType.url),
                                          ("integer", CssType.number), ("number", CssType.number),
                                          ("%", CssType.percentage)]
            for s in ["length", "em", "ex", "ch", "rem", "vw", "vh", "vmin", "vmax", "mm", "cm", "q", "in", "pt", "pc", "px"] {
                table.append((s, CssType.length))
            }
            for s in ["angle", "deg", "rad", "grad", "turn"] {
                table.append((s, CssType.angle))
            }
            for s in ["time", "ms", "s"] {
                table.append((s, CssType.time))
            }
            for s in ["frequency", "hz", "khz"] {
                table.append((s, CssType.frequency))
            }
            return table
        }()

        /// functionvar (CssParser.jj:3971-4006): var( --name ( "," expr )* );
        /// its type is its fallback's when that's one value.
        func functionVar() throws -> Value {
            try enter(2)
            defer {
                leave(2)
            }
            try consume(T.functionVar)
            try skipSpaces()
            let n = try consume(T.dashedIdent)
            let text = "var(" + HTMLMediaQueryDatatype.string(convertIdent(Array(image(n)))[...])
            var fallback: Expression?
            while T.comma == (try next()) {
                try consume(T.comma)
                try skipSpaces()
                do {
                    let e = try expr()
                    if let f = fallback {
                        for v in e.values {
                            f.add(v)
                        }
                    } else {
                        fallback = e
                    }
                } catch Interrupt.parse {
                    try skipToMatchingParen()
                }
            }
            try skipSpaces()
            try consume(T.rparen)
            var type = CssType.variable
            if let f = fallback, 1 == f.count {
                type = f.values[0].type
            }
            return .variable(text, type, fallback)
        }

        /// functionenv (CssParser.jj:3940-3969): env( name term* ( "," expr )? ).
        func functionEnv() throws -> Value {
            try enter(2)
            defer {
                leave(2)
            }
            try consume(T.functionEnv)
            try skipSpaces()
            let n = try consume(T.ident)
            try skipSpaces()
            let name = HTMLMediaQueryDatatype.string(convertIdent(Array(image(n)))[...])
            let numbers = Expression()
            while try lookahead(1, { try self.scanTerm() }) {
                try term(numbers)
            }
            var declaration: Expression?
            if T.comma == (try next()) {
                try consume(T.comma)
                try skipSpaces()
                do {
                    declaration = try expr()
                } catch Interrupt.parse {
                    try skipToMatchingParen()
                }
            }
            try consume(T.rparen)
            // env.setNumberExp(e) (CssParser.jj:3960, values/CssEnv.java:
            // 138-154): every term after the name must be a number (Case
            // 554591 review), an InvalidParamException printing the value
            for v in numbers.values where CssType.number != v.type {
                throw v.messageThrows ? Interrupt.runtime(nil) : Interrupt.parse(.invalid(Message.value(v.text, "env()")))
            }
            var type = CssType.env
            if HTMLMediaQueryDatatype.envLengths.contains(name) {
                type = CssType.length
                // CssEnv.getType() (values/CssEnv.java:50-87), which the
                // caller asks at once (setValue, CssCalc's constructor, the
                // divisor test): a known length variable's one-value
                // fallback of another type is a plain error, unless it is a
                // number that is zero. Not for a color or gradient taken on
                // trust: upstream's parser may have thrown on it, and the
                // catch above would then have left no fallback to check
                // ("env(safe-area-inset-top, light-dark())" is valid in a
                // custom property; Case 554591 review)
                if let d = declaration, 1 == d.count {
                    let v = d.values[0]
                    if CssType.length != v.type && !(CssType.number == v.type && v.checkableIsZero) && !v.isOnTrust {
                        if v.messageThrows {
                            throw Interrupt.runtime(nil)
                        }
                        try recordPlain(Message.value(v.text, "env(" + name + ")"))
                    }
                }
            } else if let d = declaration, 1 == d.count {
                type = d.values[0].type
            }
            var text = "env(" + name
            if numbers.count > 0 {
                text += " " + numbers.text
            }
            return .env(text, type, declaration)
        }

        /// skip_to_matching_paren (CssParser.jj:4233-4292).
        func skipToMatchingParen() throws {
            var nesting = 1
            while nesting > 0 {
                let tok = try peek(1)
                if T.eof == tok.kind {
                    break
                }
                if T.lparen == tok.kind || T.function == tok.kind || (tok.kind >= 130 && tok.kind <= T.functionEnv) {
                    nesting += 1
                } else if T.rparen == tok.kind {
                    nesting -= 1
                    if 0 == nesting {
                        break
                    }
                }
                try advance()
            }
        }

        // MARK: calc() and the math functions

        /// mathcalc (CssParser.jj:3707-3731).
        func mathCalc() throws -> Value {
            try consume(T.functionCalc)
            try skipSpaces()
            let v = try mathSum()
            try skipSpaces()
            try consume(T.rparen)
            let c: Calc
            if case .calc(let inner) = v {
                c = inner
            } else {
                c = Calc(v)
            }
            try validate(c)
            c.implicitFunction = false
            return .calc(c)
        }

        /// mathsum (CssParser.jj:3733-3766).
        func mathSum() throws -> Value {
            var levels = 0
            defer {
                depth -= levels
            }
            try enter(2)
            defer {
                leave(2)
            }
            let v1 = try mathProduct()
            var c = Calc(v1)
            var concat = false
            while try lookahead(2, { try self.scanSumOperator() }) {
                var spaces = 0
                var o: Token
                if T.plus == (try next()) {
                    o = try advance()
                } else {
                    while T.s == (try next()) {
                        try consume(T.s)
                        spaces += 1
                    }
                    o = try consume(T.minus)
                }
                if o.end - o.start < 2 && 0 == spaces {
                    throw Interrupt.parse(.plain(Message.calcWhitespace))
                }
                try consume(T.s)
                try skipSpaces()
                let v2 = try mathProduct()
                let symbol = UInt16(text[o.end - 1])
                if concat {
                    // a level deeper, as CssCalc(ac, c) nests the sum so far
                    try enter(1)
                    levels += 1
                    let nc = Calc(.calc(c))
                    try addRightSide(nc, symbol, v2)
                    c = nc
                } else {
                    try addRightSide(c, symbol, v2)
                    concat = true
                }
            }
            return .calc(c)
        }

        /// The LOOKAHEAD(2) of mathsum's and calcnumbersum's loops: (
        /// <PLUS> | ( <S> )* <MINUS> ) ( <S> )+ — "-" can't carry its
        /// whitespace as "+" does. So "calc(100px+2em)", whose "+" has no
        /// space after it, ends the sum there, and calc() then fails on
        /// the "+" with a plain syntax error.
        func scanSumOperator() throws -> Bool {
            let op = try scanFirst([
                { try self.scan(T.plus) },
                {
                    try self.scanSpaces()
                    return try self.scan(T.minus)
                }
            ])
            guard op else {
                return false
            }
            guard try scan(T.s) else {
                return false
            }
            try scanSpaces()
            return try scanMathProduct()
        }

        /// mathproduct (CssParser.jj:3769-3818).
        func mathProduct() throws -> Value {
            var levels = 0
            defer {
                depth -= levels
            }
            let v1 = try mathUnit()
            var c = Calc(v1)
            var concat = false
            // jj_3_27: ( <S> )* then "*" S* mathunit or DIV S* (calcnumbervalue
            // | functionvar | functionenv), on into the operand (Case 554591
            // review): with no space around the operator its operand is the
            // second token, so "1s/1px" ends the product at "1s" and the
            // enclosing sum or list reports its type clash first
            while try lookahead(2, {
                try self.scanSpaces()
                return try self.scanFirst([
                    {
                        guard try self.scan(T.any) else {
                            return false
                        }
                        try self.scanSpaces()
                        return try self.scanMathUnit()
                    },
                    {
                        guard try self.scan(T.div) else {
                            return false
                        }
                        try self.scanSpaces()
                        return try self.scanFirst([
                            { try self.scanCalcNumberValue() },
                            { try self.scanVar() },
                            { try self.scanEnv() }
                        ])
                    }
                ])
            }) {
                try skipSpaces()
                let o = try advance()
                try skipSpaces()
                let v2: Value
                if T.any == o.kind {
                    v2 = try mathUnit()
                } else {
                    let k = try next()
                    if T.functionVar == k {
                        v2 = try functionVar()
                        if CssType.variable == v2.type {
                            c.containsVariable = true
                        }
                    } else if T.functionEnv == k {
                        v2 = try functionEnv()
                        if CssType.env == v2.type {
                            c.containsVariable = true
                        }
                    } else {
                        v2 = try calcNumberValue()
                    }
                }
                let symbol: UInt16 = T.any == o.kind ? 0x2A : 0x2F
                if concat {
                    // a level deeper, as CssCalc(ac, c) nests the sum so far
                    try enter(1)
                    levels += 1
                    let nc = Calc(.calc(c))
                    if c.containsVariable {
                        nc.containsVariable = true
                    }
                    try addRightSide(nc, symbol, v2)
                    c = nc
                } else {
                    try addRightSide(c, symbol, v2)
                    concat = true
                }
            }
            return .calc(c)
        }

        /// calcnumbervalue (CssParser.jj:3820-3833).
        func calcNumberValue() throws -> Value {
            if T.lparen == (try next()) {
                try consume(T.lparen)
                try skipSpaces()
                let v = try calcNumberSum()
                try skipSpaces()
                try consume(T.rparen)
                if case .calc(let c) = v {
                    c.hasParen = true
                }
                return v
            }
            let op = try unaryOperator()
            let k = try next()
            guard T.number == k || T.ident == k else {
                throw Interrupt.parse(.syntax)
            }
            let n = try advance()
            return try calcNumber(signed(op, n))
        }

        /// calcnumbersum (CssParser.jj:3835-3865).
        func calcNumberSum() throws -> Value {
            var levels = 0
            defer {
                depth -= levels
            }
            try enter(2)
            defer {
                leave(2)
            }
            let v1 = try calcNumberProduct()
            var c = Calc(v1)
            var concat = false
            while try lookahead(2, { try self.scanSumOperator() }) {
                var spaces = 0
                var o: Token
                if T.plus == (try next()) {
                    o = try advance()
                } else {
                    while T.s == (try next()) {
                        try consume(T.s)
                        spaces += 1
                    }
                    o = try consume(T.minus)
                }
                if o.end - o.start < 2 && 0 == spaces {
                    throw Interrupt.parse(.plain(Message.calcWhitespace))
                }
                try consume(T.s)
                try skipSpaces()
                let v2 = try calcNumberProduct()
                let symbol = UInt16(text[o.end - 1])
                if concat {
                    // a level deeper, as CssCalc(ac, c) nests the sum so far
                    try enter(1)
                    levels += 1
                    let nc = Calc(.calc(c))
                    try addRightSide(nc, symbol, v2)
                    c = nc
                } else {
                    try addRightSide(c, symbol, v2)
                    concat = true
                }
            }
            return .calc(c)
        }

        /// calcnumberproduct (CssParser.jj:3867-3885).
        func calcNumberProduct() throws -> Value {
            var levels = 0
            defer {
                depth -= levels
            }
            let v1 = try calcNumberValue()
            var c = Calc(v1)
            var concat = false
            // jj_3_29: ( <S> )* ( DIV | "*" ) ( <S> )* calcnumbervalue
            while try lookahead(2, {
                try self.scanSpaces()
                guard try self.scan(any: [T.div, T.any]) else {
                    return false
                }
                try self.scanSpaces()
                return try self.scanCalcNumberValue()
            }) {
                try skipSpaces()
                let o = try advance()
                try skipSpaces()
                let v2 = try calcNumberValue()
                let symbol: UInt16 = T.any == o.kind ? 0x2A : 0x2F
                if concat {
                    // a level deeper, as CssCalc(ac, c) nests the sum so far
                    try enter(1)
                    levels += 1
                    let nc = Calc(.calc(c))
                    try addRightSide(nc, symbol, v2)
                    c = nc
                } else {
                    try addRightSide(c, symbol, v2)
                    concat = true
                }
            }
            return .calc(c)
        }

        /// CssNumber.set on a NUMBER or an IDENT in calc(): the constants,
        /// the relative-color channels, and otherwise BigDecimal (whose
        /// NumberFormatException is swallowed by media()).
        func calcNumber(_ s: [UInt16]) throws -> Value {
            var body = s[...]
            var negative = false
            if let first = body.first, 0x2D == first || 0x2B == first {
                negative = 0x2D == first
                body = body.dropFirst()
            }
            let lower = HTMLMediaQueryDatatype.string(javaLowercase(Array(body))[...])
            let one = Num(negative: negative, digits: [1], scale: 0, source: "1")
            let sign = negative ? "-" : ""
            switch lower {
            case "pi", "e":
                return .number(one, isInt: false, special: sign + lower)
            case "infinity":
                return .number(one, isInt: true, special: sign + "infinity")
            case "a", "alpha", "b", "c", "g", "h", "l", "r", "s", "w":
                return .number(one, isInt: true, special: sign + lower)
            case "nan":
                return .number(one, isInt: false, special: sign + "NaN")
            default:
                // new BigDecimal(val) on the rest, then negated: BigDecimal
                // reads any BMP decimal digit through Character.digit, so
                // "٣" is 3 (Case 554591 review); it prints in ASCII
                let digits = HTMLMediaQueryDatatype.asciiDigits(Array(body))
                guard var n = Num.parse(digits) else {
                    throw Interrupt.runtime(Num.failure(digits))
                }
                if negative && !n.digits.isEmpty {
                    n.negative.toggle()
                }
                n.source = (negative ? "-" : "") + HTMLMediaQueryDatatype.string(digits[...])
                return .number(n, isInt: !digits.contains(0x2E), special: nil)
            }
        }

        /// mathunit (CssParser.jj:3887-3910).
        func mathUnit() throws -> Value {
            let k = try next()
            switch k {
            case T.lparen:
                try consume(T.lparen)
                try skipSpaces()
                let v = try mathSum()
                try skipSpaces()
                try consume(T.rparen)
                if case .calc(let c) = v {
                    c.hasParen = true
                }
                return v
            case T.functionCalc:
                return try mathCalc()
            case T.functionMath1, T.functionMath2, T.functionMathN, T.functionRound:
                return .math(try mathFunction())
            case T.functionClamp:
                return .math(try mathClamp())
            case T.functionAttr:
                return try attr()
            case T.functionVar:
                return try functionVar()
            case T.functionEnv:
                return try functionEnv()
            default:
                let op = try unaryOperator()
                let k2 = try next()
                switch k2 {
                case T.number, T.ident:
                    let n = try advance()
                    return try calcNumber(signed(op, n))
                case T.percentage, T.relFontLength, T.relViewLength, T.absolutLength, T.flex, T.angle, T.time, T.freq:
                    guard let v = try unitValue(k2, op) else {
                        throw Interrupt.parse(.syntax)
                    }
                    return v
                default:
                    throw Interrupt.parse(.syntax)
                }
            }
        }

        /// CssCalc.addRightSide (values/CssCalc.java:96-129).
        func addRightSide(_ c: Calc, _ op: UInt16, _ value: Value) throws {
            c.op = op
            c.val2 = value
            if CssType.variable == value.type {
                c.containsVariable = true
            }
            try computeType(c)
        }

        func validate(_ c: Calc) throws {
            try computeType(c)
        }

        /// A CssCalc error: every one prints the calc() into its message
        /// (toStringUnprefixed()), and when a number in it can't be printed
        /// that throws first, a RuntimeException media() swallows.
        func calcError(_ c: Calc, _ message: String) -> Interrupt {
            if c.val1.textThrows || (c.val2?.textThrows ?? false) {
                return Interrupt.runtime(nil)
            }
            return Interrupt.parse(.invalid(message))
        }

        /// _checkAcceptableType (CssCalc.java:150-162).
        func checkAcceptable(_ type: Int, _ c: Calc) throws {
            if CssType.percentage != type && CssType.length != type && CssType.number != type
                && CssType.angle != type && CssType.frequency != type && CssType.time != type {
                // "Invalid type: “…”" quotes the calc(), so the message's
                // own length counts too
                if c.val1.messageThrows || (c.val2?.messageThrows ?? false) {
                    throw Interrupt.runtime(nil)
                }
                throw calcError(c, Message.invalidType(c.unprefixed))
            }
        }

        /// The number a value stands for, as getNumber() finds it.
        func numberIsZero(_ value: Value) throws -> Bool {
            switch value {
            case .number(let n, _, _):
                return n.isZero
            case .calc(let c):
                // CssCalc.getNumber: val1's or val2's number
                if CssType.number == c.computedType {
                    if CssType.number == c.val1.type {
                        return try numberIsZero(c.val1)
                    }
                    if let v2 = c.val2, CssType.number == v2.type {
                        return try numberIsZero(v2)
                    }
                }
                throw Interrupt.runtime(nil)
            case .math(let m):
                if CssType.number == m.computedType {
                    for v in m.values where CssType.number == v.type {
                        return try numberIsZero(v)
                    }
                }
                throw Interrupt.runtime(nil)
            case .variable(_, let type, let fallback), .env(_, let type, let fallback):
                // CssVariable.getNumber() and CssEnv.getNumber() give their
                // one fallback (declaration) value's number when their type
                // is number, and throw ClassCastException otherwise (Case
                // 554591 review): so var(--x, 0) is a zero that may be added
                // to a length, and dividing by it is a division by zero
                if CssType.number == type, let f = fallback, 1 == f.count {
                    return try numberIsZero(f.values[0])
                }
                throw Interrupt.runtime(nil)
            case .attr:
                // CssAttr.getNumber() always throws ClassCastException
                throw Interrupt.runtime(nil)
            default:
                throw Interrupt.runtime(nil)
            }
        }

        /// _computeResultingType (CssCalc.java:164-238).
        func computeType(_ c: Calc) throws {
            if c.containsVariable {
                return
            }
            guard let v2 = c.val2 else {
                let t = c.val1.type
                try checkAcceptable(t, c)
                c.computedType = t
                return
            }
            let t1 = c.val1.type
            let t2 = v2.type
            switch c.op {
            case 0x2A:
                if CssType.number == t1 {
                    try checkAcceptable(t2, c)
                    c.computedType = t2
                } else if CssType.number == t2 {
                    try checkAcceptable(t1, c)
                    c.computedType = t1
                } else {
                    throw calcError(c, Message.operandNumber)
                }
            case 0x2F:
                if CssType.number != t2 {
                    throw calcError(c, Message.divisorType)
                }
                if try numberIsZero(v2) {
                    throw calcError(c, Message.divZero)
                }
                try checkAcceptable(t1, c)
                c.computedType = t1
            default:
                if t1 == t2 {
                    try checkAcceptable(t1, c)
                    c.computedType = t1
                } else if CssType.percentage == t1 {
                    try checkAcceptable(t2, c)
                    c.computedType = t2
                } else if CssType.percentage == t2 {
                    try checkAcceptable(t1, c)
                    c.computedType = t1
                } else if CssType.number == t1, try numberIsZero(c.val1) {
                    try checkAcceptable(t2, c)
                    c.computedType = t2
                } else if CssType.number == t2, try numberIsZero(v2) {
                    try checkAcceptable(t1, c)
                    c.computedType = t1
                } else {
                    throw calcError(c, Message.incompatibleTypes)
                }
            }
        }

        /// mathfunction (CssParser.jj:3605-3613) and its four forms.
        func mathFunction() throws -> MathFunction {
            try enter(1)
            defer {
                leave(1)
            }
            let n = try advance()
            let prefix = HTMLMediaQueryDatatype.string(image(n)).lowercased()
            let m = MathFunction(prefix: prefix)
            try skipSpaces()
            switch n.kind {
            case T.functionRound:
                // LOOKAHEAD(2) n=<IDENT> (CssParser.jj:3642): the generated
                // jj_3_25 scans the IDENT alone, so any identifier first
                // takes this branch, and "round(pi*1px, 1px)" then fails at
                // the "*" (Case 554591 review)
                if try lookahead(2, { try self.scan(T.ident) }) {
                    let id = try consume(T.ident)
                    m.values.append(.ident(convertIdent(Array(image(id)))))
                    try mathComputeType(m, final: false)
                } else {
                    try mathAdd(m, try mathSum(), first: true)
                }
                try skipSpaces()
                while T.comma == (try next()) {
                    try consume(T.comma)
                    try skipSpaces()
                    try mathAdd(m, try mathSum(), first: false)
                    try skipSpaces()
                }
            case T.functionMath1:
                try mathAdd(m, try mathSum(), first: true)
                try skipSpaces()
            case T.functionMath2:
                try mathAdd(m, try mathSum(), first: true)
                try skipSpaces()
                if T.comma == (try next()) {
                    try consume(T.comma)
                    try skipSpaces()
                    try mathAdd(m, try mathSum(), first: false)
                    try skipSpaces()
                }
            default:
                try mathAdd(m, try mathSum(), first: true)
                try skipSpaces()
                while T.comma == (try next()) {
                    try consume(T.comma)
                    try skipSpaces()
                    try mathAdd(m, try mathSum(), first: false)
                    try skipSpaces()
                }
            }
            try consume(T.rparen)
            try mathComputeType(m, final: true)
            return m
        }

        /// mathclamp (CssParser.jj:3681-3705).
        func mathClamp() throws -> MathFunction {
            try enter(1)
            defer {
                leave(1)
            }
            try consume(T.functionClamp)
            try skipSpaces()
            var values = [Value]()
            for index in 0..<3 {
                values.append(try mathSum())
                try skipSpaces()
                if index < 2 {
                    try consume(T.comma)
                    try skipSpaces()
                }
            }
            try consume(T.rparen)
            let m = MathFunction(prefix: "clamp(")
            for v in values {
                m.values.append(v)
                try mathComputeType(m, final: false)
            }
            try mathComputeType(m, final: true)
            return m
        }

        /// The CssMathFunction constructor with its first value (its type
        /// check's exception ignored), or addValue.
        func mathAdd(_ m: MathFunction, _ value: Value, first: Bool) throws {
            m.values.append(value)
            if first && 1 == m.values.count {
                m.computedType = value.type
                return
            }
            try mathComputeType(m, final: false)
        }

        func mathAcceptable(_ type: Int, _ m: MathFunction) throws -> Int {
            if CssType.percentage != type && CssType.length != type && CssType.number != type
                && CssType.angle != type && CssType.frequency != type && CssType.time != type {
                throw m.values.contains(where: { $0.messageThrows }) ? Interrupt.runtime(nil)
                    : Interrupt.parse(.invalid(Message.invalidType(m.unprefixed)))
            }
            return type
        }

        /// _computeResultingType (CssMathFunction.java:118-190) and its
        /// helpers.
        func mathComputeType(_ m: MathFunction, final: Bool) throws {
            // incompatibletypes prints the function (toString()), which
            // throws first for a number Java can't print; looked at only
            // when it's thrown, as this runs at every value of a list
            var incompatible: Interrupt {
                m.values.contains(where: { $0.textThrows }) ? Interrupt.runtime(nil)
                    : Interrupt.parse(.invalid(Message.incompatibleTypes))
            }
            let unrecognized = Interrupt.parse(.invalid(Message.unrecognize))
            func type(_ i: Int) -> Int {
                m.values[i].type
            }
            let lengthy: Set<Int> = [CssType.percentage, CssType.length, CssType.number]
            switch m.prefix {
            case "clamp(", "min(", "max(", "hypot(":
                // _computeResultingTypeList (CssMathFunction.java:420-462),
                // folding only the values not folded yet
                while m.listFolded < m.values.count {
                    let v = m.values[m.listFolded]
                    m.listFolded += 1
                    if m.listFirst {
                        m.listType = v.type
                        if CssType.variable == m.listType {
                            m.hasVariable = true
                            continue
                        }
                        _ = try mathAcceptable(m.listType, m)
                        m.computedType = m.listType
                        m.listFirst = false
                        m.listPrevious = v
                        continue
                    }
                    if m.listType == v.type {
                        m.listPrevious = v
                        continue
                    }
                    if CssType.percentage == m.listType {
                        m.listType = try mathAcceptable(v.type, m)
                        m.listPrevious = v
                        continue
                    }
                    if CssType.percentage == v.type {
                        continue
                    }
                    if CssType.number == m.listType, let p = m.listPrevious, try numberIsZero(p) {
                        m.listType = try mathAcceptable(v.type, m)
                        m.listPrevious = v
                        continue
                    }
                    if CssType.number == v.type, try numberIsZero(v) {
                        continue
                    }
                    if CssType.variable == v.type || CssType.variable == v.rawType {
                        m.hasVariable = true
                        continue
                    }
                    throw incompatible
                }
                m.computedType = m.listType
            case "sin(", "cos(", "tan(", "asin(", "acos(", "atan(":
                guard final else {
                    return
                }
                if m.values.count > 1 {
                    throw unrecognized
                }
                let t = type(0)
                if CssType.variable == t || CssType.number == t || CssType.angle == t {
                    m.computedType = m.prefix.hasPrefix("a") ? CssType.angle : CssType.number
                } else {
                    throw incompatible
                }
            case "exp(", "sqrt(":
                if m.values.count > 1 {
                    throw unrecognized
                }
                let t = type(0)
                if CssType.number == t || CssType.variable == t {
                    m.computedType = t
                } else {
                    throw incompatible
                }
            case "pow(":
                guard final else {
                    return
                }
                if 2 != m.values.count {
                    throw unrecognized
                }
                let t1 = type(0)
                let t2 = type(1)
                if CssType.number == t1 && CssType.number == t2 {
                    m.computedType = CssType.number
                } else if CssType.variable == t1 && (CssType.number == t2 || CssType.variable == t2) {
                    m.computedType = t2
                } else if CssType.variable == t2 && CssType.number == t1 {
                    m.computedType = t1
                } else {
                    throw incompatible
                }
            case "log(":
                guard final else {
                    return
                }
                if m.values.count > 2 {
                    throw unrecognized
                }
                let t = type(0)
                if CssType.number == t || CssType.variable == t {
                    m.computedType = t
                } else {
                    throw incompatible
                }
                if m.values.count > 1 {
                    let t2 = type(1)
                    if CssType.number != t2 && CssType.variable != t2 {
                        throw incompatible
                    }
                }
            case "mod(", "rem(":
                guard final else {
                    return
                }
                if 2 != m.values.count {
                    throw unrecognized
                }
                let t1 = type(0)
                let t2 = type(1)
                if CssType.variable == t1 || CssType.variable == t2 {
                    m.computedType = CssType.variable != t1 ? t1 : t2
                } else if t1 == t2 {
                    m.computedType = t1
                } else {
                    throw incompatible
                }
            case "abs(":
                if m.values.count > 1 {
                    throw unrecognized
                }
                m.computedType = type(0)
            case "atan2(":
                guard final else {
                    return
                }
                if 2 != m.values.count {
                    throw unrecognized
                }
                let t1 = type(0)
                let t2 = type(1)
                if CssType.variable == t1 || CssType.variable == t2 {
                    if CssType.variable != t1 && !lengthy.contains(t1) {
                        throw incompatible
                    } else if CssType.variable == t1 && CssType.variable != t2 && !lengthy.contains(t2) {
                        throw incompatible
                    }
                    m.computedType = CssType.angle
                    return
                }
                if !lengthy.contains(t1) || t1 != t2 {
                    throw incompatible
                }
                m.computedType = CssType.angle
            case "sign(":
                guard final else {
                    return
                }
                if m.values.count > 1 {
                    throw unrecognized
                }
                m.computedType = CssType.number
            case "round(":
                guard final else {
                    return
                }
                let count = m.values.count
                if count < 2 || count > 3 {
                    throw unrecognized
                }
                var t1: Int
                var t2: Int
                if 2 == count {
                    t1 = type(0)
                    if CssType.ident == t1 {
                        // "parsing artefact" (CssMathFunction.java:337-344):
                        // an identifier counts as a number when CssNumber.set
                        // takes it, with its sign stripped and BigDecimal's
                        // digits, as calcNumber does it (so -pi and \31 do,
                        // Case 554591 review); its exception is ignored
                        // values.get(0).getIdent(), whose ClassCastException
                        // the catch ignores too; a var() with an identifier
                        // fallback answers with that ("round(var(--x, pi),
                        // 1)")
                        if let units = m.values[0].javaIdent, nil != (try? calcNumber(units)) {
                            t1 = CssType.number
                        }
                    } else if CssType.variable == t1 {
                        t2 = type(1)
                        if CssType.variable == t2 {
                            m.computedType = t1
                            return
                        }
                        if !lengthy.contains(t2) {
                            throw incompatible
                        }
                        m.computedType = t2
                        return
                    } else if !lengthy.contains(t1) {
                        throw incompatible
                    }
                    t2 = type(1)
                } else {
                    // v.getType() != CSS_IDENT, then isAllowedRounding(v
                    // .getIdent()) (CssMathFunction.java:368-375): a var()
                    // with an identifier fallback names its strategy, and a
                    // value of identifier type without getIdent() throws
                    // ClassCastException
                    guard CssType.ident == m.values[0].type else {
                        throw incompatible
                    }
                    guard let units = m.values[0].javaIdent else {
                        throw Interrupt.runtime(nil)
                    }
                    let strategies = ["nearest", "up", "down", "to-zero"]
                    if !strategies.contains(where: { identEquals(units, $0) }) {
                        throw incompatible
                    }
                    t1 = type(1)
                    t2 = type(2)
                }
                if CssType.variable == t1 {
                    if CssType.variable == t2 {
                        m.computedType = t1
                        return
                    }
                    if !lengthy.contains(t2) {
                        throw incompatible
                    }
                    m.computedType = t2
                    return
                } else if CssType.variable == t2 {
                    if !lengthy.contains(t1) {
                        throw incompatible
                    }
                    m.computedType = t1
                    return
                }
                if t1 == t2 && lengthy.contains(t1) {
                    m.computedType = t1
                } else {
                    throw incompatible
                }
            default:
                throw unrecognized
            }
        }

        // MARK: What a value can inject after closing its rule

        /// ruleSet (CssParser.jj:2334-2420), for a rule that follows a
        /// value that closed its @media rule early: selectors, then a
        /// block of declarations, whose syntax is checked (declaration())
        /// but whose properties aren't, since that needs the CSS property
        /// database: a bad property there goes unreported. A ParseException
        /// is recorded after skipStatement; a TokenMgrError too, with its
        /// own message (CssParser.java's ruleSet ends in `catch
        /// (TokenMgrError e) { addError(new ParseException(e.getMessage()),
        /// skipStatement()); }`).
        func ruleSet() throws {
            do {
                do {
                    try selectorList()
                    try consume(T.lbrace)
                    try skipSpaces()
                    try declarations()
                    try consume(T.rbrace)
                    try skipSpaces()
                } catch Interrupt.parse(let failure) {
                    _ = try skipStatement()
                    try record(failure)
                }
            } catch Interrupt.tokenMgr(let start, let kill) {
                let message = lexicalError(start: start, kill: kill)
                _ = try skipStatement()
                try record(.plain(message))
            }
        }

        /// TokenMgrError.LexicalErr (TokenMgrError.java:106-113), with
        /// SimpleCharStream's line and column (a tab counts as one).
        func lexicalError(start: Int, kill: Int) -> String {
            var line = 1
            var column = 0
            var previousLF = false
            var previousCR = false
            var index = 0
            while index <= kill && index < text.count {
                let c = text[index]
                column += 1
                if previousLF {
                    previousLF = false
                    line += 1
                    column = 1
                } else if previousCR {
                    previousCR = false
                    if 0x0A == c {
                        previousLF = true
                    } else {
                        line += 1
                        column = 1
                    }
                }
                if 0x0D == c {
                    previousCR = true
                } else if 0x0A == c {
                    previousLF = true
                }
                index += 1
            }
            func escapes(_ units: ArraySlice<UInt16>) -> String {
                var out = ""
                for ch in units {
                    switch ch {
                    case 0x08:
                        out += "\\b"
                    case 0x09:
                        out += "\\t"
                    case 0x0A:
                        out += "\\n"
                    case 0x0C:
                        out += "\\f"
                    case 0x0D:
                        out += "\\r"
                    case 0x22:
                        out += "\\\""
                    case 0x27:
                        out += "\\'"
                    case 0x5C:
                        out += "\\\\"
                    default:
                        if ch < 0x20 || ch > 0x7E {
                            let hex = String(ch, radix: 16)
                            out += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
                        } else {
                            out.append(Character(Unicode.Scalar(UInt8(ch))))
                        }
                    }
                }
                return out
            }
            guard kill < text.count else {
                return "Lexical error at line \(line), column \(column).  Encountered: <EOF>"
            }
            let current = text[kill]
            var message = "Lexical error at line \(line), column \(column).  Encountered: '"
                + escapes(text[kill...kill]) + "' (\(current)),"
            if kill > start {
                message += " after prefix \"" + escapes(text[start..<kill]) + "\""
            }
            return message
        }

        /// selector_list: a lenient reading of CSS selectors, enough for
        /// what a media attribute might hold: compound selectors of
        /// identifiers, "*", "#id", ".class", "[...]", ":pseudo" and
        /// "::pseudo", joined by combinators and commas.
        func selectorList() throws {
            try selector()
            while T.comma == (try next()) {
                try consume(T.comma)
                try skipSpaces()
                try selector()
            }
        }

        /// complex_selector (CssParser.jj:2574-2620): compound_selector (
        /// LOOKAHEAD(2) ( combinator() )? compound_selector )*. The
        /// combinator is optional, so "a*" and "a/**/b" are two compounds
        /// with none (a comment is a special token); and the loop's
        /// two-token lookahead takes an S only when a compound selector
        /// follows it, so an S before "{" is left for ruleSet to fail on, as
        /// after "not ^" (Case 554591 review).
        func selector() throws {
            try compoundSelector()
            while try selectorContinues() {
                let k = try next()
                if T.plus == k || T.greater == k || T.tilde == k || T.twoPipes == k {
                    // combinator(): ( PLUS | GREATER | TILDE | TWOPIPES ) S*
                    try advance()
                    try skipSpaces()
                } else if T.s == k {
                    // or S+
                    try skipSpaces()
                }
                try compoundSelector()
            }
        }

        /// The loop's LOOKAHEAD(2): an optional combinator, then the first
        /// token of a compound selector (or, after a combinator token, an S).
        func selectorContinues() throws -> Bool {
            let k1 = try peek(1).kind
            if T.plus == k1 || T.greater == k1 || T.tilde == k1 || T.twoPipes == k1 {
                let k2 = try peek(2).kind
                return T.s == k2 || Parser.compoundStarts.contains(k2)
            }
            if T.s == k1 {
                // S+: a second S (after a bad character's resume) uses up the
                // two-token budget too
                let k2 = try peek(2).kind
                return T.s == k2 || Parser.compoundStarts.contains(k2)
            }
            return Parser.compoundStarts.contains(k1)
        }

        /// What can continue a compound selector, for the tokens
        /// compound_selector's LOOKAHEAD(4) fetches.
        static let selectorParts: Set<Int> = [
            T.ident, T.and, T.or, T.not, T.only, T.any, T.hashIdent, T.hash, T.dot, T.lbracket, T.colon,
            T.pseudoElement, T.pipe, T.relFontLength, T.relViewLength, T.absolutLength, T.angle, T.time, T.freq,
            T.resolution, T.dimen, T.function
        ]

        /// What can begin a compound selector.
        static let compoundStarts: Set<Int> = selectorParts.subtracting([T.function])

        func compoundSelector() throws {
            // compound_selector begins with LOOKAHEAD(4) (CssParser.jj:
            // 2668), whose scan fetches up to four tokens of the selector,
            // and so meets a bad character among them before anything is
            // checked
            var ahead = 1
            while ahead <= 4 {
                let t = try peek(ahead)
                if !Parser.selectorParts.contains(t.kind) {
                    break
                }
                ahead += 1
            }
            var any = false
            // type_selector's namespace prefix, ( LOOKAHEAD(2) ( ident() |
            // "*" )? "|" )? (CssParser.jj:2774-2830): "|a" and "*|a" need
            // no @namespace, and a named prefix can never be declared in a
            // media value, so it is upstream's "Undefined namespace" (Case
            // 554591 review)
            let k0 = try next()
            var prefixed = false
            if T.pipe == k0 {
                try advance()
                prefixed = true
            } else if [T.ident, T.and, T.or, T.not, T.only, T.any].contains(k0), T.pipe == (try peek(2)).kind {
                let prefix = try advance()
                try advance()
                if T.any != prefix.kind {
                    try record(.plain("Undefined namespace"))
                }
                prefixed = true
            }
            if prefixed {
                let k = try next()
                guard [T.ident, T.and, T.or, T.not, T.only, T.any].contains(k) else {
                    throw Interrupt.parse(.syntax)
                }
                try advance()
                any = true
            }
            while true {
                let k = try next()
                switch k {
                case T.ident, T.and, T.or, T.not, T.only, T.any:
                    guard !any else {
                        return
                    }
                    try advance()
                case T.hashIdent:
                    try advance()
                case T.hash:
                    // hash() (CssParser.jj, after id_dim): a HASH that isn't
                    // a HASHIDENT ("#1", "#-1") is new ParseException(
                    // "Invalid ID selector"), which ruleSet records (Case
                    // 554591 review: the port once took it as an id)
                    throw Interrupt.parse(.plain("Invalid ID selector"))
                case T.relFontLength, T.relViewLength, T.absolutLength, T.angle, T.time, T.freq, T.resolution,
                     T.dimen:
                    // class_selector's deprecated_class (CssParser.jj:
                    // 2693-2757): a dimension as a class, the CSS1 way
                    let n = try advance()
                    let units = Array(image(n))
                    guard 0x2E == units.first, units.count >= 3 else {
                        throw Interrupt.parse(.plain("Unrecognized "))
                    }
                    let name = Array(units.dropFirst())
                    var escaped = "\\" + String(name[0], radix: 16)
                    if HTMLMediaQueryDatatype.isHex(name[1]) {
                        escaped += " "
                    }
                    escaped += HTMLMediaQueryDatatype.string(name[1...])
                    throw Interrupt.parse(.plain(Message.oldClass(HTMLMediaQueryDatatype.string(name[...]), "." + escaped)))
                case T.dot:
                    try advance()
                    _ = try identToken()
                case T.lbracket:
                    try advance()
                    var nesting = 1
                    while nesting > 0 {
                        let t = try advance()
                        if T.lbracket == t.kind {
                            nesting += 1
                        } else if T.rbracket == t.kind {
                            nesting -= 1
                        } else if T.eof == t.kind {
                            throw Interrupt.parse(.syntax)
                        }
                    }
                case T.colon, T.pseudoElement:
                    let colon = try advance()
                    let k2 = try next()
                    if T.pseudoElement == colon.kind && (T.function == k2 || (k2 >= 130 && k2 <= 156)) {
                        // pseudo_element_selector takes an identifier or
                        // slotted( only (CssParser.jj, pseudo_element_selector)
                        guard 135 == k2 else {
                            throw Interrupt.parse(.syntax)
                        }
                        try advance()
                        try skipToMatchingParen()
                        try consume(T.rparen)
                    } else if T.function == k2 {
                        // ":" FUNCTION S* expression() ")": expression is one
                        // or more of + - NUMBER PERCENTAGE DIMEN STRING ident,
                        // each with S*; then setPseudoFun knows no such
                        // function (the named ones are tokens of their own),
                        // a plain error (Case 554591 review)
                        let f = try advance()
                        try skipSpaces()
                        var terms = 0
                        while [T.plus, T.minus, T.number, T.percentage, T.dimen, T.string, T.ident, T.and, T.or, T.not,
                               T.only].contains(try next()) {
                            try advance()
                            try skipSpaces()
                            terms += 1
                        }
                        if 0 == terms {
                            throw Interrupt.parse(.syntax)
                        }
                        try consume(T.rparen)
                        let fname = javaLowercase(convertIdent(Array(image(f).dropLast())))
                        try recordPlain("Unknown pseudo-element or pseudo-class “:\(HTMLMediaQueryDatatype.string(fname[...]))”")
                    } else if k2 >= 130 && k2 <= 156 {
                        // the functional pseudo-classes with tokens of their
                        // own (:not(, :is(, :nth-child(, ...), read leniently
                        try advance()
                        try skipToMatchingParen()
                        try consume(T.rparen)
                    } else {
                        let n = try identToken()
                        let name = HTMLMediaQueryDatatype.string(
                            javaLowercase(T.ident == n.kind ? convertIdent(Array(image(n))) : Array(image(n)))[...])
                        try checkPseudo(name, element: T.pseudoElement == colon.kind)
                    }
                default:
                    if !any {
                        throw Interrupt.parse(.syntax)
                    }
                    return
                }
                any = true
            }
        }

        /// CssSelectors.addPseudoClass and addPseudoElement (parser/
        /// CssSelectors.java:172-235), with PseudoFactory's CSS3 lists: a
        /// vendor name ("-" first) is only a warning; an unknown
        /// pseudo-class is a plain error, an unknown pseudo-element a
        /// ParseException (pseudo_element_selector rethrows it).
        func checkPseudo(_ name: String, element: Bool) throws {
            if name.hasPrefix("-") {
                return
            }
            if element {
                if !HTMLMediaQueryDatatype.pseudoElements.contains(name) {
                    throw Interrupt.parse(.plain("Unknown pseudo-element or pseudo-class “::\(name)”"))
                }
                return
            }
            if !HTMLMediaQueryDatatype.pseudoClasses.contains(name)
                && !["first-line", "first-letter", "before", "after"].contains(name) {
                try recordPlain("Unknown pseudo-element or pseudo-class “:\(name)”")
            }
        }

        /// declarations (CssParser.jj:3165-3240): declaration? ( ";" S*
        /// declaration? )*.
        func declarations() throws {
            while true {
                let k = try next()
                if T.rbrace == k || T.eof == k {
                    return
                }
                if T.semicolon == k {
                    try advance()
                    try skipSpaces()
                    continue
                }
                try declaration()
                currentProperty = nil
            }
        }

        /// declaration (CssParser.jj:3242-3330): property ":" S* expr?
        /// prio?, with errors meanwhile naming the property (property()
        /// sets currentProperty, CssParser.jj:2263; declarations() clears
        /// it, 2449-2460). A missing value is a plain syntax error; a
        /// ParseException goes to skipAfterExpression, which records it.
        /// The property and its value aren't checked any further: that
        /// would be the CSS property database (handleDeclaration).
        func declaration() throws {
            // a CSS-hack property name (property(), CssParser.jj:2258-2284):
            // one of these tokens right before the name, or a #name, .name
            // or @name; hacks are warnings, so property() returns null and
            // declaration() parses the value and records nothing more, not
            // even a missing value (Case 554591 review)
            var hack = false
            do {
                let k = try next()
                let n: Token
                if Parser.propertyHacks.contains(k) {
                    try advance()
                    n = try identToken()
                    hack = true
                    currentProperty = HTMLMediaQueryDatatype.string(convertIdent(Array(image(n)))[...])
                    try skipSpaces()
                } else if T.hashIdent == k || T.atKeyword == k || T.dot == k {
                    // convertIdent(n.image).substring(1), and no S* after:
                    // the action returns before it
                    if T.dot == k {
                        try advance()
                        n = try identToken()
                    } else {
                        n = try advance()
                    }
                    hack = true
                    currentProperty = HTMLMediaQueryDatatype.string(convertIdent(Array(image(n))).dropFirst())
                } else {
                    if T.dashedIdent == k {
                        n = try advance()
                    } else {
                        n = try identToken()
                    }
                    currentProperty = HTMLMediaQueryDatatype.string(convertIdent(Array(image(n)))[...])
                    try skipSpaces()
                }
                let property = currentProperty ?? ""
                try consume(T.colon)
                try skipSpaces()
                // ( values=expr() )?: no value at all (values == null) is a
                // syntax error, but an expression that came out empty (as
                // "!ie" leaves it, a warning) isn't
                var parsedValue = false
                let first = try next()
                if T.importantSym != first && T.semicolon != first && T.rbrace != first {
                    _ = try expr()
                    parsedValue = true
                }
                if T.importantSym == (try next()) {
                    try advance()
                    try skipSpaces()
                }
                if !parsedValue && !hack && !property.hasPrefix("--") {
                    throw Interrupt.parse(.syntax)
                }
            } catch Interrupt.parse(let failure) {
                // skipAfterExpression (CssParser.jj:4305-4335): to the next
                // ";" or "}", then the error
                try skipAfterExpression()
                try record(failure)
            } catch Interrupt.runtime(let message) {
                // declaration() catches NumberFormatException and
                // NullPointerException for skipAfterExpression, which records
                // them with their own messages and the property (Case 554591
                // review); the port knows BigDecimal's messages, not the
                // JDK's NullPointerException texts
                try skipAfterExpression()
                try record(.invalid(message ?? "null"))
            }
        }

        /// The tokens property() takes before a hacked name.
        static let propertyHacks: Set<Int> = [
            T.bang, T.dollar, T.percent, T.ampersand, T.backquote, T.question, T.less, T.pipe, T.any, T.eq,
            T.rbracket, T.lbracket, T.rparen, T.lparen, T.colon, T.tilde, T.plus, T.comma, T.greater, T.div
        ]

        /// skipAfterExpression's skipping: tokens up to ";", "}" or the
        /// end, a block skipped whole, a TokenMgrError costing a character.
        func skipAfterExpression() throws {
            while true {
                do {
                    let t = try peek(1)
                    if T.lbrace == t.kind {
                        try advance()
                        _ = try skipToMatchingBrace()
                        try advance()
                        continue
                    }
                    if T.semicolon == t.kind || T.rbrace == t.kind || T.eof == t.kind {
                        return
                    }
                    try advance()
                } catch Interrupt.tokenMgr {
                    guard position < text.count else {
                        return
                    }
                    position += 1
                }
            }
        }

        /// atRuleDeclaration (CssParser.jj:2156-2180): an at-rule the
        /// validator doesn't know is an error, but a vendor one ("@-webkit-
        /// …") only a warning.
        func atRuleDeclaration() throws {
            let n = try consume(T.atKeyword)
            let name = imageString(n)
            if !name.hasPrefix("@-") {
                try recordPlain(Message.unrecognizedAtRule(name))
            }
            _ = try skipStatement()
        }

        /// viewport() (CssParser.jj:1930-1972): VIEWPORT_SYM S* "{" S*
        /// declarations() "}" S*. Under css3svg its catch swallows a
        /// ParseException and leaves the token where it failed (only below
        /// CSS3 does it record the error and skip the statement), so in
        /// "all{@viewport}a" the "}" closes @media's block and "a" starts a
        /// rule. A TokenMgrError isn't caught (Case 554591 review: the port
        /// once skipped @viewport like the other at-rules, which ate that
        /// "}" and failed the value).
        func viewport() throws {
            try consume(T.viewportSym)
            do {
                try skipSpaces()
                try consume(T.lbrace)
                try skipSpaces()
                // declarations() as generated (CssParser.java:5305-5400):
                // declaration()? ( ";" S* declaration()? )*, entering a
                // declaration only at a token that can start one, and
                // returning at any other, which the "}" then fails on (so
                // "@viewport{@media x{}}" leaves "@media" to the block
                // around it)
                if Parser.declarationStarts.contains(try next()) {
                    try declaration()
                    currentProperty = nil
                }
                while T.semicolon == (try next()) {
                    try advance()
                    try skipSpaces()
                    if Parser.declarationStarts.contains(try next()) {
                        try declaration()
                        currentProperty = nil
                    }
                }
                try consume(T.rbrace)
                try skipSpaces()
            } catch Interrupt.parse {
                return
            }
        }

        /// The tokens a declaration can start with (the generated
        /// declarations()' cases): a property hack's token, an identifier,
        /// a #name, .name or @name.
        static let declarationStarts: Set<Int> = propertyHacks.union([
            T.and, T.or, T.only, T.not, T.ident, T.hashIdent, T.dashedIdent, T.dot, T.atKeyword
        ])

        /// The other at-rules (@page, @font-face, ...): their blocks are
        /// skipped unchecked.
        func otherAtRule() throws {
            try advance()
            skippingAtRule = true
            defer {
                skippingAtRule = false
            }
            _ = try skipStatement()
        }
    }

    // MARK: - The media features

    /// The media features of CSS3Properties.properties:571-605, by family.
    private enum FeatureKind {
        case keywords([String])
        case viewMode
        case grid
        case width
        case height
        case aspectRatio
        case integer(Int)
        case resolution
        case deprecated
    }

    private static let features: [String: FeatureKind] = [
        "any-hover": .keywords(["none", "hover"]),
        "hover": .keywords(["none", "hover"]),
        "any-pointer": .keywords(["none", "coarse", "fine"]),
        "pointer": .keywords(["none", "coarse", "fine"]),
        "color-gamut": .keywords(["srgb", "p3", "rec2020"]),
        "video-color-gamut": .keywords(["srgb", "p3", "rec2020"]),
        "dynamic-range": .keywords(["standard", "high"]),
        "video-dynamic-range": .keywords(["standard", "high"]),
        "environment-blending": .keywords(["opaque", "additive", "subtractive"]),
        "forced-colors": .keywords(["none", "active"]),
        "inverted-colors": .keywords(["none", "inverted"]),
        "orientation": .keywords(["portrait", "landscape"]),
        "overflow-block": .keywords(["none", "scroll", "paged"]),
        "overflow-inline": .keywords(["none", "scroll"]),
        "prefers-color-scheme": .keywords(["light", "dark"]),
        "prefers-contrast": .keywords(["no-preference", "less", "more", "custom"]),
        "prefers-reduced-motion": .keywords(["no-preference", "reduce"]),
        "prefers-reduced-transparency": .keywords(["no-preference", "reduce"]),
        "scan": .keywords(["interlace", "progressive"]),
        "scripting": .keywords(["none", "initial-only", "enabled"]),
        "update": .keywords(["none", "slow", "fast"]),
        "view-mode": .viewMode,
        "grid": .grid,
        "width": .width,
        "height": .height,
        "aspect-ratio": .aspectRatio,
        "color": .integer(1),
        "monochrome": .integer(1),
        "horizontal-viewport-segments": .integer(1),
        "vertical-viewport-segments": .integer(1),
        "color-index": .integer(2),
        "resolution": .resolution,
        "device-width": .deprecated,
        "device-height": .deprecated,
        "device-aspect-ratio": .deprecated
    ]

    private static let lengthUnits = [
        "em", "rem", "ex", "rex", "cap", "rcap", "ch", "rch", "ic", "ric", "lh", "rlh",
        "vw", "svw", "lvw", "dvw", "vh", "svh", "lvh", "dvh",
        "vi", "svi", "lvi", "dvi", "vb", "svb", "lvb", "dvb",
        "vmin", "svmin", "lvmin", "dvnim", "vmax", "svmax", "lvmax", "dvmax",
        "in", "cm", "mm", "pt", "pc", "px", "q"
    ]

    /// The names CssNumber.set takes as numbers.
    private static let calcConstants: Set<String> = [
        "pi", "e", "infinity", "nan", "a", "alpha", "b", "c", "g", "h", "l", "r", "s", "w"
    ]

    /// PseudoFactory's CSS3 pseudo-classes and pseudo-elements
    /// (selectors/PseudoFactory.java:32-95).
    private static let pseudoClasses: Set<String> = [
        "any-link", "link", "visited", "local-link", "target", "target-within", "scope", "hover", "active", "focus",
        "focus-visible", "focus-within", "current", "past", "future", "playing", "paused", "enabled", "disabled",
        "read-only", "read-write", "placeholder-shown", "default", "checked", "indeterminate", "blank", "valid",
        "invalid", "in-range", "out-of-range", "required", "optional", "user-invalid", "root", "empty",
        "first-child", "last-child", "only-child", "first-of-type", "last-of-type", "only-of-type", "left", "right",
        "first", "host", "fullscreen", "autofill", "defined"
    ]

    private static let pseudoElements: Set<String> = [
        "first-line", "first-letter", "selection", "target-text", "spelling-error", "grammar-error", "before",
        "after", "marker", "placeholder", "file-selector-button", "backdrop", "cue", "cue-region", "content", "shadow"
    ]

    /// CssEnv's environment variables with a length type.
    private static let envLengths: Set<String> = [
        "safe-area-inset-top", "safe-area-inset-left", "safe-area-inset-bottom", "safe-area-inset-right",
        "viewport-segment-width", "viewport-segment-height", "viewport-segment-top", "viewport-segment-left",
        "viewport-segment-bottom", "viewport-segment-right"
    ]

    /// Whether CssImage.setImageList takes an identifier as a color: its
    /// own CssColorCSS3.currentColor.equals (CssImage.java:184, CssIdent
    /// equality), then CssColor.setIdentColor (CssColor.java:280-338) on
    /// the name lowercased with toLowerCase(Locale.ENGLISH), so the Kelvin
    /// sign is a k: getRGBA ("transparent".equalsIgnoreCase, then the named
    /// colors), the system and deprecated system colors, and getIdentColor
    /// ("currentColor".equalsIgnoreCase).
    private static func isColorIdent(_ units: [UInt16]) -> Bool {
        if identEquals(units, "currentcolor") {
            return true
        }
        let lowered = javaLowercase(units)
        if javaEqualsIgnoreCase(lowered, "transparent") || javaEqualsIgnoreCase(lowered, "currentcolor") {
            return true
        }
        return colorKeywords.contains(string(lowered[...]))
    }

    /// The color keywords CssColor.setIdentColor takes in CSS3 (values/
    /// color/CssColorCSS3.java:47-230): the named colors, transparent, and
    /// the system and deprecated system colors (currentColor is checked
    /// apart, by CssIdent's equality).
    private static let colorKeywords: Set<String> = [
        "aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black", "blanchedalmond",
        "blue", "blueviolet", "brown", "burlywood", "cadetblue", "chartreuse", "chocolate", "coral",
        "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue", "darkcyan", "darkgoldenrod", "darkgray",
        "darkgreen", "darkgrey", "darkkhaki", "darkmagenta", "darkolivegreen", "darkorange", "darkorchid",
        "darkred", "darksalmon", "darkseagreen", "darkslateblue", "darkslategray", "darkslategrey",
        "darkturquoise", "darkviolet", "deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue",
        "firebrick", "floralwhite", "forestgreen", "fuchsia", "gainsboro", "ghostwhite", "gold", "goldenrod",
        "gray", "green", "greenyellow", "grey", "honeydew", "hotpink", "indianred", "indigo", "ivory", "khaki",
        "lavender", "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan",
        "lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink", "lightsalmon",
        "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey", "lightsteelblue", "lightyellow",
        "lime", "limegreen", "linen", "magenta", "maroon", "mediumaquamarine", "mediumblue", "mediumorchid",
        "mediumpurple", "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise",
        "mediumvioletred", "midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite", "navy",
        "oldlace", "olive", "olivedrab", "orange", "orangered", "orchid", "palegoldenrod", "palegreen",
        "paleturquoise", "palevioletred", "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue",
        "purple", "rebeccapurple", "red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown",
        "seagreen", "seashell", "sienna", "silver", "skyblue", "slateblue", "slategray", "slategrey", "snow",
        "springgreen", "steelblue", "tan", "teal", "thistle", "tomato", "turquoise", "violet", "wheat", "white",
        "whitesmoke", "yellow", "yellowgreen", "transparent",
        "accentcolor", "accentcolortext", "activetext", "buttonborder", "buttonface", "buttontext", "canvas",
        "canvastext", "field", "fieldtext", "graytext", "highlight", "highlighttext", "linktext", "mark",
        "marktext", "selecteditem", "selecteditemtext", "visitedtext",
        "activeborder", "activecaption", "appworkspace", "background", "buttonhighlight", "buttonshadow",
        "captiontext", "inactiveborder", "inactivecaption", "inactivecaptiontext", "infobackground", "infotext",
        "menu", "menutext", "scrollbar", "threeddarkshadow", "threedface", "threedhighlight",
        "threedlightshadow", "threedshadow", "window", "windowframe", "windowtext"
    ]

    /// A media feature class's constructor (atrules/css3/media/*.java).
    private struct FeatureCheck {
        enum Result {
            /// The feature, whether it's a MediaRangeFeature, and the values
            /// it keeps (which media() prints, MediaRangeFeature.toString).
            case valid(Bool, [Value])
            /// An InvalidParamException, recorded as a plain error.
            case error(String?)
            /// Any other exception out of the constructor (a
            /// ClassCastException, or building a message around a number
            /// Java can't print): handleMediaFeature throws an
            /// InvalidParamException with a null message, which is skipped.
            case exception
        }

        /// A checkValue's verdict on one value.
        enum Check {
            case ok
            case error(String)
            case exception
        }

        let name: String
        let modifier: String?
        let expression: Expression?

        func run(_ kind: FeatureKind) -> Result {
            switch kind {
            case .keywords(let allowed):
                return keywords(allowed)
            case .viewMode:
                return keywords(["windowed", "floating", "fullscreen", "maximized", "minimized"])
            case .grid:
                return grid()
            case .width:
                return range(limit: nil, accepts: lengthValue)
            case .height:
                return range(limit: 2, accepts: lengthValue)
            case .aspectRatio:
                return range(limit: 2, accepts: ratioValue)
            case .integer(let limit):
                return range(limit: limit, accepts: integerValue)
            case .resolution:
                return resolution()
            case .deprecated:
                // MediaFeature.reportDeprecatedMediaFeature
                // (atrules/css/media/MediaFeature.java:60-70), whatever the
                // value
                let full = modifier.map { "\($0)-\(name)" } ?? name
                return .error(Message.deprecatedFeature(full))
            }
        }

        /// The "value" error ("“V” is not a “F” value"), whose arguments
        /// print the value: when that can't be done, the exception instead.
        func valueError(_ val: Value, _ caller: String) -> Check {
            val.messageThrows ? .exception : .error(Message.value(val.text, caller))
        }

        func result(_ check: Check) -> Result? {
            switch check {
            case .ok:
                return nil
            case .error(let message):
                return .error(message)
            case .exception:
                return .exception
            }
        }

        /// MediaHover and its 20 siblings, and ViewMode (whose deprecation
        /// is only a warning): no prefix, at most one value, an allowed
        /// keyword by CssIdent's hash equality.
        func keywords(_ allowed: [String]) -> Result {
            if nil != modifier {
                return .error(Message.noModifierMedia(name))
            }
            guard let exp = expression else {
                return .valid(false, [])
            }
            if exp.count > 1 {
                return .error(Message.unrecognize)
            }
            if 0 == exp.count {
                return .error(Message.fewValue(name))
            }
            let val = exp.values[0]
            // switch (val.getType()), case CSS_IDENT: getAllowedIdent(val
            // .getIdent()). Any value of identifier type takes that case, so
            // an abs() or mod() of a var() with an identifier fallback has
            // no getIdent() and fails with a ClassCastException, which
            // MediaQuery skips (Case 554591 review: the port once matched
            // identifiers alone, a false error for those)
            if CssType.ident == val.type {
                guard let units = val.javaIdent else {
                    return .exception
                }
                if allowed.contains(where: { HTMLMediaQueryDatatype.identEquals(units, $0) }) {
                    return .valid(false, [val])
                }
            }
            return result(valueError(val, name)) ?? .valid(false, [val])
        }

        /// MediaGrid (MediaGrid.java:33-69).
        func grid() -> Result {
            if nil != modifier {
                return .error(Message.noModifierMedia(name))
            }
            guard let exp = expression else {
                return .valid(false, [])
            }
            if exp.count > 1 {
                return .error(Message.unrecognize)
            }
            if 0 == exp.count {
                return .error(Message.fewValue(name))
            }
            let val = exp.values[0]
            guard CssType.number == val.type else {
                return .error(Message.unrecognize)
            }
            if case .number(let n, let isInt, _) = val {
                if !isInt {
                    // checkInteger prints the number into the message
                    return val.textThrows ? .exception : .error(Message.integer)
                }
                // getInt(): out of a Java int's range is "out-of-range",
                // a key Messages.properties.en lacks: a null message
                guard let v = n.intValueExact else {
                    return .error(nil)
                }
                if 0 != v && 1 != v {
                    return .error(Message.grid)
                }
            }
            return .valid(false, [val])
        }

        /// What MediaWidth's and MediaHeight's checkValue accept.
        func lengthValue(_ val: Value, _ caller: String) -> Check {
            switch val.type {
            case CssType.number:
                // checkEqualsZero: a number must be zero (a calc() always
                // is; a math function only warns). CssNumber's builds its
                // message's arguments, the number printed, before it looks,
                // and CssCalc's prints the calc().
                if case .math = val {
                    return .ok
                }
                if val.textThrows {
                    return .exception
                }
                return val.isZero ? .ok : .error(Message.zero)
            case CssType.length:
                return .ok
            default:
                return valueError(val, caller)
            }
        }

        /// MediaAspectRatio's checkValue.
        func ratioValue(_ val: Value, _ caller: String) -> Check {
            CssType.ratio == val.type ? .ok : valueError(val, caller)
        }

        /// The integer features' checkValue (MediaColor.java:91-108).
        func integerValue(_ val: Value, _ caller: String) -> Check {
            guard CssType.number == val.type else {
                return valueError(val, caller)
            }
            if case .number(_, let isInt, _) = val, !isInt {
                return val.textThrows ? .exception : .error(Message.integer)
            }
            return .ok
        }

        /// The range features' shared constructor shape (MediaWidth.java:
        /// 34-86 and siblings): the count limit, then the first value: a
        /// plain value checked, or a comparator (no prefix) whose side is
        /// checked, a second comparator's too, and "=" not allowed in a
        /// two-sided range; then setModifier. No value: no prefix.
        func range(limit: Int?, accepts: (Value, String) -> Check) -> Result {
            guard let exp = expression else {
                return nil != modifier ? .error(Message.noModifierShort) : .valid(true, [])
            }
            if let l = limit, exp.count > l {
                return .error(Message.unrecognize)
            }
            if 0 == exp.count {
                return .error(Message.fewValue(name))
            }
            let val = exp.values[0]
            if case .comparator(let symbol, let side) = val {
                if nil != modifier {
                    return .error(Message.noModifierRange)
                }
                if 0 == side.count {
                    return .error(Message.fewValue(name))
                }
                if let r = result(accepts(side.values[0], name)) {
                    return r
                }
                var stored = [side.values[0]]
                if exp.count > 1 {
                    guard case .comparator(let symbol2, let side2) = exp.values[1] else {
                        return .error(Message.unrecognize)
                    }
                    if 0 == side2.count {
                        return .error(Message.fewValue(name))
                    }
                    if let r = result(accepts(side2.values[0], name)) {
                        return r
                    }
                    if "=" == symbol || "=" == symbol2 {
                        return .error(Message.comparator(symbol, symbol2))
                    }
                    stored.append(side2.values[0])
                }
                return .valid(true, stored)
            }
            // a value of a type the switch doesn't take is the same
            // "value" error checkValue gives
            if let r = result(accepts(val, name)) {
                return r
            }
            return .valid(true, [val])
        }

        /// MediaResolution (MediaResolution.java:38-109): an identifier
        /// other than infinite falls into the comparator case and fails
        /// its cast (a ClassCastException, skipped by MediaQuery).
        func resolution() -> Result {
            guard let exp = expression else {
                return nil != modifier ? .error(Message.noModifierShort) : .valid(true, [])
            }
            if exp.count > 2 {
                return .error(Message.unrecognize)
            }
            if 0 == exp.count {
                return .error(Message.fewValue(name))
            }
            let val = exp.values[0]
            // case CSS_IDENT takes any value of identifier type, whose
            // getIdent() may throw (see keywords())
            if CssType.ident == val.type {
                guard let units = val.javaIdent else {
                    return .exception
                }
                if HTMLMediaQueryDatatype.identEquals(units, "infinite") {
                    return .valid(true, [val])
                }
                if nil != modifier {
                    return .error(Message.noModifierRange)
                }
                return .exception
            }
            switch val {
            case .comparator(let symbol, let side):
                if nil != modifier {
                    return .error(Message.noModifierRange)
                }
                if 0 == side.count {
                    return .error(Message.fewValue(name))
                }
                if CssType.resolution != side.values[0].type {
                    return .error(Message.unrecognize)
                }
                var stored = [side.values[0]]
                if exp.count > 1 {
                    guard case .comparator(let symbol2, let side2) = exp.values[1] else {
                        return .error(Message.unrecognize)
                    }
                    if 0 == side2.count {
                        return .error(Message.fewValue(name))
                    }
                    if CssType.resolution != side2.values[0].type {
                        return .error(Message.unrecognize)
                    }
                    if "=" == symbol || "=" == symbol2 {
                        return .error(Message.comparator(symbol, symbol2))
                    }
                    stored.append(side2.values[0])
                }
                return .valid(true, stored)
            default:
                if CssType.resolution == val.type {
                    return .valid(true, [val])
                }
                return .error(Message.unrecognize)
            }
        }
    }
}

/// Case 554591 (A14): upstream's schema model of an element's ARIA states and
/// properties, as vnu.jar's default schema has it (aria.rnc and the html5
/// element patterns, with svg11 and MathML), and Jing's way of judging an
/// element's attributes against it (PatternValidator). Each of the element's
/// patterns, and within each its implicit and role patterns, is an
/// alternative. Each attribute in turn, in the order the schema validator
/// gets them (see schemaAttributes), narrows the live alternatives to those
/// that take it; one no live alternative takes is "not allowed", and
/// ignored. If no alternative left is satisfied at the end of the start tag,
/// what the ones left still need is "missing" (see missingAttributes).
///
/// The port judged a few of these attributes with hand-written role sets,
/// keyed by the first token of the role as written, ignoring implicit roles:
/// so aria-valuemin and aria-valuemax on a role=progressbar (Bootstrap's
/// progress bars), aria-selected and aria-checked on a role=treeitem, and
/// aria-readonly on an <input type=text> were all "not allowed", where
/// vnu.jar reports nothing. Those attributes (judgedAttributes) are now
/// judged as the schema judges them. The others, every attribute's value,
/// and the states a role requires on its own (role=checkbox's aria-checked)
/// are left for a later unit: every attribute narrows the alternatives, as
/// in Jing, but only the judged ones are reported as not allowed, and
/// "missing" is reported only for an element with one of them.
enum HTMLARIASchema {
    /// aria.<name> in aria.rnc: a role value, the role-specific states and
    /// properties it accepts (beyond aria.global, which every element with
    /// ARIA attributes takes), and those it requires.
    struct RolePattern {
        let role: String
        let allowed: Set<String>
        let required: [String]
    }

    /// One of an element's patterns in the schema, as far as ARIA goes.
    struct Variant {
        /// Where this pattern is one of the element's alternatives at all.
        /// (The attributes that tell an element's patterns apart, its type
        /// and those in `rejected`, narrow them where they come in the start
        /// tag instead, as Jing narrows by them.)
        enum Selector {
            /// Everywhere.
            case always
            /// Only where its parent is this element: an li's patterns
            /// differ by its parent (ul.inner, ol.inner, menu.inner).
            case parent(String)
            /// Only where its parent isn't this element: meta's microdata
            /// pattern isn't one in a noscript (A14's third review), since
            /// head's noscript takes only the refresh and default-style
            /// pragmas, and the port's events can't tell head's noscript
            /// from the body's.
            case notParent(String)
            /// input's and button's patterns differ by their type attribute
            /// (w:string, compared ignoring ASCII case): this one takes this
            /// value, and is the one with no type attribute where `optional`.
            case type(String, optional: Bool)
        }

        let selector: Selector
        /// Its implicit patterns (implicitPatterns), alternatives used
        /// with no role attribute (several for td, cell and gridcell).
        let implicit: [String]
        /// The role patterns it accepts (rolePatterns); nil for any
        /// (anyRolePatterns).
        let roles: [String]?
        /// Whether it takes a role attribute at all.
        let acceptsRole: Bool
        /// Whether it takes any attribute (the obsolete elements legacy.rnc
        /// defines with a wildcard), so nothing here applies.
        let anyAttribute: Bool
        /// Other states and properties it takes in every alternative (the
        /// date inputs' aria-valuemin and aria-valuemax, embed's wildcard).
        let extraARIA: Set<String>
        /// Other attributes it requires: each list is one requirement,
        /// satisfied by any of its names (img's src or srcset).
        let requiredGroups: [[String]]
        /// Attributes it doesn't take that another of the element's patterns
        /// does, so that one written leaves this pattern out, unless it's the
        /// last one left: a without href takes no href, target or download;
        /// button's reset and button patterns no formaction; time's without
        /// datetime no datetime; the textbox half of an email, url or tel
        /// input no list (the combobox half requires it); the RDFa meta for
        /// the body no name.
        let rejected: Set<String>
    }

    /// What the schema reports for an element's judged attributes.
    enum Message: Equatable {
        /// "Attribute “X” not allowed on element “E” at this point."
        case notAllowed(String)
        /// "Element “E” is missing required attribute “X”."
        case missingRequired(String)
        /// "Element “E” is missing one or more of the following attributes:
        /// “X”, “Y”."
        case missingOneOf([String])
    }

    /// The states and properties the port judges (see the type's comment):
    /// the ones its hand-written role sets judged before.
    static let judgedAttributes: Set<String> = [
        "aria-checked", "aria-multiselectable", "aria-placeholder", "aria-readonly", "aria-selected", "aria-valuemax",
        "aria-valuemin"
    ]

    /// The states and properties aria.global doesn't have, which only some
    /// roles' and implicit patterns take: the ones that narrow an element's
    /// implicit and role patterns.
    static let roleSpecificAttributes: Set<String> = [
        "aria-activedescendant", "aria-autocomplete", "aria-checked", "aria-colcount", "aria-colindex", "aria-colspan",
        "aria-expanded", "aria-level", "aria-modal", "aria-multiline", "aria-multiselectable", "aria-orientation",
        "aria-placeholder", "aria-posinset", "aria-pressed", "aria-readonly", "aria-required", "aria-rowcount",
        "aria-rowindex", "aria-rowspan", "aria-selected", "aria-setsize", "aria-sort", "aria-valuemax", "aria-valuemin",
        "aria-valuenow", "aria-valuetext"
    ]

    /// AriaAttributeDroppingContentHandlerWrapper's KNOWN_ARIA_ATTRIBUTE_NAMES:
    /// the aria-* names whose valueless attributes it drops (see
    /// droppingValuelessARIA).
    static let knownARIAAttributes: Set<String> = [
        "aria-activedescendant", "aria-atomic", "aria-autocomplete", "aria-braillelabel", "aria-brailleroledescription",
        "aria-busy", "aria-checked", "aria-colcount", "aria-colindex", "aria-colindextext", "aria-colspan",
        "aria-controls", "aria-current", "aria-describedby", "aria-description", "aria-details", "aria-disabled",
        "aria-dropeffect", "aria-errormessage", "aria-expanded", "aria-flowto", "aria-grabbed", "aria-haspopup",
        "aria-hidden", "aria-invalid", "aria-keyshortcuts", "aria-label", "aria-labelledby", "aria-level", "aria-live",
        "aria-modal", "aria-multiline", "aria-multiselectable", "aria-orientation", "aria-owns", "aria-placeholder",
        "aria-posinset", "aria-pressed", "aria-readonly", "aria-relevant", "aria-required", "aria-roledescription",
        "aria-rowcount", "aria-rowindex", "aria-rowindextext", "aria-rowspan", "aria-selected", "aria-setsize",
        "aria-sort", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"
    ]

    /// An element's attribute as the schema gets it: its name, and its value
    /// as upstream's tokenizer hands it on (nil for an attribute written
    /// without a value).
    struct Attribute {
        let name: String
        let value: String?
    }

    /// One of an element's alternatives: one of its variants' implicit
    /// patterns or role patterns (or, for a variant with no implicit
    /// pattern, the one with neither), as indices and bits, so that
    /// narrowing copies no sets. (A14 review: built once for each HTML
    /// element, htmlAlternatives, where they were built from the tables for
    /// every element with a judged attribute; 50,000 <div aria-readonly>
    /// took half again as long as before.)
    private struct Alternative {
        /// Its variant's index among the element's variants.
        let variant: Int
        /// Its role pattern's role value, an index into roleValues; -1 for
        /// an implicit or plain alternative.
        let role: Int
        /// The role-specific states and properties it takes (stateBits):
        /// its implicit or role pattern's, and its variant's extras.
        let accepts: UInt32
        /// Those its role requires.
        let requires: UInt32
    }

    /// Where Jing's narrowing leaves an element's alternatives.
    private struct Narrowing {
        var live: [Alternative]
        /// The role-specific states and properties the live alternatives
        /// have taken (stateBits).
        var states: UInt32 = 0
        /// The other attributes they have taken, the role and type among
        /// them. (Every live alternative has taken all of these: an
        /// attribute leaves only those that take it.)
        var consumed: Set<String> = []
        /// The judged attributes none of them took, in order.
        var notAllowed: [String] = []
    }

    /// What one of the live patterns still needs, for telling identical
    /// requirements apart, as Jing's interned patterns are (see
    /// missingAttributes): its type's value, its other required attributes,
    /// and what its ARIA part needs.
    private struct PatternNeeds: Hashable {
        var type: String?
        var groups: [[String]] = []
        var aria: ARIANeeds?
    }

    /// What one implicit or role alternative's ARIA part needs: its role's
    /// value (an index into roleValues; -1 when the role is given) and the
    /// states it still requires (stateBits).
    private struct ARIANeeds: Hashable {
        let role: Int
        let states: UInt32
    }

    /// roleSpecificAttributes in order, each one's bit its index.
    private static let stateNames: [String] = roleSpecificAttributes.sorted()

    /// A bit for each of roleSpecificAttributes, for the alternatives' sets
    /// of them.
    private static let stateBits: [String: UInt32] = Dictionary(
        uniqueKeysWithValues: stateNames.enumerated().map { ($1, UInt32(1) << UInt32($0)) }
    )

    /// The bits of those of these names that are role-specific states and
    /// properties.
    private static func stateMask(_ names: some Sequence<String>) -> UInt32 {
        names.reduce(0) { $0 | (stateBits[$1] ?? 0) }
    }

    /// The role values of rolePatterns, in order, for the alternatives'
    /// role indices. (Several patterns can have one role value: switch and
    /// switch-checked-not-required; their role attribute patterns are one.)
    private static let roleValues: [String] = Array(Set(rolePatterns.values.map(\.role))).sorted()

    /// Each role value's index in roleValues.
    private static let roleValueIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: roleValues.enumerated().map { ($1, $0) }
    )

    /// Every HTML element's alternatives, for all of its variants (see
    /// alternatives(of:)), built once.
    private static let htmlAlternatives: [String: [Alternative]] = htmlElements.mapValues { alternatives(of: $0) }

    /// Whether the schema sees an element's `attribute` at all: not when
    /// upstream's dropping takes it away (see droppingValuelessARIA). For the
    /// port's hand-written stand-in for the schema's message about a select
    /// with role=combobox, which went by the attribute as written, so <select
    /// role="combobox" aria-hidden aria-expanded="true"> wasn't missing its
    /// aria-expanded, as it is in vnu.jar.
    static func schemaSees(_ attribute: String, in attributes: [Attribute]) -> Bool {
        guard attributes.contains(where: { attribute == $0.name }) else {
            return false
        }
        return droppingValuelessARIA(firstOfEachName(attributes)).contains { attribute == $0.name }
    }

    /// The schema's messages for an element's judged attributes, in Jing's
    /// order. `schemaRole` is the role as the schema sees it (after
    /// upstream's role filter for HTML and SVG; as written for MathML), nil
    /// with no role attribute; `parent` is an HTML element's parent's name
    /// (for li and meta); `reportedElsewhere` are
    /// the attributes another of the port's checkers reports missing on this
    /// element (img's src and srcset with neither, say); `judged` are the
    /// states and properties to report on, judgedAttributes and, for some
    /// elements, others (see
    /// HTMLGeneralAttributeChecker.ariaSchemaJudgedAttributes). Empty for an
    /// element the schema doesn't know or doesn't judge (custom elements,
    /// the obsolete ones it takes anything on).
    static func messages(
        element name: String,
        namespace: HTMLNamespace,
        parent: String?,
        attributes: [Attribute],
        schemaRole: String?,
        reportedElsewhere: Set<String>,
        judged: Set<String>
    ) -> [Message] {
        // Only the judged attributes get messages here, so an element with
        // none of them (nearly every element) needs nothing more; nor does
        // one whose judged attributes upstream drops before its schema sees
        // them.
        guard attributes.contains(where: { judged.contains($0.name) }) else {
            return []
        }
        let seen = schemaAttributes(attributes, element: name, namespace: namespace)
        guard seen.contains(where: { judged.contains($0.name) }) else {
            return []
        }
        // The element's patterns and their alternatives, those of the
        // patterns it can have where it is (see selects).
        let variants: [Variant]
        var initial: [Alternative]
        switch namespace {
        case .svg:
            variants = [svgVariant(name)]
            initial = alternatives(of: variants)
        case .mathML:
            variants = [mathMLVariant(name)]
            initial = alternatives(of: variants)
        case .html:
            guard let known = htmlElements[name], let all = htmlAlternatives[name] else {
                return []
            }
            variants = known
            initial = all
        }
        let selected = variants.map { selects($0, parent: parent) }
        guard selected.contains(true), !zip(variants, selected).contains(where: { $1 && $0.anyAttribute }) else {
            return []
        }
        if selected.contains(false) {
            initial = initial.filter { selected[$0.variant] }
        }
        let typed = variants.contains { variant in
            if case .type = variant.selector {
                return true
            }
            return false
        }
        let final = narrowing(initial, by: seen, variants: variants, typed: typed, schemaRole: schemaRole, judged: judged)
        var messages = final.notAllowed.map(Message.notAllowed)
        if !final.live.isEmpty, !final.live.contains(where: { satisfied($0, variants: variants, state: final) }) {
            let missing = missingAttributes(final, variants: variants)
            // (Jing sorts the names, a TreeSet of Java strings; these are all
            // ASCII, so Swift's order is the same.)
            let sorted = missing.names.sorted()
            if missing.hasChoice {
                // One message naming them all; but not where it names an
                // attribute another checker reports missing (img's src, input
                // type=image's alt): that one's message stands, and Jing's one
                // message naming it and the role too is a later unit's.
                if missing.names.isDisjoint(with: reportedElsewhere) {
                    messages.append(.missingOneOf(sorted))
                }
            } else {
                // One message for each name, as Jing gives them, but for those
                // another checker reports already, in the same words. (A14
                // review: <input type="image" role="checkbox"
                // aria-readonly="true"> lost vnu.jar's "missing required
                // attribute “aria-checked”" with the alt message.)
                messages.append(contentsOf: sorted.filter { !reportedElsewhere.contains($0) }.map(Message.missingRequired))
            }
        }
        return messages
    }

    /// The first attribute of each name, which is the one upstream's
    /// tokenizer keeps.
    private static func firstOfEachName(_ attributes: [Attribute]) -> [Attribute] {
        var names: Set<String> = []
        return attributes.filter { names.insert($0.name).inserted }
    }

    /// An element's attributes as upstream's schema validator gets them: the
    /// first of each name, in the order AttributesPermutingXMLReaderWrapper
    /// puts an HTML element's in (an SVG or MathML element's keep theirs;
    /// see permute), less those AriaAttributeDroppingContentHandlerWrapper
    /// drops (see droppingValuelessARIA), which comes after it.
    private static func schemaAttributes(_ attributes: [Attribute], element name: String, namespace: HTMLNamespace) -> [Attribute] {
        var list = firstOfEachName(attributes)
        if .html == namespace {
            permute(&list, element: name)
        }
        return droppingValuelessARIA(list)
    }

    /// AttributesPermutingXMLReaderWrapper.startElement, which puts some of
    /// an HTML element's attributes first, for the schema's better messages:
    /// for an input (or command) whose type isn't first, the type, then the
    /// role; for a textarea, script or meta, its wrap, src or content
    /// instead (the content last), the role staying where it is; for any
    /// other element, the role (each after the template attribute, which
    /// goes first). Jing narrows by the attributes in this order, so which
    /// alternatives the role leaves depends on it: <a href="#" role="alert">
    /// is a.nohref's alert, the href then not allowed, where the port took
    /// the href first and judged the role against a.href's 15. (And <input
    /// type=checkbox role=switch> is judged with the role first but <input
    /// role=switch type=checkbox> with the type first: upstream's quirk,
    /// kept.)
    private static func permute(_ list: inout [Attribute], element name: String) {
        // (Java's getIndex: -1 for an attribute that isn't there.)
        func index(_ attribute: String) -> Int {
            list.firstIndex { attribute == $0.name } ?? -1
        }
        // PermutingAttributesWrapper.pullUp: to the front, if it isn't there.
        func pullUp(_ attribute: String) {
            let at = index(attribute)
            if at > 0 {
                list.insert(list.remove(at: at), at: 0)
            }
        }
        // PermutingAttributesWrapper.pushDown: to the end, if it isn't there.
        func pushDown(_ attribute: String) {
            let at = index(attribute)
            if at >= 0, at != list.count - 1 {
                list.append(list.remove(at: at))
            }
        }
        if ("input" == name || "command" == name) && index("type") > 0 {
            pullUp("role")
            pullUp("type")
            pullUp("template")
        } else if "textarea" == name && index("wrap") > 0 {
            pullUp("wrap")
            pullUp("template")
        } else if "script" == name && index("src") > 0 {
            pullUp("src")
            pullUp("template")
        } else if "meta" == name && index("content") < list.count - 1 {
            // (Taken with no content attribute too: -1 is less.)
            pushDown("content")
            pullUp("template")
        } else if index("template") > 0 || index("role") > 0 {
            pullUp("role")
            pullUp("template")
        }
    }

    /// AriaAttributeDroppingContentHandlerWrapper.filterAttributes, which
    /// stands between the parser and the schema validator (for HTML, SVG and
    /// MathML alike): at the first attribute with one of its known aria-*
    /// names written without a value (the parser's shared empty string is
    /// the value it compares against, so aria-x="" is kept), it drops that
    /// attribute and, because its second loop tests that attribute's index
    /// instead of each later one's, every later attribute with a known name,
    /// whatever its value. So the schema never sees the aria-checked in <div
    /// aria-hidden aria-checked="true">, and says nothing about it, where the
    /// port said it was missing a role. (Only the schema: upstream's
    /// Assertions sees every attribute.)
    private static func droppingValuelessARIA(_ list: [Attribute]) -> [Attribute] {
        guard let first = list.firstIndex(where: { nil == $0.value && knownARIAAttributes.contains($0.name) }) else {
            return list
        }
        return Array(list[..<first]) + list[(first + 1)...].filter { !knownARIAAttributes.contains($0.name) }
    }

    /// Every alternative of the element's patterns, as Jing's choice of them
    /// starts out: each pattern's implicit patterns (or, for one with none,
    /// the pattern with no role, which takes aria.global and its extra
    /// states only), then its role patterns.
    private static func alternatives(of variants: [Variant]) -> [Alternative] {
        var alternatives: [Alternative] = []
        for (index, variant) in variants.enumerated() {
            let extra = stateMask(variant.extraARIA)
            if variant.implicit.isEmpty {
                alternatives.append(Alternative(variant: index, role: -1, accepts: extra, requires: 0))
            }
            for key in variant.implicit {
                alternatives.append(Alternative(variant: index, role: -1, accepts: stateMask(implicitPatterns[key] ?? []) | extra, requires: 0))
            }
            guard variant.acceptsRole else {
                continue
            }
            for key in variant.roles ?? anyRolePatterns {
                if let pattern = rolePatterns[key], let role = roleValueIndex[pattern.role] {
                    alternatives.append(Alternative(variant: index, role: role, accepts: stateMask(pattern.allowed) | extra, requires: stateMask(pattern.required)))
                }
            }
        }
        return alternatives
    }

    /// Jing's narrowing (PatternValidator.startElement's attribute loop):
    /// each attribute in turn leaves the live alternatives that take it.
    private static func narrowing(
        _ initial: [Alternative],
        by attributes: [Attribute],
        variants: [Variant],
        typed: Bool,
        schemaRole: String?,
        judged: Set<String>
    ) -> Narrowing {
        var state = Narrowing(live: initial)
        // (Whether any of the patterns rejects anything; see below.)
        let anyRejects = variants.contains { !$0.rejected.isEmpty }
        for attribute in attributes {
            let name = attribute.name
            if "role" == name {
                // The role: the alternatives with a role pattern take it,
                // those for its value if there are any. A value none has
                // (role="foo") is a "Bad value" that Jing recovers from by
                // keeping them all, the role counting as given. With no
                // alternative left that takes a role at all, it's "not
                // allowed" (the role checks report that), and ignored.
                guard let schemaRole else {
                    continue
                }
                let takers = state.live.filter { 0 <= $0.role }
                guard !takers.isEmpty else {
                    continue
                }
                let role = roleValueIndex[schemaRole] ?? -1
                let matching = takers.filter { role == $0.role }
                state.live = matching.isEmpty ? takers : matching
                state.consumed.insert(name)
            } else if let bit = stateBits[name] {
                // A role-specific state or property.
                let next = state.live.filter { 0 != $0.accepts & bit }
                if next.isEmpty {
                    if judged.contains(name) {
                        state.notAllowed.append(name)
                    }
                } else {
                    state.live = next
                    state.states |= bit
                }
            } else if typed, "type" == name {
                // input's and button's type: every pattern takes it, those
                // for its value if any of them is still live; any other value
                // is a "Bad value" (reported elsewhere) that keeps them all.
                let value = typeValue(attribute.value)
                let matching = state.live.filter { alternative in
                    if case let .type(type, _) = variants[alternative.variant].selector {
                        return type == value
                    }
                    return false
                }
                if !matching.isEmpty {
                    state.live = matching
                }
                state.consumed.insert(name)
            } else {
                // Any other attribute leaves out only the patterns that
                // reject it (see Variant.rejected), unless that would leave
                // none: then it's "not allowed" (reported elsewhere, where
                // the port reports it at all), and ignored. (A14 review:
                // decided once for each pattern, not for each of its
                // alternatives: an a without href has some 124, and every
                // attribute looked in each one's rejected set.)
                if anyRejects {
                    let rejecting = variants.indices.filter { variants[$0].rejected.contains(name) }
                    if !rejecting.isEmpty, state.live.contains(where: { rejecting.contains($0.variant) }) {
                        let next = state.live.filter { !rejecting.contains($0.variant) }
                        guard !next.isEmpty else {
                            continue
                        }
                        state.live = next
                    }
                }
                state.consumed.insert(name)
            }
        }
        return state
    }

    /// Whether an alternative needs nothing more: its role and the states
    /// the role requires (see roleSatisfied), and its pattern's type and
    /// other required attributes (see patternSatisfied).
    private static func satisfied(_ alternative: Alternative, variants: [Variant], state: Narrowing) -> Bool {
        roleSatisfied(alternative, state: state) && patternSatisfied(variants[alternative.variant], consumed: state.consumed)
    }

    /// Whether an alternative's own ARIA part needs nothing more: an
    /// implicit or plain one never does; a role's needs the role and the
    /// states that role requires.
    private static func roleSatisfied(_ alternative: Alternative, state: Narrowing) -> Bool {
        guard 0 <= alternative.role else {
            return true
        }
        return state.consumed.contains("role") && 0 == alternative.requires & ~state.states
    }

    /// Whether a pattern's own attributes need nothing more: its type where
    /// that isn't optional, and its other required attributes.
    private static func patternSatisfied(_ variant: Variant, consumed: Set<String>) -> Bool {
        if case let .type(_, optional) = variant.selector, !optional, !consumed.contains("type") {
            return false
        }
        return variant.requiredGroups.allSatisfy { $0.contains(where: consumed.contains) }
    }

    /// Jing's end-of-tag message when no live alternative is satisfied
    /// (PatternValidator.startElement): RequiredContent.getRequiredAttributes
    /// of what's left, a choice of the live patterns, each the interleave of
    /// what it still needs: its type, its other required attributes, and its
    /// ARIA part. A pattern's ARIA part adds nothing while one of its live
    /// implicit or role alternatives needs nothing more
    /// (RequiredContentFunction.caseChoice returns empty for a nullable
    /// choice), so <input aria-expanded> doesn't ask for the aria-checked
    /// that only the checkbox input's checkbox and switch roles need, its
    /// implicit checkbox still being live; otherwise it's a choice of what
    /// each of them needs, its role (with that role's value) and the states
    /// that role requires. Identical patterns are one
    /// (ValidatorPatternBuilder.makeChoice, of interned patterns), so the
    /// three button patterns of <button type=foo aria-colindex=1>, each
    /// needing role="gridcell", ask for the role once. Then
    /// NameRecordingVisitor: every attribute that names, and whether it has
    /// a choice (then Jing gives one message naming them all; without, one
    /// per attribute).
    private static func missingAttributes(_ state: Narrowing, variants: [Variant]) -> (names: Set<String>, hasChoice: Bool) {
        let roleTaken = state.consumed.contains("role")
        var names: Set<String> = []
        var hasChoice = false
        // The live patterns' needs, those with no choice in them, to tell
        // apart (with a choice anywhere, the message names them all anyway).
        var patterns: Set<PatternNeeds> = []
        // A pattern's own needs: its type, where that isn't optional, and its
        // other required attributes.
        func ownNeeds(_ variant: Variant) -> PatternNeeds {
            var needs = PatternNeeds()
            if case let .type(type, optional) = variant.selector, !optional, !state.consumed.contains("type") {
                names.insert("type")
                needs.type = type
            }
            for group in variant.requiredGroups where !group.contains(where: state.consumed.contains) {
                names.formUnion(group)
                // (src or srcset: a choice.)
                hasChoice = hasChoice || group.count > 1
                needs.groups.append(group)
            }
            return needs
        }
        // The states a role alternative still needs (stateBits), named.
        func missingStates(_ alternative: Alternative) -> UInt32 {
            let missing = alternative.requires & ~state.states
            var bits = missing
            while 0 != bits {
                names.insert(stateNames[bits.trailingZeroBitCount])
                bits &= bits - 1
            }
            return missing
        }
        if roleTaken {
            // Once the role is given, each live alternative (every one a
            // role's) is a pattern of its own in Jing's choice: each role
            // pattern's role attribute has its own value, so the derivatives
            // by the role don't merge, and a value none has is recovered from
            // as a flat choice of them all (RecoverAfterFunction), each with
            // its pattern's own needs and its role's missing states. So one
            // that needs nothing more of its role doesn't hide another's
            // states, as it does inside a pattern's ARIA part (below). (A14
            // review: <input role="foo" aria-selected="true"> asks for the
            // aria-checked the radio input's radio role needs, though its
            // menuitemradio role needs none.)
            for alternative in state.live {
                var needs = ownNeeds(variants[alternative.variant])
                let missing = missingStates(alternative)
                if 0 != missing {
                    needs.aria = ARIANeeds(role: -1, states: missing)
                }
                patterns.insert(needs)
            }
            return (names, hasChoice || patterns.count > 1)
        }
        // Without a role, a pattern's ARIA part is one choice inside it, of
        // its implicit and role alternatives. (The live alternatives keep the
        // order they were built in, so each variant's are together.)
        var start = 0
        while start < state.live.count {
            let index = state.live[start].variant
            var end = start + 1
            while end < state.live.count, index == state.live[end].variant {
                end += 1
            }
            let ariaAlternatives = state.live[start..<end]
            start = end
            var needs = ownNeeds(variants[index])
            if !ariaAlternatives.contains(where: { roleSatisfied($0, state: state) }) {
                // (Every one of them is a role's here: an implicit or plain
                // alternative is always satisfied.)
                var choices: Set<ARIANeeds> = []
                for alternative in ariaAlternatives where 0 <= alternative.role {
                    choices.insert(ARIANeeds(role: alternative.role, states: missingStates(alternative)))
                    names.insert("role")
                }
                hasChoice = hasChoice || choices.count > 1
                needs.aria = choices.first
            }
            patterns.insert(needs)
        }
        return (names, hasChoice || patterns.count > 1)
    }

    /// A type attribute's value as the schema compares it: decoded, ASCII
    /// letters lowercased, not trimmed ("" for one with no value).
    private static func typeValue(_ value: String?) -> String {
        let decoded = HTMLCharacterReferences.decodeAttributeValue(value ?? "")
        return String(String.UnicodeScalarView(decoded.unicodeScalars.map { ("A"..."Z").contains($0) ? Unicode.Scalar(UInt8(truncatingIfNeeded: $0.value + 0x20)) : $0 }))
    }

    /// Whether one of the element's variants can be one of its alternatives
    /// where it is: all of them but an li's for other parents and meta's
    /// microdata pattern in a noscript. (Its type and the attributes in
    /// `rejected` narrow them as they come; see narrowing.)
    private static func selects(_ variant: Variant, parent: String?) -> Bool {
        switch variant.selector {
        case .always, .type:
            return true
        case let .parent(required):
            return required == parent
        case let .notParent(excluded):
            return excluded != parent
        }
    }

    /// An SVG element's pattern (.drivers/html5-svg-mathml.rnc and svg11):
    /// any role, with an implicit pattern for some; every other SVG element
    /// takes aria.global only, and no role.
    private static func svgVariant(_ name: String) -> Variant {
        var implicit: [String] = []
        if svgImplicitGroupElements.contains(name) {
            implicit = ["group"]
        } else if svgImplicitLinkElements.contains(name) {
            implicit = ["link"]
        } else if svgImplicitImgElements.contains(name) {
            implicit = ["img"]
        }
        let takesRole = !implicit.isEmpty || svgAnyRoleElements.contains(name)
        return Variant(selector: .always, implicit: implicit, roles: takesRole ? nil : [], acceptsRole: takesRole, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: [])
    }

    /// A MathML element's pattern: math takes role="math" or its implicit
    /// pattern; no other MathML element takes any ARIA attribute.
    private static func mathMLVariant(_ name: String) -> Variant {
        if "math" == name {
            return Variant(selector: .always, implicit: ["math"], roles: ["math"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: [])
        }
        return Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: [])
    }

    // MARK: Generated from the schema (a14/gen_aria_tables.py)

    /// aria.rnc's role patterns (aria.<name>), each with its role value, the
    /// role-specific states and properties it accepts beyond aria.global, and
    /// those it requires, by pattern name. Generated from aria.rnc.
    static let rolePatterns: [String: RolePattern] = [
        "alert": RolePattern(role: "alert", allowed: ["aria-expanded"], required: []),
        "alertdialog": RolePattern(role: "alertdialog", allowed: ["aria-expanded", "aria-modal"], required: []),
        "application": RolePattern(role: "application", allowed: ["aria-activedescendant", "aria-expanded"], required: []),
        "article": RolePattern(role: "article", allowed: ["aria-expanded", "aria-posinset", "aria-setsize"], required: []),
        "banner": RolePattern(role: "banner", allowed: ["aria-expanded"], required: []),
        "blockquote": RolePattern(role: "blockquote", allowed: [], required: []),
        "button": RolePattern(role: "button", allowed: ["aria-expanded", "aria-pressed"], required: []),
        "caption": RolePattern(role: "caption", allowed: [], required: []),
        "cell": RolePattern(role: "cell", allowed: ["aria-colindex", "aria-colspan", "aria-rowindex", "aria-rowspan"], required: []),
        "checkbox": RolePattern(role: "checkbox", allowed: ["aria-checked", "aria-expanded", "aria-readonly", "aria-required"], required: ["aria-checked"]),
        "code": RolePattern(role: "code", allowed: [], required: []),
        "columnheader": RolePattern(role: "columnheader", allowed: ["aria-colindex", "aria-colspan", "aria-expanded", "aria-readonly", "aria-required", "aria-rowindex", "aria-rowspan", "aria-selected", "aria-sort"], required: []),
        "combobox": RolePattern(role: "combobox", allowed: ["aria-activedescendant", "aria-autocomplete", "aria-expanded", "aria-orientation", "aria-readonly", "aria-required"], required: ["aria-expanded"]),
        "complementary": RolePattern(role: "complementary", allowed: ["aria-expanded"], required: []),
        "contentinfo": RolePattern(role: "contentinfo", allowed: ["aria-expanded"], required: []),
        "definition": RolePattern(role: "definition", allowed: ["aria-expanded"], required: []),
        "deletion": RolePattern(role: "deletion", allowed: [], required: []),
        "dialog": RolePattern(role: "dialog", allowed: ["aria-expanded", "aria-modal"], required: []),
        "doc-abstract": RolePattern(role: "doc-abstract", allowed: [], required: []),
        "doc-acknowledgments": RolePattern(role: "doc-acknowledgments", allowed: [], required: []),
        "doc-afterword": RolePattern(role: "doc-afterword", allowed: [], required: []),
        "doc-appendix": RolePattern(role: "doc-appendix", allowed: [], required: []),
        "doc-backlink": RolePattern(role: "doc-backlink", allowed: [], required: []),
        "doc-biblioentry": RolePattern(role: "doc-biblioentry", allowed: [], required: []),
        "doc-bibliography": RolePattern(role: "doc-bibliography", allowed: [], required: []),
        "doc-biblioref": RolePattern(role: "doc-biblioref", allowed: [], required: []),
        "doc-chapter": RolePattern(role: "doc-chapter", allowed: [], required: []),
        "doc-colophon": RolePattern(role: "doc-colophon", allowed: [], required: []),
        "doc-conclusion": RolePattern(role: "doc-conclusion", allowed: [], required: []),
        "doc-cover": RolePattern(role: "doc-cover", allowed: [], required: []),
        "doc-credit": RolePattern(role: "doc-credit", allowed: [], required: []),
        "doc-credits": RolePattern(role: "doc-credits", allowed: [], required: []),
        "doc-dedication": RolePattern(role: "doc-dedication", allowed: [], required: []),
        "doc-endnote": RolePattern(role: "doc-endnote", allowed: [], required: []),
        "doc-endnotes": RolePattern(role: "doc-endnotes", allowed: [], required: []),
        "doc-epigraph": RolePattern(role: "doc-epigraph", allowed: [], required: []),
        "doc-epilogue": RolePattern(role: "doc-epilogue", allowed: [], required: []),
        "doc-errata": RolePattern(role: "doc-errata", allowed: [], required: []),
        "doc-example": RolePattern(role: "doc-example", allowed: [], required: []),
        "doc-footnote": RolePattern(role: "doc-footnote", allowed: [], required: []),
        "doc-foreword": RolePattern(role: "doc-foreword", allowed: [], required: []),
        "doc-glossary": RolePattern(role: "doc-glossary", allowed: [], required: []),
        "doc-glossref": RolePattern(role: "doc-glossref", allowed: [], required: []),
        "doc-index": RolePattern(role: "doc-index", allowed: [], required: []),
        "doc-introduction": RolePattern(role: "doc-introduction", allowed: [], required: []),
        "doc-noteref": RolePattern(role: "doc-noteref", allowed: [], required: []),
        "doc-notice": RolePattern(role: "doc-notice", allowed: [], required: []),
        "doc-pagebreak": RolePattern(role: "doc-pagebreak", allowed: [], required: []),
        "doc-pagelist": RolePattern(role: "doc-pagelist", allowed: [], required: []),
        "doc-part": RolePattern(role: "doc-part", allowed: [], required: []),
        "doc-preface": RolePattern(role: "doc-preface", allowed: [], required: []),
        "doc-prologue": RolePattern(role: "doc-prologue", allowed: [], required: []),
        "doc-pullquote": RolePattern(role: "doc-pullquote", allowed: [], required: []),
        "doc-qna": RolePattern(role: "doc-qna", allowed: [], required: []),
        "doc-subtitle": RolePattern(role: "doc-subtitle", allowed: [], required: []),
        "doc-tip": RolePattern(role: "doc-tip", allowed: [], required: []),
        "doc-toc": RolePattern(role: "doc-toc", allowed: [], required: []),
        "document": RolePattern(role: "document", allowed: ["aria-expanded"], required: []),
        "emphasis": RolePattern(role: "emphasis", allowed: [], required: []),
        "feed": RolePattern(role: "feed", allowed: ["aria-expanded"], required: []),
        "figure": RolePattern(role: "figure", allowed: ["aria-expanded"], required: []),
        "form": RolePattern(role: "form", allowed: ["aria-expanded"], required: []),
        "graphics-document": RolePattern(role: "graphics-document", allowed: [], required: []),
        "graphics-object": RolePattern(role: "graphics-object", allowed: [], required: []),
        "graphics-symbol": RolePattern(role: "graphics-symbol", allowed: [], required: []),
        "grid": RolePattern(role: "grid", allowed: ["aria-activedescendant", "aria-colcount", "aria-expanded", "aria-level", "aria-multiselectable", "aria-readonly", "aria-rowcount"], required: []),
        "gridcell": RolePattern(role: "gridcell", allowed: ["aria-colindex", "aria-colspan", "aria-expanded", "aria-level", "aria-readonly", "aria-required", "aria-rowindex", "aria-rowspan", "aria-selected"], required: []),
        "group": RolePattern(role: "group", allowed: ["aria-activedescendant", "aria-expanded"], required: []),
        "heading": RolePattern(role: "heading", allowed: ["aria-expanded", "aria-level"], required: ["aria-level"]),
        "image": RolePattern(role: "image", allowed: ["aria-expanded"], required: []),
        "img": RolePattern(role: "img", allowed: ["aria-expanded"], required: []),
        "insertion": RolePattern(role: "insertion", allowed: [], required: []),
        "link": RolePattern(role: "link", allowed: ["aria-expanded"], required: []),
        "list": RolePattern(role: "list", allowed: ["aria-expanded"], required: []),
        "listbox": RolePattern(role: "listbox", allowed: ["aria-activedescendant", "aria-multiselectable", "aria-orientation", "aria-readonly", "aria-required"], required: []),
        "listitem": RolePattern(role: "listitem", allowed: ["aria-expanded", "aria-level", "aria-posinset", "aria-setsize"], required: []),
        "log": RolePattern(role: "log", allowed: ["aria-expanded"], required: []),
        "main": RolePattern(role: "main", allowed: ["aria-expanded"], required: []),
        "marquee": RolePattern(role: "marquee", allowed: ["aria-expanded"], required: []),
        "math": RolePattern(role: "math", allowed: ["aria-expanded"], required: []),
        "menu": RolePattern(role: "menu", allowed: ["aria-activedescendant", "aria-expanded", "aria-orientation"], required: []),
        "menubar": RolePattern(role: "menubar", allowed: ["aria-activedescendant", "aria-expanded", "aria-orientation"], required: []),
        "menuitem": RolePattern(role: "menuitem", allowed: ["aria-expanded", "aria-posinset", "aria-setsize"], required: []),
        "menuitemcheckbox": RolePattern(role: "menuitemcheckbox", allowed: ["aria-checked", "aria-expanded", "aria-posinset", "aria-setsize"], required: ["aria-checked"]),
        "menuitemcheckbox-checked-not-required": RolePattern(role: "menuitemcheckbox", allowed: ["aria-expanded", "aria-posinset", "aria-setsize"], required: []),
        "menuitemradio": RolePattern(role: "menuitemradio", allowed: ["aria-checked", "aria-expanded", "aria-posinset", "aria-selected", "aria-setsize"], required: ["aria-checked"]),
        "menuitemradio-checked-not-required": RolePattern(role: "menuitemradio", allowed: ["aria-expanded", "aria-posinset", "aria-selected", "aria-setsize"], required: []),
        "meter": RolePattern(role: "meter", allowed: ["aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], required: ["aria-valuenow"]),
        "navigation": RolePattern(role: "navigation", allowed: ["aria-expanded"], required: []),
        "none": RolePattern(role: "none", allowed: [], required: []),
        "note": RolePattern(role: "note", allowed: ["aria-expanded"], required: []),
        "option": RolePattern(role: "option", allowed: ["aria-checked", "aria-posinset", "aria-selected", "aria-setsize"], required: []),
        "paragraph": RolePattern(role: "paragraph", allowed: [], required: []),
        "presentation": RolePattern(role: "presentation", allowed: [], required: []),
        "progressbar": RolePattern(role: "progressbar", allowed: ["aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], required: []),
        "radio": RolePattern(role: "radio", allowed: ["aria-checked", "aria-posinset", "aria-selected", "aria-setsize"], required: ["aria-checked"]),
        "radiogroup": RolePattern(role: "radiogroup", allowed: ["aria-activedescendant", "aria-expanded", "aria-orientation", "aria-readonly", "aria-required"], required: []),
        "region": RolePattern(role: "region", allowed: ["aria-expanded"], required: []),
        "row": RolePattern(role: "row", allowed: ["aria-activedescendant", "aria-colindex", "aria-expanded", "aria-level", "aria-posinset", "aria-rowindex", "aria-selected", "aria-setsize"], required: []),
        "rowgroup": RolePattern(role: "rowgroup", allowed: ["aria-activedescendant", "aria-expanded"], required: []),
        "rowheader": RolePattern(role: "rowheader", allowed: ["aria-colindex", "aria-colspan", "aria-expanded", "aria-readonly", "aria-required", "aria-rowindex", "aria-rowspan", "aria-selected", "aria-sort"], required: []),
        "scrollbar": RolePattern(role: "scrollbar", allowed: ["aria-orientation", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], required: ["aria-valuenow"]),
        "search": RolePattern(role: "search", allowed: ["aria-expanded", "aria-orientation"], required: []),
        "searchbox": RolePattern(role: "searchbox", allowed: ["aria-activedescendant", "aria-autocomplete", "aria-multiline", "aria-placeholder", "aria-readonly", "aria-required"], required: []),
        "separator": RolePattern(role: "separator", allowed: ["aria-expanded", "aria-orientation", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], required: []),
        "slider": RolePattern(role: "slider", allowed: ["aria-orientation", "aria-readonly", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], required: ["aria-valuenow"]),
        "spinbutton": RolePattern(role: "spinbutton", allowed: ["aria-activedescendant", "aria-readonly", "aria-required", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], required: []),
        "status": RolePattern(role: "status", allowed: ["aria-expanded"], required: []),
        "strong": RolePattern(role: "strong", allowed: [], required: []),
        "subscript": RolePattern(role: "subscript", allowed: [], required: []),
        "superscript": RolePattern(role: "superscript", allowed: [], required: []),
        "switch": RolePattern(role: "switch", allowed: ["aria-checked", "aria-expanded", "aria-readonly", "aria-required"], required: ["aria-checked"]),
        "switch-checked-not-required": RolePattern(role: "switch", allowed: ["aria-expanded", "aria-readonly", "aria-required"], required: []),
        "tab": RolePattern(role: "tab", allowed: ["aria-expanded", "aria-posinset", "aria-selected", "aria-setsize"], required: []),
        "table": RolePattern(role: "table", allowed: ["aria-colcount", "aria-rowcount"], required: []),
        "tablist": RolePattern(role: "tablist", allowed: ["aria-activedescendant", "aria-expanded", "aria-level", "aria-multiselectable", "aria-orientation"], required: []),
        "tabpanel": RolePattern(role: "tabpanel", allowed: ["aria-expanded"], required: []),
        "term": RolePattern(role: "term", allowed: ["aria-expanded"], required: []),
        "textbox": RolePattern(role: "textbox", allowed: ["aria-activedescendant", "aria-autocomplete", "aria-multiline", "aria-placeholder", "aria-readonly", "aria-required"], required: []),
        "time": RolePattern(role: "time", allowed: [], required: []),
        "timer": RolePattern(role: "timer", allowed: ["aria-expanded"], required: []),
        "toolbar": RolePattern(role: "toolbar", allowed: ["aria-activedescendant", "aria-expanded", "aria-orientation"], required: []),
        "tooltip": RolePattern(role: "tooltip", allowed: ["aria-expanded"], required: []),
        "tree": RolePattern(role: "tree", allowed: ["aria-activedescendant", "aria-expanded", "aria-multiselectable", "aria-orientation", "aria-required"], required: []),
        "treegrid": RolePattern(role: "treegrid", allowed: ["aria-activedescendant", "aria-colcount", "aria-expanded", "aria-level", "aria-multiselectable", "aria-orientation", "aria-readonly", "aria-required", "aria-rowcount"], required: []),
        "treeitem": RolePattern(role: "treeitem", allowed: ["aria-checked", "aria-expanded", "aria-level", "aria-posinset", "aria-selected", "aria-setsize"], required: []),
    ]

    /// common.attrs.aria: the role patterns of an element that takes any role
    /// (the 123 of aria.rnc's patterns it lists).
    static let anyRolePatterns: [String] = [
        "alert", "alertdialog", "application", "article", "banner", "blockquote", "button", "caption", "cell",
        "checkbox", "code", "columnheader", "combobox", "complementary", "contentinfo", "definition", "deletion",
        "dialog", "doc-abstract", "doc-acknowledgments", "doc-afterword", "doc-appendix", "doc-backlink",
        "doc-biblioentry", "doc-bibliography", "doc-biblioref", "doc-chapter", "doc-colophon", "doc-conclusion",
        "doc-cover", "doc-credit", "doc-credits", "doc-dedication", "doc-endnote", "doc-endnotes", "doc-epigraph",
        "doc-epilogue", "doc-errata", "doc-example", "doc-footnote", "doc-foreword", "doc-glossary", "doc-glossref",
        "doc-index", "doc-introduction", "doc-noteref", "doc-notice", "doc-pagebreak", "doc-pagelist", "doc-part",
        "doc-preface", "doc-prologue", "doc-pullquote", "doc-qna", "doc-subtitle", "doc-tip", "doc-toc", "document",
        "emphasis", "feed", "figure", "form", "graphics-document", "graphics-object", "graphics-symbol", "grid",
        "gridcell", "group", "heading", "image", "img", "insertion", "link", "list", "listbox", "listitem", "log",
        "main", "marquee", "math", "menu", "menubar", "menuitem", "menuitemcheckbox", "menuitemradio", "meter",
        "navigation", "none", "note", "option", "paragraph", "presentation", "progressbar", "radio", "radiogroup",
        "region", "row", "rowgroup", "rowheader", "scrollbar", "search", "searchbox", "separator", "slider",
        "spinbutton", "status", "strong", "subscript", "superscript", "switch", "tab", "table", "tablist",
        "tabpanel", "term", "textbox", "time", "timer", "toolbar", "tooltip", "tree", "treegrid", "treeitem",
    ]

    /// aria.rnc's implicit patterns (common.attrs.aria.implicit.<name>): the
    /// states and properties an element with that implicit role accepts with
    /// no role attribute, beyond aria.global.
    static let implicitPatterns: [String: Set<String>] = [
        "article": ["aria-expanded"],
        "banner": ["aria-expanded"],
        "button": ["aria-expanded", "aria-pressed"],
        "cell": ["aria-colindex", "aria-colspan", "aria-rowindex", "aria-rowspan"],
        "checkbox": ["aria-checked", "aria-expanded", "aria-readonly", "aria-required"],
        "column-or-row-header": ["aria-colindex", "aria-colspan", "aria-expanded", "aria-readonly", "aria-required", "aria-rowindex", "aria-rowspan", "aria-selected", "aria-sort"],
        "combobox": ["aria-activedescendant", "aria-autocomplete", "aria-expanded", "aria-placeholder", "aria-readonly", "aria-required"],
        "complementary": ["aria-expanded"],
        "contentinfo": ["aria-expanded"],
        "definition": ["aria-expanded"],
        "dialog": ["aria-expanded", "aria-modal"],
        "document": ["aria-expanded"],
        "figure": ["aria-expanded"],
        "form": ["aria-expanded"],
        "gridcell": ["aria-colindex", "aria-colspan", "aria-expanded", "aria-level", "aria-readonly", "aria-required", "aria-rowindex", "aria-rowspan", "aria-selected"],
        "group": ["aria-activedescendant", "aria-expanded"],
        "heading": ["aria-expanded", "aria-level"],
        "img": ["aria-expanded"],
        "landmark": ["aria-expanded"],
        "link": ["aria-expanded"],
        "list": ["aria-expanded"],
        "listbox": ["aria-activedescendant", "aria-multiselectable", "aria-required"],
        "listitem": ["aria-expanded", "aria-level", "aria-posinset", "aria-setsize"],
        "main": ["aria-expanded"],
        "math": ["aria-expanded"],
        "navigation": ["aria-expanded"],
        "option": ["aria-checked", "aria-posinset", "aria-selected", "aria-setsize"],
        "progressbar": ["aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"],
        "radio": ["aria-checked", "aria-posinset", "aria-required", "aria-selected", "aria-setsize"],
        "region": ["aria-expanded"],
        "row": ["aria-activedescendant", "aria-colindex", "aria-expanded", "aria-level", "aria-posinset", "aria-rowindex", "aria-selected", "aria-setsize"],
        "rowgroup": ["aria-activedescendant", "aria-expanded"],
        "search": ["aria-expanded"],
        "searchbox": ["aria-activedescendant", "aria-autocomplete", "aria-multiline", "aria-placeholder", "aria-readonly", "aria-required"],
        "section": ["aria-expanded"],
        "separator": ["aria-orientation", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"],
        "slider": ["aria-orientation", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"],
        "spinbutton": ["aria-placeholder", "aria-required", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"],
        "status": ["aria-expanded"],
        "table": ["aria-colcount", "aria-rowcount"],
        "term": ["aria-expanded"],
        "textbox": ["aria-activedescendant", "aria-autocomplete", "aria-multiline", "aria-placeholder", "aria-readonly", "aria-required"],
        "toolbar": ["aria-activedescendant", "aria-expanded"],
    ]

    /// The HTML elements' patterns, as far as ARIA goes: for each element,
    /// each of its patterns (several where the schema has several, as for
    /// input's types), with what selects it, its implicit patterns, the role
    /// patterns it accepts (nil: any, anyRolePatterns), whether it takes a
    /// role attribute at all, its other aria-* attributes, and the other
    /// attributes it requires (a list for a choice, as img's src or srcset).
    /// Generated from the html5 schema files.
    static let htmlElements: [String: [Variant]] = [
        "a": [
            Variant(selector: .always, implicit: ["link"], roles: ["button", "checkbox", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "switch", "tab", "treeitem", "doc-backlink", "doc-biblioref", "doc-glossref", "doc-noteref"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["href"]], rejected: []),
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["about", "charset", "content", "coords", "datatype", "download", "href", "hreflang", "inlist", "itemid", "itemprop", "itemref", "itemscope", "itemtype", "methods", "name", "ping", "prefix", "property", "referrerpolicy", "rel", "resource", "rev", "shape", "target", "type", "typeof", "urn", "vocab"]),
        ],
        "abbr": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "acronym": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "address": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "applet": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "area": [
            Variant(selector: .always, implicit: ["link"], roles: ["link", "button"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "article": [
            Variant(selector: .always, implicit: ["article"], roles: ["article", "document", "application", "main", "feed", "region", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "aside": [
            Variant(selector: .always, implicit: ["complementary"], roles: ["note", "complementary", "search", "feed", "region", "presentation", "none", "doc-dedication", "doc-example", "doc-footnote", "doc-glossary", "doc-pullquote", "doc-tip"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "audio": [
            Variant(selector: .always, implicit: [], roles: ["application"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "b": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "base": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "basefont": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "bdi": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "bdo": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "bgsound": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "big": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "blink": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "blockquote": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "body": [
            Variant(selector: .always, implicit: ["document"], roles: ["application", "document", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "br": [
            Variant(selector: .always, implicit: [], roles: ["presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "button": [
            Variant(selector: .type("submit", optional: true), implicit: ["button"], roles: ["button", "checkbox", "combobox", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "separator", "tab", "gridcell", "slider", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("reset", optional: false), implicit: ["button"], roles: ["button", "checkbox", "combobox", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "separator", "switch", "gridcell", "slider", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["formaction", "formenctype", "formmethod", "formnovalidate", "formtarget"]),
            Variant(selector: .type("button", optional: false), implicit: ["button"], roles: ["button", "checkbox", "combobox", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "separator", "switch", "tab", "gridcell", "slider", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["formaction", "formenctype", "formmethod", "formnovalidate", "formtarget"]),
        ],
        "canvas": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "caption": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "center": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "cite": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "code": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "col": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "colgroup": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "data": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["value"]], rejected: []),
        ],
        "datalist": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "dd": [
            Variant(selector: .always, implicit: ["definition"], roles: ["definition"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "del": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "details": [
            Variant(selector: .always, implicit: ["group"], roles: ["group"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "dfn": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "dialog": [
            Variant(selector: .always, implicit: ["dialog"], roles: ["alertdialog", "dialog"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "dir": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "div": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "dl": [
            Variant(selector: .always, implicit: [], roles: ["list", "group", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "dt": [
            Variant(selector: .always, implicit: ["term"], roles: ["term", "listitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "em": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "embed": [
            Variant(selector: .always, implicit: [], roles: ["application", "document", "img", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: ["aria-autocomplete", "aria-checked", "aria-colcount", "aria-colindex", "aria-colspan", "aria-level", "aria-modal", "aria-multiline", "aria-multiselectable", "aria-orientation", "aria-placeholder", "aria-posinset", "aria-pressed", "aria-readonly", "aria-rowcount", "aria-rowindex", "aria-rowspan", "aria-selected", "aria-setsize", "aria-sort", "aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext"], requiredGroups: [], rejected: []),
        ],
        "fieldset": [
            Variant(selector: .always, implicit: ["group"], roles: ["group", "radiogroup", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "figcaption": [
            Variant(selector: .always, implicit: [], roles: ["presentation", "none", "group"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "figure": [
            Variant(selector: .always, implicit: ["figure"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "font": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "footer": [
            Variant(selector: .always, implicit: ["contentinfo"], roles: ["contentinfo", "group", "presentation", "none", "doc-footnote"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "form": [
            Variant(selector: .always, implicit: ["form"], roles: ["form", "search", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "frame": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "frameset": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "h1": [
            Variant(selector: .always, implicit: ["heading"], roles: ["heading", "tab", "presentation", "none", "doc-subtitle"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "h2": [
            Variant(selector: .always, implicit: ["heading"], roles: ["heading", "tab", "presentation", "none", "doc-subtitle"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "h3": [
            Variant(selector: .always, implicit: ["heading"], roles: ["heading", "tab", "presentation", "none", "doc-subtitle"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "h4": [
            Variant(selector: .always, implicit: ["heading"], roles: ["heading", "tab", "presentation", "none", "doc-subtitle"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "h5": [
            Variant(selector: .always, implicit: ["heading"], roles: ["heading", "tab", "presentation", "none", "doc-subtitle"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "h6": [
            Variant(selector: .always, implicit: ["heading"], roles: ["heading", "tab", "presentation", "none", "doc-subtitle"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "head": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "header": [
            Variant(selector: .always, implicit: ["banner"], roles: ["banner", "group", "presentation", "none", "doc-footnote"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "hgroup": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "hr": [
            Variant(selector: .always, implicit: ["separator"], roles: ["separator", "presentation", "none", "doc-pagebreak"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "html": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "i": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "iframe": [
            Variant(selector: .always, implicit: [], roles: ["application", "document", "img", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "img": [
            Variant(selector: .always, implicit: ["img"], roles: ["button", "checkbox", "img", "link", "math", "menuitem", "menuitemcheckbox", "menuitemradio", "none", "option", "presentation", "progressbar", "radio", "scrollbar", "separator", "slider", "switch", "tab", "treeitem", "doc-cover"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["src", "srcset"]], rejected: []),
        ],
        "input": [
            Variant(selector: .type("text", optional: true), implicit: ["textbox"], roles: ["textbox", "combobox", "searchbox", "spinbutton"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("password", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-placeholder", "aria-required"], requiredGroups: [], rejected: []),
            Variant(selector: .type("checkbox", optional: false), implicit: ["checkbox"], roles: ["checkbox", "button", "menuitemcheckbox-checked-not-required", "option", "switch-checked-not-required"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("radio", optional: false), implicit: ["radio"], roles: ["radio", "menuitemradio-checked-not-required"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("button", optional: false), implicit: ["button"], roles: ["button", "checkbox", "combobox", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "separator", "switch", "tab", "gridcell", "slider", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("submit", optional: false), implicit: ["button"], roles: ["button", "checkbox", "combobox", "gridcell", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "slider", "switch", "tab", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("reset", optional: false), implicit: ["button"], roles: ["button", "checkbox", "combobox", "gridcell", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "slider", "switch", "tab", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("file", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-required"], requiredGroups: [], rejected: []),
            Variant(selector: .type("hidden", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("image", optional: false), implicit: ["button"], roles: ["button", "checkbox", "combobox", "gridcell", "link", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "separator", "slider", "switch", "tab", "treeitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["alt"]], rejected: []),
            Variant(selector: .type("datetime-local", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-required", "aria-valuemax", "aria-valuemin"], requiredGroups: [], rejected: []),
            Variant(selector: .type("date", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-required", "aria-valuemax", "aria-valuemin"], requiredGroups: [], rejected: []),
            Variant(selector: .type("month", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-required", "aria-valuemax", "aria-valuemin"], requiredGroups: [], rejected: []),
            Variant(selector: .type("time", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-required", "aria-valuemax", "aria-valuemin"], requiredGroups: [], rejected: []),
            Variant(selector: .type("week", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-required", "aria-valuemax", "aria-valuemin"], requiredGroups: [], rejected: []),
            Variant(selector: .type("number", optional: false), implicit: ["spinbutton"], roles: ["spinbutton"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("range", optional: false), implicit: ["slider"], roles: ["slider"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("email", optional: false), implicit: ["textbox"], roles: ["textbox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["list"]),
            Variant(selector: .type("email", optional: false), implicit: ["combobox"], roles: ["combobox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["list"]], rejected: []),
            Variant(selector: .type("url", optional: false), implicit: ["textbox"], roles: ["textbox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["list"]),
            Variant(selector: .type("url", optional: false), implicit: ["combobox"], roles: ["combobox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["list"]], rejected: []),
            Variant(selector: .type("search", optional: false), implicit: ["searchbox"], roles: ["searchbox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .type("tel", optional: false), implicit: ["textbox"], roles: ["textbox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["list"]),
            Variant(selector: .type("tel", optional: false), implicit: ["combobox"], roles: ["combobox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["list"]], rejected: []),
            Variant(selector: .type("color", optional: false), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "ins": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "isindex": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "kbd": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "keygen": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "label": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "legend": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "li": [
            Variant(selector: .parent("ul"), implicit: ["listitem"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .parent("ol"), implicit: ["listitem"], roles: ["listitem", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "tab", "treeitem", "separator", "presentation", "none", "doc-biblioentry", "doc-endnote"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
            Variant(selector: .parent("menu"), implicit: [], roles: ["listitem", "menuitem", "menuitemcheckbox", "menuitemradio", "option", "tab", "treeitem", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "link": [
            Variant(selector: .always, implicit: [], roles: ["link", "presentation", "none", "menuitem"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "listing": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "main": [
            Variant(selector: .always, implicit: ["main"], roles: ["main"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "map": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "mark": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "marquee": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "menu": [
            Variant(selector: .always, implicit: ["list"], roles: ["group", "list", "listbox", "menu", "menubar", "radiogroup", "tablist", "toolbar", "tree", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "menuitem": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "meta": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["itemprop"]),
            Variant(selector: .notParent("noscript"), implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [["content"], ["itemprop"]], rejected: ["about", "charset", "datatype", "http-equiv", "inlist", "media", "name", "prefix", "property", "resource", "scheme", "typeof", "vocab"]),
        ],
        "meter": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: ["aria-valuemax", "aria-valuemin"], requiredGroups: [["value"]], rejected: []),
        ],
        "multicol": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "nav": [
            Variant(selector: .always, implicit: ["navigation"], roles: ["navigation", "doc-index", "doc-pagelist", "doc-toc", "menu", "menubar", "none", "presentation", "tablist"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "nextid": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "nobr": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "noembed": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "noframes": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "noscript": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "object": [
            Variant(selector: .always, implicit: [], roles: ["application", "document", "img"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["data"]], rejected: []),
        ],
        "ol": [
            Variant(selector: .always, implicit: ["list"], roles: ["group", "list", "listbox", "menu", "menubar", "radiogroup", "tablist", "toolbar", "tree", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "optgroup": [
            Variant(selector: .always, implicit: ["group"], roles: ["group"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "option": [
            Variant(selector: .always, implicit: ["option"], roles: ["option"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "output": [
            Variant(selector: .always, implicit: ["status"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "p": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "param": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "picture": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "plaintext": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "pre": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "progress": [
            Variant(selector: .always, implicit: ["progressbar"], roles: ["progressbar"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "q": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "rb": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "rp": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "rt": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "rtc": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "ruby": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "s": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "samp": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "script": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "search": [
            Variant(selector: .always, implicit: ["search"], roles: ["search", "form", "group", "none", "presentation", "region"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "section": [
            Variant(selector: .always, implicit: ["region"], roles: ["alert", "alertdialog", "application", "dialog", "feed", "group", "log", "marquee", "presentation", "none", "region", "status", "tabpanel", "banner", "complementary", "contentinfo", "document", "main", "navigation", "note", "search", "doc-abstract", "doc-acknowledgments", "doc-afterword", "doc-appendix", "doc-bibliography", "doc-chapter", "doc-colophon", "doc-conclusion", "doc-credit", "doc-credits", "doc-dedication", "doc-endnotes", "doc-epigraph", "doc-epilogue", "doc-errata", "doc-example", "doc-foreword", "doc-glossary", "doc-index", "doc-introduction", "doc-notice", "doc-pagelist", "doc-part", "doc-preface", "doc-prologue", "doc-pullquote", "doc-qna", "doc-toc"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "select": [
            Variant(selector: .always, implicit: ["combobox", "listbox"], roles: ["listbox", "combobox", "menu"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "selectedcontent": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "slot": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "small": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "source": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "spacer": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "span": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "strike": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "strong": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "style": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "sub": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "summary": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "sup": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "table": [
            Variant(selector: .always, implicit: ["table"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "tbody": [
            Variant(selector: .always, implicit: ["rowgroup"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "td": [
            Variant(selector: .always, implicit: ["cell", "gridcell"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "template": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "textarea": [
            Variant(selector: .always, implicit: ["textbox"], roles: ["textbox"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "tfoot": [
            Variant(selector: .always, implicit: ["rowgroup"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "th": [
            Variant(selector: .always, implicit: ["column-or-row-header"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "thead": [
            Variant(selector: .always, implicit: ["rowgroup"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "time": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: ["datetime"]),
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [["datetime"]], rejected: []),
        ],
        "title": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "tr": [
            Variant(selector: .always, implicit: ["row"], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "track": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "tt": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "u": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "ul": [
            Variant(selector: .always, implicit: ["list"], roles: ["group", "list", "listbox", "menu", "menubar", "radiogroup", "tablist", "toolbar", "tree", "presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "var": [
            Variant(selector: .always, implicit: [], roles: nil, acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "video": [
            Variant(selector: .always, implicit: [], roles: ["application"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "wbr": [
            Variant(selector: .always, implicit: [], roles: ["presentation", "none"], acceptsRole: true, anyAttribute: false, extraARIA: [], requiredGroups: [], rejected: []),
        ],
        "xmp": [
            Variant(selector: .always, implicit: [], roles: [], acceptsRole: false, anyAttribute: true, extraARIA: [], requiredGroups: [], rejected: []),
        ],
    ]

    /// The SVG elements that take a role attribute: any role, and some with
    /// an implicit pattern as well (.drivers/html5-svg-mathml.rnc and svg11).
    /// Every other SVG element takes aria.global only.
    static let svgAnyRoleElements: Set<String> = ["circle", "ellipse", "line", "path", "polygon", "rect", "svg", "symbol", "use"]
    static let svgImplicitGroupElements: Set<String> = ["altglyph", "foreignobject", "g", "glyph", "glyphref", "polyline", "text", "tspan"]
    static let svgImplicitLinkElements: Set<String> = ["a"]
    static let svgImplicitImgElements: Set<String> = ["image"]
}
