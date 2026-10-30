import Foundation
import VNUCore

struct HTMLAttribute: Equatable, Sendable {
    var name: String
    var value: String?
    var offset: Int
}

/// Review item A2: attribute values are kept as written, character references
/// and all (the tokenizer only checks the references), but upstream's checks
/// see values its tokenizer has already decoded. A check that compares or
/// parses a value has to decode it first: A2's namespace check reported
/// xmlns="http&#x3a;//www.w3.org/1999/xhtml" as a bad value, and its SVG path
/// data check rejected d="M0 0&#10;L1 1", both of which vnu.jar accepts.
///
/// This decodes every numeric reference, and the named references that stand
/// for an ASCII character (such as &amp;, &colon; and &sol;). For namespace
/// URIs, encodings and path data that's all that matters: a value written
/// with any other named reference doesn't match or parse whether it's decoded
/// or not. IDs aren't so simple: id="caf&eacute;" and id="café" are the same
/// ID upstream, but not here, since the port has no table of HTML's other
/// named references to decode them with. Anything else, including a named
/// reference without its semicolon, is left as written. (Numeric references in
/// the C1 range aren't remapped to windows-1252 characters as the tokenizer
/// would; nothing checked here can tell the difference.)
enum HTMLCharacterReferences {
    static func decode(_ value: String) -> String {
        decode(value, formFeedReferenceIsSpace: false)
    }

    /// Case 554591 (item 12): an attribute value as upstream's tokenizer
    /// hands it to the checkers: as decode(_:) has it, except that a
    /// reference to a form feed (&#12;, &#xC;) is a space there, as it is in
    /// text (see item 4's figure text rules), while a literal form feed stays
    /// one. So vnu.jar reads span="&#12;2" as " 2", a span of 2, and splits
    /// headers="a&#12;b" into two IDs, but not headers="a<FF>b". Only the
    /// table checker and headingoffset (case 554591, item 3: its check and
    /// the heading levels) use this so far; the other checks that decode a
    /// value still see the form feed.
    static func decodeAttributeValue(_ value: String) -> String {
        decode(value, formFeedReferenceIsSpace: true)
    }

    private static func decode(_ value: String, formFeedReferenceIsSpace: Bool) -> String {
        // The usual case: nothing to decode, and no copy made.
        guard value.contains("&") else {
            return value
        }
        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if "&" == scalars[index], let decoded = reference(in: scalars, at: index) {
                output.append(formFeedReferenceIsSpace && "\u{0C}" == decoded.scalar ? " " : decoded.scalar)
                index = decoded.next
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    /// The reference starting at `start` (an "&"): its character, and the
    /// index just past it. nil if it isn't one this decodes.
    private static func reference(in scalars: [Unicode.Scalar], at start: Int) -> (scalar: Unicode.Scalar, next: Int)? {
        var cursor = start + 1
        guard cursor < scalars.count else {
            return nil
        }
        if "#" == scalars[cursor] {
            cursor += 1
            var radix: UInt32 = 10
            if cursor < scalars.count, "x" == scalars[cursor] || "X" == scalars[cursor] {
                radix = 16
                cursor += 1
            }
            let digitsStart = cursor
            var code: UInt32 = 0
            while cursor < scalars.count, let digit = digitValue(of: scalars[cursor], radix: radix) {
                // Past U+10FFFF no more digits can bring it back into range,
                // so stop accumulating there, which also means this can't
                // overflow (see review item A10's `&#4294967296;`).
                if code <= 0x10FFFF {
                    code = code * radix + digit
                }
                cursor += 1
            }
            guard cursor > digitsStart else {
                return nil
            }
            // A numeric reference counts even without its semicolon (the
            // tokenizer reports that), as upstream's does.
            if cursor < scalars.count, ";" == scalars[cursor] {
                cursor += 1
            }
            // As in the tokenizer: NUL, surrogates and anything past U+10FFFF
            // become U+FFFD.
            let scalar = (0 == code) ? nil : Unicode.Scalar(code)
            return (scalar ?? "\u{FFFD}", cursor)
        }
        // A named reference: ASCII letters and digits, then a semicolon. (The
        // longest name in HTML's list has 31 characters; stop well past that.)
        let nameStart = cursor
        while cursor < scalars.count, cursor - nameStart < 40, isASCIIAlphanumeric(scalars[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart, cursor < scalars.count, ";" == scalars[cursor] else {
            return nil
        }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: scalars[nameStart..<cursor])
        guard let scalar = asciiNamedReferences[String(name)] else {
            return nil
        }
        return (scalar, cursor + 1)
    }

    private static func digitValue(of scalar: Unicode.Scalar, radix: UInt32) -> UInt32? {
        switch scalar.value {
        case 0x30...0x39:
            return scalar.value - 0x30
        case 0x41...0x46 where 16 == radix:
            return scalar.value - 0x41 + 10
        case 0x61...0x66 where 16 == radix:
            return scalar.value - 0x61 + 10
        default:
            return nil
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            return true
        default:
            return false
        }
    }

    /// HTML's named references for ASCII characters (from the HTML
    /// standard's list), by name without the "&" and ";".
    private static let asciiNamedReferences: [String: Unicode.Scalar] = [
        "amp": "&", "AMP": "&", "quot": "\"", "QUOT": "\"", "apos": "'",
        "lt": "<", "LT": "<", "gt": ">", "GT": ">",
        "colon": ":", "sol": "/", "bsol": "\\", "period": ".", "comma": ",", "semi": ";",
        "excl": "!", "quest": "?", "num": "#", "dollar": "$", "percnt": "%",
        "plus": "+", "equals": "=", "commat": "@", "ast": "*", "midast": "*",
        "lpar": "(", "rpar": ")", "lsqb": "[", "lbrack": "[", "rsqb": "]", "rbrack": "]",
        "lcub": "{", "lbrace": "{", "rcub": "}", "rbrace": "}",
        "verbar": "|", "vert": "|", "VerticalLine": "|",
        "lowbar": "_", "UnderBar": "_", "Hat": "^", "grave": "`", "DiacriticalGrave": "`",
        "Tab": "\t", "NewLine": "\n",
    ]
}

/// Review item A2: which namespace an element is in. The tokenizer works this
/// out for every start tag (see HTMLTreeEventBuilder.namespace(forStartTag:
/// attributes:)), and the tree builder and the checkers use it to apply
/// HTML's rules (its vocabulary, content models, void elements and
/// self-closing syntax) to HTML elements only.
/// Before, everything inside inline <svg> or <math> was checked as HTML, so
/// every icon's <path/> and <circle/> was reported twice over.
enum HTMLNamespace: Equatable, Sendable {
    case html
    case svg
    case mathML
}

enum HTMLToken: Equatable, Sendable {
    case startTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool, namespace: HTMLNamespace, offset: Int, length: Int)
    case endTag(name: String, offset: Int, length: Int)
    case doctype(offset: Int, length: Int)
    case text(content: String, offset: Int, length: Int)
    case comment(content: String, offset: Int, length: Int)
    case bogusMarkup(offset: Int, length: Int)
    case parseError(message: String, offset: Int, length: Int)
}

final class HTMLTokenizer {
    private let source: String
    private let locations: SourceLocationMap

    init(source: String, locations: SourceLocationMap) {
        self.source = source
        self.locations = locations
    }

    /// The tokens, and the events HTMLTreeEventBuilder builds from them.
    /// Review item A2: the tree builder runs as the tokens are produced,
    /// because the namespace of each start tag's element, and whether
    /// "<![CDATA[" starts a CDATA section, depend on its current node (see
    /// HTMLTreeEventBuilder).
    func tokenizeAndBuildTree() -> (tokens: [HTMLToken], events: [HTMLDocumentEvent], impliedColgroupEnds: [Int], impliedTablePartEnds: [HTMLImpliedTablePartEnd], implicitEndCauses: [HTMLImplicitEndCause]) {
        // Case 554591: the whole-source diagnostics (character references and
        // forbidden code points) are now computed after the main loop, which
        // collects the ranges where the HTML tokenizer never parses character
        // references: raw text and script contents, comments and CDATA
        // sections. "&#" in JavaScript or "&nbsp" in CSS used to be errors.
        var tokens: [HTMLToken] = []
        var noCharacterReferenceRanges: [Range<String.Index>] = []
        // Review item A2: the tree builder, and how many of `tokens` it has
        // consumed. It's caught up just before each question it's asked, so it
        // consumes every token, in order, exactly as it did when it ran after
        // the tokenizer (nothing here changes a token once it's appended).
        var treeBuilder = HTMLTreeEventBuilder()
        var tokensConsumedByTreeBuilder = 0
        func catchUpTreeBuilder() {
            while tokensConsumedByTreeBuilder < tokens.count {
                treeBuilder.consume(tokens[tokensConsumedByTreeBuilder])
                tokensConsumedByTreeBuilder += 1
            }
        }
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "<" else {
                let textStart = index
                while index < source.endIndex, source[index] != "<" {
                    source.formIndex(after: &index)
                }
                appendText(from: textStart, to: index, to: &tokens)
                continue
            }
            let start = index
            if consumePrefix("<!--", from: &index) {
                let commentStart = index
                if let endRange = source[index...].range(of: "-->") {
                    let comment = source[commentStart..<endRange.lowerBound]
                    if let nested = comment.range(of: "<!--") {
                        appendError(
                            "Saw \u{201c}<!--\u{201d} within a comment. Probable cause: Nested comment (not allowed).",
                            at: nested.lowerBound,
                            length: 4,
                            to: &tokens
                        )
                    }
                    appendComment(from: commentStart, to: endRange.lowerBound, to: &tokens)
                    noCharacterReferenceRanges.append(commentStart..<endRange.lowerBound)
                    index = endRange.upperBound
                } else {
                    appendError("End of file inside comment.", at: start, length: source.utf16.distance(from: start.samePosition(in: source.utf16) ?? source.utf16.startIndex, to: source.utf16.endIndex), to: &tokens)
                    appendComment(from: commentStart, to: source.endIndex, to: &tokens)
                    noCharacterReferenceRanges.append(commentStart..<source.endIndex)
                    index = source.endIndex
                }
                continue
            }
            // Case 554591: in SVG/MathML, "<![CDATA[...]]>" is a CDATA section
            // (text), e.g. the CSS in an exported SVG's <style>. It used to be
            // reported as a bogus comment. (In HTML content it still is one.)
            catchUpTreeBuilder()
            if treeBuilder.isCDATAAllowed, consumePrefix("<![CDATA[", from: &index) {
                let contentStart = index
                let contentEnd = source[index...].range(of: "]]>")
                appendText(from: contentStart, to: contentEnd?.lowerBound ?? source.endIndex, to: &tokens)
                noCharacterReferenceRanges.append(contentStart..<(contentEnd?.lowerBound ?? source.endIndex))
                // Upstream's tokenizer reports nothing for EOF in a CDATA section.
                index = contentEnd?.upperBound ?? source.endIndex
                continue
            }
            if consumePrefix("<!DOCTYPE", from: &index, caseInsensitive: true) {
                appendDoctypeDiagnostics(from: start, afterKeyword: index, to: &tokens)
                _ = skipUntil(">", from: &index)
                // Upstream's DOCTYPE, bogus-comment and attribute-name states
                // never parse character references, so neither do we here or
                // in the "<?" and "<!" branches and attribute names below.
                // (Without this, e.g. `<!x &#0;>` got character-reference
                // errors upstream doesn't report.)
                noCharacterReferenceRanges.append(start..<index)
                let offset = locations.offset(of: start)
                tokens.append(.doctype(offset: offset, length: max(1, locations.offset(of: index) - offset)))
                continue
            }
            if consumePrefix("</", from: &index) {
                if index == source.endIndex {
                    appendError("End of file after \u{201c}<\u{201d}.", at: start, length: 2, to: &tokens)
                    continue
                }
                if source[index] == ">" {
                    appendError("Saw \u{201c}</>\u{201d}. Probable causes: Unescaped \u{201c}<\u{201d} (escape as \u{201c}&lt;\u{201d}) or mistyped end tag.", at: start, length: 3, to: &tokens)
                    source.formIndex(after: &index)
                    continue
                }
                let beforeWhitespace = index
                skipWhitespace(from: &index)
                if beforeWhitespace != index {
                    appendError("Garbage after \u{201c}</\u{201d}.", at: start, length: max(2, locations.offset(of: index) - locations.offset(of: start)), to: &tokens)
                    _ = skipUntil(">", from: &index)
                    continue
                }
                if index < source.endIndex, !isNameStart(source[index]) {
                    appendError("Garbage after \u{201c}</\u{201d}.", at: start, length: max(2, locations.offset(of: index) - locations.offset(of: start)), to: &tokens)
                    _ = skipUntil(">", from: &index)
                    continue
                }
                let nameStart = index
                while index < source.endIndex, isNameCharacter(source[index]) {
                    source.formIndex(after: &index)
                }
                let name = String(source[nameStart..<index]).lowercased()
                var postName = index
                skipWhitespace(from: &postName)
                if postName < source.endIndex, source[postName] != ">" {
                    if source[postName] == "/" {
                        appendError("Stray \u{201c}/\u{201d} at the end of an end tag.", at: postName, length: 1, to: &tokens)
                    } else {
                        appendError("End tag had attributes.", at: postName, length: 1, to: &tokens)
                    }
                }
                let foundEnd = skipUntil(">", from: &index)
                if !foundEnd {
                    appendError("End of file seen when looking for tag name. Ignoring tag.", at: start, length: max(1, locations.offset(of: source.endIndex) - locations.offset(of: start)), to: &tokens)
                }
                let offset = locations.offset(of: start)
                if name.isEmpty {
                    tokens.append(.bogusMarkup(offset: offset, length: max(1, locations.offset(of: index) - offset)))
                } else {
                    tokens.append(.endTag(name: name, offset: offset, length: max(1, locations.offset(of: index) - offset)))
                }
                continue
            }
            if consumePrefix("<?", from: &index) {
                appendError("Saw \u{201c}<?\u{201d}. Probable cause: Attempt to use an XML processing instruction in HTML. (XML processing instructions are not supported in HTML.)", at: start, length: 2, to: &tokens)
                _ = skipUntil(">", from: &index)
                // A bogus comment: no character references (see "<!DOCTYPE").
                noCharacterReferenceRanges.append(start..<index)
                continue
            }
            if consumePrefix("<!", from: &index) {
                appendError("Bogus comment.", at: start, length: 2, to: &tokens)
                _ = skipUntil(">", from: &index)
                // A bogus comment: no character references (see "<!DOCTYPE").
                noCharacterReferenceRanges.append(start..<index)
                continue
            }
            source.formIndex(after: &index)
            if index == source.endIndex {
                appendError("End of file after \u{201c}<\u{201d}.", at: start, length: 1, to: &tokens)
                continue
            }
            if source[index] == ">" {
                appendError("Saw \u{201c}<>\u{201d}. Probable causes: Unescaped \u{201c}<\u{201d} (escape as \u{201c}&lt;\u{201d}) or mistyped start tag.", at: start, length: 2, to: &tokens)
                source.formIndex(after: &index)
                continue
            }
            guard index < source.endIndex, isNameStart(source[index]) else {
                let offset = locations.offset(of: start)
                appendError(
                    "Bad character \u{201c}\(display(source[index]))\u{201d} after \u{201c}<\u{201d}. Probable cause: Unescaped \u{201c}<\u{201d}. Try escaping it as \u{201c}&lt;\u{201d}.",
                    at: index,
                    length: 1,
                    to: &tokens
                )
                tokens.append(.bogusMarkup(offset: offset, length: max(1, locations.offset(of: index) - offset + 1)))
                continue
            }
            let nameStart = index
            while index < source.endIndex, isNameCharacter(source[index]) {
                source.formIndex(after: &index)
            }
            let name = String(source[nameStart..<index]).lowercased()
            var attributes: [HTMLAttribute] = []
            var selfClosing = false
            var tagClosed = false
            // True when the previous attribute had a quoted value, so this
            // iteration starts exactly where upstream's "after attribute
            // value (quoted)" state starts: just past the closing quote.
            var afterQuotedValue = false
            while index < source.endIndex {
                let whitespaceStart = index
                skipWhitespace(from: &index)
                let hadWhitespace = whitespaceStart != index
                // "No space between attributes." is only an error right after
                // a quoted value's closing quote: upstream raises
                // errNoSpaceBetweenAttributes in AFTER_ATTRIBUTE_VALUE_QUOTED
                // and nowhere else. It used to be reported whenever this
                // iteration found no whitespace, but after a valueless
                // attribute (async, required, controls, x-cloak...) the
                // whitespace has already been skipped while looking for "=",
                // so every boolean attribute that wasn't last on its tag was
                // reported, e.g. `<script async src="a.js">`. The attributes
                // themselves were still recorded, so this was only the bogus
                // error.
                let missingSpaceAfterQuotedValue = afterQuotedValue && !hadWhitespace
                afterQuotedValue = false
                guard index < source.endIndex else { break }
                if source[index] == ">" {
                    source.formIndex(after: &index)
                    tagClosed = true
                    break
                }
                if source[index] == "/" {
                    source.formIndex(after: &index)
                    if index < source.endIndex, source[index] == ">" {
                        selfClosing = true
                        source.formIndex(after: &index)
                        tagClosed = true
                        break
                    }
                    // Upstream's self-closing start tag state: anything other
                    // than ">" right after the slash is errSlashNotFollowedByGt,
                    // and that character is reconsumed as if it began the next
                    // attribute (whitespace included). So "<br / >" isn't
                    // self-closing, and `id="a"/class="b"` has a slash error but
                    // no missing-space error. This used to skip whitespace
                    // after the slash and treat "/ >" as self-closing; for
                    // anything else it never reported the slash error, just
                    // nothing (e.g. `<br//>`, or no attribute before the
                    // slash) or one or two bogus missing-space errors. At end
                    // of file upstream reports no slash error either, only
                    // the unclosed-tag error below.
                    if index < source.endIndex {
                        appendError("A slash was not immediately followed by \u{201c}>\u{201d}.", at: index, length: 1, to: &tokens)
                    }
                    continue
                }
                if missingSpaceAfterQuotedValue {
                    appendError("No space between attributes.", at: index, length: 1, to: &tokens)
                }
                if source[index] == "=" {
                    appendError("Saw \u{201c}=\u{201d} when expecting an attribute name. Probable cause: Attribute name missing.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                    continue
                }
                if source[index] == "<" {
                    appendError("Saw \u{201c}<\u{201d} when expecting an attribute name. Probable cause: Missing \u{201c}>\u{201d} immediately before.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                    continue
                }
                let attrOffset = locations.offset(of: index)
                let attrNameStart = index
                while index < source.endIndex, isAttributeNameCharacter(source[index]) {
                    source.formIndex(after: &index)
                }
                // Attribute names: no character references (see "<!DOCTYPE").
                if attrNameStart < index {
                    noCharacterReferenceRanges.append(attrNameStart..<index)
                }
                let attrName = String(source[attrNameStart..<index]).lowercased()
                if attrName.isEmpty {
                    if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                        appendError("Quote \u{201c}\(display(source[index]))\u{201d} in attribute name. Probable cause: Matching quote missing somewhere earlier.", at: index, length: 1, to: &tokens)
                    }
                    source.formIndex(after: &index)
                    continue
                }
                if index < source.endIndex, source[index] == "<" {
                    appendError("\u{201c}<\u{201d} in attribute name. Probable cause: \u{201c}>\u{201d} missing immediately before.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                } else if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                    appendError("Quote \u{201c}\(display(source[index]))\u{201d} in attribute name. Probable cause: Matching quote missing somewhere earlier.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                }
                skipWhitespace(from: &index)
                var value: String?
                if index < source.endIndex, source[index] == "=" {
                    source.formIndex(after: &index)
                    skipWhitespace(from: &index)
                    // Remember whether the value is quoted for the next
                    // iteration's missing-space check (see above). An unquoted
                    // value always ends at whitespace or ">", so it can't run
                    // into the next attribute.
                    afterQuotedValue = index < source.endIndex && ("\"" == source[index] || "'" == source[index])
                    value = parseAttributeValue(from: &index, tokens: &tokens)
                }
                attributes.append(HTMLAttribute(name: attrName, value: value, offset: attrOffset))
            }
            if !tagClosed {
                let message = attributes.isEmpty ? "Saw end of file without the previous tag ending with \u{201c}>\u{201d}. Ignoring tag." : "End of file occurred in an attribute name. Ignoring tag."
                appendError(message, at: start, length: max(1, locations.offset(of: source.endIndex) - locations.offset(of: start)), to: &tokens)
                // (Case 554591, from U11's review: and the tag is ignored, as
                // the message says and as upstream's tokenizer does, emitting
                // nothing at the end of the file. It went on to be an element,
                // so a "<tr" the file ended in was a row, a "<td colspan=3"
                // a cell, for the tree and every checker. This is the end of
                // the file, so the loop ends here.)
                continue
            }
            let offset = locations.offset(of: start)
            // Review item A2: the element's namespace goes on the token, from
            // the tree builder's current node. (An HTML <image> keeps its
            // name here: the tree builder handles it as <img>, and
            // HTMLValidator reports it, under the name it was written with
            // where upstream does.)
            catchUpTreeBuilder()
            let namespace = treeBuilder.namespace(forStartTag: name, attributes: attributes)
            tokens.append(.startTag(name: name, attributes: attributes, selfClosing: selfClosing, namespace: namespace, offset: offset, length: max(1, locations.offset(of: index) - offset)))

            // Case 554591: the contents of <script>, <style>, <title>,
            // <textarea> and a few obsolete elements aren't markup; the HTML
            // tokenizer switches to its script data / RAWTEXT / RCDATA state
            // and reads text up to the matching end tag. This tokenizer used
            // to keep parsing markup there, so "i<3" in a script or "<b>" in a
            // <title> became bogus tags and errors.
            //
            // This only applies to HTML elements. In inline SVG or MathML,
            // <script>, <style> and <title> are foreign elements whose
            // contents are ordinary markup; upstream's tree builder never
            // switches the tokenizer state for them.
            //
            // A self-closing tag is no different: on an HTML element the slash
            // is ignored, so <script/>'s contents are still script. (This used
            // to be skipped because HTMLValidator didn't keep self-closed
            // elements open; review item A2 fixed that. The self-closing error
            // itself is reported elsewhere.)
            if tagClosed, .html == namespace, let kind = TextContentKind(elementName: name) {
                consumeTextContent(of: name, kind: kind, from: &index, to: &tokens, noCharacterReferenceRanges: &noCharacterReferenceRanges)
            }
        }
        catchUpTreeBuilder()
        // (Review item A2: the tree builder finishes first, and the whole-source
        // diagnostics go in front of the tokens in place. Building a third
        // array, a copy of every token, while the tokens and the finished
        // events were all alive raised the peak memory for a large document
        // by 30–60%.)
        let events = treeBuilder.finish(endOffset: locations.offset(of: source.endIndex))
        tokens.insert(contentsOf: sourceDiagnostics(skippingCharacterReferencesIn: noCharacterReferenceRanges), at: 0)
        // (Case 554591, item 12, from its second and third reviews: see
        // HTMLParsedDocument.impliedColgroupEnds and impliedTablePartEnds; and
        // U11's implicitEndCauses.)
        return (tokens, events, treeBuilder.impliedColgroupEnds, treeBuilder.impliedTablePartEnds, treeBuilder.implicitEndCauses)
    }

    /// Which tokenizer state an element's contents are read in.
    private enum TextContentKind {
        /// title, textarea: text (character references are still recognized).
        case rcdata
        /// style, xmp, iframe, noembed, noframes: raw text.
        case rawText
        /// script: raw text, with the "<!-- ... <script> ... -->" escaping rules.
        case scriptData
        /// plaintext: everything to the end of the file.
        case plaintext

        /// Nu parses with scripting disabled, so <noscript> contents are
        /// markup, not raw text, and aren't listed here.
        init?(elementName: String) {
            switch elementName {
            case "title", "textarea":
                self = .rcdata
            case "style", "xmp", "iframe", "noembed", "noframes":
                self = .rawText
            case "script":
                self = .scriptData
            case "plaintext":
                self = .plaintext
            default:
                return nil
            }
        }
    }

    /// Emits the contents of a text-only element as a single text token and
    /// leaves `index` at the "<" of its end tag, which the main loop then
    /// tokenizes normally.
    private func consumeTextContent(
        of name: String,
        kind: TextContentKind,
        from index: inout String.Index,
        to tokens: inout [HTMLToken],
        noCharacterReferenceRanges: inout [Range<String.Index>]
    ) {
        let contentStart = index
        let contentEnd: String.Index?
        switch kind {
        case .rcdata, .rawText:
            contentEnd = nextEndTag(named: name, from: index)
        case .scriptData:
            contentEnd = endOfScriptData(from: index)
        case .plaintext:
            contentEnd = nil
        }

        // Only RCDATA (<title>, <textarea>) recognizes character references;
        // raw text, script data and plaintext contents are taken literally.
        if .rcdata != kind {
            noCharacterReferenceRanges.append(contentStart..<(contentEnd ?? source.endIndex))
        }

        guard let contentEnd else {
            appendText(from: contentStart, to: source.endIndex, to: &tokens)
            // Upstream's tree builder reports this when the file ends while it
            // is still expecting an element's text ("text" insertion mode).
            // Case 554591: this replaces a heuristic that reported it for any
            // document merely containing both "</style>" and "<script".
            // (<plaintext> can't be closed at all; it's reported as obsolete.)
            if .plaintext != kind {
                appendError("End of file seen when expecting text or an end tag.", at: source.endIndex, length: 1, to: &tokens)
            }
            index = source.endIndex
            return
        }

        appendText(from: contentStart, to: contentEnd, to: &tokens)
        index = contentEnd
    }

    /// The "<" of the next "</name" end tag (RCDATA/RAWTEXT "appropriate end
    /// tag" rule), or nil if the file ends first.
    private func nextEndTag(named name: String, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            if "<" == source[cursor], matchesTagOpen("</", name, at: cursor) {
                return cursor
            }
            source.formIndex(after: &cursor)
        }
        return nil
    }

    /// The "<" of the "</script" end tag that actually closes a script, or nil
    /// if the file ends first. This follows the tokenizer's script data
    /// states: inside "<!--", a "<script" starts a "double escaped" section in
    /// which "</script>" does *not* end the element (that's how the old
    /// document.write("<script ...></script>") idiom works), and "-->" goes
    /// back to plain script data.
    private func endOfScriptData(from start: String.Index) -> String.Index? {
        enum Mode {
            case data
            case escaped
            case doubleEscaped
        }

        var mode = Mode.data
        // Consecutive "-" characters just seen in the escaped modes; "-->"
        // (two or more dashes, then ">") returns to plain script data.
        var dashes = 0
        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            switch mode {
            case .data:
                if "<" == character {
                    if matchesTagOpen("</", "script", at: cursor) {
                        return cursor
                    }
                    if source[cursor...].hasPrefix("<!--") {
                        // "script data escape start" through "escaped dash
                        // dash": the "--" of "<!--" counts toward "-->", so
                        // "<!-->" escapes and immediately unescapes.
                        mode = .escaped
                        dashes = 2
                        cursor = source.index(cursor, offsetBy: 4)
                        continue
                    }
                }
            case .escaped, .doubleEscaped:
                if "-" == character {
                    dashes += 1
                } else if ">" == character, dashes >= 2 {
                    mode = .data
                    dashes = 0
                } else {
                    dashes = 0
                    if "<" == character {
                        if .escaped == mode {
                            if matchesTagOpen("</", "script", at: cursor) {
                                return cursor
                            }
                            if matchesTagOpen("<", "script", at: cursor) {
                                mode = .doubleEscaped
                            }
                        } else if matchesTagOpen("</", "script", at: cursor) {
                            // "script data double escape end": back to
                            // escaped; this end tag doesn't close the script.
                            mode = .escaped
                        }
                    }
                }
            }
            source.formIndex(after: &cursor)
        }
        return nil
    }

    /// Whether `opener` followed by `name` (ASCII case-insensitively; `name`
    /// is lowercase) starts at `index` and is followed by a character that
    /// ends a tag name: tab, LF, FF, CR, space, "/" or ">". The trailing
    /// character matters: "</scripts>" doesn't close a <script>, and neither
    /// does "</script" at the very end of the file.
    private func matchesTagOpen(_ opener: String, _ name: String, at index: String.Index) -> Bool {
        var cursor = index
        for expected in (opener + name).utf8 {
            guard cursor < source.endIndex,
                  let actual = source[cursor].asciiValue,
                  expected == ((65...90).contains(actual) ? actual + 32 : actual) else {
                return false
            }
            source.formIndex(after: &cursor)
        }
        guard cursor < source.endIndex else {
            return false
        }
        let terminator = source[cursor]
        if "/" == terminator || ">" == terminator {
            return true
        }
        // Check scalars rather than Character.isWhitespace, which is broader
        // than HTML's definition (it includes e.g. U+00A0). "\r\n" is a
        // single Character, hence allSatisfy.
        return terminator.unicodeScalars.allSatisfy { [0x09, 0x0A, 0x0C, 0x0D, 0x20].contains($0.value) }
    }

    private func parseAttributeValue(from index: inout String.Index, tokens: inout [HTMLToken]) -> String {
        guard index < source.endIndex else {
            return ""
        }
        if source[index] == ">" {
            appendError("Attribute value missing.", at: index, length: 1, to: &tokens)
            return ""
        }
        if source[index] == "\"" || source[index] == "'" {
            let quote = source[index]
            source.formIndex(after: &index)
            let valueStart = index
            while index < source.endIndex, source[index] != quote {
                source.formIndex(after: &index)
            }
            let value = String(source[valueStart..<index])
            if index < source.endIndex {
                source.formIndex(after: &index)
            } else {
                appendError("End of file reached when inside an attribute value. Ignoring tag.", at: valueStart, length: max(1, locations.offset(of: source.endIndex) - locations.offset(of: valueStart)), to: &tokens)
            }
            return value
        }
        switch source[index] {
        case "=":
            appendError("\u{201c}=\u{201d} at the start of an unquoted attribute value. Probable cause: Stray duplicate equals sign.", at: index, length: 1, to: &tokens)
        case "<":
            appendError("\u{201c}<\u{201d} at the start of an unquoted attribute value. Probable cause: Missing \u{201c}>\u{201d} immediately before.", at: index, length: 1, to: &tokens)
        case "`":
            appendError("\u{201c}`\u{201d} at the start of an unquoted attribute value. Probable cause: Using the wrong character as a quote.", at: index, length: 1, to: &tokens)
        default:
            break
        }
        let valueStart = index
        while index < source.endIndex, !source[index].isWhitespace, source[index] != ">" {
            switch source[index] {
            case "<":
                appendError("\u{201c}<\u{201d} in an unquoted attribute value. Probable cause: Missing \u{201c}>\u{201d} immediately before.", at: index, length: 1, to: &tokens)
            case "`" where index != valueStart:
                appendError("\u{201c}`\u{201d} in an unquoted attribute value. Probable cause: Using the wrong character as a quote.", at: index, length: 1, to: &tokens)
            case "\"":
                appendError("\u{201c}\"\u{201d} in an unquoted attribute value. Probable causes: Attributes running together or a URL query string in an unquoted attribute value.", at: index, length: 1, to: &tokens)
            default:
                break
            }
            source.formIndex(after: &index)
        }
        return String(source[valueStart..<index])
    }

    private func appendText(from start: String.Index, to end: String.Index, to tokens: inout [HTMLToken]) {
        guard start < end else { return }
        let offset = locations.offset(of: start)
        tokens.append(.text(content: String(source[start..<end]), offset: offset, length: max(1, locations.offset(of: end) - offset)))
    }

    private func appendComment(from start: String.Index, to end: String.Index, to tokens: inout [HTMLToken]) {
        let offset = locations.offset(of: start)
        tokens.append(.comment(content: String(source[start..<end]), offset: offset, length: max(1, locations.offset(of: end) - offset)))
    }

    private func skipWhitespace(from index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            source.formIndex(after: &index)
        }
    }

    @discardableResult
    private func skipUntil(_ needle: String, from index: inout String.Index) -> Bool {
        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                index = source.index(index, offsetBy: needle.count, limitedBy: source.endIndex) ?? source.endIndex
                return true
            }
            source.formIndex(after: &index)
        }
        return false
    }

    private func consumePrefix(_ prefix: String, from index: inout String.Index, caseInsensitive: Bool = false) -> Bool {
        // Review item A11: the case-insensitive test (used for "<!DOCTYPE" at
        // every "<") lowercased the whole rest of the document before
        // comparing, so tokenizing was quadratic: a 1.5 MB page took over 30
        // seconds, and because lowercased() only has a fast path for ASCII,
        // a single non-ASCII character made it about 100 times slower (a
        // 136 KB page with a "©" in its footer took 14 s). Compare just the
        // prefix's characters instead.
        //
        // The comparison stays Character by Character, as hasPrefix did,
        // so a combining mark attached to the last character still prevents
        // a match and the index always lands on a Character boundary. Case
        // folding is ASCII-only, as HTML specifies for DOCTYPE.
        var cursor = index
        for expected in prefix {
            guard cursor < source.endIndex else {
                return false
            }
            let actual = source[cursor]
            let same = actual == expected
                || (caseInsensitive && actual.isASCII && expected.isASCII && actual.lowercased() == expected.lowercased())
            guard same else {
                return false
            }
            source.formIndex(after: &cursor)
        }
        index = cursor
        return true
    }

    private func isNameStart(_ character: Character) -> Bool {
        character.isLetter || character == ":"
    }

    private func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
    }

    private func isAttributeNameCharacter(_ character: Character) -> Bool {
        !(character.isWhitespace || character == "=" || character == ">" || character == "/" || character == "\"" || character == "'" || character == "<")
    }

    /// Whole-source diagnostics. `noCharacterReferenceRanges` (ascending, from
    /// tokenizeAndBuildTree()) are the places where "&" is just a character.
    private func sourceDiagnostics(skippingCharacterReferencesIn noCharacterReferenceRanges: [Range<String.Index>]) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var index = source.startIndex
        var rangeIndex = 0
        while index < source.endIndex {
            if source[index] == "&" {
                // Case 554591: skip "&" inside script/style contents,
                // comments and CDATA sections, which upstream never parses
                // for character references.
                while rangeIndex < noCharacterReferenceRanges.count, noCharacterReferenceRanges[rangeIndex].upperBound <= index {
                    rangeIndex += 1
                }
                let isLiteral = rangeIndex < noCharacterReferenceRanges.count && noCharacterReferenceRanges[rangeIndex].contains(index)
                if !isLiteral {
                    appendCharacterReferenceDiagnostics(at: index, to: &tokens)
                }
            }
            if let scalar = source[index].unicodeScalars.first {
                appendCodePointDiagnostics(scalar, at: index, to: &tokens)
            }
            source.formIndex(after: &index)
        }

        // Case 554591: a heuristic here reported "End of file seen when
        // expecting text or an end tag." for *any* document containing both
        // "</style>" and "<script" (or "</src>"), which is most real pages.
        // The error is now reported by consumeTextContent(), when a script or
        // other text-only element actually runs to the end of the file.
        return tokens
    }

    private func appendCodePointDiagnostics(_ scalar: Unicode.Scalar, at index: String.Index, to tokens: inout [HTMLToken]) {
        let value = scalar.value
        if value == 0x000B {
            appendError("Forbidden code point U+000b.", at: index, length: 1, to: &tokens)
        } else if isAstralNonCharacter(value) {
            appendError("Astral non-character.", at: index, length: 1, to: &tokens)
        }
    }

    private func appendCharacterReferenceDiagnostics(at ampersand: String.Index, to tokens: inout [HTMLToken]) {
        var index = ampersand
        source.formIndex(after: &index)
        guard index < source.endIndex else { return }

        if source[index] != "#" {
            let nameStart = index
            while index < source.endIndex, source[index].isLetter || source[index].isNumber {
                source.formIndex(after: &index)
            }
            let name = String(source[nameStart..<index]).lowercased()
            if ["amp", "lt", "gt", "quot", "nbsp"].contains(name), index < source.endIndex, source[index] != ";" {
                appendError("Named character reference was not terminated by a semicolon. (Or \u{201c}&\u{201d} should have been escaped as \u{201c}&amp;\u{201d}.)", at: ampersand, length: max(1, locations.offset(of: index) - locations.offset(of: ampersand)), to: &tokens)
            }
            return
        }

        source.formIndex(after: &index)
        var isHex = false
        if index < source.endIndex, source[index] == "x" || source[index] == "X" {
            isHex = true
            source.formIndex(after: &index)
        }
        let digitsStart = index
        while index < source.endIndex, isHex ? source[index].isHexDigit : source[index].isNumber {
            source.formIndex(after: &index)
        }
        guard digitsStart != index else {
            appendError("No digits after \u{201c}\u{201d}.", at: ampersand, length: max(1, locations.offset(of: index) - locations.offset(of: ampersand)), to: &tokens)
            return
        }
        let digits = String(source[digitsStart..<index])
        if index == source.endIndex || source[index] != ";" {
            appendError("Character reference was not terminated by a semicolon.", at: ampersand, length: max(1, locations.offset(of: index) - locations.offset(of: ampersand)), to: &tokens)
        }
        // UInt32(_:radix:) returns nil when the number doesn't fit, so a
        // reference of 2^32 or more (e.g. `&#4294967296;`) used to get no
        // diagnostic at all; upstream reports it as outside the permissible
        // Unicode range. Treat an all-ASCII-digit overflow as UInt32.max so
        // it gets that error. (A non-ASCII digit still gets nothing, as
        // before.)
        let isASCIIDigits = digits.unicodeScalars.allSatisfy { scalar in
            isHex ? scalar.properties.isASCIIHexDigit : (48...57).contains(scalar.value)
        }
        guard let value = UInt32(digits, radix: isHex ? 16 : 10) ?? (isASCIIDigits ? UInt32.max : nil) else { return }
        appendNumericCharacterReferenceDiagnostic(value, at: ampersand, to: &tokens)
    }

    private func appendNumericCharacterReferenceDiagnostic(_ value: UInt32, at index: String.Index, to tokens: inout [HTMLToken]) {
        switch value {
        case 0:
            appendError("Character reference expands to zero.", at: index, length: 1, to: &tokens)
        case 0x0D:
            appendError("A numeric character reference expanded to carriage return.", at: index, length: 1, to: &tokens)
        case 0x80...0x9F:
            appendError("A numeric character reference expanded to the C1 controls range.", at: index, length: 1, to: &tokens)
        case 0xD800...0xDFFF:
            appendError("Character reference expands to a surrogate.", at: index, length: 1, to: &tokens)
        case 0x110000...UInt32.max:
            appendError("Character reference outside the permissible Unicode range.", at: index, length: 1, to: &tokens)
        // Upstream reports the whole U+FDD0–U+FDEF block this way; this used to
        // catch only U+FDD0, and the rest got no error at all.
        case 0xFDD0...0xFDEF:
            appendError("Character reference expands to a permanently unassigned code point.", at: index, length: 1, to: &tokens)
        default:
            // The C0 controls other than tab, line feed, form feed and carriage
            // return (which has its own message above), and DEL, as upstream's
            // tokenizer has them. This used to include tab, LF and FF, so a
            // multi-line tooltip, title="line 1&#10;line 2", was an error.
            if value <= 0x08 || 0x0B == value || (0x0E...0x1F).contains(value) || 0x7F == value {
                appendError("Character reference expands to a control character (\(uPlus(value))).", at: index, length: 1, to: &tokens)
            } else if isAstralNonCharacter(value) {
                appendError("Character reference expands to an astral non-character (\(uPlus(value))).", at: index, length: 1, to: &tokens)
            } else if isBMPNonCharacter(value) {
                appendError("Character reference expands to a non-character (\(uPlus(value))).", at: index, length: 1, to: &tokens)
            }
        }
    }

    private func appendDoctypeDiagnostics(from start: String.Index, afterKeyword: String.Index, to tokens: inout [HTMLToken]) {
        let tailEnd = source[start...].firstIndex(of: "\n") ?? source.endIndex
        let tail = String(source[start..<tailEnd])
        let lowerTail = tail.lowercased()
        if afterKeyword == source.endIndex || source[afterKeyword] == ">" || !source[afterKeyword].isWhitespace {
            appendError("Missing space before doctype name.", at: start, length: minUTF16Length(9, from: start), to: &tokens)
        }
        if lowerTail.contains(" bogus") {
            appendError("Bogus doctype.", at: start, length: minUTF16Length(tail.utf16.count, from: start), to: &tokens)
        }
        if lowerTail.contains("public\"") {
            appendError("No space between the doctype \u{201c}PUBLIC\u{201d} keyword and the quote.", at: start, length: 1, to: &tokens)
        }
        if lowerTail.contains("system\"") {
            appendError("No space between the doctype \u{201c}SYSTEM\u{201d} keyword and the quote.", at: start, length: 1, to: &tokens)
        }
        if lowerTail.contains("\"\"") {
            appendError("No space between the doctype public and system identifiers.", at: start, length: 1, to: &tokens)
        }
        if lowerTail.contains("public >") {
            appendError("Expected a public identifier but the doctype ended.", at: start, length: 1, to: &tokens)
        }
        if lowerTail.contains("system >") {
            appendError("Expected a system identifier but the doctype ended.", at: start, length: 1, to: &tokens)
        }
        if quotedIdentifierContainsGreaterThan(keyword: "public", in: lowerTail) {
            appendError("\u{201c}>\u{201d} in public identifier.", at: start, length: 1, to: &tokens)
        }
        if quotedIdentifierContainsGreaterThan(keyword: "system", in: lowerTail) {
            appendError("\u{201c}>\u{201d} in system identifier.", at: start, length: 1, to: &tokens)
        }
        if !lowerTail.contains(">") {
            if lowerTail.contains("public \"") {
                appendError("End of file inside public identifier.", at: start, length: 1, to: &tokens)
            } else if lowerTail.contains("system \"") {
                appendError("End of file inside system identifier.", at: start, length: 1, to: &tokens)
            } else {
                appendError("End of file inside system identifier.", at: start, length: 1, to: &tokens)
            }
        }
        if lowerTail.contains("html 4.01 transitional") {
            appendError("Almost standards mode doctype. Expected \u{201c}<!DOCTYPE html>\u{201d}.", at: start, length: 1, to: &tokens)
        } else if lowerTail.contains("html 4.01") || lowerTail.contains("html 4.0") {
            appendError("Obsolete doctype. Expected \u{201c}<!DOCTYPE html>\u{201d}.", at: start, length: 1, to: &tokens)
        }
    }

    private func appendError(_ message: String, at index: String.Index, length: Int, to tokens: inout [HTMLToken]) {
        tokens.append(.parseError(message: message, offset: locations.offset(of: index), length: max(1, length)))
    }

    private func display(_ character: Character) -> String {
        if character == "\u{0}" {
            return "\\"
        }
        return String(character)
    }

    private func minUTF16Length(_ length: Int, from index: String.Index) -> Int {
        max(1, min(length, locations.offset(of: source.endIndex) - locations.offset(of: index)))
    }

    private func uPlus(_ value: UInt32) -> String {
        let width = value <= 0xFFFF ? 4 : 1
        return "U+" + String(String(value, radix: 16).leftPadded(to: width, with: "0"))
    }

    private func isAstralNonCharacter(_ value: UInt32) -> Bool {
        value > 0xFFFF && (value & 0xFFFE) == 0xFFFE && value <= 0x10FFFF
    }

    private func isBMPNonCharacter(_ value: UInt32) -> Bool {
        value == 0xFFFE || value == 0xFFFF
    }

    private func quotedIdentifierContainsGreaterThan(keyword: String, in text: String) -> Bool {
        guard let keywordRange = text.range(of: "\(keyword) \"") else {
            return false
        }
        let valueStart = keywordRange.upperBound
        guard let greaterThan = text[valueStart...].firstIndex(of: ">"),
              let quote = text[valueStart...].firstIndex(of: "\"") else {
            return false
        }
        return greaterThan < quote
    }
}

private extension Character {
    var isHexDigit: Bool {
        unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
        }
    }
}

private extension String {
    func leftPadded(to width: Int, with character: Character) -> String {
        if count >= width { return self }
        return String(repeating: String(character), count: width - count) + self
    }
}

/// Review item A2: upstream's tree-builder rules for foreign content (SVG and
/// MathML), shared by the element stacks in HTMLTreeEventBuilder (which the
/// tokenizer also asks for each start tag's namespace) and HTMLValidator, so
/// that they agree on which elements are foreign and where HTML content
/// resumes.
enum HTMLForeignContent {
    /// Start tags that end foreign content (TreeBuilder's "breakout" list);
    /// upstream reports them as HTML start tags in a foreign context and pops
    /// back to the nearest HTML context. (<font> only with color/face/size.)
    static let breakoutStartTags: Set<String> = [
        "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div",
        "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p",
        "pre", "ruby", "s", "small", "span", "strike", "strong", "sub", "sup",
        "table", "tt", "u", "ul", "var"
    ]

    /// Whether a start tag is handled as foreign content rather than as HTML:
    /// a foreign element, other than the <svg> or <math> that starts foreign
    /// content where HTML is allowed (the tree builder handles that tag as an
    /// HTML start tag, implied end tags included). `parentChildrenAreHTML` is
    /// whether the current node is an HTML element or an integration point.
    static func isHandledAsForeign(_ name: String, namespace: HTMLNamespace, parentChildrenAreHTML: Bool) -> Bool {
        .html != namespace && !(parentChildrenAreHTML && nil != rootNamespace(of: name))
    }

    /// Upstream's exception for MathML text integration points: inside mi,
    /// mo, mn, ms or mtext, an <mglyph> or <malignmark> start tag is MathML.
    static func staysMathML(_ name: String, inside parent: String, namespace: HTMLNamespace) -> Bool {
        .mathML == namespace && ("mglyph" == name || "malignmark" == name) && mathMLTextIntegrationPoints.contains(parent)
    }

    static let mathMLTextIntegrationPoints: Set<String> = ["mi", "mo", "mn", "ms", "mtext"]

    /// Review item A2 (U18): SVG element names that have capitals, from the
    /// HTML spec's table (upstream's ElementName), keyed by the lowercased
    /// name the tokenizer produces. Messages use these, as upstream's do.
    static let svgTagNameCase: [String: String] = [
        "altglyph": "altGlyph",
        "altglyphdef": "altGlyphDef",
        "altglyphitem": "altGlyphItem",
        "animatecolor": "animateColor",
        "animatemotion": "animateMotion",
        "animatetransform": "animateTransform",
        "clippath": "clipPath",
        "feblend": "feBlend",
        "fecolormatrix": "feColorMatrix",
        "fecomponenttransfer": "feComponentTransfer",
        "fecomposite": "feComposite",
        "feconvolvematrix": "feConvolveMatrix",
        "fediffuselighting": "feDiffuseLighting",
        "fedisplacementmap": "feDisplacementMap",
        "fedistantlight": "feDistantLight",
        "fedropshadow": "feDropShadow",
        "feflood": "feFlood",
        "fefunca": "feFuncA",
        "fefuncb": "feFuncB",
        "fefuncg": "feFuncG",
        "fefuncr": "feFuncR",
        "fegaussianblur": "feGaussianBlur",
        "feimage": "feImage",
        "femerge": "feMerge",
        "femergenode": "feMergeNode",
        "femorphology": "feMorphology",
        "feoffset": "feOffset",
        "fepointlight": "fePointLight",
        "fespecularlighting": "feSpecularLighting",
        "fespotlight": "feSpotLight",
        "fetile": "feTile",
        "feturbulence": "feTurbulence",
        "foreignobject": "foreignObject",
        "glyphref": "glyphRef",
        "lineargradient": "linearGradient",
        "radialgradient": "radialGradient",
        "textpath": "textPath"
    ]

    /// An element's name as upstream's messages spell it.
    static func displayName(_ name: String, namespace: HTMLNamespace) -> String {
        (.svg == namespace) ? (svgTagNameCase[name] ?? name) : name
    }

    /// Every element upstream's MathML schema (schema/mml3) defines,
    /// presentation and content MathML alike (193; "list" is written \list
    /// there, as it's an RNC keyword). The schema accepts any of these where
    /// a MathML expression may go, so only other names are "not allowed as
    /// child" of a MathML element.
    static let mathMLSchemaElements: Set<String> = [
        "list",
        "abs", "and", "annotation", "annotation-xml", "apply", "approx", "arccos", "arccosh",
        "arccot", "arccoth", "arccsc", "arccsch", "arcsec", "arcsech", "arcsin", "arcsinh",
        "arctan", "arctanh", "arg", "bind", "bvar", "card", "cartesianproduct", "cbytes",
        "ceiling", "cerror", "ci", "cn", "codomain", "complexes", "compose", "condition",
        "conjugate", "cos", "cosh", "cot", "coth", "cs", "csc", "csch", "csymbol", "curl",
        "declare", "degree", "determinant", "diff", "divergence", "divide", "domain",
        "domainofapplication", "emptyset", "eq", "equivalent", "eulergamma", "exists", "exp",
        "exponentiale", "factorial", "factorof", "false", "floor", "fn", "forall", "gcd",
        "geq", "grad", "gt", "ident", "image", "imaginary", "imaginaryi", "implies", "in",
        "infinity", "int", "integers", "intersect", "interval", "inverse", "lambda",
        "laplacian", "lcm", "leq", "limit", "ln", "log", "logbase", "lowlimit", "lt",
        "maction", "maligngroup", "malignmark", "math", "matrix", "matrixrow", "max", "mean",
        "median", "menclose", "merror", "mfenced", "mfrac", "mglyph", "mi", "min", "minus",
        "mlabeledtr", "mlongdiv", "mmultiscripts", "mn", "mo", "mode", "moment", "momentabout",
        "mover", "mpadded", "mphantom", "mprescripts", "mroot", "mrow", "ms", "mscarries",
        "mscarry", "msgroup", "msline", "mspace", "msqrt", "msrow", "mstack", "mstyle", "msub",
        "msubsup", "msup", "mtable", "mtd", "mtext", "mtr", "munder", "munderover",
        "naturalnumbers", "neq", "none", "not", "notanumber", "notin", "notprsubset",
        "notsubset", "or", "otherwise", "outerproduct", "partialdiff", "pi", "piece",
        "piecewise", "plus", "power", "primes", "product", "prsubset", "quotient", "rationals",
        "real", "reals", "reln", "rem", "root", "scalarproduct", "sdev", "sec", "sech",
        "selector", "semantics", "sep", "set", "setdiff", "share", "sin", "sinh", "subset",
        "sum", "tan", "tanh", "tendsto", "times", "transpose", "true", "union", "uplimit",
        "variance", "vector", "vectorproduct", "xor"
    ]

    /// Review item A2: the MathML elements upstream's Assertions checker knows
    /// (MATHML_ELEMENTS: presentation MathML); any other MathML element is "a
    /// completely-unknown element", content MathML (apply, ci, cn, ...)
    /// included, which the schema allows but vnu.jar reports anyway.
    static let mathMLElements: Set<String> = [
        "annotation", "annotation-xml", "maction", "maligngroup", "malignmark", "math",
        "menclose", "merror", "mfenced", "mfrac", "mglyph", "mi", "mlabeledtr", "mlongdiv",
        "mmultiscripts", "mn", "mo", "mover", "mpadded", "mphantom", "mprescripts", "mroot",
        "mrow", "ms", "mscarries", "mscarry", "msgroup", "msline", "mspace", "msqrt", "msrow",
        "mstack", "mstyle", "msub", "msubsup", "msup", "mtable", "mtd", "mtext", "mtr",
        "munder", "munderover", "none", "semantics"
    ]

    /// Review item A2: the SVG elements upstream's Assertions checker knows
    /// (SVG_ELEMENTS, in their camelCase spelling); any other SVG element is
    /// "a completely-unknown element", and the schema checks none of its
    /// attributes.
    static let svgElements: Set<String> = [
        "a", "altGlyph", "altGlyphDef", "altGlyphItem", "animate", "animateColor",
        "animateMotion", "animateTransform", "circle", "clipPath", "color-profile", "cursor",
        "defs", "desc", "ellipse", "feBlend", "feColorMatrix", "feComponentTransfer",
        "feComposite", "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap",
        "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB", "feFuncG",
        "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology",
        "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile",
        "feTurbulence", "filter", "font", "font-face", "font-face-format", "font-face-name",
        "font-face-src", "font-face-uri", "foreignObject", "g", "glyph", "glyphRef", "hkern",
        "image", "line", "linearGradient", "marker", "mask", "metadata", "missing-glyph",
        "mpath", "path", "pattern", "polygon", "polyline", "radialGradient", "rect", "script",
        "set", "stop", "style", "svg", "switch", "symbol", "text", "textPath", "title", "tref",
        "tspan", "use", "view", "vkern"
    ]

    /// MathML elements that may only appear inside particular parents (in
    /// upstream's schema): anywhere else, they're "not allowed as child".
    static let mathMLRequiredParents: [String: Set<String>] = [
        "annotation": ["semantics"],
        "annotation-xml": ["semantics"],
        "mprescripts": ["mmultiscripts"],
        // (none is also an msrow, mscarries and mscarry child, in elementary
        // math: MsrowExpression in mathml3-presentation.rnc.)
        "none": ["mmultiscripts", "msrow", "mscarries", "mscarry"],
        "mtr": ["mtable"],
        "mlabeledtr": ["mtable"],
        "mtd": ["mtr", "mlabeledtr"],
        // Review item A2: the rest of the schema's elements that only some
        // parents take. Before A2 every MathML element was "not allowed",
        // which caught these by accident; once the vocabulary was known, an
        // <mglyph> or <msline> directly in <math> went unreported. mglyph is
        // token content (mi, mn, mo, ms, mtext) and content MathML's cn, ci
        // and csymbol content; sep is cn's; elementary math's rows, lines,
        // groups and carries go in mstack, mlongdiv or msgroup, and mscarry
        // in mscarries; piece and otherwise in piecewise (from
        // mathml3-presentation.rnc and mathml3-content.rnc).
        "mglyph": ["mi", "mn", "mo", "ms", "mtext", "cn", "ci", "csymbol"],
        "sep": ["cn"],
        "msline": ["mstack", "mlongdiv", "msgroup"],
        "msgroup": ["mstack", "mlongdiv", "msgroup"],
        "msrow": ["mstack", "mlongdiv", "msgroup"],
        "mscarries": ["mstack", "mlongdiv", "msgroup"],
        "mscarry": ["mscarries"],
        "piece": ["piecewise"],
        "otherwise": ["piecewise"]
    ]

    /// Review item A2: whether upstream's schema rejects a foreign element
    /// where it is ("not allowed as child"): an SVG element it doesn't know
    /// (its SVG schema and its Assertions list know the same elements), a
    /// MathML element the schema doesn't know, one in a parent that doesn't
    /// take it (mathMLRequiredParents), or a <math> inside MathML. Upstream
    /// reports nothing more inside such an element (see HTMLValidator's
    /// OpenElement.Flags). (For HTML in MathML, see tokenElementRejects.)
    static func schemaRejects(_ name: String, namespace: HTMLNamespace, parent: String?, parentNamespace: HTMLNamespace?) -> Bool {
        switch namespace {
        case .html:
            return false
        case .svg:
            return !svgElements.contains(displayName(name, namespace: namespace))
        case .mathML:
            // (A <math> as a MathML element's child: math isn't one of the
            // schema's MathML expressions, so "not allowed as child", except
            // in <mtext>, whose content vnu.jar's schema extends with HTML's
            // phrasing content, <math> included. A <math> in HTML, or in an
            // SVG integration point, is fine.)
            if !mathMLSchemaElements.contains(name) || ("math" == name && .mathML == parentNamespace && "mtext" != parent) {
                return true
            }
            if let allowedParents = mathMLRequiredParents[name] {
                return !allowedParents.contains(parent ?? "")
            }
            return false
        }
    }

    /// Review item A2: MathML's token elements other than <mtext> (mi, mn, mo
    /// and ms) take no HTML at all, not even an <svg>; mtext takes HTML's
    /// phrasing content (vnu.jar's schema extends its content with that), so
    /// what it doesn't take is flow content's blocks and the elements that
    /// belong only in particular parents.
    static let mathTokenElementsWithoutHTML: Set<String> = ["mi", "mn", "mo", "ms"]
    static let htmlNotAllowedInMText: Set<String> = HTMLVocabulary.flowButNotPhrasing.union([
        "caption", "col", "colgroup", "dd", "dt", "figcaption", "legend", "li", "optgroup", "option", "param", "rp",
        "rt", "source", "summary", "tbody", "td", "tfoot", "th", "thead", "tr", "track"
    ])

    /// Review item A2: whether upstream's schema rejects a tag processed as
    /// HTML (an HTML element, or the <svg> that starts foreign content) as a
    /// MathML token element's child: "Element “b” not allowed as child of
    /// “mi”". The token elements are MathML's text integration points, so the
    /// tree builder puts HTML elements in them, and the port used to accept
    /// them all. Upstream reports nothing more inside such an element. (For a
    /// <math>, see schemaRejects; mglyph and malignmark stay MathML.)
    static func tokenElementRejects(_ name: String, parent: String?, parentNamespace: HTMLNamespace?) -> Bool {
        guard .mathML == parentNamespace, let parent else {
            return false
        }
        return mathTokenElementsWithoutHTML.contains(parent) || ("mtext" == parent && htmlNotAllowedInMText.contains(name))
    }

    /// Whether a start tag seen in foreign content ends it.
    static func breaksOut(_ name: String, attributes: [HTMLAttribute]) -> Bool {
        if breakoutStartTags.contains(name) {
            return true
        }
        return "font" == name && attributes.contains { "color" == $0.name || "face" == $0.name || "size" == $0.name }
    }

    /// The namespace an <svg> or <math> start tag in HTML content begins, or
    /// nil for any other element (which is HTML).
    static func rootNamespace(of name: String) -> HTMLNamespace? {
        switch name {
        case "svg":
            return .svg
        case "math":
            return .mathML
        default:
            return nil
        }
    }

    /// The namespace of an element started inside a foreign element: the
    /// parent's, except that <svg> inside MathML annotation-xml starts SVG.
    static func namespace(ofChild name: String, inForeignElement parent: String, namespace: HTMLNamespace) -> HTMLNamespace {
        ("svg" == name && "annotation-xml" == parent) ? .svg : namespace
    }

    /// Whether a foreign element's children are HTML again: the HTML
    /// integration points (svg foreignObject, desc and title; MathML
    /// annotation-xml with an HTML encoding) and the MathML text integration
    /// points (mi, mo, mn, ms, mtext). Upstream's scope checks also stop at
    /// these, which is why HTML's implied end tags never reach past them.
    static func childrenAreHTML(_ name: String, namespace: HTMLNamespace, attributes: [HTMLAttribute]) -> Bool {
        switch namespace {
        case .html:
            return true
        case .svg:
            return "foreignobject" == name || "desc" == name || "title" == name
        case .mathML:
            if "annotation-xml" == name {
                // (Decoded, as upstream compares it; review item A2.)
                let encoding = attributes.first { "encoding" == $0.name }?.value.map { HTMLCharacterReferences.decode($0).lowercased() }
                return "text/html" == encoding || "application/xhtml+xml" == encoding
            }
            return mathMLTextIntegrationPoints.contains(name)
        }
    }
}
