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

private func checkHTML(_ source: String) -> ValidationResult {
    NuValidator().check(
        input: DocumentInput(data: Data(source.utf8), contentType: "text/html; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
}
