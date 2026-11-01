import Foundation
import VNUCore

struct HTMLAttribute: Equatable, Sendable {
    var name: String
    var value: String?
    var offset: Int
}

/// Case 554591 (A7): what HTMLCharacterReferences.consume tells, in order,
/// as it reads (see HTMLCharacterReferences.Event): a sink, so that the
/// events of a long text run are handled as they come rather than all kept.
protocol HTMLCharacterReferenceEventSink {
    mutating func note(_ event: HTMLCharacterReferences.Event)
}

/// Review item A2: attribute values are kept as written, character references
/// and all, but upstream's checks see values its tokenizer has already
/// decoded. A check that compares or parses a value has to decode it first:
/// A2's namespace check reported xmlns="http&#x3a;//www.w3.org/1999/xhtml" as
/// a bad value, and its SVG path data check rejected d="M0 0&#10;L1 1", both
/// of which vnu.jar accepts.
///
/// Case 554591 (A7): this is now upstream's own reading of references, its
/// tokenizer's (Tokenizer.java: CONSUME_CHARACTER_REFERENCE,
/// CHARACTER_REFERENCE_HILO_LOOKUP, CHARACTER_REFERENCE_TAIL, CONSUME_NCR,
/// DECIMAL_NRC_LOOP, HEX_NCR_LOOP, handleNcrValue and eof()), under the XML
/// violation policies vnu.jar sets, used both to decode values and text and,
/// by the tokenizer, to report what upstream's tokenizer reports (see
/// consume). It used to know the numeric references and the 45 named ones
/// that stand for an ASCII character, each with its semicolon, and nothing
/// else; and the tokenizer's diagnostics came from a separate pass over the
/// whole source that knew five names. So id="caf&eacute;" and id="café"
/// weren't the same ID, &#128; wasn't the euro sign, an &amp without its
/// semicolon at the end of a value stayed as written, &copy 2020 in text got
/// no message, href="/s?a=1&lt=2" got a false one, and so did the HTML
/// standard's own entity table, where &gt; is followed by a combining mark.
/// The rules, each checked against vnu.jar on thousands of documents (the
/// case's A7/A21 notes):
/// - A reference is read in text (data and RCDATA) and in attribute values;
///   the tokenizer calls consume only there.
/// - "&" followed by a space, tab, line break, form feed, "<", "&", NUL,
///   ";", an attribute value's quote (or ">" for an unquoted value), or
///   nothing, or by anything but "#" or an ASCII letter, is just "&".
/// - A name is the longest name in HTML's table (2,231 of them, 106 legacy
///   ones without their semicolon) that the text starts with; what was read
///   past it, looking for a longer one, is text again (&notit; is "¬it;").
///   With no name at all, the text stays as written, and only a search that
///   failed at a ";" is reported (&x; and &nop;, but not &xyz;).
/// - A legacy name without its semicolon is decoded, with a message; but in
///   an attribute value, one followed by "=" or an ASCII letter or digit
///   stays as written, silently, so href="/s?a=1&copy=2" is just that.
/// - Numeric references: ASCII digits only; past U+10FFFF the value stops
///   growing; 0, surrogates and anything past U+10FFFF become U+FFFD;
///   &#128; to &#159; map to their windows-1252 characters, but for five
///   that stay as they are; &#12; becomes a space, silently (vnu.jar's
///   content-space policy alters the form feed, while a literal one stays);
///   &#13; stays a carriage return (while a literal one becomes a line
///   feed); control characters and noncharacters are kept, with an error.
/// - In an attribute value, "No digits after “X”." names the value decoded
///   so far, and empties it: upstream's tokenizer makes the message from its
///   value buffer, clearing the buffer as it does (strBufToString), so
///   vnu.jar's checkers see width="12&#;34" as "&#;34".
enum HTMLCharacterReferences {
    /// Where a reference is read, which decides two of upstream's rules: an
    /// attribute value's "additional allowed character" (its quote, or ">"
    /// for an unquoted value), after which "&" is just "&", and the
    /// attribute exception for a legacy name without its semicolon; and
    /// whether "No digits after" names a value (text names nothing).
    enum Context: Equatable, Sendable {
        case text
        case attribute(additional: Unicode.Scalar)
    }

    /// Case 554591 (A7): one of upstream's tokenizer messages about a
    /// reference. lastIndex is an index into the scalars consumed (the count
    /// of them for the character that follows), where upstream's locator is
    /// when it reports, which vnu.jar gives as the message's last column: the
    /// ";" of a numeric reference, the character that stopped the digits or a
    /// name's search, the last character at the end of the input, or the "&"
    /// itself for the two messages reported at the ampersand. (From A7's
    /// review: readIndex is where the tokenizer has read to when it reports,
    /// for the order of the messages about the characters it reads: the
    /// same, but for those two, which it reports once it has read the
    /// character that stopped the name.)
    struct Diagnostic: Equatable, Sendable {
        var message: String
        var isWarning: Bool
        var lastIndex: Int
        var readIndex: Int
    }

    /// Case 554591 (A7): what vnu.jar's location recorder notes, in order, as
    /// upstream's tokenizer reads text: the place before an "&" where it hands
    /// on the text pending before it (placeBefore, at the UTF-16 unit before
    /// the "&"); each place where it hands on what a reference produced
    /// (place); and each message (whose last place it notes too). A message's
    /// first place is one past the latest place noted before its last one
    /// (MessageEmitterAdapter.messageWithRange), so the tokenizer needs these
    /// to place messages as vnu.jar does. In an attribute value only the
    /// messages count: a value produces no events of its own.
    enum Event: Equatable, Sendable {
        case placeBefore(Int)
        case place(Int)
        case diagnostic(Diagnostic)
    }

    /// Case 554591 (A7): the sink for callers that only decode.
    struct NoEvents: HTMLCharacterReferenceEventSink {
        mutating func note(_ event: Event) {}
    }

    /// Case 554591 (A7): a decoded array of scalars as a string. (From A7's
    /// review: made from its UTF-8, as String(String.UnicodeScalarView(_:))
    /// went through the standard library's generic append, with a malloc and
    /// a free for each scalar, so that decoding a long value took about nine
    /// times as long as it had to.)
    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count)
        for scalar in scalars {
            UTF8.encode(scalar) { bytes.append($0) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// An attribute value as upstream's tokenizer hands it to the checkers:
    /// literal carriage returns as line feeds (its input stream normalizes
    /// them), a literal NUL as U+FFFD (with "Saw U+0000 in stream.", which
    /// the port doesn't give yet), and every reference read as above, the
    /// attribute exception and the "No digits" emptying included.
    static func decodeAttributeValue(_ value: String) -> String {
        // The usual case: nothing to decode, and no copy made. (Case 554591,
        // A14 review: looked for in the UTF-8 bytes, where an "&", a CR or a
        // NUL can only be itself; contains("&") was Foundation's substring
        // search, which took a good part of the time the ARIA rules added
        // once they decoded every role value.)
        guard value.utf8.contains(where: { UInt8(ascii: "&") == $0 || UInt8(ascii: "\r") == $0 || 0 == $0 }) else {
            return value
        }
        var unused = false
        var sink = NoEvents()
        return string(consume(Array(value.unicodeScalars), context: .attribute(additional: "\""), following: "\"", privateUseWarned: &unused, collectingEvents: false, sink: &sink))
    }

    /// Case 554591 (A7): decode(_:) used to keep a reference to a form feed
    /// as one where decodeAttributeValue(_:) made it a space (item 12 found
    /// that upstream does the latter, and changed only the checks it was
    /// working on); upstream does it for every value, so the two are now the
    /// same, and SVG path data and duplicate IDs with &#12; are read as
    /// vnu.jar reads them.
    static func decode(_ value: String) -> String {
        decodeAttributeValue(value)
    }

    /// Case 554591 (A7): text as upstream's tokenizer hands it to the tree
    /// builder and the checkers: the same as an attribute value but without
    /// the attribute exception (in text, &copy2020 is "©2020") or the "No
    /// digits" emptying, which are a value's, and with NULs left as they are,
    /// for the callers that drop them where upstream's tree builder does.
    /// Carriage returns become line feeds, as in values.
    static func decodeText(_ text: String) -> String {
        guard text.utf8.contains(where: { UInt8(ascii: "&") == $0 || UInt8(ascii: "\r") == $0 }) else {
            return text
        }
        var unused = false
        var sink = NoEvents()
        return string(consume(Array(text.unicodeScalars), context: .text, following: nil, privateUseWarned: &unused, collectingEvents: false, sink: &sink))
    }

    /// The reference starting at `start` (an "&") in text: its first
    /// character, and the index just past what it consumed. nil if the "&"
    /// doesn't start one (it's just "&"). (Case 554591, A20: for the <time>
    /// text check, which has to know whether text starts with a reference to
    /// a line feed; see HTMLGeneralAttributeChecker.droppingLeadingLineFeed.
    /// A7: read as upstream's tokenizer reads it, so &#10 without its
    /// semicolon counts too; &NewLine; has no legacy form, so &NewLine
    /// doesn't.)
    static func reference(in scalars: [Unicode.Scalar], at start: Int) -> (scalar: Unicode.Scalar, next: Int)? {
        var unused = false
        var output: [Unicode.Scalar] = []
        var sink = NoEvents()
        let read = readReference(scalars, at: start, context: .text, following: nil, privateUseWarned: &unused, collectingEvents: false, output: &output, sink: &sink)
        guard read.decoded, let first = output.first else {
            return nil
        }
        return (first, read.next)
    }

    /// Case 554591 (A7): reads `scalars` (a text run, or an attribute value
    /// as written) as upstream's tokenizer does, with `following` the
    /// character after them (an end tag's "<", a value's closing quote or the
    /// character that ends an unquoted value; nil at the end of the input),
    /// which can stop a reference. Returns the decoded text and, if
    /// collectingEvents, tells `sink` upstream's messages and the places its
    /// recorder notes, in order, as it reads (see Event). privateUseWarned is
    /// the document's: vnu.jar warns about the Private Use Area once per
    /// document.
    static func consume<Sink: HTMLCharacterReferenceEventSink>(_ scalars: [Unicode.Scalar], context: Context, following: Unicode.Scalar?, privateUseWarned: inout Bool, collectingEvents: Bool, sink: inout Sink) -> [Unicode.Scalar] {
        // (The output goes into an array, made into a string once at the end:
        // the standard library's String.UnicodeScalarView.append(contentsOf:)
        // makes a new string each time, which made a long text run's decoding
        // quadratic, a megabyte of "&amp;"s taking seconds; and the reading of
        // each reference writes into it, and tells the sink, directly, as an
        // array per reference made a value of thousands of references slow,
        // such as the headingoffset of item 3's review.)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        let isAttribute = .text != context
        // Where the text pending after the last reference starts, as
        // upstream's tokenizer tracks it: an "&" with text pending before it
        // hands that text on first, which the recorder notes at the unit
        // before the "&".
        var pending = 0
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if "&" != scalar {
                // Upstream's input stream turns CRLF and a lone CR into one
                // LF before its tokenizer sees them; and in an attribute
                // value a literal NUL becomes U+FFFD (in text, the tree
                // builder decides, so it stays for the callers).
                if "\r" == scalar {
                    output.append("\n")
                    let next = index + ((index + 1 < scalars.count && "\n" == scalars[index + 1]) ? 2 : 1)
                    // (Case 554591, A7's review: in text, upstream's tokenizer
                    // hands on what it has at a carriage return, and then a
                    // line feed for it (emitCarriageReturn), which the
                    // recorder notes, at the carriage return; what follows is
                    // new text. So a code point's message after it starts
                    // past it, on the next line.)
                    if !isAttribute {
                        if collectingEvents {
                            sink.note(.place(index))
                        }
                        pending = next
                    }
                    index = next
                    continue
                }
                output.append(isAttribute && "\u{0}" == scalar ? "\u{FFFD}" : scalar)
                index += 1
                continue
            }
            if collectingEvents, !isAttribute, pending < index {
                sink.note(.placeBefore(index))
            }
            let read = readReference(scalars, at: index, context: context, following: following, privateUseWarned: &privateUseWarned, collectingEvents: collectingEvents, output: &output, sink: &sink)
            // Upstream reports before it hands the result on.
            if collectingEvents, !isAttribute, let emitAt = read.emitAt {
                sink.note(.place(emitAt))
            }
            pending = read.next
            index = read.next
        }
        return output
    }

    /// Reads the reference at `amp` (an "&"), as upstream's tokenizer reads it
    /// from its CONSUME_CHARACTER_REFERENCE state, appending what it produces
    /// to `output` (the decoded characters, or what was written when it isn't
    /// a reference or isn't decoded) and, if collectingEvents, telling `sink`
    /// its messages. Returns where reading resumes; where upstream's tokenizer
    /// is when it hands the result on, which the recorder notes in text (nil
    /// when it hands nothing on: an attribute value's exception, which stays
    /// in the value as written); and whether it decoded a reference.
    private static func readReference<Sink: HTMLCharacterReferenceEventSink>(
        _ scalars: [Unicode.Scalar],
        at amp: Int,
        context: Context,
        following: Unicode.Scalar?,
        privateUseWarned: inout Bool,
        collectingEvents: Bool,
        output: inout [Unicode.Scalar],
        sink: inout Sink
    ) -> (next: Int, emitAt: Int?, decoded: Bool) {
        let count = scalars.count
        let isAttribute = .text != context
        func at(_ index: Int) -> Unicode.Scalar? {
            index < count ? scalars[index] : following
        }
        // Where upstream's locator is when the input ends inside a reference:
        // on the character that follows (a closing quote, an end tag's "<"),
        // or on the last character at the end of the input.
        let endPlace = (nil == following) ? count - 1 : count
        func place(_ index: Int, _ scalar: Unicode.Scalar?) -> Int {
            nil == scalar ? endPlace : index
        }
        func report(_ message: String, _ lastIndex: Int, readAt readIndex: Int, _ sink: inout Sink) {
            if collectingEvents {
                sink.note(.diagnostic(Diagnostic(message: message, isWarning: false, lastIndex: lastIndex, readIndex: readIndex)))
            }
        }
        let afterAmp = amp + 1
        let first = at(afterAmp)
        var additional: Unicode.Scalar?
        if case let .attribute(quote) = context {
            additional = quote
        }
        guard let first, !isReferenceStopper(first), first != additional else {
            output.append("&")
            return (afterAmp, place(afterAmp, first), false)
        }
        if "#" == first {
            return readNumericReference(scalars, at: amp, isAttribute: isAttribute, scalarAt: at, placeOf: place, privateUseWarned: &privateUseWarned, collectingEvents: collectingEvents, output: &output, sink: &sink)
        }
        guard isASCIILetter(first) else {
            output.append("&")
            return (afterAmp, afterAmp, false)
        }
        // A name: read on while some name in the table starts with what's
        // been read, remembering the longest full name on the way; a ";"
        // that completes a name ends the search.
        let table = namedTable
        var (low, high) = table.narrow(0, table.names.count, depth: 0, byte: UInt8(first.value))
        var depth = 1
        var next = afterAmp + 1
        var candidate: (entry: Int, length: Int)?
        var stopper: Unicode.Scalar?
        while true {
            let scalar = at(next)
            if low < high, depth == table.names[low].count {
                candidate = (low, depth)
            }
            if let scalar, scalar.isASCII, low < high {
                let (narrowLow, narrowHigh) = table.narrow(low, high, depth: depth, byte: UInt8(scalar.value))
                if narrowLow < narrowHigh {
                    low = narrowLow
                    high = narrowHigh
                    depth += 1
                    next += 1
                    if ";" == scalar {
                        candidate = (low, depth)
                        stopper = nil
                        break
                    }
                    continue
                }
            }
            stopper = scalar
            break
        }
        let stopPlace = place(next, stopper)
        let didNotStart = "\u{201c}&\u{201d} did not start a character reference. (\u{201c}&\u{201d} probably should have been escaped as \u{201c}&amp;\u{201d}.)"
        let readEnd = min(next, count)
        guard let candidate else {
            // No name: what was read stays as written, and only a search
            // that failed at a ";" is reported.
            if ";" == stopper {
                report(didNotStart, amp, readAt: stopPlace, &sink)
            }
            output.append(contentsOf: scalars[amp..<readEnd])
            return (next, stopPlace, false)
        }
        let endedBySemicolon = UInt8(ascii: ";") == table.names[candidate.entry].last
        if !endedBySemicolon {
            if isAttribute {
                // The attribute exception: a legacy name followed by "=" or
                // an ASCII letter or digit isn't decoded (the first
                // character read past it, or the one that stopped the
                // search). Upstream checks only for letters and digits at the
                // end of the input, where nothing else can follow.
                let afterName = (candidate.length < depth) ? scalars[afterAmp + candidate.length] : stopper
                if let afterName, isASCIIAlphanumeric(afterName) || "=" == afterName {
                    if ";" == stopper {
                        report(didNotStart, amp, readAt: stopPlace, &sink)
                    }
                    output.append(contentsOf: scalars[amp..<readEnd])
                    return (next, nil, false)
                }
                report("The string following \u{201c}&\u{201d} was interpreted as a character reference. (\u{201c}&\u{201d} probably should have been escaped as \u{201c}&amp;\u{201d}.)", amp, readAt: stopPlace, &sink)
            } else {
                report("Named character reference was not terminated by a semicolon. (Or \u{201c}&\u{201d} should have been escaped as \u{201c}&amp;\u{201d}.)", stopPlace, readAt: stopPlace, &sink)
            }
        }
        let value = table.values[candidate.entry]
        output.append(value.first)
        if let second = value.second {
            output.append(second)
        }
        // What was read past the name, looking for a longer one, is text.
        output.append(contentsOf: scalars[(afterAmp + candidate.length)..<readEnd])
        // (After a name its ";" ended, upstream's tokenizer is on the ";";
        // otherwise on the character that stopped the search.)
        return (next, (nil == stopper && endedBySemicolon) ? next - 1 : stopPlace, true)
    }

    /// The numeric reference at `amp` ("&#"): see readReference.
    private static func readNumericReference<Sink: HTMLCharacterReferenceEventSink>(
        _ scalars: [Unicode.Scalar],
        at amp: Int,
        isAttribute: Bool,
        scalarAt at: (Int) -> Unicode.Scalar?,
        placeOf place: (Int, Unicode.Scalar?) -> Int,
        privateUseWarned: inout Bool,
        collectingEvents: Bool,
        output: inout [Unicode.Scalar],
        sink: inout Sink
    ) -> (next: Int, emitAt: Int?, decoded: Bool) {
        var next = amp + 2
        let marker = at(next)
        let isHexadecimal = "x" == marker || "X" == marker
        if isHexadecimal {
            next += 1
        }
        let digitsStart = next
        var value: UInt32 = 0
        while let scalar = at(next), let digit = digitValue(of: scalar, radix: isHexadecimal ? 16 : 10) {
            // Past U+10FFFF no more digits can bring it back into range, so
            // upstream stops accumulating there, which also means this can't
            // overflow (see review item A10's &#4294967296;).
            if value <= 0x10FFFF {
                value = value * (isHexadecimal ? 16 : 10) + digit
            }
            next += 1
        }
        let scalar = at(next)
        let endedBySemicolon = ";" == scalar
        let lastIndex = endedBySemicolon ? next : place(next, scalar)
        guard digitsStart < next else {
            // No digits: "No digits after “X”.", where in an attribute value X
            // is the value decoded so far, which upstream's tokenizer then
            // empties (see the type's comment); in text it's empty. What was
            // written stays, with the ";" right after "&#" or "&#x".
            if collectingEvents {
                let valueSoFar = isAttribute ? string(output) : ""
                sink.note(.diagnostic(Diagnostic(message: "No digits after \u{201c}\(scrubbedForMessage(valueSoFar))\u{201d}.", isWarning: false, lastIndex: lastIndex, readIndex: lastIndex)))
            }
            if isAttribute {
                output.removeAll(keepingCapacity: true)
            }
            output.append(contentsOf: scalars[amp..<min(next, scalars.count)])
            if endedBySemicolon {
                output.append(";")
                return (next + 1, next, false)
            }
            return (next, lastIndex, false)
        }
        if !endedBySemicolon, collectingEvents {
            sink.note(.diagnostic(Diagnostic(message: "Character reference was not terminated by a semicolon.", isWarning: false, lastIndex: lastIndex, readIndex: lastIndex)))
        }
        appendNumericValue(value, lastIndex: lastIndex, privateUseWarned: &privateUseWarned, collectingEvents: collectingEvents, output: &output, sink: &sink)
        return (endedBySemicolon ? next + 1 : next, lastIndex, true)
    }

    /// What upstream's handleNcrValue delivers for a numeric reference's
    /// value, and its message, under vnu.jar's content-space policy
    /// (ALTER_INFOSET: a form feed becomes a space) and its non-XML-character
    /// policy (ALLOW: control characters and noncharacters are kept).
    private static func appendNumericValue<Sink: HTMLCharacterReferenceEventSink>(_ value: UInt32, lastIndex: Int, privateUseWarned: inout Bool, collectingEvents: Bool, output: inout [Unicode.Scalar], sink: inout Sink) {
        func report(_ message: String, warning: Bool) {
            if collectingEvents {
                sink.note(.diagnostic(Diagnostic(message: message, isWarning: warning, lastIndex: lastIndex, readIndex: lastIndex)))
            }
        }
        if value <= 0xFFFF {
            if (0x80...0x9F).contains(value) {
                report("A numeric character reference expanded to the C1 controls range.", warning: false)
                output.append(windows1252[Int(value - 0x80)])
                return
            }
            if 0x0C == value {
                output.append(" ")
                return
            }
            if 0 == value {
                report("Character reference expands to zero.", warning: false)
                output.append("\u{FFFD}")
                return
            }
            if 0xD800 == (value & 0xF800) {
                report("Character reference expands to a surrogate.", warning: false)
                output.append("\u{FFFD}")
                return
            }
            if 0x0D == value {
                report("A numeric character reference expanded to carriage return.", warning: false)
            } else if value <= 0x08 || 0x0B == value || (0x0E...0x1F).contains(value) || 0x7F == value {
                report("Character reference expands to a control character (\(uPlus(value))).", warning: false)
            } else if (0xFDD0...0xFDEF).contains(value) {
                report("Character reference expands to a permanently unassigned code point.", warning: false)
            } else if 0xFFFE == (value & 0xFFFE) {
                report("Character reference expands to a non-character (\(uPlus(value))).", warning: false)
            } else if isPrivateUse(value), !privateUseWarned {
                privateUseWarned = true
                report(privateUseWarning, warning: true)
            }
            output.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            return
        }
        if value <= 0x10FFFF {
            if isPrivateUse(value), !privateUseWarned {
                privateUseWarned = true
                report(privateUseWarning, warning: true)
            }
            if 0xFFFE == (value & 0xFFFE) {
                report("Character reference expands to an astral non-character (\(uPlus(value))).", warning: false)
            }
            output.append(Unicode.Scalar(value) ?? "\u{FFFD}")
            return
        }
        report("Character reference outside the permissible Unicode range.", warning: false)
        output.append("\u{FFFD}")
    }

    /// Case 554591 (A7): the warning upstream gives once per document for a
    /// Private Use Area character, written as a reference or literally.
    static let privateUseWarning = "Document uses the Unicode Private Use Area(s), which should not be used in publicly exchanged documents. (Charmod C073)"

    static func isPrivateUse(_ value: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(value) || (0xF0000...0xFFFFD).contains(value) || (0x100000...0x10FFFD).contains(value)
    }

    /// Document text quoted in a message, as vnu.jar prints it
    /// (MessageEmitterAdapter.scrub with CharacterUtil.PRUDENT): without the
    /// C0 controls but tab, line feed and carriage return, U+007F to U+009F,
    /// U+FEFF, U+FDD0 to U+FDDF, and U+10FC01 and up (PRUDENT's
    /// "􏰀" reads as the one code point U+10FC00, so its kept range
    /// ends there); in NFC; and with a space before it when it starts with a
    /// combining character. (Upstream counts a few characters with combining
    /// class 0 as composing too, such as the Hangul vowel jamo; they're left
    /// out here.)
    static func scrubbedForMessage(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard 0x09 == value || 0x0A == value || 0x0D == value || (0x20...0x10FC00).contains(value) else {
                continue
            }
            guard !(0x7F...0x9F).contains(value), 0xFEFF != value, !(0xFDD0...0xFDDF).contains(value) else {
                continue
            }
            kept.append(scalar)
        }
        let normalized = String(kept).precomposedStringWithCanonicalMapping
        if let first = normalized.unicodeScalars.first, .notReordered != first.properties.canonicalCombiningClass {
            return " " + normalized
        }
        return normalized
    }

    /// The characters after "&" that never start a reference (with an
    /// attribute value's quote, checked separately): upstream's
    /// CONSUME_CHARACTER_REFERENCE state hands these back silently. (A CR
    /// counts as the line feed the input stream makes it.)
    private static func isReferenceStopper(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0C, 0x0D, 0x3C, 0x26, 0x00, 0x3B:
            return true
        default:
            return false
        }
    }

    private static func uPlus(_ value: UInt32) -> String {
        // ErrorReportingTokenizer.toUPlusString: lowercase hex, at least four
        // digits.
        let hex = String(value, radix: 16)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
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

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (0x30...0x39).contains(scalar.value)
    }

    /// NamedCharacters.WINDOWS_1252: what &#128; to &#159; stand for. 0x81,
    /// 0x8D, 0x8F, 0x90 and 0x9D, which windows-1252 leaves unassigned, stay
    /// as they are.
    private static let windows1252: [Unicode.Scalar] = [
        "\u{20AC}", "\u{0081}", "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", "\u{008D}", "\u{017D}", "\u{008F}",
        "\u{0090}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", "\u{009D}", "\u{017E}", "\u{0178}",
    ]

    /// Case 554591 (A7): HTML's named references, sorted (as bytes, which is
    /// upstream's order: digits, ";", then letters), with their characters.
    struct NamedTable: Sendable {
        struct Value: Sendable {
            var first: Unicode.Scalar
            var second: Unicode.Scalar?
        }

        let names: [[UInt8]]
        let values: [Value]

        /// The entries in low..<high (which all start with the same `depth`
        /// bytes) whose byte at `depth` is `byte`: as upstream narrows its hi
        /// and lo bounds one character at a time. In such a range the names
        /// that are only `depth` bytes long come first, so the byte at `depth`
        /// (with those taken as below any byte) only grows.
        func narrow(_ low: Int, _ high: Int, depth: Int, byte: UInt8) -> (Int, Int) {
            func key(_ index: Int) -> Int {
                depth < names[index].count ? Int(names[index][depth]) : -1
            }
            var lower = low
            var upper = high
            while lower < upper {
                let middle = (lower + upper) / 2
                if key(middle) < Int(byte) {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            var end = lower
            upper = high
            while end < upper {
                let middle = (end + upper) / 2
                if key(middle) <= Int(byte) {
                    end = middle + 1
                } else {
                    upper = middle
                }
            }
            return (lower, end)
        }
    }

    /// The table, parsed from namedReferenceTable the first time it's needed.
    static let namedTable: NamedTable = {
        var entries: [([UInt8], NamedTable.Value)] = []
        for line in namedReferenceTable.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard 2 <= fields.count, let first = UInt32(fields[1], radix: 16).flatMap(Unicode.Scalar.init) else {
                continue
            }
            let second = (3 == fields.count) ? UInt32(fields[2], radix: 16).flatMap(Unicode.Scalar.init) : nil
            entries.append((Array(fields[0].utf8), NamedTable.Value(first: first, second: second)))
        }
        entries.sort { $0.0.lexicographicallyPrecedes($1.0) }
        return NamedTable(names: entries.map(\.0), values: entries.map(\.1))
    }()

    /// Case 554591 (A7): HTML's named character references, from upstream's
    /// own table (NamedCharacters.java, read out of vnu.jar; the same as the
    /// WHATWG list): one line per name, the name as written (with its ";"
    /// unless it's one of the 106 legacy names that may go without), a
    /// space, and the one or two code points it stands for, in hex. (A
    /// string to parse rather than an array literal, which would take the
    /// compiler a long time to type-check.)
    private static let namedReferenceTable = """
        AElig C6
        AElig; C6
        AMP 26
        AMP; 26
        Aacute C1
        Aacute; C1
        Abreve; 102
        Acirc C2
        Acirc; C2
        Acy; 410
        Afr; 1D504
        Agrave C0
        Agrave; C0
        Alpha; 391
        Amacr; 100
        And; 2A53
        Aogon; 104
        Aopf; 1D538
        ApplyFunction; 2061
        Aring C5
        Aring; C5
        Ascr; 1D49C
        Assign; 2254
        Atilde C3
        Atilde; C3
        Auml C4
        Auml; C4
        Backslash; 2216
        Barv; 2AE7
        Barwed; 2306
        Bcy; 411
        Because; 2235
        Bernoullis; 212C
        Beta; 392
        Bfr; 1D505
        Bopf; 1D539
        Breve; 2D8
        Bscr; 212C
        Bumpeq; 224E
        CHcy; 427
        COPY A9
        COPY; A9
        Cacute; 106
        Cap; 22D2
        CapitalDifferentialD; 2145
        Cayleys; 212D
        Ccaron; 10C
        Ccedil C7
        Ccedil; C7
        Ccirc; 108
        Cconint; 2230
        Cdot; 10A
        Cedilla; B8
        CenterDot; B7
        Cfr; 212D
        Chi; 3A7
        CircleDot; 2299
        CircleMinus; 2296
        CirclePlus; 2295
        CircleTimes; 2297
        ClockwiseContourIntegral; 2232
        CloseCurlyDoubleQuote; 201D
        CloseCurlyQuote; 2019
        Colon; 2237
        Colone; 2A74
        Congruent; 2261
        Conint; 222F
        ContourIntegral; 222E
        Copf; 2102
        Coproduct; 2210
        CounterClockwiseContourIntegral; 2233
        Cross; 2A2F
        Cscr; 1D49E
        Cup; 22D3
        CupCap; 224D
        DD; 2145
        DDotrahd; 2911
        DJcy; 402
        DScy; 405
        DZcy; 40F
        Dagger; 2021
        Darr; 21A1
        Dashv; 2AE4
        Dcaron; 10E
        Dcy; 414
        Del; 2207
        Delta; 394
        Dfr; 1D507
        DiacriticalAcute; B4
        DiacriticalDot; 2D9
        DiacriticalDoubleAcute; 2DD
        DiacriticalGrave; 60
        DiacriticalTilde; 2DC
        Diamond; 22C4
        DifferentialD; 2146
        Dopf; 1D53B
        Dot; A8
        DotDot; 20DC
        DotEqual; 2250
        DoubleContourIntegral; 222F
        DoubleDot; A8
        DoubleDownArrow; 21D3
        DoubleLeftArrow; 21D0
        DoubleLeftRightArrow; 21D4
        DoubleLeftTee; 2AE4
        DoubleLongLeftArrow; 27F8
        DoubleLongLeftRightArrow; 27FA
        DoubleLongRightArrow; 27F9
        DoubleRightArrow; 21D2
        DoubleRightTee; 22A8
        DoubleUpArrow; 21D1
        DoubleUpDownArrow; 21D5
        DoubleVerticalBar; 2225
        DownArrow; 2193
        DownArrowBar; 2913
        DownArrowUpArrow; 21F5
        DownBreve; 311
        DownLeftRightVector; 2950
        DownLeftTeeVector; 295E
        DownLeftVector; 21BD
        DownLeftVectorBar; 2956
        DownRightTeeVector; 295F
        DownRightVector; 21C1
        DownRightVectorBar; 2957
        DownTee; 22A4
        DownTeeArrow; 21A7
        Downarrow; 21D3
        Dscr; 1D49F
        Dstrok; 110
        ENG; 14A
        ETH D0
        ETH; D0
        Eacute C9
        Eacute; C9
        Ecaron; 11A
        Ecirc CA
        Ecirc; CA
        Ecy; 42D
        Edot; 116
        Efr; 1D508
        Egrave C8
        Egrave; C8
        Element; 2208
        Emacr; 112
        EmptySmallSquare; 25FB
        EmptyVerySmallSquare; 25AB
        Eogon; 118
        Eopf; 1D53C
        Epsilon; 395
        Equal; 2A75
        EqualTilde; 2242
        Equilibrium; 21CC
        Escr; 2130
        Esim; 2A73
        Eta; 397
        Euml CB
        Euml; CB
        Exists; 2203
        ExponentialE; 2147
        Fcy; 424
        Ffr; 1D509
        FilledSmallSquare; 25FC
        FilledVerySmallSquare; 25AA
        Fopf; 1D53D
        ForAll; 2200
        Fouriertrf; 2131
        Fscr; 2131
        GJcy; 403
        GT 3E
        GT; 3E
        Gamma; 393
        Gammad; 3DC
        Gbreve; 11E
        Gcedil; 122
        Gcirc; 11C
        Gcy; 413
        Gdot; 120
        Gfr; 1D50A
        Gg; 22D9
        Gopf; 1D53E
        GreaterEqual; 2265
        GreaterEqualLess; 22DB
        GreaterFullEqual; 2267
        GreaterGreater; 2AA2
        GreaterLess; 2277
        GreaterSlantEqual; 2A7E
        GreaterTilde; 2273
        Gscr; 1D4A2
        Gt; 226B
        HARDcy; 42A
        Hacek; 2C7
        Hat; 5E
        Hcirc; 124
        Hfr; 210C
        HilbertSpace; 210B
        Hopf; 210D
        HorizontalLine; 2500
        Hscr; 210B
        Hstrok; 126
        HumpDownHump; 224E
        HumpEqual; 224F
        IEcy; 415
        IJlig; 132
        IOcy; 401
        Iacute CD
        Iacute; CD
        Icirc CE
        Icirc; CE
        Icy; 418
        Idot; 130
        Ifr; 2111
        Igrave CC
        Igrave; CC
        Im; 2111
        Imacr; 12A
        ImaginaryI; 2148
        Implies; 21D2
        Int; 222C
        Integral; 222B
        Intersection; 22C2
        InvisibleComma; 2063
        InvisibleTimes; 2062
        Iogon; 12E
        Iopf; 1D540
        Iota; 399
        Iscr; 2110
        Itilde; 128
        Iukcy; 406
        Iuml CF
        Iuml; CF
        Jcirc; 134
        Jcy; 419
        Jfr; 1D50D
        Jopf; 1D541
        Jscr; 1D4A5
        Jsercy; 408
        Jukcy; 404
        KHcy; 425
        KJcy; 40C
        Kappa; 39A
        Kcedil; 136
        Kcy; 41A
        Kfr; 1D50E
        Kopf; 1D542
        Kscr; 1D4A6
        LJcy; 409
        LT 3C
        LT; 3C
        Lacute; 139
        Lambda; 39B
        Lang; 27EA
        Laplacetrf; 2112
        Larr; 219E
        Lcaron; 13D
        Lcedil; 13B
        Lcy; 41B
        LeftAngleBracket; 27E8
        LeftArrow; 2190
        LeftArrowBar; 21E4
        LeftArrowRightArrow; 21C6
        LeftCeiling; 2308
        LeftDoubleBracket; 27E6
        LeftDownTeeVector; 2961
        LeftDownVector; 21C3
        LeftDownVectorBar; 2959
        LeftFloor; 230A
        LeftRightArrow; 2194
        LeftRightVector; 294E
        LeftTee; 22A3
        LeftTeeArrow; 21A4
        LeftTeeVector; 295A
        LeftTriangle; 22B2
        LeftTriangleBar; 29CF
        LeftTriangleEqual; 22B4
        LeftUpDownVector; 2951
        LeftUpTeeVector; 2960
        LeftUpVector; 21BF
        LeftUpVectorBar; 2958
        LeftVector; 21BC
        LeftVectorBar; 2952
        Leftarrow; 21D0
        Leftrightarrow; 21D4
        LessEqualGreater; 22DA
        LessFullEqual; 2266
        LessGreater; 2276
        LessLess; 2AA1
        LessSlantEqual; 2A7D
        LessTilde; 2272
        Lfr; 1D50F
        Ll; 22D8
        Lleftarrow; 21DA
        Lmidot; 13F
        LongLeftArrow; 27F5
        LongLeftRightArrow; 27F7
        LongRightArrow; 27F6
        Longleftarrow; 27F8
        Longleftrightarrow; 27FA
        Longrightarrow; 27F9
        Lopf; 1D543
        LowerLeftArrow; 2199
        LowerRightArrow; 2198
        Lscr; 2112
        Lsh; 21B0
        Lstrok; 141
        Lt; 226A
        Map; 2905
        Mcy; 41C
        MediumSpace; 205F
        Mellintrf; 2133
        Mfr; 1D510
        MinusPlus; 2213
        Mopf; 1D544
        Mscr; 2133
        Mu; 39C
        NJcy; 40A
        Nacute; 143
        Ncaron; 147
        Ncedil; 145
        Ncy; 41D
        NegativeMediumSpace; 200B
        NegativeThickSpace; 200B
        NegativeThinSpace; 200B
        NegativeVeryThinSpace; 200B
        NestedGreaterGreater; 226B
        NestedLessLess; 226A
        NewLine; A
        Nfr; 1D511
        NoBreak; 2060
        NonBreakingSpace; A0
        Nopf; 2115
        Not; 2AEC
        NotCongruent; 2262
        NotCupCap; 226D
        NotDoubleVerticalBar; 2226
        NotElement; 2209
        NotEqual; 2260
        NotEqualTilde; 2242 338
        NotExists; 2204
        NotGreater; 226F
        NotGreaterEqual; 2271
        NotGreaterFullEqual; 2267 338
        NotGreaterGreater; 226B 338
        NotGreaterLess; 2279
        NotGreaterSlantEqual; 2A7E 338
        NotGreaterTilde; 2275
        NotHumpDownHump; 224E 338
        NotHumpEqual; 224F 338
        NotLeftTriangle; 22EA
        NotLeftTriangleBar; 29CF 338
        NotLeftTriangleEqual; 22EC
        NotLess; 226E
        NotLessEqual; 2270
        NotLessGreater; 2278
        NotLessLess; 226A 338
        NotLessSlantEqual; 2A7D 338
        NotLessTilde; 2274
        NotNestedGreaterGreater; 2AA2 338
        NotNestedLessLess; 2AA1 338
        NotPrecedes; 2280
        NotPrecedesEqual; 2AAF 338
        NotPrecedesSlantEqual; 22E0
        NotReverseElement; 220C
        NotRightTriangle; 22EB
        NotRightTriangleBar; 29D0 338
        NotRightTriangleEqual; 22ED
        NotSquareSubset; 228F 338
        NotSquareSubsetEqual; 22E2
        NotSquareSuperset; 2290 338
        NotSquareSupersetEqual; 22E3
        NotSubset; 2282 20D2
        NotSubsetEqual; 2288
        NotSucceeds; 2281
        NotSucceedsEqual; 2AB0 338
        NotSucceedsSlantEqual; 22E1
        NotSucceedsTilde; 227F 338
        NotSuperset; 2283 20D2
        NotSupersetEqual; 2289
        NotTilde; 2241
        NotTildeEqual; 2244
        NotTildeFullEqual; 2247
        NotTildeTilde; 2249
        NotVerticalBar; 2224
        Nscr; 1D4A9
        Ntilde D1
        Ntilde; D1
        Nu; 39D
        OElig; 152
        Oacute D3
        Oacute; D3
        Ocirc D4
        Ocirc; D4
        Ocy; 41E
        Odblac; 150
        Ofr; 1D512
        Ograve D2
        Ograve; D2
        Omacr; 14C
        Omega; 3A9
        Omicron; 39F
        Oopf; 1D546
        OpenCurlyDoubleQuote; 201C
        OpenCurlyQuote; 2018
        Or; 2A54
        Oscr; 1D4AA
        Oslash D8
        Oslash; D8
        Otilde D5
        Otilde; D5
        Otimes; 2A37
        Ouml D6
        Ouml; D6
        OverBar; 203E
        OverBrace; 23DE
        OverBracket; 23B4
        OverParenthesis; 23DC
        PartialD; 2202
        Pcy; 41F
        Pfr; 1D513
        Phi; 3A6
        Pi; 3A0
        PlusMinus; B1
        Poincareplane; 210C
        Popf; 2119
        Pr; 2ABB
        Precedes; 227A
        PrecedesEqual; 2AAF
        PrecedesSlantEqual; 227C
        PrecedesTilde; 227E
        Prime; 2033
        Product; 220F
        Proportion; 2237
        Proportional; 221D
        Pscr; 1D4AB
        Psi; 3A8
        QUOT 22
        QUOT; 22
        Qfr; 1D514
        Qopf; 211A
        Qscr; 1D4AC
        RBarr; 2910
        REG AE
        REG; AE
        Racute; 154
        Rang; 27EB
        Rarr; 21A0
        Rarrtl; 2916
        Rcaron; 158
        Rcedil; 156
        Rcy; 420
        Re; 211C
        ReverseElement; 220B
        ReverseEquilibrium; 21CB
        ReverseUpEquilibrium; 296F
        Rfr; 211C
        Rho; 3A1
        RightAngleBracket; 27E9
        RightArrow; 2192
        RightArrowBar; 21E5
        RightArrowLeftArrow; 21C4
        RightCeiling; 2309
        RightDoubleBracket; 27E7
        RightDownTeeVector; 295D
        RightDownVector; 21C2
        RightDownVectorBar; 2955
        RightFloor; 230B
        RightTee; 22A2
        RightTeeArrow; 21A6
        RightTeeVector; 295B
        RightTriangle; 22B3
        RightTriangleBar; 29D0
        RightTriangleEqual; 22B5
        RightUpDownVector; 294F
        RightUpTeeVector; 295C
        RightUpVector; 21BE
        RightUpVectorBar; 2954
        RightVector; 21C0
        RightVectorBar; 2953
        Rightarrow; 21D2
        Ropf; 211D
        RoundImplies; 2970
        Rrightarrow; 21DB
        Rscr; 211B
        Rsh; 21B1
        RuleDelayed; 29F4
        SHCHcy; 429
        SHcy; 428
        SOFTcy; 42C
        Sacute; 15A
        Sc; 2ABC
        Scaron; 160
        Scedil; 15E
        Scirc; 15C
        Scy; 421
        Sfr; 1D516
        ShortDownArrow; 2193
        ShortLeftArrow; 2190
        ShortRightArrow; 2192
        ShortUpArrow; 2191
        Sigma; 3A3
        SmallCircle; 2218
        Sopf; 1D54A
        Sqrt; 221A
        Square; 25A1
        SquareIntersection; 2293
        SquareSubset; 228F
        SquareSubsetEqual; 2291
        SquareSuperset; 2290
        SquareSupersetEqual; 2292
        SquareUnion; 2294
        Sscr; 1D4AE
        Star; 22C6
        Sub; 22D0
        Subset; 22D0
        SubsetEqual; 2286
        Succeeds; 227B
        SucceedsEqual; 2AB0
        SucceedsSlantEqual; 227D
        SucceedsTilde; 227F
        SuchThat; 220B
        Sum; 2211
        Sup; 22D1
        Superset; 2283
        SupersetEqual; 2287
        Supset; 22D1
        THORN DE
        THORN; DE
        TRADE; 2122
        TSHcy; 40B
        TScy; 426
        Tab; 9
        Tau; 3A4
        Tcaron; 164
        Tcedil; 162
        Tcy; 422
        Tfr; 1D517
        Therefore; 2234
        Theta; 398
        ThickSpace; 205F 200A
        ThinSpace; 2009
        Tilde; 223C
        TildeEqual; 2243
        TildeFullEqual; 2245
        TildeTilde; 2248
        Topf; 1D54B
        TripleDot; 20DB
        Tscr; 1D4AF
        Tstrok; 166
        Uacute DA
        Uacute; DA
        Uarr; 219F
        Uarrocir; 2949
        Ubrcy; 40E
        Ubreve; 16C
        Ucirc DB
        Ucirc; DB
        Ucy; 423
        Udblac; 170
        Ufr; 1D518
        Ugrave D9
        Ugrave; D9
        Umacr; 16A
        UnderBar; 5F
        UnderBrace; 23DF
        UnderBracket; 23B5
        UnderParenthesis; 23DD
        Union; 22C3
        UnionPlus; 228E
        Uogon; 172
        Uopf; 1D54C
        UpArrow; 2191
        UpArrowBar; 2912
        UpArrowDownArrow; 21C5
        UpDownArrow; 2195
        UpEquilibrium; 296E
        UpTee; 22A5
        UpTeeArrow; 21A5
        Uparrow; 21D1
        Updownarrow; 21D5
        UpperLeftArrow; 2196
        UpperRightArrow; 2197
        Upsi; 3D2
        Upsilon; 3A5
        Uring; 16E
        Uscr; 1D4B0
        Utilde; 168
        Uuml DC
        Uuml; DC
        VDash; 22AB
        Vbar; 2AEB
        Vcy; 412
        Vdash; 22A9
        Vdashl; 2AE6
        Vee; 22C1
        Verbar; 2016
        Vert; 2016
        VerticalBar; 2223
        VerticalLine; 7C
        VerticalSeparator; 2758
        VerticalTilde; 2240
        VeryThinSpace; 200A
        Vfr; 1D519
        Vopf; 1D54D
        Vscr; 1D4B1
        Vvdash; 22AA
        Wcirc; 174
        Wedge; 22C0
        Wfr; 1D51A
        Wopf; 1D54E
        Wscr; 1D4B2
        Xfr; 1D51B
        Xi; 39E
        Xopf; 1D54F
        Xscr; 1D4B3
        YAcy; 42F
        YIcy; 407
        YUcy; 42E
        Yacute DD
        Yacute; DD
        Ycirc; 176
        Ycy; 42B
        Yfr; 1D51C
        Yopf; 1D550
        Yscr; 1D4B4
        Yuml; 178
        ZHcy; 416
        Zacute; 179
        Zcaron; 17D
        Zcy; 417
        Zdot; 17B
        ZeroWidthSpace; 200B
        Zeta; 396
        Zfr; 2128
        Zopf; 2124
        Zscr; 1D4B5
        aacute E1
        aacute; E1
        abreve; 103
        ac; 223E
        acE; 223E 333
        acd; 223F
        acirc E2
        acirc; E2
        acute B4
        acute; B4
        acy; 430
        aelig E6
        aelig; E6
        af; 2061
        afr; 1D51E
        agrave E0
        agrave; E0
        alefsym; 2135
        aleph; 2135
        alpha; 3B1
        amacr; 101
        amalg; 2A3F
        amp 26
        amp; 26
        and; 2227
        andand; 2A55
        andd; 2A5C
        andslope; 2A58
        andv; 2A5A
        ang; 2220
        ange; 29A4
        angle; 2220
        angmsd; 2221
        angmsdaa; 29A8
        angmsdab; 29A9
        angmsdac; 29AA
        angmsdad; 29AB
        angmsdae; 29AC
        angmsdaf; 29AD
        angmsdag; 29AE
        angmsdah; 29AF
        angrt; 221F
        angrtvb; 22BE
        angrtvbd; 299D
        angsph; 2222
        angst; C5
        angzarr; 237C
        aogon; 105
        aopf; 1D552
        ap; 2248
        apE; 2A70
        apacir; 2A6F
        ape; 224A
        apid; 224B
        apos; 27
        approx; 2248
        approxeq; 224A
        aring E5
        aring; E5
        ascr; 1D4B6
        ast; 2A
        asymp; 2248
        asympeq; 224D
        atilde E3
        atilde; E3
        auml E4
        auml; E4
        awconint; 2233
        awint; 2A11
        bNot; 2AED
        backcong; 224C
        backepsilon; 3F6
        backprime; 2035
        backsim; 223D
        backsimeq; 22CD
        barvee; 22BD
        barwed; 2305
        barwedge; 2305
        bbrk; 23B5
        bbrktbrk; 23B6
        bcong; 224C
        bcy; 431
        bdquo; 201E
        becaus; 2235
        because; 2235
        bemptyv; 29B0
        bepsi; 3F6
        bernou; 212C
        beta; 3B2
        beth; 2136
        between; 226C
        bfr; 1D51F
        bigcap; 22C2
        bigcirc; 25EF
        bigcup; 22C3
        bigodot; 2A00
        bigoplus; 2A01
        bigotimes; 2A02
        bigsqcup; 2A06
        bigstar; 2605
        bigtriangledown; 25BD
        bigtriangleup; 25B3
        biguplus; 2A04
        bigvee; 22C1
        bigwedge; 22C0
        bkarow; 290D
        blacklozenge; 29EB
        blacksquare; 25AA
        blacktriangle; 25B4
        blacktriangledown; 25BE
        blacktriangleleft; 25C2
        blacktriangleright; 25B8
        blank; 2423
        blk12; 2592
        blk14; 2591
        blk34; 2593
        block; 2588
        bne; 3D 20E5
        bnequiv; 2261 20E5
        bnot; 2310
        bopf; 1D553
        bot; 22A5
        bottom; 22A5
        bowtie; 22C8
        boxDL; 2557
        boxDR; 2554
        boxDl; 2556
        boxDr; 2553
        boxH; 2550
        boxHD; 2566
        boxHU; 2569
        boxHd; 2564
        boxHu; 2567
        boxUL; 255D
        boxUR; 255A
        boxUl; 255C
        boxUr; 2559
        boxV; 2551
        boxVH; 256C
        boxVL; 2563
        boxVR; 2560
        boxVh; 256B
        boxVl; 2562
        boxVr; 255F
        boxbox; 29C9
        boxdL; 2555
        boxdR; 2552
        boxdl; 2510
        boxdr; 250C
        boxh; 2500
        boxhD; 2565
        boxhU; 2568
        boxhd; 252C
        boxhu; 2534
        boxminus; 229F
        boxplus; 229E
        boxtimes; 22A0
        boxuL; 255B
        boxuR; 2558
        boxul; 2518
        boxur; 2514
        boxv; 2502
        boxvH; 256A
        boxvL; 2561
        boxvR; 255E
        boxvh; 253C
        boxvl; 2524
        boxvr; 251C
        bprime; 2035
        breve; 2D8
        brvbar A6
        brvbar; A6
        bscr; 1D4B7
        bsemi; 204F
        bsim; 223D
        bsime; 22CD
        bsol; 5C
        bsolb; 29C5
        bsolhsub; 27C8
        bull; 2022
        bullet; 2022
        bump; 224E
        bumpE; 2AAE
        bumpe; 224F
        bumpeq; 224F
        cacute; 107
        cap; 2229
        capand; 2A44
        capbrcup; 2A49
        capcap; 2A4B
        capcup; 2A47
        capdot; 2A40
        caps; 2229 FE00
        caret; 2041
        caron; 2C7
        ccaps; 2A4D
        ccaron; 10D
        ccedil E7
        ccedil; E7
        ccirc; 109
        ccups; 2A4C
        ccupssm; 2A50
        cdot; 10B
        cedil B8
        cedil; B8
        cemptyv; 29B2
        cent A2
        cent; A2
        centerdot; B7
        cfr; 1D520
        chcy; 447
        check; 2713
        checkmark; 2713
        chi; 3C7
        cir; 25CB
        cirE; 29C3
        circ; 2C6
        circeq; 2257
        circlearrowleft; 21BA
        circlearrowright; 21BB
        circledR; AE
        circledS; 24C8
        circledast; 229B
        circledcirc; 229A
        circleddash; 229D
        cire; 2257
        cirfnint; 2A10
        cirmid; 2AEF
        cirscir; 29C2
        clubs; 2663
        clubsuit; 2663
        colon; 3A
        colone; 2254
        coloneq; 2254
        comma; 2C
        commat; 40
        comp; 2201
        compfn; 2218
        complement; 2201
        complexes; 2102
        cong; 2245
        congdot; 2A6D
        conint; 222E
        copf; 1D554
        coprod; 2210
        copy A9
        copy; A9
        copysr; 2117
        crarr; 21B5
        cross; 2717
        cscr; 1D4B8
        csub; 2ACF
        csube; 2AD1
        csup; 2AD0
        csupe; 2AD2
        ctdot; 22EF
        cudarrl; 2938
        cudarrr; 2935
        cuepr; 22DE
        cuesc; 22DF
        cularr; 21B6
        cularrp; 293D
        cup; 222A
        cupbrcap; 2A48
        cupcap; 2A46
        cupcup; 2A4A
        cupdot; 228D
        cupor; 2A45
        cups; 222A FE00
        curarr; 21B7
        curarrm; 293C
        curlyeqprec; 22DE
        curlyeqsucc; 22DF
        curlyvee; 22CE
        curlywedge; 22CF
        curren A4
        curren; A4
        curvearrowleft; 21B6
        curvearrowright; 21B7
        cuvee; 22CE
        cuwed; 22CF
        cwconint; 2232
        cwint; 2231
        cylcty; 232D
        dArr; 21D3
        dHar; 2965
        dagger; 2020
        daleth; 2138
        darr; 2193
        dash; 2010
        dashv; 22A3
        dbkarow; 290F
        dblac; 2DD
        dcaron; 10F
        dcy; 434
        dd; 2146
        ddagger; 2021
        ddarr; 21CA
        ddotseq; 2A77
        deg B0
        deg; B0
        delta; 3B4
        demptyv; 29B1
        dfisht; 297F
        dfr; 1D521
        dharl; 21C3
        dharr; 21C2
        diam; 22C4
        diamond; 22C4
        diamondsuit; 2666
        diams; 2666
        die; A8
        digamma; 3DD
        disin; 22F2
        div; F7
        divide F7
        divide; F7
        divideontimes; 22C7
        divonx; 22C7
        djcy; 452
        dlcorn; 231E
        dlcrop; 230D
        dollar; 24
        dopf; 1D555
        dot; 2D9
        doteq; 2250
        doteqdot; 2251
        dotminus; 2238
        dotplus; 2214
        dotsquare; 22A1
        doublebarwedge; 2306
        downarrow; 2193
        downdownarrows; 21CA
        downharpoonleft; 21C3
        downharpoonright; 21C2
        drbkarow; 2910
        drcorn; 231F
        drcrop; 230C
        dscr; 1D4B9
        dscy; 455
        dsol; 29F6
        dstrok; 111
        dtdot; 22F1
        dtri; 25BF
        dtrif; 25BE
        duarr; 21F5
        duhar; 296F
        dwangle; 29A6
        dzcy; 45F
        dzigrarr; 27FF
        eDDot; 2A77
        eDot; 2251
        eacute E9
        eacute; E9
        easter; 2A6E
        ecaron; 11B
        ecir; 2256
        ecirc EA
        ecirc; EA
        ecolon; 2255
        ecy; 44D
        edot; 117
        ee; 2147
        efDot; 2252
        efr; 1D522
        eg; 2A9A
        egrave E8
        egrave; E8
        egs; 2A96
        egsdot; 2A98
        el; 2A99
        elinters; 23E7
        ell; 2113
        els; 2A95
        elsdot; 2A97
        emacr; 113
        empty; 2205
        emptyset; 2205
        emptyv; 2205
        emsp13; 2004
        emsp14; 2005
        emsp; 2003
        eng; 14B
        ensp; 2002
        eogon; 119
        eopf; 1D556
        epar; 22D5
        eparsl; 29E3
        eplus; 2A71
        epsi; 3B5
        epsilon; 3B5
        epsiv; 3F5
        eqcirc; 2256
        eqcolon; 2255
        eqsim; 2242
        eqslantgtr; 2A96
        eqslantless; 2A95
        equals; 3D
        equest; 225F
        equiv; 2261
        equivDD; 2A78
        eqvparsl; 29E5
        erDot; 2253
        erarr; 2971
        escr; 212F
        esdot; 2250
        esim; 2242
        eta; 3B7
        eth F0
        eth; F0
        euml EB
        euml; EB
        euro; 20AC
        excl; 21
        exist; 2203
        expectation; 2130
        exponentiale; 2147
        fallingdotseq; 2252
        fcy; 444
        female; 2640
        ffilig; FB03
        fflig; FB00
        ffllig; FB04
        ffr; 1D523
        filig; FB01
        fjlig; 66 6A
        flat; 266D
        fllig; FB02
        fltns; 25B1
        fnof; 192
        fopf; 1D557
        forall; 2200
        fork; 22D4
        forkv; 2AD9
        fpartint; 2A0D
        frac12 BD
        frac12; BD
        frac13; 2153
        frac14 BC
        frac14; BC
        frac15; 2155
        frac16; 2159
        frac18; 215B
        frac23; 2154
        frac25; 2156
        frac34 BE
        frac34; BE
        frac35; 2157
        frac38; 215C
        frac45; 2158
        frac56; 215A
        frac58; 215D
        frac78; 215E
        frasl; 2044
        frown; 2322
        fscr; 1D4BB
        gE; 2267
        gEl; 2A8C
        gacute; 1F5
        gamma; 3B3
        gammad; 3DD
        gap; 2A86
        gbreve; 11F
        gcirc; 11D
        gcy; 433
        gdot; 121
        ge; 2265
        gel; 22DB
        geq; 2265
        geqq; 2267
        geqslant; 2A7E
        ges; 2A7E
        gescc; 2AA9
        gesdot; 2A80
        gesdoto; 2A82
        gesdotol; 2A84
        gesl; 22DB FE00
        gesles; 2A94
        gfr; 1D524
        gg; 226B
        ggg; 22D9
        gimel; 2137
        gjcy; 453
        gl; 2277
        glE; 2A92
        gla; 2AA5
        glj; 2AA4
        gnE; 2269
        gnap; 2A8A
        gnapprox; 2A8A
        gne; 2A88
        gneq; 2A88
        gneqq; 2269
        gnsim; 22E7
        gopf; 1D558
        grave; 60
        gscr; 210A
        gsim; 2273
        gsime; 2A8E
        gsiml; 2A90
        gt 3E
        gt; 3E
        gtcc; 2AA7
        gtcir; 2A7A
        gtdot; 22D7
        gtlPar; 2995
        gtquest; 2A7C
        gtrapprox; 2A86
        gtrarr; 2978
        gtrdot; 22D7
        gtreqless; 22DB
        gtreqqless; 2A8C
        gtrless; 2277
        gtrsim; 2273
        gvertneqq; 2269 FE00
        gvnE; 2269 FE00
        hArr; 21D4
        hairsp; 200A
        half; BD
        hamilt; 210B
        hardcy; 44A
        harr; 2194
        harrcir; 2948
        harrw; 21AD
        hbar; 210F
        hcirc; 125
        hearts; 2665
        heartsuit; 2665
        hellip; 2026
        hercon; 22B9
        hfr; 1D525
        hksearow; 2925
        hkswarow; 2926
        hoarr; 21FF
        homtht; 223B
        hookleftarrow; 21A9
        hookrightarrow; 21AA
        hopf; 1D559
        horbar; 2015
        hscr; 1D4BD
        hslash; 210F
        hstrok; 127
        hybull; 2043
        hyphen; 2010
        iacute ED
        iacute; ED
        ic; 2063
        icirc EE
        icirc; EE
        icy; 438
        iecy; 435
        iexcl A1
        iexcl; A1
        iff; 21D4
        ifr; 1D526
        igrave EC
        igrave; EC
        ii; 2148
        iiiint; 2A0C
        iiint; 222D
        iinfin; 29DC
        iiota; 2129
        ijlig; 133
        imacr; 12B
        image; 2111
        imagline; 2110
        imagpart; 2111
        imath; 131
        imof; 22B7
        imped; 1B5
        in; 2208
        incare; 2105
        infin; 221E
        infintie; 29DD
        inodot; 131
        int; 222B
        intcal; 22BA
        integers; 2124
        intercal; 22BA
        intlarhk; 2A17
        intprod; 2A3C
        iocy; 451
        iogon; 12F
        iopf; 1D55A
        iota; 3B9
        iprod; 2A3C
        iquest BF
        iquest; BF
        iscr; 1D4BE
        isin; 2208
        isinE; 22F9
        isindot; 22F5
        isins; 22F4
        isinsv; 22F3
        isinv; 2208
        it; 2062
        itilde; 129
        iukcy; 456
        iuml EF
        iuml; EF
        jcirc; 135
        jcy; 439
        jfr; 1D527
        jmath; 237
        jopf; 1D55B
        jscr; 1D4BF
        jsercy; 458
        jukcy; 454
        kappa; 3BA
        kappav; 3F0
        kcedil; 137
        kcy; 43A
        kfr; 1D528
        kgreen; 138
        khcy; 445
        kjcy; 45C
        kopf; 1D55C
        kscr; 1D4C0
        lAarr; 21DA
        lArr; 21D0
        lAtail; 291B
        lBarr; 290E
        lE; 2266
        lEg; 2A8B
        lHar; 2962
        lacute; 13A
        laemptyv; 29B4
        lagran; 2112
        lambda; 3BB
        lang; 27E8
        langd; 2991
        langle; 27E8
        lap; 2A85
        laquo AB
        laquo; AB
        larr; 2190
        larrb; 21E4
        larrbfs; 291F
        larrfs; 291D
        larrhk; 21A9
        larrlp; 21AB
        larrpl; 2939
        larrsim; 2973
        larrtl; 21A2
        lat; 2AAB
        latail; 2919
        late; 2AAD
        lates; 2AAD FE00
        lbarr; 290C
        lbbrk; 2772
        lbrace; 7B
        lbrack; 5B
        lbrke; 298B
        lbrksld; 298F
        lbrkslu; 298D
        lcaron; 13E
        lcedil; 13C
        lceil; 2308
        lcub; 7B
        lcy; 43B
        ldca; 2936
        ldquo; 201C
        ldquor; 201E
        ldrdhar; 2967
        ldrushar; 294B
        ldsh; 21B2
        le; 2264
        leftarrow; 2190
        leftarrowtail; 21A2
        leftharpoondown; 21BD
        leftharpoonup; 21BC
        leftleftarrows; 21C7
        leftrightarrow; 2194
        leftrightarrows; 21C6
        leftrightharpoons; 21CB
        leftrightsquigarrow; 21AD
        leftthreetimes; 22CB
        leg; 22DA
        leq; 2264
        leqq; 2266
        leqslant; 2A7D
        les; 2A7D
        lescc; 2AA8
        lesdot; 2A7F
        lesdoto; 2A81
        lesdotor; 2A83
        lesg; 22DA FE00
        lesges; 2A93
        lessapprox; 2A85
        lessdot; 22D6
        lesseqgtr; 22DA
        lesseqqgtr; 2A8B
        lessgtr; 2276
        lesssim; 2272
        lfisht; 297C
        lfloor; 230A
        lfr; 1D529
        lg; 2276
        lgE; 2A91
        lhard; 21BD
        lharu; 21BC
        lharul; 296A
        lhblk; 2584
        ljcy; 459
        ll; 226A
        llarr; 21C7
        llcorner; 231E
        llhard; 296B
        lltri; 25FA
        lmidot; 140
        lmoust; 23B0
        lmoustache; 23B0
        lnE; 2268
        lnap; 2A89
        lnapprox; 2A89
        lne; 2A87
        lneq; 2A87
        lneqq; 2268
        lnsim; 22E6
        loang; 27EC
        loarr; 21FD
        lobrk; 27E6
        longleftarrow; 27F5
        longleftrightarrow; 27F7
        longmapsto; 27FC
        longrightarrow; 27F6
        looparrowleft; 21AB
        looparrowright; 21AC
        lopar; 2985
        lopf; 1D55D
        loplus; 2A2D
        lotimes; 2A34
        lowast; 2217
        lowbar; 5F
        loz; 25CA
        lozenge; 25CA
        lozf; 29EB
        lpar; 28
        lparlt; 2993
        lrarr; 21C6
        lrcorner; 231F
        lrhar; 21CB
        lrhard; 296D
        lrm; 200E
        lrtri; 22BF
        lsaquo; 2039
        lscr; 1D4C1
        lsh; 21B0
        lsim; 2272
        lsime; 2A8D
        lsimg; 2A8F
        lsqb; 5B
        lsquo; 2018
        lsquor; 201A
        lstrok; 142
        lt 3C
        lt; 3C
        ltcc; 2AA6
        ltcir; 2A79
        ltdot; 22D6
        lthree; 22CB
        ltimes; 22C9
        ltlarr; 2976
        ltquest; 2A7B
        ltrPar; 2996
        ltri; 25C3
        ltrie; 22B4
        ltrif; 25C2
        lurdshar; 294A
        luruhar; 2966
        lvertneqq; 2268 FE00
        lvnE; 2268 FE00
        mDDot; 223A
        macr AF
        macr; AF
        male; 2642
        malt; 2720
        maltese; 2720
        map; 21A6
        mapsto; 21A6
        mapstodown; 21A7
        mapstoleft; 21A4
        mapstoup; 21A5
        marker; 25AE
        mcomma; 2A29
        mcy; 43C
        mdash; 2014
        measuredangle; 2221
        mfr; 1D52A
        mho; 2127
        micro B5
        micro; B5
        mid; 2223
        midast; 2A
        midcir; 2AF0
        middot B7
        middot; B7
        minus; 2212
        minusb; 229F
        minusd; 2238
        minusdu; 2A2A
        mlcp; 2ADB
        mldr; 2026
        mnplus; 2213
        models; 22A7
        mopf; 1D55E
        mp; 2213
        mscr; 1D4C2
        mstpos; 223E
        mu; 3BC
        multimap; 22B8
        mumap; 22B8
        nGg; 22D9 338
        nGt; 226B 20D2
        nGtv; 226B 338
        nLeftarrow; 21CD
        nLeftrightarrow; 21CE
        nLl; 22D8 338
        nLt; 226A 20D2
        nLtv; 226A 338
        nRightarrow; 21CF
        nVDash; 22AF
        nVdash; 22AE
        nabla; 2207
        nacute; 144
        nang; 2220 20D2
        nap; 2249
        napE; 2A70 338
        napid; 224B 338
        napos; 149
        napprox; 2249
        natur; 266E
        natural; 266E
        naturals; 2115
        nbsp A0
        nbsp; A0
        nbump; 224E 338
        nbumpe; 224F 338
        ncap; 2A43
        ncaron; 148
        ncedil; 146
        ncong; 2247
        ncongdot; 2A6D 338
        ncup; 2A42
        ncy; 43D
        ndash; 2013
        ne; 2260
        neArr; 21D7
        nearhk; 2924
        nearr; 2197
        nearrow; 2197
        nedot; 2250 338
        nequiv; 2262
        nesear; 2928
        nesim; 2242 338
        nexist; 2204
        nexists; 2204
        nfr; 1D52B
        ngE; 2267 338
        nge; 2271
        ngeq; 2271
        ngeqq; 2267 338
        ngeqslant; 2A7E 338
        nges; 2A7E 338
        ngsim; 2275
        ngt; 226F
        ngtr; 226F
        nhArr; 21CE
        nharr; 21AE
        nhpar; 2AF2
        ni; 220B
        nis; 22FC
        nisd; 22FA
        niv; 220B
        njcy; 45A
        nlArr; 21CD
        nlE; 2266 338
        nlarr; 219A
        nldr; 2025
        nle; 2270
        nleftarrow; 219A
        nleftrightarrow; 21AE
        nleq; 2270
        nleqq; 2266 338
        nleqslant; 2A7D 338
        nles; 2A7D 338
        nless; 226E
        nlsim; 2274
        nlt; 226E
        nltri; 22EA
        nltrie; 22EC
        nmid; 2224
        nopf; 1D55F
        not AC
        not; AC
        notin; 2209
        notinE; 22F9 338
        notindot; 22F5 338
        notinva; 2209
        notinvb; 22F7
        notinvc; 22F6
        notni; 220C
        notniva; 220C
        notnivb; 22FE
        notnivc; 22FD
        npar; 2226
        nparallel; 2226
        nparsl; 2AFD 20E5
        npart; 2202 338
        npolint; 2A14
        npr; 2280
        nprcue; 22E0
        npre; 2AAF 338
        nprec; 2280
        npreceq; 2AAF 338
        nrArr; 21CF
        nrarr; 219B
        nrarrc; 2933 338
        nrarrw; 219D 338
        nrightarrow; 219B
        nrtri; 22EB
        nrtrie; 22ED
        nsc; 2281
        nsccue; 22E1
        nsce; 2AB0 338
        nscr; 1D4C3
        nshortmid; 2224
        nshortparallel; 2226
        nsim; 2241
        nsime; 2244
        nsimeq; 2244
        nsmid; 2224
        nspar; 2226
        nsqsube; 22E2
        nsqsupe; 22E3
        nsub; 2284
        nsubE; 2AC5 338
        nsube; 2288
        nsubset; 2282 20D2
        nsubseteq; 2288
        nsubseteqq; 2AC5 338
        nsucc; 2281
        nsucceq; 2AB0 338
        nsup; 2285
        nsupE; 2AC6 338
        nsupe; 2289
        nsupset; 2283 20D2
        nsupseteq; 2289
        nsupseteqq; 2AC6 338
        ntgl; 2279
        ntilde F1
        ntilde; F1
        ntlg; 2278
        ntriangleleft; 22EA
        ntrianglelefteq; 22EC
        ntriangleright; 22EB
        ntrianglerighteq; 22ED
        nu; 3BD
        num; 23
        numero; 2116
        numsp; 2007
        nvDash; 22AD
        nvHarr; 2904
        nvap; 224D 20D2
        nvdash; 22AC
        nvge; 2265 20D2
        nvgt; 3E 20D2
        nvinfin; 29DE
        nvlArr; 2902
        nvle; 2264 20D2
        nvlt; 3C 20D2
        nvltrie; 22B4 20D2
        nvrArr; 2903
        nvrtrie; 22B5 20D2
        nvsim; 223C 20D2
        nwArr; 21D6
        nwarhk; 2923
        nwarr; 2196
        nwarrow; 2196
        nwnear; 2927
        oS; 24C8
        oacute F3
        oacute; F3
        oast; 229B
        ocir; 229A
        ocirc F4
        ocirc; F4
        ocy; 43E
        odash; 229D
        odblac; 151
        odiv; 2A38
        odot; 2299
        odsold; 29BC
        oelig; 153
        ofcir; 29BF
        ofr; 1D52C
        ogon; 2DB
        ograve F2
        ograve; F2
        ogt; 29C1
        ohbar; 29B5
        ohm; 3A9
        oint; 222E
        olarr; 21BA
        olcir; 29BE
        olcross; 29BB
        oline; 203E
        olt; 29C0
        omacr; 14D
        omega; 3C9
        omicron; 3BF
        omid; 29B6
        ominus; 2296
        oopf; 1D560
        opar; 29B7
        operp; 29B9
        oplus; 2295
        or; 2228
        orarr; 21BB
        ord; 2A5D
        order; 2134
        orderof; 2134
        ordf AA
        ordf; AA
        ordm BA
        ordm; BA
        origof; 22B6
        oror; 2A56
        orslope; 2A57
        orv; 2A5B
        oscr; 2134
        oslash F8
        oslash; F8
        osol; 2298
        otilde F5
        otilde; F5
        otimes; 2297
        otimesas; 2A36
        ouml F6
        ouml; F6
        ovbar; 233D
        par; 2225
        para B6
        para; B6
        parallel; 2225
        parsim; 2AF3
        parsl; 2AFD
        part; 2202
        pcy; 43F
        percnt; 25
        period; 2E
        permil; 2030
        perp; 22A5
        pertenk; 2031
        pfr; 1D52D
        phi; 3C6
        phiv; 3D5
        phmmat; 2133
        phone; 260E
        pi; 3C0
        pitchfork; 22D4
        piv; 3D6
        planck; 210F
        planckh; 210E
        plankv; 210F
        plus; 2B
        plusacir; 2A23
        plusb; 229E
        pluscir; 2A22
        plusdo; 2214
        plusdu; 2A25
        pluse; 2A72
        plusmn B1
        plusmn; B1
        plussim; 2A26
        plustwo; 2A27
        pm; B1
        pointint; 2A15
        popf; 1D561
        pound A3
        pound; A3
        pr; 227A
        prE; 2AB3
        prap; 2AB7
        prcue; 227C
        pre; 2AAF
        prec; 227A
        precapprox; 2AB7
        preccurlyeq; 227C
        preceq; 2AAF
        precnapprox; 2AB9
        precneqq; 2AB5
        precnsim; 22E8
        precsim; 227E
        prime; 2032
        primes; 2119
        prnE; 2AB5
        prnap; 2AB9
        prnsim; 22E8
        prod; 220F
        profalar; 232E
        profline; 2312
        profsurf; 2313
        prop; 221D
        propto; 221D
        prsim; 227E
        prurel; 22B0
        pscr; 1D4C5
        psi; 3C8
        puncsp; 2008
        qfr; 1D52E
        qint; 2A0C
        qopf; 1D562
        qprime; 2057
        qscr; 1D4C6
        quaternions; 210D
        quatint; 2A16
        quest; 3F
        questeq; 225F
        quot 22
        quot; 22
        rAarr; 21DB
        rArr; 21D2
        rAtail; 291C
        rBarr; 290F
        rHar; 2964
        race; 223D 331
        racute; 155
        radic; 221A
        raemptyv; 29B3
        rang; 27E9
        rangd; 2992
        range; 29A5
        rangle; 27E9
        raquo BB
        raquo; BB
        rarr; 2192
        rarrap; 2975
        rarrb; 21E5
        rarrbfs; 2920
        rarrc; 2933
        rarrfs; 291E
        rarrhk; 21AA
        rarrlp; 21AC
        rarrpl; 2945
        rarrsim; 2974
        rarrtl; 21A3
        rarrw; 219D
        ratail; 291A
        ratio; 2236
        rationals; 211A
        rbarr; 290D
        rbbrk; 2773
        rbrace; 7D
        rbrack; 5D
        rbrke; 298C
        rbrksld; 298E
        rbrkslu; 2990
        rcaron; 159
        rcedil; 157
        rceil; 2309
        rcub; 7D
        rcy; 440
        rdca; 2937
        rdldhar; 2969
        rdquo; 201D
        rdquor; 201D
        rdsh; 21B3
        real; 211C
        realine; 211B
        realpart; 211C
        reals; 211D
        rect; 25AD
        reg AE
        reg; AE
        rfisht; 297D
        rfloor; 230B
        rfr; 1D52F
        rhard; 21C1
        rharu; 21C0
        rharul; 296C
        rho; 3C1
        rhov; 3F1
        rightarrow; 2192
        rightarrowtail; 21A3
        rightharpoondown; 21C1
        rightharpoonup; 21C0
        rightleftarrows; 21C4
        rightleftharpoons; 21CC
        rightrightarrows; 21C9
        rightsquigarrow; 219D
        rightthreetimes; 22CC
        ring; 2DA
        risingdotseq; 2253
        rlarr; 21C4
        rlhar; 21CC
        rlm; 200F
        rmoust; 23B1
        rmoustache; 23B1
        rnmid; 2AEE
        roang; 27ED
        roarr; 21FE
        robrk; 27E7
        ropar; 2986
        ropf; 1D563
        roplus; 2A2E
        rotimes; 2A35
        rpar; 29
        rpargt; 2994
        rppolint; 2A12
        rrarr; 21C9
        rsaquo; 203A
        rscr; 1D4C7
        rsh; 21B1
        rsqb; 5D
        rsquo; 2019
        rsquor; 2019
        rthree; 22CC
        rtimes; 22CA
        rtri; 25B9
        rtrie; 22B5
        rtrif; 25B8
        rtriltri; 29CE
        ruluhar; 2968
        rx; 211E
        sacute; 15B
        sbquo; 201A
        sc; 227B
        scE; 2AB4
        scap; 2AB8
        scaron; 161
        sccue; 227D
        sce; 2AB0
        scedil; 15F
        scirc; 15D
        scnE; 2AB6
        scnap; 2ABA
        scnsim; 22E9
        scpolint; 2A13
        scsim; 227F
        scy; 441
        sdot; 22C5
        sdotb; 22A1
        sdote; 2A66
        seArr; 21D8
        searhk; 2925
        searr; 2198
        searrow; 2198
        sect A7
        sect; A7
        semi; 3B
        seswar; 2929
        setminus; 2216
        setmn; 2216
        sext; 2736
        sfr; 1D530
        sfrown; 2322
        sharp; 266F
        shchcy; 449
        shcy; 448
        shortmid; 2223
        shortparallel; 2225
        shy AD
        shy; AD
        sigma; 3C3
        sigmaf; 3C2
        sigmav; 3C2
        sim; 223C
        simdot; 2A6A
        sime; 2243
        simeq; 2243
        simg; 2A9E
        simgE; 2AA0
        siml; 2A9D
        simlE; 2A9F
        simne; 2246
        simplus; 2A24
        simrarr; 2972
        slarr; 2190
        smallsetminus; 2216
        smashp; 2A33
        smeparsl; 29E4
        smid; 2223
        smile; 2323
        smt; 2AAA
        smte; 2AAC
        smtes; 2AAC FE00
        softcy; 44C
        sol; 2F
        solb; 29C4
        solbar; 233F
        sopf; 1D564
        spades; 2660
        spadesuit; 2660
        spar; 2225
        sqcap; 2293
        sqcaps; 2293 FE00
        sqcup; 2294
        sqcups; 2294 FE00
        sqsub; 228F
        sqsube; 2291
        sqsubset; 228F
        sqsubseteq; 2291
        sqsup; 2290
        sqsupe; 2292
        sqsupset; 2290
        sqsupseteq; 2292
        squ; 25A1
        square; 25A1
        squarf; 25AA
        squf; 25AA
        srarr; 2192
        sscr; 1D4C8
        ssetmn; 2216
        ssmile; 2323
        sstarf; 22C6
        star; 2606
        starf; 2605
        straightepsilon; 3F5
        straightphi; 3D5
        strns; AF
        sub; 2282
        subE; 2AC5
        subdot; 2ABD
        sube; 2286
        subedot; 2AC3
        submult; 2AC1
        subnE; 2ACB
        subne; 228A
        subplus; 2ABF
        subrarr; 2979
        subset; 2282
        subseteq; 2286
        subseteqq; 2AC5
        subsetneq; 228A
        subsetneqq; 2ACB
        subsim; 2AC7
        subsub; 2AD5
        subsup; 2AD3
        succ; 227B
        succapprox; 2AB8
        succcurlyeq; 227D
        succeq; 2AB0
        succnapprox; 2ABA
        succneqq; 2AB6
        succnsim; 22E9
        succsim; 227F
        sum; 2211
        sung; 266A
        sup1 B9
        sup1; B9
        sup2 B2
        sup2; B2
        sup3 B3
        sup3; B3
        sup; 2283
        supE; 2AC6
        supdot; 2ABE
        supdsub; 2AD8
        supe; 2287
        supedot; 2AC4
        suphsol; 27C9
        suphsub; 2AD7
        suplarr; 297B
        supmult; 2AC2
        supnE; 2ACC
        supne; 228B
        supplus; 2AC0
        supset; 2283
        supseteq; 2287
        supseteqq; 2AC6
        supsetneq; 228B
        supsetneqq; 2ACC
        supsim; 2AC8
        supsub; 2AD4
        supsup; 2AD6
        swArr; 21D9
        swarhk; 2926
        swarr; 2199
        swarrow; 2199
        swnwar; 292A
        szlig DF
        szlig; DF
        target; 2316
        tau; 3C4
        tbrk; 23B4
        tcaron; 165
        tcedil; 163
        tcy; 442
        tdot; 20DB
        telrec; 2315
        tfr; 1D531
        there4; 2234
        therefore; 2234
        theta; 3B8
        thetasym; 3D1
        thetav; 3D1
        thickapprox; 2248
        thicksim; 223C
        thinsp; 2009
        thkap; 2248
        thksim; 223C
        thorn FE
        thorn; FE
        tilde; 2DC
        times D7
        times; D7
        timesb; 22A0
        timesbar; 2A31
        timesd; 2A30
        tint; 222D
        toea; 2928
        top; 22A4
        topbot; 2336
        topcir; 2AF1
        topf; 1D565
        topfork; 2ADA
        tosa; 2929
        tprime; 2034
        trade; 2122
        triangle; 25B5
        triangledown; 25BF
        triangleleft; 25C3
        trianglelefteq; 22B4
        triangleq; 225C
        triangleright; 25B9
        trianglerighteq; 22B5
        tridot; 25EC
        trie; 225C
        triminus; 2A3A
        triplus; 2A39
        trisb; 29CD
        tritime; 2A3B
        trpezium; 23E2
        tscr; 1D4C9
        tscy; 446
        tshcy; 45B
        tstrok; 167
        twixt; 226C
        twoheadleftarrow; 219E
        twoheadrightarrow; 21A0
        uArr; 21D1
        uHar; 2963
        uacute FA
        uacute; FA
        uarr; 2191
        ubrcy; 45E
        ubreve; 16D
        ucirc FB
        ucirc; FB
        ucy; 443
        udarr; 21C5
        udblac; 171
        udhar; 296E
        ufisht; 297E
        ufr; 1D532
        ugrave F9
        ugrave; F9
        uharl; 21BF
        uharr; 21BE
        uhblk; 2580
        ulcorn; 231C
        ulcorner; 231C
        ulcrop; 230F
        ultri; 25F8
        umacr; 16B
        uml A8
        uml; A8
        uogon; 173
        uopf; 1D566
        uparrow; 2191
        updownarrow; 2195
        upharpoonleft; 21BF
        upharpoonright; 21BE
        uplus; 228E
        upsi; 3C5
        upsih; 3D2
        upsilon; 3C5
        upuparrows; 21C8
        urcorn; 231D
        urcorner; 231D
        urcrop; 230E
        uring; 16F
        urtri; 25F9
        uscr; 1D4CA
        utdot; 22F0
        utilde; 169
        utri; 25B5
        utrif; 25B4
        uuarr; 21C8
        uuml FC
        uuml; FC
        uwangle; 29A7
        vArr; 21D5
        vBar; 2AE8
        vBarv; 2AE9
        vDash; 22A8
        vangrt; 299C
        varepsilon; 3F5
        varkappa; 3F0
        varnothing; 2205
        varphi; 3D5
        varpi; 3D6
        varpropto; 221D
        varr; 2195
        varrho; 3F1
        varsigma; 3C2
        varsubsetneq; 228A FE00
        varsubsetneqq; 2ACB FE00
        varsupsetneq; 228B FE00
        varsupsetneqq; 2ACC FE00
        vartheta; 3D1
        vartriangleleft; 22B2
        vartriangleright; 22B3
        vcy; 432
        vdash; 22A2
        vee; 2228
        veebar; 22BB
        veeeq; 225A
        vellip; 22EE
        verbar; 7C
        vert; 7C
        vfr; 1D533
        vltri; 22B2
        vnsub; 2282 20D2
        vnsup; 2283 20D2
        vopf; 1D567
        vprop; 221D
        vrtri; 22B3
        vscr; 1D4CB
        vsubnE; 2ACB FE00
        vsubne; 228A FE00
        vsupnE; 2ACC FE00
        vsupne; 228B FE00
        vzigzag; 299A
        wcirc; 175
        wedbar; 2A5F
        wedge; 2227
        wedgeq; 2259
        weierp; 2118
        wfr; 1D534
        wopf; 1D568
        wp; 2118
        wr; 2240
        wreath; 2240
        wscr; 1D4CC
        xcap; 22C2
        xcirc; 25EF
        xcup; 22C3
        xdtri; 25BD
        xfr; 1D535
        xhArr; 27FA
        xharr; 27F7
        xi; 3BE
        xlArr; 27F8
        xlarr; 27F5
        xmap; 27FC
        xnis; 22FB
        xodot; 2A00
        xopf; 1D569
        xoplus; 2A01
        xotime; 2A02
        xrArr; 27F9
        xrarr; 27F6
        xscr; 1D4CD
        xsqcup; 2A06
        xuplus; 2A04
        xutri; 25B3
        xvee; 22C1
        xwedge; 22C0
        yacute FD
        yacute; FD
        yacy; 44F
        ycirc; 177
        ycy; 44B
        yen A5
        yen; A5
        yfr; 1D536
        yicy; 457
        yopf; 1D56A
        yscr; 1D4CE
        yucy; 44E
        yuml FF
        yuml; FF
        zacute; 17A
        zcaron; 17E
        zcy; 437
        zdot; 17C
        zeetrf; 2128
        zeta; 3B6
        zfr; 1D537
        zhcy; 436
        zigrarr; 21DD
        zopf; 1D56B
        zscr; 1D4CF
        zwj; 200D
        zwnj; 200C
        """
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
    /// Case 554591 (A7): a tokenizer message with vnu.jar's own place: its
    /// first and last UTF-16 offsets, both inclusive (see
    /// SourceLocationMap.location(firstOffset:lastOffset:)), which
    /// .parseError's offset and length can't say when the two are the same
    /// character (the messages reported at an "&"); and whether it's a
    /// warning (the Private Use Area one) rather than an error.
    case diagnostic(message: String, isWarning: Bool, firstOffset: Int, lastOffset: Int)
}

final class HTMLTokenizer {
    private let source: String
    private let locations: SourceLocationMap
    /// Case 554591 (A7): vnu.jar gives one Private Use Area warning per
    /// document, at the first such character, written as a reference or
    /// literally. privateUseWarned is the references' flag
    /// (HTMLCharacterReferences.consume sets it at the first one, and the
    /// tokenizer once the literal one has the warning);
    /// firstLiteralPrivateUseLastOffset is where the first literal one ends
    /// (from sourceDiagnostics, which runs before the main loop), so that a
    /// reference's warning after it is dropped; and privateUseWarningKept
    /// says that a reference came first and has the warning, so the literal
    /// one gets none.
    private var privateUseWarned = false
    private var firstLiteralPrivateUseLastOffset: Int?
    private var privateUseWarningKept = false
    /// Case 554591 (A7's review): the document's code-point messages, in
    /// order (see CodePointMessage and sourceDiagnostics), and the first of
    /// them not given yet. The tokenizer reads the source in order, and each
    /// is given as it reads past it, so a cursor will do.
    private var codePointMessages: [CodePointMessage] = []
    private var nextCodePointMessage = 0
    /// Case 554591 (A7's review): the latest place vnu.jar's recorder has
    /// noted in the tag being read, start or end tag, for the first places of
    /// the tag's messages: the place before its "<" (or the "<" itself, where
    /// a reference in the text before the tag ran into it, which upstream
    /// hands on with its locator there; see textRunNotedEnd), then the last
    /// place of each message given in the tag, and the end of a repeated
    /// attribute name, where upstream's tokenizer reports the duplicate. The
    /// places grow as the tag is read, so the latest is all that's needed.
    /// Each value's messages used to be placed from the tag's earlier
    /// messages, gathered again for each value, so a tag of thousands of
    /// attributes with references took quadratic time (6.6 s for 64,000);
    /// and the duplicate, the code points and the text's reference weren't
    /// among them, so a message after one started too early.
    private var tagNotedPlace = 0
    /// Case 554591 (A7's review): the "<" that ended the latest text run,
    /// when a reference in it ran into that "<" (see tagNotedPlace).
    private var textRunNotedEnd: Int?

    /// Case 554591 (A7's review): a message upstream's tokenizer gives about
    /// a character written as is, as it reads it (ErrorReportingTokenizer's
    /// checkChar; see sourceDiagnostics). lastOffset is where vnu.jar ends
    /// it: the character, or, for an astral one, its low surrogate, which is
    /// where checkChar sees it (so after the high surrogate has ended a
    /// reference, and after that reference's messages, while a character in
    /// the BMP that ends a reference comes before the reference's messages).
    /// Its first place is one past the latest place noted before it, as for
    /// any of the tokenizer's messages, found where it's given: by the
    /// ReferenceMessageSink of the text run or the value it's in, or by
    /// appendCodePointMessages. These messages used to go in front of every
    /// other message, each placed on its character alone, and weren't noted
    /// for the places of the messages after them.
    private struct CodePointMessage {
        var lastOffset: Int
        var message: String
        var isWarning: Bool
    }

    init(source: String, locations: SourceLocationMap) {
        self.source = source
        self.locations = locations
    }

    /// The tokens, and the events HTMLTreeEventBuilder builds from them.
    /// Review item A2: the tree builder runs as the tokens are produced,
    /// because the namespace of each start tag's element, and whether
    /// "<![CDATA[" starts a CDATA section, depend on its current node (see
    /// HTMLTreeEventBuilder).
    func tokenizeAndBuildTree() -> (tokens: [HTMLToken], events: [HTMLDocumentEvent], impliedColgroupEnds: [Int], impliedTablePartEnds: [HTMLImpliedTablePartEnd], implicitEndCauses: [HTMLImplicitEndCause], attributesEndedByTag: Set<Int>, bodyStartEvent: Int?) {
        // Case 554591: the whole-source diagnostics used to be computed after
        // the main loop, which collected the ranges where the HTML tokenizer
        // never parses character references (raw text and script contents,
        // comments and CDATA sections: "&#" in JavaScript or "&nbsp" in CSS
        // were errors). Case 554591 (A7): references are now read where
        // upstream's tokenizer reads them and as it reads them (see
        // appendTextReferenceDiagnostics and parseAttributeValue), so the
        // whole-source pass is left with the literal code points, and runs
        // first, as it notes where the first literal Private Use Area
        // character is (see privateUseWarned).
        var tokens: [HTMLToken] = []
        codePointMessages = sourceDiagnostics()
        // Case 554591 (A14's third review): see
        // HTMLParsedDocument.attributesEndedByTag.
        var attributesEndedByTag: Set<Int> = []
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
                // (Case 554591, A7's review: whether the tree builder will
                // ignore the run's leading white space, or drop the newline
                // after a pre or listing start tag, so that the recorder
                // never notes a carriage return there; see
                // appendTextReferenceDiagnostics.)
                var dropsLeadingNewline = false
                if case let .startTag(name, _, _, namespace, _, _)? = tokens.last, .html == namespace, "pre" == name || "listing" == name {
                    dropsLeadingNewline = true
                }
                catchUpTreeBuilder()
                let ignoresLeadingWhiteSpace = treeBuilder.ignoresWhiteSpace
                appendText(from: textStart, to: index, to: &tokens)
                appendTextReferenceDiagnostics(from: textStart, to: index, ignoresLeadingWhiteSpace: ignoresLeadingWhiteSpace, dropsLeadingNewline: dropsLeadingNewline, to: &tokens)
                continue
            }
            let start = index
            if consumePrefix("<!--", from: &index) {
                let commentStart = index
                // (Case 554591, A7's review: the code-point messages in a
                // comment, before it, in order with its own messages, placed
                // from its "<".)
                var floor = locations.offset(of: start) - 1
                if let endRange = source[index...].range(of: "-->") {
                    let comment = source[commentStart..<endRange.lowerBound]
                    if let nested = comment.range(of: "<!--") {
                        appendCodePointMessages(through: locations.offset(of: nested.lowerBound), floor: &floor, to: &tokens)
                        appendError(
                            "Saw \u{201c}<!--\u{201d} within a comment. Probable cause: Nested comment (not allowed).",
                            at: nested.lowerBound,
                            length: 4,
                            to: &tokens
                        )
                        floor = max(floor, tokens.last.flatMap(Self.lastOffset(of:)) ?? floor)
                    }
                    appendCodePointMessages(through: locations.offset(of: endRange.lowerBound) - 1, floor: &floor, to: &tokens)
                    appendComment(from: commentStart, to: endRange.lowerBound, to: &tokens)
                    index = endRange.upperBound
                } else {
                    appendCodePointMessages(through: source.utf16.count - 1, floor: &floor, to: &tokens)
                    appendError("End of file inside comment.", at: start, length: source.utf16.distance(from: start.samePosition(in: source.utf16) ?? source.utf16.startIndex, to: source.utf16.endIndex), to: &tokens)
                    appendComment(from: commentStart, to: source.endIndex, to: &tokens)
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
                // (Case 554591, A7's review: its code-point messages first,
                // placed as in text.)
                appendTextCodePointMessages(from: locations.offset(of: contentStart), to: locations.offset(of: contentEnd?.lowerBound ?? source.endIndex), floor: locations.offset(of: start) - 1, notedFrom: locations.offset(of: contentStart), to: &tokens)
                appendText(from: contentStart, to: contentEnd?.lowerBound ?? source.endIndex, to: &tokens)
                // Upstream's tokenizer reports nothing for EOF in a CDATA section.
                index = contentEnd?.upperBound ?? source.endIndex
                continue
            }
            if consumePrefix("<!DOCTYPE", from: &index, caseInsensitive: true) {
                appendDoctypeDiagnostics(from: start, afterKeyword: index, to: &tokens)
                _ = skipUntil(">", from: &index)
                // (Upstream's DOCTYPE, bogus-comment and attribute-name states
                // never parse character references, nor does this tokenizer:
                // see appendTextReferenceDiagnostics. Case 554591, A7's review:
                // the doctype's code-point messages go before it.)
                let offset = locations.offset(of: start)
                var floor = offset - 1
                appendCodePointMessages(through: locations.offset(of: index) - 1, floor: &floor, to: &tokens)
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
                    appendSkippedCodePointMessages(from: start, to: index, to: &tokens)
                    continue
                }
                if index < source.endIndex, !isNameStart(source[index]) {
                    appendError("Garbage after \u{201c}</\u{201d}.", at: start, length: max(2, locations.offset(of: index) - locations.offset(of: start)), to: &tokens)
                    _ = skipUntil(">", from: &index)
                    appendSkippedCodePointMessages(from: start, to: index, to: &tokens)
                    continue
                }
                let nameStart = index
                while index < source.endIndex, isNameCharacter(source[index]) {
                    source.formIndex(after: &index)
                }
                let name = String(source[nameStart..<index]).lowercased()
                // (Case 554591, A7's review: see tagNotedPlace.)
                startTagNotedPlace(at: start)
                var postName = index
                skipWhitespace(from: &postName)
                var hadAttributes = false
                if postName < source.endIndex, source[postName] != ">" {
                    if source[postName] == "/" {
                        appendTagError("Stray \u{201c}/\u{201d} at the end of an end tag.", at: postName, length: 1, to: &tokens)
                    } else {
                        hadAttributes = true
                    }
                }
                let foundEnd = skipUntil(">", from: &index)
                let tagEnd = foundEnd ? source.index(before: index) : source.endIndex
                // Case 554591 (A7): the references in an end tag's attribute
                // values, from the attributes' start to its ">" (or the end of
                // the file). (From A7's review: then the code-point messages in
                // the rest of the tag, and then, as upstream's tokenizer gives
                // it when the tag ends, after them all, "End tag had
                // attributes.", at vnu.jar's place, from one past the tag's
                // latest noted place to the ">". It came before them, placed
                // at the first attribute's first character; and at the end of
                // the file, where upstream drops the tag without it.)
                appendEndTagReferenceDiagnostics(from: postName, to: tagEnd, to: &tokens)
                appendCodePointMessages(through: locations.offset(of: tagEnd) - 1, floor: &tagNotedPlace, to: &tokens)
                if hadAttributes, foundEnd {
                    let last = locations.offset(of: tagEnd)
                    tokens.append(.diagnostic(message: "End tag had attributes.", isWarning: false, firstOffset: min(tagNotedPlace + 1, last), lastOffset: last))
                }
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
                appendSkippedCodePointMessages(from: start, to: index, to: &tokens)
                continue
            }
            if consumePrefix("<!", from: &index) {
                appendError("Bogus comment.", at: start, length: 2, to: &tokens)
                _ = skipUntil(">", from: &index)
                appendSkippedCodePointMessages(from: start, to: index, to: &tokens)
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
                // (Case 554591, A7's review: a code point read there comes
                // first, as checkChar reads the character before the tag's
                // state does.)
                var floor = offset - 1
                appendCodePointMessages(through: locations.offset(of: index), floor: &floor, to: &tokens)
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
            // Case 554591 (A7's review): see tagNotedPlace, and
            // seenAttributeNames below.
            startTagNotedPlace(at: start)
            var seenAttributeNames: Set<String> = []
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
                        appendTagError("A slash was not immediately followed by \u{201c}>\u{201d}.", at: index, length: 1, to: &tokens)
                    }
                    continue
                }
                if missingSpaceAfterQuotedValue {
                    appendTagError("No space between attributes.", at: index, length: 1, to: &tokens)
                }
                if source[index] == "=" {
                    appendTagError("Saw \u{201c}=\u{201d} when expecting an attribute name. Probable cause: Attribute name missing.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                    continue
                }
                if source[index] == "<" {
                    appendTagError("Saw \u{201c}<\u{201d} when expecting an attribute name. Probable cause: Missing \u{201c}>\u{201d} immediately before.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                    continue
                }
                let attrOffset = locations.offset(of: index)
                let attrNameStart = index
                while index < source.endIndex, isAttributeNameCharacter(source[index]) {
                    source.formIndex(after: &index)
                }
                let attrName = String(source[attrNameStart..<index]).lowercased()
                // (Case 554591, A7's review: upstream's tokenizer reports a
                // repeated name when it ends, at the character that ends it,
                // the place its recorder then notes, so the tag's later
                // messages start past it: "Duplicate attribute", which the
                // port gives later, in HTMLValidator. The code points read
                // before that go first.)
                if !attrName.isEmpty, !seenAttributeNames.insert(attrName).inserted, index < source.endIndex {
                    let nameEnd = locations.offset(of: index)
                    appendCodePointMessages(through: nameEnd, floor: &tagNotedPlace, to: &tokens)
                    tagNotedPlace = max(tagNotedPlace, nameEnd)
                }
                if attrName.isEmpty {
                    if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                        appendTagError("Quote \u{201c}\(display(source[index]))\u{201d} in attribute name. Probable cause: Matching quote missing somewhere earlier.", at: index, length: 1, to: &tokens)
                    }
                    source.formIndex(after: &index)
                    continue
                }
                if index < source.endIndex, source[index] == "<" {
                    appendTagError("\u{201c}<\u{201d} in attribute name. Probable cause: \u{201c}>\u{201d} missing immediately before.", at: index, length: 1, to: &tokens)
                    source.formIndex(after: &index)
                } else if index < source.endIndex, source[index] == "\"" || source[index] == "'" {
                    appendTagError("Quote \u{201c}\(display(source[index]))\u{201d} in attribute name. Probable cause: Matching quote missing somewhere earlier.", at: index, length: 1, to: &tokens)
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
                    // (Case 554591, A14's second and third reviews, the notes'
                    // item 89: an "=" and then the tag's end, as in <div
                    // aria-checked=>, is an attribute without a value to
                    // upstream's tokenizer, as <div aria-checked> is: its
                    // "before attribute value" state calls
                    // addAttributeWithoutValue. See attributesEndedByTag.)
                    if index < source.endIndex, ">" == source[index] {
                        attributesEndedByTag.insert(attrOffset)
                    }
                    value = parseAttributeValue(from: &index, tokens: &tokens)
                }
                attributes.append(HTMLAttribute(name: attrName, value: value, offset: attrOffset))
            }
            // (Case 554591, A7's review: the code-point messages in the rest
            // of the tag, its names, before the tag; see tagNotedPlace.)
            appendCodePointMessages(through: locations.offset(of: index) - 1, floor: &tagNotedPlace, to: &tokens)
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
                consumeTextContent(of: name, kind: kind, from: &index, to: &tokens)
            }
        }
        catchUpTreeBuilder()
        // (Review item A2: the tree builder finishes first, and the whole-source
        // diagnostics go in front of the tokens in place. Building a third
        // array, a copy of every token, while the tokens and the finished
        // events were all alive raised the peak memory for a large document
        // by 30–60%.)
        let events = treeBuilder.finish(endOffset: locations.offset(of: source.endIndex))
        // (Case 554591, A7's review: every code-point message has been given
        // in its place, as the loop read past it; this is only in case one
        // wasn't, placed on its character. They used to go in front of the
        // tokens here.)
        var floor = Int.max - 1
        appendCodePointMessages(through: Int.max, floor: &floor, to: &tokens)
        // (Case 554591, item 12, from its second and third reviews: see
        // HTMLParsedDocument.impliedColgroupEnds and impliedTablePartEnds; and
        // U11's implicitEndCauses; and A14's attributesEndedByTag and
        // bodyStartEvent.)
        return (tokens, events, treeBuilder.impliedColgroupEnds, treeBuilder.impliedTablePartEnds, treeBuilder.implicitEndCauses, attributesEndedByTag, treeBuilder.bodyStartEvent)
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
        to tokens: inout [HTMLToken]
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
        // (Case 554591, A7: and are read here, as text, to the end tag's "<" or
        // the end of the file.)
        if .rcdata == kind {
            appendTextReferenceDiagnostics(from: contentStart, to: contentEnd ?? source.endIndex, ignoresLeadingWhiteSpace: false, dropsLeadingNewline: "textarea" == name, to: &tokens)
        } else {
            // (Case 554591, A7's review: other contents have only their
            // code-point messages, placed as in text.)
            let contentStartOffset = locations.offset(of: contentStart)
            appendTextCodePointMessages(from: contentStartOffset, to: locations.offset(of: contentEnd ?? source.endIndex), floor: contentStartOffset - 1, notedFrom: contentStartOffset, to: &tokens)
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

    /// (Case 554591, A7: the value's references are read here too; see
    /// appendAttributeReferenceDiagnostics. From A7's review: the places of
    /// their messages come from the tag's noted place, tagNotedPlace, rather
    /// than from the tag's start and its messages in `tokens`, which this took.)
    private func parseAttributeValue(from index: inout String.Index, tokens: inout [HTMLToken]) -> String {
        guard index < source.endIndex else {
            return ""
        }
        if source[index] == ">" {
            appendTagError("Attribute value missing.", at: index, length: 1, to: &tokens)
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
            // Case 554591 (A7): the value's references, before the end of the
            // file's message, as upstream reports them as it reads.
            appendAttributeReferenceDiagnostics(from: valueStart, to: index, additional: quote.unicodeScalars.first ?? "\"", following: index < source.endIndex ? source.unicodeScalars[index] : nil, valueErrors: [], to: &tokens)
            if index < source.endIndex {
                source.formIndex(after: &index)
            } else {
                appendCodePointMessages(through: source.utf16.count - 1, floor: &tagNotedPlace, to: &tokens)
                appendError("End of file reached when inside an attribute value. Ignoring tag.", at: valueStart, length: max(1, locations.offset(of: source.endIndex) - locations.offset(of: valueStart)), to: &tokens)
            }
            return value
        }
        switch source[index] {
        case "=":
            appendTagError("\u{201c}=\u{201d} at the start of an unquoted attribute value. Probable cause: Stray duplicate equals sign.", at: index, length: 1, to: &tokens)
        case "<":
            appendTagError("\u{201c}<\u{201d} at the start of an unquoted attribute value. Probable cause: Missing \u{201c}>\u{201d} immediately before.", at: index, length: 1, to: &tokens)
        case "`":
            appendTagError("\u{201c}`\u{201d} at the start of an unquoted attribute value. Probable cause: Using the wrong character as a quote.", at: index, length: 1, to: &tokens)
        default:
            break
        }
        let valueStart = index
        // (Case 554591, A7's review: the value's messages about its
        // characters go to its references' sink, which gives them in the
        // order upstream's tokenizer does, among its references' messages;
        // they all came before those. And a "<" at the start is reported
        // once, as the start of the value, as upstream's "before attribute
        // value" state takes it; it was reported again as one in the value.)
        var valueErrors: [HTMLToken] = []
        while index < source.endIndex, !source[index].isWhitespace, source[index] != ">" {
            switch source[index] {
            case "<" where index != valueStart:
                appendError("\u{201c}<\u{201d} in an unquoted attribute value. Probable cause: Missing \u{201c}>\u{201d} immediately before.", at: index, length: 1, to: &valueErrors)
            case "`" where index != valueStart:
                appendError("\u{201c}`\u{201d} in an unquoted attribute value. Probable cause: Using the wrong character as a quote.", at: index, length: 1, to: &valueErrors)
            case "\"":
                appendError("\u{201c}\"\u{201d} in an unquoted attribute value. Probable causes: Attributes running together or a URL query string in an unquoted attribute value.", at: index, length: 1, to: &valueErrors)
            default:
                break
            }
            source.formIndex(after: &index)
        }
        // Case 554591 (A7): an unquoted value's references (its "additional
        // allowed character" is ">").
        appendAttributeReferenceDiagnostics(from: valueStart, to: index, additional: ">", following: index < source.endIndex ? source.unicodeScalars[index] : nil, valueErrors: valueErrors, to: &tokens)
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

    /// Whole-source diagnostics: the literal code points upstream's tokenizer
    /// reports wherever it reads them (its checkChar), in every state, as far
    /// as the port has them: U+000B and the astral noncharacters (checkChar
    /// reports more, other controls, U+FFFE and U+0000 among them, which the
    /// port doesn't yet), and the warning for the first literal Private Use
    /// Area character (see privateUseWarned). (Case 554591, A7: this pass
    /// used to report the character references too, skipping the places where
    /// "&" is just a character; they're read where upstream's tokenizer reads
    /// them now. It walks the scalars, where it used to take each Character's
    /// first scalar only. From A7's review: it only finds the messages now,
    /// in order; each is given as the tokenizer reads past it, among the
    /// others, at vnu.jar's place: see CodePointMessage.)
    private func sourceDiagnostics() -> [CodePointMessage] {
        var messages: [CodePointMessage] = []
        var offset = 0
        for scalar in source.unicodeScalars {
            let value = scalar.value
            let last = offset + scalar.utf16.count - 1
            if 0x000B == value {
                messages.append(CodePointMessage(lastOffset: last, message: "Forbidden code point U+000b.", isWarning: false))
            } else if isAstralNonCharacter(value) {
                messages.append(CodePointMessage(lastOffset: last, message: "Astral non-character.", isWarning: false))
            } else if nil == firstLiteralPrivateUseLastOffset, HTMLCharacterReferences.isPrivateUse(value) {
                firstLiteralPrivateUseLastOffset = last
                messages.append(CodePointMessage(lastOffset: last, message: HTMLCharacterReferences.privateUseWarning, isWarning: true))
            }
            offset += scalar.utf16.count
        }

        // Case 554591: a heuristic here reported "End of file seen when
        // expecting text or an end tag." for *any* document containing both
        // "</style>" and "<script" (or "</src>"), which is most real pages.
        // The error is now reported by consumeTextContent(), when a script or
        // other text-only element actually runs to the end of the file.
        return messages
    }

    /// Case 554591 (A7's review): gives the code-point messages not given yet
    /// whose characters end at `place` or before (see CodePointMessage), each
    /// placed from one past `floor`, the latest place noted, to its
    /// character, which then becomes the floor. For what isn't a text run or
    /// an attribute value with references, whose sinks give their own: a
    /// tag's names, a comment, a doctype, raw text, a CDATA section, bogus
    /// markup, text without references.
    private func appendCodePointMessages(through place: Int, floor: inout Int, to tokens: inout [HTMLToken]) {
        while nextCodePointMessage < codePointMessages.count, codePointMessages[nextCodePointMessage].lastOffset <= place {
            let codePoint = codePointMessages[nextCodePointMessage]
            nextCodePointMessage += 1
            if codePoint.isWarning {
                // (The literal's Private Use Area warning, but where a
                // reference's came first.)
                guard !privateUseWarningKept else { continue }
                privateUseWarned = true
            }
            tokens.append(.diagnostic(message: codePoint.message, isWarning: codePoint.isWarning, firstOffset: min(floor + 1, codePoint.lastOffset), lastOffset: codePoint.lastOffset))
            floor = max(floor, codePoint.lastOffset)
        }
    }

    /// Case 554591 (A7's review): the code-point messages in what upstream's
    /// tokenizer hands on as characters, from offset `start` to `end`, where
    /// no reference sink reads it: a text run without references, raw text, a
    /// CDATA section. Each is placed from one past the latest place noted
    /// before it: `floor`, the place before the text, or a carriage return in
    /// it, where upstream's tokenizer hands on what it has and a line feed
    /// for it, which the recorder notes (see consume), but for those before
    /// `notedFrom`, which the tree builder never hands on (see
    /// appendTextReferenceDiagnostics). (Found by the case's a7/fix/fuzz:
    /// "\r\n" then U+E000 in the head was placed from the end of the line
    /// before.)
    private func appendTextCodePointMessages(from start: Int, to end: Int, floor: Int, notedFrom: Int, to tokens: inout [HTMLToken]) {
        guard hasCodePointMessage(before: end) else { return }
        var floor = floor
        let units = source.utf16
        var index = units.index(units.startIndex, offsetBy: start)
        var offset = start
        while hasCodePointMessage(before: end) {
            let last = codePointMessages[nextCodePointMessage].lastOffset
            while offset < last, index < units.endIndex {
                if 13 == units[index], notedFrom <= offset {
                    floor = max(floor, offset)
                }
                units.formIndex(after: &index)
                offset += 1
            }
            appendCodePointMessages(through: last, floor: &floor, to: &tokens)
        }
    }

    /// Case 554591 (A7's review): whether a code-point message not given yet
    /// is for a character before `offset`.
    private func hasCodePointMessage(before offset: Int) -> Bool {
        nextCodePointMessage < codePointMessages.count && codePointMessages[nextCodePointMessage].lastOffset < offset
    }

    /// Case 554591 (A7's review): the code-point messages in markup skipped
    /// as a bogus comment, from `start` to `index`, after its error (the
    /// last token), placed from one past it.
    private func appendSkippedCodePointMessages(from start: String.Index, to index: String.Index, to tokens: inout [HTMLToken]) {
        var floor = max(locations.offset(of: start) - 1, tokens.last.flatMap(Self.lastOffset(of:)) ?? 0)
        appendCodePointMessages(through: locations.offset(of: index) - 1, floor: &floor, to: &tokens)
    }

    /// Case 554591 (A7's review): a tag starts at `start`: see tagNotedPlace.
    private func startTagNotedPlace(at start: String.Index) {
        let offset = locations.offset(of: start)
        tagNotedPlace = textRunNotedEnd == offset ? offset : offset - 1
    }

    /// Case 554591 (A7's review): an error in the tag being read, which
    /// upstream's tokenizer gives as it reads the character at `index`: after
    /// the code-point messages up to that character, and with its last place
    /// noted for the tag's later messages (see tagNotedPlace).
    private func appendTagError(_ message: String, at index: String.Index, length: Int, to tokens: inout [HTMLToken]) {
        appendCodePointMessages(through: locations.offset(of: index), floor: &tagNotedPlace, to: &tokens)
        appendError(message, at: index, length: length, to: &tokens)
        if let last = tokens.last.flatMap(Self.lastOffset(of:)) {
            tagNotedPlace = max(tagNotedPlace, last)
        }
    }

    /// Case 554591 (A7): the tokenizer's messages about the character
    /// references in a text run, data or RCDATA, from `start` to `end` (the
    /// "<" that ends it, or the end of the file), as upstream's tokenizer
    /// makes them (HTMLCharacterReferences.consume) and where vnu.jar puts
    /// them. The run's token keeps the text as written: each check that reads
    /// text decodes it for itself (HTMLCharacterReferences.decodeText).
    /// (From A7's review: ignoresLeadingWhiteSpace says that the tree builder
    /// ignores white space where the run starts, and dropsLeadingNewline that
    /// it drops a newline at its start, after a pre, listing or textarea start
    /// tag: the carriage returns it never hands on aren't noted.)
    private func appendTextReferenceDiagnostics(from start: String.Index, to end: String.Index, ignoresLeadingWhiteSpace: Bool, dropsLeadingNewline: Bool, to tokens: inout [HTMLToken]) {
        textRunNotedEnd = nil
        guard start < end else {
            return
        }
        // (The place before the run, the previous token's end, is noted;
        // but where upstream's recorder doesn't note it, after </body> or
        // </html>, a CDATA section, or a "<" that's text, an older difference.
        // Case 554591, A7's review: the code-point messages in the run are
        // given here, among its references' messages, or alone.)
        let startOffset = locations.offset(of: start)
        let endOffset = locations.offset(of: end)
        // (Where places start to be noted: the carriage returns before it, and
        // the text an "&" there hands on, are what the tree builder ignores or
        // drops, so that the recorder never sees them: the run's leading white
        // space, or its leading newline, a carriage return or a line feed.)
        var notedFrom = startOffset
        if ignoresLeadingWhiteSpace {
            var cursor = start
            while cursor < end, Self.isHTMLSpace(source[cursor]) {
                source.formIndex(after: &cursor)
            }
            notedFrom = locations.offset(of: cursor)
        } else if dropsLeadingNewline, "\r" == source.unicodeScalars[start] || "\n" == source.unicodeScalars[start] {
            notedFrom = startOffset + 1
        }
        guard source[start..<end].utf8.contains(UInt8(ascii: "&")) else {
            appendTextCodePointMessages(from: startOffset, to: endOffset, floor: startOffset - 1, notedFrom: notedFrom, to: &tokens)
            return
        }
        let following: Unicode.Scalar? = end < source.endIndex ? source.unicodeScalars[end] : nil
        let latest = appendReferenceDiagnostics(Array(source.unicodeScalars[start..<end]), context: .text, following: following, startOffset: startOffset, endOffset: endOffset, noted: startOffset - 1, notedFrom: notedFrom, valueErrors: [], to: &tokens)
        // (Case 554591, A7's review: a reference that ran into the "<" after
        // the run is handed on with upstream's locator on it, which the
        // recorder notes, for the tag's first places: see tagNotedPlace.)
        if let latest, endOffset == latest, end < source.endIndex {
            textRunNotedEnd = endOffset
        }
    }

    /// Case 554591 (A7): the same for an attribute value, from `start` to
    /// `end` (its quotes left out). In a value upstream's attribute exception
    /// applies, "No digits after" names the value so far, and nothing inside
    /// the tag is an event of its own, so a message starts at the tag's "<",
    /// or just past the latest place noted in the tag before it (see
    /// tagNotedPlace). `additional` is the value's quote, or ">" for an
    /// unquoted value, and `following` the character after the value.
    /// (From A7's review: valueErrors are an unquoted value's messages about
    /// its characters, given among its references' messages in the order
    /// read; and the code-point messages read before the value go first.)
    private func appendAttributeReferenceDiagnostics(from start: String.Index, to end: String.Index, additional: Unicode.Scalar, following: Unicode.Scalar?, valueErrors: [HTMLToken], to tokens: inout [HTMLToken]) {
        let startOffset = locations.offset(of: start)
        appendCodePointMessages(through: startOffset - 1, floor: &tagNotedPlace, to: &tokens)
        let hasReference = start < end && source[start..<end].utf8.contains(UInt8(ascii: "&"))
        // (Without either, the value's code-point messages, if any, are given
        // with the tag's next message, or at its end, in order all the same.)
        guard hasReference || !valueErrors.isEmpty else {
            return
        }
        let firstToken = tokens.count
        _ = appendReferenceDiagnostics(hasReference ? Array(source.unicodeScalars[start..<end]) : [], context: .attribute(additional: additional), following: following, startOffset: startOffset, endOffset: locations.offset(of: end), noted: tagNotedPlace, notedFrom: startOffset, valueErrors: valueErrors, to: &tokens)
        for token in tokens[firstToken...] {
            if let last = Self.lastOffset(of: token) {
                tagNotedPlace = max(tagNotedPlace, last)
            }
        }
    }

    /// Case 554591 (A7): an end tag's attribute values, which upstream's
    /// tokenizer reads as it reads a start tag's (before it drops them, with
    /// "End tag had attributes."), so their references get the attribute
    /// rules and messages. This tokenizer only skips an end tag to its ">",
    /// so the values are found in what it skips, from `start` to `end` (the
    /// ">", or the end of the file): a name, then "=" and a quoted or
    /// unquoted value, as the start tag's loop reads them. (Upstream reports
    /// "End tag had attributes." when the tag ends, after these, and so does
    /// the port now.) Their places start from the tag's (see tagNotedPlace).
    private func appendEndTagReferenceDiagnostics(from start: String.Index, to end: String.Index, to tokens: inout [HTMLToken]) {
        guard start < end, source[start..<end].utf8.contains(UInt8(ascii: "&")) else {
            return
        }
        var index = start
        func skipSpaces(_ cursor: inout String.Index) {
            while cursor < end, Self.isHTMLSpace(source[cursor]) {
                source.formIndex(after: &cursor)
            }
        }
        while index < end {
            if Self.isHTMLSpace(source[index]) || "/" == source[index] {
                source.formIndex(after: &index)
                continue
            }
            // A name, up to white space, "/" or "=" (a first "=" is part of
            // it, as upstream's attribute-name state has it).
            source.formIndex(after: &index)
            while index < end, !Self.isHTMLSpace(source[index]), "/" != source[index], "=" != source[index] {
                source.formIndex(after: &index)
            }
            var cursor = index
            skipSpaces(&cursor)
            guard cursor < end, "=" == source[cursor] else {
                index = cursor
                continue
            }
            source.formIndex(after: &cursor)
            skipSpaces(&cursor)
            guard cursor < end else {
                break
            }
            if "\"" == source[cursor] || "'" == source[cursor] {
                let quote = source[cursor]
                source.formIndex(after: &cursor)
                let valueStart = cursor
                while cursor < end, quote != source[cursor] {
                    source.formIndex(after: &cursor)
                }
                appendAttributeReferenceDiagnostics(from: valueStart, to: cursor, additional: quote.unicodeScalars.first ?? "\"", following: cursor < source.endIndex ? source.unicodeScalars[cursor] : nil, valueErrors: [], to: &tokens)
                if cursor < end {
                    source.formIndex(after: &cursor)
                }
            } else {
                let valueStart = cursor
                while cursor < end, !Self.isHTMLSpace(source[cursor]) {
                    source.formIndex(after: &cursor)
                }
                appendAttributeReferenceDiagnostics(from: valueStart, to: cursor, additional: ">", following: cursor < source.endIndex ? source.unicodeScalars[cursor] : nil, valueErrors: [], to: &tokens)
            }
            index = cursor
        }
    }

    /// Case 554591 (A7): consume's events as message tokens, as they come (see
    /// ReferenceMessageSink), for the scalars from startOffset to endOffset;
    /// with, from A7's review, the code-point messages there and
    /// `valueErrors` among them, and no place noted before `notedFrom` (see
    /// appendTextReferenceDiagnostics). Returns the latest place noted.
    private func appendReferenceDiagnostics(_ scalars: [Unicode.Scalar], context: HTMLCharacterReferences.Context, following: Unicode.Scalar?, startOffset: Int, endOffset: Int, noted: Int, notedFrom: Int, valueErrors: [HTMLToken], to tokens: inout [HTMLToken]) -> Int? {
        let firstCodePoint = nextCodePointMessage
        while nextCodePointMessage < codePointMessages.count, codePointMessages[nextCodePointMessage].lastOffset < endOffset {
            nextCodePointMessage += 1
        }
        var sink = ReferenceMessageSink(
            scalars: scalars,
            startOffset: startOffset,
            noted: noted,
            firstLiteralPrivateUseLastOffset: firstLiteralPrivateUseLastOffset,
            codePoints: codePointMessages[firstCodePoint..<nextCodePointMessage],
            valueErrors: valueErrors,
            privateUseWarningKept: privateUseWarningKept,
            notedFrom: notedFrom
        )
        if !scalars.isEmpty {
            _ = HTMLCharacterReferences.consume(scalars, context: context, following: following, privateUseWarned: &privateUseWarned, collectingEvents: true, sink: &sink)
        }
        sink.finish()
        if sink.keptPrivateUseWarning {
            privateUseWarningKept = true
        }
        if sink.gaveLiteralPrivateUseWarning {
            privateUseWarned = true
        }
        tokens.append(contentsOf: sink.tokens)
        return sink.latestPlace
    }

    /// Case 554591 (A7): turns consume's events into message tokens. A
    /// message's last place comes from its index; its first is one past the
    /// latest place noted before that (vnu.jar's MessageEmitterAdapter rule):
    /// the places in `noted` (the one before the run or tag, and the tag's
    /// earlier messages' last places), the places consume notes, and each
    /// earlier message's last place. consume's indices only grow, but for a
    /// message at its "&", which still comes after the place before it; so
    /// offsets are found by walking forward, and the latest place below a last
    /// place is near the end of what was noted, where only the last few places
    /// are kept, with the latest one left out as a floor. The Private Use
    /// Area warning is left out when a literal such character comes first
    /// (see privateUseWarned); consume gives it for the first such reference
    /// only. (From A7's review: `noted` is one place, the latest before the
    /// run or the value, as the places only grow; and the code-point messages
    /// in the scalars, and an unquoted value's messages about its characters,
    /// are given among consume's, as they're read: see givePending.)
    private struct ReferenceMessageSink: HTMLCharacterReferenceEventSink {
        let scalars: [Unicode.Scalar]
        let noted: Int
        let firstLiteralPrivateUseLastOffset: Int?
        let codePoints: ArraySlice<CodePointMessage>
        let valueErrors: [HTMLToken]
        /// Whether a reference's Private Use Area warning came before these
        /// scalars, so that the literal one gets none.
        let privateUseWarningKept: Bool
        /// Where places start to be noted: the carriage returns before it, and
        /// the text handed on before an "&" there, are what the tree builder
        /// never hands on (see appendTextReferenceDiagnostics).
        let notedFrom: Int
        var tokens: [HTMLToken] = []
        var keptPrivateUseWarning = false
        var gaveLiteralPrivateUseWarning = false
        /// The latest place noted, the last one remembered.
        private(set) var latestPlace: Int?
        private var cursorIndex = 0
        private var cursorOffset: Int
        private let startOffset: Int
        private var recent: [Int] = []
        private var floor: Int?
        private var nextCodePoint: Int
        private var nextValueError = 0

        init(scalars: [Unicode.Scalar], startOffset: Int, noted: Int, firstLiteralPrivateUseLastOffset: Int?, codePoints: ArraySlice<CodePointMessage>, valueErrors: [HTMLToken], privateUseWarningKept: Bool, notedFrom: Int) {
            self.scalars = scalars
            self.startOffset = startOffset
            self.cursorOffset = startOffset
            self.noted = noted
            self.firstLiteralPrivateUseLastOffset = firstLiteralPrivateUseLastOffset
            self.codePoints = codePoints
            self.nextCodePoint = codePoints.startIndex
            self.valueErrors = valueErrors
            self.privateUseWarningKept = privateUseWarningKept
            self.notedFrom = notedFrom
        }

        /// Gives the messages read before consume's next event, at `place`:
        /// the code-point messages whose characters end there or before
        /// (checkChar comes as a character is read, before the reference it
        /// ends is handled), and the value's messages about its characters
        /// before it (upstream gives those as it handles the character, after
        /// the reference it ends: <p title=&#1"x> has the reference's two
        /// messages, then the quote's), in the order read.
        private mutating func givePending(before place: Int) {
            while true {
                let codePointLast = nextCodePoint < codePoints.endIndex ? codePoints[nextCodePoint].lastOffset : nil
                let valueErrorLast = nextValueError < valueErrors.count ? HTMLTokenizer.lastOffset(of: valueErrors[nextValueError]) : nil
                if let codePointLast, codePointLast <= place, codePointLast <= (valueErrorLast ?? Int.max) {
                    give(codePoints[nextCodePoint])
                    nextCodePoint += 1
                } else if let valueErrorLast, valueErrorLast < place {
                    tokens.append(valueErrors[nextValueError])
                    remember(valueErrorLast)
                    nextValueError += 1
                } else {
                    return
                }
            }
        }

        private mutating func give(_ codePoint: CodePointMessage) {
            if codePoint.isWarning {
                guard !privateUseWarningKept, !keptPrivateUseWarning else { return }
                gaveLiteralPrivateUseWarning = true
            }
            let first = latestBefore(codePoint.lastOffset) + 1
            remember(codePoint.lastOffset)
            tokens.append(.diagnostic(message: codePoint.message, isWarning: codePoint.isWarning, firstOffset: first, lastOffset: codePoint.lastOffset))
        }

        /// What's left, once consume is done.
        mutating func finish() {
            givePending(before: Int.max)
        }

        /// The UTF-16 offset of scalars[index] (or of the character after
        /// them, for the count): walked to from the last one asked for, or
        /// from the start if this one comes earlier.
        private mutating func offset(of index: Int) -> Int {
            if index < cursorIndex {
                cursorIndex = 0
                cursorOffset = startOffset
            }
            while cursorIndex < index, cursorIndex < scalars.count {
                cursorOffset += scalars[cursorIndex].utf16.count
                cursorIndex += 1
            }
            return cursorOffset
        }

        private mutating func remember(_ place: Int) {
            latestPlace = place
            recent.append(place)
            if 64 < recent.count {
                // (The places dropped are no later than those kept; the
                // latest of them stays as the floor.)
                let dropped = recent[0..<32].max() ?? place
                floor = max(floor ?? dropped, dropped)
                recent.removeFirst(32)
            }
        }

        private func latestBefore(_ last: Int) -> Int {
            var latest = noted < last ? noted : last - 1
            if let fromRecent = recent.last(where: { $0 < last }) {
                latest = max(latest, fromRecent)
            } else if let floor, floor < last {
                latest = max(latest, floor)
            }
            return latest
        }

        mutating func note(_ event: HTMLCharacterReferences.Event) {
            switch event {
            case let .placeBefore(index):
                let place = offset(of: index) - 1
                givePending(before: place)
                if notedFrom <= place {
                    remember(place)
                }
            case let .place(index):
                let place = offset(of: min(index, scalars.count))
                givePending(before: place)
                if notedFrom <= place {
                    remember(place)
                }
            case let .diagnostic(diagnostic):
                let last = offset(of: min(diagnostic.lastIndex, scalars.count))
                // (From A7's review: the messages before it are the ones read
                // before the tokenizer reported it, which for one placed at the
                // "&" takes in the character that stopped the name. Its offset
                // is found after the last place's, so the walk goes forward.)
                givePending(before: offset(of: min(diagnostic.readIndex, scalars.count)))
                if diagnostic.isWarning {
                    // (From A7's review: a literal in the BMP that ends the
                    // reference is read first, so it has the warning.)
                    if let literal = firstLiteralPrivateUseLastOffset, literal <= last {
                        return
                    }
                    keptPrivateUseWarning = true
                }
                let first = latestBefore(last) + 1
                remember(last)
                tokens.append(.diagnostic(message: diagnostic.message, isWarning: diagnostic.isWarning, firstOffset: first, lastOffset: last))
            }
        }
    }

    /// Where a message token ends, as vnu.jar's last place: a .diagnostic's
    /// last offset, or the offset before the end of a .parseError's
    /// (exclusive) length.
    private static func lastOffset(of token: HTMLToken) -> Int? {
        switch token {
        case let .parseError(_, offset, length):
            return offset + max(length, 1) - 1
        case let .diagnostic(_, _, _, lastOffset):
            return lastOffset
        default:
            return nil
        }
    }

    /// HTML's white space as upstream's tokenizer has it: space, tab, line
    /// feed, form feed and carriage return (and the CRLF pair, which is one
    /// Character).
    private static func isHTMLSpace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { 0x20 == $0.value || 0x09 == $0.value || 0x0A == $0.value || 0x0C == $0.value || 0x0D == $0.value }
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

    private func isAstralNonCharacter(_ value: UInt32) -> Bool {
        value > 0xFFFF && (value & 0xFFFE) == 0xFFFE && value <= 0x10FFFF
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
