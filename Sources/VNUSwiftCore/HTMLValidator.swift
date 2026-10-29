import Foundation
import VNUCore

public final class HTMLValidator: Sendable {
    public init() {}

    private struct OpenElement {
        /// Review item A2: per-element facts, packed into one byte: the stack
        /// is scanned whole for every start tag, so a larger record made
        /// deeply nested documents measurably slower.
        struct Flags: OptionSet {
            let rawValue: UInt8

            /// HTML elements, and the foreign elements whose children are HTML
            /// (see HTMLForeignContent.childrenAreHTML).
            static let childrenAreHTML = Flags(rawValue: 1 << 0)
            /// The element is one upstream's schema rejects (an unknown SVG or
            /// MathML element, a MathML element in a parent that doesn't take
            /// it, a <math> where MathML can't go), or inside one, at any depth
            /// and in any namespace: upstream's schema validator reports
            /// nothing more in that subtree (Jing's suppressDepth; vnu.jar's
            /// "Suppressing further errors from this subtree"), though its
            /// other checks (unknown elements, duplicate IDs) still apply.
            static let inRejectedSubtree = Flags(rawValue: 1 << 1)
            /// The element is in content upstream's schema accepts unchecked:
            /// anything inside an SVG <desc>, at any depth (svg11's
            /// any_element), and a non-MathML element inside a MathML
            /// <annotation-xml>, with everything inside it (MathML 3's
            /// anyElement; a MathML child of annotation-xml is checked as
            /// usual). Upstream's other checks still apply there.
            static let inAnyElementContent = Flags(rawValue: 1 << 2)
            /// The element is in annotation-xml's anyElement content, which
            /// excludes MathML at every depth: a <math> there is rejected.
            /// (Not inside an SVG <desc>, whose any_element accepts everything
            /// below it, an annotation-xml's content included.)
            static let inAnnotationXMLContent = Flags(rawValue: 1 << 3)
            /// The element is inside a <template>, where upstream checks
            /// nothing but the parser's own errors.
            static let inTemplateContents = Flags(rawValue: 1 << 4)
            /// "Unclosed element" has been reported for the element (upstream
            /// reports each element at most once).
            static let reportedUnclosed = Flags(rawValue: 1 << 5)
            /// The element started after the body did (for a <template>:
            /// whether </body> in it can be a body end tag).
            static let startedInBody = Flags(rawValue: 1 << 6)
            /// Case 554591 (item 4): the element is, or is inside, an HTML
            /// element whose content upstream's schema doesn't check: one it
            /// rejects ("Suppressing further errors from this subtree"),
            /// either because it doesn't know it or, as the older content-model
            /// rules here find (see contentModelMessage), because it's
            /// misplaced; or one of the obsolete elements its legacy schema
            /// takes with anything at all in them (see legacyAnythingElements);
            /// or (item 12) a colgroup after the table's rows, which it rejects
            /// though the port doesn't report it yet (see TableColumnSection).
            /// Only the figure rules and item 12's colgroup rule look at this
            /// so far (see schemaChecksChildren); the older rules predate it,
            /// and still check inside such elements.
            static let inUncheckedElement = Flags(rawValue: 1 << 7)
        }

        var name: String
        var offset: Int
        /// Review item A2: the start tag's length, for "Unclosed element"
        /// messages, which upstream reports at the start tag.
        var length: Int
        /// Review item A2: see HTMLNamespace and HTMLForeignContent.
        var namespace: HTMLNamespace
        /// Review item A2: a template's insertion mode (see
        /// HTMLImplicitClosures.TemplateContentMode); unused otherwise.
        var templateMode: HTMLImplicitClosures.TemplateContentMode
        var flags: Flags

        var childrenAreHTML: Bool { flags.contains(.childrenAreHTML) }
        var isInRejectedSubtree: Bool { flags.contains(.inRejectedSubtree) }
        var isInAnyElementContent: Bool { flags.contains(.inAnyElementContent) }
        var isInAnnotationXMLContent: Bool { flags.contains(.inAnnotationXMLContent) }
        var isInTemplateContents: Bool { flags.contains(.inTemplateContents) }
        var startedInBody: Bool { flags.contains(.startedInBody) }
        var reportedUnclosed: Bool {
            get { flags.contains(.reportedUnclosed) }
            set {
                if newValue {
                    flags.insert(.reportedUnclosed)
                } else {
                    flags.remove(.reportedUnclosed)
                }
            }
        }
    }

    /// Review item A2: upstream's insertion modes after the body or frameset.
    /// </body> and </html> don't close anything (see the .endTag case): they
    /// switch to "after body" and "after after body", where the next start
    /// tag, end tag or non-space text is reported and then handled as body
    /// content again. The outermost </frameset> switches to "after frameset",
    /// and </html> then to "after after frameset", where every tag (but
    /// <noframes>) and non-space character is reported and ignored.
    private enum AfterBodyMode {
        case inBody
        case afterBody
        case afterAfterBody
        case afterFrameset
        case afterAfterFrameset
    }

    /// Case 554591 (item 4): an open <figure>'s content so far, for its
    /// content model in upstream's schema (html5/media.rnc): a figcaption
    /// and then flow content, or flow content and then a figcaption. So once
    /// other content has come before the caption, nothing may follow the
    /// caption; a caption that came first may be followed by anything; and
    /// there's never a second caption. (HTMLGeneralAttributeChecker used to
    /// report everything after any figcaption, so the usual caption-first
    /// figure, <figure><figcaption>…</figcaption><img …></figure>, was an
    /// error, as were the elements after a figcaption nested deeper in the
    /// figure, such as one in a <div>.) See figureContentModelMessage.
    private struct FigureContent {
        enum CaptionPosition {
            /// Before any other content: flow content may follow it.
            case first
            /// After other content: nothing may follow it.
            case last
        }

        /// Whether flow content (an element, or text that isn't whitespace)
        /// has come before any figcaption.
        var sawContent = false
        /// Where the figcaption is, once there is one.
        var caption: CaptionPosition?
    }

    /// Case 554591 (item 12, from its review): how far a table's children
    /// have got in upstream's content model for it (tables.rnc: a caption,
    /// then colgroups, then the rows, with script-supporting elements,
    /// script and template, in between), as far as its colgroups go. Once
    /// the rows have started, or a script or template has come after a
    /// colgroup, no colgroup may follow: the schema rejects one ("Element
    /// “colgroup” not allowed as child of “table”"), and checks nothing
    /// inside it. The port doesn't report that yet; but the colgroup rule
    /// mustn't report what's inside such a colgroup either (see
    /// colgroupContentModelMessage), which it did for the template in
    /// <tr>…</tr><colgroup span=2><template>. Kept by the table's start-tag
    /// offset, as FigureContent is.
    private struct TableColumnSection {
        /// A colgroup has come, or a col directly in the table, which
        /// upstream's parser puts in a colgroup it implies.
        var sawColumnGroup = false
        /// No more colgroups are allowed.
        var isClosed = false
    }

    /// Review item A2: the flags a child, in the given namespace, inherits
    /// from its parent (see OpenElement.Flags).
    private static func childFlags(of parent: OpenElement?, childNamespace: HTMLNamespace) -> OpenElement.Flags {
        var flags: OpenElement.Flags = []
        guard let parent else { return flags }
        if parent.isInRejectedSubtree {
            flags.insert(.inRejectedSubtree)
        }
        let isAnnotationXMLChild = .mathML == parent.namespace && "annotation-xml" == parent.name && .mathML != childNamespace
        if parent.isInAnyElementContent || (.svg == parent.namespace && "desc" == parent.name) || isAnnotationXMLChild {
            flags.insert(.inAnyElementContent)
        }
        // (An annotation-xml in an SVG <desc>'s unchecked content is itself
        // unchecked, so nothing in it is anyElement's: a <math> there is
        // fine, as vnu.jar has it.)
        let parentIsInDescContent = parent.isInAnyElementContent && !parent.isInAnnotationXMLContent
        if parent.isInAnnotationXMLContent || (isAnnotationXMLChild && !parentIsInDescContent) {
            flags.insert(.inAnnotationXMLContent)
        }
        if parent.isInTemplateContents || (.html == parent.namespace && "template" == parent.name) {
            flags.insert(.inTemplateContents)
        }
        // (Case 554591, item 4: an unchecked element marks itself, as it
        // starts; see validateStartTag.)
        if parent.flags.contains(.inUncheckedElement) {
            flags.insert(.inUncheckedElement)
        }
        return flags
    }

    /// Review item A2: the elements whose end tags may be left out
    /// (OPTIONAL_END_TAG in upstream's ElementName), which upstream never
    /// lists as "Unclosed element".
    private static let optionalEndTagElements: Set<String> = [
        "body", "colgroup", "dd", "dt", "head", "html", "li", "optgroup", "option", "p",
        "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot", "th", "thead", "tr"
    ]

    /// Review item A2: upstream's errListUnclosedStartTags, which follows each
    /// "… there were open elements" (or unclosed elements) error: every
    /// element above `index` whose end tag can't be left out, innermost
    /// first, as "Unclosed element", each at most once per document.
    private func appendUnclosedElements(above index: Int, stack: inout [OpenElement], locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        var position = stack.count - 1
        while position > index {
            let element = stack[position]
            if !element.reportedUnclosed, !(.html == element.namespace && Self.optionalEndTagElements.contains(element.name)) {
                stack[position].reportedUnclosed = true
                appendError("Unclosed element \u{201c}\(HTMLForeignContent.displayName(element.name, namespace: element.namespace))\u{201d}.", offset: element.offset, length: element.length, locations: locations, messages: &messages)
            }
            position -= 1
        }
    }

    /// Review item A2: the elements whose contents the tokenizer reads as
    /// text (raw text, RCDATA, script data), upstream's "text" mode.
    private static let textContentElements: Set<String> = [
        "iframe", "noembed", "noframes", "plaintext", "script", "style", "textarea", "title", "xmp"
    ]

    /// Review item A2: the elements that may still be open at the end of the
    /// file without "End of file seen and there were open elements." (in
    /// upstream's TreeBuilder.eof, for the body and table modes).
    private static let elementsQuietAtEndOfFile: Set<String> = [
        "body", "dd", "dt", "html", "li", "p", "tbody", "td", "tfoot", "th", "thead"
    ]

    /// Review item A2: the end of the file, as upstream's tree builder handles
    /// it (TreeBuilder.eof), outside the "after" modes, which report nothing:
    /// - in a raw-text or RCDATA element, the tokenizer has reported "End of
    ///   file seen when expecting text or an end tag."; upstream lists the
    ///   open elements after it and closes that element;
    /// - in the head, elements open inside it are an error;
    /// - in a frameset, any open element is;
    /// - in the body (or a table), any open element whose end tag can't be
    ///   left out (the list here isn't quite the one for </body>) is;
    /// - in a <template>, upstream lists what's open, closes the template, and
    ///   checks again (in its "in template" mode, it only lists them).
    /// Errors about open elements are followed by the list of them (see
    /// appendUnclosedElements); an element already listed isn't listed again.
    private func appendEndOfFileMessages(stack: inout [OpenElement], sections: HTMLImplicitClosures.DocumentSections, offset: Int, locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        func endOfFileError() {
            appendError("End of file seen and there were open elements.", offset: offset, length: 1, locations: locations, messages: &messages)
            appendUnclosedElements(above: -1, stack: &stack, locations: locations, messages: &messages)
        }
        if let current = stack.last, .html == current.namespace, Self.textContentElements.contains(current.name) {
            appendUnclosedElements(above: -1, stack: &stack, locations: locations, messages: &messages)
            stack.removeLast()
        }
        // Upstream's insertion mode decides, and an open <template> (in the
        // head too) has its own, so each pass finds the mode again after
        // closing one. (With a template open in the head, the head's rule
        // used to apply instead: a false open-elements error, or, when the
        // <head> tag had been left out, nothing at all.)
        while true {
            let templateIndex = stack.lastIndex(where: { .html == $0.namespace && "template" == $0.name })
            if nil == templateIndex, sections.isInHead {
                // Anything open in the head (a <noscript>; the head itself
                // may have been implied) is an error.
                if stack.contains(where: { !(.html == $0.namespace && ("html" == $0.name || "head" == $0.name)) }) {
                    endOfFileError()
                }
                return
            }
            if nil == templateIndex, stack.contains(where: { .html == $0.namespace && "frameset" == $0.name }) {
                endOfFileError()
                return
            }
            // (In a template's own "in template" insertion mode, with nothing
            // but head content in it, upstream only lists what's open and
            // closes the template: its open-elements check belongs to the
            // body and table modes, a template's included. This used to
            // report "End of file seen and there were open elements." for
            // <template><script>…</script> left open.)
            let isInTemplateMode = stack.last.map { .html == $0.namespace && "template" == $0.name && .inTemplate == $0.templateMode } ?? false
            if !isInTemplateMode, stack.contains(where: { !(.html == $0.namespace && Self.elementsQuietAtEndOfFile.contains($0.name)) }) {
                endOfFileError()
            }
            guard let templateIndex else {
                return
            }
            appendUnclosedElements(above: -1, stack: &stack, locations: locations, messages: &messages)
            stack.removeSubrange(templateIndex...)
        }
    }

    /// Review item A2: what </body> and </html> do in the insertion mode the
    /// stack implies: in the body, they're body end tags; in a table, cell,
    /// caption, column group, frameset, or a template in its "in template" or
    /// table modes (or one in the head), they're stray; in a template in
    /// "in column group" mode, they're "Garbage in “colgroup” fragment".
    /// (Stray table parts and framesets aren't on the stack; see
    /// HTMLImplicitClosures.ignoredStartTag.)
    private enum BodyEndContext {
        case body
        case stray
        case columnGroupGarbage
    }

    private static func bodyEndContext(in stack: [OpenElement]) -> BodyEndContext {
        var index = stack.count - 1
        while index >= 0 {
            let element = stack[index]
            if .html == element.namespace {
                switch element.name {
                case "body":
                    return .body
                case "caption", "colgroup", "frameset", "table", "tbody", "td", "tfoot", "th", "thead", "tr":
                    return .stray
                case "template":
                    switch element.templateMode {
                    case .inTemplate, .inTable:
                        return .stray
                    case .inColumnGroup:
                        return .columnGroupGarbage
                    case .inBody:
                        return element.startedInBody ? .body : .stray
                    }
                default:
                    break
                }
            }
            index -= 1
        }
        return .body
    }

    /// Review item A2: the innermost open HTML table or template (see
    /// HTMLImplicitClosures.TableContext).
    private static func tableContext(in stack: [OpenElement]) -> HTMLImplicitClosures.TableContext {
        guard let element = stack.last(where: { .html == $0.namespace && ("table" == $0.name || "template" == $0.name) }) else {
            return .none
        }
        return ("table" == element.name) ? .table : .template(element.templateMode)
    }

    /// Review item A2: a start tag processed while the innermost template is
    /// still in "in template" mode (only head content in it so far) sets that
    /// template's mode, as upstream's tree builder does; HTMLTreeEventBuilder
    /// does the same.
    private static func noteTemplateContent(_ name: String, namespace: HTMLNamespace, stack: inout [OpenElement]) {
        guard let index = HTMLImplicitClosures.templateInTemplateMode(count: stack.count, element: { (stack[$0].name, stack[$0].namespace, stack[$0].templateMode) }),
              let mode = HTMLImplicitClosures.templateContentMode(afterStartTag: name, namespace: namespace) else {
            return
        }
        stack[index].templateMode = mode
    }

    public func validate(source: String) -> [ValidationMessage] {
        let locations = SourceLocationMap(source)
        let document = HTMLDocumentParser(source: source, locations: locations).parse()
        let tokens = document.tokens
        var messages: [ValidationMessage] = []
        var sawDoctype = false
        var sawStartTag = false
        var sawHTMLLang = false
        // Review item A2: see AfterBodyMode.
        var afterBodyMode = AfterBodyMode.inBody
        // Review item A2: see HTMLImplicitClosures.DocumentSections.
        var sections = HTMLImplicitClosures.DocumentSections()
        // Case 554591: quirks mode changes one implicit closure (<table>
        // doesn't close an open <p>); see HTMLImplicitClosures.isQuirksMode.
        var quirksMode = false
        var firstStartTag: (offset: Int, length: Int)?
        // Review item A2: each ID's first start tag (see the .startTag case).
        var ids: [String: (offset: Int, length: Int)] = [:]
        var metaCharsetCount = 0
        var stack: [OpenElement] = []
        // Case 554591 (item 4): each <figure>'s content so far (see
        // FigureContent), by its start tag's offset, which no other element
        // shares. (Keyed by the tag rather than kept in OpenElement, which
        // review item A2 kept small; nor in a stack of its own, which every
        // place that closes elements would then have to pop.)
        var figureContents: [Int: FigureContent] = [:]
        // Case 554591 (item 12): the start tag offsets of the HTML colgroups
        // that have a span attribute, whose children upstream's schema
        // rejects (see colgroupContentModelMessage); kept by the tag, as
        // figureContents is, and for the same reasons.
        var spannedColgroups: Set<Int> = []
        // Case 554591 (item 12, from its review): each table's column
        // section (see TableColumnSection), by its start tag's offset.
        var tableColumnSections: [Int: TableColumnSection] = [:]
        // Case 554591 (item 12, from its review): the start-tag offsets of the
        // tables in which upstream's parser now has a colgroup open that it
        // implied for a col directly in the table, which the port doesn't
        // model as an element: </colgroup> closes it, where this reported
        // "Stray end tag “colgroup”" for the valid <table><col></colgroup>.
        // Like any colgroup that is the current node, it ends at any start
        // tag but col or template, at most end tags and at non-space text
        // (see HTMLImplicitClosures.beforeStartTag). (From its third review:
        // one for each table. It was a single value, which a table nested in a
        // template in the implied colgroup took over or cleared; so a second
        // template there closed the outer table's column section, and the
        // spans and children of the colgroups after it went unchecked, and the
        // outer </colgroup> was "stray".)
        var impliedColgroupTables: Set<Int> = []
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
            case .comment:
                continue
            case let .text(content, offset, _):
                // (Case 554591, item 12, from its reviews: non-space text ends
                // a colgroup that is the current node, as in the tree builder;
                // see HTMLImplicitClosures.beforeStartTag and
                // textEndsColumnGroup. Upstream's parser then handles it as
                // text in the table.)
                if let current = stack.last, .html == current.namespace, "colgroup" == current.name, HTMLImplicitClosures.textEndsColumnGroup(content) {
                    stack.removeLast()
                }
                if let table = stack.last, "table" == table.name, impliedColgroupTables.contains(table.offset), HTMLImplicitClosures.textEndsColumnGroup(content) {
                    impliedColgroupTables.remove(table.offset)
                }
                // Case 554591 (item 4): text directly in a <figure>, which
                // its content model takes before a figcaption (making that
                // caption the last thing the figure may have) or after a
                // caption that came first, but not after one that came last
                // (see FigureContent). This comes before the check below,
                // which passes over text that's all HTML whitespace: upstream's
                // schema validator counts a form feed as text. After </body>,
                // whitespace still goes into the open figure, as does any text
                // after </html> (the error below, after which upstream goes
                // on); but not non-space text after </body>, the error below
                // after which vnu.jar stops checking. (After a frameset there
                // can be no figure. Upstream first reopens any formatting
                // element, such as a <b>, that a misnested end tag closed,
                // which the port doesn't model; the text then goes in that.)
                let textStopsUpstream = .afterBody == afterBodyMode && HTMLImplicitClosures.containsNonSpace(content)
                if !textStopsUpstream, let figure = stack.last, .html == figure.namespace, "figure" == figure.name {
                    appendFigureTextMessages(content, offset: offset, stack: stack[...], figureContents: &figureContents, locations: locations, messages: &messages)
                }
                // Review item A2: non-space text, where the insertion mode
                // handles it (not in foreign content, which its own rules
                // handle), as upstream's tree builder takes it: after </body>
                // it's "Non-space character after body." (where upstream also
                // stops checking, which the port doesn't); after </html>, "…in
                // page trailer."; both then go back to the body. After a
                // frameset, every non-space character is reported and ignored.
                // In the head, it ends the head and starts the body. The port
                // used to skip text here; a fitted rule reported only the
                // literal "</body>text".
                // (Text in a raw-text or RCDATA element, such as a <noframes>
                // after the frameset, is that element's content, in upstream's
                // "text" mode, whatever mode came before it.)
                guard HTMLImplicitClosures.containsNonSpace(content), stack.last.map({ (.html == $0.namespace && !Self.textContentElements.contains($0.name)) || (.html != $0.namespace && $0.childrenAreHTML) }) ?? true else {
                    continue
                }
                switch afterBodyMode {
                case .afterBody, .afterAfterBody:
                    let leadingSpace = content.utf16.prefix { 0x20 == $0 || 0x09 == $0 || 0x0A == $0 || 0x0C == $0 || 0x0D == $0 }.count
                    appendError(.afterBody == afterBodyMode ? "Non-space character after body." : "Non-space character in page trailer.", offset: offset + leadingSpace, length: 1, locations: locations, messages: &messages)
                    afterBodyMode = .inBody
                case .afterFrameset, .afterAfterFrameset:
                    for (position, unit) in content.utf16.enumerated() where !(0x20 == unit || 0x09 == unit || 0x0A == unit || 0x0C == unit || 0x0D == unit) {
                        appendError(.afterFrameset == afterBodyMode ? "Non-space after \u{201c}frameset\u{201d}." : "Non-space character in page trailer.", offset: offset + position, length: 1, locations: locations, messages: &messages)
                    }
                    continue
                case .inBody:
                    break
                }
                // (In a frameset, upstream reports each non-space character
                // and ignores it.)
                if let current = stack.last, .html == current.namespace, "frameset" == current.name {
                    for (position, unit) in content.utf16.enumerated() where !(0x20 == unit || 0x09 == unit || 0x0A == unit || 0x0C == unit || 0x0D == unit) {
                        appendError("Non-space in \u{201c}frameset\u{201d}.", offset: offset + position, length: 1, locations: locations, messages: &messages)
                    }
                    continue
                }
                if sections.textStartsBody, stack.last.map({ .html == $0.namespace && ("html" == $0.name || "head" == $0.name) }) ?? true {
                    if let headIndex = stack.lastIndex(where: { .html == $0.namespace && "head" == $0.name }) {
                        stack.removeSubrange(headIndex...)
                    }
                    sections.noteBodyStarted()
                }
            case let .startTag(writtenName, attributes, selfClosing, namespace, offset, length):
                if firstStartTag == nil {
                    firstStartTag = (offset, length)
                }
                // Review item A2: an HTML <image> start tag is handled as <img>
                // (as in upstream's tree builder, and in HTMLTreeEventBuilder);
                // validateStartTag reports it, under the written name where
                // upstream does.
                let name = (.html == namespace && "image" == writtenName) ? "img" : writtenName
                // Review item A2: duplicate attributes, which upstream's
                // tokenizer reports for every start tag, whatever the tree
                // builder then does with it (a tag it ignores included). These
                // used to be checked with the rest of a tag's checks, which an
                // ignored tag now skips.
                appendDuplicateAttributeMessages(attributes, locations: locations, messages: &messages)
                // Review item A2: duplicate IDs, as upstream's tree builder
                // checks them: first thing for every start tag, so one it then
                // ignores (a stray <frame> or <td>, an <html> after </body>)
                // still counts; in any namespace; for an empty ID too; and not
                // at all inside a <template> (the template's own ID still
                // counts). Like upstream, this also says where the first one
                // was. The port used to check HTML and foreign elements apart,
                // later on, so it skipped the tags it ignored, empty IDs, and
                // nothing in a template.
                if !Self.childFlags(of: stack.last, childNamespace: namespace).contains(.inTemplateContents), let id = attributes.first(where: { "id" == $0.name }).map({ decodeEntities($0.value ?? "") }) {
                    if let first = ids[id] {
                        appendError("Duplicate ID \u{201c}\(id)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                        appendWarning("The first occurrence of ID \u{201c}\(id)\u{201d} was here.", offset: first.offset, length: first.length, locations: locations, messages: &messages)
                    } else {
                        ids[id] = (offset, length)
                    }
                }
                // Review item A2: whether the insertion mode handles the tag
                // (an HTML element, or the <svg> or <math> that starts foreign
                // content) rather than the foreign-content rules (a foreign
                // element's child). Upstream's dispatcher also sends an <svg>
                // directly in a MathML <annotation-xml> to the insertion mode.
                let isHandledAsForeign = HTMLForeignContent.isHandledAsForeign(name, namespace: namespace, parentChildrenAreHTML: stack.last?.childrenAreHTML ?? true)
                let insertionModeHandlesTag = !isHandledAsForeign || ("svg" == name && .svg == namespace && .mathML == stack.last?.namespace && "annotation-xml" == stack.last?.name)
                // Review item A2: after </body> or </html>, upstream reports a
                // start tag that its insertion mode handles as stray, and then
                // handles it as body content, so only the first one is
                // reported; an <html> start tag is reported and otherwise
                // ignored. (This used to report every start tag after </body>.
                // After </html>, upstream also stops checking the document
                // there, with "Cannot recover after last error"; the port goes
                // on.) After a frameset, every start tag but <noframes> is
                // reported and ignored.
                if insertionModeHandlesTag {
                    switch afterBodyMode {
                    case .afterBody, .afterAfterBody:
                        appendError("Stray start tag \u{201c}\(writtenName)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                        if .html == namespace, "html" == name {
                            validateNamespaceDeclarations(namespace: namespace, attributes: attributes, offset: offset, length: length, locations: locations, messages: &messages)
                            sections.noteStartTag(name, namespace: namespace, ignored: true, inTemplateContents: false)
                            continue
                        }
                        afterBodyMode = .inBody
                    case .afterFrameset, .afterAfterFrameset:
                        if !(.html == namespace && "noframes" == name) {
                            appendError("Stray start tag \u{201c}\(writtenName)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                            sections.noteStartTag(name, namespace: namespace, ignored: true, inTemplateContents: false)
                            continue
                        }
                    case .inBody:
                        break
                    }
                }
                sawStartTag = true
                if !sawDoctype {
                    appendError("Start tag seen without seeing a doctype first. Expected \u{201c}<!DOCTYPE html>\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    quirksMode = HTMLImplicitClosures.isQuirksMode(sawDoctype: false)
                    sawDoctype = true
                }
                // Case 554591: work out which open elements this start tag
                // closes implicitly *before* checking where it may appear.
                // The content model applies to the parent the element actually
                // gets after HTML's optional end tags are implied, so e.g. the
                // second <li> of "<li>A<li>B" is a child of the <ul>, not of
                // the first <li>, and "<p>Intro<ul>" puts the <ul> in the
                // body, not in the <p>. Checking against the pre-closure stack
                // reported valid documents as errors.
                //
                // Review item A2: an HTML start tag in foreign content (one of
                // the "breakout" tags, such as <p> inside <svg>) ends the
                // foreign content first, as in upstream's tree builder; the
                // tokenizer has already decided which tags those are.
                if .html == namespace, let top = stack.last, !top.childrenAreHTML {
                    appendError("HTML start tag \u{201c}\(writtenName)\u{201d} in a foreign namespace context.", offset: offset, length: length, locations: locations, messages: &messages)
                    while let top = stack.last, !top.childrenAreHTML {
                        stack.removeLast()
                    }
                }
                // Review item A2: the start tags upstream's tree builder
                // ignores (see HTMLImplicitClosures.ignoredStartTag), reported
                // as upstream reports them; HTMLTreeEventBuilder leaves them
                // out too. The port used to insert them, so a second <body>, a
                // stray <td> or <frameset>, or an <html> or <head> in the body
                // became an open element that later end tags then found
                // unclosed (and a stray <frame> was reported as obsolete). One
                // that implies the body (a stray <frame> or table part) still
                // closes the head first, as upstream's "anything else" rule in
                // the head does. In a table, a stray <frame> is first reported
                // as being there, as other tags are (validateStartTag).
                let tagIsInTemplateContents = Self.childFlags(of: stack.last, childNamespace: namespace).contains(.inTemplateContents)
                if !isHandledAsForeign, let ignored = HTMLImplicitClosures.ignoredStartTag(name, namespace: namespace, sections: sections, inTemplateContents: tagIsInTemplateContents, formIsOpen: stack.contains(where: { .html == $0.namespace && "form" == $0.name }), tableContext: Self.tableContext(in: stack)) {
                    if "frame" == name, nil != HTMLImplicitClosures.tableInsertionModeIndex(in: stack[((stack.lastIndex { .html != $0.namespace }).map { $0 + 1 } ?? 0)...].map(\.name)) {
                        appendError("Start tag \u{201c}frame\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    switch ignored {
                    case .stray:
                        appendError("Stray start tag \u{201c}\(writtenName)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    case .alreadyOpen:
                        appendError("Start tag \u{201c}\(name)\u{201d} seen but an element of the same type was already open.", offset: offset, length: length, locations: locations, messages: &messages)
                    case .nestedForm:
                        appendError("Saw a \u{201c}form\u{201d} start tag, but there was already an active \u{201c}form\u{201d} element. Nested forms are not allowed. Ignoring the tag.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    // (An ignored tag's slash isn't acknowledged either, so
                    // <frame/> outside a frameset is the self-closing error.)
                    if "frame" == name, selfClosing {
                        appendError("Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    // (Upstream checks a stray <html>'s namespace attributes,
                    // as it merges them into the first.)
                    if "html" == name {
                        validateNamespaceDeclarations(namespace: namespace, attributes: attributes, offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    if sections.isInHead, !tagIsInTemplateContents, HTMLImplicitClosures.startTagImpliesBody(name, namespace: namespace) {
                        if let headIndex = stack.lastIndex(where: { .html == $0.namespace && "head" == $0.name }) {
                            stack.removeSubrange(headIndex...)
                        }
                        sections.noteBodyStarted()
                    }
                    // (Case 554591, item 12, from its second review: in "in
                    // column group" mode the tag is "anything else" first,
                    // which ends a colgroup that is the current node, or the one
                    // upstream's parser implied (see impliedColgroupTables),
                    // before the tag is ignored in the table; an <html> start
                    // tag goes by the "in body" rules and ends nothing. The
                    // tree builder does the same. This kept the colgroup open,
                    // so <colgroup span=2><frame><col> put the col in it.)
                    if "html" != name {
                        if let current = stack.last, .html == current.namespace, "colgroup" == current.name {
                            stack.removeLast()
                        } else if let table = stack.last, .html == table.namespace, "table" == table.name {
                            impliedColgroupTables.remove(table.offset)
                        }
                    }
                    sections.noteStartTag(name, namespace: namespace, ignored: true, inTemplateContents: tagIsInTemplateContents)
                    continue
                }
                // An HTML element stays open unless it's void: the slash in
                // "<div/>" means nothing in HTML. (This used to leave every
                // self-closed HTML element off the stack, so "<div/>text</div>"
                // reported a stray end tag.) A foreign element is complete when
                // self-closed.
                let pushesElement = (.html == namespace) ? !HTMLVocabulary.voidElements.contains(name) : !selfClosing
                // A foreign element's children (SVG's <path>, MathML's <mi>)
                // aren't HTML: HTML's vocabulary, content models, implied end
                // tags and self-closing rule don't apply to them, so of the
                // start-tag checks only the namespace-neutral ones run.
                if isHandledAsForeign {
                    var flags = Self.childFlags(of: stack.last, childNamespace: namespace)
                    if HTMLForeignContent.childrenAreHTML(name, namespace: namespace, attributes: attributes) {
                        flags.insert(.childrenAreHTML)
                    }
                    if HTMLForeignContent.schemaRejects(name, namespace: namespace, parent: stack.last?.name, parentNamespace: stack.last?.namespace) {
                        flags.insert(.inRejectedSubtree)
                    }
                    if sections.bodyStarted {
                        flags.insert(.startedInBody)
                    }
                    validateForeignStartTag(name: name, namespace: namespace, stack: stack, attributes: attributes, offset: offset, length: length, locations: locations, messages: &messages)
                    if pushesElement {
                        stack.append(OpenElement(name: name, offset: offset, length: length, namespace: namespace, templateMode: .inTemplate, flags: flags))
                    }
                    sections.noteStartTag(name, namespace: namespace, ignored: false, inTemplateContents: flags.contains(.inTemplateContents))
                    continue
                }
                // Review item A2: a reopened <a> or <nobr> (see
                // HTMLImplicitClosures.reopenedFormattingElement): the error,
                // and the old element closed. The port reported nothing, and
                // a later </body> then listed the old one as unclosed.
                if .html == namespace, "a" == name || "nobr" == name,
                   let reopened = HTMLImplicitClosures.reopenedFormattingElement(named: name, count: stack.count, element: { (stack[$0].name, stack[$0].namespace, stack[$0].childrenAreHTML) }) {
                    appendError("Start tag \u{201c}\(name)\u{201d} seen but an element of the same type was already open.", offset: offset, length: length, locations: locations, messages: &messages)
                    if !reopened.inScope {
                        appendError("No \u{201c}\(name)\u{201d} element in scope but a \u{201c}\(name)\u{201d} end tag seen.", offset: offset, length: length, locations: locations, messages: &messages)
                        stack.remove(at: reopened.index)
                    } else {
                        if reopened.index != stack.count - 1 {
                            appendError("End tag \u{201c}\(name)\u{201d} violates nesting rules.", offset: offset, length: length, locations: locations, messages: &messages)
                        }
                        if reopened.hasFurthestBlock {
                            stack.remove(at: reopened.index)
                        } else {
                            stack.removeSubrange(reopened.index...)
                        }
                    }
                }
                // Otherwise the tag is processed as HTML: an HTML element, or
                // the <svg> or <math> that starts foreign content. The implied
                // end tag rules see only the HTML elements above the innermost
                // foreign one (see "Foreign content" in HTMLImplicitClosures).
                // (Table-scoped tags see the whole stack, foreign elements
                // blanked out; see HTMLImplicitClosures.tableScopedStartTags.)
                let boundary = HTMLImplicitClosures.tableScopedStartTags.contains(name) ? 0 : (stack.lastIndex { .html != $0.namespace }).map { $0 + 1 } ?? 0
                var closure = HTMLImplicitClosures.beforeStartTag(name, openElements: stack[boundary...].map { .html == $0.namespace ? $0.name : "" }, quirksMode: quirksMode)
                closure.keepCount += boundary
                // (Review item A2: the stack after the implied end tags is a
                // slice of it, not a copy; copying the whole stack for every
                // start tag made deeply nested documents slower still.)
                let startTagFlags = validateStartTag(name: name, writtenName: writtenName, attributes: attributes, selfClosing: selfClosing, namespace: namespace, offset: offset, length: length, stack: stack, contentStack: stack[..<closure.keepCount], impliedEndTagErrors: closure.errors, inHead: sections.isInHead, locations: locations, figureContents: &figureContents, spannedColgroups: &spannedColgroups, tableColumnSections: &tableColumnSections, impliedColgroupTables: impliedColgroupTables, metaCharsetCount: &metaCharsetCount, sawHTMLLang: &sawHTMLLang, messages: &messages)
                // Review item A2: after "End tag “p” implied, but there were
                // open elements." and the like, upstream lists the elements
                // above the one closed (see appendUnclosedElements).
                if closure.errors.contains(where: { $0.hasSuffix(", but there were open elements.") }) {
                    appendUnclosedElements(above: closure.keepCount, stack: &stack, locations: locations, messages: &messages)
                }
                stack.removeSubrange(closure.keepCount...)
                // (Case 554591, item 12: see impliedColgroupTables. A template
                // goes in the implied colgroup, which stays open around it.)
                if let table = stack.last, .html == table.namespace, "table" == table.name {
                    if .html == namespace, "col" == name {
                        impliedColgroupTables.insert(table.offset)
                    } else if !(.html == namespace && "template" == name) {
                        impliedColgroupTables.remove(table.offset)
                    }
                }
                Self.noteTemplateContent(name, namespace: namespace, stack: &stack)
                sections.noteStartTag(name, namespace: namespace, ignored: false, inTemplateContents: Self.childFlags(of: stack.last, childNamespace: namespace).contains(.inTemplateContents))
                // Review item A2: the new element's flags come from its parent
                // after the implied end tags: a table part that closes an open
                // SVG <desc> (table scope reaches past it) isn't inside it.
                var flags = Self.childFlags(of: stack.last, childNamespace: namespace)
                if HTMLForeignContent.childrenAreHTML(name, namespace: namespace, attributes: attributes) {
                    flags.insert(.childrenAreHTML)
                }
                if sections.bodyStarted {
                    flags.insert(.startedInBody)
                }
                // Case 554591 (item 4): an element the figure rules found not
                // allowed where it is (see figureContentModelMessage) starts
                // a rejected subtree, where upstream's schema reports nothing
                // more ("Suppressing further errors from this subtree"); and
                // an unknown or legacy element, or one the older content-model
                // rules reject, marks itself as one whose content upstream
                // doesn't check (see Flags.inUncheckedElement).
                flags.formUnion(startTagFlags)
                // Review item A2: a <math> where MathML can't go: in a MathML
                // element (an annotation-xml with an HTML encoding, or a token
                // element: mi, mn, mo or ms; mtext takes HTML phrasing content,
                // <math> included), or anywhere in annotation-xml's anyElement
                // content, which excludes MathML at every depth (vnu.jar:
                // "Element “math” not allowed as child of “span”"). Upstream
                // reports nothing more inside it. (See also
                // HTMLForeignContent.schemaRejects.)
                // (In an SVG <desc>'s unchecked content, though, nothing is
                // reported; only annotation-xml's anyElement content excludes
                // MathML. See OpenElement.Flags.inAnnotationXMLContent.)
                if .mathML == namespace, "math" == name, let parent = stack.last, HTMLForeignContent.schemaRejects(name, namespace: namespace, parent: parent.name, parentNamespace: parent.namespace) || parent.isInAnnotationXMLContent {
                    if flags.isDisjoint(with: [.inRejectedSubtree, .inTemplateContents]), !flags.contains(.inAnyElementContent) || flags.contains(.inAnnotationXMLContent) {
                        appendError(HTMLVocabulary.notAllowedAsChildMessage("math", parent: HTMLForeignContent.displayName(parent.name, namespace: parent.namespace)), offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    flags.insert(.inRejectedSubtree)
                } else if let parent = stack.last, HTMLForeignContent.tokenElementRejects(name, parent: parent.name, parentNamespace: parent.namespace) {
                    // Review item A2: HTML in a MathML token element that
                    // doesn't take it (see HTMLForeignContent.tokenElementRejects):
                    // "Element “b” not allowed as child of “mi”", which starts a
                    // rejected subtree. (Not where upstream's schema checks
                    // nothing; see OpenElement.Flags.)
                    // (An element HTML doesn't know at all already has this
                    // message from validateStartTag, which vnu.jar gives once.)
                    let validateStartTagReportedIt = .html == namespace && Self.isUnknownHTMLElement(name)
                    if !validateStartTagReportedIt, flags.isDisjoint(with: [.inRejectedSubtree, .inTemplateContents, .inAnyElementContent]) {
                        appendError(HTMLVocabulary.notAllowedAsChildMessage(name, parent: parent.name), offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    flags.insert(.inRejectedSubtree)
                }
                if pushesElement {
                    stack.append(OpenElement(name: name, offset: offset, length: length, namespace: namespace, templateMode: .inTemplate, flags: flags))
                } else if selfClosing && .html == namespace && HTMLVocabulary.voidElements.contains(name) {
                    appendInfo("Trailing slash on void elements has no effect and interacts badly with unquoted attribute values.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            case let .endTag(name, offset, length):
                // Review item A2: an end tag while the current node is a
                // foreign element follows upstream's foreign-content steps
                // (TreeBuilder.endTag): it's an error unless it closes the
                // current node, and it closes the nearest matching foreign
                // element; if it reaches an HTML element first, it's then
                // handled as an HTML end tag below. (Upstream doesn't give </p>
                // or </br> the spec's newer breakout step here.)
                if let current = stack.last, .html != current.namespace {
                    if current.name != name {
                        appendError("End tag \u{201c}\(name)\u{201d} did not match the name of the current open element (\u{201c}\(HTMLForeignContent.displayName(current.name, namespace: current.namespace))\u{201d}).", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    if let match = stack.lastIndex(where: { .html == $0.namespace || name == $0.name }), .html != stack[match].namespace {
                        stack.removeSubrange(match...)
                        continue
                    }
                }
                // Case 554591 (item 12, from its review): "in column group"
                // mode ends a colgroup that is the current node at most end
                // tags, which are then handled as in the table (see
                // HTMLImplicitClosures.endTagEndsColumnGroup); the tree
                // builder does the same.
                if HTMLImplicitClosures.endTagEndsColumnGroup(name), let current = stack.last, .html == current.namespace, "colgroup" == current.name {
                    stack.removeLast()
                }
                // (Case 554591, item 12: the same for the colgroup upstream's
                // parser implies; see impliedColgroupTables. Its </colgroup>
                // closes it, and is no stray end tag.)
                if let table = stack.last, .html == table.namespace, "table" == table.name, impliedColgroupTables.contains(table.offset) {
                    if "colgroup" == name {
                        impliedColgroupTables.remove(table.offset)
                        continue
                    }
                    if HTMLImplicitClosures.endTagEndsColumnGroup(name) {
                        impliedColgroupTables.remove(table.offset)
                    }
                }
                // Review item A2: the end tag of a raw-text or RCDATA element
                // (</script>, </noframes>, ...) is handled by upstream's "text"
                // mode, which closes it and returns to the mode before it, so
                // the after-body and after-frameset modes don't see it.
                if let current = stack.last, .html == current.namespace, Self.textContentElements.contains(current.name), current.name == name {
                    stack.removeLast()
                    continue
                }
                // Review item A2: the rest is the insertion mode's. After
                // </body> ("after body"), the first end tag is reported and
                // then handled again as body content, and </html> moves on to
                // "after after body", where the first end tag is a stray one,
                // likewise handled again. (This used to report, and skip, every
                // end tag after </body>, and nothing after </html>.) Being
                // handled again, with a foreign current node, repeats the
                // foreign end-tag step and its error first. After a frameset,
                // end tags are stray and ignored, </html> moving on to "after
                // after frameset".
                switch afterBodyMode {
                case .afterBody, .afterAfterBody:
                    if .afterBody == afterBodyMode, "html" == name {
                        afterBodyMode = .afterAfterBody
                        continue
                    }
                    appendError(.afterBody == afterBodyMode ? "Saw an end tag after \u{201c}body\u{201d} had been closed." : "Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    afterBodyMode = .inBody
                    if let current = stack.last, .html != current.namespace, current.name != name {
                        appendError("End tag \u{201c}\(name)\u{201d} did not match the name of the current open element (\u{201c}\(HTMLForeignContent.displayName(current.name, namespace: current.namespace))\u{201d}).", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                case .afterFrameset:
                    if "html" == name {
                        afterBodyMode = .afterAfterFrameset
                    } else {
                        appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    continue
                case .afterAfterFrameset:
                    appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    continue
                case .inBody:
                    break
                }
                if HTMLVocabulary.voidElements.contains(name) {
                    if name == "br" {
                        appendError("End tag \u{201c}br\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                        // Upstream inserts a <br> for it, which first ends any
                        // foreign content it's in.
                        popForeignContent(forInsertedElement: name, stack: &stack, offset: offset, length: length, locations: locations, messages: &messages)
                        appendInsertedElementMessages(name, offset: offset, length: length, stack: stack, bodyStarted: sections.bodyStarted, figureContents: &figureContents, locations: locations, messages: &messages)
                    } else {
                        appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    continue
                }
                // Review item A2: </head> in the head closes it, whether it was
                // written or implied (by <title> with no <head>, say, where
                // there's no element to close); after the head it's stray. The
                // port used to call the implied head's </head> stray.
                if "head" == name, sections.isInHead {
                    sections.noteHeadEnded()
                    if let headIndex = stack.lastIndex(where: { .html == $0.namespace && "head" == $0.name }) {
                        stack.removeSubrange(headIndex...)
                    }
                    continue
                }
                // Review item A2: an HTML end tag closes an HTML element, and
                // can't reach past the innermost HTML or MathML text
                // integration point (foreignObject, mi, ...), which upstream's
                // scope checks and its "special" category both stop at; so
                // <foreignObject><div></foreignObject> is a stray end tag, as
                // upstream reports it, rather than closing the <div>.
                // (Table-scoped end tags and </template> aren't stopped this
                // way upstream; see
                // HTMLImplicitClosures.endTagsUnscopedByIntegrationPoints.)
                let scopeStart = HTMLImplicitClosures.endTagsUnscopedByIntegrationPoints.contains(name) ? 0 : (stack.lastIndex { .html != $0.namespace && $0.childrenAreHTML }).map { $0 + 1 } ?? 0
                // Review item A2: </body> and </html> as upstream's tree builder
                // handles them (TreeBuilder.endTag). They close nothing in the
                // body: the elements stay open, and they switch to the "after
                // body" modes (see AfterBodyMode). The port used to close
                // everything, and to call these stray when no <body> or <html>
                // start tag was open, although upstream always has both by then
                // (the first body content implies <body>; in the head, these
                // end tags close the head and imply the body).
                if "body" == name || "html" == name {
                    switch Self.bodyEndContext(in: stack) {
                    case .stray:
                        appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                        continue
                    case .columnGroupGarbage:
                        appendError("Garbage in \u{201c}colgroup\u{201d} fragment.", offset: offset, length: length, locations: locations, messages: &messages)
                        continue
                    case .body:
                        break
                    }
                    // In the head, with no body yet, they close the head.
                    if sections.textStartsBody {
                        if let headIndex = stack.lastIndex(where: { .html == $0.namespace && "head" == $0.name }) {
                            stack.removeSubrange(headIndex...)
                        }
                        sections.noteBodyStarted()
                    }
                    // Elements still open, other than the ones whose end tags
                    // may be left out, are an error: for </body>, those above
                    // the body (or, when the <body> start tag was left out,
                    // above the <html>); for </html>, all of them. Upstream
                    // then lists them (see appendUnclosedElements).
                    let quiet = ("body" == name) ? HTMLImplicitClosures.elementsQuietAtBodyEnd : HTMLImplicitClosures.elementsQuietAtHTMLEnd
                    let checkedStart = ("body" == name) ? ((stack.firstIndex { .html == $0.namespace && "body" == $0.name }).map { $0 + 1 } ?? (stack.firstIndex { !(.html == $0.namespace && "html" == $0.name) } ?? stack.count)) : 0
                    if stack[checkedStart...].contains(where: { .html != $0.namespace || !quiet.contains($0.name) }) {
                        // (Two spaces after "for": upstream's spelling.)
                        appendError("End tag for  \u{201c}\(name)\u{201d} seen, but there were unclosed elements.", offset: offset, length: length, locations: locations, messages: &messages)
                        appendUnclosedElements(above: -1, stack: &stack, locations: locations, messages: &messages)
                    }
                    if "body" == name {
                        afterBodyMode = .afterBody
                    } else {
                        // Upstream handles </html> again in "after body", which
                        // goes on to "after after body"; with a foreign current
                        // node, that first repeats the foreign end-tag step,
                        // and its error.
                        if let current = stack.last, .html != current.namespace, current.name != name {
                            appendError("End tag \u{201c}\(name)\u{201d} did not match the name of the current open element (\u{201c}\(HTMLForeignContent.displayName(current.name, namespace: current.namespace))\u{201d}).", offset: offset, length: length, locations: locations, messages: &messages)
                        }
                        afterBodyMode = .afterAfterBody
                    }
                    continue
                }
                // (Case 554591, item 12, from its second review: </colgroup>
                // closes only a colgroup that is the current node, or the one
                // upstream's parser implied (above); anywhere else it's a
                // stray end tag, whatever colgroup is open further down. This
                // closed one around a template through the template, once
                // the colgroup in the template had ended.)
                if "colgroup" == name, !(stack.last.map { .html == $0.namespace && "colgroup" == $0.name } ?? false) {
                    appendError("Stray end tag \u{201c}colgroup\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    continue
                }
                guard let match = stack[scopeStart...].lastIndex(where: { .html == $0.namespace && $0.name == name }) else {
                    if name == "p" {
                        appendError("No \u{201c}p\u{201d} element in scope but a \u{201c}p\u{201d} end tag seen.", offset: offset, length: length, locations: locations, messages: &messages)
                        // Upstream inserts a <p> for it, which first ends any
                        // foreign content it's in.
                        popForeignContent(forInsertedElement: name, stack: &stack, offset: offset, length: length, locations: locations, messages: &messages)
                        appendInsertedElementMessages(name, offset: offset, length: length, stack: stack, bodyStarted: sections.bodyStarted, figureContents: &figureContents, locations: locations, messages: &messages)
                    } else {
                        appendError("Stray end tag \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                    continue
                }
                // Case 554591: the parser "generates implied end tags" before
                // it checks the current node, so elements whose end tags are
                // optional (li, p, dd, option, ...; and table parts for the
                // table end tags) aren't "open elements" here. Previously
                // "<ul><li>A</ul>" and "<div><p>text</div>" were errors.
                // (Review item A2: and, as upstream does, the error is followed
                // by the elements still open; see appendUnclosedElements.)
                if !HTMLImplicitClosures.endTagClosesQuietly(name, matchIndex: match, openElements: stack.map(\.name)) {
                    appendError("End tag \u{201c}\(name)\u{201d} seen, but there were open elements.", offset: offset, length: length, locations: locations, messages: &messages)
                    appendUnclosedElements(above: match, stack: &stack, locations: locations, messages: &messages)
                }
                // Review item A2: the outermost </frameset> starts upstream's
                // "after frameset" mode (see AfterBodyMode).
                if "frameset" == name, !stack[..<match].contains(where: { .html == $0.namespace && "frameset" == $0.name }) {
                    afterBodyMode = .afterFrameset
                    sections.noteFramesetEnded()
                }
                stack.removeSubrange(match...)
            }
        }

        // Review item A2: the end of the file, as upstream's tree builder
        // handles it (TreeBuilder.eof). This replaces a rule that reported
        // only an unclosed <picture> (a fitted rule).
        if .inBody == afterBodyMode {
            appendEndOfFileMessages(stack: &stack, sections: sections, offset: source.utf16.count, locations: locations, messages: &messages)
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

    /// Review item A2: for </p> without a <p> in scope, and for </br>, upstream
    /// inserts an empty <p> or <br>; when the current node is foreign, that
    /// HTML element ends the foreign content first (TreeBuilder.endTag's P and
    /// BR cases), with the breakout error.
    private func popForeignContent(
        forInsertedElement name: String,
        stack: inout [OpenElement],
        offset: Int,
        length: Int,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        guard let current = stack.last, .html != current.namespace else { return }
        appendError("HTML start tag \u{201c}\(name)\u{201d} in a foreign namespace context.", offset: offset, length: length, locations: locations, messages: &messages)
        while let top = stack.last, .html != top.namespace {
            stack.removeLast()
        }
    }

    /// Case 554591 (item 4): the element upstream's parser inserts for a
    /// stray </p> (an empty <p>) or a </br> (a <br>), when it goes in a
    /// figure: upstream's schema sees it as any other child, so it's content
    /// there, and a caption after it is the figure's last child, or, after
    /// such a caption, it's not allowed. The port reported only the end tag,
    /// so it took a caption after such a </p> for the first one, and missed
    /// the error after it. (The port's stack still doesn't hold the element,
    /// which has no content anyway. Only the figure rules check it so far:
    /// elsewhere, upstream's schema would check it against its parent too,
    /// "Element “p” not allowed as child of “span”", but where the port's
    /// tree differs from upstream's, as with a heading inside another, which
    /// upstream's parser closes, that put it in the wrong parent. Before a
    /// <br>, upstream also reopens any formatting element a misnested end tag
    /// closed, which the port doesn't model. Nothing is checked before the
    /// body, where upstream ignores a stray </p>; in a table, which would
    /// foster-parent the element, and where vnu.jar stops checking; or where
    /// upstream's schema checks nothing; see schemaChecksChildren.)
    private func appendInsertedElementMessages(
        _ name: String,
        offset: Int,
        length: Int,
        stack: [OpenElement],
        bodyStarted: Bool,
        figureContents: inout [Int: FigureContent],
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        // (Whether the parent is a figure comes first, as it rules out nearly
        // every one, before the walk down the stack for the table test: doing
        // that first made a deep document with many </br>s twice as slow.
        // figureContentModelMessage does the rest, checking only where
        // upstream's schema checks anything.)
        guard bodyStarted, let parent = stack.last, .html == parent.namespace, "figure" == parent.name else {
            return
        }
        let htmlStack = stack[((stack.lastIndex { .html != $0.namespace }).map { $0 + 1 } ?? 0)...]
        guard nil == HTMLImplicitClosures.tableInsertionModeIndex(in: htmlStack.map(\.name)) else {
            return
        }
        if let message = figureContentModelMessage(for: name, namespace: .html, stack: stack[...], inHead: false, isFosterParented: false, figureContents: &figureContents) {
            appendError(message, offset: offset, length: length, locations: locations, messages: &messages)
        }
    }

    /// Review item A2 (U16): namespace declarations, as upstream's tree builder
    /// checks them (TreeBuilder.checkAttributes) for every element: "xmlns"
    /// must name the element's own namespace; "xmlns:xlink" must name XLink on
    /// an SVG or MathML element and isn't allowed on an HTML one; and no other
    /// "xmlns:" attribute is allowed. ("xmlns:link" in the message is
    /// upstream's spelling.) HTMLGeneralAttributeChecker used to report every
    /// "xmlns:" attribute as not allowed, so nearly every SVG file, which
    /// declares xmlns:xlink, got an error, and it checked "xmlns" only on SVG.
    private func validateNamespaceDeclarations(
        namespace: HTMLNamespace,
        attributes: [HTMLAttribute],
        offset: Int,
        length: Int,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        let namespaceURI: String
        switch namespace {
        case .html:
            namespaceURI = "http://www.w3.org/1999/xhtml"
        case .svg:
            namespaceURI = "http://www.w3.org/2000/svg"
        case .mathML:
            namespaceURI = "http://www.w3.org/1998/Math/MathML"
        }
        // Only the first of duplicate attributes counts: upstream's tokenizer
        // drops the rest (the duplicate is reported elsewhere), so
        // <html xmlns="http://www.w3.org/1999/xhtml" xmlns="foo"> has no bad
        // value (review item A2).
        var seenNames: Set<String> = []
        for attribute in attributes where seenNames.insert(attribute.name).inserted {
            if "xmlns" == attribute.name {
                let value = decodeEntities(attribute.value ?? "")
                if value != namespaceURI {
                    appendError("Bad value \u{201c}\(value)\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}\(namespaceURI)\u{201d} permitted here).", offset: offset, length: length, locations: locations, messages: &messages)
                }
            } else if attribute.name.hasPrefix("xmlns:") {
                if .html != namespace, "xmlns:xlink" == attribute.name {
                    let value = decodeEntities(attribute.value ?? "")
                    if "http://www.w3.org/1999/xlink" != value {
                        appendError("Bad value \u{201c}\(value)\u{201d} for the attribute \u{201c}xmlns:link\u{201d} (only \u{201c}http://www.w3.org/1999/xlink\u{201d} permitted here).", offset: offset, length: length, locations: locations, messages: &messages)
                    }
                } else {
                    appendError("Attribute \u{201c}\(attribute.name)\u{201d} not allowed here.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            }
        }
    }

    /// Review item A2: duplicate attributes, which upstream's tokenizer
    /// reports for every start tag, whatever the tree builder then does with
    /// it (see validate()).
    private func appendDuplicateAttributeMessages(_ attributes: [HTMLAttribute], locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        var seenAttributes: Set<String> = []
        for attribute in attributes {
            if seenAttributes.contains(attribute.name) {
                appendError("Duplicate attribute \u{201c}\(attribute.name)\u{201d}.", offset: attribute.offset, length: max(1, attribute.name.utf16.count), locations: locations, messages: &messages)
            }
            seenAttributes.insert(attribute.name)
        }
    }

    /// Review item A2: the start-tag checks that apply to an element inside
    /// foreign content (SVG or MathML): duplicate attributes, which the
    /// tokenizer reports in any namespace; namespace declarations; and the
    /// SVG and MathML vocabularies and the parents some MathML elements
    /// require. (Duplicate IDs are checked for every start tag; see
    /// validate().) Everything else in validateStartTag is about HTML
    /// elements.
    private func validateForeignStartTag(
        name: String,
        namespace: HTMLNamespace,
        stack: [OpenElement],
        attributes: [HTMLAttribute],
        offset: Int,
        length: Int,
        locations: SourceLocationMap,
        messages: inout [ValidationMessage]
    ) {
        validateNamespaceDeclarations(namespace: namespace, attributes: attributes, offset: offset, length: length, locations: locations, messages: &messages)
        // These used to come, by accident, from the HTML vocabulary check,
        // which also reported every valid MathML element.
        // The schema's MathML vocabulary and required parents ("not allowed
        // as child"), and upstream's Assertions lists of MathML and SVG
        // elements ("completely-unknown"), which aren't the same thing: the
        // schema accepts content MathML such as <apply>, which Assertions
        // still reports.
        //
        // Where upstream's schema checks nothing, its "not allowed" messages
        // don't apply: in an SVG <desc> or annotation-xml's anyElement content
        // (see OpenElement.Flags.inAnyElementContent), in a <template> (where
        // upstream checks nothing at all, "completely-unknown" included), and
        // inside an element it has already rejected (vnu.jar's "Suppressing
        // further errors from this subtree"; Flags.inRejectedSubtree), where a
        // child gets only the "completely-unknown" message, if that.
        let parent = stack.last
        let inheritedFlags = Self.childFlags(of: parent, childNamespace: namespace)
        let inTemplateContents = inheritedFlags.contains(.inTemplateContents)
        let schemaChecksApply = inheritedFlags.isDisjoint(with: [.inTemplateContents, .inAnyElementContent, .inRejectedSubtree])
        if .mathML == namespace, let parentName = parent?.name {
            if schemaChecksApply, HTMLForeignContent.schemaRejects(name, namespace: namespace, parent: parentName, parentNamespace: parent?.namespace) {
                appendError(HTMLVocabulary.notAllowedAsChildMessage(name, parent: parentName), offset: offset, length: length, locations: locations, messages: &messages)
            }
            if !inTemplateContents, !HTMLForeignContent.mathMLElements.contains(name) {
                appendError("The \u{201c}\(name)\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }
        if .svg == namespace {
            let displayName = HTMLForeignContent.displayName(name, namespace: namespace)
            if !HTMLForeignContent.svgElements.contains(displayName) {
                // The schema's message, naming the SVG parent (vnu.jar gives
                // both for <svg><foo/></svg>; this one was missing). vnu.jar's
                // SVG schema and upstream's Assertions list know the same 81
                // elements (SVG 1.1's, plus feDropShadow), so one set serves
                // both messages, unlike MathML's above.
                if schemaChecksApply, let parent {
                    appendError(HTMLVocabulary.notAllowedAsChildMessage(displayName, parent: HTMLForeignContent.displayName(parent.name, namespace: parent.namespace)), offset: offset, length: length, locations: locations, messages: &messages)
                }
                if !inTemplateContents {
                    appendError("The \u{201c}\(displayName)\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            }
        }
    }

    /// Checks a start tag that the insertion mode handles. Returns flags for
    /// the new element (case 554591, item 4; see OpenElement.Flags):
    /// inRejectedSubtree when one of the rules here that start a rejected
    /// subtree rejects it (so far, the figure rules and item 12's colgroup
    /// rule), and
    /// inUncheckedElement when it's one whose content upstream's schema
    /// doesn't check.
    private func validateStartTag(
        name: String,
        writtenName: String,
        attributes: [HTMLAttribute],
        selfClosing: Bool,
        namespace: HTMLNamespace,
        offset: Int,
        length: Int,
        stack: [OpenElement],
        contentStack: ArraySlice<OpenElement>,
        impliedEndTagErrors: [String],
        inHead: Bool,
        locations: SourceLocationMap,
        figureContents: inout [Int: FigureContent],
        spannedColgroups: inout Set<Int>,
        tableColumnSections: inout [Int: TableColumnSection],
        impliedColgroupTables: Set<Int>,
        metaCharsetCount: inout Int,
        sawHTMLLang: inout Bool,
        messages: inout [ValidationMessage]
    ) -> OpenElement.Flags {
        var elementFlags: OpenElement.Flags = []
        // (Duplicate attributes are reported for every start tag; see
        // validate().)
        var attr: [String: String] = [:]
        for attribute in attributes {
            // The first of duplicate attributes wins, as in upstream's
            // tokenizer, which drops the rest; this used to keep the last.
            if nil == attr[attribute.name] {
                attr[attribute.name] = decodeEntities(attribute.value ?? "")
            }
        }
        validateNamespaceDeclarations(namespace: namespace, attributes: attributes, offset: offset, length: length, locations: locations, messages: &messages)

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

        // Review item A2: an HTML <image> start tag, which is checked as
        // <img> from here on (see validate()).
        if writtenName != name {
            appendError("Saw a start tag \u{201c}\(writtenName)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        // (A nested <form> is ignored, as upstream ignores it; see
        // HTMLImplicitClosures.ignoredStartTag.)

        if name == "basefont" {
            appendError("Element \u{201c}basefont\u{201d} not allowed as child of \u{201c}head\u{201d} in this context.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        if name == "head", attr["profile"] != nil {
            appendWarning("The \u{201c}profile\u{201d} attribute on the \u{201c}head\u{201d} element is obsolete. To declare which \u{201c}meta\u{201d} terms are used in the document, instead register the names as meta extensions. To trigger specific UA behaviors, use a \u{201c}link\u{201d} element instead.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        // Review item A2: these two look at the HTML elements above the
        // innermost foreign one only (see "Foreign content" in HTMLImplicitClosures):
        // a heading inside an SVG's <foreignObject> inside another heading, or
        // a <div> there inside a table, isn't nested in them as HTML.
        let htmlStack = stack[((stack.lastIndex { .html != $0.namespace }).map { $0 + 1 } ?? 0)...]
        // (And, as upstream's tree builder does, only when the current node,
        // after any implied </p>, is a heading: "<h1><span><h2>" isn't this
        // error, though the <h2> is still not allowed in the <span>.)
        if HTMLVocabulary.headingElements.contains(name), let current = contentStack.last, .html == current.namespace, HTMLVocabulary.headingElements.contains(current.name) {
            appendError("Heading cannot be a child of another heading.", offset: offset, length: length, locations: locations, messages: &messages)
        }

        // Case 554591: these parse errors belong to the table insertion modes,
        // i.e. while directly inside a table, row group or row, not inside a
        // cell or caption. The old checks fired for a <table> anywhere inside
        // another table, so a valid table nested in a <td> was an error, and
        // they only knew about <input>/<select> directly in a <table>, while
        // upstream reports every start tag that gets foster-parented out of
        // a table (errStartTagInTable).
        // (Case 554591, item 4: whether this one is, which the figure rules
        // want to know too: see figureContentModelMessage.)
        var isFosterParented = false
        if nil != HTMLImplicitClosures.tableInsertionModeIndex(in: htmlStack.map(\.name)) {
            if "table" == name {
                appendError("Start tag for \u{201c}table\u{201d} seen but the previous \u{201c}table\u{201d} is still open.", offset: offset, length: length, locations: locations, messages: &messages)
            } else if !HTMLImplicitClosures.isTableModeStartTag(name) {
                isFosterParented = true
                // (Review item A2: upstream reports an <image> here under that
                // name, then again as the <img> it handles it as.)
                if writtenName != name {
                    appendError("Start tag \u{201c}\(writtenName)\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                }
                appendError("Start tag \u{201c}\(name)\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }

        // (Case 554591, item 4: an element of the legacy schema's that takes
        // anything, or one HTML doesn't have, marks itself as one whose
        // content upstream's schema doesn't check; see
        // OpenElement.Flags.inUncheckedElement.)
        if HTMLVocabulary.obsoleteElements.contains(name) {
            if let obsoleteMessage = obsoleteElementMessage(for: name) {
                appendError(obsoleteMessage, offset: offset, length: length, locations: locations, messages: &messages)
            } else if name == "keygen" {
                appendError("The \u{201c}keygen\u{201d} element is obsolete.", offset: offset, length: length, locations: locations, messages: &messages)
            } else {
                appendError("The \u{201c}\(name)\u{201d} element is obsolete. Use CSS instead.", offset: offset, length: length, locations: locations, messages: &messages)
            }
            if .html == namespace, Self.legacyAnythingElements.contains(name) {
                elementFlags.insert(.inUncheckedElement)
            }
        } else if name == "menuitem", stack.last?.name != "menu" {
            appendError("The \u{201c}menuitem\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.", offset: offset, length: length, locations: locations, messages: &messages)
            if .html == namespace {
                elementFlags.insert(.inUncheckedElement)
            }
        } else if name.contains("-") {
            if !isValidAutonomousCustomElementName(name) {
                appendError("Element \u{201c}\(name)\u{201d} not allowed.", offset: offset, length: length, locations: locations, messages: &messages)
            }
            if attr["is"] != nil {
                appendError("Autonomous custom elements must not specify the \u{201c}is\u{201d} attribute.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        } else if !HTMLVocabulary.elements.contains(name) {
            // Review item A2: the parent is named as messages spell it, so an
            // unknown element in a <foreignObject> is "not allowed as child of
            // “foreignObject”" (this used to say “foreignobject”, the
            // tokenizer's lowercased name). Inside an SVG <desc> or a MathML
            // <annotation-xml>, at any depth, upstream's schemas accept any
            // HTML content at all, so there is no such message there (vnu.jar
            // reports one under an SVG <title>, though, and the port does too);
            // nor in a <template>, where upstream checks nothing, nor inside
            // an element upstream's schema has rejected (see
            // OpenElement.Flags).
            if .html == namespace {
                elementFlags.insert(.inUncheckedElement)
            }
            let inheritedFlags = Self.childFlags(of: contentStack.last, childNamespace: .html)
            let inTemplateContents = inheritedFlags.contains(.inTemplateContents)
            if inheritedFlags.isDisjoint(with: [.inTemplateContents, .inAnyElementContent, .inRejectedSubtree]) {
                let parent: String
                if let top = stack.last, "html" != top.name {
                    parent = HTMLForeignContent.displayName(top.name, namespace: top.namespace)
                } else {
                    parent = "body"
                }
                appendError(HTMLVocabulary.notAllowedAsChildMessage(name, parent: parent), offset: offset, length: length, locations: locations, messages: &messages)
            }
            // Upstream's Assertions checker also reports every HTML element
            // whose name it doesn't know, wherever it is (vnu.jar gives both
            // messages for <p><foo>, and only this one inside an SVG <desc>).
            // The port never did, so inside <desc> an unknown element, such
            // as the <rect/> of an icon whose <desc> was left unclosed (an
            // HTML element there), would otherwise go unreported. Its list
            // isn't the vocabulary above: it knows obsolete elements and newer
            // ones such as <selectedcontent>, which get no such message.
            if !inTemplateContents, !HTMLVocabulary.assertionsElements.contains(name) {
                appendError("The \u{201c}\(name)\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }

        // Review item 3: an <img> without a text alternative, by upstream's
        // rules (see ImageTextAlternativeFacts: a title, an ARIA label, a role
        // or other aria-* attributes each make it something else). This used
        // to be reported for every <img> without an alt attribute. One inside
        // a <figure> is left to HTMLGeneralAttributeChecker, which reports it
        // when the figure ends unless the figure's caption can stand in for
        // it; and nothing is reported in a <template>, where upstream checks
        // nothing. (It's reported here, as upstream does as it reads the tag,
        // so it keeps its place among this checker's messages.)
        if "img" == name, .html == namespace, ImageTextAlternativeFacts(attributes: attributes).needsAlt,
           !Self.childFlags(of: contentStack.last, childNamespace: .html).contains(.inTemplateContents),
           !contentStack.contains(where: { .html == $0.namespace && "figure" == $0.name }) {
            appendError(ImageTextAlternativeFacts.missingAltMessage, offset: offset, length: length, locations: locations, messages: &messages)
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

        // Parse errors from implicitly closing elements that don't have
        // optional end tags (e.g. "End tag \"p\" implied, but there were open
        // elements."), computed by HTMLImplicitClosures in validate().
        for impliedEndTagError in impliedEndTagErrors {
            appendError(impliedEndTagError, offset: offset, length: length, locations: locations, messages: &messages)
        }

        // Case 554591: the content model is checked against the stack after
        // implicit closures (see validate()), not the stack as it was when
        // the tag was seen.
        // (Review item A2: not for an HTML element whose parent is foreign,
        // such as a <foreignObject> or <mtext>: upstream doesn't judge HTML
        // children by an SVG or MathML parent's content model.)
        // (Review item A2: nor inside an element upstream's schema has
        // rejected, where it reports nothing more; see OpenElement.Flags.)
        // (Case 554591, item 4: then the figure rules, for a child of a
        // <figure> or a figcaption anywhere else, unless the rules above have
        // already reported the element. Unlike those, which are older, an
        // element these reject starts a rejected subtree, as in upstream.)
        // (Case 554591, item 12: and the colgroup rule, the same way, for a
        // child of a colgroup with a span attribute, which is recorded here
        // for its children to find.)
        if "colgroup" == name, .html == namespace, nil != attr["span"] {
            spannedColgroups.insert(offset)
        }
        // (Case 554591, item 12, from its review: a child of a table moves its
        // column section along (see TableColumnSection); a colgroup that comes
        // after the section has closed is one upstream's schema rejects, so
        // nothing inside it is checked. A start tag the table foster-parents
        // isn't the table's child upstream, so it moves nothing; nor does a
        // style, which the schema rejects without moving on, so a colgroup
        // after <colgroup></colgroup><style> is still in its place.)
        if .html == namespace, let table = contentStack.last, .html == table.namespace, "table" == table.name, !isFosterParented {
            var section = tableColumnSections[table.offset] ?? TableColumnSection()
            switch name {
            case "colgroup":
                if section.isClosed {
                    elementFlags.insert(.inUncheckedElement)
                } else {
                    section.sawColumnGroup = true
                }
            case "col":
                if !section.isClosed {
                    section.sawColumnGroup = true
                }
            case "script", "template":
                // (Case 554591, item 12, from its second review: not a
                // template after cols directly in the table, which goes in the
                // colgroup upstream's parser implied for them (see
                // impliedColgroupTables), not in the table; a script ends that
                // colgroup and lands in the table.)
                if section.sawColumnGroup, !("template" == name && impliedColgroupTables.contains(table.offset)) {
                    section.isClosed = true
                }
            case "thead", "tbody", "tfoot", "tr", "td", "th":
                section.isClosed = true
            default:
                break
            }
            tableColumnSections[table.offset] = section
        }
        // (Case 554591, item 12, from its second review: a colgroup's or col's
        // span as the schema checks it: see spanIsCheckedBySchema.)
        if .html == namespace, "colgroup" == name || "col" == name,
           let span = attributes.first(where: { "span" == $0.name }).map({ HTMLCharacterReferences.decodeAttributeValue($0.value ?? "") }),
           !Self.isPositiveInteger(span),
           spanIsCheckedBySchema(name, stack: contentStack, isMisplaced: elementFlags.contains(.inUncheckedElement), spannedColgroups: spannedColgroups, tableColumnSections: tableColumnSections) {
            appendError("Bad value \u{201c}\(span)\u{201d} for attribute \u{201c}span\u{201d} on element \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
        }
        // (Case 554591, U11, and the notes' item 30: a cell's colspan and
        // rowspan as the schema checks them, with its datatypes, ASCII digits
        // alone, not all zeros for a colspan (isPositiveInteger,
        // isNonNegativeInteger), and wherever it checks the cell: not where it
        // checks nothing (see schemaChecksChildren), as in a template, or in
        // a table it has rejected, such as one in a <label>. The table checker
        // reported these, with its own reader, which trimmed white space, so
        // that " 2", "2 " and a no-break space before the digits passed,
        // wherever it took the cell.)
        if .html == namespace, "td" == name || "th" == name,
           let parent = contentStack.last, .html == parent.namespace,
           Self.schemaChecksChildren(of: parent, childNamespace: .html), !elementFlags.contains(.inUncheckedElement) {
            // (In the order the attributes are written, as the schema checks
            // them, the first of duplicates; from U11's review. XMLParser
            // gives XMLValidator no order.)
            var seen: Set<String> = []
            for attribute in attributes where ("colspan" == attribute.name || "rowspan" == attribute.name) && seen.insert(attribute.name).inserted {
                let value = HTMLCharacterReferences.decodeAttributeValue(attribute.value ?? "")
                if "colspan" == attribute.name ? !Self.isPositiveInteger(value) : !Self.isNonNegativeInteger(value) {
                    appendError("Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute.name)\u{201d} on element \u{201c}\(name)\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                }
            }
        }
        if .html == contentStack.last?.namespace ?? .html, !(contentStack.last?.isInRejectedSubtree ?? false) {
            if let parentMessage = contentModelMessage(for: name, stack: contentStack, inHead: inHead) {
                appendError(parentMessage, offset: offset, length: length, locations: locations, messages: &messages)
                // (Case 554591, item 4: an element these older rules report
                // is one upstream's schema rejects, after which it checks
                // nothing inside it; so the figure rules don't look inside
                // it either, though these rules still do, as they always
                // have. Otherwise a figcaption in, say, the <div> of
                // <span><div>, which vnu.jar doesn't report, was. The one
                // message here that's the parser's rather than a rejection,
                // for a <picture> in a <noscript> in the head, makes no
                // difference: upstream's schema rejects anything in a
                // picture but what the figure rules don't check.)
                elementFlags.insert(.inUncheckedElement)
            } else if let figureMessage = figureContentModelMessage(for: name, namespace: namespace, stack: contentStack, inHead: inHead, isFosterParented: isFosterParented, figureContents: &figureContents) {
                appendError(figureMessage, offset: offset, length: length, locations: locations, messages: &messages)
                elementFlags.insert(.inRejectedSubtree)
            } else if let colgroupMessage = colgroupContentModelMessage(for: name, namespace: namespace, stack: contentStack, spannedColgroups: spannedColgroups) {
                appendError(colgroupMessage, offset: offset, length: length, locations: locations, messages: &messages)
                elementFlags.insert(.inRejectedSubtree)
            }
        }

        // (Review item A2: a self-closed <svg/> or <math/> is fine.)
        if selfClosing && .html == namespace && !HTMLVocabulary.voidElements.contains(name) {
            appendError("Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.", offset: offset, length: length, locations: locations, messages: &messages)
        }
        return elementFlags
    }

    private func contentModelMessage(for child: String, stack: ArraySlice<OpenElement>, inHead: Bool) -> String? {
        if child == "li" {
            let parent = stack.last?.name
            if parent != "ol" && parent != "ul" && parent != "menu" {
                let parentName = parent == nil || parent == "html" ? "body" : parent!
                return HTMLVocabulary.notAllowedAsChildMessage("li", parent: parentName)
            }
        }
        if child == "picture" {
            // (Case 554591, item 4: whether the <noscript> is in the head is
            // the port's model of the parser's state, not whether a <body> is
            // open: the port opens no element for a body it implies, so a
            // <noscript> in a body whose tag was left out was taken for one in
            // the head, and its <picture> got this error. The model still
            // takes one in a <template> in the head for one in the head,
            // though upstream's parser takes it as in a body.)
            if stack.last?.name == "noscript", inHead {
                return "Bad start tag in \u{201c}picture\u{201d} in \u{201c}noscript\u{201d} in \u{201c}head\u{201d}."
            }
            if let parent = stack.last?.name, Self.invalidPictureParents.contains(parent) {
                return "Element \u{201c}picture\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context."
            }
        }
        guard HTMLVocabulary.flowButNotPhrasing.contains(child), let parent = stack.last?.name else { return nil }
        // Review item A4: a, ins and del have transparent content models, so
        // what they may contain is whatever their own parent may contain. The
        // port used to list them as phrasing-only containers and check that
        // first, so a block inside one was always an error: card links
        // (<a href><div>…</div></a>) and <ins><p>…</p></ins> were rejected
        // even directly in body. Now the check looks through any transparent
        // ancestors to the nearest element whose content model isn't
        // transparent, as upstream's schema does, and the message names the
        // immediate parent (with the transparent-model Note when that parent
        // is transparent).
        let inheritedFrom = stack.last(where: { !HTMLVocabulary.transparentElements.contains($0.name) })?.name
        if let inheritedFrom, HTMLVocabulary.phrasingOnlyContainers.contains(inheritedFrom) {
            return HTMLVocabulary.notAllowedAsChildMessage(child, parent: parent)
        }
        return nil
    }

    /// Case 554591 (item 4): upstream's schema rules for <figure> and
    /// <figcaption> (html5/media.rnc), for a start tag whose parent is
    /// `stack.last`: the figure's content model (see FigureContent), the
    /// children a figure never takes, and a figcaption anywhere but in a
    /// figure. Returns the message for an element they don't allow there,
    /// which is then left out of its figure's content, as Jing leaves it out.
    /// Nothing is reported where upstream's schema checks nothing (see
    /// schemaChecksChildren), nor what another rule already reports.
    private func figureContentModelMessage(for child: String, namespace: HTMLNamespace, stack: ArraySlice<OpenElement>, inHead: Bool, isFosterParented: Bool, figureContents: inout [Int: FigureContent]) -> String? {
        // (Not for a start tag a table foster-parents, which the port has
        // already reported as "seen in “table”", and after which vnu.jar
        // stops checking: the port's stack doesn't put it where upstream's
        // parser does.)
        // (With no element open, the start tag goes in the body the parser
        // implies, which the port opens no element for when the document has
        // no <html> or <body> tag; contentModelMessage's <li> rule takes it
        // the same way.)
        guard !isFosterParented, .html == stack.last?.namespace ?? .html, Self.schemaChecksChildren(of: stack.last, childNamespace: namespace) else {
            return nil
        }
        let isFigcaption = .html == namespace && "figcaption" == child
        guard let parent = stack.last, "figure" == parent.name else {
            // A figcaption outside a figure, which upstream reports in any
            // parent (vnu.jar: "Element “figcaption” not allowed as child of
            // “div”"). The port reported one only in a phrasing parent (see
            // contentModelMessage), and took one in a <div> in a figure for
            // the figure's own caption.
            guard isFigcaption, Self.reportsFigcaption(in: stack, inHead: inHead) else {
                return nil
            }
            let parentName = stack.last.map { "html" == $0.name ? "body" : $0.name } ?? "body"
            return HTMLVocabulary.notAllowedAsChildMessage("figcaption", parent: parentName)
        }
        let content = figureContents[parent.offset] ?? FigureContent()
        // A child a figure never takes is reported wherever it is in the
        // figure, and doesn't count as content before a caption.
        if .html == namespace, Self.figureRejectedChildren.contains(child) {
            return HTMLVocabulary.notAllowedAsChildMessage(child, parent: "figure")
        }
        // (Nor does an element HTML doesn't have, which validateStartTag has
        // already reported as not allowed, or a <base>, which a figure never
        // takes either, but which HTMLGeneralAttributeChecker reports. One
        // that upstream's schema has as flow content but the port's
        // vocabulary lacks, a legacy one such as <spacer> or <multicol>, or
        // a <selectedcontent>, still counts before a caption, though; after
        // a caption that came last, validateStartTag's "not allowed" is
        // already the right message.)
        let isUnknown = .html == namespace && Self.isUnknownHTMLElement(child)
        if .html == namespace, "base" == child || (isUnknown && !Self.legacyAnythingElements.contains(child) && "selectedcontent" != child) {
            return nil
        }
        if isFigcaption {
            // A second caption is never allowed, wherever the first one is.
            if nil != content.caption {
                return HTMLVocabulary.notAllowedAsChildMessage("figcaption", parent: "figure")
            }
            figureContents[parent.offset, default: FigureContent()].caption = content.sawContent ? .last : .first
            return nil
        }
        switch content.caption {
        case .last?:
            // Nothing may follow a caption that came after other content.
            return isUnknown ? nil : HTMLVocabulary.notAllowedAsChildMessage(HTMLForeignContent.displayName(child, namespace: namespace), parent: "figure")
        case .first?:
            return nil
        case nil:
            // (Any other element, an obsolete, custom, SVG or MathML one
            // included, is flow content here: vnu.jar reports the <p> in
            // <figure><center>…</center><figcaption>…</figcaption><p>….)
            figureContents[parent.offset, default: FigureContent()].sawContent = true
            return nil
        }
    }

    /// Case 554591 (item 4): text directly in the <figure> that's the last
    /// of `stack` (see FigureContent): before any caption it's content, so a
    /// caption after it is the figure's last child; after such a caption,
    /// each piece of it that upstream's schema validator sees (see
    /// HTMLGeneralAttributeChecker.nonSpaceTextPieces) is reported. This used
    /// to be reported, once for the whole text, after any figcaption at all.
    private func appendFigureTextMessages(_ content: String, offset: Int, stack: ArraySlice<OpenElement>, figureContents: inout [Int: FigureContent], locations: SourceLocationMap, messages: inout [ValidationMessage]) {
        guard let figure = stack.last else { return }
        let state = figureContents[figure.offset] ?? FigureContent()
        // (Text after a caption that came first is fine, and once there's
        // content before the caption, more of it changes nothing; this
        // returns before the work below for the space between the figure's
        // children, in the usual figure.)
        let isAfterLastCaption = (.last == state.caption)
        guard isAfterLastCaption || (nil == state.caption && !state.sawContent) else { return }
        // (A NUL in it is dropped, as in any HTML element.)
        let pieces = HTMLGeneralAttributeChecker.nonSpaceTextPieces(in: content, droppingNUL: true)
        guard !pieces.isEmpty, Self.schemaChecksChildren(of: figure, childNamespace: .html) else { return }
        guard isAfterLastCaption else {
            figureContents[figure.offset, default: FigureContent()].sawContent = true
            return
        }
        for piece in pieces {
            appendError("Text not allowed in \u{201c}figure\u{201d} in this context.", offset: offset + piece.lowerBound, length: piece.count, locations: locations, messages: &messages)
        }
    }

    /// Case 554591 (item 12): upstream's schema rule for a colgroup's
    /// children (html5/tables.rnc): a colgroup takes either col children
    /// (with script-supporting elements) or a span attribute, never both,
    /// so an element in a colgroup that has a span attribute, whatever its
    /// value, is reported ("Element “col” not allowed as child of
    /// “colgroup” in this context."), and starts a subtree where the schema
    /// checks nothing more. HTMLGeneralAttributeChecker used to report every
    /// col in any colgroup (a rule fitted to upstream's one test of this,
    /// span-ignored-with-col-children-novalid.html, whose colgroup has a
    /// span), so the usual, valid <colgroup><col><col></colgroup> got an
    /// error for each col. Only a col or a template is looked at: they're
    /// the only elements upstream's parser puts in a colgroup (anything else
    /// ends it, as both of the port's stacks now have it; see
    /// HTMLImplicitClosures.beforeStartTag). Nothing is reported where
    /// upstream's schema checks nothing (see schemaChecksChildren): in a
    /// template, in a table that's itself been reported as misplaced (one
    /// in a <span>, say), or in an obsolete element that takes anything,
    /// such as <center>.
    private func colgroupContentModelMessage(for child: String, namespace: HTMLNamespace, stack: ArraySlice<OpenElement>, spannedColgroups: Set<Int>) -> String? {
        guard .html == namespace, "col" == child || "template" == child,
              let parent = stack.last, .html == parent.namespace, "colgroup" == parent.name,
              spannedColgroups.contains(parent.offset),
              Self.schemaChecksChildren(of: parent, childNamespace: namespace) else {
            return nil
        }
        return HTMLVocabulary.notAllowedAsChildMessage(child, parent: "colgroup")
    }

    /// Case 554591 (item 12, from its second review): whether upstream's schema
    /// checks the span attribute of a colgroup or col starting here (as a
    /// positive integer; see isPositiveInteger). It does where it takes the
    /// element itself: a colgroup directly in a table, in the table's column
    /// section (`isMisplaced` is one after it has closed; see
    /// TableColumnSection); a col in a colgroup without a span (one with a span
    /// rejects it); and a col directly in a table, which is in the colgroup
    /// upstream's parser implies for it, while that is in its place. And never
    /// where the schema checks nothing (see schemaChecksChildren), as in a
    /// template. The table checker used to report this, by its own trimming
    /// reader, wherever its own, different, state machine took the element:
    /// so span=" 2" was fine, a span the schema rejects was reported, and,
    /// since item 12's first round, a span the schema checks after rows in a
    /// template wasn't.
    private func spanIsCheckedBySchema(_ name: String, stack: ArraySlice<OpenElement>, isMisplaced: Bool, spannedColgroups: Set<Int>, tableColumnSections: [Int: TableColumnSection]) -> Bool {
        guard let parent = stack.last, .html == parent.namespace, Self.schemaChecksChildren(of: parent, childNamespace: .html) else {
            return false
        }
        if "colgroup" == name {
            return "table" == parent.name && !isMisplaced
        }
        switch parent.name {
        case "colgroup":
            return !spannedColgroups.contains(parent.offset)
        case "table":
            return !(tableColumnSections[parent.offset]?.isClosed ?? false)
        default:
            return false
        }
    }

    /// Case 554591 (item 12, from its second review): the schema's datatype
    /// for a span (common.data.integer.positive): one or more ASCII digits, not
    /// all zeros, and nothing else; vnu.jar reports a sign or white space as
    /// "Expected a digit but saw “ ” instead". (XMLValidator uses it too.)
    static func isPositiveInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { 0x30 <= $0 && 0x39 >= $0 } && value.utf8.contains { 0x30 != $0 }
    }

    /// Case 554591 (U11): whether a value is a non-negative integer as the
    /// schema's datatype for a cell's rowspan has it: ASCII digits, nothing
    /// else, not even white space around them (see isPositiveInteger,
    /// colspan's).
    static func isNonNegativeInteger(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { 0x30 <= $0 && 0x39 >= $0 }
    }

    /// Case 554591 (item 4): whether upstream's schema checks a child, in the
    /// given namespace, of `parent` at all: not in a template, in content it
    /// accepts unchecked, inside an element the figure rules (or, since item
    /// 12, the colgroup rule) have rejected, or inside one whose content it
    /// doesn't check otherwise (an unknown, misplaced or legacy element; see
    /// OpenElement.Flags.inUncheckedElement, which only those rules look at,
    /// so as not to report what vnu.jar never would, such as a figcaption
    /// inside a <center>). (No parent: the body the parser implies, where it
    /// checks everything.)
    private static func schemaChecksChildren(of parent: OpenElement?, childNamespace: HTMLNamespace) -> Bool {
        childFlags(of: parent, childNamespace: childNamespace).isDisjoint(with: [.inTemplateContents, .inAnyElementContent, .inRejectedSubtree, .inUncheckedElement])
    }

    /// Case 554591 (item 4): an HTML element that validateStartTag reports as
    /// not allowed wherever it is: one HTML doesn't have, neither in the
    /// vocabulary nor obsolete, and not a custom element; see its last
    /// branch. (A <menuitem> outside a <menu> gets a branch of its own, and
    /// isn't counted here, though one in a <menu> is reported by that last
    /// branch: neither caller can tell the difference, as their parent is a
    /// figure or a MathML token element. validate()'s MathML token-element
    /// rule asks this so as not to repeat that message.)
    private static func isUnknownHTMLElement(_ name: String) -> Bool {
        !name.contains("-") && !HTMLVocabulary.elements.contains(name) && !HTMLVocabulary.obsoleteElements.contains(name) && "menuitem" != name
    }

    /// Case 554591 (item 4): whether the figure rules report a figcaption
    /// whose parent, `stack.last`, isn't a figure. Not where another rule
    /// reports it already (in a phrasing parent, see contentModelMessage,
    /// which comes first; in a <dl>, or a <div> in one, see
    /// HTMLDefinitionListChecker; in a <picture>, see
    /// HTMLGeneralAttributeChecker), nor in a <noscript> in the head: there
    /// upstream's parser reports a "Bad start tag" and moves the figcaption
    /// to the body, where vnu.jar reports it as a child of that, all of
    /// which the port doesn't model yet (the "in head noscript" mode). (Nor
    /// where a table foster-parents it; see figureContentModelMessage. With
    /// no parent at all, it's in the body the parser implies.)
    private static func reportsFigcaption(in stack: ArraySlice<OpenElement>, inHead: Bool) -> Bool {
        guard let parent = stack.last else { return true }
        switch parent.name {
        case "dl", "picture":
            return false
        case "div":
            let grandparent = stack.dropLast().last
            return !(.html == grandparent?.namespace && "dl" == grandparent?.name)
        case "noscript":
            // (Whether it's in the head is the port's model of the parser's
            // state, not whether a <body> is open: the port opens no element
            // for a body it implies.)
            return !inHead
        default:
            return true
        }
    }

    /// Case 554591 (item 4): the HTML elements that upstream's schema never
    /// takes as a child of a <figure> (vnu.jar reports each as not allowed
    /// there, before or after a caption, and goes on as if it weren't there),
    /// though its parser puts them there: definition list parts, legend,
    /// summary, select's options, ruby's parts, media sources and tracks, and
    /// the head's title and style. (Also an <li>, which contentModelMessage
    /// reports first, and a <base>; see figureContentModelMessage.) Not
    /// private: XMLValidator's figure rules use it too.
    static let figureRejectedChildren: Set<String> = [
        "dd", "dt", "legend", "optgroup", "option", "rb", "rp", "rt", "rtc",
        "source", "style", "summary", "title", "track"
    ]

    /// Case 554591 (item 4): the obsolete elements that upstream's legacy
    /// schema (schema/.drivers/legacy.rnc) takes as flow or phrasing content
    /// with anything at all in them (common.inner.anything), so that its
    /// schema checks nothing inside one; its Assertions checker reports the
    /// element itself as obsolete. (vnu.jar has no error for an <li> or a
    /// figcaption in a <center>, or for a figure there.) validateStartTag
    /// marks the ones the port knows as obsolete with
    /// OpenElement.Flags.inUncheckedElement; the rest (isindex, listing,
    /// multicol, nextid, spacer, and menuitem) the port takes for unknown,
    /// which marks them too. figureContentModelMessage counts them all as
    /// flow content, as upstream does. (Not private: XMLValidator's figure
    /// rules check nothing inside one either.)
    static let legacyAnythingElements: Set<String> = [
        "acronym", "applet", "basefont", "bgsound", "big", "blink", "center", "dir",
        "font", "frame", "frameset", "isindex", "keygen", "listing", "marquee", "menuitem",
        "multicol", "nextid", "nobr", "noembed", "noframes", "param", "plaintext",
        "spacer", "strike", "tt", "xmp"
    ]

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
        append("Non-space character inside \u{201c}noscript\u{201d} inside \u{201c}head\u{201d}.", pattern: "<head><noscript>text</noscript></head>")
        append("The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.", pattern: "</frameset>\ntext")
    }

    /// Review item A2: this decoded only &quot;, &#34;, &apos;, &#39; and
    /// &amp;, so A2's namespace check, which compares the decoded value as
    /// upstream's does, reported xmlns values written with any other reference
    /// as bad (and showed them undecoded); IDs had the same problem
    /// (id="&#x61;" and id="a" weren't duplicates). See HTMLCharacterReferences.
    private func decodeEntities(_ value: String) -> String {
        HTMLCharacterReferences.decode(value)
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
        case "blink":
            return "The \u{201c}blink\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."
        case "dir":
            return "The \u{201c}dir\u{201d} element is obsolete. Use the \u{201c}ul\u{201d} element instead."
        case "param":
            return "The \u{201c}param\u{201d} element is obsolete. Use the \u{201c}data\u{201d} attribute of the \u{201c}object\u{201d} element to set the URL of the external resource."
        // (Review item A2: frame too, which, now that a frame is void in a
        // frameset, is checked there; it was "Use CSS instead.")
        case "frame", "frameset", "noframes":
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
            if case let .startTag(name, _, _, _, offset, length) = token, name == "html" {
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
        // Review item A2: only HTML elements take part in the table model;
        // an element named tr inside an SVG in a table cell used to start a
        // row. The tree builder's events are strictly nested, so this records
        // whether each open element is foreign, to skip its end event too.
        var foreignStack: [Bool] = []
        // Case 554591 (item 12, from its second and third reviews): the next of
        // the places where an implied colgroup, or an implied tr or tbody, ends
        // (see HTMLParsedDocument.impliedColgroupEnds and
        // impliedTablePartEnds).
        var nextImpliedColgroupEnd = 0
        var nextImpliedTablePartEnd = 0
        // Case 554591 (U11, review items A17 and A43): the next of the tokens
        // that closed an element implicitly (see
        // HTMLParsedDocument.implicitEndCauses).
        var nextImplicitEndCause = 0

        for (index, event) in document.events.enumerated() {
            while nextImpliedColgroupEnd < document.impliedColgroupEnds.count, document.impliedColgroupEnds[nextImpliedColgroupEnd] <= index {
                checker.impliedColgroupEnded()
                nextImpliedColgroupEnd += 1
            }
            while nextImpliedTablePartEnd < document.impliedTablePartEnds.count, document.impliedTablePartEnds[nextImpliedTablePartEnd].index <= index {
                let end = document.impliedTablePartEnds[nextImpliedTablePartEnd]
                checker.impliedTablePartEnded(end.name, at: position(named: end.name, range: end.range, locations: locations))
                nextImpliedTablePartEnd += 1
            }
            switch event {
            case let .startElement(element):
                foreignStack.append(.html != element.namespace)
                if .html == element.namespace {
                    checker.startElement(info(for: element, locations: locations))
                }
            case let .endElement(name, range, implicit):
                // (Case 554591, U11: where the element ended, which upstream's
                // table checker reports a row's width and a colgroup's
                // columns at: the end tag, or the token that closed the
                // element implicitly, if it was still open then; an implicit
                // end event's own range is the start tag.)
                var endRange = range
                if implicit {
                    while nextImplicitEndCause < document.implicitEndCauses.count, document.implicitEndCauses[nextImplicitEndCause].index < index {
                        nextImplicitEndCause += 1
                    }
                    if nextImplicitEndCause < document.implicitEndCauses.count, index == document.implicitEndCauses[nextImplicitEndCause].index {
                        endRange = document.implicitEndCauses[nextImplicitEndCause].range
                    }
                }
                if !(foreignStack.popLast() ?? false) {
                    // (Only the ends that can carry a message get a position,
                    // as working one out for every element in a large document
                    // isn't free.)
                    checker.endElement(name, at: Self.positionedEnds.contains(name) ? position(named: name, range: endRange, locations: locations) : nil)
                }
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

    /// Case 554591 (U11): the elements whose end the table checker reports at
    /// (see HTMLTableModelChecker.endElement): a row's, or the row group's,
    /// table's or template's that ends the row the parser implied, for the
    /// row's messages; and a colgroup's, for its columns.
    private static let positionedEnds: Set<String> = ["tr", "tbody", "thead", "tfoot", "colgroup", "table", "template"]

    /// Case 554591 (U11): a place in the source for the table checker's
    /// messages, as an element named for what ends there.
    private func position(named name: String, range: HTMLSourceRange, locations: SourceLocationMap) -> HTMLTableElementInfo {
        HTMLTableElementInfo(
            name: name,
            attributes: [:],
            location: locations.location(offset: range.offset, length: range.length),
            extract: locations.extract(offset: range.offset, length: range.length)
        )
    }

    private func info(for element: HTMLStartElement, locations: SourceLocationMap) -> HTMLTableElementInfo {
        // Case 554591 (item 12): each attribute's value as upstream's parser
        // hands it to its TableChecker: the first of duplicate attributes
        // (its tokenizer drops the rest; this kept the last), with character
        // references decoded (span=&#50; is the number 2, where this
        // reported "Bad value “&#50;”"), &#12; as a space (see
        // decodeAttributeValue). It showed in the colgroup span that item
        // 12's warning repeats; colspan, rowspan, headers, id and role are
        // read the same way. (Decoded, a value can hold characters that the
        // checks below once never saw, such as a no-break space from
        // &#160;, which is why headers and role are now read as upstream
        // reads them; see startCell, and the table's role in startElement.)
        var attributes: [String: String] = [:]
        for attribute in element.attributes where nil == attributes[attribute.name] {
            attributes[attribute.name] = HTMLCharacterReferences.decodeAttributeValue(attribute.value ?? "")
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
        /// Case 554591 (U11, review item A17): the column count rows are held
        /// to (upstream's Table.columnCount): the columns the column markup
        /// establishes, from 0 at the first colgroup or col (see
        /// noteColumnMarkup), or else the first row's width, set at that
        /// row's end (see finishCurrentRow); -1 until one of those. It was
        /// the column markup's count alone; the rows were kept until the
        /// table's end, and the first of them with any width at all stood
        /// for the first row.
        var columnCount = -1
        /// Case 554591 (U11, review item A43): how many columns the table has
        /// so far (upstream's realColumnCount): the column markup's, then as
        /// many as the widest row so far has needed. A cell that reaches past
        /// it establishes the columns past it (see noteCellColumns).
        var realColumnCount = 0
        /// Case 554591 (U11, review item A43 and the notes' item 29): the runs
        /// of columns an element established in which no cell has begun yet,
        /// in upstream's order (its ColumnRange list), linked from
        /// firstColumnRange through ColumnRange.next, with the last one; and,
        /// in the open row, the range its cells have reached and the one
        /// before that (upstream's currentColRange and previousColRange).
        /// Each is reported at the table's end, naming the element that
        /// established it, where that element is. This kept the columns any
        /// cell covered and the ones a cell began in, and reported the
        /// difference as established by a td, at the table: it never named a
        /// th, nor a col or colgroup, whose columns it didn't report at all.
        var columnRanges: [ColumnRange] = []
        var firstColumnRange: Int?
        var lastColumnRange: Int?
        var currentColumnRange: Int?
        var previousColumnRange: Int?
        var thIDs: Set<String> = []
        var pendingHeaderReferences: [HeaderReference] = []
        var rowGroup: RowGroupState?
        var row: ActiveRow?
        /// Case 554591 (item 12): whether the table has column markup (a
        /// colgroup or a col) that came before any row or row group, so that
        /// rows are held to the column count it sets (upstream's
        /// Table.hardWidth), even when that adds up to no columns at all, as
        /// a lone <colgroup span=0> does. This used to be whether the count
        /// was more than zero.
        var hasColumnMarkup = false
        /// Case 554591 (item 12): the open colgroup's span, held, as
        /// upstream's Table holds it (pendingColGroupSpan), until the
        /// colgroup ends, when its absolute value is added to the column
        /// count, unless a col in the colgroup has set it to zero first (see
        /// processCol and upstreamSpan); nil while no colgroup is open. The
        /// span used to be counted as the colgroup started, and the cols in
        /// a colgroup only when it had no span. So, in an HTML document, a
        /// colgroup with both counted both (span="3" and one col made four
        /// columns), and, in an XHTML one, only the span; and an empty
        /// colgroup without a span counted nothing, where upstream counts one
        /// column, so a valid table with <colgroup span=2></colgroup>
        /// <colgroup></colgroup> and rows three cells wide got "A table row
        /// was 3 columns wide and exceeded the column count established using
        /// column markup (2)."
        var pendingColgroupSpan: Int?
        /// Case 554591 (item 12, from its review): whether a row group, or a
        /// row or cell (which starts one), has started in the table, even if
        /// it has ended since. upstream's Table takes column markup only
        /// before that (IN_TABLE_AT_START or IN_TABLE_COLS_SEEN; afterwards
        /// it stays in IN_TABLE_AT_POTENTIAL_ROW_GROUP_START at best), and
        /// ignores a colgroup or col anywhere else (see isSuppressedStart).
        var sawRowGroup = false
        /// Case 554591 (item 12, from its reviews): the table elements (see
        /// tableElementsTableRoutes) now open in the table that upstream's
        /// Table ignores, and the ones inside them (its suppressedStarts,
        /// through needSuppressStart and needSuppressEnd; see
        /// isSuppressedStart): their ends finish nothing. Other elements
        /// don't count, as Table never sees them; counting a <template> in an
        /// ignored colgroup, whose end this never takes back, left everything
        /// after it ignored, and the table's later rows unchecked.
        var suppressedDepth = 0
        /// Case 554591 (item 12, from its second review): in an HTML document,
        /// whether the colgroup the parser implies for a col directly in the
        /// table is open, and whether upstream's Table ignores it, as it
        /// ignores a col after the rows (see startImpliedColgroup). The tree
        /// has no element for it (as it has none for an implied tbody or tr),
        /// so it starts at a col directly in the table, and ends where the
        /// tree builder found that upstream's parser ends it (see
        /// HTMLParsedDocument.impliedColgroupEnds and impliedColgroupEnded),
        /// or with the table. While it's open, it holds a span as an explicit
        /// colgroup does (pendingColgroupSpan; it has no span attribute), or,
        /// if Table ignores it, everything in it is ignored (suppressedDepth),
        /// so that the rows in a <template> in it are ignored, as Table
        /// ignores them. They set sawRowGroup, so that a col after the
        /// template was dropped, and every real row got a row-width error.
        var impliedColgroupIsOpen = false
        var impliedColgroupIsSuppressed = false
    }

    private struct RowGroupState {
        var name: String?
        /// Case 554591 (U11, review item A17): the row group's current row,
        /// counted from 0 within it (upstream's RowGroup.currentRow); -1
        /// before its first row.
        var currentRow = -1
        /// Case 554591 (U11, review item A17): the cells from the rows so far
        /// that span into a later row (upstream's cellsIfEffect), each
        /// dropped at the end of the last row it spans (see
        /// finishCurrentRow); the ones left when the group ends span past it
        /// (see finishCurrentRowGroup). This kept every cell with a rowspan,
        /// with the row after its last as a number counted through the whole
        /// table, and compared that with the number of the group's last row,
        /// one short: so a rowspan that ended on the group's last row, as in
        /// <tr><th rowspan="2">…</th><td>…</td></tr><tr><td>…</td></tr>, the
        /// usual way to use one, was "Table cell spans past the end of its row
        /// group".
        var cellsInEffect: [PlacedCell] = []
        /// Case 554591 (item 12, from its third review): for a row group the
        /// table checker starts for a row (see startRow), whether it stands
        /// for the tbody an HTML parser implies, an element in upstream's tree,
        /// for a row or cell directly in the table. Rows in a template's
        /// content have none; upstream's Table puts them in an implicit row
        /// group, which a row group starting later ends, where one starting in
        /// an implied tbody is inside it and ignored (see isSuppressedStart).
        var isImpliedTbody = false
    }

    /// Case 554591 (U11, review item A17): the open row, as upstream's
    /// RowGroup keeps it while one is: the column its next cell goes in (the
    /// insertion point); the cells still in effect from earlier rows, by
    /// column, and how many of them the insertion point has passed; and
    /// whether a cell has begun on it. It kept the set of columns in use and
    /// the rightmost one, so a cell spanning down past a gap made a row as
    /// wide as that cell's right edge, where upstream counts a row's width
    /// only to its insertion point, past the spanning cells that start there.
    private struct ActiveRow {
        var insertionPoint = 0
        var cellsOnCurrentRow: [PlacedCell]
        var nextOldCell = 0
        var hadCells = false
    }

    /// Case 554591 (U11, review item A17): a cell once placed, as upstream's
    /// Cell keeps it: its columns, from left up to but not including right;
    /// the first row of its group that it doesn't span to, or
    /// rowspanZeroBottom for one that spans to the group's end; and the cell,
    /// where its messages go.
    private struct PlacedCell {
        var left: Int
        var right: Int
        var bottom: Int
        var element: HTMLTableElementInfo
    }

    /// Case 554591 (U11, review item A43): a run of columns that one element
    /// established and in which no cell has begun yet (upstream's
    /// ColumnRange): the element's name and where it is (a colgroup's where
    /// it ended, as upstream has it), its columns from left up to but not
    /// including right, and the next range in the table's list.
    private struct ColumnRange {
        var element: String
        var position: HTMLTableElementInfo
        var left: Int
        var right: Int
        var next: Int?
    }

    /// Case 554591 (U11, review item A17): upstream's Cell.MAX_ROWSPAN, the
    /// most a rowspan counts (a bigger one is an error, and counts this), and
    /// also, as a cell's bottom, the mark of a cell that spans to the end of
    /// its group (rowspan="0"). So a rowspan of 65534 or more, and even one
    /// whose bottom row lands on 65534, spans to the group's end upstream,
    /// and is never reported as spanning past it.
    private static let rowspanZeroBottom = 65534

    private struct HeaderReference {
        var cellName: String
        var id: String
        var cell: HTMLTableElementInfo
    }

    /// Case 554591 (item 12, from its third review): what upstream's parser
    /// does with a table element directly in a <template>, which depends on
    /// the template's content mode: its first start tag that isn't head
    /// content sets it (HTMLImplicitClosures.templateContentMode, with the
    /// three table modes told apart). Upstream's Table sees template content
    /// as any other, so this decides what it sees. The table checker took a
    /// template's table parts as written: a cell there was always outside a
    /// row (round 3 of item 12; before that, always in one), and a part the
    /// parser drops was counted.
    private enum TemplateTableMode {
        /// No content yet, or only head content.
        case undecided
        /// "In row": the content began with a cell. A cell is a sibling of the
        /// others, with no row (see isSuppressedStart); a row, row group,
        /// colgroup or col has no row to close and is dropped.
        case inRow
        /// "In table body": the content began with a row. A cell outside a
        /// row is in one the parser implies; a colgroup or col is dropped.
        case inTableBody
        /// "In table": the content began with a caption, colgroup or row
        /// group. A row is in a tbody the parser implies, and a cell in a tr
        /// in one.
        case inTable
        /// "In column group": the content began with a col. Anything but a
        /// col is dropped ("Garbage in “colgroup” fragment").
        case inColumnGroup
        /// "In body": anything else began it, and every table part is
        /// dropped. (The tree builder drops these itself, since
        /// HTMLImplicitClosures.ignoredStartTag knows the mode, so the table
        /// model never sees them; nor an SVG or MathML element, which begins
        /// this mode too.)
        case inBody
    }

    /// Case 554591 (item 12, from its third review): a tbody or tr upstream's
    /// parser implies in a template's content, which the tree has no element
    /// for (see TemplateTableMode): whether upstream's Table takes it, or
    /// ignores it with everything in it (suppressedDepth).
    private enum ImpliedPart {
        case taken
        case suppressed
    }

    /// Case 554591 (item 12, from its third review): an open HTML template:
    /// where it is on elementStack, tableStack's count when it started (its
    /// implied parts belong to that table), its content mode, and its implied
    /// tbody and tr, while they're open.
    private struct OpenTemplate {
        var index: Int
        var tableDepth: Int
        var mode = TemplateTableMode.undecided
        var impliedRowGroup: ImpliedPart?
        var impliedRow: ImpliedPart?
    }

    private let mode: Mode
    private var elementStack: [String] = []
    // Case 554591 (item 12, from its third review): the open HTML templates
    // (see OpenTemplate), and where on elementStack the open tables and table
    // elements are, each innermost last, so that isSuppressedStart finds the
    // innermost of each without walking the stack. It walked it for every
    // table element, which an XHTML colgroup holding thousands of nested
    // <div>s made quadratic (11 s for a 0.7 MB document).
    private var openTemplates: [OpenTemplate] = []
    private var tableElementIndices: [Int] = []
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

        // (Case 554591, item 12, from its third review: the content mode of
        // the template this is directly in, if any, before this element, which
        // sets it if it isn't set yet; see TemplateTableMode.)
        let templateIndex = parentTemplateIndex
        var templateMode = TemplateTableMode.undecided
        if let templateIndex {
            templateMode = openTemplates[templateIndex].mode
            if .undecided == templateMode, let decided = Self.templateTableMode(afterStartTag: element.name) {
                openTemplates[templateIndex].mode = decided
            }
        }

        if element.name == "table" {
            // Case 554591 (item 12, from its review): the table's role, for the
            // rule that a td with a role mustn't be in a table with no role or
            // one of table, grid and treegrid (see startCell), as upstream's
            // Assertions compares it: the value exactly as the parser delivers
            // it, nil only when there's no role attribute at all. This took
            // the value's first token, lowercased, splitting at any Unicode
            // whitespace; and since item 12 decodes the value,
            // role="&#160;grid" (a no-break space and grid) became grid, and
            // its cells' roles errors. vnu.jar reports none there, nor for
            // role="grid foo", "GRID", " grid" or "", which this had taken for
            // grid or, the empty one, for no role.
            let role = element.attributes["role"]
            tableStack.append(TableState(element: element, role: role))
            tableElementIndices.append(elementStack.count)
            elementStack.append(element.name)
            return
        }

        if !tableStack.isEmpty {
            // (Case 554591, item 12, from its third review: a caption, colgroup
            // or col directly in an HTML table ends the tbody and tr the parser
            // implied for the rows or cells before it; see
            // impliedTablePartEnded.)
            if .html == mode, "caption" == element.name || "colgroup" == element.name || "col" == element.name, "table" == elementStack.last {
                endImpliedTableParts(closesRowGroup: true, at: element)
            }
            // (Case 554591, item 12, from its second review: see
            // TableState.impliedColgroupIsOpen.)
            if .html == mode, "col" == element.name, "table" == elementStack.last, !currentTable.impliedColgroupIsOpen {
                startImpliedColgroup(for: element)
            }
            // (Case 554591, item 12, from its third review: a table part
            // directly in a template, by the template's content mode.)
            var isDropped = false
            if let templateIndex, .undecided != templateMode, Self.tableElementsTableRoutes.contains(element.name) || "caption" == element.name,
               tableStack.count == openTemplates[templateIndex].tableDepth {
                isDropped = noteTemplateTablePart(element, template: templateIndex, mode: templateMode)
            }
            processTableElement(element, isDropped: isDropped)
        }
        if Self.tableElementsTableRoutes.contains(element.name) {
            tableElementIndices.append(elementStack.count)
        }
        if .html == mode, "template" == element.name {
            openTemplates.append(OpenTemplate(index: elementStack.count, tableDepth: tableStack.count))
        }
        elementStack.append(element.name)
    }

    /// Case 554591 (item 12, from its third review): the index in
    /// openTemplates of the HTML template what starts now is directly in, if
    /// it's directly in one.
    private var parentTemplateIndex: Int? {
        guard .html == mode, let index = openTemplates.indices.last, elementStack.count - 1 == openTemplates[index].index else {
            return nil
        }
        return index
    }

    /// Case 554591 (item 12, from its third review): the mode a template's
    /// first content start tag sets (see TemplateTableMode), or nil for head
    /// content, which leaves it unset.
    private static func templateTableMode(afterStartTag name: String) -> TemplateTableMode? {
        switch HTMLImplicitClosures.templateContentMode(afterStartTag: name, namespace: .html) {
        case nil:
            return nil
        case .inTable?:
            switch name {
            case "td", "th":
                return .inRow
            case "tr":
                return .inTableBody
            default:
                return .inTable
            }
        case .inColumnGroup?:
            return .inColumnGroup
        case .inBody?, .inTemplate?:
            return .inBody
        }
    }

    /// Case 554591 (item 12, from its third review): a table part (or a
    /// caption) directly in a template whose content mode is set, as
    /// upstream's parser handles it there (see TemplateTableMode): a cell in
    /// "in table body" or "in table" mode is in a tr the parser implies, in a
    /// tbody it implies in "in table" mode, as is a row in "in table" mode;
    /// a row ends the implied tr, and a row group, caption or column markup
    /// both (they are then inserted in the template itself). Returns whether
    /// the parser drops the element, which upstream's Table then never sees.
    private mutating func noteTemplateTablePart(_ element: HTMLTableElementInfo, template index: Int, mode templateMode: TemplateTableMode) -> Bool {
        switch (templateMode, element.name) {
        case (.inTableBody, "td"), (.inTableBody, "th"):
            if nil == openTemplates[index].impliedRow {
                startImpliedRow(template: index, at: element)
            }
            return false
        case (.inTable, "td"), (.inTable, "th"):
            if nil == openTemplates[index].impliedRowGroup {
                startImpliedRowGroup(template: index, at: element)
            }
            if nil == openTemplates[index].impliedRow {
                startImpliedRow(template: index, at: element)
            }
            return false
        case (.inTableBody, "tr"):
            endImpliedRow(template: index, at: element)
            return false
        case (.inTable, "tr"):
            endImpliedRow(template: index, at: element)
            if nil == openTemplates[index].impliedRowGroup {
                startImpliedRowGroup(template: index, at: element)
            }
            return false
        case (.inTableBody, "colgroup"), (.inTableBody, "col"):
            // (No row group is open to close, as in "in table body" mode a
            // template has none: dropped.)
            endImpliedRow(template: index, at: element)
            return true
        case (.inTableBody, _), (.inTable, _):
            endImpliedRow(template: index, at: element)
            endImpliedRowGroup(template: index, at: element)
            return false
        case (.inRow, "td"), (.inRow, "th"), (.inColumnGroup, "col"):
            return false
        case (.inRow, _), (.inColumnGroup, _), (.inBody, _):
            return Self.tableElementsTableRoutes.contains(element.name)
        case (.undecided, _):
            return false
        }
    }

    /// Case 554591 (item 12, from its third review): a tbody upstream's parser
    /// implies in a template's content (see noteTemplateTablePart), which its
    /// Table takes or ignores as any row group starting there. (The row or
    /// cell it's implied for sets sawRowGroup, as it's taken too.)
    private mutating func startImpliedRowGroup(template index: Int, at element: HTMLTableElementInfo) {
        let tbody = HTMLTableElementInfo(name: "tbody", attributes: [:], location: element.location, extract: element.extract)
        if 0 < currentTable.suppressedDepth || isSuppressedStart(tbody) {
            openTemplates[index].impliedRowGroup = .suppressed
            currentTable.suppressedDepth += 1
        } else {
            openTemplates[index].impliedRowGroup = .taken
            // (Case 554591, U11: the open row, if any, ends where the tag the
            // tbody is implied for is; see finishCurrentRow.)
            finishCurrentRow(at: element)
            finishCurrentRowGroup()
            currentTable.rowGroup = RowGroupState(name: "tbody", isImpliedTbody: true)
        }
    }

    /// Case 554591 (item 12, from its third review): a tr upstream's parser
    /// implies in a template's content (see noteTemplateTablePart), which its
    /// Table takes or ignores as any row starting there: it ignores one in a
    /// row, a cell or a colgroup. (The cell it's implied for sets sawRowGroup,
    /// as it's taken too.)
    private mutating func startImpliedRow(template index: Int, at element: HTMLTableElementInfo) {
        let tr = HTMLTableElementInfo(name: "tr", attributes: [:], location: element.location, extract: element.extract)
        if 0 < currentTable.suppressedDepth || isSuppressedStart(tr) {
            openTemplates[index].impliedRow = .suppressed
            currentTable.suppressedDepth += 1
        } else {
            openTemplates[index].impliedRow = .taken
            startRow(tr)
        }
    }

    /// Case 554591 (item 12, from its third review): a template's implied tr
    /// ending (see noteTemplateTablePart), at the template's next row, row
    /// group, caption or column markup, or at its end. (Case 554591, U11: the
    /// row's messages go where it ends, `position`; see finishCurrentRow.)
    private mutating func endImpliedRow(template index: Int, at position: HTMLTableElementInfo?) {
        guard let part = openTemplates[index].impliedRow else { return }
        openTemplates[index].impliedRow = nil
        guard !tableStack.isEmpty, tableStack.count == openTemplates[index].tableDepth else { return }
        switch part {
        case .suppressed:
            currentTable.suppressedDepth -= 1
        case .taken:
            finishCurrentRow(at: position)
        }
    }

    /// Case 554591 (item 12, from its third review): a template's implied
    /// tbody ending, as its implied tr does (see endImpliedRow), but not at a
    /// row, which is in it.
    private mutating func endImpliedRowGroup(template index: Int, at position: HTMLTableElementInfo?) {
        guard let part = openTemplates[index].impliedRowGroup else { return }
        openTemplates[index].impliedRowGroup = nil
        guard !tableStack.isEmpty, tableStack.count == openTemplates[index].tableDepth else { return }
        switch part {
        case .suppressed:
            currentTable.suppressedDepth -= 1
        case .taken:
            finishCurrentRow(at: position)
            finishCurrentRowGroup()
        }
    }

    /// Case 554591 (item 12, from its second review): the colgroup an HTML
    /// parser implies for a col directly in the table, starting (see
    /// TableState.impliedColgroupIsOpen), as upstream's Table takes a
    /// colgroup with no span attribute, or ignores it where it ignores one.
    private mutating func startImpliedColgroup(for col: HTMLTableElementInfo) {
        currentTable.impliedColgroupIsOpen = true
        if 0 < currentTable.suppressedDepth || isSuppressedStart(HTMLTableElementInfo(name: "colgroup", attributes: [:], location: col.location, extract: col.extract)) {
            currentTable.impliedColgroupIsSuppressed = true
            currentTable.suppressedDepth += 1
        } else {
            currentTable.pendingColgroupSpan = Self.upstreamSpan(nil)
            noteColumnMarkup()
        }
    }

    /// Case 554591 (item 12, from its third review): a </tr> or </tbody> that
    /// came while the current table was the parser's current node (see
    /// HTMLParsedDocument.impliedTablePartEnds): it closes the tr the parser
    /// implied for cells directly in the table, and </tbody> the tbody it
    /// implied for rows or cells there too (RowGroupState.isImpliedTbody),
    /// as upstream's parser closes them. The table checker kept them open, so
    /// a row or row group in a template after them was taken to be inside
    /// them, and ignored (see isSuppressedStart).
    /// (Case 554591, U11: `position` is the end tag's, where the row's
    /// messages go; see finishCurrentRow. From U11's review: it can come with
    /// a cell still open in the tree, one directly in the table or in a row
    /// group, whose implied tr upstream's parser closes, cell and all; the
    /// tree builder decides that, and that the table is the innermost one
    /// open, so this no longer requires the table to be the current node.)
    mutating func impliedTablePartEnded(_ name: String, at position: HTMLTableElementInfo) {
        guard .html == mode, !tableStack.isEmpty else { return }
        endImpliedTableParts(closesRowGroup: "tbody" == name, at: position)
    }

    /// Case 554591 (item 12, from its third review): the tr an HTML parser
    /// implied directly in the current table ending, which is the open row
    /// when the table is the innermost open element; and, if
    /// `closesRowGroup`, the tbody it implied too. (U11: at the tag that ends
    /// them, `position`.)
    private mutating func endImpliedTableParts(closesRowGroup: Bool, at position: HTMLTableElementInfo) {
        finishCurrentRow(at: position)
        if closesRowGroup, currentTable.rowGroup?.isImpliedTbody ?? false {
            finishCurrentRowGroup()
        }
    }

    /// Case 554591 (item 12, from its second review): the implied colgroup
    /// directly in the current table ending (see
    /// HTMLParsedDocument.impliedColgroupEnds), where its count is added, as
    /// an explicit colgroup's is at its end tag.
    mutating func impliedColgroupEnded() {
        guard !tableStack.isEmpty, currentTable.impliedColgroupIsOpen else { return }
        currentTable.impliedColgroupIsOpen = false
        if currentTable.impliedColgroupIsSuppressed {
            currentTable.impliedColgroupIsSuppressed = false
            currentTable.suppressedDepth -= 1
        } else {
            // (Case 554591, U11: with no place, as the col that opened it has
            // set its span aside, so it establishes no columns of its own; see
            // finishCurrentColgroup.)
            finishCurrentColgroup(at: nil)
        }
    }

    /// The end of an element, at `position` (Case 554591, U11): the end tag,
    /// or the token that closed the element if it was still open then. It's
    /// where upstream's table checker reports a row's messages and a
    /// colgroup's columns, so it's needed only at the end of a tr, row group,
    /// table, template or colgroup (see finishCurrentRow and
    /// finishCurrentColgroup); nil elsewhere.
    mutating func endElement(_ name: String, at position: HTMLTableElementInfo?) {
        // Review item A9: </tr>, </tbody>, </thead> and </tfoot> used to
        // finish the current row or row group even with no table open, and
        // currentTable traps on an empty stack. That crashed the XPC service
        // (and hung BBEdit, A10) on valid markup such as MDN's
        // <template><tr>...</tr></template> example, and on fragments like
        // <tr><td>x</td></tr> or <div><tbody></div>. Upstream's TableChecker
        // ignores every table end tag while no table is open (current ==
        // null), with no special case for <template>, so do the same.
        // (Case 554591, item 12, from its reviews: and the end of a table
        // element upstream's Table ignores finishes nothing; see
        // TableState.suppressedDepth.)
        if !tableStack.isEmpty, 0 < currentTable.suppressedDepth, Self.tableElementsTableRoutes.contains(name) {
            currentTable.suppressedDepth -= 1
        } else if name == "tr", !tableStack.isEmpty {
            finishCurrentRow(at: position)
        } else if Self.rowGroupElements.contains(name), !tableStack.isEmpty {
            finishCurrentRow(at: position)
            finishCurrentRowGroup()
        } else if name == "colgroup", !tableStack.isEmpty {
            finishCurrentColgroup(at: position)
        } else if name == "table", !tableStack.isEmpty {
            finishCurrentRow(at: position)
            finishCurrentRowGroup()
            finishCurrentTable()
        }

        if let index = elementStack.lastIndex(of: name) {
            elementStack.removeSubrange(index...)
        }
        // (Case 554591, item 12, from its third review: the templates and table
        // elements that have ended with it; a template's implied tbody and tr
        // end with it.)
        while let last = openTemplates.last, last.index >= elementStack.count {
            endImpliedRow(template: openTemplates.count - 1, at: position)
            endImpliedRowGroup(template: openTemplates.count - 1, at: position)
            openTemplates.removeLast()
        }
        while let last = tableElementIndices.last, last >= elementStack.count {
            tableElementIndices.removeLast()
        }
    }

    mutating func finish() -> [HTMLTableDiagnostic] {
        // (A table still open here, which only an XHTML document that the XML
        // parser stopped on can leave, ends with no place of its own; its
        // row's messages go at the row's table; see finishCurrentRow.)
        while !tableStack.isEmpty {
            finishCurrentRow(at: nil)
            finishCurrentRowGroup()
            finishCurrentTable()
        }
        return diagnostics
    }

    private mutating func processTableElement(_ element: HTMLTableElementInfo, isDropped: Bool) {
        // Case 554591: "Start tag \"input\"/\"select\" seen in \"table\"." used to
        // be reported here as well as by HTMLValidator, so it appeared twice.
        // That parse error is now reported only by HTMLValidator, for every
        // foster-parented start tag, as upstream does.
        // (The schema's error for a col directly in an XHTML table, where XHTML
        // has no colgroup a parser implies, is reported wherever the table's
        // state is.)
        if "col" == element.name, .xhtml == mode, "table" == elementStack.last {
            append("Element \u{201c}col\u{201d} not allowed as child of \u{201c}table\u{201d} in this context.", at: element)
        }
        // Case 554591 (item 12, from its reviews): a table element upstream's
        // Table ignores, with the table elements inside it (see
        // isSuppressedStart and TableState.suppressedDepth). Its colgroup's or
        // col's "must be less than or equal to 1000" check comes first
        // upstream (clampSpan), so that's still reported. (From the third
        // review: and one upstream's parser drops from a template's content,
        // which Table never sees, so its span isn't checked either; see
        // noteTemplateTablePart.)
        if Self.tableElementsTableRoutes.contains(element.name), 0 < currentTable.suppressedDepth || isDropped || isSuppressedStart(element) {
            currentTable.suppressedDepth += 1
            if !isDropped, "colgroup" == element.name || "col" == element.name {
                appendSpanLimitMessage(element.attributes["span"], element: element)
            }
            return
        }
        switch element.name {
        case "colgroup":
            // (Case 554591, item 12: this used to end the current row group
            // first. A colgroup that upstream's Table takes comes before any
            // row group, so there's none to end; and one that comes after
            // rows, in a template in a row group, say, it ignores, leaving
            // the row group open.)
            processColgroup(element)
        case "col":
            processCol(element)
        case "tbody", "thead", "tfoot":
            // (Case 554591, item 12: rows have started; see sawRowGroup.)
            currentTable.sawRowGroup = true
            // (Case 554591, U11: a row the parser implied ends at this tag;
            // see finishCurrentRow.)
            finishCurrentRow(at: element)
            finishCurrentRowGroup()
            currentTable.rowGroup = RowGroupState(name: element.name)
        case "tr":
            currentTable.sawRowGroup = true
            startRow(element)
        case "td", "th":
            currentTable.sawRowGroup = true
            startCell(element)
        default:
            break
        }
    }

    /// Case 554591 (item 12, from its reviews): whether upstream's Table
    /// ignores a table element starting here, as its startColGroup, startCol,
    /// startRowGroup, startRow and startCell do in any state they don't take
    /// (their default case: suppressedStarts). Table's state follows the
    /// table elements it has taken, so this goes by the innermost one open
    /// in the table, and by whether a colgroup (pendingColgroupSpan, an
    /// implied one included) or a row (an HTML parser's implied tr, too,
    /// which isn't in the tree) is open. In an HTML document, the parser
    /// closes an open cell, row or row group before starting another, so one
    /// is inside another only through a <template> between them; the tree
    /// builder here doesn't always close them in a template's content (a
    /// <td> after a <td> there is inside it), where upstream's are siblings,
    /// which Table takes, so without a template between them, the nesting
    /// isn't counted. It ignores:
    /// - a colgroup after a row group has started (see
    ///   TableState.sawRowGroup), or inside a colgroup (which an HTML
    ///   document can have through a <template>);
    /// - a col after a row group has started;
    /// - a row group anywhere but directly in the table: inside a colgroup,
    ///   a row group, a row or a cell;
    /// - a row inside a colgroup, a row or a cell;
    /// - a cell inside a colgroup or a cell, or outside a row: in an HTML
    ///   document, a cell directly in the table or in a row group is in the
    ///   row the parser implies, and one directly in a <template> is in one
    ///   only when the template's content began with a row, a caption, a
    ///   colgroup or a row group (see TemplateTableMode; the implied row is
    ///   then judged as a row is);
    /// - anything inside a col, which only XHTML can have.
    /// (An HTML document can have most of these only through a <template>,
    /// whose content Table sees as any other. And the tbody and tr the parser
    /// implies for rows and cells directly in the table aren't in the tree,
    /// but the table's open row group and row stand for them: a template after
    /// such rows is inside them, so a row group or row in it is inside a row
    /// group or a row, as in <table><td>1</td><template><tr>…. Since the third
    /// review.) Holding every row to a
    /// colgroup Table ignores, as this did once an empty colgroup counted one
    /// column, gave false row-width errors: one per row for an empty colgroup
    /// after a <thead>, and one for the valid
    /// <td><template><colgroup></colgroup></template></td>. And the rows or
    /// cells in a template in a colgroup, or a template's cell directly in
    /// the table, set sawRowGroup, so that the column markup after them was
    /// dropped, and every real row got a row-width error.
    private func isSuppressedStart(_ element: HTMLTableElementInfo) -> Bool {
        let innermostIndex = tableElementIndices.last
        let innermost = innermostIndex.map { elementStack[$0] } ?? "table"
        if "col" == innermost {
            return true
        }
        let isInColgroup = nil != currentTable.pendingColgroupSpan
        let isNested = .xhtml == mode || (innermostIndex.map { index in (openTemplates.last?.index ?? -1) > index } ?? false)
        let isInCell = isNested && ("td" == innermost || "th" == innermost)
        // (Whether, in an HTML document, a tbody or tr the parser implied is
        // open around what starts now, with no element of its own in the tree;
        // see above, and RowGroupState.isImpliedTbody.)
        let isInImpliedRowGroup = .html == mode && "table" == innermost && ((currentTable.rowGroup?.isImpliedTbody ?? false) || nil != currentTable.row)
        switch element.name {
        case "colgroup":
            return currentTable.sawRowGroup || isInColgroup
        case "col":
            return currentTable.sawRowGroup
        case "tbody", "thead", "tfoot":
            return isInColgroup || (isNested && ("table" != innermost || isInImpliedRowGroup))
        case "tr":
            return isInColgroup || isInCell || (isNested && ("tr" == innermost || (.html == mode && nil != currentTable.row)))
        case "td", "th":
            // (A cell in a template's implied tr that Table took is taken by the
            // open row below; see noteTemplateTablePart.)
            if isInColgroup || isInCell {
                return true
            }
            if "tr" == innermost || nil != currentTable.row {
                return false
            }
            return .xhtml == mode || !Self.rowImplyingParents.contains(elementStack.last ?? "")
        default:
            return false
        }
    }

    /// Case 554591 (item 12, from its second review): the elements that an
    /// HTML parser implies a tr in for a cell directly in them (see
    /// isSuppressedStart).
    private static let rowImplyingParents: Set<String> = ["table", "tbody", "thead", "tfoot"]

    /// Case 554591 (item 12): the table elements upstream's TableChecker hands
    /// its Table (see TableState.suppressedDepth).
    private static let tableElementsTableRoutes: Set<String> = ["colgroup", "col", "tbody", "thead", "tfoot", "tr", "td", "th"]

    private mutating func processColgroup(_ element: HTMLTableElementInfo) {
        // Case 554591 (item 12): the colgroup's span is held until the
        // colgroup ends (see TableState.pendingColgroupSpan); only what the
        // colgroup counts is now upstream's. (A bad span is reported where the
        // schema checks it, by HTMLValidator and XMLValidator.)
        appendSpanLimitMessage(element.attributes["span"], element: element)
        noteColumnMarkup()
        currentTable.pendingColgroupSpan = Self.upstreamSpan(element.attributes["span"])
    }

    private mutating func processCol(_ element: HTMLTableElementInfo) {
        // Case 554591 (item 12): a col in a colgroup makes upstream's Table
        // set the colgroup's held span aside (the schema reports the col,
        // too, when the colgroup has a span attribute; see
        // HTMLValidator.colgroupContentModelMessage), with this warning at
        // the first such col if the span was a positive number. The cols
        // are then what the colgroup counts, in an XHTML document as well,
        // where they used to be left out when the colgroup had a span.
        // (Case 554591, U11: the span's limit is checked first, as upstream's
        // TableChecker reads the span, with clampSpan, before its Table
        // takes the col and gives the warning below.)
        appendSpanLimitMessage(element.attributes["span"], element: element)
        if let pendingSpan = currentTable.pendingColgroupSpan {
            if pendingSpan > 0 {
                append("A col element causes a span attribute with value \(pendingSpan) to be ignored on the parent colgroup.", at: element, warning: true)
            }
            currentTable.pendingColgroupSpan = 0
        }
        // (Case 554591, item 12: the col counts as many columns as upstream
        // reads its span as (see upstreamSpan): none for span="0", one for
        // span="2 " or span="99999999999", which this counted, by its own
        // reading, as one, two and 1000 columns.)
        // (Case 554591, U11, review item A43 and the notes' item 29: they are
        // columns the col establishes, as upstream's Table.startCol records
        // them, so the ones no cell begins in are reported at the table's end,
        // at the col. Even none: a span="0" col's empty run is reported
        // upstream as "Table columns in range 1…0", say, which no cell can
        // begin in.)
        // (From U11's review: wherever the col is, as upstream's Table takes
        // any col its TableChecker hands it in a state that takes one, which
        // isSuppressedStart has already decided. In an XHTML document this
        // counted a col only in a colgroup or directly in the table, so one in
        // a <div>, a caption or a template before the rows added no columns,
        // no span limit message, and no range, and a table it completed got
        // a false row-width error.)
        noteColumnMarkup()
        let left = currentTable.columnCount
        let right = left + abs(Self.upstreamSpan(element.attributes["span"]))
        appendColumnRange("col", at: element, left: left, right: right)
        currentTable.columnCount = right
        currentTable.realColumnCount = right
    }

    /// Case 554591 (U11, review item A17): column markup that upstream's Table
    /// takes, its first making the table's width hard (see
    /// TableState.hasColumnMarkup), with the column count starting from 0
    /// rather than from the first row's width (see TableState.columnCount),
    /// as upstream's startColGroup and startCol do in IN_TABLE_AT_START.
    private mutating func noteColumnMarkup() {
        if !currentTable.hasColumnMarkup {
            currentTable.hasColumnMarkup = true
            currentTable.columnCount = 0
        }
    }

    /// Case 554591 (item 12): the end of the open colgroup, if there is one,
    /// where its held span counts (see TableState.pendingColgroupSpan): the
    /// number; one column for a colgroup with no span or a bad one; and
    /// none for span="0", or once a col in it has set the span aside. (From
    /// the second review: an implied colgroup's, too; see
    /// impliedColgroupEnded.) (Case 554591, U11, review item A43 and the
    /// notes' item 29: the columns it counts are ones it establishes, as
    /// upstream's Table.endColGroup records them, at `position`, where it
    /// ends, as upstream has it; the table's own place if there's none.)
    private mutating func finishCurrentColgroup(at position: HTMLTableElementInfo?) {
        guard let pendingSpan = currentTable.pendingColgroupSpan else { return }
        if 0 != pendingSpan {
            let left = currentTable.columnCount
            let right = left + abs(pendingSpan)
            appendColumnRange("colgroup", at: position ?? currentTable.element, left: left, right: right)
            currentTable.columnCount = right
        }
        currentTable.realColumnCount = currentTable.columnCount
        currentTable.pendingColgroupSpan = nil
    }

    /// Case 554591 (item 12): a colgroup's or col's span as upstream's
    /// TableChecker reads it (clampSpan, with
    /// AttributeUtil.parseNonNegativeInteger): -1 when there's none, or when
    /// it isn't a number a Java int can hold (nothing but ASCII digits,
    /// perhaps after a minus sign, once leading spaces, tabs, CRs and LFs,
    /// and only those, are skipped), or when it's negative; otherwise the
    /// number, but no more than 1000. Its absolute value is what the
    /// colgroup or col counts (see finishCurrentColgroup and processCol), so
    /// a missing or bad span is one column, and span="0" none. (The table
    /// checker used to count a span by its own reading, as one column for
    /// span="0", and taking "2 " and an out-of-range number such as
    /// 99999999999 for numbers.)
    private static func upstreamSpan(_ value: String?) -> Int {
        guard let value, let number = upstreamNonNegativeInteger(value) else { return -1 }
        return min(number, 1000)
    }

    /// Case 554591 (item 12): the number AttributeUtil.parseNonNegativeInteger
    /// reads in a span, before clampSpan's limit of 1000 (see upstreamSpan
    /// and appendSpanLimitMessage); nil where it gives -1.
    private static func upstreamNonNegativeInteger(_ value: String) -> Int? {
        var scalars = Substring(value).unicodeScalars
        while let first = scalars.first, " " == first || "\t" == first || "\n" == first || "\r" == first {
            scalars = scalars.dropFirst()
        }
        let isNegative = "-" == scalars.first
        if isNegative {
            scalars = scalars.dropFirst()
        }
        guard !scalars.isEmpty else { return nil }
        var number = 0
        for scalar in scalars {
            guard ("0"..."9").contains(scalar) else { return nil }
            number = number * 10 + Int(scalar.value - 48)
            // (Past Integer.MAX_VALUE, Java's Integer.parseInt fails, and
            // upstream takes that as -1, as it does any other bad value.)
            if number > Int(Int32.max) {
                return nil
            }
        }
        // ("-0" is zero; any other negative number is -1.)
        if isNegative {
            return 0 == number ? 0 : nil
        }
        return number
    }

    private mutating func startRow(_ element: HTMLTableElementInfo) {
        if currentTable.row != nil {
            // (Case 554591, U11: the row the parser implied ends at the tag
            // that starts the next; see finishCurrentRow.)
            finishCurrentRow(at: element)
        }
        // (Case 554591, U11: in an HTML document, a row or cell directly in
        // the table after a template's rows is in a tbody the parser implies,
        // which upstream's Table takes as a row group starting, ending the
        // implicit one the template's rows were in. This went on numbering
        // the rows in that one.)
        if .html == mode, "table" == elementStack.last, let group = currentTable.rowGroup, nil == group.name, !group.isImpliedTbody {
            finishCurrentRowGroup()
        }
        if currentTable.rowGroup == nil {
            // (Case 554591, item 12, from its third review: see isImpliedTbody.)
            currentTable.rowGroup = RowGroupState(name: nil, isImpliedTbody: .html == mode && "table" == elementStack.last)
        }

        // Case 554591 (U11, review items A17 and A43): the row starts as it
        // does in upstream's Table.startRow and RowGroup.startRow: the next
        // row of its group, whose cells are looked for in the column ranges
        // from the first on (see noteCellColumns), and placed among the cells
        // still in effect from earlier rows, taken in column order (see
        // findInsertionPoint).
        currentTable.currentColumnRange = currentTable.firstColumnRange
        currentTable.previousColumnRange = nil
        currentTable.rowGroup?.currentRow += 1
        let cellsOnCurrentRow = (currentTable.rowGroup?.cellsInEffect ?? []).sorted { $0.left < $1.left }
        currentTable.row = ActiveRow(cellsOnCurrentRow: cellsOnCurrentRow)
    }

    private mutating func startCell(_ element: HTMLTableElementInfo) {
        if currentTable.row == nil {
            startRow(element)
        }

        if element.name == "th", let id = element.attributes["id"], !id.isEmpty {
            currentTable.thIDs.insert(id)
        }
        if let headers = element.attributes["headers"] {
            // (Case 554591, item 12, from its review: split only at spaces,
            // tabs, LFs and CRs, as upstream's AttributeUtil.split does.
            // Character.isWhitespace also splits at a no-break space, which,
            // decoded from &#160; since item 12, made headers="a&#160;b"
            // two IDs, neither of them the th's. By scalars, since a CRLF is
            // one Character; and split leaves out the empty pieces.)
            for id in headers.unicodeScalars.split(whereSeparator: { " " == $0 || "\t" == $0 || "\n" == $0 || "\r" == $0 }).map({ String(Substring($0)) }) {
                currentTable.pendingHeaderReferences.append(HeaderReference(cellName: element.name, id: id, cell: element))
            }
        }
        if element.name == "td",
           element.attributes["role"] != nil,
           currentTable.role == nil || Self.tableCellRoleBlockingTableRoles.contains(currentTable.role ?? "") {
            append("The \u{201c}role\u{201d} attribute must not be used on a \u{201c}td\u{201d} element which has a \u{201c}table\u{201d} ancestor with no \u{201c}role\u{201d} attribute, or with a \u{201c}role\u{201d} attribute whose value is \u{201c}table\u{201d}, \u{201c}grid\u{201d}, or \u{201c}treegrid\u{201d}.", at: element)
        }

        // Case 554591 (U11, review item A17): the cell's spans as upstream's
        // Table reads them (Math.abs of AttributeUtil's parsePositiveInteger
        // for colspan, and of parseNonNegativeInteger for rowspan; see
        // upstreamCellSpan), with Cell's limits, the rowspan's checked first.
        // The checker's own reading took a span with a trailing space or a
        // no-break space, or one too big for a Java int (99999999999), for a
        // number, which upstream reads as 1 (with no limit message for the
        // big one); and a rowspan over the limit spanned 65534 rows, where
        // upstream's spans to the end of its group (see rowspanZeroBottom).
        // (Whether a span is a bad value is the schema's to say, with its own
        // datatypes, where it checks the cell; HTMLValidator and XMLValidator
        // say it now. This said it, by its own reading, wherever it took the
        // cell.)
        var rowspan = Self.upstreamCellSpan(element.attributes["rowspan"], isPositive: false)
        var colspan = Self.upstreamCellSpan(element.attributes["colspan"], isPositive: true)
        if rowspan > Self.rowspanZeroBottom {
            append("The value of the \u{201c}rowspan\u{201d} attribute must be less than or equal to 65534.", at: element)
            rowspan = Self.rowspanZeroBottom
        }
        if colspan > 1000 {
            append("The value of the \u{201c}colspan\u{201d} attribute must be less than or equal to 1000.", at: element)
            colspan = 1000
        }

        // Case 554591 (U11, review items A17 and A43): the cell is placed as
        // upstream's RowGroup.cell places it: at the insertion point, past the
        // cells from earlier rows that start at or before it; and its bottom
        // is the row after its last, in its group, unless it spans to the
        // group's end. It's still in effect after this row if it spans
        // further. It overlaps any later cell from an earlier row it reaches,
        // which upstream reports at both: the earlier one is "overlapped by
        // later table cell", this one "overlaps an earlier table cell". This
        // reported only the first, at this cell. (The column ranges are
        // updated first, as upstream's Table.cell is; see noteCellColumns.)
        guard var row = currentTable.row else { return }
        let top = currentTable.rowGroup?.currentRow ?? 0
        row.hadCells = true
        Self.findInsertionPoint(&row)
        let bottom = (0 == rowspan || Self.rowspanZeroBottom == rowspan) ? Self.rowspanZeroBottom : top + rowspan
        let cell = PlacedCell(left: row.insertionPoint, right: row.insertionPoint + colspan, bottom: bottom, element: element)
        noteCellColumns(cell)
        if cell.bottom > top + 1 {
            currentTable.rowGroup?.cellsInEffect.append(cell)
        }
        row.insertionPoint = cell.right
        for earlier in row.cellsOnCurrentRow[row.nextOldCell...] where !(cell.right <= earlier.left || earlier.right <= cell.left) {
            append("Table cell is overlapped by later table cell.", at: earlier.element)
            append("Table cell overlaps an earlier table cell.", at: element)
        }
        currentTable.row = row
    }

    /// Case 554591 (U11, review item A17): upstream's RowGroup.findInsertionPoint:
    /// the insertion point moves past each cell from an earlier row, in column
    /// order, that starts at or before it, to that cell's right edge.
    private static func findInsertionPoint(_ row: inout ActiveRow) {
        while row.nextOldCell < row.cellsOnCurrentRow.count {
            let earlier = row.cellsOnCurrentRow[row.nextOldCell]
            if row.insertionPoint < earlier.left {
                break
            }
            row.insertionPoint = max(row.insertionPoint, earlier.right)
            row.nextOldCell += 1
        }
    }

    /// Case 554591 (U11, review item A17): a cell's colspan or rowspan as
    /// upstream's Table reads it: the absolute value of
    /// AttributeUtil.parsePositiveInteger (`isPositive`) or
    /// parseNonNegativeInteger, so 1 when there's none, or when it isn't a
    /// number a Java int can hold once leading spaces, tabs, LFs and CRs are
    /// skipped (see upstreamNonNegativeInteger), or when it's negative, or a
    /// colspan of 0; otherwise the number ("-0" is a rowspan of 0).
    private static func upstreamCellSpan(_ value: String?, isPositive: Bool) -> Int {
        guard let value, let number = upstreamNonNegativeInteger(value), !isPositive || 0 < number else { return 1 }
        return number
    }

    /// Case 554591 (U11, review item A43 and the notes' item 29): upstream's
    /// Table.cell, for a cell just placed: the columns it reaches past the
    /// table's columns so far are columns it establishes, all but the one it
    /// begins in if it begins right at the edge; otherwise the column it
    /// begins in is looked for in the column ranges, from the one the row
    /// has reached, and taken out of the range it's in (splitting it, if it's
    /// in the middle), as a cell has now begun in it.
    private mutating func noteCellColumns(_ cell: PlacedCell) {
        let left = cell.left
        let right = cell.right
        if right > currentTable.realColumnCount {
            if left == currentTable.realColumnCount {
                if left + 1 != right {
                    appendColumnRange(cell.element.name, at: cell.element, left: left + 1, right: right)
                }
                currentTable.realColumnCount = right
                return
            }
            appendColumnRange(cell.element.name, at: cell.element, left: currentTable.realColumnCount, right: right)
            currentTable.realColumnCount = right
        }
        while let current = currentTable.currentColumnRange {
            let range = currentTable.columnRanges[current]
            if left < range.left {
                return
            }
            if left >= range.right {
                currentTable.previousColumnRange = current
                currentTable.currentColumnRange = range.next
                continue
            }
            // (Upstream's ColumnRange.removeColumn, and what Table.cell does
            // with what it returns. A one-column range goes, the one before
            // it, if any, linking to the one after it; when it's the list's
            // last, the one before it becomes the last, even if there's none,
            // as upstream has it. Taking a column from the middle splits the
            // range, the new right half coming next, which the row then
            // reaches, with the range before the left half still taken for
            // the one before it, as upstream leaves it.)
            if range.left + 1 == range.right {
                if let previous = currentTable.previousColumnRange {
                    currentTable.columnRanges[previous].next = range.next
                }
                if current == currentTable.firstColumnRange {
                    currentTable.firstColumnRange = range.next
                }
                if current == currentTable.lastColumnRange {
                    currentTable.lastColumnRange = currentTable.previousColumnRange
                }
                currentTable.currentColumnRange = range.next
            } else if left == range.left {
                currentTable.columnRanges[current].left += 1
            } else if left + 1 == range.right {
                currentTable.columnRanges[current].right -= 1
            } else {
                let created = currentTable.columnRanges.count
                currentTable.columnRanges.append(ColumnRange(element: range.element, position: range.position, left: left + 1, right: range.right, next: range.next))
                currentTable.columnRanges[current].right = left
                currentTable.columnRanges[current].next = created
                if current == currentTable.lastColumnRange {
                    currentTable.lastColumnRange = created
                }
                currentTable.currentColumnRange = created
            }
            return
        }
    }

    /// Case 554591 (U11, review item A43 and the notes' item 29): upstream's
    /// Table.appendColumnRange: a range `element` established, where it is,
    /// goes at the end of the table's list.
    private mutating func appendColumnRange(_ element: String, at position: HTMLTableElementInfo, left: Int, right: Int) {
        let index = currentTable.columnRanges.count
        currentTable.columnRanges.append(ColumnRange(element: element, position: position, left: left, right: right, next: nil))
        if let last = currentTable.lastColumnRange {
            currentTable.columnRanges[last].next = index
        } else {
            currentTable.firstColumnRange = index
        }
        currentTable.lastColumnRange = index
    }

    /// The open row's end (Case 554591, U11, review item A17), as upstream's
    /// RowGroup.endRow handles it, at `position`, the row's end tag, or the
    /// tag that ended the row the parser implied (the row's table if there's
    /// none): "has no cells beginning on it" if no cell began on it; then its
    /// width, its insertion point once moved past the spanning cells that
    /// start there, is held to the column markup's count (an error) or the
    /// first row's (a warning), or, for the first row, sets that; and the
    /// cells that span no further than this row are no longer in effect.
    /// This kept the rows until the table's end and checked only the ones
    /// with cells (the notes' item 38), so an empty <tr></tr>, such as the
    /// stray <tr> left where a </tr> was meant, got no "A table row was 0
    /// columns wide…"; took the first row with any width for the first row;
    /// counted a row as wide as its rightmost spanning cell, even past a gap;
    /// and put the messages at the row's start tag, before the table's
    /// others, where upstream puts them at its end, as each row ends.
    private mutating func finishCurrentRow(at position: HTMLTableElementInfo?) {
        // Every caller checks for an open table first; this guard is a second
        // line of defense, because currentTable traps on an empty stack and a
        // trap in the checker is a crashed XPC service (A9).
        guard !tableStack.isEmpty, var row = currentTable.row else { return }
        let place = position ?? currentTable.element
        let group = currentTable.rowGroup
        let rowNumber = (group?.currentRow ?? 0) + 1
        if !row.hadCells {
            append(rowNoCellsMessage(rowNumber, group: group), at: place)
        }

        Self.findInsertionPoint(&row)
        let width = row.insertionPoint
        let columnCount = currentTable.columnCount
        if currentTable.hasColumnMarkup {
            // (Case 554591, item 12: column markup that adds up to no
            // columns, a lone <colgroup span=0>, still sets the count rows
            // are held to, as in upstream: "… exceeded the column count
            // established using column markup (0).")
            if width > columnCount {
                append("A table row was \(width) columns wide and exceeded the column count established using column markup (\(columnCount)).", at: place)
            } else if width < columnCount {
                append("A table row was \(width) columns wide, which is less than the column count established using column markup (\(columnCount)).", at: place)
            }
        } else if -1 == columnCount {
            currentTable.columnCount = width
        } else if width > columnCount {
            append("A table row was \(width) columns wide and exceeded the column count established by the first row (\(columnCount)).", at: place, warning: true)
        } else if width < columnCount {
            append("A table row was \(width) columns wide, which is less than the column count established by the first row (\(columnCount)).", at: place, warning: true)
        }

        currentTable.rowGroup?.cellsInEffect.removeAll { $0.bottom <= rowNumber }
        currentTable.row = nil
    }

    /// The open row group's end (Case 554591, U11, review item A17), as
    /// upstream's RowGroup.end handles it: a cell still in effect spans past
    /// the group's last row, and is reported, in upstream's order (by its
    /// bottom row, then its column), unless it spans to the group's end
    /// (rowspan="0"; see rowspanZeroBottom). Its row has ended, as every
    /// caller ends the open row first.
    private mutating func finishCurrentRowGroup() {
        // See finishCurrentRow.
        guard !tableStack.isEmpty, let group = currentTable.rowGroup else { return }
        for cell in group.cellsInEffect.sorted(by: { ($0.bottom, $0.left) < ($1.bottom, $1.left) }) where Self.rowspanZeroBottom != cell.bottom {
            append(spansPastMessage(group), at: cell.element)
        }
        currentTable.rowGroup = nil
    }

    private mutating func finishCurrentTable() {
        // Case 554591 (item 12): a colgroup still open counts now (see
        // finishCurrentColgroup). Its end always comes first in a document
        // the tree builder or the XML parser has finished, as it does in
        // upstream, whose Table counts it only there; this is in case it
        // doesn't, so that its span isn't lost.
        finishCurrentColgroup(at: nil)
        let table = tableStack.removeLast()

        for reference in table.pendingHeaderReferences where !table.thIDs.contains(reference.id) {
            append(
                "The \u{201c}headers\u{201d} attribute on the element \u{201c}\(reference.cellName)\u{201d} refers to the ID \u{201c}\(reference.id)\u{201d}, but there is no \u{201c}th\u{201d} element with that ID in the same table.",
                at: reference.cell
            )
        }

        // Case 554591 (U11, review item A43 and the notes' item 29): as
        // upstream's Table.end, last, each column range left, in its list's
        // order, at the element that established it (see
        // TableState.columnRanges).
        var next = table.firstColumnRange
        while let index = next {
            let range = table.columnRanges[index]
            if range.left + 1 == range.right {
                append("Table column \(range.right) established by element \u{201c}\(range.element)\u{201d} has no cells beginning in it.", at: range.position)
            } else {
                append("Table columns in range \(range.left + 1)\u{2026}\(range.right) established by element \u{201c}\(range.element)\u{201d} have no cells beginning in them.", at: range.position)
            }
            next = range.next
        }
    }

    /// "The value of the “span” attribute must be less than or equal to 1000."
    /// for a colgroup's or col's span over that, as upstream's TableChecker
    /// gives it (clampSpan), wherever the colgroup or col is, and by its own
    /// reading of the number: a value a Java int can't hold, such as
    /// 99999999999, gets no message, as in vnu.jar, nor does "1001 ", which it
    /// doesn't read as a number at all. Case 554591 (item 12): this was
    /// tableSpan, which also counted the span (what a span counts is now
    /// upstreamSpan's), went by the checker's own reading, which took both of
    /// those for numbers over 1000, and reported a bad span, which
    /// HTMLValidator and XMLValidator now do where the schema checks one.
    private mutating func appendSpanLimitMessage(_ value: String?, element: HTMLTableElementInfo) {
        guard let value, let number = Self.upstreamNonNegativeInteger(value), number > 1000 else { return }
        append("The value of the \u{201c}span\u{201d} attribute must be less than or equal to 1000.", at: element)
    }

    /// Case 554591 (U11): the element that established a row group, as
    /// upstream's messages name it, or nil for an implicit row group: in an
    /// HTML document, a row group the checker started for a row or cell
    /// directly in the table stands for the tbody the parser implies (see
    /// RowGroupState.isImpliedTbody), an element in upstream's tree, but one
    /// for the rows of a template is implicit there, as it is for the rows
    /// directly in an XHTML table. A row group with no name was always a
    /// tbody in an HTML document.
    private func rowGroupElement(_ group: RowGroupState?) -> String? {
        if let name = group?.name {
            return name
        }
        return .html == mode && (group?.isImpliedTbody ?? false) ? "tbody" : nil
    }

    /// Case 554591 (U11, review item A17): upstream's Cell.errIfNotRowspanZero
    /// message, which for an implicit row group is "… past the end of its
    /// implicit row group; …"; this said "… of its row group established by
    /// an implicit row group; …" in an XHTML document.
    private func spansPastMessage(_ group: RowGroupState?) -> String {
        if let element = rowGroupElement(group) {
            return "Table cell spans past the end of its row group established by a \u{201c}\(element)\u{201d} element; clipped to the end of the row group."
        }
        return "Table cell spans past the end of its implicit row group; clipped to the end of the row group."
    }

    private func rowNoCellsMessage(_ rowNumber: Int, group: RowGroupState?) -> String {
        if let element = rowGroupElement(group) {
            return "Row \(rowNumber) of a row group established by a \u{201c}\(element)\u{201d} element has no cells beginning on it."
        }
        return "Row \(rowNumber) of an implicit row group has no cells beginning on it."
    }

    private mutating func append(_ message: String, at element: HTMLTableElementInfo, warning: Bool = false) {
        diagnostics.append(HTMLTableDiagnostic(
            message: message,
            location: element.location,
            extract: element.extract,
            warning: warning
        ))
    }

    // Case 554591 (U11; the notes' P1 item 2): the innermost open table,
    // changed in place. With a getter and a setter, every change through
    // this, such as appending to one of the table's arrays, copied the
    // table, and then the array, as the copy shared it with tableStack's. A
    // table's rows were kept in one until U11, so a table took time in the
    // square of its rows (50,000 rows, 38 s), and so did its th IDs and
    // headers references in the square of their numbers; U11's cells in
    // effect and column ranges would have done the same. (_modify is what
    // Array's own subscript uses for this.)
    private var currentTable: TableState {
        get { tableStack[tableStack.index(before: tableStack.endIndex)] }
        _modify { yield &tableStack[tableStack.index(before: tableStack.endIndex)] }
    }

    private static let rowGroupElements: Set<String> = ["tbody", "thead", "tfoot"]
    private static let tableCellRoleBlockingTableRoles: Set<String> = ["table", "grid", "treegrid"]
}

enum HTMLVocabulary {
    // Review item A2: with upstream's parser's legacy void elements too
    // (keygen, basefont, bgsound and frame, which TreeBuilder inserts as void
    // elements). Since A2 keeps a self-closed non-void element open, as HTML
    // does, these would otherwise have stayed open after "<keygen/>".
    static let voidElements: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img",
        "input", "keygen", "link", "meta", "param", "source", "track", "wbr"
    ]

    static let obsoleteElements: Set<String> = [
        "acronym", "applet", "basefont", "bgsound", "big", "blink", "center", "dir",
        "font", "frame", "frameset", "keygen", "marquee", "nobr", "noembed",
        "noframes", "param", "plaintext", "rb", "rtc", "strike", "tt", "xmp"
    ]

    // Upstream's TRANSPARENT_ELEMENTS (MessageEmitterAdapter.java), which
    // had slot and the port's list didn't.
    static let transparentElements: Set<String> = [
        "a", "audio", "canvas", "del", "ins", "map", "object", "slot", "video"
    ]

    // Elements whose content model is phrasing content only. a, ins and del
    // used to be listed here, but their content model is transparent (see
    // transparentElements and contentModelMessage).
    static let phrasingOnlyContainers: Set<String> = [
        "abbr", "b", "bdi", "bdo", "button", "cite", "code", "data",
        "dfn", "em", "h1", "h2", "h3", "h4", "h5", "h6", "i",
        "kbd", "label", "mark", "p", "q", "s", "samp", "small", "span",
        "strong", "sub", "sup", "time", "u", "var"
    ]

    // Review item A4: upstream's MessageEmitterAdapter appends the
    // transparent-model Note to every "not allowed as child" error whose
    // parent is in its TRANSPARENT_ELEMENTS, because the parent's allowed
    // content comes from further up. Building those messages here keeps the
    // Note the same wherever the port reports one.
    static func notAllowedAsChildMessage(_ child: String, parent: String) -> String {
        var message = "Element \u{201c}\(child)\u{201d} not allowed as child of \u{201c}\(parent)\u{201d} in this context."
        if transparentElements.contains(parent) {
            message += " Note: The \u{201c}\(parent)\u{201d} element has a transparent content model; its allowed content is inherited from its parent element."
        }
        return message
    }

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

    /// Review item A2: the HTML element names upstream's Assertions checker
    /// knows (HTML_ELEMENTS in Assertions.java); any other name without a
    /// hyphen is "a completely-unknown element". Unlike `elements`, it has the
    /// obsolete elements, and a few the port's vocabulary lacks.
    static let assertionsElements: Set<String> = [
        "a", "abbr", "acronym", "address", "annotation-xml", "applet", "area",
        "article", "aside", "attachment", "audio", "b", "base", "basefont", "bdi",
        "bdo", "bgsound", "big", "blockquote", "body", "br", "button", "canvas",
        "caption", "center", "cite", "code", "col", "colgroup", "color-profile",
        "data", "datalist", "dd", "del", "details", "dfn", "dialog", "dir", "div",
        "dl", "dt", "em", "embed", "fieldset", "figcaption", "figure", "font",
        "font-face", "font-face-format", "font-face-name", "font-face-src",
        "font-face-uri", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4",
        "h5", "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe", "image",
        "img", "input", "ins", "kbd", "keygen", "label", "legend", "li", "link",
        "listing", "main", "map", "mark", "marquee", "menu", "meta", "meter",
        "missing-glyph", "model", "nav", "nobr", "noembed", "noframes", "noscript",
        "object", "ol", "optgroup", "option", "output", "p", "param", "picture",
        "plaintext", "pre", "progress", "q", "rb", "rp", "rt", "rtc", "ruby", "s",
        "samp", "script", "search", "section", "select", "selectedcontent", "slot",
        "small", "source", "span", "strike", "strong", "style", "sub", "summary",
        "sup", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
        "time", "title", "tr", "track", "tt", "u", "ul", "var", "video", "wbr", "xmp"
    ]
}
