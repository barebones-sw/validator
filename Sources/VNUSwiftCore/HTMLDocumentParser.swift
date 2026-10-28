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
    /// Review item A2: the element's namespace, from the tokenizer (see
    /// HTMLNamespace), so that every checker sees the same answer.
    var namespace: HTMLNamespace
    var range: HTMLSourceRange

    func attributeValue(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    func hasAttribute(_ name: String) -> Bool {
        attributes.contains { $0.name == name }
    }

    /// Review item A2 (U18): the name as messages spell it (SVG's camelCase
    /// names such as foreignObject and linearGradient; the tokenizer
    /// lowercases every tag name).
    var displayName: String {
        HTMLForeignContent.displayName(name, namespace: namespace)
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
        // Review item A2: the tokenizer runs the tree builder as it goes (see
        // HTMLTreeEventBuilder), so one pass produces both.
        let (tokens, events) = HTMLTokenizer(source: source, locations: locations).tokenizeAndBuildTree()
        return HTMLParsedDocument(tokens: tokens, events: events)
    }
}

/// Turns the tokens into the start, end, text and comment events the checkers
/// read, keeping a stack of open elements as upstream's tree builder does
/// (implied end tags, foreign content), but reporting nothing: HTMLValidator
/// reports the parse errors.
///
/// Review item A2: the tokenizer runs this as it produces the tokens, feeding
/// it each one in order (see HTMLTokenizer.tokenizeAndBuildTree), rather than
/// running it afterward, because some of the tokenizer's own decisions depend
/// on the current node: the namespace of each start tag's element, and whether
/// "<![CDATA[" starts a CDATA section. In upstream's parser the tree builder
/// drives the tokenizer the same way. The tokenizer used to keep a smaller
/// model of the stack for those decisions, which drifted from this one: it
/// didn't apply HTML's implied end tags, so a <p> closed by the next <p> in a
/// <foreignObject> left the foreignObject open for good, and a stray end tag
/// inside an <svg> (a </span> with no span open) ended the SVG. Either way,
/// every SVG element after that point was checked as HTML.
struct HTMLTreeEventBuilder {
    private struct OpenElement {
        var name: String
        var range: HTMLSourceRange
        var namespace: HTMLNamespace
        /// HTML elements, and the foreign elements whose children are HTML
        /// (see HTMLForeignContent.childrenAreHTML).
        var childrenAreHTML: Bool
        /// Review item A2: a template's insertion mode (see
        /// HTMLImplicitClosures.TemplateContentMode); unused otherwise.
        var templateMode: HTMLImplicitClosures.TemplateContentMode
        /// Review item A2: the element is inside a <template> (see
        /// isInTemplateContents).
        var isInTemplateContents: Bool
    }

    private var events: [HTMLDocumentEvent] = [.startDocument]
    private var stack: [OpenElement] = []
    // Quirks mode changes one implicit closure (<table> doesn't close an
    // open <p>); see HTMLImplicitClosures.isQuirksMode.
    private var sawDoctype = false
    private var sawStartTag = false
    private var quirksMode = false
    // Review item A2: see HTMLImplicitClosures.DocumentSections.
    private var sections = HTMLImplicitClosures.DocumentSections()

    init() {}

    /// Review item A2: the namespace of the element a start tag starts, from
    /// the current node, as upstream's tree builder decides it (the "tree
    /// construction dispatcher" and its foreign-content rules). Inside a
    /// foreign element other than an integration point, a child is in its
    /// parent's namespace (an <svg> in MathML's annotation-xml starts SVG),
    /// unless the tag is one of the HTML start tags that end foreign content.
    /// Directly inside a MathML text integration point (mi, mo, mn, ms,
    /// mtext), <mglyph> and <malignmark> are still MathML. Anywhere else the
    /// tag is HTML's, where <svg> and <math> start foreign content.
    func namespace(forStartTag name: String, attributes: [HTMLAttribute]) -> HTMLNamespace {
        if let current = stack.last, .html != current.namespace {
            if !current.childrenAreHTML {
                if HTMLForeignContent.breaksOut(name, attributes: attributes) {
                    return .html
                }
                return HTMLForeignContent.namespace(ofChild: name, inForeignElement: current.name, namespace: current.namespace)
            }
            if HTMLForeignContent.staysMathML(name, inside: current.name, namespace: current.namespace) {
                return .mathML
            }
        }
        return HTMLForeignContent.rootNamespace(of: name) ?? .html
    }

    /// Review item A2: whether "<![CDATA[" starts a CDATA section rather than
    /// a bogus comment: whenever the current node isn't an HTML element, as in
    /// upstream (and the spec). That includes an integration point itself, so
    /// CDATA directly in a <foreignObject> or <mi> is a CDATA section, but not
    /// in an HTML element inside one.
    var isCDATAAllowed: Bool {
        stack.last.map { .html != $0.namespace } ?? false
    }

    mutating func consume(_ token: HTMLToken) {
        switch token {
        case let .doctype(offset, length):
            events.append(.doctype(range: HTMLSourceRange(offset: offset, length: length)))
            if !sawStartTag {
                sawDoctype = true
            }
        case let .startTag(writtenName, attributes, selfClosing, namespace, offset, length):
            if !sawStartTag {
                sawStartTag = true
                quirksMode = HTMLImplicitClosures.isQuirksMode(sawDoctype: sawDoctype)
            }
            // Review item A2: an HTML <image> start tag is handled as <img>,
            // as upstream's tree builder does (HTMLValidator reports it), so
            // the checkers apply all of img's rules to it: alt, srcset, void,
            // picture's img child. An SVG <image> is an ordinary SVG element.
            let name = (.html == namespace && "image" == writtenName) ? "img" : writtenName
            // Review item A2: a start tag upstream's tree builder ignores (see
            // HTMLImplicitClosures.ignoredStartTag; HTMLValidator reports it)
            // isn't an element the checkers see. One that implies the body (a
            // stray <frame> or table part) still closes the head first, as
            // upstream's "anything else" rule in the head does.
            if nil != HTMLImplicitClosures.ignoredStartTag(name, namespace: namespace, sections: sections, inTemplateContents: isInTemplateContents, formIsOpen: stack.contains(where: { .html == $0.namespace && "form" == $0.name }), tableContext: tableContext) {
                if sections.isInHead, !isInTemplateContents, HTMLImplicitClosures.startTagImpliesBody(name, namespace: namespace) {
                    closeHead()
                    sections.noteBodyStarted()
                }
                sections.noteStartTag(name, namespace: namespace, ignored: true, inTemplateContents: isInTemplateContents)
                return
            }
            // Review item A2: an HTML start tag in foreign content (one of
            // HTMLForeignContent's "breakout" tags, such as <p> inside
            // <svg>) ends the foreign content first, as upstream's tree
            // builder does.
            if .html == namespace {
                while let top = stack.last, !top.childrenAreHTML {
                    closeTop()
                }
            }
            // Review item A2: a reopened <a> or <nobr> closes the old one
            // first (see HTMLImplicitClosures.reopenedFormattingElement); in
            // the "furthest block" case, or when the old one is out of scope,
            // upstream takes it out from under the elements above it, which
            // these events can't follow, so it stays open here.
            if .html == namespace, "a" == name || "nobr" == name,
               let reopened = HTMLImplicitClosures.reopenedFormattingElement(named: name, count: stack.count, element: { (stack[$0].name, stack[$0].namespace, stack[$0].childrenAreHTML) }),
               !reopened.hasFurthestBlock, reopened.inScope {
                while stack.count > reopened.index {
                    closeTop()
                }
            }
            // HTML's implied end tags apply only to tags processed as HTML
            // (an HTML element, or the <svg> or <math> that starts foreign
            // content), never to a foreign element's children.
            if !HTMLForeignContent.isHandledAsForeign(name, namespace: namespace, parentChildrenAreHTML: stack.last?.childrenAreHTML ?? true) {
                closeImplicitElements(beforeStarting: name)
                // Review item A2: a template's first content start tag sets
                // its insertion mode (see TemplateContentMode).
                noteTemplateContent(name, namespace: namespace)
            }
            sections.noteStartTag(name, namespace: namespace, ignored: false, inTemplateContents: isInTemplateContents)
            let range = HTMLSourceRange(offset: offset, length: length)
            let element = HTMLStartElement(name: name, attributes: attributes, selfClosing: selfClosing, namespace: namespace, range: range)
            events.append(.startElement(element))

            // A self-closed foreign element ("<path/>") is complete, like an
            // HTML void element; the slash means nothing on an HTML element.
            // This builder used to keep every self-closed element open, so
            // an SVG icon's later siblings were nested inside its <path/>.
            if (.html == namespace) ? HTMLVocabulary.voidElements.contains(name) : selfClosing {
                events.append(.endElement(name: name, range: range, implicit: true))
            } else {
                stack.append(OpenElement(name: name, range: range, namespace: namespace, childrenAreHTML: HTMLForeignContent.childrenAreHTML(name, namespace: namespace, attributes: attributes), templateMode: .inTemplate, isInTemplateContents: isInTemplateContents))
            }
        case let .endTag(name, offset, length):
            closeElements(forEndTag: name, range: HTMLSourceRange(offset: offset, length: length))
        case let .text(content, offset, length):
            guard !content.isEmpty else { return }
            // Review item A2: non-space text in the head (directly in it, not
            // in its <title> or <style>) ends the head and starts the body, as
            // upstream's "anything else" rule does; the text is then body
            // content. (Leaving the head open made a later </body> find it
            // unclosed.)
            if sections.textStartsBody, HTMLImplicitClosures.containsNonSpace(content), stack.last.map({ .html == $0.namespace && ("html" == $0.name || "head" == $0.name) }) ?? true {
                closeHead()
                sections.noteBodyStarted()
            }
            events.append(.characters(content, range: HTMLSourceRange(offset: offset, length: length)))
        case let .comment(content, offset, length):
            events.append(.comment(content, range: HTMLSourceRange(offset: offset, length: length)))
        case .bogusMarkup, .parseError:
            return
        }
    }

    /// Review item A2: whether the current node is inside a <template>.
    /// (Review item A2: from the current node's flag, not a walk down the
    /// stack for every start tag; the flag is set as each element is pushed,
    /// and an element's ancestors don't change while it's open.)
    private var isInTemplateContents: Bool {
        stack.last.map { $0.isInTemplateContents || (.html == $0.namespace && "template" == $0.name) } ?? false
    }

    /// Review item A2: the innermost open HTML table or template (see
    /// HTMLImplicitClosures.TableContext).
    private var tableContext: HTMLImplicitClosures.TableContext {
        guard let element = stack.last(where: { .html == $0.namespace && ("table" == $0.name || "template" == $0.name) }) else {
            return .none
        }
        return ("table" == element.name) ? .table : .template(element.templateMode)
    }

    /// Review item A2: a start tag processed while the innermost template is
    /// still in "in template" mode (only head content in it so far) sets that
    /// template's mode, as upstream's tree builder does.
    private mutating func noteTemplateContent(_ name: String, namespace: HTMLNamespace) {
        guard let index = HTMLImplicitClosures.templateInTemplateMode(count: stack.count, element: { (stack[$0].name, stack[$0].namespace, stack[$0].templateMode) }),
              let mode = HTMLImplicitClosures.templateContentMode(afterStartTag: name, namespace: namespace) else {
            return
        }
        stack[index].templateMode = mode
    }

    /// Review item A2: closes the <head>, and anything still open in it.
    private mutating func closeHead() {
        guard let index = stack.lastIndex(where: { .html == $0.namespace && "head" == $0.name }) else { return }
        while stack.count > index {
            closeTop()
        }
    }

    /// The events, once every token has been consumed: the elements still
    /// open are closed (implicitly) at the end of the document.
    mutating func finish() -> [HTMLDocumentEvent] {
        while !stack.isEmpty {
            closeTop()
        }
        events.append(.endDocument)
        return events
    }

    private mutating func closeImplicitElements(beforeStarting name: String) {
        // Case 554591: this used to close the nearest open "li" (or "dd"/"dt")
        // anywhere on the stack, which reached through a nested <ul>/<ol>/<dl>
        // and closed the *outer* list item, so every nested list produced a
        // corrupt event tree for the downstream checkers. It also only closed a
        // "p" that was the current node. Use the same spec-derived rules as
        // HTMLValidator so both views of the tree agree. (Parse errors are
        // reported by HTMLValidator; this builder only needs the tree shape.)
        //
        // Review item A2: the rules only see the HTML elements above the
        // innermost foreign element (an integration point such as
        // <foreignObject>, whose children are HTML), because upstream's scope
        // checks stop there; HTML inside an SVG can't close a <p> outside it.
        let boundary = HTMLImplicitClosures.tableScopedStartTags.contains(name) ? 0 : (stack.lastIndex { .html != $0.namespace }).map { $0 + 1 } ?? 0
        let closure = HTMLImplicitClosures.beforeStartTag(name, openElements: stack[boundary...].map { .html == $0.namespace ? $0.name : "" }, quirksMode: quirksMode)
        while stack.count > boundary + closure.keepCount {
            closeTop()
        }
    }

    private mutating func closeTop() {
        guard let element = stack.popLast() else { return }
        events.append(.endElement(name: element.name, range: element.range, implicit: true))
    }

    private mutating func closeElements(forEndTag name: String, range: HTMLSourceRange) {
        // Review item A2: the same model as HTMLValidator's. With a foreign
        // current node, the end tag closes the nearest matching foreign element
        // if there's one before the first HTML element...
        if let current = stack.last, .html != current.namespace,
           let foreignMatch = stack.lastIndex(where: { .html == $0.namespace || name == $0.name }), .html != stack[foreignMatch].namespace {
            while stack.count - 1 > foreignMatch {
                closeTop()
            }
            _ = stack.popLast()
            events.append(.endElement(name: name, range: range, implicit: false))
            return
        }
        // Review item A2: upstream's </body> and </html> close nothing in the
        // body: they switch its tree builder to the "after body" modes, and
        // every element stays open until the end of the file. So content
        // after </body>, which upstream reports and then handles as body
        // content, is still in the body here, and an <svg> that a stray
        // </body> appears in is still open after it. (This used to close
        // everything up to the <body> or <html>.) In the head, though, they
        // first close the head and imply the body, as upstream's "anything
        // else" rule there does; HTMLValidator does the same.
        if "body" == name || "html" == name {
            if sections.textStartsBody {
                closeHead()
                sections.noteBodyStarted()
            }
            return
        }
        // Review item A2: </head> closes the head, implied or not (and an
        // implied one has no element to close); later, it's stray.
        if "head" == name, sections.isInHead {
            sections.noteHeadEnded()
            closeHead()
            return
        }
        // Review item A2: the outermost </frameset> starts upstream's "after
        // frameset" mode, where every start tag but <noframes> is ignored.
        if "frameset" == name, let index = stack.lastIndex(where: { .html == $0.namespace && "frameset" == $0.name }), !stack[..<index].contains(where: { .html == $0.namespace && "frameset" == $0.name }) {
            sections.noteFramesetEnded()
        }
        // ... and otherwise it's an HTML end tag, which closes an HTML element
        // above the innermost integration point (foreignObject, mi, ...). For
        // </p> without a <p> to close, and for </br>, upstream inserts an
        // empty element that first ends foreign content.
        // (Except HTMLImplicitClosures.endTagsUnscopedByIntegrationPoints.)
        let scopeStart = HTMLImplicitClosures.endTagsUnscopedByIntegrationPoints.contains(name) ? 0 : (stack.lastIndex { .html != $0.namespace && $0.childrenAreHTML }).map { $0 + 1 } ?? 0
        let htmlMatch = stack[scopeStart...].lastIndex(where: { .html == $0.namespace && $0.name == name })
        if "br" == name || ("p" == name && nil == htmlMatch) {
            while let top = stack.last, .html != top.namespace {
                closeTop()
            }
            // Case 554591 (item 4): and, in a figure, the element itself, as
            // an empty one, so that the checkers see what upstream's do: a
            // figure's child elements are counted for its table caption
            // rule, and the <p> in
            // <figure><figcaption>…</figcaption><table>…</table></p> is a
            // third, which this builder used to leave out. (Only in a figure,
            // as HTMLValidator checks it, for now: elsewhere the checkers
            // would judge it against a parent the port's tree may have got
            // wrong, or inside an element upstream's schema rejected, which
            // they don't know about. In the body only: upstream ignores a
            // stray </p> before the body. Not in a template, where nothing is
            // checked, nor in a table, which would foster-parent it, and
            // where vnu.jar stops checking.)
            // (The figure test comes first: the table test walks the stack,
            // which for every </br> in a deep document was measurably slow.)
            if let current = stack.last, .html == current.namespace, "figure" == current.name,
               sections.bodyStarted, !isInTemplateContents,
               nil == HTMLImplicitClosures.tableInsertionModeIndex(in: stack[((stack.lastIndex { .html != $0.namespace }).map { $0 + 1 } ?? 0)...].map(\.name)) {
                events.append(.startElement(HTMLStartElement(name: name, attributes: [], selfClosing: false, namespace: .html, range: range)))
                events.append(.endElement(name: name, range: range, implicit: true))
            }
            return
        }
        guard !HTMLVocabulary.voidElements.contains(name), let match = htmlMatch else {
            return
        }

        while stack.count - 1 > match {
            closeTop()
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

    /// Review item A2: the elements that may still be open, without "End tag
    /// for  “body” seen, but there were unclosed elements.", when </body>
    /// arrives (upstream's uncloseloop1, which looks above the body), and
    /// </html>'s list (uncloseloop2, which looks at every element). They
    /// aren't quite the same lists, and neither has tr. (These replace older
    /// lists here, which had tr and head and were used by endTagClosesQuietly;
    /// HTMLValidator now handles </body> and </html> itself.)
    static let elementsQuietAtBodyEnd: Set<String> = [
        "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot", "th", "thead"
    ]
    static let elementsQuietAtHTMLEnd: Set<String> = [
        "body", "dd", "dt", "html", "li", "p", "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot", "th", "thead"
    ]

    // MARK: Document sections

    /// Review item A2: the start tags that don't imply the <body> in upstream's
    /// "before head", "in head" and "after head" insertion modes: the head's
    /// content (with noscript, which is head content when scripting is off),
    /// and the html, head, body and frameset tags those modes handle
    /// themselves. Any other start tag, a foreign <svg> or <math> included,
    /// implies the body, as non-space text in the head does.
    static let headSectionStartTags: Set<String> = [
        "base", "basefont", "bgsound", "body", "frameset", "head", "html", "link", "meta", "noframes", "noscript",
        "script", "style", "template", "title"
    ]

    /// Review item A2: whether a start tag (in the given namespace) implies the
    /// <body>; see headSectionStartTags.
    static func startTagImpliesBody(_ name: String, namespace: HTMLNamespace) -> Bool {
        .html != namespace || !headSectionStartTags.contains(name)
    }

    /// Review item A2: the table-part start tags, which upstream's "in body"
    /// mode ignores, as stray, outside a table.
    static let tablePartStartTags: Set<String> = [
        "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"
    ]

    /// Review item A2: a template's current insertion mode (upstream's "stack
    /// of template insertion modes"), which its first content start tag
    /// decides. It matters to what upstream does with a stray start tag or
    /// with </body> and </html> inside the template.
    enum TemplateContentMode: Equatable, Sendable {
        /// "In template": no content start tag yet, or only head content.
        case inTemplate
        /// One of the table modes (a table part started the content).
        case inTable
        /// "In column group" (a <col> started it).
        case inColumnGroup
        /// "In body" (anything else did).
        case inBody
    }

    /// Review item A2: where upstream's tree builder is in the document's
    /// sections, as far as the port needs to know: whether a start tag has
    /// started the head (implicitly, too), whether the head has ended, and
    /// whether the body has started (implicitly, too: any start tag outside
    /// headSectionStartTags, or non-space text in the head), and whether the
    /// outermost frameset has ended. HTMLTreeEventBuilder and HTMLValidator
    /// keep one each, updated the same way, so they agree on the start tags
    /// upstream ignores (see ignoredStartTag).
    struct DocumentSections: Equatable, Sendable {
        private(set) var sawStartTag: Bool
        private(set) var headStarted: Bool
        private(set) var headEnded: Bool
        private(set) var bodyStarted: Bool
        /// A frameset document: everything after its <frameset> is the
        /// frameset's (or after it), and nothing implies a body.
        private(set) var framesetStarted: Bool
        private(set) var framesetEnded: Bool

        init() {
            sawStartTag = false
            headStarted = false
            headEnded = false
            bodyStarted = false
            framesetStarted = false
            framesetEnded = false
        }

        /// Upstream's "in head" mode: the head (explicit or implied) is open.
        var isInHead: Bool {
            headStarted && !headEnded && !bodyStarted && !framesetStarted
        }

        /// Whether non-space text would start the body (in the head, or before
        /// it), as opposed to being body content already, or a frameset's.
        var textStartsBody: Bool {
            !bodyStarted && !framesetStarted
        }

        /// After a start tag, ignored or not: the html tag starts nothing; any
        /// other starts the head (a <head> explicitly, the rest implicitly);
        /// <body>, and any tag that implies it, starts the body. A template's
        /// contents are parsed apart and move neither: a <dl> in a <template>
        /// in the head doesn't imply the body.
        mutating func noteStartTag(_ name: String, namespace: HTMLNamespace, ignored: Bool, inTemplateContents: Bool) {
            sawStartTag = true
            if ignored || inTemplateContents {
                return
            }
            if !(.html == namespace && "html" == name) {
                headStarted = true
            }
            if .html == namespace, "frameset" == name {
                framesetStarted = true
                noteHeadEnded()
            }
            if !framesetStarted, (.html == namespace && "body" == name) || startTagImpliesBody(name, namespace: namespace) {
                noteBodyStarted()
            }
        }

        /// </head>, or the head closing because the body started.
        mutating func noteHeadEnded() {
            headStarted = true
            headEnded = true
        }

        mutating func noteBodyStarted() {
            noteHeadEnded()
            bodyStarted = true
        }

        mutating func noteFramesetEnded() {
            framesetEnded = true
        }

        /// Whether a frameset is open: from the <frameset> start tag to the
        /// outermost </frameset> (upstream's "in frameset" mode, as far as
        /// start tags go). (Review item A2: this used to be a walk down the
        /// stack of open elements for every start tag, in the tree builder
        /// and again in HTMLValidator.)
        var framesetIsOpen: Bool {
            framesetStarted && !framesetEnded
        }
    }

    /// Review item A2: the innermost table or template context a start tag is
    /// in (the innermost open HTML table or template element), which decides
    /// whether upstream takes a table-part start tag or ignores it.
    enum TableContext: Equatable, Sendable {
        case none
        case table
        case template(TemplateContentMode)
    }

    /// Review item A2: how upstream's tree builder answers a start tag it
    /// ignores, after reporting it (and why the port's stacks must leave the
    /// element out). The port used to insert all of these, so a second
    /// <body>, a stray <td> or a stray <frameset> in the body became an open
    /// element that later end tags, and the checkers, then saw.
    enum IgnoredStartTag: Equatable, Sendable {
        /// "Stray start tag “x”."
        case stray
        /// "Start tag “x” seen but an element of the same type was already
        /// open."
        case alreadyOpen
        /// "Saw a “form” start tag, but there was already an active “form”
        /// element. Nested forms are not allowed. Ignoring the tag."
        case nestedForm
    }

    /// Review item A2: whether upstream's tree builder ignores this start tag:
    /// in a frameset, anything but frameset, frame and noframes;
    /// <html> after any start tag (its attributes are merged into the first);
    /// <head> once the head has started (already open while in the head;
    /// stray after it); <body> once the body has started (already open; stray
    /// in a template); <frameset> once the body has started; <frame> outside a
    /// frameset; a <form> in a form (outside a template); a table part outside
    /// a table (or a template in its body mode); and, after the outermost
    /// </frameset>, anything but <noframes>.
    /// (`formIsOpen` and `tableContext` are worked out only for the tags that
    /// need them: each is a walk down the stack of open elements, and doing
    /// both for every start tag made deeply nested documents slower still.)
    static func ignoredStartTag(
        _ name: String,
        namespace: HTMLNamespace,
        sections: DocumentSections,
        inTemplateContents: Bool,
        formIsOpen: @autoclosure () -> Bool,
        tableContext: @autoclosure () -> TableContext
    ) -> IgnoredStartTag? {
        guard .html == namespace else { return nil }
        if sections.framesetEnded, "noframes" != name {
            return .stray
        }
        // In a frameset ("in frameset" mode), only frameset, frame and
        // noframes start tags are taken; anything else is stray.
        if sections.framesetIsOpen, !("frame" == name || "frameset" == name || "noframes" == name) {
            return .stray
        }
        switch name {
        case "html":
            return sections.sawStartTag ? .stray : nil
        case "head":
            if inTemplateContents || sections.headEnded || sections.bodyStarted {
                return .stray
            }
            return sections.headStarted ? .alreadyOpen : nil
        case "body":
            if inTemplateContents {
                return .stray
            }
            return sections.bodyStarted ? .alreadyOpen : nil
        case "frameset":
            return (inTemplateContents || sections.bodyStarted) ? .stray : nil
        case "frame":
            return sections.framesetIsOpen ? nil : .stray
        case "form":
            // (Upstream's form element pointer, roughly: a <form> is open.
            // Inside a template, a nested form is allowed.)
            return (!inTemplateContents && formIsOpen()) ? .nestedForm : nil
        default:
            guard tablePartStartTags.contains(name) else { return nil }
            switch tableContext() {
            case .none, .template(.inBody):
                return .stray
            case .table, .template:
                return nil
            }
        }
    }

    /// Review item A2: an <a> start tag while an <a> is still "active" (open
    /// since the last cell, caption, template, applet, object or marquee), or
    /// a <nobr> while a <nobr> is in scope: upstream reports "Start tag “a”
    /// seen but an element of the same type was already open." and runs its
    /// adoption agency, which closes the old one: with no special element
    /// opened inside it, everything up to and including it; otherwise (the
    /// "furthest block" case, where upstream also reports "End tag “a”
    /// violates nesting rules." and then, in vnu.jar, stops checking) just
    /// the old element, the block staying open. An old <a> that's out of
    /// scope (below an SVG <foreignObject>, say) is "No “a” element in scope
    /// but a “a” end tag seen." instead, and upstream then drops just that
    /// element too (vnu.jar stops checking there as well). The port used to
    /// keep the old one open, so a later </body> found it unclosed.
    /// `element(index)` gives the open element at an index of a stack of
    /// `count`. Returns the old element's index, whether there's a special
    /// element above it, and whether it's in scope.
    static func reopenedFormattingElement(
        named name: String,
        count: Int,
        element: (Int) -> (name: String, namespace: HTMLNamespace, childrenAreHTML: Bool)
    ) -> (index: Int, hasFurthestBlock: Bool, inScope: Bool)? {
        // (The default scope's boundaries, upstream's SCOPING elements: the
        // HTML ones in defaultScopeBoundaries, and the foreign integration
        // points and annotation-xml.)
        let isScopeBoundary: ((name: String, namespace: HTMLNamespace, childrenAreHTML: Bool)) -> Bool = { node in
            (.html == node.namespace && defaultScopeBoundaries.contains(node.name)) || (.html != node.namespace && (node.childrenAreHTML || "annotation-xml" == node.name))
        }
        var index = count - 1
        var found: Int?
        var inScope = true
        while index >= 0 {
            let node = element(index)
            if .html == node.namespace, name == node.name {
                found = index
                break
            }
            if "a" == name {
                if .html == node.namespace, activeFormattingMarkers.contains(node.name) {
                    return nil
                }
                if isScopeBoundary(node) {
                    inScope = false
                }
            } else if isScopeBoundary(node) {
                return nil
            }
            index -= 1
        }
        guard let found else { return nil }
        let hasFurthestBlock = ((found + 1)..<count).contains { position in
            let node = element(position)
            return (.html == node.namespace && specialElements.contains(node.name)) || (.html != node.namespace && (node.childrenAreHTML || "annotation-xml" == node.name))
        }
        return (found, hasFurthestBlock, inScope)
    }

    /// Review item A2: the elements that put a marker on upstream's list of
    /// active formatting elements, which an <a>'s search stops at (see
    /// reopenedFormattingElement).
    private static let activeFormattingMarkers: Set<String> = ["applet", "caption", "marquee", "object", "td", "template", "th"]

    /// Review item A2: whether text has a character other than HTML's space
    /// characters (space, tab, LF, FF, CR), which upstream's tree builder
    /// treats differently in the head and after the body.
    static func containsNonSpace(_ text: String) -> Bool {
        text.utf8.contains { 0x20 != $0 && 0x09 != $0 && 0x0A != $0 && 0x0C != $0 && 0x0D != $0 }
    }

    /// Review item A2: the mode a start tag switches a template in "in
    /// template" mode to, or nil if it leaves it there (head content).
    /// Review item A2: the template whose insertion mode a start tag can set
    /// (see templateContentMode): the innermost template, when it's still in
    /// "in template" mode with nothing but head content open inside it. It's
    /// found from the top of the stack down, stopping at the first element
    /// that isn't head content, so it's quick even in a deep document; it
    /// used to be a walk down the whole stack for every start tag.
    /// `element(index)` gives the open element at an index of a stack of
    /// `count`.
    static func templateInTemplateMode(
        count: Int,
        element: (Int) -> (name: String, namespace: HTMLNamespace, templateMode: TemplateContentMode)
    ) -> Int? {
        var index = count - 1
        while index >= 0 {
            let node = element(index)
            guard .html == node.namespace else {
                return nil
            }
            if "template" == node.name {
                return (.inTemplate == node.templateMode) ? index : nil
            }
            guard headSectionStartTags.contains(node.name) else {
                return nil
            }
            index -= 1
        }
        return nil
    }

    static func templateContentMode(afterStartTag name: String, namespace: HTMLNamespace) -> TemplateContentMode? {
        guard .html == namespace else { return .inBody }
        switch name {
        case "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title":
            return nil
        case "caption", "colgroup", "tbody", "tfoot", "thead", "tr", "td", "th":
            return .inTable
        case "col":
            return .inColumnGroup
        default:
            return .inBody
        }
    }

    // MARK: Foreign content

    // Review item A2: these rules model the HTML namespace only, so callers
    // pass them the HTML part of the stack of open elements, the elements
    // above its innermost foreign (SVG or MathML) element, and add that
    // boundary back to keepCount; upstream's scope checks stop at the
    // integration point there. (The table-scoped tags below are the
    // exception.)

    /// Review item A2: start tags whose implied end tags are found in table
    /// scope, which stops only at an HTML table, template or html element,
    /// never at an SVG or MathML integration point (TreeBuilder's
    /// findLastInTableScope): a <td> inside a cell's <math><mi> closes the
    /// cell. Callers give the rules the whole stack for these, with foreign
    /// elements' names blanked out, rather than the HTML part above the
    /// innermost foreign element.
    static let tableScopedStartTags: Set<String> = [
        "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"
    ]

    /// Review item A2: end tags that likewise aren't stopped by an
    /// integration point: the table-scoped ones, and </template> (upstream's
    /// findLast, with no scope). (</body> and </html> close nothing; see
    /// HTMLValidator and HTMLTreeEventBuilder.)
    static let endTagsUnscopedByIntegrationPoints: Set<String> = [
        "caption", "table", "tbody", "td", "template", "tfoot", "th", "thead", "tr"
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
    /// - (</body> and </html> close nothing; HTMLValidator checks them with
    ///   elementsQuietAtBodyEnd and elementsQuietAtHTMLEnd;)
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
                // Review item A2 (U16): HTML's required attributes; an SVG <a>
                // or <script> shares the name but not the rules.
                if .html == element.namespace {
                    appendRequiredAttributeMessages(for: element, parent: stack.last, locations: locations, messages: &messages)
                }
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
