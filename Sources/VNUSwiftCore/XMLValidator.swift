import Foundation
import VNUCore

public final class XMLValidator: NSObject, XMLParserDelegate, @unchecked Sendable {
    private struct PendingInputListReference {
        var value: String
        var location: SourceLocation
    }

    private struct DefinitionListContext {
        var termNames: Set<String> = []
    }

    private struct DTCapture {
        var dlIndex: Int
        var text = ""
        var location: SourceLocation
    }

    /// Case 554591 (item 4): a <figure>'s content so far, for its content
    /// model (a figcaption and then flow content, or flow content and then a
    /// figcaption; see HTMLValidator's FigureContent, which this follows in
    /// a simpler way). Everything after any figcaption used to be reported,
    /// a caption that came first included, and a second caption wasn't.
    private struct FigureContext {
        var depth: Int
        /// The number of SVG and MathML elements open when the figure started
        /// (see foreignDepth): the figure is the parent of an element or text
        /// only while it's the same.
        var foreignDepth: Int
        /// Whether an element or text came before any figcaption.
        var sawContent = false
        /// Whether there's a figcaption yet, and whether it came after
        /// other content, so that nothing may follow it.
        var sawFigcaption = false
        var figcaptionIsLast = false
    }

    /// Case 554591 (item 12): an open colgroup the schema takes where it is
    /// (see noteColgroupStart): where it is on elementStack, and, as with
    /// FigureContext, the number of SVG and MathML elements open when it
    /// started; and whether it has a span attribute, which leaves it no
    /// children at all (see noteColgroupChild).
    private struct ColgroupContext {
        var depth: Int
        var foreignDepth: Int
        var hasSpan: Bool
    }

    /// Case 554591 (item 12, from its review): an open table's column
    /// section, as HTMLValidator's TableColumnSection has it: where the
    /// table is (as in ColgroupContext), whether a colgroup has come, and
    /// whether no more may (once a row group or row, or a script or
    /// template after a colgroup, has come).
    private struct TableColumnSection {
        var depth: Int
        var foreignDepth: Int
        var sawColgroup = false
        var isClosed = false
    }

    private struct RubyContext {
        var location: SourceLocation
        var directChildNames: [String] = []
        var sawBaseContent = false
    }

    private struct XMLStylesheetPseudoAttribute {
        var name: String
        var value: String?
    }

    private var messages: [ValidationMessage] = []
    private var idElementNames: [String: String] = [:]
    private var pendingInputListReferences: [PendingInputListReference] = []
    private var elementStack: [String] = []
    private var anchorHrefStack: [Bool] = []
    private var definitionListContexts: [DefinitionListContext] = []
    private var dtCaptures: [DTCapture] = []
    private var figureContexts: [FigureContext] = []
    // Case 554591 (item 4): the number of open SVG and MathML elements, which
    // aren't on elementStack: an XHTML element or text inside one isn't its
    // figure's child, however elementStack looks. And the depth (open
    // elements of any namespace) of the element the figure rules last found
    // not allowed, or of a template or legacy element, while it's open:
    // upstream's schema checks nothing more inside it, so neither do they.
    // (Item 12's colgroup rule shares it, and adds the content the schema
    // takes unchecked; see noteColgroupChild and noteUncheckedContent.)
    private var foreignDepth = 0
    private var figureRulesSuppressedAbove: Int?
    // Case 554591 (item 12): the open colgroups the schema takes where
    // they are, innermost last; and, from its review, the open tables'
    // column sections, and the depths (open elements of any namespace)
    // of the open MathML annotation-xml elements, likewise.
    private var openColgroups: [ColgroupContext] = []
    private var tableColumnSections: [TableColumnSection] = []
    private var annotationXMLDepths: [Int] = []
    private var rubyContexts: [RubyContext] = []
    private var sawElement = false
    private var tableChecker = HTMLTableModelChecker(mode: .xhtml)

    public func validate(data: Data, source: String) -> [ValidationMessage] {
        messages = []
        idElementNames = [:]
        pendingInputListReferences = []
        elementStack = []
        anchorHrefStack = []
        definitionListContexts = []
        dtCaptures = []
        figureContexts = []
        foreignDepth = 0
        figureRulesSuppressedAbove = nil
        openColgroups = []
        tableColumnSections = []
        annotationXMLDepths = []
        rubyContexts = []
        sawElement = false
        tableChecker = HTMLTableModelChecker(mode: .xhtml)
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        if !parser.parse(), messages.isEmpty {
            messages.append(.error("XML parser failed before reporting a specific well-formedness error."))
        }
        return messages
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        messages.append(.error(parseError.localizedDescription, location: location))
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        sawElement = true
        let name = elementName.lowercased()
        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        guard isXHTMLElement(namespaceURI) else {
            // Case 554591 (item 4): an SVG or MathML element directly in a
            // figure is flow content there, like any other (as written: the
            // parser keeps SVG's camelCase names); everything in it is the
            // foreign element's, not the figure's.
            noteFigureChild(elementName, isXHTML: false, location: location)
            // (Case 554591, item 12: one directly in a colgroup is reported,
            // as a colgroup takes nothing in another namespace; and one can
            // start content the schema takes unchecked.)
            noteColgroupChild(elementName, isXHTML: false, location: location)
            noteUncheckedContent(elementName, namespaceURI: namespaceURI)
            foreignDepth += 1
            return
        }

        if let id = attributeDict["id"], idElementNames[id] == nil {
            idElementNames[id] = name
        }
        let normalizedAttributes = normalizedAttributes(attributeDict)
        // (Case 554591, item 12: with the attributes' names as written, as
        // upstream's TableChecker reads them; an XHTML attribute named SPAN
        // or COLSPAN isn't span or colspan. Lowercased, SPAN="2" got the new
        // warning for a col in its colgroup, which vnu.jar doesn't give.)
        tableChecker.startElement(HTMLTableElementInfo(
            name: name,
            attributes: attributeDict,
            location: location,
            extract: nil
        ))
        if elementStack.last == "ruby", let index = rubyContexts.indices.last {
            rubyContexts[index].directChildNames.append(name)
            if !Self.xhtmlRubyAnnotationElements.contains(name) {
                rubyContexts[index].sawBaseContent = true
            }
        }
        appendXHTMLContentModelMessages(element: name, attributes: normalizedAttributes, location: location)
        noteFigureChild(name, isXHTML: true, location: location)
        noteColgroupChild(name, isXHTML: true, location: location)
        noteUncheckedContent(name, namespaceURI: namespaceURI)
        // (Case 554591, item 4: upstream's schema checks nothing in a
        // template, or in a legacy element that takes anything, such as
        // <center>; so neither do the figure rules, from here until it ends.)
        if nil == figureRulesSuppressedAbove, "template" == name || HTMLValidator.legacyAnythingElements.contains(name) {
            figureRulesSuppressedAbove = elementStack.count + foreignDepth
        }
        appendGlobalAttributeMessages(element: name, attributes: attributeDict, location: location)
        if name == "base",
           attributeDict["href"] == nil,
           attributeDict["target"] == nil {
            messages.append(.error(
                "Element \u{201c}base\u{201d} is missing one or more of the following attributes: \u{201c}href\u{201d}, \u{201c}target\u{201d}.",
                location: location
            ))
        }
        if name == "script", attributeDict["language"] != nil {
            messages.append(.warning(
                "The \u{201c}language\u{201d} attribute on the \u{201c}script\u{201d} element is obsolete. Use the \u{201c}type\u{201d} attribute instead.",
                location: location
            ))
        }
        if name == "keygen" {
            messages.append(.error(
                "The \u{201c}keygen\u{201d} element is obsolete.",
                location: location
            ))
        }
        if name == "applet" {
            messages.append(.error(
                "The \u{201c}applet\u{201d} element is obsolete. Use \u{201c}embed\u{201d} or \u{201c}object\u{201d} element instead.",
                location: location
            ))
        }
        if name == "object", normalizedAttributes["data"] == nil {
            messages.append(.error(
                "Element \u{201c}object\u{201d} is missing required attribute \u{201c}data\u{201d}.",
                location: location
            ))
        }
        if name == "embed" {
            appendEmbedMessages(attributes: attributeDict, location: location)
        }
        if name == "img" {
            appendImageMessages(attributes: attributeDict, location: location)
        }
        if name == "meter" {
            appendMeterMessages(attributes: attributeDict, location: location)
        }
        if name == "progress" {
            appendProgressMessages(attributes: attributeDict, location: location)
        }
        if name == "link",
           attributeDict["href"] == nil,
           attributeDict["imagesrcset"] == nil {
            messages.append(.error(
                "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both.",
                location: location
            ))
        }
        if name == "input", let list = attributeDict["list"] {
            pendingInputListReferences.append(PendingInputListReference(value: list, location: location))
        }
        if name == "dl" {
            definitionListContexts.append(DefinitionListContext())
        } else if name == "dt", let dlIndex = definitionListContexts.indices.last {
            dtCaptures.append(DTCapture(dlIndex: dlIndex, location: location))
        }
        if name == "figure" {
            figureContexts.append(FigureContext(depth: elementStack.count, foreignDepth: foreignDepth))
        }
        // (Case 554591, item 12: an XHTML attribute's name is as written, so
        // this is attributeDict's span, not normalizedAttributes'.)
        if "colgroup" == name {
            noteColgroupStart(hasSpan: nil != attributeDict["span"])
        } else {
            noteTableChild(name)
        }
        // (Case 554591, item 12, from its second review: a span the schema
        // checks; see spanIsCheckedBySchema.)
        if "colgroup" == name || "col" == name, let span = attributeDict["span"], !HTMLValidator.isPositiveInteger(span), spanIsCheckedBySchema(name) {
            appendBadAttributeValue(span, attribute: "span", element: name, location: location)
        }
        // (Case 554591, U11, and the notes' item 30: a cell's colspan and
        // rowspan as the schema checks them (see HTMLValidator's), where it
        // checks the cell: in a row, which is the only place it takes one,
        // outside content it checks nothing in (see
        // figureRulesSuppressedAbove). The table checker reported these, with
        // its own reader, wherever it took the cell.)
        if "td" == name || "th" == name, "tr" == elementStack.last, !(figureRulesSuppressedAbove.map { elementStack.count + foreignDepth > $0 } ?? false) {
            if let colspan = attributeDict["colspan"], !HTMLValidator.isPositiveInteger(colspan) {
                appendBadAttributeValue(colspan, attribute: "colspan", element: name, location: location)
            }
            if let rowspan = attributeDict["rowspan"], !HTMLValidator.isNonNegativeInteger(rowspan) {
                appendBadAttributeValue(rowspan, attribute: "rowspan", element: name, location: location)
            }
        }
        if "table" == name {
            tableColumnSections.append(TableColumnSection(depth: elementStack.count, foreignDepth: foreignDepth))
            noteTablePlacement()
        }
        if name == "ruby" {
            rubyContexts.append(RubyContext(location: location))
        }
        elementStack.append(name)
        anchorHrefStack.append(name == "a" && attributeDict["href"] != nil)
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        guard isXHTMLElement(namespaceURI) else {
            // (Case 554591, item 4: see foreignDepth.)
            foreignDepth -= 1
            // (Case 554591, item 12: see noteUncheckedContent.)
            if annotationXMLDepths.last == elementStack.count + foreignDepth {
                annotationXMLDepths.removeLast()
            }
            noteElementEnded()
            return
        }

        if name == "dt", let capture = dtCaptures.popLast() {
            finishDTCapture(capture)
        }
        if name == "dl", !definitionListContexts.isEmpty {
            _ = definitionListContexts.popLast()
        }
        if name == "figure", !figureContexts.isEmpty {
            _ = figureContexts.popLast()
        }
        if name == "ruby", let context = rubyContexts.popLast() {
            appendXHTMLRubyMessages(context)
        }
        // (Case 554591, U11: where the element ends, the parser's place now,
        // where the table checker reports a row's messages and a colgroup's
        // columns, as upstream's does.)
        tableChecker.endElement(name, at: HTMLTableElementInfo(
            name: name,
            attributes: [:],
            location: SourceLocation(
                firstLine: parser.lineNumber,
                firstColumn: parser.columnNumber,
                lastLine: parser.lineNumber,
                lastColumn: parser.columnNumber
            ),
            extract: nil
        ))
        if let index = elementStack.lastIndex(of: name) {
            elementStack.removeSubrange(index...)
            anchorHrefStack.removeSubrange(index...)
        }
        // (Case 554591, item 12: a colgroup or table that has ended, with
        // whatever the end tag closed above it, takes no more children.)
        while let colgroup = openColgroups.last, colgroup.depth >= elementStack.count {
            openColgroups.removeLast()
        }
        while let section = tableColumnSections.last, section.depth >= elementStack.count {
            tableColumnSections.removeLast()
        }
        noteElementEnded()
    }

    /// Case 554591 (item 12): an element (XHTML, SVG or MathML) directly in a
    /// colgroup the schema takes (see noteColgroupStart), when the
    /// colgroup's content model (html5/tables.rnc) rejects it: a colgroup
    /// with a span attribute takes no children at all, and one without takes
    /// col, script and template (see HTMLValidator's
    /// colgroupContentModelMessage, where only a col or a template can be
    /// in one). In an XHTML document the tree is as written, so a colgroup
    /// can hold anything, and none of this was reported. Then, as with the
    /// figure rules, whose record of where the schema checks nothing this
    /// shares (see figureRulesSuppressedAbove), nothing more is checked
    /// inside the rejected element. Nothing is reported in a template, in a
    /// legacy element such as <center>, in content the schema takes
    /// unchecked (see noteUncheckedContent), or inside an element these
    /// rules have rejected; but the XML checker doesn't know everywhere the
    /// schema rejects a table (in a <ul>, say, or in a <div> in a MathML
    /// <mtext>), and the cols in one are still reported.
    private func noteColgroupChild(_ name: String, isXHTML: Bool, location: SourceLocation) {
        guard "colgroup" == elementStack.last, let colgroup = openColgroups.last,
              elementStack.count - 1 == colgroup.depth, foreignDepth == colgroup.foreignDepth else {
            return
        }
        if let depth = figureRulesSuppressedAbove, elementStack.count + foreignDepth > depth {
            return
        }
        if !colgroup.hasSpan, isXHTML, Self.xhtmlColgroupChildren.contains(name) {
            return
        }
        messages.append(.error(
            "Element \u{201c}\(name)\u{201d} not allowed as child of \u{201c}colgroup\u{201d} in this context.",
            location: location
        ))
        figureRulesSuppressedAbove = elementStack.count + foreignDepth
    }

    /// Case 554591 (item 12, from its second review): whether the schema
    /// checks the span attribute of the XHTML colgroup or col starting now, as
    /// a positive integer (HTMLValidator.isPositiveInteger): a colgroup it
    /// takes where it is (noteColgroupStart has just recorded it), or a col in
    /// such a colgroup that has no span (one with a span rejects it); and
    /// never where it checks nothing (see figureRulesSuppressedAbove). It
    /// rejects a col directly in a table (see HTMLTableModelChecker). The
    /// table checker used to report a bad span, by its own trimming reader,
    /// wherever its own state machine took the element.
    private func spanIsCheckedBySchema(_ name: String) -> Bool {
        if let depth = figureRulesSuppressedAbove, elementStack.count + foreignDepth > depth {
            return false
        }
        guard let colgroup = openColgroups.last, foreignDepth == colgroup.foreignDepth else {
            return false
        }
        if "colgroup" == name {
            return elementStack.count == colgroup.depth
        }
        return "colgroup" == elementStack.last && elementStack.count - 1 == colgroup.depth && !colgroup.hasSpan
    }

    /// Case 554591 (item 12): the children a colgroup without a span
    /// attribute takes (col.elem* & common.elem.script-supporting*).
    private static let xhtmlColgroupChildren: Set<String> = ["col", "script", "template"]

    /// Case 554591 (item 12, from its review): an XHTML colgroup starting.
    /// The schema takes one only directly in a table, before the table's
    /// column section has closed (see TableColumnSection); its children are
    /// then checked (see noteColgroupChild). It rejects one anywhere else (in
    /// a <div>, a cell or a row group, or after the rows) and checks nothing
    /// in it ("Element “colgroup” not allowed as child of …"). The XML
    /// checker doesn't report that yet, but it now checks nothing in it
    /// either, where it reported the cols in it.
    private func noteColgroupStart(hasSpan: Bool) {
        if let index = parentTableSectionIndex, !tableColumnSections[index].isClosed {
            tableColumnSections[index].sawColgroup = true
            openColgroups.append(ColgroupContext(depth: elementStack.count, foreignDepth: foreignDepth, hasSpan: hasSpan))
        } else if nil == figureRulesSuppressedAbove {
            figureRulesSuppressedAbove = elementStack.count + foreignDepth
        }
    }

    /// Case 554591 (item 12, from its review): an XHTML element other than a
    /// colgroup starting, which moves the column section of the table it's
    /// directly in along, if it's in one: a row group or a row closes it, as
    /// does a script or template after a colgroup. (A td or th directly in an
    /// XHTML table, where the schema rejects it, doesn't; nor does anything
    /// else the schema rejects there.)
    private func noteTableChild(_ name: String) {
        guard let index = parentTableSectionIndex else { return }
        switch name {
        case "script", "template":
            if tableColumnSections[index].sawColgroup {
                tableColumnSections[index].isClosed = true
            }
        case "thead", "tbody", "tfoot", "tr":
            tableColumnSections[index].isClosed = true
        default:
            break
        }
    }

    /// Case 554591 (item 12, from its review): an XHTML table starting where
    /// the schema rejects it, as its parent takes phrasing content only (a
    /// <p>, a <span> or a <button>, say, looking through a, ins, del and the
    /// other transparent elements, as HTMLValidator's contentModelMessage
    /// does): vnu.jar reports that ("Element “table” not allowed as child of
    /// “p”"), which the XML checker doesn't yet, and checks nothing inside
    /// the table; so, now, neither do the colgroup and figure rules (see
    /// figureRulesSuppressedAbove), where the colgroup rule reported the
    /// cols in a spanned colgroup in one. (Only outside SVG and MathML
    /// content, where elementStack is the table's ancestry; and not for the
    /// parents whose content HTMLValidator doesn't check either, such as
    /// <ul>: see items 25 and 28 in the case notes.)
    private func noteTablePlacement() {
        guard 0 == foreignDepth, nil == figureRulesSuppressedAbove,
              let parent = elementStack.last(where: { !HTMLVocabulary.transparentElements.contains($0) }),
              HTMLVocabulary.phrasingOnlyContainers.contains(parent) else {
            return
        }
        figureRulesSuppressedAbove = elementStack.count + foreignDepth
    }

    /// Case 554591 (item 12, from its review): the index in
    /// tableColumnSections of the table the element starting now is directly
    /// in, if it's in one.
    private var parentTableSectionIndex: Int? {
        guard "table" == elementStack.last, let index = tableColumnSections.indices.last,
              elementStack.count - 1 == tableColumnSections[index].depth, foreignDepth == tableColumnSections[index].foreignDepth else {
            return nil
        }
        return index
    }

    /// Case 554591 (item 12, from its review): an element starting where the
    /// schema takes content unchecked, as HTMLValidator's inAnyElementContent
    /// has it: anything in an SVG <desc>, at any depth, and an element other
    /// than MathML in a MathML <annotation-xml>, with everything in it.
    /// Nothing is checked there from here until it ends (see
    /// figureRulesSuppressedAbove). The colgroup rule reported a col in a
    /// table in a desc, and item 4's figure rules a figure's content there,
    /// where vnu.jar reports neither. (The element itself is checked as its
    /// parent's child, which a desc or an annotation-xml has no rules for.)
    private func noteUncheckedContent(_ name: String, namespaceURI: String?) {
        let depth = elementStack.count + foreignDepth
        let isMathML = Self.mathMLNamespace == namespaceURI
        if nil == figureRulesSuppressedAbove {
            if Self.svgNamespace == namespaceURI, "desc" == name {
                figureRulesSuppressedAbove = depth
            } else if !isMathML, let annotationXMLDepth = annotationXMLDepths.last, annotationXMLDepth + 1 == depth {
                figureRulesSuppressedAbove = depth
            }
        }
        if isMathML, "annotation-xml" == name {
            annotationXMLDepths.append(depth)
        }
    }

    private static let svgNamespace = "http://www.w3.org/2000/svg"
    private static let mathMLNamespace = "http://www.w3.org/1998/Math/MathML"

    /// Case 554591 (item 4): an element (XHTML, SVG or MathML), for the
    /// content model of the figure it's directly in, if any (see
    /// FigureContext): a figcaption first, then flow content, or flow
    /// content, then a figcaption, and never a second one; and the children
    /// a figure never takes (see xhtmlFigureRejectedChildren), wherever they
    /// are. An element found not allowed starts a subtree where the figure
    /// rules check nothing more, as upstream's schema does. The old version
    /// of this reported everything after any figcaption (a caption that came
    /// first included), and no second caption; and, not seeing SVG or
    /// MathML, took a caption after an <svg> for the first one, and an XHTML
    /// figcaption inside one's foreignObject for the figure's own.
    private func noteFigureChild(_ name: String, isXHTML: Bool, location: SourceLocation) {
        guard let index = currentFigureIndex else { return }
        if isXHTML, "figcaption" == name, !figureContexts[index].sawFigcaption {
            figureContexts[index].sawFigcaption = true
            figureContexts[index].figcaptionIsLast = figureContexts[index].sawContent
            return
        }
        let isRejected = isXHTML && Self.xhtmlFigureRejectedChildren.contains(name)
        guard isRejected || (isXHTML && "figcaption" == name) || figureContexts[index].figcaptionIsLast else {
            // (Flow content, which, before any caption, makes a caption
            // after it the last.)
            if !figureContexts[index].sawFigcaption {
                figureContexts[index].sawContent = true
            }
            return
        }
        // A second figcaption, anything after one that came last, or a child
        // a figure never takes.
        messages.append(.error(
            "Element \u{201c}\(name)\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context.",
            location: location
        ))
        figureRulesSuppressedAbove = elementStack.count + foreignDepth
    }

    /// Case 554591 (item 4): the index of the figure an element or text here
    /// is directly in, if the figure rules apply (see FigureContext and
    /// figureRulesSuppressedAbove).
    private var currentFigureIndex: Int? {
        guard "figure" == elementStack.last, let index = figureContexts.indices.last, foreignDepth == figureContexts[index].foreignDepth else {
            return nil
        }
        if let depth = figureRulesSuppressedAbove, elementStack.count + foreignDepth > depth {
            return nil
        }
        return index
    }

    /// Case 554591 (item 4): once the element the figure rules last found not
    /// allowed has ended, they apply again (see figureRulesSuppressedAbove).
    private func noteElementEnded() {
        if let depth = figureRulesSuppressedAbove, elementStack.count + foreignDepth <= depth {
            figureRulesSuppressedAbove = nil
        }
    }

    /// Case 554591 (item 4): the XHTML elements upstream's schema never takes
    /// as a child of a figure, wherever they are in it: HTMLValidator's list
    /// (see figureRejectedChildren), and, as HTML's own checkers report them
    /// in an HTML document, <li> and <base>; and <noscript>, which XHTML
    /// doesn't have at all.
    private static let xhtmlFigureRejectedChildren: Set<String> = HTMLValidator.figureRejectedChildren.union(["base", "li", "noscript"])

    private func appendXHTMLContentModelMessages(element name: String, attributes: [String: String], location: SourceLocation) {
        if attributes["contextmenu"] != nil {
            messages.append(.warning(
                "The \u{201c}contextmenu\u{201d} attribute is obsolete. Use script to handle \u{201c}contextmenu\u{201d} event instead.",
                location: location
            ))
        }
        if name == "menu", attributes["type"] != nil {
            messages.append(.warning(
                "The \u{201c}type\u{201d} attribute on the \u{201c}menu\u{201d} element is obsolete. Use script to handle \u{201c}contextmenu\u{201d} event instead.",
                location: location
            ))
        }
        if name == "a", attributes["name"] != nil {
            messages.append(.warning(
                "The \u{201c}name\u{201d} attribute on the \u{201c}a\u{201d} element is obsolete. Consider putting an \u{201c}id\u{201d} attribute on the nearest container instead.",
                location: location
            ))
        }
        if name == "footer" || name == "header",
           let ancestor = elementStack.last(where: { $0 == "footer" || $0 == "header" }) {
            messages.append(.error(
                "The element \u{201c}\(name)\u{201d} must not appear as a descendant of the \u{201c}\(ancestor)\u{201d} element.",
                location: location
            ))
        }

        if elementStack.last == "menu", !Self.xhtmlMenuChildElements.contains(name) {
            messages.append(.error(
                "Element \u{201c}\(name)\u{201d} not allowed as child of \u{201c}menu\u{201d} in this context.",
                location: location
            ))
        }
        if elementStack.last == "dialog", name == "dt" {
            messages.append(.error(
                "Element \u{201c}dt\u{201d} not allowed as child of \u{201c}dialog\u{201d} in this context.",
                location: location
            ))
        }
    }

    private func appendGlobalAttributeMessages(element: String, attributes: [String: String], location: SourceLocation) {
        if let accesskey = attributes["accesskey"], !isValidAccesskeyValue(accesskey) {
            appendBadAttributeValue(accesskey, attribute: "accesskey", element: element, location: location)
        }
        if let spellcheck = attributes["spellcheck"], !isValidSpellcheckValue(spellcheck) {
            appendBadAttributeValue(spellcheck, attribute: "spellcheck", element: element, location: location)
        }
        if attributes.keys.contains(where: isInvalidXMLDataAttributeName) {
            messages.append(.error(
                "\u{201c}data-*\u{201d} attributes must not have characters from the range \u{201c}A\u{201d}\u{2026}\u{201c}Z\u{201d} in the name.",
                location: location
            ))
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in dtCaptures.indices {
            dtCaptures[index].text += string
        }
        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        // Case 554591 (item 4): text directly in a figure, which is reported
        // only after a figcaption that came last, and before any figcaption
        // makes the one after it the last. This comes before the check below,
        // which passes over text that's all Unicode whitespace: to upstream's
        // schema validator only a space, tab, CR or LF is, so a no-break
        // space is text.
        if string.unicodeScalars.contains(where: { !(" " == $0 || "\t" == $0 || "\n" == $0 || "\r" == $0) }), let index = currentFigureIndex {
            if figureContexts[index].figcaptionIsLast {
                messages.append(.error("Text not allowed in \u{201c}figure\u{201d} in this context.", location: location))
            } else if !figureContexts[index].sawFigcaption {
                figureContexts[index].sawContent = true
            }
        }
        guard string.contains(where: { !$0.isWhitespace }) else { return }
        if elementStack.last == "menu" {
            messages.append(.error("Text not allowed in \u{201c}menu\u{201d} in this context.", location: location))
        }
        if elementStack.contains("iframe") {
            messages.append(.error("Text not allowed in \u{201c}iframe\u{201d} in this context.", location: location))
        }
        if elementStack.last == "ruby", let index = rubyContexts.indices.last {
            rubyContexts[index].sawBaseContent = true
        }
    }

    public func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        guard target.lowercased() == "xml-stylesheet" else { return }
        let location = SourceLocation(
            firstLine: parser.lineNumber,
            firstColumn: parser.columnNumber,
            lastLine: parser.lineNumber,
            lastColumn: parser.columnNumber
        )
        if sawElement {
            messages.append(.error(
                "Any \u{201c}xml-stylesheet\u{201d} instruction in a document must occur before any elements in the document. Suppressing any further errors for this \u{201c}xml-stylesheet\u{201d} instruction.",
                location: location
            ))
            return
        }
        appendXMLStylesheetMessages(data ?? "", location: location)
    }

    private func appendXHTMLRubyMessages(_ context: RubyContext) {
        if !context.sawBaseContent && context.directChildNames.isEmpty {
            messages.append(.error(
                "Element \u{201c}ruby\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}rp\u{201d}, \u{201c}rt\u{201d}, \u{201c}rtc\u{201d}.",
                location: context.location
            ))
        } else if !context.sawBaseContent && context.directChildNames.contains("rt") {
            messages.append(.error(
                "Element \u{201c}ruby\u{201d} is missing a required instance of child element \u{201c}rt\u{201d}.",
                location: context.location
            ))
        }
    }

    public func parserDidEndDocument(_ parser: XMLParser) {
        for diagnostic in tableChecker.finish() {
            if diagnostic.warning {
                messages.append(.warning(diagnostic.message, location: diagnostic.location, extract: diagnostic.extract))
            } else {
                messages.append(.error(diagnostic.message, location: diagnostic.location, extract: diagnostic.extract))
            }
        }
        for reference in pendingInputListReferences where idElementNames[reference.value] != "datalist" {
            messages.append(.error(
                "The \u{201c}list\u{201d} attribute of the \u{201c}input\u{201d} element must refer to a \u{201c}datalist\u{201d} element.",
                location: reference.location
            ))
        }
    }

    private func appendEmbedMessages(attributes: [String: String], location: SourceLocation) {
        for attribute in ["height", "width"] {
            if let value = attributes[attribute], !isValidNonNegativeInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, element: "embed", location: location)
            }
        }
        if let type = attributes["type"], !isValidMIMEType(type) {
            appendBadAttributeValue(type, attribute: "type", element: "embed", location: location)
        }
    }

    private func appendImageMessages(attributes: [String: String], location: SourceLocation) {
        for attribute in ["height", "width"] {
            if let value = attributes[attribute], !isValidNonNegativeInteger(value) {
                appendBadAttributeValue(value, attribute: attribute, element: "img", location: location)
            }
        }
        if attributes["ismap"] != nil, !anchorHrefStack.contains(true) {
            messages.append(.error(
                "The \u{201c}img\u{201d} element with the \u{201c}ismap\u{201d} attribute set must have an \u{201c}a\u{201d} ancestor with the \u{201c}href\u{201d} attribute.",
                location: location
            ))
        }
        if attributes["usemap"] != nil, elementStack.contains("a") {
            messages.append(.error(
                "The element \u{201c}img\u{201d} with the attribute \u{201c}usemap\u{201d} must not appear as a descendant of the \u{201c}a\u{201d} element.",
                location: location
            ))
        }
    }

    private func appendMeterMessages(attributes: [String: String], location: SourceLocation) {
        guard let value = attributes["value"] else {
            messages.append(.error("Element \u{201c}meter\u{201d} is missing required attribute \u{201c}value\u{201d}.", location: location))
            return
        }
        guard let meterValue = validFloatingPointAttribute("value", value, element: "meter", location: location) else {
            return
        }
        let minValue = numberAttribute("min", attributes: attributes, defaultValue: 0, element: "meter", location: location)
        let maxValue = numberAttribute("max", attributes: attributes, defaultValue: 1, element: "meter", location: location)
        guard let minValue, let maxValue else { return }
        let lowValue = numberAttribute("low", attributes: attributes, defaultValue: minValue, element: "meter", location: location)
        let highValue = numberAttribute("high", attributes: attributes, defaultValue: maxValue, element: "meter", location: location)
        let optimumValue = optionalNumberAttribute("optimum", attributes: attributes, element: "meter", location: location)

        if attributes["min"] == nil, meterValue < 0 {
            messages.append(.error("The value of the \u{201c}value\u{201d} attribute must be greater than or equal to zero when the \u{201c}min\u{201d} attribute is absent.", location: location))
        }
        if attributes["max"] == nil, meterValue > 1 {
            messages.append(.error("The value of the \u{201c}value\u{201d} attribute must be less than or equal to one when the \u{201c}max\u{201d} attribute is absent.", location: location))
        }
        if minValue > meterValue {
            messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}value\u{201d} attribute.", location: location))
        }
        if meterValue > maxValue {
            messages.append(.error("The value of the \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
        }
        if let lowValue {
            if minValue > lowValue {
                messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}low\u{201d} attribute.", location: location))
            }
            if let highValue, lowValue > highValue {
                messages.append(.error("The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute.", location: location))
            }
            if lowValue > maxValue {
                messages.append(.error("The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
            }
        }
        if let highValue {
            if minValue > highValue {
                messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute.", location: location))
            }
            if highValue > maxValue {
                messages.append(.error("The value of the \u{201c}high\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
            }
        }
        if let optimumValue {
            if minValue > optimumValue {
                messages.append(.error("The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}optimum\u{201d} attribute.", location: location))
            }
            if optimumValue > maxValue {
                messages.append(.error("The value of the \u{201c}optimum\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
            }
        }
    }

    private func appendProgressMessages(attributes: [String: String], location: SourceLocation) {
        let maxValue = numberAttribute("max", attributes: attributes, defaultValue: 1, element: "progress", location: location)
        if let max = maxValue, max <= 0 {
            appendBadAttributeValue(attributes["max"] ?? "", attribute: "max", element: "progress", location: location)
        }
        guard let value = attributes["value"],
              let progressValue = validFloatingPointAttribute("value", value, element: "progress", location: location) else {
            return
        }
        if progressValue < 0 {
            appendBadAttributeValue(value, attribute: "value", element: "progress", location: location)
        }
        if attributes["max"] == nil, progressValue > 1 {
            messages.append(.error("The value of the  \u{201c}value\u{201d} attribute must be less than or equal to one when the \u{201c}max\u{201d} attribute is absent.", location: location))
        } else if let max = maxValue, progressValue > max {
            messages.append(.error("The value of the  \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute.", location: location))
        }
    }

    private func validFloatingPointAttribute(_ attribute: String, _ value: String, element: String, location: SourceLocation) -> Double? {
        guard isValidFloatingPointNumber(value), let parsed = Double(value) else {
            appendBadAttributeValue(value, attribute: attribute, element: element, location: location)
            return nil
        }
        return parsed
    }

    private func optionalNumberAttribute(_ attribute: String, attributes: [String: String], element: String, location: SourceLocation) -> Double? {
        guard let value = attributes[attribute] else { return nil }
        return validFloatingPointAttribute(attribute, value, element: element, location: location)
    }

    private func numberAttribute(_ attribute: String, attributes: [String: String], defaultValue: Double, element: String, location: SourceLocation) -> Double? {
        guard let value = attributes[attribute] else { return defaultValue }
        return validFloatingPointAttribute(attribute, value, element: element, location: location)
    }

    private func isValidFloatingPointNumber(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: isASCIIWhitespace),
              let parsed = Double(value),
              parsed.isFinite else {
            return false
        }
        return true
    }

    private func isValidNonNegativeInteger(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy(isASCIIDigit) else { return false }
        return Int(value) != nil
    }

    private func appendXMLStylesheetMessages(_ data: String, location: SourceLocation) {
        let attributes = parseXMLStylesheetPseudoAttributes(data)
        let allowedAttributes: Set<String> = ["href", "type", "title", "media", "charset", "alternate"]
        var values: [String: String] = [:]
        var seenNames: Set<String> = []

        for attribute in attributes {
            guard allowedAttributes.contains(attribute.name) else {
                messages.append(.error(
                    "Pseudo-attribute \u{201c}\(attribute.name)\u{201d} not allowed in \u{201c}xml-stylesheet\u{201d} instruction.",
                    location: location
                ))
                continue
            }
            guard let value = attribute.value else {
                messages.append(.error(
                    "Found \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}\(attribute.name)\u{201d} without a value. All pseudo-attributes in \u{201c}xml-stylesheet\u{201d} instructions must have values.",
                    location: location
                ))
                continue
            }
            if seenNames.contains(attribute.name) {
                messages.append(.error(
                    "Duplicate \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}\(attribute.name)\u{201d}.",
                    location: location
                ))
                continue
            }
            seenNames.insert(attribute.name)
            values[attribute.name] = value
        }

        if values["href"] == nil {
            messages.append(.error(
                "\u{201c}xml-stylesheet\u{201d} instruction lacks \u{201c}href\u{201d} pseudo-attribute. The \u{201c}href\u{201d} pseudo-attribute is required in all \u{201c}xml-stylesheet\u{201d} instructions.",
                location: location
            ))
        } else if let href = values["href"], href.unicodeScalars.contains(where: isASCIIWhitespace) {
            messages.append(.error(
                "Bad value \u{201c}\(href)\u{201d} for \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}href\u{201d}. Bad URL: Illegal character in path segment. Space is not allowed.",
                location: location
            ))
        }

        if let type = values["type"] {
            if !isValidMIMEType(type) {
                let suffix = type == "text" ? " Bad MIME type: Subtype missing." : ""
                messages.append(.error(
                    "Bad value \u{201c}\(type)\u{201d} for \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}type\u{201d}.\(suffix)",
                    location: location
                ))
            } else if !Self.supportedXMLStylesheetTypes.contains(type.lowercased()) {
                messages.append(.warning(
                    "\u{201c}text/css\u{201d} and \u{201c}text/xsl\u{201d} are the only MIME types for the \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}type\u{201d} that are supported across browsers.",
                    location: location
                ))
            }
        }

        if let charset = values["charset"] {
            if !Self.supportedXMLStylesheetCharsets.contains(charset.lowercased()) {
                messages.append(.error(
                    "Bad value \u{201c}\(charset)\u{201d} for \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}charset\u{201d}. Bad encoding name: \u{201c}\(charset)\u{201d} is not a valid character encoding name.",
                    location: location
                ))
            } else {
                messages.append(.warning(
                    "Some browsers ignore the value of the \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}charset\u{201d}.",
                    location: location
                ))
            }
        }

        if let alternate = values["alternate"] {
            if alternate != "yes" && alternate != "no" {
                messages.append(.error(
                    "The value of the \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}alternate\u{201d} must be either \u{201c}yes\u{201d} or \u{201c}no\u{201d}.",
                    location: location
                ))
            } else if alternate == "yes", values["title"]?.isEmpty != false {
                messages.append(.error(
                    "An \u{201c}xml-stylesheet\u{201d} instruction with an \u{201c}alternate\u{201d} pseudo-attribute whose value is \u{201c}yes\u{201d} must also have a \u{201c}title\u{201d} pseudo-attribute with a non-empty value.",
                    location: location
                ))
            }
        }
    }

    private func parseXMLStylesheetPseudoAttributes(_ data: String) -> [XMLStylesheetPseudoAttribute] {
        var attributes: [XMLStylesheetPseudoAttribute] = []
        var index = data.startIndex

        while index < data.endIndex {
            skipXMLStylesheetWhitespace(in: data, index: &index)
            guard index < data.endIndex else { break }

            let nameStart = index
            while index < data.endIndex,
                  data[index] != "=",
                  !data[index].unicodeScalars.allSatisfy(isASCIIWhitespace) {
                data.formIndex(after: &index)
            }
            let name = String(data[nameStart..<index])
            skipXMLStylesheetWhitespace(in: data, index: &index)
            guard index < data.endIndex, data[index] == "=" else {
                attributes.append(XMLStylesheetPseudoAttribute(name: name, value: nil))
                continue
            }

            data.formIndex(after: &index)
            skipXMLStylesheetWhitespace(in: data, index: &index)
            guard index < data.endIndex else {
                attributes.append(XMLStylesheetPseudoAttribute(name: name, value: ""))
                break
            }

            let quote = data[index]
            if quote == "\"" || quote == "'" {
                data.formIndex(after: &index)
                let valueStart = index
                while index < data.endIndex, data[index] != quote {
                    data.formIndex(after: &index)
                }
                let value = String(data[valueStart..<index])
                if index < data.endIndex {
                    data.formIndex(after: &index)
                }
                attributes.append(XMLStylesheetPseudoAttribute(name: name, value: value))
            } else {
                let valueStart = index
                while index < data.endIndex,
                      !data[index].unicodeScalars.allSatisfy(isASCIIWhitespace) {
                    data.formIndex(after: &index)
                }
                attributes.append(XMLStylesheetPseudoAttribute(name: name, value: String(data[valueStart..<index])))
            }
        }

        return attributes
    }

    private func skipXMLStylesheetWhitespace(in data: String, index: inout String.Index) {
        while index < data.endIndex, data[index].unicodeScalars.allSatisfy(isASCIIWhitespace) {
            data.formIndex(after: &index)
        }
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

    private func isValidSpellcheckValue(_ value: String) -> Bool {
        value.isEmpty || value.lowercased() == "true" || value.lowercased() == "false"
    }

    private func isInvalidXMLDataAttributeName(_ name: String) -> Bool {
        guard name.hasPrefix("data-"), name.count > "data-".count else { return false }
        return name.unicodeScalars.contains { scalar in
            scalar.value >= 65 && scalar.value <= 90
        }
    }

    private func appendBadAttributeValue(_ value: String, attribute: String, element: String, location: SourceLocation) {
        messages.append(.error(
            "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}\(attribute)\u{201d} on element \u{201c}\(element)\u{201d}.",
            location: location
        ))
    }

    private func normalizedAttributes(_ attributes: [String: String]) -> [String: String] {
        Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
    }

    private func finishDTCapture(_ capture: DTCapture) {
        let name = normalizedText(capture.text)
        guard !name.isEmpty,
              definitionListContexts.indices.contains(capture.dlIndex) else {
            return
        }
        if definitionListContexts[capture.dlIndex].termNames.contains(name) {
            messages.append(.warning(
                "Duplicate \u{201c}dt\u{201d} name \u{201c}\(name)\u{201d} in \u{201c}dl\u{201d} element. Within a single \u{201c}dl\u{201d} element, there should not be more than one \u{201c}dt\u{201d} element for each name.",
                location: capture.location
            ))
        }
        definitionListContexts[capture.dlIndex].termNames.insert(name)
    }

    private func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func isXHTMLElement(_ namespaceURI: String?) -> Bool {
        namespaceURI == "http://www.w3.org/1999/xhtml" || namespaceURI == nil
    }

    private func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            return true
        default:
            return false
        }
    }

    private func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static let xhtmlMenuChildElements: Set<String> = [
        "li", "script", "template"
    ]

    private static let xhtmlRubyAnnotationElements: Set<String> = [
        "rp", "rt", "rtc"
    ]

    private static let supportedXMLStylesheetTypes: Set<String> = [
        "text/css", "text/xsl"
    ]

    private static let supportedXMLStylesheetCharsets: Set<String> = [
        "utf-8", "utf8", "us-ascii", "iso-8859-1", "utf-16"
    ]
}

public final class CSSValidator: Sendable {
    public init() {}

    public func validate(source: String) -> [ValidationMessage] {
        let locations = SourceLocationMap(source)
        var messages: [ValidationMessage] = []
        var stack: [(Character, Int)] = []
        for (offset, character) in source.utf16OffsetsAndCharacters() {
            switch character {
            case "{", "(", "[":
                stack.append((character, offset))
            case "}":
                close("{", actual: "}", offset: offset, locations: locations, stack: &stack, messages: &messages)
            case ")":
                close("(", actual: ")", offset: offset, locations: locations, stack: &stack, messages: &messages)
            case "]":
                close("[", actual: "]", offset: offset, locations: locations, stack: &stack, messages: &messages)
            default:
                break
            }
        }
        for (character, offset) in stack {
            messages.append(.error("CSS: Unclosed \u{201c}\(character)\u{201d}.", location: locations.location(offset: offset), extract: locations.extract(offset: offset)))
        }
        return messages
    }

    private func close(
        _ expected: Character,
        actual: Character,
        offset: Int,
        locations: SourceLocationMap,
        stack: inout [(Character, Int)],
        messages: inout [ValidationMessage]
    ) {
        guard let last = stack.popLast() else {
            messages.append(.error("CSS: Stray \u{201c}\(actual)\u{201d}.", location: locations.location(offset: offset), extract: locations.extract(offset: offset)))
            return
        }
        if last.0 != expected {
            messages.append(.error("CSS: Expected matching \u{201c}\(last.0)\u{201d} before \u{201c}\(actual)\u{201d}.", location: locations.location(offset: offset), extract: locations.extract(offset: offset)))
        }
    }
}

private extension String {
    func utf16OffsetsAndCharacters() -> [(Int, Character)] {
        var result: [(Int, Character)] = []
        var index = startIndex
        while index < endIndex {
            let utf16 = index.samePosition(in: self.utf16).map { self.utf16.distance(from: self.utf16.startIndex, to: $0) } ?? self.utf16.count
            result.append((utf16, self[index]))
            formIndex(after: &index)
        }
        return result
    }
}
