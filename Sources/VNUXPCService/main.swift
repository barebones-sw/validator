import Foundation
import VNUCore
import VNUSwiftCore

final class ValidatorXPCService: NSObject, ValidatorXPCChecking {
    private let validator = NuValidator()

    func checkSource(
        _ source: NSString,
        filename: NSString?,
        contentType: NSString?,
        options: NSDictionary,
        withReply reply: @escaping (NSString?, NSError?) -> Void
    ) {
        let parameters = checkerParameters(from: options)
        let input = DocumentInput(
            data: Data((source as String).utf8),
            contentType: (contentType as String?)?.nonEmpty ?? "text/html; charset=utf-8",
            url: filename as String?
        )
        let result = validator.check(input: input, options: CheckerOptions(parameters: parameters))
        guard let json = String(data: ValidationJSON.encode(result), encoding: .utf8) else {
            let error = NSError(
                domain: ValidatorXPC.errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to encode validator JSON."]
            )
            reply(nil, error)
            return
        }
        reply(json as NSString, nil)
    }

    private func checkerParameters(from options: NSDictionary) -> [String: [String]] {
        var parameters: [String: [String]] = [:]
        for (rawKey, rawValue) in options {
            guard let key = rawKey as? String else { continue }
            append(value: rawValue, for: normalizedParameterName(key), to: &parameters)
        }
        return parameters
    }

    private func append(value: Any, for key: String, to parameters: inout [String: [String]]) {
        switch value {
        case let string as String:
            parameters.appendParameter(name: key, value: string)
        case let number as NSNumber:
            parameters.appendParameter(name: key, value: number.boolValue ? "yes" : "no")
        case let array as [Any]:
            for item in array {
                append(value: item, for: key, to: &parameters)
            }
        default:
            parameters.appendParameter(name: key, value: "\(value)")
        }
    }

    private func normalizedParameterName(_ key: String) -> String {
        switch key.lowercased().replacingOccurrences(of: "_", with: "") {
        case "showsource":
            return "showsource"
        case "asciiquotes":
            return "asciiquotes"
        default:
            return key.lowercased()
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = ValidatorXPC.interface()
        newConnection.exportedObject = ValidatorXPCService()
        newConnection.resume()
        return true
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Dictionary where Key == String, Value == [String] {
    mutating func appendParameter(name: String, value: String) {
        self[name.lowercased(), default: []].append(value)
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
