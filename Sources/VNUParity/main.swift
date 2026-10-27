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

    // Upstream TestRunner rules mode (review unit U0); see the comment at the
    // top of that section in ParityHarness.swift.
    var upstreamRules = false
    var knownFailuresPath: String? = "resources/NuValidator/upstream-known-failures.json"
    var updateKnownFailures = false
    var initializeKnownFailures = false
    var accepted: [String] = []
    var acceptRemovedFixtures = false
    var ignore: [String] = []
    var replayPath: String?
    var reportPath: String?
    var verbose = false
    /// Options given that belong to only one mode, so they can be rejected
    /// in the other rather than silently ignored.
    var upstreamOnlyOptions: [String] = []
    var messagesModeOnlyOptions: [String] = []
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidLimit(String)
    case unknownOption(String)
    case requiresUpstreamRules([String])
    case notInUpstreamRules(String)
    case conflictingOptions(String, String)
    case acceptWithoutUpdate
    case updateAllowingRegressions
    case knownFailuresDisabled
    case knownFailuresExist(String)
    case knownFailuresMissing(String)
    case missingReportFolder(String)

    var description: String {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .invalidLimit(let value):
            return "Invalid --limit value \(value)."
        case .unknownOption(let option):
            return "Unknown option \(option)."
        case .requiresUpstreamRules(let options):
            return "These options require --upstream-rules: \(options.joined(separator: ", "))."
        case .notInUpstreamRules(let option):
            return "\(option) doesn't apply with --upstream-rules (it belongs to the messages.json mode)."
        case .conflictingOptions(let first, let second):
            return "\(first) and \(second) can't be used together."
        case .acceptWithoutUpdate:
            return "--accept and --accept-removed-fixtures only apply with --update-known-failures."
        case .updateAllowingRegressions:
            return "Refusing to write the known-failure list with --allow-regression."
        case .knownFailuresDisabled:
            return "--no-known-failures can't be combined with --update-known-failures or --initialize-known-failures."
        case .knownFailuresExist(let path):
            return "A known-failure list already exists at \(path); use --update-known-failures (and --accept) instead."
        case .knownFailuresMissing(let path):
            return "No known-failure list at \(path). Create it with --initialize-known-failures, or score without one using --no-known-failures."
        case .missingReportFolder(let path):
            return "The --report folder \(path) doesn't exist."
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
            options.messagesModeOnlyOptions.append(argument)
        case "--no-baseline":
            options.baselinePath = nil
            options.messagesModeOnlyOptions.append(argument)
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
            options.messagesModeOnlyOptions.append(argument)
        case "--allow-regression":
            options.failOnRegression = false
        case "--strict":
            options.strict = true
            options.messagesModeOnlyOptions.append(argument)
        case "--upstream-rules":
            options.upstreamRules = true
        case "--known-failures":
            options.knownFailuresPath = try value(after: argument, in: arguments, at: &index)
            options.upstreamOnlyOptions.append(argument)
        case "--no-known-failures":
            options.knownFailuresPath = nil
            options.upstreamOnlyOptions.append(argument)
        case "--update-known-failures":
            options.updateKnownFailures = true
            options.upstreamOnlyOptions.append(argument)
        case "--initialize-known-failures":
            options.initializeKnownFailures = true
            options.upstreamOnlyOptions.append(argument)
        case "--accept":
            options.accepted.append(try value(after: argument, in: arguments, at: &index))
            options.upstreamOnlyOptions.append(argument)
        case "--accept-removed-fixtures":
            options.acceptRemovedFixtures = true
            options.upstreamOnlyOptions.append(argument)
        case "--ignore":
            options.ignore.append(try value(after: argument, in: arguments, at: &index))
            options.upstreamOnlyOptions.append(argument)
        case "--replay":
            options.replayPath = try value(after: argument, in: arguments, at: &index)
            options.upstreamOnlyOptions.append(argument)
        case "--report":
            options.reportPath = try value(after: argument, in: arguments, at: &index)
            options.upstreamOnlyOptions.append(argument)
        case "--verbose":
            options.verbose = true
            options.upstreamOnlyOptions.append(argument)
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
                               (refused with --filter, --limit or
                               --allow-regression, and skipped if anything
                               regressed)
      --allow-regression       Report regressions but exit successfully
      --strict                 Fail unless every selected expectation matches
      --help                   Show this help

    Upstream TestRunner rules (--upstream-rules):
      Checks every .html/.htm/.xhtml/.xht fixture under --fixtures the way
      upstream's TestRunner does: valid files must have no errors or
      warnings; an invalid file's first error must equal messages.json
      exactly; a haswarn file's first warning must match with no errors; a
      hasinfo file's first info message must match with no errors or
      warnings. Failures are compared with a known-failure list that may only
      shrink.

      --upstream-rules         Use these rules instead of the messages.json mode
      --known-failures <path>  Known-failure list
                               (default: resources/NuValidator/upstream-known-failures.json)
      --no-known-failures      Only score; don't compare with a list
      --update-known-failures  Rewrite the list: drop entries that now pass or
                               no longer exist; refresh reasons and counts
      --accept <path>          With --update-known-failures, allow adding this
                               new failure (repeatable)
      --accept-removed-fixtures
                               With --update-known-failures, allow fixtures to
                               disappear (fixture and pass counts to drop)
      --initialize-known-failures
                               Create the list from this run (only if none exists)
      --ignore <text>          Skip fixtures whose path contains text
                               (repeatable; makes the run partial)
      --replay <path>          Score recorded messages (JSON Lines of
                               {"path", "messages"}) instead of running the port;
                               can't be used to write the list
      --report <path>          Write every fixture's result as JSON
      --verbose                Print each fixture path to stderr before checking it
      --filter and --limit select fixtures by path; with --ignore they make the
      run partial, which can't update the list or check pass counts.
      --allow-regression reports ratchet failures but exits successfully.
    """)
}

/// Every fixture's result plus per-category totals, for --report.
struct UpstreamRulesReport: Encodable {
    struct CategoryTotals: Encodable {
        var total: Int
        var passed: Int
    }

    var isPartial: Bool
    var categories: [String: CategoryTotals]
    var results: [UpstreamFixtureResult]

    init(run: UpstreamRulesRun) {
        isPartial = run.isPartial
        var categories: [String: CategoryTotals] = [:]
        for category in UpstreamFixtureCategory.allCases {
            categories[category.rawValue] = CategoryTotals(total: run.total(for: category), passed: run.passCount(for: category))
        }
        self.categories = categories
        results = run.results
    }
}

func printUpstreamSummary(_ run: UpstreamRulesRun) {
    print("NuValidator Swift parity (upstream TestRunner rules)")
    print("  fixtures: \(run.results.count)\(run.isPartial ? " (partial run)" : "")")
    for category in UpstreamFixtureCategory.allCases {
        print("  \(category.rawValue): \(run.passCount(for: category))/\(run.total(for: category)) passed")
    }
}

func printResults(_ title: String, _ results: [UpstreamFixtureResult], showReason: Bool) {
    guard !results.isEmpty else {
        return
    }
    print("")
    print("\(title):")
    for result in results.prefix(20) {
        print("  \(result.path) [\(result.category.rawValue)]")
        if showReason, let failure = result.failure {
            print("    \(failure)")
        }
    }
    if results.count > 20 {
        print("  ... \(results.count - 20) more")
    }
}

func printRatchetReport(_ report: UpstreamRatchetReport, list: UpstreamKnownFailures) {
    print("  known failures listed: \(list.failures.count)")
    print("  new failures: \(report.newFailures.count)")
    print("  listed but now passing: \(report.nowPassing.count)")
    print("  listed but missing: \(report.missingEntries.count)")
    print("  pass-count drops: \(report.passCountDrops.count)")
    print("  listed with a changed failure: \(report.changedFailures.count)")

    printResults("New failures (fix them, or add them with --update-known-failures --accept <path>)", report.newFailures, showReason: true)
    printResults("Listed but now passing (remove them with --update-known-failures)", report.nowPassing, showReason: false)
    // Not a ratchet failure (a partial fix often moves the first error), but
    // a listed fixture can also get worse without starting to pass or fail,
    // so show what changed.
    printResults("Listed with a changed failure (informational; --update-known-failures records the new reason)", report.changedFailures, showReason: true)
    if !report.missingEntries.isEmpty {
        print("")
        print("Listed but missing (remove them with --update-known-failures):")
        for path in report.missingEntries.prefix(20) {
            print("  \(path)")
        }
        if report.missingEntries.count > 20 {
            print("  ... \(report.missingEntries.count - 20) more")
        }
    }
    if !report.passCountDrops.isEmpty {
        print("")
        print("Pass-count drops:")
        for drop in report.passCountDrops {
            print("  \(drop.category.rawValue): \(drop.recorded) -> \(drop.current)")
        }
    }
}

/// Runs the upstream-rules mode and returns the exit status.
func runUpstreamRules(_ options: CommandLineOptions) throws -> Int32 {
    // Writing the list is only allowed from a run that reports everything,
    // and only one way at a time.
    let writesList = options.updateKnownFailures || options.initializeKnownFailures
    if options.updateKnownFailures && options.initializeKnownFailures {
        throw CLIError.conflictingOptions("--update-known-failures", "--initialize-known-failures")
    }
    if writesList && !options.failOnRegression {
        throw CLIError.updateAllowingRegressions
    }
    if writesList && nil == options.knownFailuresPath {
        throw CLIError.knownFailuresDisabled
    }
    if (!options.accepted.isEmpty || options.acceptRemovedFixtures) && !options.updateKnownFailures {
        throw CLIError.acceptWithoutUpdate
    }
    // The list records the port's failures; writing it from messages
    // recorded elsewhere (another checker, an edited file) would launder it.
    if writesList && nil != options.replayPath {
        throw CLIError.conflictingOptions("--replay", options.updateKnownFailures ? "--update-known-failures" : "--initialize-known-failures")
    }
    // Check the report's folder now rather than after the minute-long run.
    if let reportPath = options.reportPath {
        var isDirectory: ObjCBool = false
        let folder = url(for: reportPath).deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.missingReportFolder(folder)
        }
    }

    // Load (and vet) the list before the minute-long run, so a missing,
    // unreadable or already-existing list is reported right away.
    let listURL = options.knownFailuresPath.map(url(for:))
    let existing = try listURL.flatMap(UpstreamKnownFailures.load(from:))
    if let listPath = options.knownFailuresPath {
        if options.initializeKnownFailures && nil != existing {
            throw CLIError.knownFailuresExist(listPath)
        }
        if !options.initializeKnownFailures && nil == existing {
            throw CLIError.knownFailuresMissing(listPath)
        }
    }

    let configuration = UpstreamRulesConfiguration(
        messagesPath: url(for: options.messagesPath),
        fixturesRoot: url(for: options.fixturesRoot),
        ignore: options.ignore,
        filter: options.filter,
        limit: options.limit,
        replayPath: options.replayPath.map(url(for:))
    )
    if writesList && configuration.isPartial {
        throw UpstreamRatchetError.partialRun
    }
    let willCheck: ((String) -> Void)? = options.verbose ? { fputs("\($0)\n", stderr) } : nil
    let run = try UpstreamRulesHarness().run(configuration: configuration, willCheck: willCheck)

    // Summary first, so a failure writing the report doesn't lose it.
    printUpstreamSummary(run)
    if let reportPath = options.reportPath {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(UpstreamRulesReport(run: run)).write(to: url(for: reportPath), options: .atomic)
    }

    guard let listURL else {
        return EXIT_SUCCESS
    }

    if options.initializeKnownFailures {
        let list = try UpstreamRatchet.initialList(from: run)
        try list.write(to: listURL)
        print("  known failures: initialized with \(list.failures.count) entries")
        return EXIT_SUCCESS
    }
    // Vetted above: without --initialize-known-failures the list exists.
    guard let existing else {
        return EXIT_FAILURE
    }
    if options.updateKnownFailures {
        let update = try UpstreamRatchet.updating(
            existing,
            with: run,
            accepting: Set(options.accepted),
            allowingRemovedFixtures: options.acceptRemovedFixtures
        )
        try update.list.write(to: listURL)
        print("  known failures: updated (removed \(update.removed.count), added \(update.added.count); now \(update.list.failures.count))")
        for path in update.removed.prefix(20) {
            print("    - \(path)")
        }
        if update.removed.count > 20 {
            print("    ... \(update.removed.count - 20) more removed")
        }
        for path in update.added {
            print("    + \(path)")
        }
        return EXIT_SUCCESS
    }

    let report = UpstreamRatchet.compare(run, with: existing)
    printRatchetReport(report, list: existing)
    return report.hasFailures && options.failOnRegression ? EXIT_FAILURE : EXIT_SUCCESS
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
    } else if configuration.updateBaseline {
        // ParityHarness.run skips the write when anything regressed (C4).
        print("  baseline: NOT updated (\(summary.regressions) regression(s))")
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

    if options.upstreamRules {
        // The messages.json mode's baseline options mean nothing here; say
        // so rather than silently ignoring them.
        if let option = options.messagesModeOnlyOptions.first {
            throw CLIError.notInUpstreamRules(option)
        }
        exit(try runUpstreamRules(options))
    }
    if !options.upstreamOnlyOptions.isEmpty {
        throw CLIError.requiresUpstreamRules(options.upstreamOnlyOptions)
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
