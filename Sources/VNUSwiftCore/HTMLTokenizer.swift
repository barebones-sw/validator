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
        var tokens = sourceDiagnostics()
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
                    index = endRange.upperBound
                } else {
                    appendError("End of file inside comment.", at: start, length: source.utf16.distance(from: start.samePosition(in: source.utf16) ?? source.utf16.startIndex, to: source.utf16.endIndex), to: &tokens)
                    appendComment(from: commentStart, to: source.endIndex, to: &tokens)
                    index = source.endIndex
                }
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
        }
        return tokens
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

    private func sourceDiagnostics() -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "&" {
                appendCharacterReferenceDiagnostics(at: index, to: &tokens)
            }
            if let scalar = source[index].unicodeScalars.first {
                appendCodePointDiagnostics(scalar, at: index, to: &tokens)
            }
            source.formIndex(after: &index)
        }

        if source.localizedCaseInsensitiveContains("</src>") || source.localizedCaseInsensitiveContains("</style>") && source.localizedCaseInsensitiveContains("<script") {
            if let script = source.range(of: "<script", options: [.caseInsensitive]) {
                appendError("End of file seen when expecting text or an end tag.", at: script.lowerBound, length: 1, to: &tokens)
            }
        }
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
