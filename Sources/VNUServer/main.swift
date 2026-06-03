import Foundation
import VNUCore
import VNUServiceCore
#if canImport(AppKit)
import AppKit
#endif

struct ServerConfiguration: Sendable {
    var host: String
    var port: UInt16
    var logRequests: Bool
    var forceCommandLine: Bool
    var showHelp: Bool
    var hostWasSpecified: Bool
    var portWasSpecified: Bool
    var loggingWasSpecified: Bool

    var baseURL: String {
        "http://\(host):\(port)/"
    }
}

func parseArguments(_ arguments: [String]) -> ServerConfiguration {
    let environment = ProcessInfo.processInfo.environment
    var configuration = ServerConfiguration(
        host: environment["BIND_ADDRESS"] ?? "127.0.0.1",
        port: UInt16(environment["PORT"] ?? "") ?? 8888,
        logRequests: environment["VNU_LOG_REQUESTS"] == "1" || environment["VNU_LOG_REQUESTS"]?.lowercased() == "yes",
        forceCommandLine: false,
        showHelp: false,
        hostWasSpecified: false,
        portWasSpecified: false,
        loggingWasSpecified: environment["VNU_LOG_REQUESTS"] != nil
    )
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--bind-address", index + 1 < arguments.count {
            configuration.host = arguments[index + 1]
            configuration.hostWasSpecified = true
            index += 2
        } else if argument == "--port", index + 1 < arguments.count {
            configuration.port = UInt16(arguments[index + 1]) ?? configuration.port
            configuration.portWasSpecified = true
            index += 2
        } else if argument == "--log-requests" {
            configuration.logRequests = true
            configuration.loggingWasSpecified = true
            index += 1
        } else if argument == "--no-log-requests" {
            configuration.logRequests = false
            configuration.loggingWasSpecified = true
            index += 1
        } else if argument == "--cli" || argument == "--no-ui" {
            configuration.forceCommandLine = true
            index += 1
        } else if argument == "--help" || argument == "-h" {
            configuration.showHelp = true
            index += 1
        } else if let parsed = UInt16(argument) {
            configuration.port = parsed
            configuration.portWasSpecified = true
            index += 1
        } else {
            index += 1
        }
    }
    return configuration
}

func printHelp() {
    print("""
    Usage: vnu-swift [options] [port]

    Options:
      --bind-address <address>  Address to bind. Default: 127.0.0.1
      --port <port>             Port to listen on. Default: 8888
      --log-requests            Log each HTTP request.
      --no-log-requests         Disable request logging.
      --cli, --no-ui            Run server-only mode even inside the app bundle.
      --help                    Show this help.

    Environment:
      BIND_ADDRESS              Default bind address.
      PORT                      Default port.
      VNU_LOG_REQUESTS=1        Enable request logging.
    """)
}

func runCommandLineServer(_ configuration: ServerConfiguration) -> Never {
    let requestLogger: (@Sendable (HTTPRequestLog) -> Void)?
    if configuration.logRequests {
        requestLogger = { log in
            print("\(SelfTimestamp.now()) \(log)")
        }
    } else {
        requestLogger = nil
    }

    let service = NuHTTPService(validator: XPCValidatorClient())
    let server = HTTPServer(host: configuration.host, port: configuration.port, service: service, requestLogger: requestLogger)
    do {
        try server.start()
    } catch {
        fputs("vnu-swift: \(error)\n", stderr)
        exit(1)
    }
}

enum SelfTimestamp {
    static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

#if canImport(AppKit)
@MainActor
final class ValidatorApplicationDelegate: NSObject, NSApplicationDelegate {
    private var configuration: ServerConfiguration
    private let defaults = UserDefaults.standard
    private let logSink: RequestLogSink
    private let validatorClient = XPCValidatorClient()
    private var nibTopLevelObjects: NSArray?

    @IBOutlet var mainMenu: NSMenu!
    @IBOutlet var window: NSWindow!
    @IBOutlet var statusLabel: NSTextField!
    @IBOutlet var urlLabel: NSTextField!
    @IBOutlet var hostField: NSTextField!
    @IBOutlet var portField: NSTextField!
    @IBOutlet var loggingCheckbox: NSButton!
    @IBOutlet var logTextView: NSTextView!

    init(configuration: ServerConfiguration) {
        var appConfiguration = configuration
        defaults.register(defaults: [
            "bindAddress": "127.0.0.1",
            "port": 8888,
            "logRequests": configuration.logRequests
        ])
        if !configuration.hostWasSpecified,
           let savedHost = defaults.string(forKey: "bindAddress"),
           !savedHost.isEmpty {
            appConfiguration.host = savedHost
        }
        if !configuration.portWasSpecified {
            let savedPort = defaults.integer(forKey: "port")
            if savedPort > 0, let port = UInt16(exactly: savedPort) {
                appConfiguration.port = port
            }
        }
        if !configuration.loggingWasSpecified {
            appConfiguration.logRequests = defaults.bool(forKey: "logRequests")
        }
        self.configuration = appConfiguration
        self.logSink = RequestLogSink(enabled: appConfiguration.logRequests)
        super.init()
        self.logSink.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        loadMainNib()
        startServer()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func loadMainNib() {
        var topLevelObjects: NSArray?
        guard Bundle.main.loadNibNamed("MainMenu", owner: self, topLevelObjects: &topLevelObjects) else {
            fatalError("Unable to load MainMenu.nib")
        }
        nibTopLevelObjects = topLevelObjects
        NSApp.mainMenu = mainMenu
        configureNibControls()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureNibControls() {
        statusLabel.stringValue = "Starting checker service..."
        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        urlLabel.stringValue = configuration.baseURL
        urlLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.lineBreakMode = .byTruncatingMiddle

        hostField.stringValue = configuration.host
        portField.stringValue = "\(configuration.port)"
        portField.formatter = PortFormatter()

        loggingCheckbox.target = self
        loggingCheckbox.action = #selector(loggingChanged(_:))
        loggingCheckbox.state = configuration.logRequests ? .on : .off

        logTextView.isEditable = false
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.string = ""
    }

    private func startServer() {
        let configuration = self.configuration
        let logSink = self.logSink
        let validatorClient = self.validatorClient
        DispatchQueue.global(qos: .userInitiated).async {
            let service = NuHTTPService(validator: validatorClient)
            let server = HTTPServer(
                host: configuration.host,
                port: configuration.port,
                service: service,
                requestLogger: { logSink.emit($0) }
            )
            do {
                try server.start()
            } catch {
                Task { @MainActor in
                    self.statusLabel.stringValue = "Checker service failed: \(error)"
                    self.appendSystemLog("Checker service failed: \(error)")
                }
            }
        }
        statusLabel.stringValue = "Checker service running"
        appendSystemLog("Checker service started at \(configuration.baseURL)")
        appendSystemLog("Validation requests are routed through \(ValidatorXPC.serviceIdentifier).")
    }

    @IBAction func showWindow(_ sender: Any?) {
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @IBAction func loggingChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        defaults.set(enabled, forKey: "logRequests")
        logSink.setEnabled(enabled)
        appendSystemLog("Request logging \(enabled ? "enabled" : "disabled").")
    }

    @IBAction func saveSettings(_ sender: Any?) {
        let newHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "127.0.0.1"
        let newPort = UInt16(portField.stringValue) ?? configuration.port
        defaults.set(newHost, forKey: "bindAddress")
        defaults.set(Int(newPort), forKey: "port")
        defaults.set(loggingCheckbox.state == .on, forKey: "logRequests")
        let restartNeeded = newHost != configuration.host || newPort != configuration.port
        appendSystemLog(restartNeeded ? "Settings saved. Restart the app to use \(newHost):\(newPort)." : "Settings saved.")
    }

    @IBAction func openChecker(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: configuration.baseURL)!)
    }

    @IBAction func copyURL(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.baseURL, forType: .string)
        appendSystemLog("Copied \(configuration.baseURL)")
    }

    fileprivate func appendRequestLog(_ log: HTTPRequestLog) {
        appendLogLine("\(SelfTimestamp.now()) \(log)")
    }

    private func appendSystemLog(_ message: String) {
        appendLogLine("\(SelfTimestamp.now()) \(message)")
    }

    private func appendLogLine(_ line: String) {
        let text = logTextView.string
        logTextView.string = text.isEmpty ? line : "\(text)\n\(line)"
        logTextView.scrollRangeToVisible(NSRange(location: logTextView.string.count, length: 0))
    }
}

final class RequestLogSink: @unchecked Sendable {
    weak var delegate: ValidatorApplicationDelegate?

    private let lock = NSLock()
    private var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    func emit(_ log: HTTPRequestLog) {
        lock.lock()
        let shouldEmit = enabled
        lock.unlock()
        guard shouldEmit else { return }
        Task { @MainActor [weak self] in
            self?.delegate?.appendRequestLog(log)
        }
    }
}

final class PortFormatter: NumberFormatter, @unchecked Sendable {
    override init() {
        super.init()
        minimum = 1
        maximum = 65535
        allowsFloats = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        minimum = 1
        maximum = 65535
        allowsFloats = false
    }
}

func shouldRunApplication(_ configuration: ServerConfiguration) -> Bool {
    Bundle.main.bundleURL.pathExtension == "app" && !configuration.forceCommandLine
}

@MainActor
func runApplication(_ configuration: ServerConfiguration) -> Never {
    let app = NSApplication.shared
    let delegate = ValidatorApplicationDelegate(configuration: configuration)
    app.delegate = delegate
    app.run()
    exit(0)
}
#endif

let configuration = parseArguments(CommandLine.arguments)
if configuration.showHelp {
    printHelp()
    exit(0)
}

#if canImport(AppKit)
if shouldRunApplication(configuration) {
    runApplication(configuration)
} else {
    runCommandLineServer(configuration)
}
#else
runCommandLineServer(configuration)
#endif
