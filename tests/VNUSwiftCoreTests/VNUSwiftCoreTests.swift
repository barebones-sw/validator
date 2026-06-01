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

@Test func xmlValidatorCoversXHTMLLinkHrefRequirement() {
    let result = NuValidator().check(
        input: DocumentInput(data: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>T</title><link rel=\"stylesheet\"/></head><body/></html>".utf8), contentType: "application/xhtml+xml; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
    #expect(result.messages.contains { $0.message == "A \u{201c}link\u{201d} element must have an \u{201c}href\u{201d} or \u{201c}imagesrcset\u{201d} attribute, or both." })
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

private func checkHTML(_ source: String) -> ValidationResult {
    NuValidator().check(
        input: DocumentInput(data: Data(source.utf8), contentType: "text/html; charset=utf-8"),
        options: CheckerOptions(parameters: ["out": ["json"]])
    )
}
