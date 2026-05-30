import Foundation
import VNUParityCore

struct CommandLineOptions {
    var messagesPath = "tests/messages.json"
    var fixturesRoot = "tests"
    var baselinePath: String? = "resources/NuValidator/parity-baseline.json"
    var filter: String?
    var limit: Int?
    var updateBaseline = false
    var failOnRegression = true
    var strict = false
    var showHelp = false
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidLimit(String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .invalidLimit(let value):
            return "Invalid --limit value \(value)."
        case .unknownOption(let option):
            return "Unknown option \(option)."
        }
    }
}

func parseArguments(_ arguments: [String]) throws -> CommandLineOptions {
    var options = CommandLineOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--messages":
            options.messagesPath = try value(after: argument, in: arguments, at: &index)
        case "--fixtures":
            options.fixturesRoot = try value(after: argument, in: arguments, at: &index)
        case "--baseline":
            options.baselinePath = try value(after: argument, in: arguments, at: &index)
        case "--no-baseline":
            options.baselinePath = nil
        case "--filter":
            options.filter = try value(after: argument, in: arguments, at: &index)
        case "--limit":
            let rawValue = try value(after: argument, in: arguments, at: &index)
            guard let limit = Int(rawValue), limit >= 0 else {
                throw CLIError.invalidLimit(rawValue)
            }
            options.limit = limit
        case "--update-baseline":
            options.updateBaseline = true
        case "--allow-regression":
            options.failOnRegression = false
        case "--strict":
            options.strict = true
        case "--help", "-h":
            options.showHelp = true
        default:
            throw CLIError.unknownOption(argument)
        }
        index += 1
    }
    return options
}

func value(after option: String, in arguments: [String], at index: inout Int) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
        throw CLIError.missingValue(option)
    }
    index = valueIndex
    return arguments[valueIndex]
}

func url(for path: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
}

func printHelp() {
    print("""
    Usage: vnu-parity [options]

    Options:
      --messages <path>        NuValidator messages JSON (default: tests/messages.json)
      --fixtures <path>        Fixture root directory (default: tests)
      --baseline <path>        Baseline JSON path (default: resources/NuValidator/parity-baseline.json)
      --no-baseline            Run without baseline comparison
      --filter <text>          Run only paths or messages containing text
      --limit <count>          Run at most count cases after filtering
      --update-baseline        Write the current match set to the baseline path
      --allow-regression       Report regressions but exit successfully
      --strict                 Fail unless every selected expectation matches
      --help                   Show this help
    """)
}

func printReport(_ run: ParityRun, configuration: ParityConfiguration) {
    let summary = run.summary
    print("NuValidator Swift parity")
    print("  cases: \(summary.total)")
    print("  matched: \(summary.matched)")
    print("  unmatched: \(summary.unmatched)")
    print("  missing fixtures: \(summary.missingFixtures)")
    print("  baseline cases: \(summary.baselineCases)")
    print("  regressions: \(summary.regressions)")
    print("  improvements: \(summary.improvements)")
    if run.baselineUpdated {
        print("  baseline: updated")
    }

    let regressions = run.results.filter { $0.previouslyMatched == true && !$0.matched }
    if !regressions.isEmpty {
        print("")
        print("Regressions:")
        for result in regressions.prefix(20) {
            print("  \(result.path)")
            print("    expected: \(result.expectedMessage)")
            if let actual = result.actualMessages.first {
                print("    first actual: \(actual)")
            } else {
                print("    first actual: <none>")
            }
        }
        if regressions.count > 20 {
            print("  ... \(regressions.count - 20) more")
        }
    }

    let missing = run.results.filter(\.missingFixture)
    if !missing.isEmpty {
        print("")
        print("Missing fixtures:")
        for result in missing.prefix(20) {
            print("  \(result.path)")
        }
        if missing.count > 20 {
            print("  ... \(missing.count - 20) more")
        }
    }

    if configuration.strict {
        let unmatched = run.results.filter { !$0.matched && !$0.missingFixture }
        if !unmatched.isEmpty {
            print("")
            print("Unmatched:")
            for result in unmatched.prefix(20) {
                print("  \(result.path)")
                print("    expected: \(result.expectedMessage)")
                if let actual = result.actualMessages.first {
                    print("    first actual: \(actual)")
                } else {
                    print("    first actual: <none>")
                }
            }
            if unmatched.count > 20 {
                print("  ... \(unmatched.count - 20) more")
            }
        }
    }
}

do {
    let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    if options.showHelp {
        printHelp()
        exit(EXIT_SUCCESS)
    }

    let configuration = ParityConfiguration(
        messagesPath: url(for: options.messagesPath),
        fixturesRoot: url(for: options.fixturesRoot),
        baselinePath: options.baselinePath.map(url(for:)),
        filter: options.filter,
        limit: options.limit,
        updateBaseline: options.updateBaseline,
        failOnRegression: options.failOnRegression,
        strict: options.strict
    )
    let harness = ParityHarness()
    let run = try harness.run(configuration: configuration)
    printReport(run, configuration: configuration)
    exit(harness.shouldFail(run, configuration: configuration) ? EXIT_FAILURE : EXIT_SUCCESS)
} catch {
    fputs("vnu-parity: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
