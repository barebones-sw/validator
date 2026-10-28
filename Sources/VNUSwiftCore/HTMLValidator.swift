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
                validateStartTag(name: name, writtenName: writtenName, attributes: attributes, selfClosing: selfClosing, namespace: namespace, offset: offset, length: length, stack: stack, contentStack: stack[..<closure.keepCount], impliedEndTagErrors: closure.errors, locations: locations, metaCharsetCount: &metaCharsetCount, sawHTMLLang: &sawHTMLLang, messages: &messages)
                // Review item A2: after "End tag “p” implied, but there were
                // open elements." and the like, upstream lists the elements
                // above the one closed (see appendUnclosedElements).
                if closure.errors.contains(where: { $0.hasSuffix(", but there were open elements.") }) {
                    appendUnclosedElements(above: closure.keepCount, stack: &stack, locations: locations, messages: &messages)
                }
                stack.removeSubrange(closure.keepCount...)
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
                    let validateStartTagReportedIt = .html == namespace && !name.contains("-") && !HTMLVocabulary.elements.contains(name) && !HTMLVocabulary.obsoleteElements.contains(name) && "menuitem" != name
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
                guard let match = stack[scopeStart...].lastIndex(where: { .html == $0.namespace && $0.name == name }) else {
                    if name == "p" {
                        appendError("No \u{201c}p\u{201d} element in scope but a \u{201c}p\u{201d} end tag seen.", offset: offset, length: length, locations: locations, messages: &messages)
                        // Upstream inserts a <p> for it, which first ends any
                        // foreign content it's in.
                        popForeignContent(forInsertedElement: name, stack: &stack, offset: offset, length: length, locations: locations, messages: &messages)
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
        locations: SourceLocationMap,
        metaCharsetCount: inout Int,
        sawHTMLLang: inout Bool,
        messages: inout [ValidationMessage]
    ) {
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
        if nil != HTMLImplicitClosures.tableInsertionModeIndex(in: htmlStack.map(\.name)) {
            if "table" == name {
                appendError("Start tag for \u{201c}table\u{201d} seen but the previous \u{201c}table\u{201d} is still open.", offset: offset, length: length, locations: locations, messages: &messages)
            } else if !HTMLImplicitClosures.isTableModeStartTag(name) {
                // (Review item A2: upstream reports an <image> here under that
                // name, then again as the <img> it handles it as.)
                if writtenName != name {
                    appendError("Start tag \u{201c}\(writtenName)\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
                }
                appendError("Start tag \u{201c}\(name)\u{201d} seen in \u{201c}table\u{201d}.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        }

        if HTMLVocabulary.obsoleteElements.contains(name) {
            if let obsoleteMessage = obsoleteElementMessage(for: name) {
                appendError(obsoleteMessage, offset: offset, length: length, locations: locations, messages: &messages)
            } else if name == "keygen" {
                appendError("The \u{201c}keygen\u{201d} element is obsolete.", offset: offset, length: length, locations: locations, messages: &messages)
            } else {
                appendError("The \u{201c}\(name)\u{201d} element is obsolete. Use CSS instead.", offset: offset, length: length, locations: locations, messages: &messages)
            }
        } else if name == "menuitem", stack.last?.name != "menu" {
            appendError("The \u{201c}menuitem\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.", offset: offset, length: length, locations: locations, messages: &messages)
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
        if .html == contentStack.last?.namespace ?? .html, !(contentStack.last?.isInRejectedSubtree ?? false), let parentMessage = contentModelMessage(for: name, stack: contentStack) {
            appendError(parentMessage, offset: offset, length: length, locations: locations, messages: &messages)
        }

        // (Review item A2: a self-closed <svg/> or <math/> is fine.)
        if selfClosing && .html == namespace && !HTMLVocabulary.voidElements.contains(name) {
            appendError("Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.", offset: offset, length: length, locations: locations, messages: &messages)
        }
    }

    private func contentModelMessage(for child: String, stack: ArraySlice<OpenElement>) -> String? {
        if child == "li" {
            let parent = stack.last?.name
            if parent != "ol" && parent != "ul" && parent != "menu" {
                let parentName = parent == nil || parent == "html" ? "body" : parent!
                return HTMLVocabulary.notAllowedAsChildMessage("li", parent: parentName)
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

        for event in document.events {
            switch event {
            case let .startElement(element):
                foreignStack.append(.html != element.namespace)
                if .html == element.namespace {
                    checker.startElement(info(for: element, locations: locations))
                }
            case let .endElement(name, _, _):
                if !(foreignStack.popLast() ?? false) {
                    checker.endElement(name)
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
        // Review item A9: </tr>, </tbody>, </thead> and </tfoot> used to
        // finish the current row or row group even with no table open, and
        // currentTable traps on an empty stack. That crashed the XPC service
        // (and hung BBEdit, A10) on valid markup such as MDN's
        // <template><tr>...</tr></template> example, and on fragments like
        // <tr><td>x</td></tr> or <div><tbody></div>. Upstream's TableChecker
        // ignores every table end tag while no table is open (current ==
        // null), with no special case for <template>, so do the same.
        if name == "tr", !tableStack.isEmpty {
            finishCurrentRow()
        } else if Self.rowGroupElements.contains(name), !tableStack.isEmpty {
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
        // Case 554591: "Start tag \"input\"/\"select\" seen in \"table\"." used to
        // be reported here as well as by HTMLValidator, so it appeared twice.
        // That parse error is now reported only by HTMLValidator, for every
        // foster-parented start tag, as upstream does.
        switch element.name {
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
        // Every caller checks for an open table first; this guard is a second
        // line of defense, because currentTable traps on an empty stack and a
        // trap in the checker is a crashed XPC service (A9).
        guard !tableStack.isEmpty, var row = currentTable.row else { return }
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
        // See finishCurrentRow.
        guard !tableStack.isEmpty, let group = currentTable.rowGroup else { return }
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
