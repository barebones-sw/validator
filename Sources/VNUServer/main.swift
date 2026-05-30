import Foundation
import VNUSwiftCore

func parseArguments(_ arguments: [String]) -> (host: String, port: UInt16) {
    var host = ProcessInfo.processInfo.environment["BIND_ADDRESS"] ?? "127.0.0.1"
    var port: UInt16 = 8888
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--bind-address", index + 1 < arguments.count {
            host = arguments[index + 1]
            index += 2
        } else if argument == "--port", index + 1 < arguments.count {
            port = UInt16(arguments[index + 1]) ?? port
            index += 2
        } else if let parsed = UInt16(argument) {
            port = parsed
            index += 1
        } else {
            index += 1
        }
    }
    return (host, port)
}

let config = parseArguments(CommandLine.arguments)
let server = HTTPServer(host: config.host, port: config.port)
do {
    try server.start()
} catch {
    fputs("vnu-swift: \(error)\n", stderr)
    exit(1)
}

