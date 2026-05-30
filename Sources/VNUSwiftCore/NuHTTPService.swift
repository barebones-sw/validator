import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class NuHTTPService: Sendable {
    private let validator = NuValidator()

    public init() {}

    public func response(for request: HTTPRequest) -> HTTPResponse {
        if request.method != "OPTIONS", request.header("user-agent") == nil {
            return plainStatus(400, reason: "Bad Request", message: "Bad request. Valid requests must include a User-Agent header.")
        }

        let path = request.path
        if request.method == "OPTIONS" {
            return optionsResponse()
        }
        if request.method == "TRACE" {
            return plainStatus(405, reason: "Method Not Allowed", message: "TRACE is not allowed.")
        }
        if request.method == "GET" {
            if let staticResponse = staticAsset(path: path) {
                return staticResponse
            }
            if request.query.isEmpty, path == "/" || path == "/html5/" {
                return withCommonHeaders(HTTPResponse(headers: ["Content-Type": OutputRenderer.formPage().contentType], body: OutputRenderer.formPage().body))
            }
        }
        guard path == "/" || path == "/html5/" else {
            return plainStatus(404, reason: "Not Found", message: "Not found.")
        }

        var parameters = QueryParser.parse(request.query)
        var documentData: Data?
        var documentContentType = request.header("content-type") ?? "text/html; charset=utf-8"
        var documentURL: String?

        if request.method == "GET" {
            if let doc = parameters.firstValue("doc") {
                documentURL = doc
                let fetched = fetchDocument(urlString: doc, request: request)
                documentData = fetched.data
                documentContentType = fetched.contentType ?? documentContentType
            }
        } else if request.method == "POST" {
            let contentType = request.header("content-type") ?? "text/html; charset=utf-8"
            if contentType.lowercased().hasPrefix("multipart/form-data") {
                let multipart = MultipartParser.parse(data: request.body, contentType: contentType)
                for (name, values) in multipart.parameters {
                    parameters[name, default: []].append(contentsOf: values)
                }
                if let doc = parameters.firstValue("doc"), !doc.isEmpty {
                    documentURL = doc
                    let fetched = fetchDocument(urlString: doc, request: request)
                    documentData = fetched.data
                    documentContentType = fetched.contentType ?? documentContentType
                } else {
                    documentData = multipart.documentData
                    documentContentType = multipart.documentContentType ?? synthesizedContentType(parameters: parameters)
                }
            } else if contentType.lowercased().hasPrefix("application/x-www-form-urlencoded") {
                let result = ValidationResult(messages: [.nonDocumentError("application/x-www-form-urlencoded input is not supported.", subType: "io")])
                return response(for: result, options: CheckerOptions(parameters: parameters))
            } else {
                documentData = request.body
                documentContentType = contentType
            }
        } else {
            return plainStatus(405, reason: "Method Not Allowed", message: "Method not allowed.")
        }

        guard let documentData else {
            let result = ValidationResult(messages: [.nonDocumentError("No document was provided.", subType: "io")])
            return response(for: result, options: CheckerOptions(parameters: parameters))
        }

        let options = CheckerOptions(parameters: parameters)
        let input = DocumentInput(data: documentData, contentType: documentContentType, url: documentURL)
        let result = validator.check(input: input, options: options)
        return response(for: result, options: options)
    }

    private func response(for result: ValidationResult, options: CheckerOptions) -> HTTPResponse {
        let rendered = OutputRenderer.render(result: result, format: options.outputFormat, callback: options.callback, asciiQuotes: options.asciiQuotes)
        return withCommonHeaders(HTTPResponse(headers: ["Content-Type": rendered.contentType], body: rendered.body))
    }

    private func staticAsset(path: String) -> HTTPResponse? {
        switch path {
        case "/style.css":
            return withCommonHeaders(HTTPResponse(headers: ["Content-Type": "text/css; charset=utf-8"], body: Data(UIAssets.css.utf8)))
        case "/script.js":
            return withCommonHeaders(HTTPResponse(headers: ["Content-Type": "text/javascript; charset=utf-8"], body: Data(UIAssets.javascript.utf8)))
        case "/robots.txt":
            return withCommonHeaders(HTTPResponse(headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("User-agent: *\nDisallow: /?\n".utf8)))
        case "/about.html":
            return withCommonHeaders(HTTPResponse(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data("<!DOCTYPE html><html lang=\"en\"><title>About</title><p>Swift Nu Validator</p></html>".utf8)))
        default:
            return nil
        }
    }

    private func fetchDocument(urlString: String, request: HTTPRequest) -> (data: Data?, contentType: String?) {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
            return (Data(), "text/html; charset=utf-8")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        urlRequest.setValue(request.header("user-agent") ?? "Swift Nu Validator", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var data: Data?
            var contentType: String?
        }
        let box = Box()
        URLSession.shared.dataTask(with: urlRequest) { data, response, _ in
            box.data = data
            box.contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return (box.data, box.contentType)
    }

    private func synthesizedContentType(parameters: [String: [String]]) -> String {
        if parameters.firstValue("css")?.lowercased() == "yes" {
            return "text/css; charset=utf-8"
        }
        if parameters.firstValue("parser")?.lowercased() == "xml" {
            return "application/xml; charset=utf-8"
        }
        return "text/html; charset=utf-8"
    }

    private func optionsResponse() -> HTTPResponse {
        withCommonHeaders(HTTPResponse(headers: [
            "Content-Type": "application/octet-stream",
            "Allow": "GET, HEAD, POST, OPTIONS",
            "Access-Control-Allow-Methods": "GET, HEAD, POST, OPTIONS",
            "Access-Control-Max-Age": "43200"
        ]))
    }

    private func plainStatus(_ status: Int, reason: String, message: String) -> HTTPResponse {
        withCommonHeaders(HTTPResponse(statusCode: status, reasonPhrase: reason, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(message.utf8)))
    }

    private func withCommonHeaders(_ response: HTTPResponse) -> HTTPResponse {
        var copy = response
        copy.headers["Cache-Control"] = "no-cache"
        copy.headers["Access-Control-Allow-Origin"] = "*"
        copy.headers["Access-Control-Allow-Headers"] = "content-type"
        copy.headers["Server"] = "Swift Nu Validator"
        return copy
    }
}

