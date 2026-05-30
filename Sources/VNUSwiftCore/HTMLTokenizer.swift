import Foundation

struct HTMLAttribute: Equatable {
    var name: String
    var value: String?
    var offset: Int
}

enum HTMLToken: Equatable {
    case startTag(name: String, attributes: [HTMLAttribute], selfClosing: Bool, offset: Int, length: Int)
    case endTag(name: String, offset: Int, length: Int)
    case doctype(offset: Int, length: Int)
    case bogusMarkup(offset: Int, length: Int)
}

final class HTMLTokenizer {
    private let source: String
    private let locations: SourceLocationMap

    init(source: String, locations: SourceLocationMap) {
        self.source = source
        self.locations = locations
    }

    func tokenize() -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "<" else {
                source.formIndex(after: &index)
                continue
            }
            let start = index
            if consumePrefix("<!--", from: &index) {
                skipUntil("-->", from: &index)
                continue
            }
            if consumePrefix("<!DOCTYPE", from: &index, caseInsensitive: true) {
                skipUntil(">", from: &index)
                let offset = locations.offset(of: start)
                tokens.append(.doctype(offset: offset, length: max(1, locations.offset(of: index) - offset)))
                continue
            }
            if consumePrefix("</", from: &index) {
                skipWhitespace(from: &index)
                let nameStart = index
                while index < source.endIndex, isNameCharacter(source[index]) {
                    source.formIndex(after: &index)
                }
                let name = String(source[nameStart..<index]).lowercased()
                skipUntil(">", from: &index)
                let offset = locations.offset(of: start)
                if name.isEmpty {
                    tokens.append(.bogusMarkup(offset: offset, length: max(1, locations.offset(of: index) - offset)))
                } else {
                    tokens.append(.endTag(name: name, offset: offset, length: max(1, locations.offset(of: index) - offset)))
                }
                continue
            }
            if consumePrefix("<!", from: &index) || consumePrefix("<?", from: &index) {
                skipUntil(">", from: &index)
                continue
            }
            source.formIndex(after: &index)
            guard index < source.endIndex, isNameStart(source[index]) else {
                let offset = locations.offset(of: start)
                tokens.append(.bogusMarkup(offset: offset, length: 1))
                continue
            }
            let nameStart = index
            while index < source.endIndex, isNameCharacter(source[index]) {
                source.formIndex(after: &index)
            }
            let name = String(source[nameStart..<index]).lowercased()
            var attributes: [HTMLAttribute] = []
            var selfClosing = false
            while index < source.endIndex {
                skipWhitespace(from: &index)
                guard index < source.endIndex else { break }
                if source[index] == ">" {
                    source.formIndex(after: &index)
                    break
                }
                if source[index] == "/" {
                    let slash = index
                    source.formIndex(after: &index)
                    skipWhitespace(from: &index)
                    if index < source.endIndex, source[index] == ">" {
                        selfClosing = true
                        source.formIndex(after: &index)
                        break
                    }
                    index = slash
                }
                let attrOffset = locations.offset(of: index)
                let attrNameStart = index
                while index < source.endIndex, isAttributeNameCharacter(source[index]) {
                    source.formIndex(after: &index)
                }
                let attrName = String(source[attrNameStart..<index]).lowercased()
                if attrName.isEmpty {
                    source.formIndex(after: &index)
                    continue
                }
                skipWhitespace(from: &index)
                var value: String?
                if index < source.endIndex, source[index] == "=" {
                    source.formIndex(after: &index)
                    skipWhitespace(from: &index)
                    value = parseAttributeValue(from: &index)
                }
                attributes.append(HTMLAttribute(name: attrName, value: value, offset: attrOffset))
            }
            let offset = locations.offset(of: start)
            tokens.append(.startTag(name: name, attributes: attributes, selfClosing: selfClosing, offset: offset, length: max(1, locations.offset(of: index) - offset)))
        }
        return tokens
    }

    private func parseAttributeValue(from index: inout String.Index) -> String {
        guard index < source.endIndex else { return "" }
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
            }
            return value
        }
        let valueStart = index
        while index < source.endIndex, !source[index].isWhitespace, source[index] != ">" {
            source.formIndex(after: &index)
        }
        return String(source[valueStart..<index])
    }

    private func skipWhitespace(from index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            source.formIndex(after: &index)
        }
    }

    private func skipUntil(_ needle: String, from index: inout String.Index) {
        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                index = source.index(index, offsetBy: needle.count, limitedBy: source.endIndex) ?? source.endIndex
                return
            }
            source.formIndex(after: &index)
        }
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
        !(character.isWhitespace || character == "=" || character == ">" || character == "/" || character == "\"" || character == "'")
    }
}

