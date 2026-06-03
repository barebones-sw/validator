import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class NuHTTPService: Sendable {
    private let validator: any ValidatorChecking

    public init(validator: any ValidatorChecking = NuValidator()) {
        self.validator = validator
    }

    public func response(for request: HTTPRequest) -> HTTPResponse {
        let isHead = request.method == "HEAD"
        let method = isHead ? "GET" : request.method

        if method != "OPTIONS", request.header("user-agent") == nil {
            return finalize(plainStatus(400, reason: "Bad Request", message: "Bad request. Valid requests must include a User-Agent header."), isHead: isHead)
        }

        let path = request.path
        if method == "OPTIONS" {
            return finalize(optionsResponse(), isHead: isHead)
        }
        if method == "TRACE" {
            return finalize(plainStatus(405, reason: "Method Not Allowed", message: "TRACE is not allowed."), isHead: isHead)
        }
        if method == "GET" {
            if let staticResponse = staticAsset(path: path) {
                return finalize(staticResponse, isHead: isHead)
            }
            if request.query.isEmpty, path == "/" || path == "/html5/" {
                return finalize(withCommonHeaders(HTTPResponse(headers: ["Content-Type": OutputRenderer.formPage().contentType], body: OutputRenderer.formPage().body)), isHead: isHead)
            }
        }
        guard path == "/" || path == "/html5/" else {
            return finalize(plainStatus(404, reason: "Not Found", message: "Not found."), isHead: isHead)
        }

        var parameters = QueryParser.parse(request.query)
        var documentData: Data?
        var documentContentType = request.header("content-type") ?? "text/html; charset=utf-8"
        var documentURL: String?

        if method == "GET" {
            if let doc = parameters.firstValue("doc") {
                documentURL = doc
                switch fetchDocument(urlString: doc, request: request, parameters: parameters) {
                case let .success(data, contentType):
                    documentData = data
                    documentContentType = contentType ?? documentContentType
                case let .failure(message):
                    return finalize(ioErrorResponse(message, url: doc, parameters: parameters), isHead: isHead)
                }
            }
        } else if method == "POST" {
            let contentType = request.header("content-type") ?? "text/html; charset=utf-8"
            if contentType.lowercased().hasPrefix("multipart/form-data") {
                let multipart = MultipartParser.parse(data: request.body, contentType: contentType)
                for (name, values) in multipart.parameters {
                    parameters[name, default: []].append(contentsOf: values)
                }
                if let doc = parameters.firstValue("doc"), !doc.isEmpty {
                    documentURL = doc
                    switch fetchDocument(urlString: doc, request: request, parameters: parameters) {
                    case let .success(data, contentType):
                        documentData = data
                        documentContentType = contentType ?? documentContentType
                    case let .failure(message):
                        return finalize(ioErrorResponse(message, url: doc, parameters: parameters), isHead: isHead)
                    }
                } else {
                    documentData = multipart.documentData
                    documentContentType = synthesizedContentType(parameters: parameters, multipart: multipart)
                    documentURL = displayFilename(multipart.documentFilename)
                }
            } else if contentType.lowercased().hasPrefix("application/x-www-form-urlencoded") {
                let result = ValidationResult(messages: [.nonDocumentError("application/x-www-form-urlencoded input is not supported.", subType: "io")])
                return finalize(response(for: result, options: CheckerOptions(parameters: parameters)), isHead: isHead)
            } else {
                documentData = request.body
                documentContentType = contentType
            }
        } else {
            return finalize(plainStatus(405, reason: "Method Not Allowed", message: "Method not allowed."), isHead: isHead)
        }

        guard let documentData else {
            let result = ValidationResult(messages: [.nonDocumentError("No document was provided.", subType: "io")])
            return finalize(response(for: result, options: CheckerOptions(parameters: parameters)), isHead: isHead)
        }

        let options = CheckerOptions(parameters: parameters)
        let input = DocumentInput(data: documentData, contentType: documentContentType, url: documentURL)
        let result = validator.check(input: input, options: options)
        return finalize(response(for: result, options: options), isHead: isHead)
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

    private enum FetchResult {
        case success(data: Data, contentType: String?)
        case failure(String)
    }

    private func fetchDocument(urlString: String, request: HTTPRequest, parameters: [String: [String]]) -> FetchResult {
        guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else {
            return .failure("Unsupported URL. The URL must use the HTTP or HTTPS scheme: \(urlString)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 15
        urlRequest.setValue(request.header("user-agent") ?? "Swift Nu Validator", forHTTPHeaderField: "User-Agent")
        if let acceptLanguage = request.header("accept-language") {
            urlRequest.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }
        for value in parameters["additionalrequestheader"] ?? [] {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                urlRequest.setValue(headerValue, forHTTPHeaderField: name)
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var data: Data?
            var contentType: String?
            var statusCode: Int?
            var error: Error?
        }
        let box = Box()
        URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            box.data = data
            if let response = response as? HTTPURLResponse {
                box.statusCode = response.statusCode
                box.contentType = response.value(forHTTPHeaderField: "Content-Type")
            }
            box.error = error
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            return .failure("\(urlString): HTTP request failed: timed out.")
        }
        if let error = box.error {
            return .failure("\(urlString): HTTP request failed: \(error.localizedDescription)")
        }
        if let statusCode = box.statusCode,
           statusCode != 200,
           parameters.firstValue("checkerrorpages")?.lowercased() != "yes" {
            return .failure("HTTP resource not retrievable. The HTTP status from the remote server was: \(statusCode).")
        }
        guard let data = box.data else {
            return .failure("Empty response.")
        }
        return .success(data: data, contentType: box.contentType)
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

    private func synthesizedContentType(parameters: [String: [String]], multipart: MultipartResult) -> String {
        let explicitCharset = parameters.firstValue("charset")
        let parsedPartType = ParsedContentType(multipart.documentContentType)
        let charset = explicitCharset ?? parsedPartType.parameters["charset"] ?? "utf-8"
        let mediaType: String
        if multipart.documentFieldName == "content" {
            mediaType = ParsedContentType(synthesizedContentType(parameters: parameters)).mediaType
        } else if let filename = multipart.documentFilename,
                  let type = mediaTypeForFilename(filename) {
            mediaType = type
        } else {
            mediaType = parsedPartType.mediaType
        }
        return "\(mediaType); charset=\(charset)"
    }

    private func mediaTypeForFilename(_ filename: String) -> String? {
        switch filename.split(separator: ".").last?.lowercased() {
        case "html", "htm":
            return "text/html"
        case "xhtml", "xht":
            return "application/xhtml+xml"
        case "atom":
            return "application/atom+xml"
        case "rng", "xsl", "xml":
            return "application/xml"
        case "dbk":
            return "application/docbook+xml"
        case "css":
            return "text/css"
        default:
            return nil
        }
    }

    private func displayFilename(_ filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        return filename.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? filename
    }

    private func ioErrorResponse(_ message: String, url: String, parameters: [String: [String]]) -> HTTPResponse {
        let result = ValidationResult(url: url, messages: [.nonDocumentError(message, subType: "io")])
        return response(for: result, options: CheckerOptions(parameters: parameters))
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

    private func finalize(_ response: HTTPResponse, isHead: Bool) -> HTTPResponse {
        guard isHead else { return response }
        var copy = response
        copy.body = Data()
        return copy
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
