import Darwin
import Foundation
import Testing
@testable import VNUCore
@testable import VNUServiceCore
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
    let service = NuHTTPService(validator: NuValidator())
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

@Test func serviceHandlesHeadRequestsWithoutBodies() {
    let service = NuHTTPService(validator: NuValidator())
    let response = service.response(for: HTTPRequest(
        method: "HEAD",
        target: "/",
        headers: ["User-Agent": "swift-test"]
    ))
    #expect(response.statusCode == 200)
    #expect(response.headers["Content-Type"]?.contains("text/html") == true)
    #expect(response.body.isEmpty)
}

@Test func serviceHandlesDocumentedMultipartFileUploads() throws {
    let service = NuHTTPService(validator: NuValidator())
    let body = multipartBody(boundary: "BOUNDARY", parts: [
        MultipartPart(name: "out", content: Data("json".utf8)),
        MultipartPart(name: "showsource", content: Data("yes".utf8)),
        MultipartPart(
            name: "file",
            filename: "sample.xhtml",
            contentType: "application/octet-stream",
            content: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body/></html>".utf8)
        )
    ])
    let response = service.response(for: HTTPRequest(
        method: "POST",
        target: "/",
        headers: [
            "User-Agent": "swift-test",
            "Content-Type": "multipart/form-data; boundary=BOUNDARY"
        ],
        body: body
    ))
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let source = try #require(object["source"] as? [String: Any])
    #expect(object["url"] as? String == "sample.xhtml")
    #expect(source["type"] as? String == "application/xhtml+xml")
}

@Test func serviceKeepsCompatibilityWithExistingUploadedFileField() throws {
    let service = NuHTTPService(validator: NuValidator())
    let body = multipartBody(boundary: "BOUNDARY", parts: [
        MultipartPart(name: "out", content: Data("json".utf8)),
        MultipartPart(name: "showsource", content: Data("yes".utf8)),
        MultipartPart(
            name: "uploaded_file",
            filename: #"C:\fakepath\bad.html"#,
            contentType: "application/octet-stream",
            content: Data("<!doctype html><html lang=en><title>T</title></div>".utf8)
        )
    ])
    let response = service.response(for: HTTPRequest(
        method: "POST",
        target: "/",
        headers: [
            "User-Agent": "swift-test",
            "Content-Type": "multipart/form-data; boundary=BOUNDARY"
        ],
        body: body
    ))
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let source = try #require(object["source"] as? [String: Any])
    #expect(object["url"] as? String == "bad.html")
    #expect(source["type"] as? String == "text/html")
}

@Test func serviceReportsFetchInputErrors() throws {
    let service = NuHTTPService(validator: NuValidator())
    let response = service.response(for: HTTPRequest(
        method: "GET",
        target: "/?out=json&doc=file%3A%2F%2F%2Ftmp%2Ftest.html",
        headers: ["User-Agent": "swift-test"]
    ))
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(object["url"] as? String == "file:///tmp/test.html")
    #expect(messages.contains { $0["type"] as? String == "non-document-error" && ($0["message"] as? String)?.contains("HTTP or HTTPS") == true })
}

@Test func serviceReportsRemoteHTTPStatusErrors() throws {
    let server = try OneShotHTTPFixture(
        statusCode: 404,
        reason: "Not Found",
        body: "<!doctype html><html lang=en><title>T</title><p>Missing</p>"
    )
    server.start()
    defer { server.stop() }

    let service = NuHTTPService(validator: NuValidator())
    let response = service.response(for: HTTPRequest(
        method: "GET",
        target: "/?out=json&doc=\(QueryParser.percentEncodeForTests("http://127.0.0.1:\(server.port)/missing"))",
        headers: ["User-Agent": "swift-test"]
    ))
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.contains { $0["type"] as? String == "non-document-error" && ($0["message"] as? String)?.contains("404") == true })
}

@Test func serviceCanCheckRemoteErrorPagesWhenRequested() throws {
    let server = try OneShotHTTPFixture(
        statusCode: 404,
        reason: "Not Found",
        body: "<!doctype html><html lang=en><title>T</title></div>"
    )
    server.start()
    defer { server.stop() }

    let service = NuHTTPService(validator: NuValidator())
    let response = service.response(for: HTTPRequest(
        method: "GET",
        target: "/?out=json&checkerrorpages=yes&doc=\(QueryParser.percentEncodeForTests("http://127.0.0.1:\(server.port)/missing"))",
        headers: ["User-Agent": "swift-test"]
    ))
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(!messages.contains { $0["type"] as? String == "non-document-error" })
    #expect(messages.contains { ($0["message"] as? String)?.contains("Stray end tag") == true })
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

// Numeric references to tab, line feed and form feed are fine, in text and in
// attribute values (title="line 1&#10;line 2" is a common way to write a
// multi-line tooltip, and used to be reported as a control character); the
// other C0 controls and DEL are errors, carriage return has its own message,
// and the whole U+FDD0–U+FDEF block is unassigned, as in upstream's
// tokenizer. The expected messages are vnu.jar's.
@Test(arguments: [
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#9;b\">x</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#10;b\">x</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#12;b\">x</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#13;b\">x</p>\n", [("error", "A numeric character reference expanded to carriage return.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#11;b\">x</p>\n", [("error", "Character reference expands to a control character (U+000b).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#x1f;b\">x</p>\n", [("error", "Character reference expands to a control character (U+001f).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#x7f;b\">x</p>\n", [("error", "Character reference expands to a control character (U+007f).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#xfdd5;b\">x</p>\n", [("error", "Character reference expands to a permanently unassigned code point.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#xfdef;b\">x</p>\n", [("error", "Character reference expands to a permanently unassigned code point.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p title=\"a&#xfdf0;b\">x</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#9;b</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#10;b</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#12;b</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#13;b</p>\n", [("error", "A numeric character reference expanded to carriage return.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#11;b</p>\n", [("error", "Character reference expands to a control character (U+000b).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x1f;b</p>\n", [("error", "Character reference expands to a control character (U+001f).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x7f;b</p>\n", [("error", "Character reference expands to a control character (U+007f).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xfdd5;b</p>\n", [("error", "Character reference expands to a permanently unassigned code point.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xfdef;b</p>\n", [("error", "Character reference expands to a permanently unassigned code point.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xfdf0;b</p>\n", []),
    // And the rest of upstream's classification, in text, in an attribute
    // value and in a <textarea>, decimal or hexadecimal, with or without the
    // semicolon: zero, the C1 range, surrogates, non-characters, and values
    // out of range (a UInt32's overflow included); and nothing where
    // references aren't parsed at all (comments, script and CDATA).
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x0;b</p>\n<p title=\"a&#x0;b\">x</p>\n<textarea>a&#x0;b</textarea>\n", [("error", "Character reference expands to zero."), ("error", "Character reference expands to zero."), ("error", "Character reference expands to zero.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#10 b</p>\n<p title=\"a&#10 b\">x</p>\n", [("error", "Character reference was not terminated by a semicolon."), ("error", "Character reference was not terminated by a semicolon.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#11;b</p>\n<p title=\"a&#11;b\">x</p>\n<textarea>a&#11;b</textarea>\n", [("error", "Character reference expands to a control character (U+000b)."), ("error", "Character reference expands to a control character (U+000b)."), ("error", "Character reference expands to a control character (U+000b).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xb b</p>\n<p title=\"a&#xb b\">x</p>\n", [("error", "Character reference expands to a control character (U+000b)."), ("error", "Character reference expands to a control character (U+000b)."), ("error", "Character reference was not terminated by a semicolon."), ("error", "Character reference was not terminated by a semicolon.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#13 b</p>\n<p title=\"a&#13 b\">x</p>\n", [("error", "A numeric character reference expanded to carriage return."), ("error", "A numeric character reference expanded to carriage return."), ("error", "Character reference was not terminated by a semicolon."), ("error", "Character reference was not terminated by a semicolon.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x7e;b</p>\n<p title=\"a&#x7e;b\">x</p>\n<textarea>a&#x7e;b</textarea>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x80;b</p>\n<p title=\"a&#x80;b\">x</p>\n<textarea>a&#x80;b</textarea>\n", [("error", "A numeric character reference expanded to the C1 controls range."), ("error", "A numeric character reference expanded to the C1 controls range."), ("error", "A numeric character reference expanded to the C1 controls range.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x80 b</p>\n<p title=\"a&#x80 b\">x</p>\n", [("error", "A numeric character reference expanded to the C1 controls range."), ("error", "A numeric character reference expanded to the C1 controls range."), ("error", "Character reference was not terminated by a semicolon."), ("error", "Character reference was not terminated by a semicolon.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x9f;b</p>\n<p title=\"a&#x9f;b\">x</p>\n<textarea>a&#x9f;b</textarea>\n", [("error", "A numeric character reference expanded to the C1 controls range."), ("error", "A numeric character reference expanded to the C1 controls range."), ("error", "A numeric character reference expanded to the C1 controls range.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xa0;b</p>\n<p title=\"a&#xa0;b\">x</p>\n<textarea>a&#xa0;b</textarea>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xd800;b</p>\n<p title=\"a&#xd800;b\">x</p>\n<textarea>a&#xd800;b</textarea>\n", [("error", "Character reference expands to a surrogate."), ("error", "Character reference expands to a surrogate."), ("error", "Character reference expands to a surrogate.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#57343;b</p>\n<p title=\"a&#57343;b\">x</p>\n<textarea>a&#57343;b</textarea>\n", [("error", "Character reference expands to a surrogate."), ("error", "Character reference expands to a surrogate."), ("error", "Character reference expands to a surrogate.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xfffd;b</p>\n<p title=\"a&#xfffd;b\">x</p>\n<textarea>a&#xfffd;b</textarea>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#xfffe;b</p>\n<p title=\"a&#xfffe;b\">x</p>\n<textarea>a&#xfffe;b</textarea>\n", [("error", "Character reference expands to a non-character (U+fffe)."), ("error", "Character reference expands to a non-character (U+fffe)."), ("error", "Character reference expands to a non-character (U+fffe).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#65535;b</p>\n<p title=\"a&#65535;b\">x</p>\n<textarea>a&#65535;b</textarea>\n", [("error", "Character reference expands to a non-character (U+ffff)."), ("error", "Character reference expands to a non-character (U+ffff)."), ("error", "Character reference expands to a non-character (U+ffff).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x1fffe;b</p>\n<p title=\"a&#x1fffe;b\">x</p>\n<textarea>a&#x1fffe;b</textarea>\n", [("error", "Character reference expands to an astral non-character (U+1fffe)."), ("error", "Character reference expands to an astral non-character (U+1fffe)."), ("error", "Character reference expands to an astral non-character (U+1fffe).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x10ffff;b</p>\n<p title=\"a&#x10ffff;b\">x</p>\n<textarea>a&#x10ffff;b</textarea>\n", [("error", "Character reference expands to an astral non-character (U+10ffff)."), ("error", "Character reference expands to an astral non-character (U+10ffff)."), ("error", "Character reference expands to an astral non-character (U+10ffff).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x110000;b</p>\n<p title=\"a&#x110000;b\">x</p>\n<textarea>a&#x110000;b</textarea>\n", [("error", "Character reference outside the permissible Unicode range."), ("error", "Character reference outside the permissible Unicode range."), ("error", "Character reference outside the permissible Unicode range.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x100000000;b</p>\n<p title=\"a&#x100000000;b\">x</p>\n<textarea>a&#x100000000;b</textarea>\n", [("error", "Character reference outside the permissible Unicode range."), ("error", "Character reference outside the permissible Unicode range."), ("error", "Character reference outside the permissible Unicode range.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x0;b</p>\n<p title=\"a&#x0;b\">x</p>\n", [("error", "Character reference expands to zero."), ("error", "Character reference expands to zero.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#X1F;b</p>\n<p title=\"a&#X1F;b\">x</p>\n", [("error", "Character reference expands to a control character (U+001f)."), ("error", "Character reference expands to a control character (U+001f).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#0000010;b</p>\n<p title=\"a&#0000010;b\">x</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a&#x000A;b</p>\n<p title=\"a&#x000A;b\">x</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=1 height=1><title>a&#10;b</title><rect width=1 height=1 aria-label=\"a&#10;b&#11;c\"/></svg>\n", [("error", "Character reference expands to a control character (U+000b).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<!-- a&#11;b&#10;c -->\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<script>var s = \"&#11;&#10;\";</script>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=1 height=1><text><![CDATA[a&#11;b]]></text></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<img src=x alt=\"a&#12;b\">\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<textarea>a&#11;b&#10;c</textarea>\n", [("error", "Character reference expands to a control character (U+000b).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<math><mi>&#11;</mi><mi>&#10;</mi></math>\n", [("error", "Character reference expands to a control character (U+000b).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>&#9;&#10;&#12;&#13;&#11;&#127;&#128;&#xfdd0;&#xfdef;</p>\n", [("error", "A numeric character reference expanded to carriage return."), ("error", "A numeric character reference expanded to the C1 controls range."), ("error", "Character reference expands to a control character (U+000b)."), ("error", "Character reference expands to a control character (U+007f)."), ("error", "Character reference expands to a permanently unassigned code point."), ("error", "Character reference expands to a permanently unassigned code point.")]),
] as [(String, [(String, String)])])
func controlCharacterReferencesMatchUpstream(document: String, expected: [(String, String)]) {
    let actual = checkHTML(document).messages
        .filter { $0.type != "info" || $0.subType == "warning" }
        .map { "\($0.type == "info" ? "warning" : "error"): \($0.message)" }
        .sorted()
    #expect(actual == expected.map { "\($0.0): \($0.1)" }.sorted(), "\(document)")
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
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><div itemtype=\"http://schema.org/Thing\"></div><div itemscope itemid=\"urn:uuid:12345\"></div><div itemref=x></div><span itemprop=name>Orphan</span><div itemscope itemref=\"missing ref ref\"></div><div id=ref itemprop=name>Name</div>")
    #expect(result.messages.contains { $0.message == "The \u{201c}itemtype\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemid\u{201d} attribute must not be specified on elements that do not have both an \u{201c}itemscope\u{201d} attribute and an \u{201c}itemtype\u{201d} attribute specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemref\u{201d} attribute must not be specified on elements that do not have an \u{201c}itemscope\u{201d} attribute specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemprop\u{201d} attribute was specified, but the element is not a property of any item." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemref\u{201d} attribute referenced \u{201c}missing\u{201d}, but there is no element with an \u{201c}id\u{201d} attribute with that value." })
    #expect(result.messages.contains { $0.message == "The \u{201c}itemref\u{201d} attribute contained redundant references." })
}

@Test func generalAttributeCheckerCoversLinkAndHreflangConstraints() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><link rel=stylesheet><area href=x alt=x hreflang=\"not a valid lang tag\">")
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}not a valid lang tag\u{201d} for attribute \u{201c}hreflang\u{201d} on element \u{201c}area\u{201d}." })
}

@Test func generalAttributeCheckerCoversMediaQueryAttributes() {
    let invalid = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><link rel=stylesheet href=x media=\"screen and(min-width: 400px)\"><link rel=stylesheet href=x media=\"screen and (color: 1em)\"><link rel=stylesheet href=x media=\"screen,,print\"><link rel=stylesheet href=x media=\"projection\">")
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}screen and(min-width: 400px)\u{201d} for attribute \u{201c}media\u{201d} on element \u{201c}link\u{201d}." })
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}screen and (color: 1em)\u{201d} for attribute \u{201c}media\u{201d} on element \u{201c}link\u{201d}." })
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}screen,,print\u{201d} for attribute \u{201c}media\u{201d} on element \u{201c}link\u{201d}." })
    #expect(invalid.messages.contains { $0.message == "Bad value \u{201c}projection\u{201d} for attribute \u{201c}media\u{201d} on element \u{201c}link\u{201d}." })

    let valid = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><link rel=stylesheet href=x media=\"screen and (min-width: 400px)and (max-width: 600px)\"><link rel=stylesheet href=x media=\"screen and (min-width: .0)\"><link rel=stylesheet href=x media=\"print and (min-resolution: 100dpi)\"><style media=\"screen and (color: 1)\"></style>")
    #expect(valid.messages.filter { $0.type == "error" }.isEmpty)
}

@Test func generalAttributeCheckerCoversDatatypeAttributeValues() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <a href=x target=""></a><a href=x target="_foo"></a>
        <div id=""></div><div id="foo bar"></div>
        <button is="mybutton">click</button><button is="1-button">click</button>
        <input type=date min="2024-02-30">
        <input type=datetime-local min="2024-13-01T12:00">
        <input type=month min="2024-00">
        <input type=time min="25:00">
        <input type=week min="2024-W54">
        <input type=number step="abc">
        <input name="">
        <input type=text placeholder="line1
        line2">
        <object type="text"></object>
        <iframe sandbox="allow-everything"></iframe>
        <iframe sandbox="allow-scripts allow-scripts"></iframe>
        <iframe sandbox="allow-scripts allow-same-origin"></iframe>
        <script src=x integrity="md5-abc123"></script>
        <span lang="ja-Jpan">Japanese</span>
        """)
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}\u{201d} for attribute \u{201c}target\u{201d} on element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}_foo\u{201d} for attribute \u{201c}target\u{201d} on element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}div\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}foo bar\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}div\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}mybutton\u{201d} for attribute \u{201c}is\u{201d} on element \u{201c}button\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}1-button\u{201d} for attribute \u{201c}is\u{201d} on element \u{201c}button\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}2024-02-30\u{201d} for attribute \u{201c}min\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}2024-13-01T12:00\u{201d} for attribute \u{201c}min\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}2024-00\u{201d} for attribute \u{201c}min\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}25:00\u{201d} for attribute \u{201c}min\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}2024-W54\u{201d} for attribute \u{201c}min\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}abc\u{201d} for attribute \u{201c}step\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}\u{201d} for attribute \u{201c}name\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message.contains("attribute \u{201c}placeholder\u{201d}") && $0.message.contains("line1") })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}text\u{201d} for attribute \u{201c}type\u{201d} on element \u{201c}object\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}allow-everything\u{201d} for attribute \u{201c}sandbox\u{201d} on element \u{201c}iframe\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}allow-scripts allow-scripts\u{201d} for attribute \u{201c}sandbox\u{201d} on element \u{201c}iframe\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}allow-scripts allow-same-origin\u{201d} for attribute \u{201c}sandbox\u{201d} on element \u{201c}iframe\u{201d}." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}md5-abc123\u{201d} for attribute \u{201c}integrity\u{201d} on element \u{201c}script\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}ja-Jpan\u{201d} for attribute \u{201c}lang\u{201d} on element \u{201c}span\u{201d}." && $0.subType == "warning" })

    let valid = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><a href=x target=_blank></a><a href=x target=myframe></a><div id=foo></div><button is=my-button>click</button><input type=date min=2024-02-29><input type=datetime-local min=2024-12-31T12:00><input type=month min=2024-12><input type=time min=12:30:59><input type=week min=2024-W52><input type=number step=any><input type=number step=0.1><object data=x type=text/html></object><iframe sandbox=\"allow-scripts\"></iframe><script src=x integrity=sha256-abc123></script>")
    #expect(valid.messages.filter { $0.type == "error" }.isEmpty)
}

@Test func generalAttributeCheckerCoversGlobalAttributesAndBaseRules() {
    let result = checkHTML("""
        <!doctype html><html lang=zzz><meta charset=utf-8><title>T</title>
        <a href=x accesskey="a b a" rel=authr spellcheck=badvalue>Author</a>
        <p data->Text</p><div name=n popover=invalid></div>
        <input enterkeyhint=""><article headingoffset=9><h1>Heading</h1></article>
        <button autofocus></button><button autofocus></button>
        <link rel=styleshet href=x><base><script src=x></script><base href=bar>
        """)
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}zzz\u{201d} for attribute \u{201c}lang\u{201d} on element \u{201c}html\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}a b a\u{201d} for attribute \u{201c}accesskey\u{201d} on element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}authr\u{201d} for attribute \u{201c}rel\u{201d} on element \u{201c}a\u{201d}: Bad list of link-type keywords:  Typo for \u{201c}author\u{201d}?" && $0.type == "info" })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}badvalue\u{201d} for attribute \u{201c}spellcheck\u{201d} on element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}data-\u{201d} not allowed on element \u{201c}p\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}name\u{201d} not allowed on element \u{201c}div\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}invalid\u{201d} for attribute \u{201c}popover\u{201d} on element \u{201c}div\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}\u{201d} for attribute \u{201c}enterkeyhint\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}headingoffset\u{201d} attribute must be a number between \u{201c}0\u{201d} and \u{201c}8\u{201d}." })
    #expect(result.messages.contains { $0.message == "There must not be two elements with the same \"nearest ancestor autofocus scoping root element\" that both have the \u{201c}autofocus\u{201d} attribute specified." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}base\u{201d} is missing one or more of the following attributes: \u{201c}href\u{201d}, \u{201c}target\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}base\u{201d} not allowed as child of \u{201c}body\u{201d} in this context." })

    let missingLang = checkHTML("<!doctype html><meta charset=utf-8><title>T</title>")
    #expect(missingLang.messages.contains { $0.message == "Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document." && $0.subType == "warning" })
}

@Test func generalAttributeCheckerCoversStructuralAssertions() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <area href=x>
        <bdo>text</bdo><bdo dir=auto>text</bdo>
        <figure><figcaption>One</figcaption><figcaption>Two</figcaption></figure>
        <input type=file value=x>
        <label for=other aria-hidden=true><input id=field><input id=second></label>
        <label for=missing>Missing</label><div id=notcontrol></div><label for=notcontrol>Bad</label>
        <article><main></main></article><nav><main></main></nav>
        <map id=a name=b></map>
        <ul><li value=5>Value</li></ul><ol><li value=abc>Bad</li></ol><div><li>Loose</li></div>
        <label role=button><input></label>
        <div aria-readonly=true></div>
        """)
    #expect(result.messages.contains { $0.message == "The \u{201c}area\u{201d} element must have a \u{201c}map\u{201d} ancestor." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}bdo\u{201d} must have attribute \u{201c}dir\u{201d}." })
    #expect(result.messages.contains { $0.message == "The value of \u{201c}dir\u{201d} attribute for the \u{201c}bdo\u{201d} element must not be \u{201c}auto\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}figcaption\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}value\u{201d} not allowed on element \u{201c}input\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-hidden\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element." })
    #expect(result.messages.contains { $0.message == "Any \u{201c}input\u{201d} descendant of a \u{201c}label\u{201d} element with a \u{201c}for\u{201d} attribute must have an ID value that matches that \u{201c}for\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The \u{201c}label\u{201d} element may contain at most one \u{201c}button\u{201d}, \u{201c}input\u{201d}, \u{201c}meter\u{201d}, \u{201c}output\u{201d}, \u{201c}progress\u{201d}, \u{201c}select\u{201d}, or \u{201c}textarea\u{201d} descendant." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}for\u{201d} attribute of the \u{201c}label\u{201d} element must be the ID of a non-hidden form control." })
    #expect(result.messages.contains { $0.message == "The \u{201c}main\u{201d} element must not appear as a descendant of the \u{201c}article\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The \u{201c}main\u{201d} element must not appear as a descendant of the \u{201c}nav\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The \u{201c}id\u{201d} attribute on a \u{201c}map\u{201d} element must have an the same value as the \u{201c}name\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}value\u{201d} not allowed on element \u{201c}li\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}abc\u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}li\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}li\u{201d} not allowed as child of \u{201c}div\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}input\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=button\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}div\u{201d} is missing one or more of the following attributes: \u{201c}aria-checked\u{201d}, \u{201c}aria-expanded\u{201d}, \u{201c}aria-valuenow\u{201d}, \u{201c}role\u{201d}." })
}

@Test func generalAttributeCheckerCoversResponsiveImageDependencies() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><img src=x alt sizes=100vw><img src=x alt srcset=\"x 100w, y 200w\"><link rel=preload as=image imagesizes=100vw><link rel=preload as=image imagesrcset=\"x 100w\">")
    #expect(result.messages.contains { $0.message == "The \u{201c}sizes\u{201d} attribute must only be specified if the \u{201c}srcset\u{201d} attribute is also specified." })
    #expect(result.messages.contains { $0.message == "When the \u{201c}srcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}sizes\u{201d} attribute must also be specified." })
    #expect(result.messages.contains { $0.message == "The \u{201c}imagesizes\u{201d} attribute must only be specified if the \u{201c}imagesrcset\u{201d} attribute is also specified." })
    #expect(result.messages.contains { $0.message == "When the \u{201c}imagesrcset\u{201d} attribute has any image candidate string with a width descriptor, the \u{201c}imagesizes\u{201d} attribute must also be specified." })
}

@Test func generalAttributeCheckerCoversPictureContentModel() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><picture>x<br><source srcset=x><source srcset=y><img src=x alt><img src=y alt></picture><picture><script></script></picture>")
    #expect(result.messages.contains { $0.message == "Text not allowed in \u{201c}picture\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}br\u{201d} not allowed as child of \u{201c}picture\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "A \u{201c}source\u{201d} element that has a following sibling \u{201c}source\u{201d} element or \u{201c}img\u{201d} element with a \u{201c}srcset\u{201d} attribute must have a \u{201c}media\u{201d} attribute and/or \u{201c}type\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}img\u{201d} not allowed as child of \u{201c}picture\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}picture\u{201d} is missing a required instance of child element \u{201c}img\u{201d}." })
}

@Test func generalAttributeCheckerCoversPictureAttributes() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><picture role=img><source srcset=x crossorigin><img src=x alt type=image/png></picture><video srcset=x></video>")
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}picture\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}crossorigin\u{201d} not allowed on element \u{201c}source\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}type\u{201d} not allowed on element \u{201c}img\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}srcset\u{201d} not allowed on element \u{201c}video\u{201d} at this point." })
}

@Test func generalAttributeCheckerCoversPictureSelectionAndSizesRules() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><picture><source srcset=x media=all><source srcset=y><img src=x alt></picture><picture><source srcset=\"x 100w\" sizes=auto media=screen><img src=x alt></picture><img src=x alt srcset=\"x 100w, y 200w\" sizes=\"100vw, (min-width:500px) 500px\"><img alt>")
    #expect(result.messages.contains { $0.message == "Value of \u{201c}media\u{201d} attribute here must not be \u{201c}all\u{201d}." })
    #expect(result.messages.contains { $0.message == "The \u{201c}sizes\u{201d} attribute value starting with \u{201c}auto\u{201d} is only valid for lazy-loaded images. The \u{201c}img\u{201d} element must have a \u{201c}loading\u{201d} attribute set to \u{201c}lazy\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}100vw, (min-width:500px) 500px\u{201d} for attribute \u{201c}sizes\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}img\u{201d} is missing one or more of the following attributes: \u{201c}src\u{201d}, \u{201c}srcset\u{201d}." })
}

@Test func definitionListCheckerCoversStructureAndDuplicateTerms() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><dl>x<dl></dl><dd>first</dd><dt>Term</dt><dd>one</dd><dt>Term</dt><dd>two</dd><dt><h2>Heading</h2><dd>heading</dd><div><span>bad</span></div></dl><dl><div><dt>Only</dt></div><div><dd>definition</dd></div><div><dt>A</dt><dd>B</dd><dt>C</dt></div></dl>")
    #expect(result.messages.contains { $0.message == "Text not allowed in \u{201c}dl\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}dl\u{201d} not allowed as child of \u{201c}dl\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}dl\u{201d} is missing a required child element." })
    #expect(result.messages.contains { $0.message == "Duplicate \u{201c}dt\u{201d} name \u{201c}Term\u{201d} in \u{201c}dl\u{201d} element. Within a single \u{201c}dl\u{201d} element, there should not be more than one \u{201c}dt\u{201d} element for each name." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The element \u{201c}h2\u{201d} must not appear as a descendant of the \u{201c}dt\u{201d} element." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}span\u{201d} not allowed as child of \u{201c}div\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}div\u{201d} is missing a required instance of child element \u{201c}dd\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}div\u{201d} is missing a required instance of child element \u{201c}dt\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}dt\u{201d} not allowed as child of \u{201c}div\u{201d} in this context." })
}

@Test func htmlValidatorReportsObsoleteKeygen() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><form><keygen name=k></form>")
    #expect(result.messages.contains { $0.message == "The \u{201c}keygen\u{201d} element is obsolete." })
}

@Test func htmlValidatorCoversObsoleteElementWordingAndProfile() {
    let result = checkHTML("<!doctype html><html lang=en><head profile=\"http://example.test\"><title>T</title></head><body><center>x</center><dir><li>x</li></dir><blink>x</blink><menuitem label=x>x</menuitem><object data=x><param name=p value=v></object></body></html>")
    #expect(result.messages.contains { $0.message == "The \u{201c}center\u{201d} element is obsolete. Use CSS instead." })
    #expect(result.messages.contains { $0.message == "The \u{201c}dir\u{201d} element is obsolete. Use the \u{201c}ul\u{201d} element instead." })
    #expect(result.messages.contains { $0.message == "The \u{201c}blink\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content." })
    #expect(result.messages.contains { $0.message == "The \u{201c}menuitem\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content." })
    #expect(result.messages.contains { $0.message == "The \u{201c}param\u{201d} element is obsolete. Use the \u{201c}data\u{201d} attribute of the \u{201c}object\u{201d} element to set the URL of the external resource." })
    #expect(result.messages.contains { $0.message == "The \u{201c}profile\u{201d} attribute on the \u{201c}head\u{201d} element is obsolete. To declare which \u{201c}meta\u{201d} terms are used in the document, instead register the names as meta extensions. To trigger specific UA behaviors, use a \u{201c}link\u{201d} element instead." && $0.subType == "warning" })
}

@Test func tableCheckerCoversCellSpansHeadersAndRoles() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <table>
          <colgroup><col span=1001></colgroup>
          <tr><td rowspan=2>A</td><td>B</td></tr>
          <tr><td colspan=2 headers=missing role=button>C</td></tr>
        </table>
        <table><tr><td colspan=0>zero</td><td rowspan=65535>tall</td></tr></table>
        """)
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}span\u{201d} attribute must be less than or equal to 1000." })
    #expect(result.messages.contains { $0.message == "Table column 3 established by element \u{201c}td\u{201d} has no cells beginning in it." })
    #expect(result.messages.contains { $0.message == "The \u{201c}headers\u{201d} attribute on the element \u{201c}td\u{201d} refers to the ID \u{201c}missing\u{201d}, but there is no \u{201c}th\u{201d} element with that ID in the same table." })
    #expect(result.messages.contains { $0.message == "The \u{201c}role\u{201d} attribute must not be used on a \u{201c}td\u{201d} element which has a \u{201c}table\u{201d} ancestor with no \u{201c}role\u{201d} attribute, or with a \u{201c}role\u{201d} attribute whose value is \u{201c}table\u{201d}, \u{201c}grid\u{201d}, or \u{201c}treegrid\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}0\u{201d} for attribute \u{201c}colspan\u{201d} on element \u{201c}td\u{201d}." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}rowspan\u{201d} attribute must be less than or equal to 65534." })
}

@Test func tableCheckerCoversRowGroupsWidthsAndTableInsertionMode() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <table><tr><td>1</td><td>2</td><td>3</td></tr><tr><td>1</td><td>2</td></tr><tr><td>1</td><td>2</td><td>3</td><td>4</td></tr></table>
        <table><tbody><tr><td rowspan=3>x</td></tr><tr><td>y</td></tr></tbody></table>
        <table><tr><td>x</td></tr><tr></tr></table>
        <table><input></table>
        """)
    #expect(result.messages.contains { $0.message == "A table row was 2 columns wide, which is less than the column count established by the first row (3)." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "A table row was 4 columns wide and exceeded the column count established by the first row (3)." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Table cell spans past the end of its row group established by a \u{201c}tbody\u{201d} element; clipped to the end of the row group." })
    #expect(result.messages.contains { $0.message == "Row 2 of a row group established by a \u{201c}tbody\u{201d} element has no cells beginning on it." })
    #expect(result.messages.contains { $0.message == "Start tag \u{201c}input\u{201d} seen in \u{201c}table\u{201d}." })
}

@Test func generalAttributeCheckerCoversElementSpecificContentRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <a media=all name=anchor>link</a><button><a href=/x>link</a></button>
        <map name=m><area shape=default coords="1,2" media=all type="bad"></map>
        <iframe allowpaymentrequest seamless>text</iframe>
        <select><option aria-selected=true></option><option label=""></option></select>
        <details><p>Before summary</p><summary>Late</summary><summary>Again</summary></details>
        <figure role=img><img src=x alt><table><caption>Table</caption><tr><td>x</td></tr></table><figcaption>Caption</figcaption><img src=y alt></figure>
        <address><address>Nested</address></address>
        <article><p>No heading</p></article><section><p>No heading</p></section>
        <button><audio controls loading=auto></audio></button>
        <header><footer></footer></header><footer><header></header></footer>
        """)
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}media\u{201d} not allowed on element \u{201c}a\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "The \u{201c}name\u{201d} attribute on the \u{201c}a\u{201d} element is obsolete. Consider putting an \u{201c}id\u{201d} attribute on the nearest container instead." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The element \u{201c}a\u{201d} with the attribute \u{201c}href\u{201d} must not appear as a descendant of the \u{201c}button\u{201d} element." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}coords\u{201d} not allowed on element \u{201c}area\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}bad\u{201d} for attribute \u{201c}type\u{201d} on element \u{201c}area\u{201d}." })
    #expect(result.messages.contains { $0.message == "Text not allowed in \u{201c}iframe\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-selected\u{201d} attribute should not be used on the \u{201c}option\u{201d} element." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Element \u{201c}option\u{201d} without attribute \u{201c}label\u{201d} must not be empty." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}details\u{201d} is missing a required instance of child element \u{201c}summary\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}summary\u{201d} not allowed as child of \u{201c}details\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "A \u{201c}figure\u{201d} element with a \u{201c}figcaption\u{201d} descendant must not have a \u{201c}role\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "When a \u{201c}table\u{201d} element is the only content in a \u{201c}figure\u{201d} element other than the \u{201c}figcaption\u{201d}, the \u{201c}caption\u{201d} element should be omitted in favor of the \u{201c}figcaption\u{201d}." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Element \u{201c}img\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}address\u{201d} must not appear as a descendant of the \u{201c}address\u{201d} element." })
    #expect(result.messages.contains { $0.message == "Article lacks heading. Consider using \u{201c}h2\u{201d}-\u{201c}h6\u{201d} elements to add identifying headings to all articles." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Section lacks heading. Consider using \u{201c}h2\u{201d}-\u{201c}h6\u{201d} elements to add identifying headings to all sections, or else use a \u{201c}div\u{201d} element instead for any cases where no heading is needed." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The element \u{201c}audio\u{201d} with the attribute \u{201c}controls\u{201d} must not appear as a descendant of the \u{201c}button\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}footer\u{201d} must not appear as a descendant of the \u{201c}header\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}header\u{201d} must not appear as a descendant of the \u{201c}footer\u{201d} element." })
}

@Test func generalAttributeCheckerCoversHeadingsRubyAndSmallElementRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <h2></h2><h1>Main</h1><h3>Skipped</h3>
        <ruby></ruby><ruby><rt></rt><rp></rp><rp></rp></ruby>
        <ruby><rb>Base</rb><rt>Annotation</rt><rtc>Alt</rtc></ruby>
        <form accept-charset=iso-8859-1></form>
        <ol start=abc><li>Item</li></ol>
        <select><optgroup><option>Alpha</option></optgroup></select>
        <output aria-pressed=true>Result</output>
        <video loading=auto></video>
        <link rel=stylesheet href=x type="text/html ">
        <template shadowrootmode=open shadowrootslotassignment=invalid></template>
        """)
    #expect(result.messages.contains { $0.message == "Empty heading." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The heading \u{201c}h3\u{201d} (with computed level 3) follows the heading \u{201c}h1\u{201d} (with computed level 1), skipping 1 heading level." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}ruby\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}rp\u{201d}, \u{201c}rt\u{201d}, \u{201c}rtc\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}ruby\u{201d} is missing a required instance of child element \u{201c}rt\u{201d}." })
    #expect(result.messages.contains { $0.message == "Not all browsers position items appropriately when \"tabular markup\" is used with the \u{201c}rb\u{201d} element. See https://www.w3.org/International/articles/ruby/markup.en.html#visual for more guidance." && $0.type == "info" })
    #expect(result.messages.contains { $0.message == "Not all browsers position items appropriately when the \u{201c}rtc\u{201d} element is used. See https://www.w3.org/International/articles/ruby/markup.en.html#visual for more guidance." && $0.type == "info" })
    #expect(result.messages.contains { $0.message == "The only allowed value for the \u{201c}accept-charset\u{201d} attribute for the \u{201c}form\u{201d} element is \u{201c}utf-8\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}abc\u{201d} for attribute \u{201c}start\u{201d} on element \u{201c}ol\u{201d}." })
    #expect(result.messages.contains { $0.message == "An \u{201c}optgroup\u{201d} element with no child \u{201c}legend\u{201d} element must have a \u{201c}label\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}output\u{201d} is missing required attribute \u{201c}role\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}auto\u{201d} for attribute \u{201c}loading\u{201d} on element \u{201c}video\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}text/html \u{201d} for attribute \u{201c}type\u{201d} on element \u{201c}link\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}invalid\u{201d} for attribute \u{201c}shadowrootslotassignment\u{201d} on element \u{201c}template\u{201d}." })

    let noTopLevel = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><h3>Only subheading</h3>")
    #expect(noTopLevel.messages.contains { $0.message == "This document has heading elements but none of them has a computed heading level of 1." && $0.subType == "warning" })
}

@Test func metaCheckerCoversDocumentAndContentRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=iso-8859-1 content="text/html">
        <meta http-equiv="content-type" content="text/html; charset=utf-8">
        <title>T</title>
        <meta name=description itemprop=description content="one">
        <meta name=description media="screen" content="two">
        <meta http-equiv=refresh content="5;url=http://example.com">
        <meta http-equiv=X-UA-Compatible content="IE=10">
        <meta http-equiv=content-language content=en>
        <meta name=viewport content="width=device-width, user-scalable=no">
        <meta http-equiv=Content-Security-Policy content="default-src 'self'; invalid-directive 'none'">
        <meta http-equiv=Content-Security-Policy content="default-src 'invalid-keyword'">
        <meta http-equiv=Content-Security-Policy content="img-src https://\u{4f8b}\u{3048}.com">
        """)
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}content\u{201d} not allowed on element \u{201c}meta\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Internal encoding declaration \u{201c}iso-8859-1\u{201d} disagrees with the actual encoding of the document (\u{201c}utf-8\u{201d})." })
    #expect(result.messages.contains { $0.message == "A document must not include both a \u{201c}meta\u{201d} element with an \u{201c}http-equiv\u{201d} attribute whose value is \u{201c}content-type\u{201d}, and a \u{201c}meta\u{201d} element with a \u{201c}charset\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}itemprop\u{201d} not allowed on element \u{201c}meta\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "A document must not include more than one \u{201c}meta\u{201d} element with its \u{201c}name\u{201d} attribute set to the value \u{201c}description\u{201d}." })
    #expect(result.messages.contains { $0.message == "A \u{201c}meta\u{201d} element with a \u{201c}media\u{201d} attribute must have a \u{201c}name\u{201d} attribute whose value is \u{201c}theme-color\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}5;url=http://example.com\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}." })
    #expect(result.messages.contains { $0.message == "A \u{201c}meta\u{201d} element with an \u{201c}http-equiv\u{201d} attribute whose value is \u{201c}X-UA-Compatible\u{201d} must have a \u{201c}content\u{201d} attribute with the value \u{201c}IE=edge\u{201d}." })
    #expect(result.messages.contains { $0.message == "Using the \u{201c}meta\u{201d} element to specify the document-wide default language is obsolete. Consider specifying the language on the root element instead." })
    #expect(result.messages.contains { $0.message == "Consider avoiding viewport values that prevent users from resizing documents." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}default-src 'self'; invalid-directive 'none'\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}default-src 'invalid-keyword'\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}img-src https://\u{4f8b}\u{3048}.com\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}." })
}

@Test func metaCheckerCoversContentTypeCharsets() {
    let result = checkHTML("""
        <!doctype html><html lang=en><title>T</title>
        <meta http-equiv="content-type" content="text/html; charset=">
        <meta http-equiv="content-type" content="text/html; charset=not-a-charset">
        """)
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}text/html; charset=\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}." })
    #expect(result.messages.contains { $0.message == "Internal encoding declaration named an unsupported chararacter encoding \u{201c}not-a-charset\u{201d}." })
}

@Test func generalAttributeCheckerCoversNumericMediaTitleAndTrackRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title></title>
        <meter value=2 min=5 max=3 low=6 high=4 optimum=7 aria-valuemax=10>Meter</meter>
        <progress value=2 max=1 aria-valuemax=1>Progress</progress>
        <embed width=20% height=20% type=foo>
        <textarea cols=0 rows=0 autocomplete="country work"></textarea>
        <video><track default label="" src=en.vtt><track default src=es.vtt></video>
        """)
    #expect(result.messages.contains { $0.message == "Element \u{201c}title\u{201d} must not be empty." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}value\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}low\u{201d} attribute must be less than or equal to the value of the \u{201c}high\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}optimum\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-valuemax\u{201d} attribute should not be used on a \u{201c}meter\u{201d} element." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The value of the  \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-valuemax\u{201d} attribute should not be used on a \u{201c}progress\u{201d} element." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}20%\u{201d} for attribute \u{201c}width\u{201d} on element \u{201c}embed\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}20%\u{201d} for attribute \u{201c}height\u{201d} on element \u{201c}embed\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}foo\u{201d} for attribute \u{201c}type\u{201d} on element \u{201c}embed\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}country work\u{201d} for attribute \u{201c}autocomplete\u{201d} on element \u{201c}textarea\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}0\u{201d} for attribute \u{201c}cols\u{201d} on element \u{201c}textarea\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}0\u{201d} for attribute \u{201c}rows\u{201d} on element \u{201c}textarea\u{201d}." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}label\u{201d} for element \u{201c}track\u{201d} must have non-empty value." })
    #expect(result.messages.contains { $0.message == "The \u{201c}default\u{201d} attribute must not occur on more than one \u{201c}track\u{201d} element within the same \u{201c}audio\u{201d} or \u{201c}video\u{201d} element." })

    let missingTitle = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><p>No title")
    #expect(missingTitle.messages.contains { $0.message == "Element \u{201c}head\u{201d} is missing a required instance of child element \u{201c}title\u{201d}." })
}

@Test func generalAttributeCheckerCoversInputTypeRules() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><input autocomplete=\"country shipping\"><input type=hidden autocomplete=on aria-label=x required><input type=button value=\"\"><input type=color value=red pattern=x><input type=number value=abc multiple><input type=checkbox role=button><input type=text list=missing form=notform><div id=notform></div><button commandfor=missing command=show-popover>Open</button>")
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}country shipping\u{201d} for attribute \u{201c}autocomplete\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "An \u{201c}input\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}hidden\u{201d} must not have an \u{201c}autocomplete\u{201d} attribute whose value is \u{201c}on\u{201d} or \u{201c}off\u{201d}." })
    #expect(result.messages.contains { $0.message == "An \u{201c}input\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}hidden\u{201d} must not have any \u{201c}aria-*\u{201d} attributes." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}required\u{201d} not allowed on element \u{201c}input\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}input\u{201d} with attribute \u{201c}type\u{201d} whose value is \u{201c}button\u{201d} must have non-empty attribute \u{201c}value\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}red\u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}pattern\u{201d} is only allowed when the input type is \u{201c}email\u{201d}, \u{201c}password\u{201d}, \u{201c}search\u{201d}, \u{201c}tel\u{201d}, \u{201c}text\u{201d}, or \u{201c}url\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}abc\u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}input\u{201d}." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}multiple\u{201d} not allowed on element \u{201c}input\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "An \u{201c}input\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}checkbox\u{201d} and with a \u{201c}role\u{201d} attribute whose value is \u{201c}button\u{201d} must have an \u{201c}aria-pressed\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The \u{201c}list\u{201d} attribute of the \u{201c}input\u{201d} element must refer to a \u{201c}datalist\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The \u{201c}form\u{201d} attribute must refer to a form element." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}commandfor\u{201d} attribute of the \u{201c}button\u{201d} element must be the ID of an element in the same tree as the \u{201c}button\u{201d} with the \u{201c}commandfor\u{201d} attribute." })
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

@Test func generalAttributeCheckerCoversScriptAttributeConstraints() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><script async></script><script type=module defer></script><script type=importmap src=map.json></script><script type=application/json nomodule></script><script src=x charset=iso-8859-1></script><script language=javascript type=text/plain></script>")
    #expect(result.messages.contains { $0.message == "An inline classic \u{201c}script\u{201d} element (i.e., a \u{201c}script\u{201d} element without a \u{201c}src\u{201d} attribute and with a \u{201c}type\u{201d} attribute that is either unspecified, empty, or a JavaScript MIME type) must not have an \u{201c}async\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "A \u{201c}script\u{201d} element with \u{201c}type=module\u{201d} must not have a \u{201c}defer\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must not have a \u{201c}src\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "A \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is neither a JavaScript MIME type, \u{201c}module\u{201d}, \u{201c}importmap\u{201d}, nor \u{201c}speculationrules\u{201d} (i.e., a data block) must not have a \u{201c}nomodule\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The only allowed value for the \u{201c}charset\u{201d} attribute for the \u{201c}script\u{201d} element is \u{201c}utf-8\u{201d}. (But the attribute is not needed and should be omitted altogether.)" })
    #expect(result.messages.contains { $0.message == "The \u{201c}language\u{201d} attribute on the \u{201c}script\u{201d} element is obsolete. Use the \u{201c}type\u{201d} attribute instead." })
    #expect(result.messages.contains { $0.message == "A \u{201c}script\u{201d} element with the \u{201c}language=\"JavaScript\"\u{201d} attribute set must not have a \u{201c}type\u{201d} attribute whose value is not \u{201c}text/javascript\u{201d}." })
}

@Test func generalAttributeCheckerCoversScriptJSONBlocks() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <script type=importmap>{"imports":{"":"/app.js"}}</script>
        <script type=speculationrules>{"prefetch":[{"source":"list","urls":[]}]}</script>
        <script type=speculationrules>{"prefetch":[{"source":"document","where":{"href_matches":""}}]}</script>
        """)
    #expect(result.messages.contains { $0.message == "A specifier map defined in a \u{201c}imports\u{201d} property within the content of a \u{201c}script\u{201d} element with a \u{201c}type\u{201d} attribute whose value is \u{201c}importmap\u{201d} must only contain non-empty keys." })
    #expect(result.messages.contains { $0.message == "The \u{201c}urls\u{201d} property in a speculation rule must contain at least one URL." })
    #expect(result.messages.contains { $0.message == "The \u{201c}href_matches\u{201d} property in a document rule must be a non-empty string." })
}

@Test func generalAttributeCheckerCoversStyleElementRules() {
    let headResult = checkHTML("""
        <!doctype html><html lang=en><head><meta charset=utf-8><title>T</title>
        <style>body { colr: red; }</style>
        <style scoped></style>
        <style type="text/plain"></style>
        <style type="text/css"></style>
        </head><body></body>
        """)
    #expect(headResult.messages.contains { $0.message == "CSS: \u{201c}colr\u{201d}: Property \u{201c}colr\u{201d} doesn't exist." })
    #expect(headResult.messages.contains { $0.message == "Attribute \u{201c}scoped\u{201d} not allowed on element \u{201c}style\u{201d} at this point." })
    #expect(headResult.messages.contains { $0.message == "The only allowed value for the \u{201c}type\u{201d} attribute for the \u{201c}style\u{201d} element is \u{201c}text/css\u{201d} (with no parameters). (But the attribute is not needed and should be omitted altogether.)" })
    #expect(headResult.messages.contains { $0.message == "The \u{201c}type\u{201d} attribute for the \u{201c}style\u{201d} element is not needed and should be omitted." && $0.subType == "warning" })

    let bodyResult = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><body><div><style scoped></style></div><p><style scoped></style></p></body>")
    #expect(bodyResult.messages.contains { $0.message == "Element \u{201c}style\u{201d} not allowed as child of \u{201c}div\u{201d} in this context." })
    #expect(bodyResult.messages.contains { $0.message == "Element \u{201c}style\u{201d} not allowed as child of \u{201c}p\u{201d} in this context." })
}

@Test func generalAttributeCheckerCoversARIAImageLabelAndSelectRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <label role=article><input></label>
        <label for=x aria-label=Name>Caption</label><input id=x>
        <img src=x alt="" role=button>
        <img src=x role=none aria-label=Description>
        <select role=combobox><option>One</option></select>
        <select><button aria-label=Pick>Pick</button><option>One</option></select>
        """)
    #expect(result.messages.contains { $0.message == "The \u{201c}role\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is an ancestor of a labelable element." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-label\u{201d} attribute must not be used on any \u{201c}label\u{201d} element that is associated with a labelable element." })
    #expect(result.messages.contains { $0.message == "An \u{201c}img\u{201d} element with a \u{201c}role\u{201d} attribute must not have an \u{201c}alt\u{201d} attribute whose value is the empty string." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}none\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}select\u{201d} is missing required attribute \u{201c}aria-expanded\u{201d}." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-label\u{201d} attribute must not be used on a \u{201c}button\u{201d} element that is a child of a \u{201c}select\u{201d} element." })
}

// Review item A3: which elements may carry aria-label, aria-labelledby or
// aria-braillelabel follows upstream's isProhibitedFromBeingNamed. Each case
// is its own document, and every expectation here was confirmed against
// vnu.jar.
@Test(arguments: [
    // Links and areas with an href may be named (the false errors A3 fixed).
    ("<a href=/ aria-label=Home>H</a>", "a", false),
    ("<a href=test.html aria-labelledby=ID1>ABC</a><div id=ID1>Nifty</div>", "a", false),
    ("<a href=x aria-braillelabel=Home>H</a>", "a", false),
    ("<map name=m><area href=/ alt=Home aria-label=Home></map><img src=x alt=y usemap=#m>", "area", false),
    // An href lifts the prohibition whatever the role.
    ("<a href=/ role=presentation aria-label=Home>H</a>", "a", false),
    // Without an href, they still may not be named.
    ("<a aria-label=Home>H</a>", "a", true),
    ("<map name=m><area alt=Home aria-label=Home></map><img src=x alt=y usemap=#m>", "area", true),
    // body and rt were missing from the port's list.
    ("<body aria-label=Page><p>x</p></body>", "body", true),
    ("<ruby>a<rt aria-label=Reading>b</rt></ruby>", "rt", true),
    // Any role token that can't be named keeps the prohibition; a role with
    // none of those tokens, even an empty one, lifts it.
    ("<span role=\"none presentation\" aria-label=x>s</span>", "span", true),
    ("<span role=\"button\" aria-label=x tabindex=0>s</span>", "span", false),
    ("<span role=\"\" aria-label=x>s</span>", "span", false),
    ("<span aria-label=x>s</span>", "span", true),
])
func ariaNamingProhibitionMatchesUpstream(markup: String, element: String, prohibited: Bool) {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\(markup)")
    let namingErrors = result.messages.filter {
        $0.type == "error" && $0.message.contains("attribute must not be specified on any \u{201c}\(element)\u{201d} element unless")
    }
    #expect(namingErrors.isEmpty != prohibited, "\(markup): \(namingErrors.map(\.message))")
}

// Review item A4: a, ins, del (and map, object, slot, ...) have transparent
// content models, so block content in them is valid wherever their parent
// allows it; an error names the immediate parent and, when that parent is
// transparent, carries upstream's Note. Each case is its own document, and
// every expected message was confirmed against vnu.jar.
private func transparentNote(_ parent: String) -> String {
    " Note: The \u{201c}\(parent)\u{201d} element has a transparent content model; its allowed content is inherited from its parent element."
}

@Test(arguments: [
    // Valid: the transparent element's own parent allows flow content.
    ("<a href=/p><div><h2>T</h2><p>x</p></div></a>", nil),
    ("<ins><p>x</p></ins>", nil),
    ("<del><div>x</div></del>", nil),
    ("<a href=/><table><tr><td>x</td></tr></table></a>", nil),
    ("<a href=/><ins><div>x</div></ins></a>", nil),
    ("<div><a href=/><section><h2>S</h2></section></a></div>", nil),
    ("<ul><li><a href=/><div>x</div></a></li></ul>", nil),
    ("<div><slot><div>x</div></slot></div>", nil),
    // Invalid: the content is inherited from a phrasing-only ancestor.
    ("<span><div>x</div></span>", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}span\u{201d} in this context."),
    ("<span><a href=/><div>x</div></a></span>", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}a\u{201d} in this context." + transparentNote("a")),
    ("<button><ins><div>x</div></ins></button>", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}ins\u{201d} in this context." + transparentNote("ins")),
    ("<span><a href=/><ins><div>x</div></ins></a></span>", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}ins\u{201d} in this context." + transparentNote("ins")),
    ("<span><slot><div>x</div></slot></span>", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}slot\u{201d} in this context." + transparentNote("slot")),
    // The Note goes on any "not allowed as child" error with a transparent parent.
    ("<a href=/><li>x</li></a>", "Element \u{201c}li\u{201d} not allowed as child of \u{201c}a\u{201d} in this context." + transparentNote("a")),
] as [(String, String?)])
func transparentContentModelsMatchUpstream(markup: String, expected: String?) {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\(markup)")
    let childErrors = result.messages.filter { $0.type == "error" && $0.message.contains("not allowed as child of") }.map(\.message)
    #expect(childErrors == (expected.map { [$0] } ?? []), "\(markup)")
}

// Review item A13: role attributes go through upstream's role filter (one
// combined Discarding error, superfluous tokens as info, case-sensitive) and
// then the schema ("Bad value" when no token is recognized and the value
// isn't one the schema knows). Each case is its own document; the expected
// role messages (kind and text) were confirmed against vnu.jar.
private func discardingUnrecognized(_ tokens: String) -> String {
    "Discarding unrecognized \(tokens) from value of attribute \u{201c}role\u{201d}. Browsers ignore any token that is not a defined ARIA non-abstract role."
}

private func badRoleValue(_ value: String, _ element: String) -> String {
    "Bad value \u{201c}\(value)\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}\(element)\u{201d}."
}

@Test(arguments: [
    // Roles the port's set lacked (tooltip, heading, the doc-* footnote roles).
    ("<div role=\"tooltip\" id=t>Help</div>", []),
    ("<div role=\"heading\" aria-level=2>H</div>", []),
    ("<p>x<sup><a href=#fn1 id=r1 role=\"doc-noteref\">1</a></sup></p>", []),
    ("<section role=\"doc-endnotes\"><ol><li id=fn1><p>n <a href=#r1 role=\"doc-backlink\">back</a></p></li></ol></section>", []),
    // No recognized token: the schema's "Bad value" for the whole value.
    ("<div role=\"foo\">x</div>", [("error", badRoleValue("foo", "div"))]),
    ("<div role=\"foo bar\">x</div>", [("error", badRoleValue("foo bar", "div"))]),
    ("<div role=\"Button\" tabindex=0>x</div>", [("error", badRoleValue("Button", "div"))]),
    ("<div role=\"\">x</div>", [("error", badRoleValue("", "div"))]),
    ("<span role=\"generic\">x</span>", [("error", badRoleValue("generic", "span"))]),
    // ... unless the schema knows the value on its own.
    ("<div role=\"paragraph\">x</div>", []),
    // A recognized token: one Discarding message for all unrecognized ones.
    ("<div role=\"foo bar button\" tabindex=0>x</div>", [("error", discardingUnrecognized("tokens \u{201c}foo\u{201d}, \u{201c}bar\u{201d}"))]),
    ("<div role=\"strong button\" tabindex=0>x</div>", [("error", discardingUnrecognized("token \u{201c}strong\u{201d}"))]),
    ("<img src=x alt=y role=\"foo img\">", [("error", discardingUnrecognized("token \u{201c}foo\u{201d}"))]),
    // Superfluous roles are info, and "presentation" never counts.
    ("<div role=\"button link\" tabindex=0>x</div>", [("info", "Discarding superfluous token \u{201c}link\u{201d} from value of attribute \u{201c}role\u{201d}. Browsers only process the first token found that is a defined ARIA non-abstract role.")]),
    ("<div role=\"button presentation\" tabindex=0>x</div>", []),
    ("<ul role=\"directory\"><li>x</li></ul>", [("warning", badRoleValue("directory", "ul"))]),
    // Nothing for custom elements.
    ("<my-el role=\"foo button\">x</my-el>", []),
    // select: upstream's assertions, plus the schema's role list.
    ("<select multiple role=\"menu\"><option>a</option></select>", [("error", "A \u{201c}select\u{201d} element with a \u{201c}multiple\u{201d} attribute or with a \u{201c}size\u{201d} attribute whose value is greater than 1 must not have any \u{201c}role\u{201d} attribute.")]),
    ("<select role=\"button\"><option>a</option></select>", [
        ("error", badRoleValue("button", "select")),
        ("error", "The \u{201c}button\u{201d} role is not allowed for element \u{201c}select\u{201d} without a \u{201c}multiple\u{201d} attribute and without a \u{201c}size\u{201d} attribute whose value is greater than 1."),
    ]),
    // ... matched exactly: no "unnecessary" warning for these.
    ("<select multiple role=\"listbox foo\"><option>a</option></select>", [
        ("error", discardingUnrecognized("token \u{201c}foo\u{201d}")),
        ("error", "A \u{201c}select\u{201d} element with a \u{201c}multiple\u{201d} attribute or with a \u{201c}size\u{201d} attribute whose value is greater than 1 must not have any \u{201c}role\u{201d} attribute."),
    ]),
    ("<select role=\"COMBOBOX\"><option>a</option></select>", [
        ("error", badRoleValue("COMBOBOX", "select")),
        ("error", "The \u{201c}COMBOBOX\u{201d} role is not allowed for element \u{201c}select\u{201d} without a \u{201c}multiple\u{201d} attribute and without a \u{201c}size\u{201d} attribute whose value is greater than 1."),
    ]),
    // One "Bad value" per attribute, even where an element has its own list.
    ("<img src=x alt=y role=\"foo\">", [("error", badRoleValue("foo", "img"))]),
    ("<p>a<br role=\"Separator\">b</p>", [("error", badRoleValue("Separator", "br"))]),
    // Java's trim, and a split on space, tab, CR and LF only.
    ("<div role=\" foo \">x</div>", [("error", badRoleValue("foo", "div"))]),
    ("<div role=\"button\u{3000}link\" tabindex=0>x</div>", [("error", badRoleValue("button\u{3000}link", "div"))]),
    // A valueless role is an empty one.
    ("<div role>x</div>", [("error", badRoleValue("", "div"))]),
    // Where the schema doesn't judge the value: template contents, obsolete
    // elements, and where role isn't allowed at all.
    ("<template><div role=\"foo\">x</div></template>", []),
    ("<center role=\"Main\">x</center>", []),
    ("<picture role=\"generic\"><img src=x alt=y></picture>", [("error", "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}picture\u{201d} at this point.")]),
    // SVG elements are filtered, even with a hyphen in the name. (A2: inside
    // a <font>, where the schema allows a <missing-glyph>, and so reports its
    // role attribute too; directly in an <svg>, vnu.jar reports the element
    // as not allowed instead, and nothing about its attributes.)
    ("<svg width=1 height=1><font horiz-adv-x=\"1\"><font-face/><missing-glyph role=\"foo button\"></missing-glyph></font></svg>", [("error", discardingUnrecognized("token \u{201c}foo\u{201d}")), ("error", "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}missing-glyph\u{201d} at this point.")]),
    // MathML isn't filtered: math may have exactly role="math" (which isn't
    // needed), and the elements inside it no role at all.
    ("<math role=\"foo button\"><mi>x</mi></math>", [("error", badRoleValue("foo button", "math"))]),
    ("<math role=\"math\"><mi>x</mi></math>", [("warning", "Element \u{201c}math\u{201d} does not need a \u{201c}role\u{201d} attribute.")]),
    ("<math><mi role=\"foo\">x</mi></math>", [("error", "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}mi\u{201d} at this point.")]),
] as [(String, [(String, String)])])
func roleAttributeMessagesMatchUpstream(markup: String, expected: [(String, String)]) {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\(markup)")
    let roleMessages = result.messages
        .filter { $0.message.contains("role") }
        .map { message -> String in
            let kind = message.type == "info" ? (message.subType == "warning" ? "warning" : "info") : message.type
            return "\(kind): \(message.message)"
        }
        .sorted()
    #expect(roleMessages == expected.map { "\($0.0): \($0.1)" }.sorted(), "\(markup)")
}

// A13: role's "Bad value" is a schema message, which upstream reports before
// its other checks' messages for the same element (TestRunner compares an
// invalid file's first error). Confirmed against vnu.jar.
@Test func roleSchemaMessageComesFirst() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><label for=nope role=\"foaf:Person\">L</label>")
    #expect(result.messages.first?.message == badRoleValue("foaf:Person", "label"))
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}for\u{201d} attribute of the \u{201c}label\u{201d} element must be the ID of a non-hidden form control." })
}

// A13: select's aria-expanded requirement is the schema's, so it applies to
// role="combobox" exactly. Confirmed against vnu.jar.
@Test func selectComboboxAriaExpandedIsCaseSensitive() {
    let missing = "Element \u{201c}select\u{201d} is missing required attribute \u{201c}aria-expanded\u{201d}."
    let exact = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><select size=1 role=\"combobox\"><option>a</option></select>")
    let upper = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><select role=\"COMBOBOX\"><option>a</option></select>")
    #expect(exact.messages.contains { $0.message == missing })
    #expect(!upper.messages.contains { $0.message == missing })
}

// Review item A15: input value datatypes follow upstream's schema
// (web-forms2.rnc): url and color (like number and the date and time types)
// allow an empty value; range's min, max and value don't. Each case is its own
// document; every expectation was confirmed against vnu.jar.
@Test(arguments: [
    // WordPress's comment form, which the port used to reject.
    ("<form><p><input id=url name=url type=url value=\"\" size=30 aria-label=f></p></form>", nil),
    ("<input type=URL value=\"\" aria-label=f>", nil),
    ("<input type=color value=\"\" aria-label=f>", nil),
    ("<input type=number value=\"\" aria-label=f>", nil),
    ("<input type=range min=0 max=10 value=5 aria-label=f>", nil),
    // Still errors.
    ("<input type=url value=\" \" aria-label=f>", "Bad value \u{201c} \u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}input\u{201d}."),
    ("<input type=color value=\"red\" aria-label=f>", "Bad value \u{201c}red\u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}input\u{201d}."),
    // range errors the port used to miss.
    ("<input type=range value=\"\" aria-label=f>", "Bad value \u{201c}\u{201d} for attribute \u{201c}value\u{201d} on element \u{201c}input\u{201d}."),
    ("<input type=range max=\"abc\" aria-label=f>", "Bad value \u{201c}abc\u{201d} for attribute \u{201c}max\u{201d} on element \u{201c}input\u{201d}."),
    ("<input type=range min=\"\" aria-label=f>", "Bad value \u{201c}\u{201d} for attribute \u{201c}min\u{201d} on element \u{201c}input\u{201d}."),
] as [(String, String?)])
func inputValueDatatypesMatchUpstream(markup: String, expected: String?) {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\(markup)")
    let badValues = result.messages.filter { $0.type == "error" && $0.message.hasPrefix("Bad value") }.map(\.message)
    #expect(badValues == (expected.map { [$0] } ?? []), "\(markup)")
}

// Review item A2: SVG and MathML ("foreign content") follow upstream's tree
// builder and schemas: namespaces, self-closed foreign elements, breakouts,
// end tags in and around foreign content, namespace declarations, MathML's
// vocabulary and child counts, SVG's ordered children and path data, which
// SVG elements take a role, and CDATA sections. Each case is a whole document,
// and the expected errors and warnings are exactly the ones vnu.jar reports
// for it.
@Test(arguments: [
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><p>x</p></svg>\n", [("error", "HTML start tag \u{201c}p\u{201d} in a foreign namespace context."), ("error", "Stray end tag \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div xmlns:xlink=\"http://www.w3.org/1999/xlink\">x</div>\n", [("error", "Attribute \u{201c}xmlns:xlink\u{201d} not allowed here.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div xmlns=\"http://example.com/\">x</div>\n", [("error", "Bad value \u{201c}http://example.com/\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/1999/xhtml\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><div xmlns=\"http://www.w3.org/1999/xhtml\">x</div></foreignObject></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><g><rect width=\"1\" height=\"1\"></g></svg>\n", [("error", "End tag \u{201c}g\u{201d} did not match the name of the current open element (\u{201c}rect\u{201d}).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><p>a<div>b</div></foreignObject></svg>c</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi>x</mi><mo>=</mo><mn>2</mn></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<button aria-label=\"Menu\"><svg viewBox=\"0 0 24 24\"><g><path d=\"M3 6h18\"/><circle cx=\"12\" cy=\"12\" r=\"2\"/></g></svg></button>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><annotation>text</annotation></math></p>\n", [("error", "Element \u{201c}annotation\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtr><mtd><mn>1</mn></mtd></mtr></math></p>\n", [("error", "Element \u{201c}mtr\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation encoding=\"text/plain\">x</annotation></semantics></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtable><mtr><mtd><mn>1</mn></mtd></mtr></mtable></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfoo>x</mfoo></math></p>\n", [("error", "Element \u{201c}mfoo\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi><mglyph src=\"g.png\" alt=\"g\"/></mi></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><b>bold</b> text</mtext></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><a href=\"#x\"/><text x=\"1\" y=\"1\">t</text></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"0\" height=\"0\"><symbol id=\"i\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1\"/></symbol></svg><svg width=\"16\" height=\"16\"><use href=\"#i\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg xmlns=\"http://www.w3.org/1999/xhtml\" width=\"1\" height=\"1\"></svg>\n", [("error", "Bad value \u{201c}http://www.w3.org/1999/xhtml\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/2000/svg\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg xmlns:xlink=\"http://example.com/\" width=\"1\" height=\"1\"></svg>\n", [("error", "Bad value \u{201c}http://example.com/\u{201d} for the attribute \u{201c}xmlns:link\u{201d} (only \u{201c}http://www.w3.org/1999/xlink\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><use xlink:href=\"#a\"/></svg><svg id=\"a\" width=\"1\" height=\"1\"></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg xmlns:foo=\"http://example.com/\" width=\"1\" height=\"1\"></svg>\n", [("error", "Attribute \u{201c}xmlns:foo\u{201d} not allowed here.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"></svg><math xmlns=\"http://www.w3.org/1998/Math/MathML\"><mi>x</mi></math>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mi>a</mi><mi>b</mi></mfrac></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mi>a</mi></mfrac></math></p>\n", [("error", "Element \u{201c}mfrac\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mi>a</mi><mi>b</mi><mi>c</mi></mfrac></math></p>\n", [("error", "Element \u{201c}mi\u{201d} not allowed as child of \u{201c}mfrac\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac></mfrac></math></p>\n", [("error", "Element \u{201c}mfrac\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac/></math></p>\n", [("error", "Element \u{201c}mfrac\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><msubsup><mi>x</mi><mn>1</mn></msubsup></math></p>\n", [("error", "Element \u{201c}msubsup\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><msup><mi>x</mi><mn>2</mn></msup></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><mn>2</mn></mfrac></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac>text<mi>b</mi></mfrac></math></p>\n", [("error", "Element \u{201c}mfrac\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}."), ("error", "Text not allowed in \u{201c}mfrac\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mi/><mi/></mfrac></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mroot><mi>x</mi><mn>3</mn><mn>4</mn></mroot></math></p>\n", [("error", "Element \u{201c}mn\u{201d} not allowed as child of \u{201c}mroot\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><filter id=\"f\"><feComponentTransfer><feFuncR type=\"identity\"/><feFuncG type=\"identity\"/></feComponentTransfer></filter></defs></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><filter id=\"f\"><feComponentTransfer><feFuncG type=\"identity\"/><feFuncR type=\"identity\"/></feComponentTransfer></filter></defs></svg>\n", [("error", "Element \u{201c}feFuncR\u{201d} not allowed as child of \u{201c}feComponentTransfer\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><filter id=\"f\"><feComponentTransfer><feFuncR type=\"identity\"/><feFuncR type=\"identity\"/></feComponentTransfer></filter></defs></svg>\n", [("error", "Element \u{201c}feFuncR\u{201d} not allowed as child of \u{201c}feComponentTransfer\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><filter id=\"f\"><feComponentTransfer><desc>d</desc><feFuncA type=\"identity\"/></feComponentTransfer></filter></defs></svg>\n", [("error", "Element \u{201c}desc\u{201d} not allowed as child of \u{201c}feComponentTransfer\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><filter id=\"f\"><feComponentTransfer><feFuncB type=\"identity\"/><desc>d</desc></feComponentTransfer></filter></defs></svg>\n", [("error", "Element \u{201c}desc\u{201d} not allowed as child of \u{201c}feComponentTransfer\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><filter id=\"f\"><feComponentTransfer></feComponentTransfer></filter></defs></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"><font-face font-family=\"x\"/><missing-glyph d=\"M0 0\"/><glyph unicode=\"a\" d=\"M0 0\"/></font></defs></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"><font-face font-family=\"x\"/></font></defs></svg>\n", [("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}missing-glyph\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"><missing-glyph d=\"M0 0\"/></font></defs></svg>\n", [("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}font-face\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"></font></defs></svg>\n", [("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}font-face\u{201d}."), ("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}missing-glyph\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"><missing-glyph d=\"M0 0\"/><font-face font-family=\"x\"/></font></defs></svg>\n", [("error", "Element \u{201c}font-face\u{201d} not allowed as child of \u{201c}font\u{201d} in this context."), ("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}font-face\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"><desc>d</desc><font-face font-family=\"x\"/><missing-glyph d=\"M0 0\"/><hkern u1=\"a\" u2=\"b\" k=\"1\"/></font></defs></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><font horiz-adv-x=\"1\"><font-face font-family=\"x\"/><missing-glyph d=\"M0 0\"/><glyph unicode=\"a\"/><desc>d</desc></font></defs></svg>\n", [("error", "Element \u{201c}desc\u{201d} not allowed as child of \u{201c}font\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><linearGradient id=\"g\" role=\"foo\"></linearGradient></defs></svg>\n", [("error", "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}linearGradient\u{201d} at this point.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><linearGradient id=\"g\" role=\"foo img\"></linearGradient></defs></svg>\n", [("error", "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}linearGradient\u{201d} at this point."), ("error", "Discarding unrecognized token \u{201c}foo\u{201d} from value of attribute \u{201c}role\u{201d}. Browsers ignore any token that is not a defined ARIA non-abstract role.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><g role=\"foo\"></g></svg>\n", [("error", "Bad value \u{201c}foo\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}g\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><rect role=\"img\" aria-label=\"x\" width=\"1\" height=\"1\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><defs><clipPath id=\"c\" role=\"img\"></clipPath></defs></svg>\n", [("error", "Attribute \u{201c}role\u{201d} not allowed on element \u{201c}clipPath\u{201d} at this point.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><text role=\"heading\" aria-level=\"2\">t</text></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><use href=\"#a\" role=\"img\" aria-label=\"x\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M 10 50 A 5 5 0 0 1 20 50\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M10,10L20,20\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M10 10 20 20 30 30\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"m1 1h2v2z\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M1 1 A 5 5 0 1120 50\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M 20 100 H 40#90\"/></svg>\n", [("error", "Bad value \u{201c}M 20 100 H 40#90\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M1 1L\"/></svg>\n", [("error", "Bad value \u{201c}M1 1L\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M1 1,\"/></svg>\n", [("error", "Bad value \u{201c}M1 1,\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"M1 1 2\"/></svg>\n", [("error", "Bad value \u{201c}M1 1 2\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><path d=\"\"/></svg>\n", []),
    ("<!DOCTYPE html><html lang=\"en\"><head><title>t</title></head><body>\n<svg><text><![CDATA[a < b]]></text></svg><p><![CDATA[x]]></p><svg><foreignObject><![CDATA[y]]><div><![CDATA[z]]></div></foreignObject></svg>\n</body></html>\n", [("error", "Bogus comment."), ("error", "Bogus comment.")]),
    ("<!DOCTYPE html><html lang=\"en\"><head><title>t</title></head><body>\n<math><mi><![CDATA[x]]></mi><mtext><b><![CDATA[y]]></b></mtext></math>\n</body></html>\n", [("error", "Bogus comment.")]),
    ("<!DOCTYPE html><html lang=\"en\"><head><title>t</title></head><body>\n<svg><style><![CDATA[ .a > .b { fill: red } ]]></style><text>Some SVG text that is fairly long and in English for detection.</text></svg><svg><script>x</script><title>t</title></svg>\n</body></html>\n", []),
    // Review item A2, after its review: vnu.jar's errors and warnings for
    // documents that each exercise one of A2's behaviors, so that undoing any
    // of them fails a case (the cases above are mostly valid documents):
    // self-closed non-void HTML elements staying open (and <script/> and
    // <title/> reading text), the heading rule, </p> and </br> ending foreign
    // content, HTML <image> as <img>, SVG <a>, foreign elements in tables,
    // language detection ignoring SVG text, implied </body> and </html>,
    // content MathML, integration points and end-tag scope, unknown HTML, SVG
    // and MathML elements, xmlns values, path data with character
    // references, SVG <font> children, and the HTML-only state machines (an
    // SVG <option> or <main>). Then one document from each of the review's
    // probe sets, each of which an earlier version of the A2 changes got
    // wrong.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div/>x</div>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><span/>text</span></p>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div/><p>x</p></div>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title/>T</title>\n<p>x</p>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<script/>var a = \"<p>\";</script><p>x</p>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><g/><rect width=\"1\" height=\"1\"/></svg></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div><h1>A<span><h2>B</h2></span></h1></div>\n", [("error", "Element \u{201c}h2\u{201d} not allowed as child of \u{201c}span\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><g></br></g></svg></p>\n", [("error", "End tag \u{201c}br\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}br\u{201d}."), ("error", "HTML start tag \u{201c}br\u{201d} in a foreign namespace context."), ("error", "Stray end tag \u{201c}g\u{201d}."), ("error", "Stray end tag \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div><svg width=\"1\" height=\"1\"><g></p></g></svg></div>\n", [("error", "End tag \u{201c}p\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "HTML start tag \u{201c}p\u{201d} in a foreign namespace context."), ("error", "No \u{201c}p\u{201d} element in scope but a \u{201c}p\u{201d} end tag seen."), ("error", "Stray end tag \u{201c}g\u{201d}."), ("error", "Stray end tag \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi>x</mi><mrow></br></mrow></math></p>\n", [("error", "End tag \u{201c}br\u{201d} did not match the name of the current open element (\u{201c}mrow\u{201d})."), ("error", "End tag \u{201c}br\u{201d}."), ("error", "HTML start tag \u{201c}br\u{201d} in a foreign namespace context."), ("error", "Stray end tag \u{201c}math\u{201d}."), ("error", "Stray end tag \u{201c}mrow\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image src=\"x.png\" alt=\"A\"></p>\n", [("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image src=\"x.png\" alt=\"A\" srcset=\"y.png 2x\"></p>\n", [("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<picture><source srcset=\"a.webp\" type=\"image/webp\"><image src=\"a.png\" alt=\"A\"></picture>\n", [("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image src=\"x.png\"></p>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image src=\"x.png\" alt=\"A\"/>b</p>\n", [("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><image href=\"x.png\" width=\"1\" height=\"1\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><a href=\"#x\"><circle r=\"1\"/></a></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><a xlink:href=\"#x\"><circle r=\"1\"/></a></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><a href=\"#x\"><g><a href=\"#y\"><circle r=\"1\"/></a></g></a></svg>\n", [("error", "The SVG element \u{201c}a\u{201d} must not appear as a descendant of another SVG element \u{201c}a\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><a href=\"#x\"><svg width=\"1\" height=\"1\"><a href=\"#y\"><circle r=\"1\"/></a></svg></a></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><tr/></svg></td></tr></table>\n", [("error", "Element \u{201c}tr\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}tr\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><g><rect width=\"1\" height=\"1\"/></g></svg></td><td>b</td></tr></table>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"100\" height=\"100\"><text>Dies ist ein ziemlich langer deutscher Text, der nur dazu dient, die automatische Spracherkennung des Pr\u{fc}fprogramms auszul\u{f6}sen. Er beschreibt nichts Bestimmtes, sondern besteht aus ganz gew\u{f6}hnlichen S\u{e4}tzen, wie man sie in jeder Zeitung oder in jedem Buch finden k\u{f6}nnte. Die W\u{f6}rter sind absichtlich allt\u{e4}glich gew\u{e4}hlt, damit die Erkennung zuverl\u{e4}ssig funktioniert und kein Zweifel an der Sprache besteht. Wenn dieser Absatz im K\u{f6}rper des Dokuments steht, sollte das Programm bemerken, dass die angegebene Sprache nicht mit dem Inhalt \u{fc}bereinstimmt, und eine entsprechende Warnung ausgeben.</text></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>Dies ist ein ziemlich langer deutscher Text, der nur dazu dient, die automatische Spracherkennung des Pr\u{fc}fprogramms auszul\u{f6}sen. Er beschreibt nichts Bestimmtes, sondern besteht aus ganz gew\u{f6}hnlichen S\u{e4}tzen, wie man sie in jeder Zeitung oder in jedem Buch finden k\u{f6}nnte. Die W\u{f6}rter sind absichtlich allt\u{e4}glich gew\u{e4}hlt, damit die Erkennung zuverl\u{e4}ssig funktioniert und kein Zweifel an der Sprache besteht. Wenn dieser Absatz im K\u{f6}rper des Dokuments steht, sollte das Programm bemerken, dass die angegebene Sprache nicht mit dem Inhalt \u{fc}bereinstimmt, und eine entsprechende Warnung ausgeben.</p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"100\" height=\"100\"><foreignObject width=\"100\" height=\"100\"><p>Dies ist ein ziemlich langer deutscher Text, der nur dazu dient, die automatische Spracherkennung des Pr\u{fc}fprogramms auszul\u{f6}sen. Er beschreibt nichts Bestimmtes, sondern besteht aus ganz gew\u{f6}hnlichen S\u{e4}tzen, wie man sie in jeder Zeitung oder in jedem Buch finden k\u{f6}nnte. Die W\u{f6}rter sind absichtlich allt\u{e4}glich gew\u{e4}hlt, damit die Erkennung zuverl\u{e4}ssig funktioniert und kein Zweifel an der Sprache besteht. Wenn dieser Absatz im K\u{f6}rper des Dokuments steht, sollte das Programm bemerken, dass die angegebene Sprache nicht mit dem Inhalt \u{fc}bereinstimmt, und eine entsprechende Warnung ausgeben.</p></foreignObject></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></html>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></html></html>\n", [("error", "Stray end tag \u{201c}html\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><apply><plus/><ci>a</ci><ci>b</ci></apply></math></p>\n", [("error", "The \u{201c}apply\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}plus\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><annotation-xml encoding=\"MathML-Content\"><apply><plus/><ci>a</ci><ci>b</ci></apply></annotation-xml></semantics></math></p>\n", [("error", "The \u{201c}apply\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}plus\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><title><span>x</span></title></svg></td></tr></table>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><svg width=\"1\" height=\"1\"><g><span>y</span></g></svg></mtext><mi>z</mi></math></p>\n", [("error", "End tag \u{201c}g\u{201d} did not match the name of the current open element (\u{201c}mtext\u{201d})."), ("error", "End tag \u{201c}svg\u{201d} did not match the name of the current open element (\u{201c}mtext\u{201d})."), ("error", "HTML start tag \u{201c}span\u{201d} in a foreign namespace context."), ("error", "Stray end tag \u{201c}g\u{201d}."), ("error", "Stray end tag \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><div><foo>x</foo></div></desc></svg>\n", [("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foo><bar/></foo></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}bar\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><a href=\"#x\"><foo/></a></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}a\u{201d} in this context. Note: The \u{201c}a\u{201d} element has a transparent content model; its allowed content is inherited from its parent element."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<ul><li><foo>x</foo></li></ul>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}li\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div xmlns=\"http&#x3a;//www.w3.org/1999/xhtml\">x</div>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\" xmlns:xlink=\"http&colon;//www.w3.org/1999/xlink\"></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\" xmlns=\"http://example.com/&#x41;\"></svg>\n", [("error", "Bad value \u{201c}http://example.com/A\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/2000/svg\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><path d=\"M0 0 &amp; L1 1\"/></svg>\n", [("error", "Bad value \u{201c}M0 0 & L1 1\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><defs><font horiz-adv-x=\"1\"><glyph/></font></defs></svg>\n", [("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}font-face\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><defs><font horiz-adv-x=\"1\"></font></defs></svg>\n", [("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}font-face\u{201d}."), ("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}missing-glyph\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><g><option/></g></svg></p>\n", [("error", "Element \u{201c}option\u{201d} not allowed as child of \u{201c}g\u{201d} in this context."), ("error", "The \u{201c}option\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><picture/></svg>\n", [("error", "Element \u{201c}picture\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}picture\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<main>x</main><svg width=\"1\" height=\"1\"><main/></svg>\n", [("error", "Element \u{201c}main\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}main\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac>1<mn>2</mn></mfrac></math></p>\n", [("error", "Element \u{201c}mfrac\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}."), ("error", "Text not allowed in \u{201c}mfrac\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><foreignObject><div>a</span><![CDATA[x]]></div></foreignObject></svg>\n", [("error", "Bogus comment."), ("error", "Stray end tag \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><ci></ci></math></p>\n", [("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<image src=\"x.png\">b</p>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<svg><colgroup><col/></colgroup></svg>\n</body>\n</html>\n", [("error", "Element \u{201c}colgroup\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}colgroup\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content."), ("error", "The \u{201c}col\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><cn>1<sep/>2</cn></math></p>\n", [("error", "The \u{201c}cn\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}sep\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div xmlns=\"http://example.com/&#x41;\">x</div>\n", [("error", "Bad value \u{201c}http://example.com/A\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/1999/xhtml\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<math><mi><foo>x</foo></mi></math>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image src=\"x.png\"></p>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><defs><font horiz-adv-x=\"1\"><glyph/></font></defs></svg>\n", [("error", "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}font-face\u{201d}.")]),
    ("<!doctype html><meta charset=utf-8><title>image start tag</title>\n<image src=\"x\">\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}."), ("warning", "Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><mglyph src=\"g.png\" alt=\"g\"></mglyph></p>\n", [("error", "Element \u{201c}mglyph\u{201d} not allowed as child of \u{201c}p\u{201d} in this context."), ("error", "The \u{201c}mglyph\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mo><mo>x</mo></mo></math></p>\n", [("error", "Element \u{201c}mo\u{201d} not allowed as child of \u{201c}mo\u{201d} in this context."), ("error", "The \u{201c}mo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mstack><msrow><none/><mn>1</mn></msrow><msline/><mn>2</mn></mstack></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><path d=\"M0 0 &amp; L1 1\"/></svg>\n", [("error", "Bad value \u{201c}M0 0 & L1 1\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><path d=\"M.0e1 1\"/></svg>\n", [("error", "Bad value \u{201c}M.0e1 1\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><path d=\"M.0e1 1\"/></svg>\n", [("error", "Bad value \u{201c}M.0e1 1\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p><image alt=\"A\"></p>\n</body>\n</html>\n", [("error", "Element \u{201c}img\u{201d} is missing one or more of the following attributes: \u{201c}src\u{201d}, \u{201c}srcset\u{201d}."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n<basefont size=\"3\">\n</head>\n<body>\n<p>x</p>\n</body>\n</html>\n", [("error", "Element \u{201c}basefont\u{201d} not allowed as child of \u{201c}head\u{201d} in this context."), ("error", "The \u{201c}basefont\u{201d} element is obsolete. Use CSS instead.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p><image src=\"a.png\"></p>\n</body>\n</html>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n<script/>\n</head>\n<body>\n<p>x</p>\n<script>var a = 1;</script>\n</body>\n</html>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\" xmlns:fb=\"a\" xmlns:fb=\"b\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p>x</p>\n</body>\n</html>\n", [("error", "Attribute \u{201c}xmlns:fb\u{201d} not allowed here."), ("error", "Duplicate attribute \u{201c}xmlns:fb\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<p>x</p>\n</body>\n</html>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><svg><title><span></svg><label>x<input></label><a href=\"x y\">y</a></span></title></svg></svg>\n", [("error", "Bad value \u{201c}x y\u{201d} for attribute \u{201c}href\u{201d} on element \u{201c}a\u{201d}."), ("error", "Stray end tag \u{201c}svg\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p>a<keygen/>b</p>\n</body>\n</html>\n", [("error", "The \u{201c}keygen\u{201d} element is obsolete.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p><image alt=\"A\"></p>\n</body>\n</html>\n", [("error", "Element \u{201c}img\u{201d} is missing one or more of the following attributes: \u{201c}src\u{201d}, \u{201c}srcset\u{201d}."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p><image src=\"a.png\"/></p>\n</body>\n</html>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<image src=\"x.png\">b</p>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<math><iframe>a</iframe></math>\n", [("error", "Element \u{201c}iframe\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}iframe\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><foo></foo></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<div xmlns=\"http&#x3a;//example.com/\">x</div>\n</body>\n</html>\n", [("error", "Bad value \u{201c}http://example.com/\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/1999/xhtml\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image alt=\"x\"></p>\n", [("error", "Element \u{201c}img\u{201d} is missing one or more of the following attributes: \u{201c}src\u{201d}, \u{201c}srcset\u{201d}."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n</head>\n<body>\n<p><image src=\"a.png\"></p>\n</body>\n</html>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfoo><mbar/></mfoo></math></p>\n", [("error", "Element \u{201c}mfoo\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}mbar\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><option></option></math></p>\n", [("error", "Element \u{201c}option\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}option\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi><mi>x</mi></mi></math></p>\n", [("error", "Element \u{201c}mi\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context."), ("error", "The \u{201c}mi\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div><foo>x</foo></div>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}div\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfoo><mbar/></mfoo></math></p>\n", [("error", "Element \u{201c}mfoo\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}mbar\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><image alt=\"x\"></p>\n", [("error", "Element \u{201c}img\u{201d} is missing one or more of the following attributes: \u{201c}src\u{201d}, \u{201c}srcset\u{201d}."), ("error", "Saw a start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math id=\"m1\" class=\"ltx_Math\" alttext=\"a+b\" display=\"inline\"><semantics><mrow><mi>a</mi><mo>+</mo><mi>b</mi></mrow><annotation-xml encoding=\"MathML-Content\"><apply><plus></plus><ci>a</ci><ci>b</ci></apply></annotation-xml><annotation encoding=\"application/x-tex\">a+b</annotation><annotation encoding=\"application/x-llamapun\">a + b</annotation></semantics></math></p>\n", [("error", "The \u{201c}apply\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}plus\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mo><mo>x</mo></mo></math></p>\n", [("error", "Element \u{201c}mo\u{201d} not allowed as child of \u{201c}mo\u{201d} in this context."), ("error", "The \u{201c}mo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><a href=\"#a\"><foreignObject width=\"1\" height=\"1\"><a href=\"x\">y</a><input name=\"q\"></foreignObject></a></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<foo>x</foo>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}body\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg><foo/></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=utf-8>\n<title>no-void keygen</title>\n</head>\n<body>\n<keygen>foo</keygen>\n</body>\n</html>\n", [("error", "Stray end tag \u{201c}keygen\u{201d}."), ("error", "The \u{201c}keygen\u{201d} element is obsolete."), ("warning", "Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Probe</title>\n<script/>\n</head>\n<body>\n<p>x</p>\n<script>var a = 1;</script>\n</body>\n</html>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag.")]),
    // More of the same, for behaviors a mutation check showed no case above
    // covered: an unknown element's parent named as messages spell it
    // (foreignObject), <mglyph> as an HTML element when it's inside HTML in
    // a MathML text element, an end tag in foreign content stopping at an
    // HTML element, URL and required-attribute rules that are HTML's only,
    // and the MathML elements that only some parents take.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><foo>x</foo></foreignObject></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}foreignObject\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi><mglyph src=\"g.png\" alt=\"g\"></mglyph></mi></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><div><svg width=\"1\" height=\"1\"><g></foreignObject><rect width=\"1\" height=\"1\"/></g></svg></div></foreignObject></svg>\n", [("error", "End tag \u{201c}foreignobject\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Stray end tag \u{201c}foreignobject\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><a href=\"http://a b/\"><circle r=\"1\"/></a></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><a xlink:href=\"http://a b/\"><circle r=\"1\"/></a></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><image width=\"1\" height=\"1\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mglyph src=\"g.png\" alt=\"g\"/></math></p>\n", [("error", "Element \u{201c}mglyph\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mstack><mn>12</mn><msrow><mo>+</mo><mn>3</mn></msrow><msline/><mn>15</mn></mstack></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mn>1</mn><msline/></math></p>\n", [("error", "Element \u{201c}msline\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><piecewise><piece><cn>1</cn><ci>x</ci></piece><otherwise><cn>0</cn></otherwise></piecewise></math></p>\n", [("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}cn\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}cn\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}otherwise\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}piecewise\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}piece\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><piece><cn>1</cn><ci>x</ci></piece></math></p>\n", [("error", "Element \u{201c}piece\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}cn\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}piece\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><cn type=\"rational\">1<sep/>2</cn></math></p>\n", [("error", "The \u{201c}cn\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content."), ("error", "The \u{201c}sep\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mstack><mscarry><mn>1</mn></mscarry></mstack></math></p>\n", [("error", "Element \u{201c}mscarry\u{201d} not allowed as child of \u{201c}mstack\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mstack><mscarries><mscarry><mn>1</mn></mscarry></mscarries><mn>12</mn></mstack></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mrow><msgroup><mn>1</mn></msgroup></mrow></math></p>\n", [("error", "Element \u{201c}msgroup\u{201d} not allowed as child of \u{201c}mrow\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><ci><mglyph src=\"g.png\" alt=\"g\"/></ci></math></p>\n", [("error", "The \u{201c}ci\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><b><mglyph src=\"g.png\" alt=\"g\"></mglyph></b></mtext></math></p>\n", [("error", "Element \u{201c}mglyph\u{201d} not allowed as child of \u{201c}b\u{201d} in this context."), ("error", "The \u{201c}mglyph\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    // (The stray </foreignObject> stops at the <div>, so the <circle> after
    // the real </foreignObject> is SVG again.)
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><div><svg width=\"1\" height=\"1\"><g></foreignObject></g></svg></div></foreignObject><circle r=\"1\"/></svg>\n", [("error", "End tag \u{201c}foreignobject\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Stray end tag \u{201c}foreignobject\u{201d}.")]),
    // From a second review of the A2 changes, each a case an intermediate
    // version got wrong: a <p> closed by the next <p> (or a <div>) inside a
    // <foreignObject>, <desc> or <annotation-xml> must not leave that element
    // open, and a stray end tag inside an <svg> or <math> must not end it
    // (the tokenizer now asks the tree builder for each start tag's
    // namespace); </body> in a cell or template is stray; unknown SVG
    // elements in a <desc>, <annotation-xml> or <template>; role on an unknown
    // SVG element; <image> after </body>; <frame/> in the body; and content
    // after a </body> the body start tag was left out for.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><p>One<p>Two</p></foreignObject><rect width=\"1\" height=\"1\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foreignObject width=\"1\" height=\"1\"><p>a<div>b</div></foreignObject><text>label</text></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"10\" height=\"10\"><title>Chart</title><desc><p>Sales by region<p>Q1-Q4</p></desc><rect width=\"1\" height=\"1\"/></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\"><p>a<div>b</div></annotation-xml><annotation encoding=\"application/x-tex\">x</annotation></semantics></math>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><g></span><rect width=\"1\" height=\"1\"/></g></svg></p>\n", [("error", "End tag \u{201c}span\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Stray end tag \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mrow></span><mi>x</mi></mrow></math></p>\n", [("error", "End tag \u{201c}span\u{201d} did not match the name of the current open element (\u{201c}mrow\u{201d})."), ("error", "Stray end tag \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td>a</body><p>b</p></td></tr></table>\n", [("error", "Stray end tag \u{201c}body\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><p>a</body><p>b</p></template>\n", [("error", "Stray end tag \u{201c}body\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><svg width=\"1\" height=\"1\"><foo/></svg></desc></svg>\n", [("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"SVG1.1\"><svg width=\"1\" height=\"1\"><foo/></svg></annotation-xml></semantics></math></p>\n", [("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><svg width=\"1\" height=\"1\"><foo/></svg></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><math><apply><plus/><ci>a</ci></apply></math></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><foo>x</foo></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foo role=\"xyz\"/></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<body><p>x</p></body><image src=x alt=y>\n", [("error", "Saw a start tag \u{201c}image\u{201d}."), ("error", "Stray start tag \u{201c}image\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<frame/>b</p>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag."), ("error", "Stray start tag \u{201c}frame\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head>\n<p>x</p>\n</body>\n<script>var a = 1;</script>\n</html>\n", [("error", "Stray start tag \u{201c}script\u{201d}.")]),
] as [(String, [(String, String)])])
func foreignContentMatchesUpstream(document: String, expected: [(String, String)]) {
    let actual = checkHTML(document).messages
        .filter { $0.type != "info" || $0.subType == "warning" }
        .map { "\($0.type == "info" ? "warning" : "error"): \($0.message)" }
        .sorted()
    #expect(actual == expected.map { "\($0.0): \($0.1)" }.sorted(), "\(document)")
}

// Review item A2: </body> and </html> as upstream's tree builder handles them
// (they close nothing, then the "after body" modes report the next tag and go
// back to the body; in a table, cell or template they're stray), what upstream
// checks inside an SVG <desc>, a MathML <annotation-xml> and a <template>
// (the schema nothing, in the first two except for a MathML element directly
// in an annotation-xml; nothing at all in a template), and <frame> outside a
// frameset. The expected messages are vnu.jar's.
@Test(arguments: [
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><g></body><rect width=\"1\" height=\"1\"/></g></svg></p>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}body\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Saw an end tag after \u{201c}body\u{201d} had been closed."), ("error", "Unclosed element \u{201c}g\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=\"1\" height=\"1\"><g></html><rect width=\"1\" height=\"1\"/></g></svg></p>\n", [("error", "End tag for  \u{201c}html\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}html\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}html\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Stray end tag \u{201c}p\u{201d}."), ("error", "Unclosed element \u{201c}g\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div>x</body></html>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}div\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div>x</html>\n", [("error", "End tag for  \u{201c}html\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}div\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div>x</body></div></html>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Saw an end tag after \u{201c}body\u{201d} had been closed."), ("error", "Unclosed element \u{201c}div\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body><div>y</div><span>z</span></html>\n", [("error", "Stray start tag \u{201c}div\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></html></div>\n", [("error", "Stray end tag \u{201c}div\u{201d}."), ("error", "Stray end tag \u{201c}div\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<select><option>x</body>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}select\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<object data=\"x\"><p>x</body>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}object\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></body></html>\n", [("error", "Saw an end tag after \u{201c}body\u{201d} had been closed.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n</body>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><svg width=\"1\" height=\"1\"><path d=\"x\"/></svg></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><math><mfrac><mn>1</mn></mfrac></math></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><math><mfoo/></math></desc></svg>\n", [("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><svg width=\"1\" height=\"1\"><rect role=\"xyz\" width=\"1\" height=\"1\"/></svg></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><img src=\"x.png\"></desc></svg>\n", [("error", "An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute, except under certain conditions. For details, consult guidance on providing text alternatives for images.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><ul><p>x</p></ul></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><svg width=\"1\" height=\"1\"><font horiz-adv-x=\"1\"><glyph/></font></svg></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><input type=\"foo\"></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"SVG1.1\"><svg width=\"1\" height=\"1\"><path d=\"x\"/></svg></annotation-xml></semantics></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\"><ul><p>x</p></ul></annotation-xml></semantics></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><math><mtd><mfoo/></mtd></math></desc></svg>\n", [("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><svg width=\"1\" height=\"1\" xmlns=\"http://example.com/\"></svg></desc></svg>\n", [("error", "Bad value \u{201c}http://example.com/\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/2000/svg\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<frame>b</p>\n", [("error", "Stray start tag \u{201c}frame\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<frame/>b</p>\n", [("error", "Self-closing syntax (\u{201c}/>\u{201d}) used on a non-void HTML element. Ignoring the slash and treating as a start tag."), ("error", "Stray start tag \u{201c}frame\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><frameset><frame src=\"a.html\"/><frame src=\"b.html\"></frameset></html>\n", [("error", "The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."), ("error", "The \u{201c}frame\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."), ("error", "The \u{201c}frame\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><svg width=\"1\" height=\"1\"><path d=\"x\"/></svg></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><math><mfrac><mn>1</mn></mfrac></math></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><ul><p>x</p></ul></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><svg width=\"1\" height=\"1\" xmlns=\"http://example.com/\"></svg></template>\n", [("error", "Bad value \u{201c}http://example.com/\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/2000/svg\u{201d} permitted here).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><svg width=\"1\" height=\"1\"><rect role=\"xyz\" width=\"1\" height=\"1\"/></svg></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><input type=\"foo\"></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><math><mfoo/></math></template>\n", []),
    // More, for behaviors a mutation check showed no case above covered:
    // MathML attribute values in a <template> or <desc>; nothing more inside a
    // MathML element in the wrong parent; the end tag after </body> handled
    // as body content again; a MathML child of <annotation-xml> still checked;
    // a stray <frame>; <picture> left open at </body>. Then duplicate IDs as
    // upstream's tree builder checks them: an empty ID too, nothing in a
    // template (but the template's own ID), an <html> start tag after
    // </body>, and SVG elements; with the first occurrence's location.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><math display=\"foo\"><mi>x</mi></math></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><math display=\"foo\"><mi>x</mi></math></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtd><mfoo/></mtd></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtd><mfrac><mn>1</mn></mfrac></mtd></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></div><p>y</p>\n", [("error", "Saw an end tag after \u{201c}body\u{201d} had been closed."), ("error", "Stray end tag \u{201c}div\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml><mglyph src=\"g.png\" alt=\"g\"/></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}mglyph\u{201d} not allowed as child of \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<frame src=\"http://a b/\">b</p>\n", [("error", "Stray start tag \u{201c}frame\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>a<frame name=\"x\" id=\"f\">b</p><p id=\"f\">c</p>\n", [("error", "Duplicate ID \u{201c}f\u{201d}."), ("error", "Stray start tag \u{201c}frame\u{201d}."), ("warning", "The first occurrence of ID \u{201c}f\u{201d} was here.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<picture><img src=\"x.png\" alt=\"A\"></body></html>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}picture\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></div></span><p>y</p>\n", [("error", "Saw an end tag after \u{201c}body\u{201d} had been closed."), ("error", "Stray end tag \u{201c}div\u{201d}."), ("error", "Stray end tag \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mprescripts/><mi>x</mi></math></p>\n", [("error", "Element \u{201c}mprescripts\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mrow><none><mi>x</mi></none></mrow></math></p>\n", [("error", "Element \u{201c}none\u{201d} not allowed as child of \u{201c}mrow\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p id=\"\">a</p><p id=\"\">b</p>\n", [("error", "Bad value \u{201c}\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}p\u{201d}."), ("error", "Bad value \u{201c}\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}p\u{201d}."), ("error", "Duplicate ID \u{201c}\u{201d}."), ("warning", "The first occurrence of ID \u{201c}\u{201d} was here.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template id=\"t\"><p id=\"t\">a</p></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p id=\"a\">x</p></body><html id=\"a\">\n", [("error", "Duplicate ID \u{201c}a\u{201d}."), ("error", "Stray start tag \u{201c}html\u{201d}."), ("warning", "The first occurrence of ID \u{201c}a\u{201d} was here.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p id=\"a\">x</p><svg width=\"1\" height=\"1\"><g id=\"a\"/></svg>\n", [("error", "Duplicate ID \u{201c}a\u{201d}."), ("warning", "The first occurrence of ID \u{201c}a\u{201d} was here.")]),
    // (And deeper inside a rejected element: nothing more two levels down.)
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtd><mrow><mfoo/></mrow></mtd></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtd><mrow><mfrac><mn>1</mn></mfrac></mrow></mtd></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foo><g><bar/></g></foo></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}bar\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
] as [(String, [(String, String)])])
func endTagsAndUncheckedContentMatchUpstream(document: String, expected: [(String, String)]) {
    let actual = checkHTML(document).messages
        .filter { $0.type != "info" || $0.subType == "warning" }
        .map { "\($0.type == "info" ? "warning" : "error"): \($0.message)" }
        .sorted()
    #expect(actual == expected.map { "\($0.0): \($0.1)" }.sorted(), "\(document)")
}

// Review item A2 (the third review, and after): more of upstream's tree
// builder and schemas, as vnu.jar reports them. First text and tags after a
// frameset; the head's end (implied, repeated, after body content) and text
// in the head; </body> in a template, by the template's mode; stray table
// parts and framesets; and the "Unclosed element" list after each
// open-elements error, each element listed once.
@Test(arguments: [
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><frameset><frame src=\"a.html\"></frameset>abc</html>\n", [("error", "Non-space after \u{201c}frameset\u{201d}."), ("error", "Non-space after \u{201c}frameset\u{201d}."), ("error", "Non-space after \u{201c}frameset\u{201d}."), ("error", "The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."), ("error", "The \u{201c}frame\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><frameset><frame src=\"a.html\"></frameset></html>abc\n", [("error", "Non-space character in page trailer."), ("error", "Non-space character in page trailer."), ("error", "Non-space character in page trailer."), ("error", "The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."), ("error", "The \u{201c}frame\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><frameset><frame src=\"a.html\"></frameset><p>x</p></body></html>\n", [("error", "Non-space after \u{201c}frameset\u{201d}."), ("error", "Stray end tag \u{201c}body\u{201d}."), ("error", "Stray end tag \u{201c}p\u{201d}."), ("error", "Stray start tag \u{201c}p\u{201d}."), ("error", "The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."), ("error", "The \u{201c}frame\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title></head><body><p>x</p></body></html>\n", []),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><head></head><body><p>x</p></body></html>\n", [("error", "Start tag \u{201c}head\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><head><p>y</p>\n", [("error", "Stray start tag \u{201c}head\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><html lang=fr><p>y</p>\n", [("error", "Stray start tag \u{201c}html\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title>hello<body><p>x</p></body>\n", [("error", "Start tag \u{201c}body\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title>hello</head><p>x</p>\n", [("error", "Stray end tag \u{201c}head\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></head>\n", [("error", "Stray end tag \u{201c}head\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><template><div>x</body>\n", [("error", "End of file seen and there were open elements."), ("error", "Stray end tag \u{201c}body\u{201d}."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><td>cell\n</body>\n</html>\n", [("error", "Stray start tag \u{201c}td\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><frameset></body></html>\n", [("error", "Stray start tag \u{201c}frameset\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><div>y</body>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><col></body>\n", [("error", "End of file seen and there were open elements."), ("error", "Garbage in \u{201c}colgroup\u{201d} fragment."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><tr></body>\n", [("error", "End of file seen and there were open elements."), ("error", "Stray end tag \u{201c}body\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><div>y</div></body>\n<p>z</p>\n", [("error", "End of file seen and there were open elements."), ("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Stray start tag \u{201c}p\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div><span>x</div>\n", [("error", "End tag \u{201c}div\u{201d} seen, but there were open elements."), ("error", "Unclosed element \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><b>x<td>y</td></tr></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Unclosed element \u{201c}b\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div><span>x</div></body></html>\n", [("error", "End tag \u{201c}div\u{201d} seen, but there were open elements."), ("error", "Unclosed element \u{201c}span\u{201d}.")]),
    // The third review's tree-building findings: a mismatched end tag in
    // foreign content after </body>, an <svg> in <annotation-xml> after it,
    // a <frame> in a table, </body> in a template, and the flags of an
    // element whose parent's implied end tags close.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><g></body></span></g></svg>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}body\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}span\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}span\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Saw an end tag after \u{201c}body\u{201d} had been closed."), ("error", "Stray end tag \u{201c}span\u{201d}."), ("error", "Unclosed element \u{201c}g\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<math><mi></html></b></mi></math>\n", [("error", "End tag for  \u{201c}html\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}b\u{201d} did not match the name of the current open element (\u{201c}mi\u{201d})."), ("error", "End tag \u{201c}b\u{201d} did not match the name of the current open element (\u{201c}mi\u{201d})."), ("error", "End tag \u{201c}html\u{201d} did not match the name of the current open element (\u{201c}mi\u{201d})."), ("error", "End tag \u{201c}html\u{201d} did not match the name of the current open element (\u{201c}mi\u{201d})."), ("error", "Stray end tag \u{201c}b\u{201d}."), ("error", "Stray end tag \u{201c}b\u{201d}."), ("error", "Unclosed element \u{201c}math\u{201d}."), ("error", "Unclosed element \u{201c}mi\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<div><math><semantics><mi>x</mi><annotation-xml></body><svg width=\"1\" height=\"1\"></svg></annotation-xml></semantics></math></div>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}body\u{201d} did not match the name of the current open element (\u{201c}annotation-xml\u{201d})."), ("error", "Stray start tag \u{201c}svg\u{201d}."), ("error", "Unclosed element \u{201c}annotation-xml\u{201d}."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}math\u{201d}."), ("error", "Unclosed element \u{201c}semantics\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><frame></table>\n", [("error", "Start tag \u{201c}frame\u{201d} seen in \u{201c}table\u{201d}."), ("error", "Stray start tag \u{201c}frame\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<body><template><div></body>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><desc>Icon<td>Next <foo>x</foo></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}td\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."), ("error", "Unclosed element \u{201c}desc\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><desc><td><svg width=\"1\" height=\"1\"><foo/></svg></td></tr></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content."), ("error", "Unclosed element \u{201c}desc\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    // The third review's minimal repros: what upstream's schemas leave
    // unchecked (an SVG <desc>, a MathML <annotation-xml>, a <template>, a
    // rejected element), and its insertion modes.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml><mfoo><mtext><span><foo>x</foo></span></mtext></mfoo></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}mfoo\u{201d} not allowed as child of \u{201c}annotation-xml\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml><mtd><mtext><span><svg width=\"1\" height=\"1\"><path d=\"x\"/></svg></span></mtext></mtd></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml><mtext><div><foo>x</foo></div></mtext></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}mtext\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"MathML-Content\">text</annotation-xml></semantics></math></p>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foo><foreignObject width=\"1\" height=\"1\"><div><svg width=\"1\" height=\"1\"><path d=\"x\"/></svg></div></foreignObject></foo></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"MathML-Content\"><math><mi>y</mi></math></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}math\u{201d} not allowed as child of \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\"><math display=\"foo\"><mfrac><mi>y</mi></mfrac></math></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}math\u{201d} not allowed as child of \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\"><span><math><mi>y</mi></math></span></annotation-xml></semantics></math></p>\n", [("error", "Element \u{201c}math\u{201d} not allowed as child of \u{201c}span\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><desc><p>x</svg><td>a<td><foo>y</foo><tr><td><bar>z</bar></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Element \u{201c}bar\u{201d} not allowed as child of \u{201c}td\u{201d} in this context."), ("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}td\u{201d} in this context."), ("error", "Stray end tag \u{201c}svg\u{201d}."), ("error", "The \u{201c}bar\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."), ("error", "Unclosed element \u{201c}desc\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}."), ("warning", "A table row was 1 columns wide, which is less than the column count established by the first row (3).")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><desc><p>x</svg><td><svg width=\"1\" height=\"1\"><foo/></svg></td></tr></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "Stray end tag \u{201c}svg\u{201d}."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content."), ("error", "Unclosed element \u{201c}desc\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\"><span>x</math><td><math><mtd/></math></td></tr></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "Stray end tag \u{201c}math\u{201d}."), ("error", "Unclosed element \u{201c}annotation-xml\u{201d}."), ("error", "Unclosed element \u{201c}math\u{201d}."), ("error", "Unclosed element \u{201c}semantics\u{201d}."), ("error", "Unclosed element \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td><svg width=\"1\" height=\"1\"><desc><p>x</svg><td><foo>y</foo></td></tr></table>\n", [("error", "A table cell was implicitly closed, but there were open elements."), ("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}td\u{201d} in this context."), ("error", "Stray end tag \u{201c}svg\u{201d}."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."), ("error", "Unclosed element \u{201c}desc\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mi>a</mi><mi>b</mi><mfoo/></mfrac></math></p>\n", [("error", "Element \u{201c}mfoo\u{201d} not allowed as child of \u{201c}mfrac\u{201d} in this context."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfrac><mi>a</mi><mtd>b</mtd><mi>c</mi></mfrac></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}mfrac\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><msup><mi>a</mi><none/></msup></math></p>\n", [("error", "Element \u{201c}msup\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}abs\u{201d}, \u{201c}and\u{201d}, \u{201c}apply\u{201d}, \u{201c}approx\u{201d}, \u{201c}arccos\u{201d}, \u{201c}arccosh\u{201d}, \u{201c}arccot\u{201d}, \u{201c}arccoth\u{201d}, \u{201c}arccsc\u{201d}, \u{201c}arccsch\u{201d}, \u{201c}arcsec\u{201d}, \u{201c}arcsech\u{201d}, \u{201c}arcsin\u{201d}, \u{201c}arcsinh\u{201d}, \u{201c}arctan\u{201d}, \u{201c}arctanh\u{201d}, \u{201c}arg\u{201d}, \u{201c}bind\u{201d}, \u{201c}card\u{201d}, \u{201c}cartesianproduct\u{201d}, \u{201c}cbytes\u{201d}, \u{201c}ceiling\u{201d}, \u{201c}cerror\u{201d}, \u{201c}ci\u{201d}, \u{201c}cn\u{201d}, \u{201c}codomain\u{201d}, \u{201c}complexes\u{201d}, \u{201c}compose\u{201d}, \u{201c}conjugate\u{201d}, \u{201c}cos\u{201d}, \u{201c}cosh\u{201d}, \u{201c}cot\u{201d}, \u{201c}coth\u{201d}, \u{201c}cs\u{201d}, \u{201c}csc\u{201d}, \u{201c}csch\u{201d}, \u{201c}csymbol\u{201d}, \u{201c}curl\u{201d}, \u{201c}declare\u{201d}, \u{201c}determinant\u{201d}, \u{201c}diff\u{201d}, \u{201c}divergence\u{201d}, \u{201c}divide\u{201d}, \u{201c}domain\u{201d}, \u{201c}emptyset\u{201d}, \u{201c}eq\u{201d}, \u{201c}equivalent\u{201d}, \u{201c}eulergamma\u{201d}, \u{201c}exists\u{201d}, \u{201c}exp\u{201d}, \u{201c}exponentiale\u{201d}, \u{201c}factorial\u{201d}, \u{201c}factorof\u{201d}, \u{201c}false\u{201d}, \u{201c}floor\u{201d}, \u{201c}fn\u{201d}, \u{201c}forall\u{201d}, \u{201c}gcd\u{201d}, \u{201c}geq\u{201d}, \u{201c}grad\u{201d}, \u{201c}gt\u{201d}, \u{201c}ident\u{201d}, \u{201c}image\u{201d}, \u{201c}imaginary\u{201d}, \u{201c}imaginaryi\u{201d}, \u{201c}implies\u{201d}, \u{201c}in\u{201d}, \u{201c}infinity\u{201d}, \u{201c}int\u{201d}, \u{201c}integers\u{201d}, \u{201c}intersect\u{201d}, \u{201c}interval\u{201d}, \u{201c}inverse\u{201d}, \u{201c}lambda\u{201d}, \u{201c}laplacian\u{201d}, \u{201c}lcm\u{201d}, \u{201c}leq\u{201d}, \u{201c}limit\u{201d}, \u{201c}list\u{201d}, \u{201c}ln\u{201d}, \u{201c}log\u{201d}, \u{201c}lt\u{201d}, \u{201c}maction\u{201d}, \u{201c}maligngroup\u{201d}, \u{201c}malignmark\u{201d}, \u{201c}matrix\u{201d}, \u{201c}matrixrow\u{201d}, \u{201c}max\u{201d}, \u{201c}mean\u{201d}, \u{201c}median\u{201d}, \u{201c}menclose\u{201d}, \u{201c}merror\u{201d}, \u{201c}mfenced\u{201d}, \u{201c}mfrac\u{201d}, \u{201c}mi\u{201d}, \u{201c}min\u{201d}, \u{201c}minus\u{201d}, \u{201c}mlongdiv\u{201d}, \u{201c}mmultiscripts\u{201d}, \u{201c}mn\u{201d}, \u{201c}mo\u{201d}, \u{201c}mode\u{201d}, \u{201c}moment\u{201d}, \u{201c}mover\u{201d}, \u{201c}mpadded\u{201d}, \u{201c}mphantom\u{201d}, \u{201c}mroot\u{201d}, \u{201c}mrow\u{201d}, \u{201c}ms\u{201d}, \u{201c}mspace\u{201d}, \u{201c}msqrt\u{201d}, \u{201c}mstack\u{201d}, \u{201c}mstyle\u{201d}, \u{201c}msub\u{201d}, \u{201c}msubsup\u{201d}, \u{201c}msup\u{201d}, \u{201c}mtable\u{201d}, \u{201c}mtext\u{201d}, \u{201c}munder\u{201d}, \u{201c}munderover\u{201d}, \u{201c}naturalnumbers\u{201d}, \u{201c}neq\u{201d}, \u{201c}not\u{201d}, \u{201c}notanumber\u{201d}, \u{201c}notin\u{201d}, \u{201c}notprsubset\u{201d}, \u{201c}notsubset\u{201d}, \u{201c}or\u{201d}, \u{201c}outerproduct\u{201d}, \u{201c}partialdiff\u{201d}, \u{201c}pi\u{201d}, \u{201c}piecewise\u{201d}, \u{201c}plus\u{201d}, \u{201c}power\u{201d}, \u{201c}primes\u{201d}, \u{201c}product\u{201d}, \u{201c}prsubset\u{201d}, \u{201c}quotient\u{201d}, \u{201c}rationals\u{201d}, \u{201c}real\u{201d}, \u{201c}reals\u{201d}, \u{201c}reln\u{201d}, \u{201c}rem\u{201d}, \u{201c}root\u{201d}, \u{201c}scalarproduct\u{201d}, \u{201c}sdev\u{201d}, \u{201c}sec\u{201d}, \u{201c}sech\u{201d}, \u{201c}selector\u{201d}, \u{201c}semantics\u{201d}, \u{201c}set\u{201d}, \u{201c}setdiff\u{201d}, \u{201c}share\u{201d}, \u{201c}sin\u{201d}, \u{201c}sinh\u{201d}, \u{201c}subset\u{201d}, \u{201c}sum\u{201d}, \u{201c}tan\u{201d}, \u{201c}tanh\u{201d}, \u{201c}tendsto\u{201d}, \u{201c}times\u{201d}, \u{201c}transpose\u{201d}, \u{201c}true\u{201d}, \u{201c}union\u{201d}, \u{201c}variance\u{201d}, \u{201c}vector\u{201d}, \u{201c}vectorproduct\u{201d}, \u{201c}xor\u{201d}."), ("error", "Element \u{201c}none\u{201d} not allowed as child of \u{201c}msup\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><template><rect role=\"xyz img\" width=\"1\" height=\"1\"/></template></svg>\n", [("error", "Discarding unrecognized token \u{201c}xyz\u{201d} from value of attribute \u{201c}role\u{201d}. Browsers ignore any token that is not a defined ARIA non-abstract role."), ("error", "Element \u{201c}template\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}template\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"SVG1.1\"><svg width=\"1\" height=\"1\"><image srcset=\"a.png 1x\" width=\"1\" height=\"1\"/></svg></annotation-xml></semantics></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><desc><svg width=\"1\" height=\"1\"><image srcset=\"a.png 1x\" width=\"1\" height=\"1\"/></svg></desc></svg>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<svg width=\"1\" height=\"1\"><foo><image srcset=\"a.png 1x\" width=\"1\" height=\"1\"/></foo></svg>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><svg width=\"1\" height=\"1\"><image srcset=\"a.png 1x\" width=\"1\" height=\"1\"/></svg></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mfoo><mtext><span><foo>x</foo></span></mtext></mfoo></math></p>\n", [("error", "Element \u{201c}mfoo\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content."), ("error", "The \u{201c}mfoo\u{201d} element is a completely-unknown element that is not allowed anywhere in any MathML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtd><mtext><span><svg width=\"1\" height=\"1\"><path d=\"x\"/></svg></span></mtext></mtd></math></p>\n", [("error", "Element \u{201c}mtd\u{201d} not allowed as child of \u{201c}math\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><math role=\"math\"><mi>x</mi></math></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><svg width=\"1\" height=\"1\"><g role=\"none\" aria-label=\"x\"></g></svg></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td>a</td></tr></table><tr><td>b\n</body>\n</html>\n", [("error", "Stray start tag \u{201c}td\u{201d}."), ("error", "Stray start tag \u{201c}tr\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><body>\n<p>x</p><frameset>\n</body>\n</html>\n", [("error", "Stray start tag \u{201c}frameset\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><body>\n<p>x</p>\n<body>\n<p>y</p>\n</body>\n</html>\n", [("error", "Start tag \u{201c}body\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><body>\n<p>x</p><head>\n</html>\n", [("error", "Stray start tag \u{201c}head\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg><g></body></p>\n", [("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}body\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}p\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}p\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}p\u{201d} seen, but there were open elements."), ("error", "Saw an end tag after \u{201c}body\u{201d} had been closed."), ("error", "Unclosed element \u{201c}g\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg><g></html></div>\n", [("error", "End of file seen and there were open elements."), ("error", "End tag for  \u{201c}html\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}div\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}div\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}html\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "End tag \u{201c}html\u{201d} did not match the name of the current open element (\u{201c}g\u{201d})."), ("error", "Stray end tag \u{201c}div\u{201d}."), ("error", "Stray end tag \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}g\u{201d}."), ("error", "Unclosed element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p></body></html>\nfoo\n<div>z</div>\n", [("error", "Non-space character in page trailer.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><frame></tr></table>\n", [("error", "Row 1 of a row group established by a \u{201c}tbody\u{201d} element has no cells beginning on it."), ("error", "Start tag \u{201c}frame\u{201d} seen in \u{201c}table\u{201d}."), ("error", "Stray start tag \u{201c}frame\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><frameset></frameset></html>\n</div>\n", [("error", "Stray end tag \u{201c}div\u{201d}."), ("error", "The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title></head><frameset><frame src=a></frameset></body>\n<p>x</p>\n", [("error", "Non-space after \u{201c}frameset\u{201d}."), ("error", "Stray end tag \u{201c}body\u{201d}."), ("error", "Stray end tag \u{201c}p\u{201d}."), ("error", "Stray start tag \u{201c}p\u{201d}."), ("error", "The \u{201c}frameset\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes."), ("error", "The \u{201c}frame\u{201d} element is obsolete. Use the \u{201c}iframe\u{201d} element and CSS instead, or use server-side includes.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><annotation-xml></body><svg></svg></annotation-xml></math></p>\n", [("error", "Element \u{201c}annotation-xml\u{201d} not allowed as child of \u{201c}math\u{201d} in this context."), ("error", "End tag for  \u{201c}body\u{201d} seen, but there were unclosed elements."), ("error", "End tag \u{201c}body\u{201d} did not match the name of the current open element (\u{201c}annotation-xml\u{201d})."), ("error", "Stray start tag \u{201c}svg\u{201d}."), ("error", "Unclosed element \u{201c}annotation-xml\u{201d}."), ("error", "Unclosed element \u{201c}math\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<a href=x>1<a href=y>2</a>\n</body>\n</html>\n", [("error", "Start tag \u{201c}a\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<form id=a><input name=q><form id=b><input name=r></form>\n</body>\n</html>\n", [("error", "Saw a \u{201c}form\u{201d} start tag, but there was already an active \u{201c}form\u{201d} element. Nested forms are not allowed. Ignoring the tag.")]),
    // A reopened <a> or <nobr>, which closes the old one; a nested <form>,
    // which is ignored (not in a template); HTML in MathML's token elements
    // (none in mi, mn, mo and ms, and only phrasing content in mtext); and
    // text directly in an <annotation-xml>, whatever its encoding.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><a href=x>1<a href=y>2</a></p>\n", [("error", "Start tag \u{201c}a\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<a href=x>1<a href=y>2</a>\n</body></html>\n", [("error", "Start tag \u{201c}a\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><nobr>1<nobr>2</nobr></p>\n", [("error", "Start tag \u{201c}nobr\u{201d} seen but an element of the same type was already open."), ("error", "The \u{201c}nobr\u{201d} element is obsolete. Use CSS instead."), ("error", "The \u{201c}nobr\u{201d} element is obsolete. Use CSS instead.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<form action=a><form action=b><input name=q></form></form>\n", [("error", "Saw a \u{201c}form\u{201d} start tag, but there was already an active \u{201c}form\u{201d} element. Nested forms are not allowed. Ignoring the tag."), ("error", "Stray end tag \u{201c}form\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<form action=a><p>x<form action=b>y</form>\n</body></html>\n", [("error", "Saw a \u{201c}form\u{201d} start tag, but there was already an active \u{201c}form\u{201d} element. Nested forms are not allowed. Ignoring the tag.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<form action=a><template><form action=b></form></template></form>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi><b>x</b></mi></math></p>\n", [("error", "Element \u{201c}b\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mo><span>+</span></mo></math></p>\n", [("error", "Element \u{201c}span\u{201d} not allowed as child of \u{201c}mo\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><div>x</div></mtext></math></p>\n", [("error", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}mtext\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><b>x</b></mtext></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><p>x</p></mtext></math></p>\n", [("error", "Element \u{201c}p\u{201d} not allowed as child of \u{201c}mtext\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><li>x</li></mtext></math></p>\n", [("error", "Element \u{201c}li\u{201d} not allowed as child of \u{201c}mtext\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi><b><foo>x</foo></b></mi></math></p>\n", [("error", "Element \u{201c}b\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mtext><img src=x.png alt=y></mtext></math></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><ms><svg width=1 height=1></svg></ms></math></p>\n", [("error", "Element \u{201c}svg\u{201d} not allowed as child of \u{201c}ms\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mn><input name=q></mn></math></p>\n", [("error", "Element \u{201c}input\u{201d} not allowed as child of \u{201c}mn\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml>text</annotation-xml></semantics></math></p>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\">text</annotation-xml></semantics></math></p>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><semantics><mi>x</mi><annotation-xml encoding=\"SVG1.1\">text<svg width=1 height=1></svg></annotation-xml></semantics></math></p>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    // An SVG <desc>'s unchecked content reaches into an <annotation-xml>
    // inside it; an unknown element in an <mi> is reported once; nothing
    // more inside a rejected HTML element; CDATA text in an <annotation-xml>,
    // and nothing in a template.
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<svg><desc><math><mi><math></math></mi></math></desc></svg>\n</body>\n</html>\n", []),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<svg><desc><math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\"><div><math></math></div></annotation-xml></semantics></math></desc></svg>\n</body>\n</html>\n", []),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml><svg><desc><math></math></desc></svg></annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Element \u{201c}math\u{201d} not allowed as child of \u{201c}desc\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<svg><desc><math><mi><b>x</b></mi></math></desc></svg>\n</body>\n</html>\n", []),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<svg><desc><math><semantics><mi>x</mi><annotation-xml>text</annotation-xml></semantics></math></desc></svg>\n</body>\n</html>\n", []),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml>a<mi>y</mi>b</annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><mi><foo>x</foo></mi></math>\n</body>\n</html>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><mi><my-el>x</my-el></mi></math>\n</body>\n</html>\n", [("error", "Element \u{201c}my-el\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><mtext><my-el>x</my-el><foo>y</foo></mtext></math>\n</body>\n</html>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}mtext\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any HTML content.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><mi><span><svg><path d=\"zz\"/></svg></span></mi></math>\n</body>\n</html>\n", [("error", "Element \u{201c}span\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><mtext><div><svg><path d=\"zz\"/></svg></div></mtext></math>\n</body>\n</html>\n", [("error", "Element \u{201c}div\u{201d} not allowed as child of \u{201c}mtext\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml><![CDATA[x]]></annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<template><math><mi><b>x</b></mi></math></template>\n</body>\n</html>\n", []),
    // "Text not allowed" once for each piece of the text that upstream's
    // tokenizer hands on: split at child elements, comments, character
    // references and a "<" that doesn't start a tag, a piece that's only
    // whitespace (a reference to whitespace included) being fine.
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a<mi>x</mi>b<mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a&amp;b<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml>a&amp;b<!--c-->d</annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml>a<mi>y</mi></annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml><mi>y</mi>b</annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><mfrac>a<mi>x</mi><mi>y</mi>b</mfrac></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}mfrac\u{201d} in this context."), ("error", "Text not allowed in \u{201c}mfrac\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\">a<div>y</div>b<span>z</span>c</annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub><mi>x</mi>a<mi>y</mi>b<mi>z</mi></msub></math>\n</body>\n</html>\n", [("error", "Element \u{201c}mi\u{201d} not allowed as child of \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><semantics><mi>x</mi><annotation-xml encoding=\"text/html\">a&amp;b</annotation-xml></semantics></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context."), ("error", "Text not allowed in \u{201c}annotation-xml\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a & b<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a&foo;b<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>&#32;x<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a\n<!-- c -->\n<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a&amp;<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a&amp b<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Named character reference was not terminated by a semicolon. (Or \u{201c}&\u{201d} should have been escaped as \u{201c}&amp;\u{201d}.)"), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a&#x41;b&#65<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Character reference was not terminated by a semicolon."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<math><msub>a&&b<mi>x</mi><mi>y</mi></msub></math>\n</body>\n</html>\n", [("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context."), ("error", "Text not allowed in \u{201c}msub\u{201d} in this context.")]),
    // A reopened <a> or <nobr> outside a cell, with "violates nesting rules"
    // when the old one isn't the current node; </body> in a template whose
    // table part has closed (still a table mode); nothing more inside HTML
    // that an <mi> rejects, MathML included; and, at the end of the file, an
    // open <p> (not an error), <li>, cell or <dd> (whose list or table is).
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><a href=x>1<a href=y>2</a><img usemap=#m src=x alt=y></p><map name=m></map>\n", [("error", "Start tag \u{201c}a\u{201d} seen but an element of the same type was already open.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<a href=x><span>x<a href=y>z</a></span>\n", [("error", "End tag \u{201c}a\u{201d} violates nesting rules."), ("error", "Start tag \u{201c}a\u{201d} seen but an element of the same type was already open."), ("error", "Stray end tag \u{201c}span\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><nobr>x<span>y<nobr>z</nobr></span></p>\n", [("error", "End tag \u{201c}nobr\u{201d} violates nesting rules."), ("error", "Start tag \u{201c}nobr\u{201d} seen but an element of the same type was already open."), ("error", "Stray end tag \u{201c}span\u{201d}."), ("error", "The \u{201c}nobr\u{201d} element is obsolete. Use CSS instead."), ("error", "The \u{201c}nobr\u{201d} element is obsolete. Use CSS instead.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><tr></tr></body>\n", [("error", "End of file seen and there were open elements."), ("error", "Stray end tag \u{201c}body\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><caption></caption></body>\n", [("error", "End of file seen and there were open elements."), ("error", "Stray end tag \u{201c}body\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi><span><math><msub><mi>a</mi></msub></math></span></mi></math></p>\n", [("error", "Element \u{201c}span\u{201d} not allowed as child of \u{201c}mi\u{201d} in this context.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<ul><li>x\n", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}ul\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<table><tr><td>x\n", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}table\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<dl><dt>a<dd>b\n", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}dl\u{201d}.")]),
    // The end of the file in a <template>: in its own "in template" mode
    // (head content only) upstream only lists what's open; in its body or
    // table modes, open elements are an error first; and in the head, the
    // template's mode, not the head's, decides (with the <head> tag or
    // without it).
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template>", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><style>p{}</style>", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><template>", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><div>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><template></template>", []),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><noscript>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}noscript\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><template><p>x</template></head><body>", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><script>var a</script>", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template>", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><div>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><template>", [("error", "Unclosed element \u{201c}template\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><template><div>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><div></div><template>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}template\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><td>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><col>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><script>var a", [("error", "End of file seen when expecting text or an end tag."), ("error", "Unclosed element \u{201c}script\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template>text", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><style>p{}</style>", [("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><template><span>a</span>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p>x</p><div><template><link rel=x href=y>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}div\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    // And the end of the file in the head: anything open in it (a
    // <noscript>, with the <head> tag or without it) is an error; a raw-text
    // element there is listed after the tokenizer's error.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><noscript>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}noscript\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><noscript><link rel=stylesheet href=a.css>", [("error", "End of file seen and there were open elements."), ("error", "Unclosed element \u{201c}noscript\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title>", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><template><template>", [("error", "Unclosed element \u{201c}template\u{201d}."), ("error", "Unclosed element \u{201c}template\u{201d}.")]),
    ("<!doctype html><html lang=en><head><meta charset=utf-8><title>T</title><noscript></noscript>", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><style>p{}", [("error", "End of file seen when expecting text or an end tag."), ("error", "Unclosed element \u{201c}style\u{201d}.")]),
    // An SVG or MathML element's id is an XML 1.0 name: no leading digit or
    // hyphen, no space (or NBSP), not empty; a leading colon, or a letter
    // beyond ASCII, is fine. Not checked in a template, in a desc's content,
    // or on an element the schema rejects; HTML's ids keep HTML's rule.
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"a b\"></svg></p>\n", [("error", "Bad value \u{201c}a b\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"1icon\"></svg></p>\n", [("error", "Bad value \u{201c}1icon\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"\"></svg></p>\n", [("error", "Bad value \u{201c}\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"icon-1.a_b:c\"></svg></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1><g id=\"2\"/></svg></p>\n", [("error", "Bad value \u{201c}2\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}g\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math id=\"3\"><mi>x</mi></math></p>\n", [("error", "Bad value \u{201c}3\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}math\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"\u{e9}t\u{e9}\"></svg></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"a&#32;b\"></svg></p>\n", [("error", "Bad value \u{201c}a b\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<template><svg width=1 height=1 id=\"1\"></svg></template>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1><foo id=\"1\"/></svg></p>\n", [("error", "Element \u{201c}foo\u{201d} not allowed as child of \u{201c}svg\u{201d} in this context."), ("error", "The \u{201c}foo\u{201d} element is a completely-unknown element that is not allowed anywhere in any SVG content.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id></svg></p>\n", [("error", "Bad value \u{201c}\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><math><mi id=\"4x\">x</mi></math></p>\n", [("error", "Bad value \u{201c}4x\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}mi\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"-a\"></svg></p>\n", [("error", "Bad value \u{201c}-a\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\":a\"></svg></p>\n", []),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p id=\"1x\">x</p><p id=\"a b\">y</p>\n", [("error", "Bad value \u{201c}a b\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}p\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1 id=\"a\u{a0}b\"></svg></p>\n", [("error", "Bad value \u{201c}a\u{a0}b\u{201d} for attribute \u{201c}id\u{201d} on element \u{201c}svg\u{201d}.")]),
    ("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<p><svg width=1 height=1><desc><svg width=1 height=1 id=\"5\"></svg></desc></svg></p>\n", []),
] as [(String, [(String, String)])])
func treeBuilderModesAndMathMLContentMatchUpstream(document: String, expected: [(String, String)]) {
    let actual = checkHTML(document).messages
        .filter { $0.type != "info" || $0.subType == "warning" }
        .map { "\($0.type == "info" ? "warning" : "error"): \($0.message)" }
        .sorted()
    #expect(actual == expected.map { "\($0.0): \($0.1)" }.sorted(), "\(document)")
}

// Review item A2: an <image> start tag in a table is reported under the name
// it was written with, then again as the <img> upstream handles it as. (vnu.jar
// then stops checking the document, "Cannot recover after last error", which
// the port doesn't, so this can't be one of the exact cases above.)
@Test func imageInTableIsReportedUnderBothNames() {
    let messages = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><table><image src=\"x.png\" alt=\"A\"></table>").messages.map(\.message)
    #expect(messages.contains("Start tag \u{201c}image\u{201d} seen in \u{201c}table\u{201d}."))
    #expect(messages.contains("Saw a start tag \u{201c}image\u{201d}."))
    #expect(messages.contains("Start tag \u{201c}img\u{201d} seen in \u{201c}table\u{201d}."))
}

// Review item A2: a reopened <a> whose old one has a block (a "special"
// element) opened inside it closes only the old <a>, leaving the block open,
// as upstream's adoption agency does; closing the block too gave a false
// "Stray end tag “div”". (vnu.jar then stops checking the document, "Cannot
// recover after last error", which the port doesn't, so this can't be one of
// the exact cases above.) And a cell or an <object> between the two hides
// the old one from the tree builder: it reports nothing there. (vnu.jar does
// report "The element “a” must not appear as a descendant of the “a”
// element.", an Assertions check the port doesn't have yet.)
@Test func reopenedAnchorClosesOnlyTheOldOneAndStopsAtCells() {
    let block = "<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<a href=x><div><a href=y>z</a></div>\n"
    #expect(["Start tag \u{201c}a\u{201d} seen but an element of the same type was already open.", "End tag \u{201c}a\u{201d} violates nesting rules."] == errorMessages(checkHTML(block)))
    for body in ["<a><table><tr><td><a>x</a></td></tr></table></a>", "<a><object data=x><a>y</a></object></a>"] {
        #expect([] == errorMessages(checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n\(body)\n")), "\(body)")
    }
    // An old <a> that's out of scope, below an SVG <foreignObject>, is "No
    // “a” element in scope", vnu.jar's first two errors here (it then stops).
    let outOfScope = errorMessages(checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title>\n<a href=x><svg width=1 height=1><foreignObject><a href=y>z</a></foreignObject></svg></a>\n"))
    #expect(["Start tag \u{201c}a\u{201d} seen but an element of the same type was already open.", "No \u{201c}a\u{201d} element in scope but a \u{201c}a\u{201d} end tag seen."] == Array(outOfScope.prefix(2)))
}

@Test func generalAttributeCheckerCoversARIAMiscRoleRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <dialog role=dialog>Dialog</dialog>
        <dl><div role=group><dt>Term</dt><dd>Definition</dd></div></dl>
        <ul role=listbox><li role=button>Item</li></ul>
        <main>Main</main><div role=main>Main role</div>
        <div role=tablist><button role=tab aria-selected=true>Tab</button></div>
        <select multiple role=button><option>One</option></select>
        <select role=listbox><option>One</option></select>
        <details><summary role=button aria-selected=true>Summary</summary></details>
        <div contenteditable aria-readonly=true>Editable</div>
        <div role=menu><div role=group><span role=button>Bad</span></div></div>
        <div role=grid><div role=rowgroup><span role=button>Bad</span></div></div>
        <div role=button><h1>Heading</h1></div>
        <div role=img aria-label=Image><button>Button</button></div>
        <div role=separator><label>Name <input></label></div>
        <div role=listbox aria-expanded=false>Listbox</div>
        """)
    #expect(result.messages.contains { $0.message == "The \u{201c}dialog\u{201d} role is unnecessary for element \u{201c}dialog\u{201d}." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "A \u{201c}div\u{201d} child of a \u{201c}dl\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}presentation\u{201d} or \u{201c}none\u{201d}." })
    #expect(result.messages.contains { $0.message == "An \u{201c}li\u{201d} element that is a descendant of a \u{201c}role=listbox\u{201d} element or \u{201c}role=list\u{201d} element must not have any \u{201c}role\u{201d} value other than \u{201c}group\u{201d} or \u{201c}option\u{201d}." })
    #expect(result.messages.contains { $0.message == "A document should not include more than one visible element with \u{201c}role=main\u{201d}." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Every active \u{201c}role=tab\u{201d} element must have a corresponding \u{201c}role=tabpanel\u{201d} element." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}button\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}select\u{201d}." })
    #expect(result.messages.contains { $0.message == "The \u{201c}listbox\u{201d} role is not allowed for element \u{201c}select\u{201d} without a \u{201c}multiple\u{201d} attribute and without a \u{201c}size\u{201d} attribute whose value is greater than 1." })
    #expect(result.messages.contains { $0.message == "The \u{201c}role\u{201d} attribute must not be used on any \u{201c}summary\u{201d} element that is a summary for its parent \u{201c}details\u{201d} element." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}summary\u{201d} is missing one or more of the following attributes: \u{201c}aria-checked\u{201d}, \u{201c}role\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}div\u{201d} is missing one or more of the following attributes: \u{201c}aria-checked\u{201d}, \u{201c}aria-expanded\u{201d}, \u{201c}aria-valuenow\u{201d}, \u{201c}role\u{201d}." })
    #expect(result.messages.contains { $0.message == "An element with \u{201c}role=group\u{201d} that is a descendant of an element with \u{201c}role=menu\u{201d} or \u{201c}role=menubar\u{201d} must contain only elements with \u{201c}role=menuitem\u{201d}, \u{201c}role=menuitemcheckbox\u{201d}, or \u{201c}role=menuitemradio\u{201d}." })
    #expect(result.messages.contains { $0.message == "An element that is a child of an element with \u{201c}role=rowgroup\u{201d} must have \u{201c}role=row\u{201d}." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}h1\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=button\u{201d}." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}button\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=img\u{201d}." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}label\u{201d} must not appear as a descendant of an element with the attribute \u{201c}role=separator\u{201d}." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}aria-expanded\u{201d} not allowed on element \u{201c}div\u{201d} at this point." })
}

@Test func generalAttributeCheckerCoversImageAndSelectEdgeRules() {
    let result = checkHTML("""
        <!doctype html><html lang=en><meta charset=utf-8><title>T</title>
        <img src=x alt=x border=0 controls=invalid width=-1 height=-1 usemap=#missing>
        <img src=x alt="" controls>
        <img src=x alt=x ismap>
        <a href=#x><img src=x alt=x usemap=#missing></a>
        <select autocomplete="country webauthn" size=0 multiple><button>Pick</button><option>One</option></select>
        <select><option selected>One</option><option selected>Two</option></select>
        <select required><option value=notempty>One</option></select>
        <select required></select>
        <select><button><selectedcontent aria-hidden=true role=status></selectedcontent></button></select>
        """)
    #expect(result.messages.contains { $0.message == "The \u{201c}border\u{201d} attribute on the \u{201c}img\u{201d} element is obsolete. Consider specifying \u{201c}img { border: 0; }\u{201d} in CSS instead." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}invalid\u{201d} for attribute \u{201c}controls\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}-1\u{201d} for attribute \u{201c}width\u{201d} on element \u{201c}img\u{201d}." })
    #expect(result.messages.contains { $0.message == "The \u{201c}controls\u{201d} attribute must not be specified on an \u{201c}img\u{201d} element that does not have an \u{201c}alt\u{201d} attribute, or whose \u{201c}alt\u{201d} attribute\u{2019}s value is the empty string." })
    #expect(result.messages.contains { $0.message == "The \u{201c}img\u{201d} element with the \u{201c}ismap\u{201d} attribute set must have an \u{201c}a\u{201d} ancestor with the \u{201c}href\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "The hash-name reference in attribute \u{201c}usemap\u{201d} referred to \u{201c}missing\u{201d}, but there is no \u{201c}map\u{201d} element with a \u{201c}name\u{201d} attribute with that value." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}img\u{201d} with the attribute \u{201c}usemap\u{201d} must not appear as a descendant of the \u{201c}a\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}autocomplete\u{201d} attribute for the \u{201c}select\u{201d} element must not contain \u{201c}webauthn\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}0\u{201d} for attribute \u{201c}size\u{201d} on element \u{201c}select\u{201d}." })
    #expect(result.messages.contains { $0.message == "A \u{201c}button\u{201d} element is only allowed as a child of a \u{201c}select\u{201d} element that is a drop-down box (one without a \u{201c}size\u{201d} attribute greater than 1 and without a \u{201c}multiple\u{201d} attribute)." })
    #expect(result.messages.contains { $0.message == "The \u{201c}select\u{201d} element cannot have more than one selected \u{201c}option\u{201d} descendant unless the \u{201c}multiple\u{201d} attribute is specified." })
    #expect(result.messages.contains { $0.message == "The first child \u{201c}option\u{201d} element of a \u{201c}select\u{201d} element with a \u{201c}required\u{201d} attribute, and without a \u{201c}multiple\u{201d} attribute, and without a \u{201c}size\u{201d} attribute whose value is greater than \u{201c}1\u{201d}, must have either an empty \u{201c}value\u{201d} attribute, or must have no text content. Consider either adding a placeholder option label, or adding a \u{201c}size\u{201d} attribute with a value equal to the number of \u{201c}option\u{201d} elements." })
    #expect(result.messages.contains { $0.message == "A \u{201c}select\u{201d} element with a \u{201c}required\u{201d} attribute, and without a \u{201c}multiple\u{201d} attribute, and without a \u{201c}size\u{201d} attribute whose value is greater than \u{201c}1\u{201d}, must have a child \u{201c}option\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The \u{201c}aria-hidden\u{201d} attribute must not be used on a \u{201c}selectedcontent\u{201d} element inside the \u{201c}button\u{201d} part of a customizable \u{201c}select\u{201d} element." })
}

@Test func xmlValidatorCoversXHTMLLinkHrefRequirement() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title><link rel=\"stylesheet\"/></head><body/></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both." })
}

@Test func xmlValidatorCoversXHTMLTableModelRules() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
            <table><tr><td rowspan="3">1</td><td>2</td></tr><tr><td rowspan="3">3</td></tr><tr></tr><tr><td>4</td></tr></table>
            <table><col/><tr><td>1</td></tr></table>
            </body></html>
            """.utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "Row 3 of an implicit row group has no cells beginning on it." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}col\u{201d} not allowed as child of \u{201c}table\u{201d} in this context." })

    let rootResult = NuValidator().check(
        input: DocumentInput(data: Data("<table xmlns=\"http://www.w3.org/1999/xhtml\"><caption>T</caption><tr><td>Cell</td></tr></table>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(rootResult.messages.contains { $0.message == "Element \u{201c}table\u{201d} not allowed in this context." })
}

@Test func xmlValidatorCoversXHTMLMenuFigureAndElementRules() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
            <menu type="context"><hr/>Text<menuitem label="Command"/></menu>
            <p contextmenu="m">p</p><a name="" href=""></a><iframe>text</iframe>
            <figure><img src="x" alt="x"/><figcaption>Caption</figcaption><img src="y" alt="y"/>Text</figure>
            <header><footer></footer></header><footer><header></header></footer>
            </body></html>
            """.utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "The \u{201c}type\u{201d} attribute on the \u{201c}menu\u{201d} element is obsolete. Use script to handle \u{201c}contextmenu\u{201d} event instead." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Element \u{201c}hr\u{201d} not allowed as child of \u{201c}menu\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Text not allowed in \u{201c}menu\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "The \u{201c}contextmenu\u{201d} attribute is obsolete. Use script to handle \u{201c}contextmenu\u{201d} event instead." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The \u{201c}name\u{201d} attribute on the \u{201c}a\u{201d} element is obsolete. Consider putting an \u{201c}id\u{201d} attribute on the nearest container instead." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Text not allowed in \u{201c}iframe\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}img\u{201d} not allowed as child of \u{201c}figure\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Text not allowed in \u{201c}figure\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}footer\u{201d} must not appear as a descendant of the \u{201c}header\u{201d} element." })
    #expect(result.messages.contains { $0.message == "The element \u{201c}header\u{201d} must not appear as a descendant of the \u{201c}footer\u{201d} element." })
}

@Test func xmlValidatorCoversXHTMLRubyRules() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
            <ruby></ruby><ruby><rt></rt><rp></rp><rp></rp></ruby>
            </body></html>
            """.utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "Element \u{201c}ruby\u{201d} is missing a required instance of one or more of the following child elements: \u{201c}rp\u{201d}, \u{201c}rt\u{201d}, \u{201c}rtc\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}ruby\u{201d} is missing a required instance of child element \u{201c}rt\u{201d}." })
}

@Test func xmlValidatorCoversXHTMLGlobalAttributeValues() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><base/><title>T</title></head><body><a href=\"x\" accesskey=\"a b a\">x</a><p spellcheck=\"badvalue\" data-zZ=\"\"></p></body></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "Element \u{201c}base\u{201d} is missing one or more of the following attributes: \u{201c}href\u{201d}, \u{201c}target\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}a b a\u{201d} for attribute \u{201c}accesskey\u{201d} on element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}badvalue\u{201d} for attribute \u{201c}spellcheck\u{201d} on element \u{201c}p\u{201d}." })
    #expect(result.messages.contains { $0.message == "\u{201c}data-*\u{201d} attributes must not have characters from the range \u{201c}A\u{201d}\u{2026}\u{201c}Z\u{201d} in the name." })
}

@Test func xmlValidatorCoversXHTMLScriptLanguageWarning() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><script language=\"vbscript\"/></body></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "The \u{201c}language\u{201d} attribute on the \u{201c}script\u{201d} element is obsolete. Use the \u{201c}type\u{201d} attribute instead." && $0.subType == "warning" })
}

@Test func xmlValidatorCoversXHTMLInputListReference() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><datalist id=\"known\"/><input type=\"text\" list=\"missing\"/></body></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "The \u{201c}list\u{201d} attribute of the \u{201c}input\u{201d} element must refer to a \u{201c}datalist\u{201d} element." })
}

@Test func xmlValidatorCoversXHTMLObsoleteKeygen() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><keygen name=\"k\"/></body></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "The \u{201c}keygen\u{201d} element is obsolete." })
}

@Test func xmlValidatorCoversXHTMLDuplicateDefinitionTerms() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><dl><dt>text</dt><dd>one</dd><dt> text </dt><dd>two</dd></dl></body></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "Duplicate \u{201c}dt\u{201d} name \u{201c}text\u{201d} in \u{201c}dl\u{201d} element. Within a single \u{201c}dl\u{201d} element, there should not be more than one \u{201c}dt\u{201d} element for each name." && $0.subType == "warning" })
}

@Test func xmlValidatorCoversXHTMLNumericAndEmbeddedRules() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title></head><body><meter min=\"0.2\" value=\"0.1\"/><meter min=\"0.3\" low=\"0.2\"/><progress value=\"0.9\" max=\"0.5\"/><embed height=\"20%\" width=\"20%\" type=\"foo\"/></body></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}min\u{201d} attribute must be less than or equal to the value of the \u{201c}value\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}meter\u{201d} is missing required attribute \u{201c}value\u{201d}." })
    #expect(result.messages.contains { $0.message == "The value of the  \u{201c}value\u{201d} attribute must be less than or equal to the value of the \u{201c}max\u{201d} attribute." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}20%\u{201d} for attribute \u{201c}height\u{201d} on element \u{201c}embed\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}20%\u{201d} for attribute \u{201c}width\u{201d} on element \u{201c}embed\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}foo\u{201d} for attribute \u{201c}type\u{201d} on element \u{201c}embed\u{201d}." })
}

@Test func htmlCheckerCoversCSPAndUnicodeNormalizationWarnings() {
    let result = checkHTML("""
        <!doctype html><html lang=en><head>
        <meta charset=utf-8><title>T</title>
        <meta http-equiv="Content-Security-Policy" content="script-src 'self'; style-src 'self'">
        <script>alert(1)</script>
        <style>p { color: red }</style>
        </head><body><button onclick="go()" style="color:red">Go</button><p>&#8053;</p></body></html>
        """)

    #expect(result.messages.contains { $0.message == "Inline script violates Content Security Policy (meta tag): blocked by \u{201c}script-src\u{201d} directive (missing \u{201c}\u{2018}unsafe-inline\u{2019}\u{201d} or nonce/hash)." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Inline style violates Content Security Policy (meta tag): blocked by \u{201c}style-src\u{201d} directive (missing \u{201c}\u{2018}unsafe-inline\u{2019}\u{201d} or nonce/hash)." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Event handler attribute \u{201c}onclick\u{201d} violates Content Security Policy (meta tag): blocked by \u{201c}script-src\u{201d} directive." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "The \u{201c}style\u{201d} attribute violates Content Security Policy (meta tag): blocked by \u{201c}style-src\u{201d} directive." && $0.subType == "warning" })
}

@Test func htmlCheckerCoversUnicodeNormalizationWarnings() {
    let result = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><p>&#8053;</p></html>")

    #expect(result.messages.contains { $0.message == "Text run is not in Unicode Normalization Form C. Should instead be \u{201c}\u{03ae}\u{201d}. (Copy and paste that into your source document to replace the un-normalized text.)" && $0.subType == "warning" })
    let vietnamese = checkHTML("<!doctype html><html lang=en><meta charset=utf-8><title>T</title><p>Tại sao họ không thể chỉ nói tiếng Việt ?</p></html>")
    #expect(vietnamese.messages.contains { $0.message == "Text run is not in Unicode Normalization Form C. Should instead be \u{201c}Tại sao họ không thể chỉ nói tiếng Việt \u{201d}. (Copy and paste that into your source document to replace the un-normalized text.)" && $0.subType == "warning" })
}

@Test func xmlValidatorCoversXMLStylesheetProcessingInstructions() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("""
            <?xml-stylesheet href="style.css" charset="utf-8"?>
            <?xml-stylesheet href="style.css" href="duplicate.css"?>
            <?xml-stylesheet href="style.css" type?>
            <?xml-stylesheet href="ht tp://example.com/style.css"?>
            <?xml-stylesheet href="style.css" alternate="yes"?>
            <?xml-stylesheet href="style.css" alternate="maybe"?>
            <?xml-stylesheet href="style.css" type="text"?>
            <?xml-stylesheet href="style.css" type="application/xslt+xml"?>
            <?xml-stylesheet foo="bar"?>
            <?xml-stylesheet HREF="style.css"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body/></html>
            <?xml-stylesheet href="after.css"?>
            """.utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )

    #expect(result.messages.contains { $0.message == "Some browsers ignore the value of the \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}charset\u{201d}." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Duplicate \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}href\u{201d}." })
    #expect(result.messages.contains { $0.message == "Found \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}type\u{201d} without a value. All pseudo-attributes in \u{201c}xml-stylesheet\u{201d} instructions must have values." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}ht tp://example.com/style.css\u{201d} for \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}href\u{201d}. Bad URL: Illegal character in path segment. Space is not allowed." })
    #expect(result.messages.contains { $0.message == "An \u{201c}xml-stylesheet\u{201d} instruction with an \u{201c}alternate\u{201d} pseudo-attribute whose value is \u{201c}yes\u{201d} must also have a \u{201c}title\u{201d} pseudo-attribute with a non-empty value." })
    #expect(result.messages.contains { $0.message == "The value of the \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}alternate\u{201d} must be either \u{201c}yes\u{201d} or \u{201c}no\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}text\u{201d} for \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}type\u{201d}. Bad MIME type: Subtype missing." })
    #expect(result.messages.contains { $0.message == "\u{201c}text/css\u{201d} and \u{201c}text/xsl\u{201d} are the only MIME types for the \u{201c}xml-stylesheet\u{201d} pseudo-attribute \u{201c}type\u{201d} that are supported across browsers." && $0.subType == "warning" })
    #expect(result.messages.contains { $0.message == "Pseudo-attribute \u{201c}foo\u{201d} not allowed in \u{201c}xml-stylesheet\u{201d} instruction." })
    #expect(result.messages.contains { $0.message == "Pseudo-attribute \u{201c}HREF\u{201d} not allowed in \u{201c}xml-stylesheet\u{201d} instruction." })
    #expect(result.messages.contains { $0.message == "\u{201c}xml-stylesheet\u{201d} instruction lacks \u{201c}href\u{201d} pseudo-attribute. The \u{201c}href\u{201d} pseudo-attribute is required in all \u{201c}xml-stylesheet\u{201d} instructions." })
    #expect(result.messages.contains { $0.message == "Any \u{201c}xml-stylesheet\u{201d} instruction in a document must occur before any elements in the document. Suppressing any further errors for this \u{201c}xml-stylesheet\u{201d} instruction." })
}

@Test func htmlCheckerCoversRemainingForeignContentAndRDFaRules() {
    // (Review item A2: the <div> gets a <math> of its own because, as in
    // upstream's tree builder, it breaks out of the <math> it's in, so an
    // <mfrac> after it would no longer be MathML. And the feFuncR follows a
    // feFuncG, because one feFuncR alone is valid; the port used to report
    // every one.)
    let japanese = String(repeating: "\u{3042}", count: 50)
    let result = checkHTML("""
        <!doctype html><html lang=en dir=ltr prefix="foaf: http://xmlns.com/foaf/0.1/"><head>
        <meta charset=utf-8><title>T</title></head><body>
        <div href=x prefix=": http://xmlns.com/foaf/0.1/" role="ex:somerole"></div>
        <table><colgroup span=3><col></colgroup><tr><td>x</td></tr></table>
        <dialog><dt>term</dt></dialog>
        <math display=center overflow=wrap><mfrac><mi>x</mi></mfrac></math><math><div>x</div></math>
        <svg xmlns="http://example.org/notsvg"><g xmlns:xlink="http://example.net/bar">
        <feConvolveMatrix/><feComponentTransfer><feFuncG/><feFuncR/></feComponentTransfer>
        <font/><rect xml:id=x stop-color=red/><path d="M 20 100 H 40#90"/>
        <a><a></a></a></g></svg>
        <p>\(japanese)</p>
        </body></html>
        """)

    #expect(result.messages.contains { $0.message == "Attribute \u{201c}href\u{201d} not allowed on element \u{201c}div\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}: http://xmlns.com/foaf/0.1/\u{201d} for attribute \u{201c}prefix\u{201d} on element \u{201c}div\u{201d}." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}ex:somerole\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}div\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}col\u{201d} not allowed as child of \u{201c}colgroup\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}dt\u{201d} not allowed as child of \u{201c}dialog\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}center\u{201d} for attribute \u{201c}display\u{201d} on element \u{201c}math\u{201d}." })
    #expect(result.messages.contains { $0.message == "HTML start tag \u{201c}div\u{201d} in a foreign namespace context." })
    #expect(result.messages.contains { $0.message.contains("Element \u{201c}mfrac\u{201d} is missing a required instance") && $0.message.contains("\u{201c}vectorproduct\u{201d}") })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}http://example.org/notsvg\u{201d} for the attribute \u{201c}xmlns\u{201d} (only \u{201c}http://www.w3.org/2000/svg\u{201d} permitted here)." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}http://example.net/bar\u{201d} for the attribute \u{201c}xmlns:link\u{201d} (only \u{201c}http://www.w3.org/1999/xlink\u{201d} permitted here)." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}feConvolveMatrix\u{201d} is missing required attribute \u{201c}order\u{201d}." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}feFuncR\u{201d} not allowed as child of \u{201c}feComponentTransfer\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}font\u{201d} is missing a required instance of child element \u{201c}missing-glyph\u{201d}." })
    #expect(result.messages.contains { $0.message == "Attribute \u{201c}xml:id\u{201d} not allowed on element \u{201c}rect\u{201d} at this point." })
    #expect(result.messages.contains { $0.message == "Bad value \u{201c}M 20 100 H 40#90\u{201d} for attribute \u{201c}d\u{201d} on element \u{201c}path\u{201d}." })
    #expect(result.messages.contains { $0.message == "The SVG element \u{201c}a\u{201d} must not appear as a descendant of another SVG element \u{201c}a\u{201d}." })
    #expect(result.messages.contains { $0.message == "This document appears to be written in Japanese but the \u{201c}html\u{201d} start tag has \u{201c}lang=\"en\"\u{201d}. Consider using \u{201c}lang=\"ja\"\u{201d} (or variant) instead." && $0.subType == "warning" })
}

@Test func xmlValidatorCoversRemainingXHTMLRules() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
            <dialog><dt>term</dt></dialog>
            <object></object>
            <applet code="x" width="10" height="10"></applet>
            </body></html>
            """.utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )

    #expect(result.messages.contains { $0.message == "Element \u{201c}dt\u{201d} not allowed as child of \u{201c}dialog\u{201d} in this context." })
    #expect(result.messages.contains { $0.message == "Element \u{201c}object\u{201d} is missing required attribute \u{201c}data\u{201d}." })
    #expect(result.messages.contains { $0.message == "The \u{201c}applet\u{201d} element is obsolete. Use \u{201c}embed\u{201d} or \u{201c}object\u{201d} element instead." })
}

// MARK: Case 554591: optional end tags and text-only element contents
//
// These documents are all valid (the W3C's checker reports no errors for
// them), but the Swift port reported errors for every one: list items,
// paragraphs, table parts, options and ruby text were closed by the wrong
// rules, and the contents of <script>/<style>/<title>/<textarea> were parsed
// as markup. The parity harness didn't notice because it only runs invalid
// fixtures, so these pin down the valid side.

/// Wraps body markup in a minimal valid document.
private func validDocument(head: String = "", body: String) -> String {
    "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n\(head)</head>\n<body>\n\(body)\n</body>\n</html>\n"
}

private func errorMessages(_ result: ValidationResult) -> [String] {
    result.messages.filter { "error" == $0.type }.map(\.message)
}

private let optionalEndTagBodies: [String] = [
    // Nested list, every end tag present: the inner <li> used to close the outer one.
    "<ul>\n<li>A\n<ul>\n<li>B</li>\n</ul>\n</li>\n<li>C</li>\n</ul>",
    // Nested list relying on the optional </li> (the case 554591 navigation menu).
    "<ul>\n<li>A\n<ul>\n<li>B</li>\n</ul>\n<li>C</li>\n</ul>",
    // Flat list relying on the optional </li>, closed by </ul>.
    "<ul>\n<li>A\n<li>B\n<li>C\n</ul>",
    // Ordered lists nested in a nav, three levels, optional </li> throughout.
    "<nav>\n<ol>\n<li><a href=\"a\">A</a>\n<ol>\n<li><a href=\"b\">B</a>\n<ol>\n<li><a href=\"c\">C</a>\n</ol>\n<li><a href=\"d\">D</a>\n</ol>\n<li><a href=\"e\">E</a>\n</ol>\n</nav>",
    "<menu>\n<li><button type=\"button\">One</button>\n<li><button type=\"button\">Two</button>\n</menu>",
    "<ul>\n<li><details><summary>S</summary><ul><li>x</ul></details>\n<li>y\n</ul>",
    "<ul>\n<li><p>One\n<li><p>Two\n</ul>",
    // Description lists: nested in a <dd>, and grouped in <div>s.
    "<dl>\n<dt>A</dt>\n<dd>\n<dl>\n<dt>B</dt>\n<dd>C</dd>\n</dl>\n</dd>\n<dt>D</dt>\n<dd>E</dd>\n</dl>",
    "<dl>\n<div><dt>A<dd>B</div>\n<div><dt>C<dd>D</div>\n</dl>",
    // Paragraphs closed by the next block, the next <p>, or the parent's end tag.
    "<p>Intro\n<ul>\n<li>x\n</ul>\n<p>One\n<p>Two\n<div>D</div>",
    "<div><p>Text</div>\n<article><h2>H</h2><p>A<p>B</article>",
    // Table parts with optional end tags.
    "<table>\n<tr><th>A<th>B\n<tr><td>1<td>2\n</table>",
    "<table>\n<thead>\n<tr><th>A\n<tbody>\n<tr><td>1\n<tfoot>\n<tr><td>F\n</table>",
    "<table>\n<caption>C\n<thead><tr><th>A\n<tbody><tr><td>1\n</table>",
    // Options, option groups and ruby text.
    "<select name=\"s\">\n<option>A\n<option>B\n<optgroup label=\"G\">\n<option>C\n</select>",
    "<p><ruby>\u{6f22}<rp>(<rt>kan<rp>)</ruby></p>",
]

@Test(arguments: optionalEndTagBodies)
func validDocumentsUsingOptionalEndTagsHaveNoErrors(_ body: String) {
    #expect([] == errorMessages(checkHTML(validDocument(body: body))))
}

private let textContentDocuments: [String] = [
    // The removed heuristic reported an end-of-file error for any document
    // containing both "</style>" and "<script".
    validDocument(head: "<style>\np { color: red; }\n</style>\n", body: "<p>x</p>\n<script src=\"a.js\"></script>"),
    validDocument(head: "<style>ul > li { margin: 0 }</style>\n", body: "<p>x</p>"),
    validDocument(body: "<script>\nfor (var i = 0; i<3; i++) {}\n</script>"),
    validDocument(body: "<div id=\"d\"></div>\n<script>\ndocument.getElementById(\"d\").innerHTML = \"<li>one</li>\";\n</script>"),
    // Inside "<!--", "<script>...</script>" doesn't end the script ("double escaped").
    validDocument(body: "<script>\n<!--\ndocument.write(\"<script src=\\\"a.js\\\"></script>\");\n//-->\n</script>"),
    validDocument(body: "<form action=\"x\"><textarea name=\"t\"><b>not bold</b></textarea></form>"),
    "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>a <b> c</title>\n</head>\n<body>\n<p>x</p>\n</body>\n</html>\n",
]

@Test(arguments: textContentDocuments)
func textOnlyElementContentsAreNotParsedAsMarkup(_ document: String) {
    #expect([] == errorMessages(checkHTML(document)))
}

/// The shape of the customer's page: a multi-level drop-down navigation menu
/// built from nested lists with optional </li> tags, plus an (empty) style
/// element and trailing scripts. It got 70 errors; the W3C's checker gives none.
@Test func case554591NavigationMenuHasNoErrors() {
    let document = validDocument(
        head: "<link href=\"/css/menus.css\" rel=\"stylesheet\">\n<style>\n</style>\n",
        body: """
        <nav>
        <ul>
            <li><a href="a/">Section A</a>
                <ul>
                <li><a href="a/1/">A1</a></li>
                <li><a href="a/2/">A2</a></li>
                </ul>
            <li><a href="b/">Section B</a>
                <ul>
                <li><a href="b/1/">B1</a>
                    <ul>
                    <li><a href="b/1/x/">B1x</a></li>
                    <li><a href="b/1/y/">B1y</a></li>
                    </ul>
                </li>
                <li><a href="b/2/">B2</a></li>
                </ul>
            </li>
            <li><a href="c/">Section C</a>
                <ul>
                <li><a href="c/1/">C1</a>
                    <ul>
                    <li><a href="c/1/x/">C1x</a></li>
                    </ul>
                <li><a href="c/2/">C2</a>
                    <ul>
                    <li><a href="c/2/x/">C2x</a></li>
                    </ul>
                </li>
                </ul>
            <li><a href="d/">Section D</a></li>
        </ul>
        </nav>
        <script src="js/menu.js"></script>
        <script src="js/date.js"></script>
        """
    )
    #expect([] == errorMessages(checkHTML(document)))
}

/// Invalid documents still get the parse errors upstream's TreeBuilder reports
/// when an implied end tag finds non-optional elements still open, or a
/// text-only element runs to the end of the file. (Review item A2: each is
/// followed by upstream's list of the elements left open, "Unclosed element",
/// as vnu.jar reports them.)
@Test(arguments: [
    ("<ul><li><div>x<li>y</ul>", ["End tag \u{201c}li\u{201d} implied, but there were open elements.", "Unclosed element \u{201c}div\u{201d}."]),
    ("<dl><dt><span>a<dd>b</dl>", ["End tag \u{201c}dd\u{201d} implied, but there were open elements.", "Unclosed element \u{201c}span\u{201d}."]),
    // The <p> and <span> are both closed, so the <div> lands in the body and
    // there's no "not allowed as child of span" error (as upstream).
    ("<p><span>x<div>y</div>", ["End tag \u{201c}p\u{201d} implied, but there were open elements.", "Unclosed element \u{201c}span\u{201d}."]),
    ("<table><tr><td><div>x<td>y</table>", ["A table cell was implicitly closed, but there were open elements.", "Unclosed element \u{201c}div\u{201d}."]),
    // (vnu.jar also reports that the <rt> isn't allowed in the <span>, and
    // that the <ruby> then has no <rt>, which the port doesn't yet.)
    ("<p><ruby>a<span>b<rt>c</ruby></p>", [
        "Unclosed children in \u{201c}ruby\u{201d}.",
        "End tag \u{201c}ruby\u{201d} seen, but there were open elements.",
        "Unclosed element \u{201c}span\u{201d}.",
    ]),
    ("<div><span>x</div>", ["End tag \u{201c}div\u{201d} seen, but there were open elements.", "Unclosed element \u{201c}span\u{201d}."]),
])
func impliedEndTagsWithOpenElementsAreStillErrors(_ body: String, _ expected: [String]) {
    #expect(expected == errorMessages(checkHTML(validDocument(body: body))))
}

@Test(arguments: [
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<script>var a = 1;\n", "script"),
    // The "</script>" inside the escaped section doesn't close the element.
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<script><!-- <script> </script> -->\n", "script"),
    ("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<title>T\n", "title"),
])
func textOnlyElementRunningToEndOfFileIsAnError(_ document: String, _ element: String) {
    #expect(["End of file seen when expecting text or an end tag.", "Unclosed element \u{201c}\(element)\u{201d}."] == errorMessages(checkHTML(document)))
}

// Found by adversarially reviewing the first version of the case 554591 fix:
// more valid structures in the same areas, and the parse errors upstream
// reports for their invalid neighbors.

private let validTableAndSelectBodies: [String] = [
    // A table nested in a cell is fine; only a <table> directly inside a
    // table, row group or row is "seen but the previous table is still open".
    "<table><tr><td><table><tr><td>N</td></tr></table></td></tr></table>",
    // <select> is a scope boundary, so the <hr> doesn't close the paragraph.
    "<p><select name=\"s\"><option>A<hr><option>B</select></p>",
    // <script> is allowed directly in a table, and its contents are text.
    "<table><script>var a = 1 < 2;</script><tr><td>1</td></tr></table>",
]

@Test(arguments: validTableAndSelectBodies)
func validTableAndSelectStructuresHaveNoErrors(_ body: String) {
    #expect([] == errorMessages(checkHTML(validDocument(body: body))))
}

/// </head> and </body> are optional too: the first element that doesn't
/// belong in <head> closes it, and </html> closes an open <body>.
@Test func omittedHeadAndBodyEndTagsAreNotErrors() {
    let document = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n<body>\n<p>x</p>\n</html>\n"
    #expect([] == errorMessages(checkHTML(document)))
}

/// "&" in script and style contents, comments and CDATA sections is just a
/// character; the HTML tokenizer never parses character references there.
@Test(arguments: [
    validDocument(body: "<script>function esc(c) { return \"&#\" + c.charCodeAt(0) + \";\"; }</script>\n<p>x</p>"),
    validDocument(head: "<style>/* &copy 2026 &amp */ p { color: red }</style>\n", body: "<p>x</p>"),
    validDocument(body: "<!-- a &amp b &# c -->\n<p>x</p>"),
])
func ampersandsInTextOnlyContentsAreNotCharacterReferences(_ document: String) {
    #expect([] == errorMessages(checkHTML(document)))
}

/// In inline SVG, <script>, <style> and <title> are foreign elements: their
/// contents are markup, as upstream parses them, not raw text.
@Test func svgScriptContentsAreParsedAsMarkup() {
    let errors = errorMessages(checkHTML(validDocument(body: "<svg><script>if (a < b) {}</script></svg>")))
    #expect("Bad character \u{201c} \u{201d} after \u{201c}<\u{201d}. Probable cause: Unescaped \u{201c}<\u{201d}. Try escaping it as \u{201c}&lt;\u{201d}." == errors.first)
}

@Test func unclosedSVGTitleDoesNotSwallowTheRestOfTheDocument() {
    // The <img> after the SVG must still be checked.
    let errors = errorMessages(checkHTML(validDocument(body: "<svg><title>Icon</svg><p><img src=\"x.png\"></p>")))
    #expect(errors.contains { $0.hasPrefix("An \u{201c}img\u{201d} element must have an \u{201c}alt\u{201d} attribute") })
    #expect(!errors.contains("End of file seen when expecting text or an end tag."))
}

@Test func svgCDATASectionIsNotABogusComment() {
    let errors = errorMessages(checkHTML(validDocument(body: "<svg><style><![CDATA[ .a { fill: red } ]]></style></svg>")))
    #expect(!errors.contains("Bogus comment."))
}

@Test(arguments: [
    ("<table><caption><span>C<tr><td>1</table>", ["Unclosed elements on stack."]),
    ("<table><tr><div>x</div><td>1</table>", ["Start tag \u{201c}div\u{201d} seen in \u{201c}table\u{201d}."]),
    // Reported once (it used to be reported twice).
    ("<table><input name=\"a\"><tr><td>1</td></tr></table>", ["Start tag \u{201c}input\u{201d} seen in \u{201c}table\u{201d}."]),
    ("<table><td>1</td></table>", ["\u{201c}td\u{201d} start tag in table body."]),
    ("<p><rt>x</rt></p>", ["Start tag \u{201c}rt\u{201d} seen without a \u{201c}ruby\u{201d} element being open."]),
    // <dialog> is special, so the inner <li> doesn't close the outer one.
    ("<ul><li><dialog open><li>x</dialog></ul>", ["Element \u{201c}li\u{201d} not allowed as child of \u{201c}dialog\u{201d} in this context."]),
])
func tableRubyAndListParseErrorsMatchUpstream(_ body: String, _ expected: [String]) {
    #expect(expected == errorMessages(checkHTML(validDocument(body: body))))
}

/// "Any other end tag" (here </video>) is blocked by an open <p>, and
/// formatting end tags (</b>) go through the adoption agency; neither closes
/// the paragraph quietly the way </div> does.
@Test(arguments: [
    "<video src=\"a.mp4\"><p>Fallback</video>",
    "<b><p>text</b>",
])
func endTagsThatDoNotImplyEndTagsStillReportOpenElements(_ body: String) {
    #expect(errorMessages(checkHTML(validDocument(body: body))).contains { $0.hasPrefix("End tag \u{201c}") })
}

/// In quirks mode (no doctype), <table> doesn't close an open <p>.
@Test func quirksModeTableDoesNotCloseParagraph() {
    let errors = errorMessages(checkHTML("<p>Intro<table><tr><td>1</td></tr></table>\n"))
    #expect(errors.contains("Element \u{201c}table\u{201d} not allowed as child of \u{201c}p\u{201d} in this context."))
}

// "No space between attributes." is only an error when a quoted value's
// closing quote runs straight into the next attribute. It used to be reported
// after every valueless (boolean) attribute that wasn't last on its tag,
// including the standard Google tag snippet `<script async src=...>`. Each of
// these documents gives no errors in vnu.jar.
private let valuelessAttributeDocuments: [String] = [
    validDocument(head: "<script async src=\"a.js\"></script>\n", body: "<p>x</p>"),
    validDocument(body: "<form action=\"x\"><input required name=\"q\"></form>"),
    validDocument(body: "<video controls muted src=\"v.mp4\"></video>"),
    // The whitespace after the valueless attribute is a newline or a tab.
    validDocument(body: "<form action=\"x\"><input disabled\nname=\"q\"></form>"),
    validDocument(body: "<form action=\"x\"><input required\tname='q'></form>"),
    validDocument(body: "<details open class=\"d\"><summary>S</summary>x</details>"),
    // Followed by an unquoted value, mixed with quoted values, and unquoted
    // values followed by another attribute.
    validDocument(body: "<form action=\"x\"><button disabled type=submit>Go</button></form>"),
    validDocument(body: "<form action=\"x\"><input disabled name=\"a\" readonly value=\"b\"></form>"),
    validDocument(body: "<div id=a class=b>x</div>"),
]

@Test(arguments: valuelessAttributeDocuments)
func valuelessAttributesFollowedByAnotherAttributeAreNotErrors(_ document: String) {
    #expect([] == errorMessages(checkHTML(document)))
}

// The missing-space error is still reported where upstream reports it. A
// slash that isn't immediately followed by ">" gets upstream's slash error,
// which the port used to omit or replace with bogus missing-space errors.
// The expectations are vnu.jar's error lists.
@Test(arguments: [
    ("<div id=\"a\"class=\"b\">x</div>", ["No space between attributes."]),
    ("<div id='a'class='b'>x</div>", ["No space between attributes."]),
    ("<div id=\"a\"/class=\"b\">x</div>", ["A slash was not immediately followed by \u{201c}>\u{201d}."]),
    ("<form action=\"x\"><input disabled/required></form>", ["A slash was not immediately followed by \u{201c}>\u{201d}."]),
    ("<p>a<br //>b</p>", ["A slash was not immediately followed by \u{201c}>\u{201d}."]),
])
func missingSpaceAndStraySlashErrorsMatchUpstream(_ body: String, _ expected: [String]) {
    #expect(expected == errorMessages(checkHTML(validDocument(body: body))))
}

/// "<br / >" isn't self-closing upstream: the slash error is reported, but
/// not the trailing-slash message, which only applies to a real "/>".
@Test func slashFollowedBySpaceIsNotSelfClosing() {
    let result = checkHTML(validDocument(body: "<p>a<br / >b</p>"))
    #expect(["A slash was not immediately followed by \u{201c}>\u{201d}."] == errorMessages(result))
    #expect(!result.messages.contains { $0.message.hasPrefix("Trailing slash on void elements") })
}

// Review item A9: table end tags with no table open used to trap in
// HTMLTableModelChecker (an empty table stack), crashing the XPC service,
// which hung BBEdit (A10). Template contents are the common valid case
// (MDN's product-row example); vnu.jar reports no errors for any of these.
private let tableMarkupWithoutATableDocuments: [String] = [
    validDocument(body: "<template><tr><td>x</td></tr></template>"),
    validDocument(body: "<template><thead><tr><th>h</th></tr></thead></template>"),
    validDocument(body: "<template><tbody><tr><td>x</td></tr></tbody></template>"),
    validDocument(body: "<template><tfoot><tr><td>x</td></tr></tfoot></template>"),
    validDocument(body: "<table><tr><td><template><tbody><tr><td>x</td></tr></tbody></template></td></tr></table>"),
    validDocument(body: "<table id=\"producttable\"><thead><tr><td>UPC_Code</td><td>Product_Name</td></tr></thead><tbody></tbody></table>\n<template id=\"productrow\"><tr><td class=\"record\"></td><td></td></tr></template>"),
]

@Test(arguments: tableMarkupWithoutATableDocuments)
func tableMarkupInsideTemplateDoesNotCrashAndIsValid(_ document: String) {
    #expect([] == errorMessages(checkHTML(document)))
}

/// Stray table end tags outside any table: a parity check that these report
/// exactly what vnu.jar does. (Unmatched end tags are dropped by the tree
/// builder before they reach the table checker, so these never took the
/// crashing path; the template documents above do.)
@Test(arguments: [
    ("<p>a</p></tfoot><p>b</p>", ["Stray end tag \u{201c}tfoot\u{201d}."]),
    ("<table><tr><td>x</td></tr></table></tr></tbody>", ["Stray end tag \u{201c}tr\u{201d}.", "Stray end tag \u{201c}tbody\u{201d}."]),
])
func strayTableEndTagsOutsideATableDoNotCrash(_ body: String, _ expected: [String]) {
    #expect(expected == errorMessages(checkHTML(validDocument(body: body))))
}

// A numeric character reference of 2^32 or more overflowed a UInt32 in
// HTMLAttributeChecker and trapped (crashing the XPC service), and the
// tokenizer reported nothing for it. vnu.jar reports exactly this one error
// for each, in text and in attribute values.
@Test(arguments: [
    "<p>a &#4294967296; b</p>",
    "<p>a &#x100000000; b</p>",
    "<p>a &#99999999999999999999; b</p>",
    "<p title=\"a &#4294967296; b\">x</p>",
    "<p title=\"a &#x100000000; b\">x</p>",
])
func hugeNumericCharacterReferencesAreOutOfRangeNotACrash(_ body: String) {
    #expect(["Character reference outside the permissible Unicode range."] == errorMessages(checkHTML(validDocument(body: body))))
}

// Bogus comments, processing instructions and attribute names never contain
// character references upstream, so a reference there gets no diagnostic
// (it used to get e.g. "Character reference expands to zero."). The
// expectations are vnu.jar's error lists.
@Test(arguments: [
    ("<p>a</p><!x &#0;><p>b</p>", ["Bogus comment."]),
    ("<p>a</p><!x &#4294967296;><p>b</p>", ["Bogus comment."]),
    ("<p>a</p><?x &#128;><p>b</p>", ["Saw \u{201c}<?\u{201d}. Probable cause: Attempt to use an XML processing instruction in HTML. (XML processing instructions are not supported in HTML.)"]),
    ("<p data-a&#0;b=\"x\">y</p>", []),
])
func characterReferencesAreNotParsedWhereUpstreamDoesNot(_ body: String, _ expected: [String]) {
    #expect(expected == errorMessages(checkHTML(validDocument(body: body))))
}

// Review item A11: comparing "<!DOCTYPE" case-insensitively no longer
// lowercases the rest of the document, but must still match any case.
@Test(arguments: ["<!doctype html>", "<!DocType html>", "<!DOCTYPE html>"])
func doctypeIsMatchedCaseInsensitively(_ doctype: String) {
    let document = "\(doctype)\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>T</title>\n</head>\n<body>\n<p>x</p>\n</body>\n</html>\n"
    #expect([] == errorMessages(checkHTML(document)))
}

/// Review item A11: tokenizing was quadratic, and about 100 times slower
/// again once the document held any non-ASCII character. This roughly
/// 450 KB page took over 3 minutes; it now takes under half a second in a
/// release build and about 1.5 s in a debug test build, so the 10 s bound
/// leaves a wide margin for a loaded machine. The time limit makes a
/// regression fail after a minute rather than hold up the run.
@Test(.timeLimit(.minutes(1)))
func largeNonASCIIDocumentIsCheckedInLinearTime() {
    let paragraph = "<p>Les élèves ont étudié <b>le café</b> et <i>la crème brûlée</i>.</p>\n"
    let document = validDocument(body: String(repeating: paragraph, count: 6_000))
    let clock = ContinuousClock()
    var errors: [String] = []
    let elapsed = clock.measure {
        errors = errorMessages(checkHTML(document))
    }
    #expect([] == errors)
    #expect(elapsed < .seconds(10))
}

private func checkHTML(_ source: String) -> ValidationResult {
    NuValidator().check(
        input: DocumentInput(data: Data(source.utf8), contentType: "text/html; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
}

private struct MultipartPart {
    var name: String
    var filename: String? = nil
    var contentType: String? = nil
    var content: Data
}

private func multipartBody(boundary: String, parts: [MultipartPart]) -> Data {
    var body = Data()
    for part in parts {
        body.append(Data("--\(boundary)\r\n".utf8))
        var disposition = #"Content-Disposition: form-data; name="\#(part.name)""#
        if let filename = part.filename {
            disposition += #"; filename="\#(filename)""#
        }
        body.append(Data("\(disposition)\r\n".utf8))
        if let contentType = part.contentType {
            body.append(Data("Content-Type: \(contentType)\r\n".utf8))
        }
        body.append(Data("\r\n".utf8))
        body.append(part.content)
        body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)--\r\n".utf8))
    return body
}

private final class OneShotHTTPFixture: @unchecked Sendable {
    let port: UInt16

    private let fd: Int32
    private let response: Data
    private let closeLock = NSLock()
    private var closed = false

    init(statusCode: Int, reason: String, body: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        self.fd = fd

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        guard listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        self.port = UInt16(bigEndian: boundAddress.sin_port)

        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(bodyData)
        self.response = response
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var clientAddress = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = accept(fd, &clientAddress, &length)
            if clientFD >= 0 {
                var buffer = [UInt8](repeating: 0, count: 1024)
                _ = recv(clientFD, &buffer, buffer.count, 0)
                response.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var sent = 0
                    while sent < response.count {
                        let count = Darwin.send(clientFD, base.advanced(by: sent), response.count - sent, 0)
                        if count <= 0 { break }
                        sent += count
                    }
                }
                Darwin.close(clientFD)
            }
            closeServer()
        }
    }

    func stop() {
        closeServer()
    }

    private func closeServer() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

private extension QueryParser {
    static func percentEncodeForTests(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
