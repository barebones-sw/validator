import Foundation
import Testing
@testable import VNUSwiftCore

@Test func validHTMLProducesNoErrors() {
    let validator = NuValidator()
    let input = DocumentInput(
        data: Data("<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body><p>Valid</p></body></html>".utf8),
        contentType: "text/html; charset=utf-8"
    )
    let result = validator.check(input: input, options: CheckerOptions(parameters: ["out": ["json"]]))
    #expect(result.messages.filter { $0.type == "error" }.isEmpty)
}

@Test func strayEndTagProducesErrorWithLocation() {
    let validator = NuValidator()
    let input = DocumentInput(
        data: Data("<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body></div></body></html>".utf8),
        contentType: "text/html; charset=utf-8"
    )
    let result = validator.check(input: input, options: CheckerOptions(parameters: ["out": ["json"]]))
    let error = result.messages.first { $0.type == "error" }
    #expect(error?.message.localizedCaseInsensitiveContains("Stray end tag") == true)
    #expect(error?.lastLine != nil)
}

@Test func jsonOutputMatchesNuShape() throws {
    let result = ValidationResult(messages: [.error("Stray end tag \u{201c}div\u{201d}.")])
    let rendered = OutputRenderer.render(result: result, format: .json)
    #expect(rendered.contentType.contains("application/json"))
    let object = try JSONSerialization.jsonObject(with: rendered.body) as? [String: Any]
    #expect(object?["messages"] is [Any])
}

@Test func serviceHandlesPostBodyAPI() throws {
    let service = NuHTTPService()
    let request = HTTPRequest(
        method: "POST",
        target: "/?out=gnu",
        headers: [
            "User-Agent": "swift-test",
            "Content-Type": "text/html; charset=utf-8"
        ],
        body: Data("<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body></div></body></html>".utf8)
    )
    let response = service.response(for: request)
    let text = String(decoding: response.body, as: UTF8.self)
    #expect(response.statusCode == 200)
    #expect(response.headers["Content-Type"]?.contains("text/plain") == true)
    #expect(text.contains("error:"))
}

@Test func sourceExtractRoundsUnicodeContextToCharacterBoundaries() {
    let locations = SourceLocationMap("Cafe\u{0301} test")
    let extract = locations.extract(offset: 4, length: 1, context: 2)
    #expect(extract.text.contains("e\u{0301}"))
}

@Test func htmlParserDiagnosticsMatchNuMessages() {
    let result = checkHTML("<!doctype html><meta charset=utf-8><title>T</title><div id=\"a\"class=\"b\">x</div>")
    #expect(result.messages.contains { $0.message == "No space between attributes." })
}

@Test func htmlParserReportsImpliedPEndWithOpenElements() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><p><ins><em>x</em><ul><li>y</li></ul></ins>")
    #expect(result.messages.contains { $0.message == "End tag \u{201c}p\u{201d} implied, but there were open elements." })
}

@Test func numericCharacterReferenceDiagnosticsMatchNuMessages() {
    let result = checkHTML("<!doctype html><meta charset=utf-8><title>T</title><p>&#x10FFFF;</p>")
    #expect(result.messages.contains { $0.message == "Character reference expands to an astral non-character (U+10ffff)." })
}

@Test func htmlDocumentParserEmitsBalancedTreeEvents() {
    let source = "<!doctype html><ul><li>one<li>two</ul><br><p>x<div>y</div>"
    let locations = SourceLocationMap(source)
    let document = HTMLDocumentParser(source: source, locations: locations).parse()
    var stack: [String] = []
    var sawImplicitListItemClose = false
    var sawVoidElementClose = false

    for event in document.events {
        switch event {
        case let .startElement(element):
            stack.append(element.name)
        case let .endElement(name, _, implicit):
            if name == "li", implicit {
                sawImplicitListItemClose = true
            }
            if name == "br", implicit {
                sawVoidElementClose = true
            }
            if let index = stack.lastIndex(of: name) {
                stack.removeSubrange(index...)
            }
        default:
            continue
        }
    }

    #expect(stack.isEmpty)
    #expect(sawImplicitListItemClose)
    #expect(sawVoidElementClose)
}

@Test func requiredAttributeCheckerConsumesParserEvents() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><picture><source><img src=x alt></picture><a download>file</a>")
    #expect(result.messages.contains { $0.message == "Element \u{201c}source\u{201d} is missing required attribute \u{201c}srcset\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}a\u{201d} is missing required attribute \u{201c}href\u{201d}." })
}

@Test func urlAttributeCheckerMatchesBadHrefMessages() {
    let nonCharacter = String(decoding: Data([0xEF, 0xB7, 0x90]), as: UTF8.self)
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><a href=\"http://example .org\"></a><a href=\"http://\(nonCharacter)zyx.com\"></a>")
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}http://example .org\u{201d} for attribute \u{201c}href\u{201d} on element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "Forbidden code point U+fdd0." })
}

@Test func urlAttributeCheckerRequiresAbsoluteItemtypeAndURLInputValues() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><div itemscope itemtype=\"/a/b/c\"></div><input type=url value=\"//foo/bar\">")
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}/a/b/c\u{201d} for attribute \u{201c}itemtype\u{201d} on element \u{201c}div\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}//foo/bar\u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}input\u{201d}." })
}

@Test func urlAttributeCheckerAllowsPermissiveHrefCases() {
    let result = checkHTML("<!DOCTYPE html>\n<html lang=en><meta charset=utf-8><title>T</title><a href=\"\"></a><a href=\"foo://\"></a><a href=\"#\u{03b2}\"></a>")
    #expect(result.messages.filter { $0.type == "error" }.isEmpty)
}

@Test func microdataAttributeCheckerEnforcesItemScopeDependencies() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><div itemtype=\"http://schema.org/Thing\"></div><div itemscope itemid=\"urn:uuid:12345\"></div><div itemref=x></div>")
    #expect(result.messages.contains { $0.message == "The \u{201c}itemtype\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemid\u{201d} attribute must not be specified on elements that do not have both an \u{201c}itemscope\u{201d} attribute and an \u{201c}itemtype\u{201d} attribute specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemref\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified." })
}

@Test func generalAttributeCheckerCoversLinkAndHreflangConstraints() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><link rel=stylesheet><area href=x alt=x hreflang=\"not a valid lang tag\">")
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}not a valid lang tag\u{201d} for attribute \u{201c}hreflang\u{201d} on element \u{201c}area\u{201d}." })
}

@Test func generalAttributeCheckerCoversResponsiveImageDependencies() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><img src=x alt sizes=100vw><img src=x alt srcset=\"x 100w, y 200w\"><link rel=preload as=image imagesizes=100vw><link rel=preload as=image imagesrcset=\"x 100w\">")
    #expect(result.messages.contains { $0.message == "The \u{201c}sizes\u{201d} attribute must only be specified if the \u{201c}srcset\u{201d} attribute is also specified." })
    #expect(result.messages.contains { $0.message == "When the \u{201c}srcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}sizes\u{201d} attribute must also be specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}imagesizes\u{201d} attribute must only be specified if the \u{201c}imagesrcset\u{201d} attribute is also specified." })
    #expect(result.messages.contains { $0.message == "When the \u{201c}imagesrcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}imagesizes\u{201d} attribute must also be specified." })
}

@Test func generalAttributeCheckerCoversLinkRelationConstraints() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><link rel=\"alternate stylesheet\" href=x><link rel=stylesheet href=x as=style><link rel=canonical href=x integrity=sha256-x><body><link rel=canonical href=x></body>")
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element with a \u{201c}rel\u{201d} attribute that contains both the values \u{201c}alternate\u{201d} and \u{201c}stylesheet\u{201d} must have a \u{201c}title\u{201d} attribute with a non-empty value." })
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element with an \u{201c}as\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}preload\u{201d} or the value \u{201c}modulepreload\u{201d}." })
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element with an \u{201c}integrity\u{201d} attribute must have a \u{201c}rel\u{201d} attribute that contains the value \u{201c}stylesheet\u{201d} or the value \u{201c}preload\u{201d} or the value \u{201c}modulepreload\u{201d}." })
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element must not appear as a descendant of a \u{201c}body\u{201d} element unless the \u{201c}link\u{201d} element has an \u{201c}itemprop\u{201d} attribute or has a \u{201c}rel\u{201d} attribute whose value contains \u{201c}dns-prefetch\u{201d}, \u{201c}modulepreload\u{201d}, \u{201c}pingback\u{201d}, \u{201c}preconnect\u{201d}, \u{201c}prefetch\u{201d}, \u{201c}preload\u{201d}, \u{201c}prerender\u{201d}, or \u{201c}stylesheet\u{201d}." })
}

@Test func generalAttributeCheckerCoversSizesAndSrcsetValues() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><img src=x alt srcset=\"x\" sizes=\"badvalue\"><img src=x alt srcset=\"x 1x, y 1.0x\"><img src=x alt srcset=\"x 100w, y 2x\"><img src=x alt srcset=\"x 100w\" sizes=\"auto\">")
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}x\u{201d} for attribute \u{201c}srcset\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}badvalue\u{201d} for attribute \u{201c}sizes\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}x 1x, y 1.0x\u{201d} for attribute \u{201c}srcset\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}x 100w, y 2x\u{201d} for attribute \u{201c}srcset\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "The \u{201c}sizes\u{201d} attribute value starting with \u{201c}auto\u{201d} is only valid for lazy-loaded images. Add \u{201c}loading=\u{201d}\u{201c}lazy\u{201d} to this element." })
}

@Test func generalAttributeCheckerCoversDateTimeValues() {
    let invalid = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><ins datetime=\"2014-02-29\"></ins><del datetime=\"2011-11-12T00:00:00+1500\"></del><time datetime=\"2024-01-01T25:00\"></time>")
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}2014-02-29\u{201d} for attribute \u{201c}datetime\u{201d} on element \u{201c}ins\u{201d}." })
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}2011-11-12T00:00:00+1500\u{201d} for attribute \u{201c}datetime\u{201d} on element \u{201c}del\u{201d}." })
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}2024-01-01T25:00\u{201d} for attribute \u{201c}datetime\u{201d} on element \u{201c}time\u{201d}." })

    let valid = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><ins datetime=\"2000-02-29\"></ins><del datetime=\"2011-11-12T06:54:39-08:00\"></del><time datetime=\"2024-01-01T12:00+02:00\"></time><time datetime=\"16:24:33.89\"></time>")
    #expect(valid.messages.filter { $0.type == "error" }.isEmpty)
}

@Test func xmlValidatorCoversXHTMLLinkHrefRequirement() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title><link rel=\"stylesheet\"/></head><body/></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both." })
}

private func checkHTML(_ source: String) -> ValidationResult {
    NuValidator().check(
        input: DocumentInput(data: Data(source.utf8), contentType: "text/html; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
}
