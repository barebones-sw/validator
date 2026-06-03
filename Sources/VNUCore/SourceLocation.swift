import Foundation

public struct SourceLocation: Codable, Equatable, Sendable {
    public var firstLine: Int
    public var firstColumn: Int
    public var lastLine: Int
    public var lastColumn: Int

    public init(firstLine: Int, firstColumn: Int, lastLine: Int, lastColumn: Int) {
        self.firstLine = firstLine
        self.firstColumn = firstColumn
        self.lastLine = lastLine
        self.lastColumn = lastColumn
    }
}

public struct SourceExtract: Codable, Equatable, Sendable {
    public var text: String
    public var hiliteStart: Int
    public var hiliteLength: Int

    public init(text: String, hiliteStart: Int, hiliteLength: Int) {
        self.text = text
        self.hiliteStart = hiliteStart
        self.hiliteLength = hiliteLength
    }
}

public final class SourceLocationMap: @unchecked Sendable {
    private let source: String
    private let lineStarts: [String.UTF16View.Index]

    public init(_ source: String) {
        self.source = source
        var starts: [String.UTF16View.Index] = [source.utf16.startIndex]
        var index = source.utf16.startIndex
        while index < source.utf16.endIndex {
            let value = source.utf16[index]
            source.utf16.formIndex(after: &index)
            if value == 10 {
                starts.append(index)
            }
        }
        self.lineStarts = starts
    }

    public func offset(of index: String.Index) -> Int {
        guard let utf16Index = index.samePosition(in: source.utf16) else {
            return source.utf16.count
        }
        return source.utf16.distance(from: source.utf16.startIndex, to: utf16Index)
    }

    public func location(offset: Int, length: Int = 1) -> SourceLocation {
        let start = max(0, min(offset, source.utf16.count))
        let end = max(start, min(start + max(length, 1), source.utf16.count))
        let first = lineAndColumn(for: start)
        let last = lineAndColumn(for: end)
        return SourceLocation(
            firstLine: first.line,
            firstColumn: first.column,
            lastLine: last.line,
            lastColumn: last.column
        )
    }

    public func extract(offset: Int, length: Int = 1, context: Int = 80) -> SourceExtract {
        let boundedOffset = max(0, min(offset, source.utf16.count))
        let startOffset = max(0, boundedOffset - context / 2)
        let endOffset = min(source.utf16.count, boundedOffset + max(length, 1) + context / 2)
        let start = stringIndex(atUTF16Offset: startOffset, bias: .backward)
        let end = stringIndex(atUTF16Offset: endOffset, bias: .forward)
        let text = String(source[start..<end])
        return SourceExtract(
            text: text,
            hiliteStart: boundedOffset - startOffset,
            hiliteLength: max(length, 1)
        )
    }

    private func lineAndColumn(for offset: Int) -> (line: Int, column: Int) {
        var low = 0
        var high = lineStarts.count
        let target = stringUTF16Index(at: offset)
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] <= target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let lineIndex = max(0, low - 1)
        let lineStart = lineStarts[lineIndex]
        let column = source.utf16.distance(from: lineStart, to: target) + 1
        return (lineIndex + 1, column)
    }

    private enum BoundaryBias {
        case backward
        case forward
    }

    private func stringIndex(atUTF16Offset offset: Int, bias: BoundaryBias) -> String.Index {
        var utf16Index = stringUTF16Index(at: offset)
        if let index = String.Index(utf16Index, within: source) {
            return index
        }

        switch bias {
        case .backward:
            while utf16Index > source.utf16.startIndex {
                source.utf16.formIndex(before: &utf16Index)
                if let index = String.Index(utf16Index, within: source) {
                    return index
                }
            }
            return source.startIndex
        case .forward:
            while utf16Index < source.utf16.endIndex {
                source.utf16.formIndex(after: &utf16Index)
                if let index = String.Index(utf16Index, within: source) {
                    return index
                }
            }
            return source.endIndex
        }
    }

    private func stringUTF16Index(at offset: Int) -> String.UTF16View.Index {
        source.utf16.index(source.utf16.startIndex, offsetBy: max(0, min(offset, source.utf16.count)))
    }
}
