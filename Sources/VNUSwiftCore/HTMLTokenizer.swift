import Foundation
import VNUCore

struct HTMLAttribute: Equatable, Sendable {
    var name: String
    var value: String?
    var offset: Int
}

enum HTMLToken: Equatable, Sendable {
    case startTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool, offset: Int, length: Int)
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

    func tokenize() -> [HTMLToken] {
        // Case 554591: the whole-source diagnostics (character references and
        // forbidden code points) are now computed after the main loop, which
        // collects the ranges where the HTML tokenizer never parses character
        // references: raw text and script contents, comments and CDATA
        // sections. "&#" in JavaScript or "&nbsp" in CSS used to be errors.
        var tokens: [HTMLToken] = []
        var noCharacterReferenceRanges: [Range<String.Index>] = []
        // Which namespace the tree builder is in (HTML, or inline SVG/MathML);
        // see ForeignContentTracker.
        var foreignContent = ForeignContentTracker()
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
            if foreignContent.isInForeignContent, consumePrefix("<![CDATA[", from: &index) {
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
                    foreignContent.endTag(name)
                }
                continue
            }
            if consumePrefix("<?", from: &index) {
                appendError("Saw \u{201c}<?\u{201d}. Probable cause: Attempt to use an XML processing instruction in HTML. (XML processing instructions are not supported in HTML.)", at: start, length: 2, to: &tokens)
                _ = skipUntil(">", from: &index)
                continue
            }
            if consumePrefix("<!", from: &index) {
                appendError("Bogus comment.", at: start, length: 2, to: &tokens)
                _ = skipUntil(">", from: &index)
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
            while index < source.endIndex {
                let whitespaceStart = index
                skipWhitespace(from: &index)
                let hadWhitespace = whitespaceStart != index
                guard index < source.endIndex else { break }
                if source[index] == ">" {
                    source.formIndex(after: &index)
                    tagClosed = true
                    break
                }
                if source[index] == "/" {
                    let slash = index
                    source.formIndex(after: &index)
                    let afterSlash = index
                    skipWhitespace(from: &index)
                    if index < source.endIndex, source[index] == ">" {
                        if afterSlash != index {
                            appendError("A slash was not immediately followed by \u{201c}>\u{201d}.", at: slash, length: max(1, locations.offset(of: index) - locations.offset(of: slash)), to: &tokens)
                        }
                        selfClosing = true
                        source.formIndex(after: &index)
                        tagClosed = true
                        break
                    }
                    index = slash
                }
                if !attributes.isEmpty, !hadWhitespace {
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
                    value = parseAttributeValue(from: &index, tokens: &tokens)
                }
                attributes.append(HTMLAttribute(name: attrName, value: value, offset: attrOffset))
            }
            if !tagClosed {
                let message = attributes.isEmpty ? "Saw end of file without the previous tag ending with \u{201c}>\u{201d}. Ignoring tag." : "End of file occurred in an attribute name. Ignoring tag."
                appendError(message, at: start, length: max(1, locations.offset(of: source.endIndex) - locations.offset(of: start)), to: &tokens)
            }
            let offset = locations.offset(of: start)
            tokens.append(.startTag(name: name, attributes: attributes, selfClosing: selfClosing, offset: offset, length: max(1, locations.offset(of: index) - offset)))

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
            // A self-closing tag is left alone: in HTML the slash is ignored
            // and the contents would still be text, but HTMLValidator doesn't
            // put self-closing elements on its stack, so its end tag would
            // then be reported as stray. (The self-closing error itself is
            // reported elsewhere.)
            let isHTMLElement = foreignContent.startTag(name, attributes: attributes, selfClosing: selfClosing)
            if tagClosed, !selfClosing, isHTMLElement, let kind = TextContentKind(elementName: name) {
                consumeTextContent(of: name, kind: kind, from: &index, to: &tokens, noCharacterReferenceRanges: &noCharacterReferenceRanges)
            }
        }
        return sourceDiagnostics(skippingCharacterReferencesIn: noCharacterReferenceRanges) + tokens
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
        let remaining = source[index...]
        let matches: Bool
        if caseInsensitive {
            matches = remaining.lowercased().hasPrefix(prefix.lowercased())
        } else {
            matches = remaining.hasPrefix(prefix)
        }
        if matches {
            index = source.index(index, offsetBy: prefix.count, limitedBy: source.endIndex) ?? source.endIndex
        }
        return matches
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
    /// tokenize()) are the places where "&" is just a character.
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
        guard let value = UInt32(digits, radix: isHex ? 16 : 10) else { return }
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
        case 0xFDD0:
            appendError("Character reference expands to a permanently unassigned code point.", at: index, length: 1, to: &tokens)
        default:
            if value < 0x20 || value == 0x7F {
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

/// Case 554591: a minimal model of which namespace the tree builder is in, so
/// the tokenizer can tell HTML content from inline SVG/MathML ("foreign
/// content") without a full tree builder. It matters in two places:
/// <script>, <style>, <title>, <textarea> etc. are text-only elements only
/// in HTML (in SVG they're foreign elements with ordinary markup inside),
/// and "<![CDATA[" starts a CDATA section only in foreign content.
///
/// Tracked: open svg/math subtrees, the HTML integration points inside them
/// (whose children are HTML again), the start tags that break out of foreign
/// content, and the </p> and </br> end tags that do the same. Valid documents
/// always close their <svg>/<math> elements explicitly, which is what keeps
/// this simple model in step with the real tree.
private struct ForeignContentTracker {
    private enum Namespace {
        case svg
        case math
    }

    private struct Entry {
        var name: String
        var namespace: Namespace
        /// HTML integration points (svg foreignObject/desc/title, MathML
        /// annotation-xml with an HTML encoding) and MathML text integration
        /// points (mi, mo, mn, ms, mtext) have HTML children.
        var childrenAreHTML: Bool
    }

    private var entries: [Entry] = []

    /// Start tags that end foreign content (TreeBuilder's "breakout" list);
    /// upstream reports them as HTML start tags in a foreign context and pops
    /// back to the nearest HTML context. (<font> only with color/face/size.)
    private static let breakoutStartTags: Set<String> = [
        "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div",
        "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p",
        "pre", "ruby", "s", "small", "span", "strike", "strong", "sub", "sup",
        "table", "tt", "u", "ul", "var"
    ]

    /// Whether the next token is parsed as foreign content.
    var isInForeignContent: Bool {
        guard let last = entries.last else {
            return false
        }
        return !last.childrenAreHTML
    }

    /// Records a start tag (tag names arrive lowercased) and returns whether
    /// the element it starts is in the HTML namespace.
    mutating func startTag(_ name: String, attributes: [HTMLAttribute], selfClosing: Bool) -> Bool {
        if let current = entries.last, !current.childrenAreHTML {
            if Self.breaksOutOfForeignContent(name, attributes: attributes) {
                popToHTMLContext()
            } else {
                // A foreign element in the current namespace, except that
                // <svg> inside MathML annotation-xml starts SVG.
                let namespace: Namespace = ("svg" == name && "annotation-xml" == current.name) ? .svg : current.namespace
                if !selfClosing {
                    entries.append(Entry(name: name, namespace: namespace, childrenAreHTML: Self.isIntegrationPoint(name, namespace: namespace, attributes: attributes)))
                }
                return false
            }
        }

        // HTML content: top level, or inside an integration point.
        if "svg" == name || "math" == name {
            if !selfClosing {
                entries.append(Entry(name: name, namespace: ("svg" == name) ? .svg : .math, childrenAreHTML: false))
            }
            return false
        }
        return true
    }

    /// Records an end tag (name lowercased).
    mutating func endTag(_ name: String) {
        guard !entries.isEmpty else {
            return
        }
        if isInForeignContent, "p" == name || "br" == name {
            popToHTMLContext()
            return
        }
        if let index = entries.lastIndex(where: { name == $0.name }) {
            entries.removeSubrange(index...)
        }
    }

    private mutating func popToHTMLContext() {
        while let last = entries.last, !last.childrenAreHTML {
            entries.removeLast()
        }
    }

    private static func breaksOutOfForeignContent(_ name: String, attributes: [HTMLAttribute]) -> Bool {
        if breakoutStartTags.contains(name) {
            return true
        }
        return "font" == name && attributes.contains { "color" == $0.name || "face" == $0.name || "size" == $0.name }
    }

    private static func isIntegrationPoint(_ name: String, namespace: Namespace, attributes: [HTMLAttribute]) -> Bool {
        switch namespace {
        case .svg:
            return "foreignobject" == name || "desc" == name || "title" == name
        case .math:
            if "annotation-xml" == name {
                let encoding = attributes.first { "encoding" == $0.name }?.value?.lowercased()
                return "text/html" == encoding || "application/xhtml+xml" == encoding
            }
            return ["mi", "mo", "mn", "ms", "mtext"].contains(name)
        }
    }
}
