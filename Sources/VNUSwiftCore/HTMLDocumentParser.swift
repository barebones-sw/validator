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
        // Quirks mode changes one implicit closure (<table> doesn't close an
        // open <p>); see HTMLImplicitClosures.isQuirksMode.
        var sawDoctype = false
        var sawStartTag = false
        var quirksMode = false

        for token in tokens {
            switch token {
            case let .doctype(offset, length):
                events.append(.doctype(range: HTMLSourceRange(offset: offset, length: length)))
                if !sawStartTag {
                    sawDoctype = true
                }
            case let .startTag(name, attributes, selfClosing, offset, length):
                if !sawStartTag {
                    sawStartTag = true
                    quirksMode = HTMLImplicitClosures.isQuirksMode(sawDoctype: sawDoctype)
                }
                closeImplicitElements(beforeStarting: name, quirksMode: quirksMode, stack: &stack, events: &events)
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
        quirksMode: Bool,
        stack: inout [OpenElement],
        events: inout [HTMLDocumentEvent]
    ) {
        // Case 554591: this used to close the nearest open "li" (or "dd"/"dt")
        // anywhere on the stack, which reached through a nested <ul>/<ol>/<dl>
        // and closed the *outer* list item, so every nested list produced a
        // corrupt event tree for the downstream checkers. It also only closed a
        // "p" that was the current node. Use the same spec-derived rules as
        // HTMLValidator so both views of the tree agree. (Parse errors are
        // reported by HTMLValidator; this builder only needs the tree shape.)
        let closure = HTMLImplicitClosures.beforeStartTag(name, openElements: stack.map(\.name), quirksMode: quirksMode)
        while stack.count > closure.keepCount {
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

/// Which open elements a start tag or an end tag closes *implicitly*, following
/// the WHATWG HTML tree-construction algorithm ("in head", "in body", "in
/// table", "in caption", "in table body", "in row", "in cell" and "in column
/// group" insertion modes), and the parse errors the upstream Nu parser
/// (htmlparser's TreeBuilder) reports while doing so.
///
/// Case 554591: HTMLValidator and HTMLTreeEventBuilder each had their own
/// ad-hoc approximation of this, and both got it wrong for any document that
/// relies on HTML's optional end tags or simply nests lists (an inner <li>
/// closed the outer one). Valid pages that the W3C's checker accepts were
/// reported as having dozens of errors. Both now share this one model.
///
/// This is deliberately limited to the HTML namespace and to the decisions that
/// matter for validation: which elements are popped. It doesn't insert implied
/// elements (<body>, <tbody>), and it doesn't model the adoption agency
/// algorithm, foster parenting (beyond reporting it), or foreign content.
enum HTMLImplicitClosures {
    struct Closure: Equatable {
        /// Entries below this index stay open; everything at or above it is
        /// popped (in order, from the top).
        var keepCount: Int
        /// Parse errors (message text) the Nu parser reports for this closure.
        var errors: [String]
    }

    // MARK: Element categories, taken from upstream's ElementName flags

    /// "Generate implied end tags" pops these while one is the current node.
    static let impliedEndTagElements: Set<String> = [
        "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc"
    ]

    /// The implied-end-tag elements that aren't "special". An "any other end
    /// tag" (</span>, </video>, </noscript>, a custom element, ...) closes these
    /// quietly but is blocked by an open <p>, <li>, <dd> or <dt>, which are.
    private static let nonSpecialImpliedEndTagElements: Set<String> = [
        "optgroup", "option", "rb", "rp", "rt", "rtc"
    ]

    /// The parser's "special" category (HTML namespace), exactly as upstream's
    /// ElementName marks it (upstream includes <dialog>, which the spec's list
    /// doesn't). The li/dd/dt start tag steps stop walking down the stack at
    /// one of these, other than address/div/p, which is what keeps an inner
    /// list item from closing an outer one: the inner <ul>/<ol>/<dl> is special.
    static let specialElements: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont",
        "bgsound", "blockquote", "body", "br", "button", "caption", "center",
        "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt",
        "embed", "fieldset", "figcaption", "figure", "footer", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li",
        "link", "listing", "main", "marquee", "menu", "meta", "nav", "noembed",
        "noframes", "noscript", "object", "ol", "p", "param", "plaintext",
        "pre", "script", "search", "section", "select", "style", "summary",
        "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
        "title", "tr", "track", "ul", "wbr", "xmp"
    ]

    /// Start tags that "close a p element" when a <p> is in button scope.
    /// This is the reason <p>Intro<ul>...</ul> and <p>One<p>Two are valid: the
    /// paragraph's end tag is implied, not missing. (<table> only does this
    /// outside quirks mode; see beforeStartTag.)
    static let paragraphClosingStartTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details",
        "dialog", "dir", "div", "dl", "dd", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "li", "listing", "main", "menu", "nav", "ol",
        "p", "plaintext", "pre", "search", "section", "summary", "table", "ul",
        "xmp"
    ]

    /// "Has an element in scope" stops at these: upstream's SCOPING elements.
    /// <select> is one (customizable-select parsing), so e.g. an <hr> or <div>
    /// inside <p><select> doesn't reach out and close the paragraph.
    static let defaultScopeBoundaries: Set<String> = [
        "applet", "caption", "html", "marquee", "object", "select", "table",
        "td", "template", "th"
    ]

    /// "Has an element in button scope": default scope plus <button>, which
    /// is why a <div> inside <p><button> doesn't close the paragraph.
    static let buttonScopeBoundaries: Set<String> = defaultScopeBoundaries.union(["button"])

    /// Start tags that stay in <head> ("in head" insertion mode); any other
    /// start tag while <head> is the current node implies </head>.
    private static let headContentStartTags: Set<String> = [
        "base", "basefont", "bgsound", "head", "html", "link", "meta",
        "noframes", "noscript", "script", "style", "template", "title"
    ]

    /// Start tags the table insertion modes accept; anything else seen while
    /// in a table (not inside a cell or caption) is foster-parented and is a
    /// parse error ("Start tag \"x\" seen in \"table\".").
    private static let tableModeStartTags: Set<String> = [
        "caption", "col", "colgroup", "script", "style", "table", "tbody", "td",
        "template", "tfoot", "th", "thead", "tr"
    ]

    /// Table structure that the table-related end tags pop without complaint;
    /// e.g. </table> closes an open cell, row and row group silently.
    private static let tableStructureElements: Set<String> = [
        "caption", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"
    ]

    private static let rowGroupElements: Set<String> = ["tbody", "tfoot", "thead"]

    /// What a new cell's insertion keeps open: its row, or failing that the
    /// row group.
    private static let rowOrRowGroupElements: Set<String> = rowGroupElements.union(["tr"])

    /// End tags upstream handles with "if in scope, generate implied end tags,
    /// then check the current node", so open elements with optional end tags
    /// (li, p, dd, option, ...) are closed quietly.
    private static let impliedEndTagClosingEndTags: Set<String> = [
        "address", "applet", "article", "aside", "blockquote", "button",
        "caption", "center", "dd", "details", "dialog", "dir", "div", "dl",
        "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2",
        "h3", "h4", "h5", "h6", "header", "hgroup", "li", "listing", "main",
        "marquee", "menu", "nav", "object", "ol", "p", "pre", "search",
        "section", "select", "summary", "td", "th", "ul"
    ]

    /// Formatting elements; their end tags run the adoption agency algorithm,
    /// which reports a nesting error unless the element is the current node.
    private static let formattingElements: Set<String> = [
        "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small",
        "strike", "strong", "tt", "u"
    ]

    /// What </body> may close without "End tag for \"body\" seen, but there were
    /// unclosed elements." (upstream's uncloseloop1), and </html>'s variant
    /// (uncloseloop2, which also allows an open <head> or <body>).
    private static let bodyEndQuietElements: Set<String> = [
        "body", "dd", "dt", "html", "li", "optgroup", "option", "p", "rb", "rp",
        "rt", "rtc", "tbody", "td", "tfoot", "th", "thead", "tr"
    ]
    private static let htmlEndQuietElements: Set<String> = [
        "body", "dd", "dt", "head", "html", "li", "p", "rb", "rp", "rt", "rtc",
        "tbody", "td", "tfoot", "th", "thead", "tr"
    ]

    // MARK: Document mode

    /// Whether the parser is in quirks mode. Upstream also derives quirks (and
    /// limited quirks) from legacy doctype public/system identifiers; this
    /// port only distinguishes the common cases: a missing doctype is quirks,
    /// any doctype is treated as no-quirks.
    static func isQuirksMode(sawDoctype: Bool) -> Bool {
        !sawDoctype
    }

    // MARK: Start tags

    /// The implicit closures that happen before `name`'s element is inserted.
    static func beforeStartTag(_ name: String, openElements: [String], quirksMode: Bool) -> Closure {
        var names = openElements
        var errors: [String] = []

        // "In head": anything that doesn't belong in <head> implies </head>
        // (e.g. a document that omits </head> before <body>). Without this
        // the rest of the page stayed inside <head>, and an omitted </body>
        // then made </html> report open elements.
        if "head" == names.last, !headContentStartTags.contains(name) {
            names.removeLast()
        }

        switch name {
        case "li", "dd", "dt":
            closeListItem(beforeStarting: name, names: &names, errors: &errors)
            // The algorithm's "done" step: close a p element in button scope.
            closeParagraphInButtonScope(names: &names, errors: &errors)
        case "option":
            closeBeforeOption(names: &names, errors: &errors)
        case "optgroup":
            closeBeforeOptgroup(names: &names, errors: &errors)
        case "rb", "rtc", "rp", "rt":
            closeBeforeRubyText(name, names: &names, errors: &errors)
        case "caption", "colgroup", "col", "tbody", "thead", "tfoot", "tr", "td", "th":
            closeBeforeTableContent(name, names: &names, errors: &errors)
        case "table":
            // A <table> start tag while still in a table (not in a cell or
            // caption) closes that table first; the parse error for it is
            // reported by HTMLValidator. Otherwise it's a paragraph closer,
            // except in quirks mode, where it nests inside an open <p>.
            if let tableIndex = tableInsertionModeIndex(in: names) {
                names.removeSubrange(tableIndex...)
            } else if !quirksMode {
                closeParagraphInButtonScope(names: &names, errors: &errors)
            }
        default:
            if paragraphClosingStartTags.contains(name) {
                closeParagraphInButtonScope(names: &names, errors: &errors)
            }
        }

        return Closure(keepCount: names.count, errors: errors)
    }

    /// The index of the table whose insertion modes ("in table", "in table
    /// body", "in row", "in column group") apply to the next token, or nil if
    /// we're not in one: the innermost <table> with no cell or caption open
    /// inside it. (Table scope also stops at html and template.)
    static func tableInsertionModeIndex(in names: [String]) -> Int? {
        var index = names.count - 1
        while index >= 0 {
            switch names[index] {
            case "table":
                return index
            case "td", "th", "caption", "html", "template":
                return nil
            default:
                index -= 1
            }
        }
        return nil
    }

    /// Whether a start tag seen while in a table insertion mode is one of the
    /// tags those modes handle, as opposed to content that gets
    /// foster-parented out of the table (a parse error).
    static func isTableModeStartTag(_ name: String) -> Bool {
        tableModeStartTags.contains(name)
    }

    /// "A start tag whose tag name is li" / "... one of: dd, dt".
    private static func closeListItem(beforeStarting name: String, names: inout [String], errors: inout [String]) {
        let targets: Set<String> = ("li" == name) ? ["li"] : ["dd", "dt"]
        var index = names.count - 1
        while index >= 0 {
            let node = names[index]
            if targets.contains(node) {
                // "Generate implied end tags, except for <node> elements. If the
                // current node is not a <node> element, then this is a parse
                // error." Anything left above the item after that is a
                // non-optional element the author never closed.
                if !onlyImpliedEndTags(above: index, in: names) {
                    errors.append("End tag \u{201c}\(name)\u{201d} implied, but there were open elements.")
                }
                names.removeSubrange(index...)
                return
            }
            // Stop at any special element except address/div/p; in
            // particular at a nested <ul>, <ol> or <dl>.
            if specialElements.contains(node), "address" != node, "div" != node, "p" != node {
                return
            }
            index -= 1
        }
    }

    /// "Close a p element", when "the stack of open elements has a p element
    /// in button scope".
    private static func closeParagraphInButtonScope(names: inout [String], errors: inout [String]) {
        guard let index = lastIndex(of: "p", in: names, scopeBoundaries: buttonScopeBoundaries) else {
            return
        }
        if !onlyImpliedEndTags(above: index, in: names) {
            errors.append("End tag \u{201c}p\u{201d} implied, but there were open elements.")
        }
        names.removeSubrange(index...)
    }

    /// "A start tag whose tag name is option" (customizable-select rules, as
    /// implemented by upstream's TreeBuilder).
    private static func closeBeforeOption(names: inout [String], errors: inout [String]) {
        if nil != lastIndex(of: "select", in: names, scopeBoundaries: defaultScopeBoundaries) {
            generateImpliedEndTags(names: &names, except: "optgroup")
            if nil != lastIndex(of: "option", in: names, scopeBoundaries: defaultScopeBoundaries) {
                errors.append("End tag \u{201c}option\u{201d} implied, but there were open elements.")
            }
        } else if "option" == names.last {
            names.removeLast()
        }
    }

    /// "A start tag whose tag name is optgroup".
    private static func closeBeforeOptgroup(names: inout [String], errors: inout [String]) {
        if nil != lastIndex(of: "select", in: names, scopeBoundaries: defaultScopeBoundaries) {
            generateImpliedEndTags(names: &names, except: nil)
            if nil != lastIndex(of: "option", in: names, scopeBoundaries: defaultScopeBoundaries)
                || nil != lastIndex(of: "optgroup", in: names, scopeBoundaries: defaultScopeBoundaries) {
                errors.append("End tag \u{201c}optgroup\u{201d} implied, but there were open elements.")
            }
        } else if "option" == names.last {
            names.removeLast()
        }
    }

    /// "A start tag whose tag name is one of: rb, rtc" / "... rp, rt". The
    /// <rb>/<rt>/<rp>/<rtc> end tags are optional, so the next one closes the
    /// previous one.
    private static func closeBeforeRubyText(_ name: String, names: inout [String], errors: inout [String]) {
        guard let rubyIndex = lastIndex(of: "ruby", in: names, scopeBoundaries: defaultScopeBoundaries) else {
            // Upstream's errStartTagSeenWithoutRuby; there's nothing to close.
            errors.append("Start tag \u{201c}\(name)\u{201d} seen without a \u{201c}ruby\u{201d} element being open.")
            return
        }
        let keepsRTC = ("rp" == name || "rt" == name)
        generateImpliedEndTags(names: &names, except: keepsRTC ? "rtc" : nil)
        let current = names.last
        if names.count - 1 != rubyIndex, !(keepsRTC && "rtc" == current) {
            errors.append("Unclosed children in \u{201c}ruby\u{201d}.")
        }
    }

    /// Start tags for table parts. Cells, rows, row groups, captions and
    /// column groups all have optional end tags, so starting the next part
    /// closes the previous one ("clear the stack back to a table / table body
    /// / table row context", "close the cell", and closing the caption).
    private static func closeBeforeTableContent(_ name: String, names: inout [String], errors: inout [String]) {
        // Only applies inside the innermost open table. (Table scope stops at
        // html, table and template.)
        guard let tableIndex = lastIndex(of: "table", in: names, scopeBoundaries: ["html", "template"]) else {
            return
        }

        // Which table part (if any) must stay open for the new element.
        let keepIndex: Int
        switch name {
        case "td", "th":
            // A new cell goes in the current row: close any open cell, keep
            // the row (or the row group, if a row hasn't been started).
            keepIndex = lastIndex(ofAny: rowOrRowGroupElements, in: names, above: tableIndex) ?? tableIndex
            if nil == lastIndex(ofAny: ["tr"], in: names, above: tableIndex) {
                // A cell needs a row; the <tr> start tag isn't optional, so
                // upstream implies one and reports errStartTagInTableBody.
                errors.append("\u{201c}\(name)\u{201d} start tag in table body.")
            }
        case "tr":
            // A new row closes the current row (if any) but stays in the
            // current row group.
            if let rowIndex = lastIndex(ofAny: ["tr"], in: names, above: tableIndex) {
                keepIndex = rowIndex - 1
            } else {
                keepIndex = lastIndex(ofAny: rowGroupElements, in: names, above: tableIndex) ?? tableIndex
            }
        case "col":
            // <col> belongs in the open <colgroup>; otherwise it starts an
            // implied column group directly in the table.
            keepIndex = ("colgroup" == names.last) ? names.count - 1 : tableIndex
        default:
            // caption, colgroup, tbody, thead, tfoot sit directly in <table>.
            keepIndex = tableIndex
        }

        guard keepIndex < names.count - 1 else {
            return
        }

        // "Close the cell" reports non-optional elements left open inside it,
        // and closing a caption the same way ("Unclosed elements on stack.").
        if let cellIndex = lastIndex(ofAny: ["td", "th"], in: names, above: keepIndex),
           !onlyImpliedEndTags(above: cellIndex, in: names) {
            errors.append("A table cell was implicitly closed, but there were open elements.")
        } else if let captionIndex = lastIndex(ofAny: ["caption"], in: names, above: keepIndex),
                  !onlyImpliedEndTags(above: captionIndex, in: names) {
            errors.append("Unclosed elements on stack.")
        }
        names.removeSubrange((keepIndex + 1)...)
    }

    // MARK: End tags

    /// Whether an end tag for `name`, matched by the open element at
    /// `matchIndex`, closes everything above that element without a parse
    /// error, following how upstream's TreeBuilder groups end tags:
    /// - block-level, list item, heading, form, cell, ... end tags first
    ///   "generate implied end tags", so </ul> after an unclosed <li> and
    ///   </div> after an unclosed <p> are fine;
    /// - table end tags also close open table parts (</table> closes an
    ///   open cell, row and row group);
    /// - </body> and </html> have their own allowed lists;
    /// - formatting end tags (</b>, </a>, ...) go through the adoption agency,
    ///   which complains unless the element is the current node;
    /// - any other end tag (</span>, </video>, </noscript>, custom elements)
    ///   is blocked by a special element such as an open <p> or <li>, and only
    ///   closes non-special optional elements (option, rt, ...) quietly.
    static func endTagClosesQuietly(_ name: String, matchIndex: Int, openElements names: [String]) -> Bool {
        let quiet: Set<String>
        switch name {
        case "table":
            quiet = impliedEndTagElements.union(tableStructureElements)
        case "tbody", "thead", "tfoot":
            quiet = impliedEndTagElements.union(["tr", "td", "th"])
        case "tr":
            quiet = impliedEndTagElements.union(["td", "th"])
        case "template":
            // "Generate all implied end tags thoroughly".
            quiet = impliedEndTagElements.union(tableStructureElements)
        case "body":
            quiet = bodyEndQuietElements
        case "html":
            quiet = htmlEndQuietElements
        default:
            if impliedEndTagClosingEndTags.contains(name) {
                quiet = impliedEndTagElements
            } else if formattingElements.contains(name) {
                quiet = []
            } else {
                quiet = nonSpecialImpliedEndTagElements
            }
        }
        return names[(matchIndex + 1)...].allSatisfy { quiet.contains($0) }
    }

    // MARK: Helpers

    /// Whether every element above `index` would be popped by "generate
    /// implied end tags" (i.e. they all have optional end tags).
    private static func onlyImpliedEndTags(above index: Int, in names: [String]) -> Bool {
        names[(index + 1)...].allSatisfy { impliedEndTagElements.contains($0) }
    }

    /// "Generate implied end tags" (optionally "except for" one element type).
    private static func generateImpliedEndTags(names: inout [String], except excluded: String?) {
        while let current = names.last, impliedEndTagElements.contains(current), current != excluded {
            names.removeLast()
        }
    }

    /// The topmost open element named `name`, if it's "in scope": no scope
    /// boundary element sits between it and the top of the stack.
    private static func lastIndex(of name: String, in names: [String], scopeBoundaries: Set<String>) -> Int? {
        var index = names.count - 1
        while index >= 0 {
            if name == names[index] {
                return index
            }
            if scopeBoundaries.contains(names[index]) {
                return nil
            }
            index -= 1
        }
        return nil
    }

    /// The topmost open element named one of `candidates`, searching only the
    /// entries above `floor`.
    private static func lastIndex(ofAny candidates: Set<String>, in names: [String], above floor: Int) -> Int? {
        var index = names.count - 1
        while index > floor {
            if candidates.contains(names[index]) {
                return index
            }
            index -= 1
        }
        return nil
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
