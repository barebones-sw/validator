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

