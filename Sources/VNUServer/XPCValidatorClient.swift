import Foundation
import VNUCore

final class XPCValidatorClient: ValidatorChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    func check(input: DocumentInput, options: CheckerOptions) -> ValidationResult {
        let source = DocumentDecoder.decode(input)
        let remoteOptions = options.xpcDictionary
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReplyBox()

        guard let proxy = remoteProxy(errorHandler: { error in
            box.error = error
            semaphore.signal()
        }) else {
            return .xpcError("Unable to connect to the Nu Validator XPC service.")
        }

        proxy.checkSource(
            source as NSString,
            filename: input.url as NSString?,
            contentType: input.contentType as NSString,
            options: remoteOptions
        ) { json, error in
            box.json = json as String?
            box.error = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + .seconds(30)) == .success else {
            invalidateConnection()
            return .xpcError("Nu Validator XPC service timed out.")
        }
        if let error = box.error {
            invalidateConnection()
            return .xpcError(error.localizedDescription)
        }
        guard let json = box.json,
              let data = json.data(using: .utf8) else {
            return .xpcError("Nu Validator XPC service returned an empty response.")
        }
        do {
            return try JSONDecoder().decode(ValidationResult.self, from: data)
        } catch {
            return .xpcError("Nu Validator XPC service returned invalid JSON: \(error.localizedDescription)")
        }
    }

    private func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> ValidatorXPCChecking? {
        let connection = activeConnection()
        return connection.remoteObjectProxyWithErrorHandler(errorHandler) as? ValidatorXPCChecking
    }

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        if let connection {
            lock.unlock()
            return connection
        }
        let connection = NSXPCConnection(serviceName: ValidatorXPC.serviceIdentifier)
        connection.remoteObjectInterface = ValidatorXPC.interface()
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.clearConnection(connection)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.clearConnection(connection)
        }
        connection.resume()
        self.connection = connection
        lock.unlock()
        return connection
    }

    private func invalidateConnection() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.invalidate()
    }

    private func clearConnection(_ connection: NSXPCConnection?) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
        }
        lock.unlock()
    }
}

private final class ReplyBox: @unchecked Sendable {
    var json: String?
    var error: Error?
}

private extension CheckerOptions {
    var xpcDictionary: NSDictionary {
        let dictionary = NSMutableDictionary()
        if showSource {
            dictionary["showsource"] = "yes"
        }
        if asciiQuotes {
            dictionary["asciiquotes"] = "yes"
        }
        if let parser {
            dictionary["parser"] = parser
        }
        switch reportLevel {
        case .all:
            break
        case .warning:
            dictionary["level"] = "warning"
        case .error:
            dictionary["level"] = "error"
        }
        return dictionary
    }
}

private extension ValidationResult {
    static func xpcError(_ message: String) -> ValidationResult {
        ValidationResult(messages: [.nonDocumentError(message, subType: "io")])
    }
}
