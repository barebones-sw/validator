import Foundation
import VNUCore
import VNUSwiftCore

public struct ParityConfiguration: Sendable {
    public var messagesPath: URL
    public var fixturesRoot: URL
    public var baselinePath: URL?
    public var filter: String?
    public var limit: Int?
    public var updateBaseline: Bool
    public var failOnRegression: Bool
    public var strict: Bool

    public init(
        messagesPath: URL,
        fixturesRoot: URL,
        baselinePath: URL? = nil,
        filter: String? = nil,
        limit: Int? = nil,
        updateBaseline: Bool = false,
        failOnRegression: Bool = true,
        strict: Bool = false
    ) {
        self.messagesPath = messagesPath
        self.fixturesRoot = fixturesRoot
        self.baselinePath = baselinePath
        self.filter = filter
        self.limit = limit
        self.updateBaseline = updateBaseline
        self.failOnRegression = failOnRegression
        self.strict = strict
    }
}

public struct ParityBaseline: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var matched: [String: Bool]

    public init(version: Int = Self.currentVersion, matched: [String: Bool] = [:]) {
        self.version = version
        self.matched = matched
    }

    public func matchedExpectation(for path: String) -> Bool? {
        matched[path]
    }
}

public struct ParityCaseResult: Codable, Equatable, Sendable {
    public var path: String
    public var expectedMessage: String
    public var actualMessages: [String]
    public var matched: Bool
    public var missingFixture: Bool
    public var previouslyMatched: Bool?

    public init(
        path: String,
        expectedMessage: String,
        actualMessages: [String],
        matched: Bool,
        missingFixture: Bool,
        previouslyMatched: Bool?
    ) {
        self.path = path
        self.expectedMessage = expectedMessage
        self.actualMessages = actualMessages
        self.matched = matched
        self.missingFixture = missingFixture
        self.previouslyMatched = previouslyMatched
    }
}

public struct ParitySummary: Codable, Equatable, Sendable {
    public var total: Int
    public var matched: Int
    public var unmatched: Int
    public var missingFixtures: Int
    public var regressions: Int
    public var improvements: Int
    public var baselineCases: Int

    public var hasFailures: Bool {
        missingFixtures > 0 || regressions > 0
    }
}

public struct ParityRun: Codable, Equatable, Sendable {
    public var summary: ParitySummary
    public var results: [ParityCaseResult]
    public var baselineUpdated: Bool
}

public enum ParityHarnessError: Error, CustomStringConvertible, Sendable {
    case invalidMessagesJSON(URL)
    case baselineVersion(Int)
    case partialBaselineUpdate
    case baselineUpdateAllowingRegressions

    public var description: String {
        switch self {
        case .invalidMessagesJSON(let url):
            return "Could not decode NuValidator messages JSON at \(url.path)."
        case .baselineVersion(let version):
            return "Unsupported parity baseline version \(version)."
        case .partialBaselineUpdate:
            return "Refusing to update the baseline from a partial run (--filter or --limit); it would drop every case that wasn't run."
        case .baselineUpdateAllowingRegressions:
            return "Refusing to update the baseline with --allow-regression; it would record the regressions as the new expectations."
        }
    }
}

public struct ParityHarness {
    private let validator: NuValidator
    private let fileManager: FileManager

    public init(validator: NuValidator = NuValidator(), fileManager: FileManager = .default) {
        self.validator = validator
        self.fileManager = fileManager
    }

    public func run(configuration: ParityConfiguration) throws -> ParityRun {
        // The baseline is rewritten wholesale from this run's results, so a
        // run that skipped cases (--filter, --limit) used to shrink it to just
        // those cases, and --allow-regression let a regression be written as
        // the new expectation, so the next run no longer reported it. Refuse
        // both before doing any work (review item C4).
        if configuration.updateBaseline {
            if !(configuration.filter ?? "").isEmpty || nil != configuration.limit {
                throw ParityHarnessError.partialBaselineUpdate
            }
            if !configuration.failOnRegression {
                throw ParityHarnessError.baselineUpdateAllowingRegressions
            }
        }

        let expectations = try loadExpectations(from: configuration.messagesPath)
        let baseline = try configuration.baselinePath.flatMap(loadBaseline(from:))
        let cases = selectCases(from: expectations, filter: configuration.filter, limit: configuration.limit)
        let results = cases.map { path, expected -> ParityCaseResult in
            evaluate(path: path, expectedMessage: expected, baseline: baseline, fixturesRoot: configuration.fixturesRoot)
        }

        let regressions = results.filter { $0.previouslyMatched == true && !$0.matched }.count

        // Only write the baseline when nothing regressed, for the same reason:
        // an update may record improvements and new cases, never a case that
        // used to match and now doesn't (C4).
        var baselineUpdated = false
        if configuration.updateBaseline, let baselinePath = configuration.baselinePath, 0 == regressions {
            try writeBaseline(from: results, to: baselinePath)
            baselineUpdated = true
        }

        let improvements = results.filter { $0.previouslyMatched == false && $0.matched }.count
        let matched = results.filter(\.matched).count
        let missing = results.filter(\.missingFixture).count
        let summary = ParitySummary(
            total: results.count,
            matched: matched,
            unmatched: results.count - matched,
            missingFixtures: missing,
            regressions: regressions,
            improvements: improvements,
            baselineCases: baseline?.matched.count ?? 0
        )

        return ParityRun(summary: summary, results: results, baselineUpdated: baselineUpdated)
    }

    public func shouldFail(_ run: ParityRun, configuration: ParityConfiguration) -> Bool {
        if run.summary.missingFixtures > 0 {
            return true
        }
        if configuration.strict && run.summary.unmatched > 0 {
            return true
        }
        if configuration.failOnRegression && run.summary.regressions > 0 {
            return true
        }
        return false
    }

    private func loadExpectations(from url: URL) throws -> [(path: String, message: String)] {
        let data = try Data(contentsOf: url)
        let object = try JSONDecoder().decode([String: String].self, from: data)
        return object
            .map { (path: $0.key, message: $0.value) }
            .sorted { $0.path < $1.path }
    }

    private func loadBaseline(from url: URL) throws -> ParityBaseline {
        guard fileManager.fileExists(atPath: url.path) else {
            return ParityBaseline()
        }
        let baseline = try JSONDecoder().decode(ParityBaseline.self, from: Data(contentsOf: url))
        guard baseline.version == ParityBaseline.currentVersion else {
            throw ParityHarnessError.baselineVersion(baseline.version)
        }
        return baseline
    }

    private func selectCases(
        from expectations: [(path: String, message: String)],
        filter: String?,
        limit: Int?
    ) -> [(path: String, message: String)] {
        let filtered: [(path: String, message: String)]
        if let filter, !filter.isEmpty {
            filtered = expectations.filter { $0.path.localizedCaseInsensitiveContains(filter) || $0.message.localizedCaseInsensitiveContains(filter) }
        } else {
            filtered = expectations
        }

        if let limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    private func evaluate(
        path: String,
        expectedMessage: String,
        baseline: ParityBaseline?,
        fixturesRoot: URL
    ) -> ParityCaseResult {
        let fixtureURL = fixturesRoot.appendingPathComponent(path)
        let previous = baseline?.matchedExpectation(for: path)
        guard fileManager.fileExists(atPath: fixtureURL.path),
              let data = try? Data(contentsOf: fixtureURL) else {
            return ParityCaseResult(
                path: path,
                expectedMessage: expectedMessage,
                actualMessages: [],
                matched: false,
                missingFixture: true,
                previouslyMatched: previous
            )
        }

        let result = validator.check(
            input: DocumentInput(data: data, contentType: contentType(for: fixtureURL), url: path),
            options: CheckerOptions(parameters: ["out": ["json"], "level": ["all"]])
        )
        let actualMessages = result.messages.map(\.message)
        let matched = actualMessages.contains { Self.messagesMatch(actual: $0, expected: expectedMessage) }
        return ParityCaseResult(
            path: path,
            expectedMessage: expectedMessage,
            actualMessages: actualMessages,
            matched: matched,
            missingFixture: false,
            previouslyMatched: previous
        )
    }

    private func writeBaseline(from results: [ParityCaseResult], to url: URL) throws {
        let baseline = ParityBaseline(matched: Dictionary(uniqueKeysWithValues: results.map { ($0.path, $0.matched) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(baseline)
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }

    private func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "xhtml":
            return "application/xhtml+xml; charset=utf-8"
        case "xml", "svg":
            return "application/xml; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        default:
            return "text/html; charset=utf-8"
        }
    }

    static func messagesMatch(actual: String, expected: String) -> Bool {
        let normalizedActual = normalizeMessage(actual)
        let normalizedExpected = normalizeMessage(expected)
        guard !normalizedActual.isEmpty, !normalizedExpected.isEmpty else {
            return false
        }

        return normalizedActual == normalizedExpected
            || normalizedActual.contains(normalizedExpected)
            || normalizedExpected.contains(normalizedActual)
    }

    private static func normalizeMessage(_ message: String) -> String {
        var normalized = message
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }
        return normalized
    }
}

// MARK: - Upstream TestRunner rules (review unit U0)
//
// The messages.json harness above is much weaker than the runner upstream
// uses to gate its own releases (src/nu/validator/client/TestRunner.java):
// - it only runs the 3,824 fixtures listed in messages.json, so the 1,700 or
//   so valid fixtures, which must produce no errors at all, never run;
// - an expectation "matches" if any message of any type contains it, or is
//   contained in it, after folding curly quotes;
// - a regression only counts if the fixture matched before.
// Case 554591 (dozens of false errors on valid nested lists, plus an error on
// every page that had both a <style> and a <script>) scored 3824/3824 here.
//
// The code below scores every fixture the way TestRunner does and keeps a
// ratchet: the list of fixtures that still fail may only shrink. A fixture
// passes when TestRunner would neither fail it nor print anything about it.
// That is slightly stricter than TestRunner's exit status, because TestRunner
// prints some problems without failing: a haswarn or hasinfo message that
// doesn't match, a haswarn file with no warning, an error in a hasinfo file,
// role="directory" in a valid or hasinfo file, a fixture missing from
// messages.json, and an exception while checking an invalid file. But
// upstream's own suite is completely silent under TestRunner (checked with
// vnu.jar built from this repository), so these rules reject nothing
// upstream accepts.

/// The kinds of fixture TestRunner.checkTestFiles distinguishes.
public enum UpstreamFixtureCategory: String, Codable, CaseIterable, Sendable {
    case valid
    case invalid
    case hasWarning = "haswarn"
    case hasInfo = "hasinfo"
}

public struct UpstreamFixture: Equatable, Sendable {
    /// Relative to the fixtures root, "/"-separated: the messages.json key.
    public var path: String
    public var category: UpstreamFixtureCategory

    public init(path: String, category: UpstreamFixtureCategory) {
        self.path = path
        self.category = category
    }

    /// The relative path as TestRunner spells it: the messages.json key and
    /// what --ignore substrings are matched against. getRelativePathname
    /// takes it from File.toURI().toURL().getPath(), which percent-encodes
    /// (as UTF-8) every ASCII character java.net.URI doesn't allow in a
    /// path, plus non-ASCII space and control characters; other non-ASCII
    /// characters stay as they are. No upstream fixture path needs encoding
    /// today, but one with a space would otherwise never find its expected
    /// message.
    static func upstreamKey(for path: String) -> String {
        // java.net.URI's unreserved and path punctuation characters.
        let allowedASCII = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'();:@&=+$,/".unicodeScalars)
        var key = ""
        for scalar in path.unicodeScalars {
            let mustQuote: Bool
            if scalar.isASCII {
                mustQuote = !allowedASCII.contains(scalar)
            } else {
                // Character.isSpaceChar (Zs, Zl, Zp) or isISOControl.
                switch scalar.properties.generalCategory {
                case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control:
                    mustQuote = true
                default:
                    mustQuote = false
                }
            }
            if mustQuote {
                for byte in String(scalar).utf8 {
                    key += String(format: "%%%02X", byte)
                }
            } else {
                key.unicodeScalars.append(scalar)
            }
        }
        return key
    }

    /// TestRunner.checkHtmlFile tests the file's name, not its path, for
    /// "missing-lang".
    var fileName: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// TestRunner parses .xhtml and .xht files as XML (checkXmlFile, which
    /// takes the encoding from the document) and everything else as HTML
    /// forced to UTF-8 (checkHtmlFile(file, true)). The messages.json
    /// harness checked .xht as HTML.
    var contentType: String {
        if path.hasSuffix(".xhtml") || path.hasSuffix(".xht") {
            return "application/xhtml+xml"
        }
        return "text/html; charset=utf-8"
    }
}

public struct UpstreamFixtureResult: Codable, Equatable, Sendable {
    public var path: String
    public var category: UpstreamFixtureCategory
    public var passed: Bool
    /// Why it failed, in TestRunner's own words where it has some.
    public var failure: String?

    public init(path: String, category: UpstreamFixtureCategory, passed: Bool, failure: String?) {
        self.path = path
        self.category = category
        self.passed = passed
        self.failure = failure
    }
}

public struct UpstreamRulesConfiguration: Sendable {
    public var messagesPath: URL
    public var fixturesRoot: URL
    /// TestRunner's --ignore list: skip fixtures whose relative path
    /// contains any of these.
    public var ignore: [String]
    public var filter: String?
    public var limit: Int?
    /// Score messages recorded elsewhere (JSON Lines of
    /// {"path": ..., "messages": [...]}) instead of running the port. Feeding
    /// it vnu.jar's own output checks these rules against the reference
    /// checker, which should pass nearly everything.
    public var replayPath: URL?

    public init(
        messagesPath: URL,
        fixturesRoot: URL,
        ignore: [String],
        filter: String?,
        limit: Int?,
        replayPath: URL?
    ) {
        self.messagesPath = messagesPath
        self.fixturesRoot = fixturesRoot
        self.ignore = ignore
        self.filter = filter
        self.limit = limit
        self.replayPath = replayPath
    }

    /// A run that skips fixtures can't say anything about the ones it
    /// skipped, so it can't update the known-failure list or check pass
    /// counts.
    public var isPartial: Bool {
        !(filter ?? "").isEmpty || nil != limit || !ignore.isEmpty
    }
}

public struct UpstreamRulesRun: Codable, Equatable, Sendable {
    public var results: [UpstreamFixtureResult]
    public var isPartial: Bool

    public func total(for category: UpstreamFixtureCategory) -> Int {
        results.filter { category == $0.category }.count
    }

    public func passCount(for category: UpstreamFixtureCategory) -> Int {
        results.filter { category == $0.category && $0.passed }.count
    }
}

/// One line of a --replay file.
public struct UpstreamReplayRecord: Codable, Sendable {
    public var path: String
    public var messages: [ValidationMessage]
}

public enum UpstreamRulesError: Error, CustomStringConvertible, Sendable {
    case unreadableReplayLine(Int, String)
    case duplicateReplayPath(String)

    public var description: String {
        switch self {
        case .unreadableReplayLine(let line, let reason):
            return "Could not decode line \(line) of the replay file: \(reason)"
        case .duplicateReplayPath(let path):
            return "The replay file has more than one record for \(path)."
        }
    }
}

/// The SAX callback TestRunner would have received for a message. The port
/// labels messages the way vnu.jar's own output does, which isn't always the
/// callback TestRunner sees:
/// - role="directory" (a warning in the port) and datatype warnings such as
///   a deprecated language subtag (a warning, "Bad value ...") reach
///   TestRunner through error(), which has special cases for both;
/// - rel typos ("Typo for", info in the port) also arrive through error();
/// - "Trailing slash on void elements ..." (info in the port, because
///   MessageEmitterAdapter relabels it for display) is a TreeBuilder warn(),
///   so TestRunner receives it through warning().
enum UpstreamCallback: Equatable {
    case error(String)
    case fatal(String)
    /// error() for role="directory", which TestRunner treats as a warning.
    case roleDirectory(String)
    /// error() for a bad attribute value whose datatype exception is only a
    /// warning: TestRunner treats it as a warning when it is the first
    /// problem in an invalid or haswarn file, and as an error otherwise.
    case datatypeWarning(String)
    case warning(String)
    /// info(), or an error() containing "Typo for", which TestRunner
    /// handles exactly like an info message.
    case info(String)

    var message: String {
        switch self {
        case .error(let message), .fatal(let message), .roleDirectory(let message), .datatypeWarning(let message), .warning(let message), .info(let message):
            return message
        }
    }

    var isDatatypeWarning: Bool {
        if case .datatypeWarning = self {
            return true
        }
        return false
    }

    /// error() or fatalError() that sets TestRunner's inError.
    var isRealError: Bool {
        switch self {
        case .error, .fatal:
            return true
        default:
            return false
        }
    }

    var isRoleDirectory: Bool {
        if case .roleDirectory = self {
            return true
        }
        return false
    }

    var isInfo: Bool {
        if case .info = self {
            return true
        }
        return false
    }

    /// What TestRunner's emitMessage would label it, for failure reasons.
    var label: String {
        switch self {
        // emitMessage(e, "error") prints datatype warnings as errors.
        case .error, .datatypeWarning:
            return "error"
        case .fatal:
            return "fatal error"
        case .roleDirectory, .warning:
            return "warning"
        case .info:
            return "info"
        }
    }
}

public struct UpstreamRulesHarness {
    private let validator: NuValidator
    private let fileManager: FileManager

    public init(validator: NuValidator = NuValidator(), fileManager: FileManager = .default) {
        self.validator = validator
        self.fileManager = fileManager
    }

    // MARK: Fixtures

    /// Every fixture TestRunner.runTestSuite would check, sorted by path.
    public func fixtures(under root: URL, ignoring ignore: [String]) throws -> [UpstreamFixture] {
        var fixtures: [UpstreamFixture] = []
        // runTestSuite only walks the directories directly under the
        // fixtures root; files at the top level (tests/template.html) are
        // never checked.
        for name in try sortedEntries(of: root) where isDirectory(root.appendingPathComponent(name)) {
            try collectFixtures(in: root.appendingPathComponent(name), relativePath: name, state: .expectingAnything, ignoring: ignore, into: &fixtures)
        }
        return fixtures.sorted { $0.path < $1.path }
    }

    private enum DirectoryState {
        case expectingAnything
        case expectingInvalid
        case expectingValid
    }

    /// TestRunner.checkTestFiles: below a directory named "invalid" or
    /// "valid" every file has that category; elsewhere the path decides.
    private func collectFixtures(
        in directory: URL,
        relativePath: String,
        state: DirectoryState,
        ignoring ignore: [String],
        into fixtures: inout [UpstreamFixture]
    ) throws {
        for name in try sortedEntries(of: directory) {
            let url = directory.appendingPathComponent(name)
            let path = relativePath + "/" + name
            if isDirectory(url) {
                let nextState: DirectoryState
                if .expectingAnything != state {
                    nextState = state
                } else if "invalid" == name {
                    nextState = .expectingInvalid
                } else if "valid" == name {
                    nextState = .expectingValid
                } else {
                    nextState = .expectingAnything
                }
                try collectFixtures(in: url, relativePath: path, state: nextState, ignoring: ignore, into: &fixtures)
                continue
            }
            // isCheckableFile: a regular file (File.isFile(), which follows
            // symlinks, so a dangling link or a FIFO is skipped) whose name
            // ends with one of these, compared with Java's case-sensitive
            // endsWith.
            guard name.hasSuffix(".html") || name.hasSuffix(".htm") || name.hasSuffix(".xhtml") || name.hasSuffix(".xht"),
                  isRegularFile(url) else {
                continue
            }
            // isIgnorable: the relative path, as TestRunner spells it (see
            // upstreamKey), contains an --ignore substring.
            let key = UpstreamFixture.upstreamKey(for: path)
            if ignore.contains(where: { key.contains($0) }) {
                continue
            }
            fixtures.append(UpstreamFixture(path: path, category: category(forPath: path, state: state)))
        }
    }

    /// TestRunner tests file.getPath(), which includes the fixtures root
    /// itself; the relative path is used here so a checkout that happens to
    /// live under a directory named e.g. "novalid" doesn't flip every
    /// fixture to invalid.
    private func category(forPath path: String, state: DirectoryState) -> UpstreamFixtureCategory {
        switch state {
        case .expectingInvalid:
            return .invalid
        case .expectingValid:
            return .valid
        case .expectingAnything:
            if path.contains("novalid") {
                return .invalid
            }
            if path.contains("haswarn") {
                return .hasWarning
            }
            if path.contains("hasinfo") {
                return .hasInfo
            }
            return .valid
        }
    }

    private func sortedEntries(of directory: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// attributesOfItem doesn't follow symlinks, so resolve them first; a
    /// dangling link then reports its own (non-regular) type.
    private func isRegularFile(_ url: URL) -> Bool {
        let attributes = try? fileManager.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return FileAttributeType.typeRegular == attributes?[.type] as? FileAttributeType
    }

    // MARK: Running

    /// Checks (or replays) every selected fixture. `willCheck` is called
    /// with each path before it is checked, so a crash in the checker can be
    /// traced to its fixture (vnu-parity --verbose).
    public func run(configuration: UpstreamRulesConfiguration, willCheck: ((String) -> Void)?) throws -> UpstreamRulesRun {
        let expectations = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configuration.messagesPath))
        var selected = try fixtures(under: configuration.fixturesRoot, ignoring: configuration.ignore)
        if let filter = configuration.filter, !filter.isEmpty {
            selected = selected.filter { $0.path.localizedCaseInsensitiveContains(filter) }
        }
        if let limit = configuration.limit {
            selected = Array(selected.prefix(limit))
        }
        let replayed = try configuration.replayPath.map(loadReplay(from:))

        let results = selected.map { fixture -> UpstreamFixtureResult in
            willCheck?(fixture.path)
            let messages: [ValidationMessage]
            if let replayed {
                guard let recorded = replayed[fixture.path] else {
                    return UpstreamFixtureResult(path: fixture.path, category: fixture.category, passed: false, failure: "No replayed messages for this fixture.")
                }
                messages = recorded
            } else {
                guard let data = try? Data(contentsOf: configuration.fixturesRoot.appendingPathComponent(fixture.path)) else {
                    return UpstreamFixtureResult(path: fixture.path, category: fixture.category, passed: false, failure: "Could not read the fixture.")
                }
                // Same options as the messages.json harness and the XPC
                // service: every message level.
                messages = validator.check(
                    input: DocumentInput(data: data, contentType: fixture.contentType, url: fixture.path),
                    options: CheckerOptions(parameters: ["out": ["json"], "level": ["all"]])
                ).messages
            }
            let failure = Self.failure(for: fixture, messages: messages, expected: expectations[UpstreamFixture.upstreamKey(for: fixture.path)])
            return UpstreamFixtureResult(path: fixture.path, category: fixture.category, passed: nil == failure, failure: failure)
        }
        return UpstreamRulesRun(results: results, isPartial: configuration.isPartial)
    }

    private func loadReplay(from url: URL) throws -> [String: [ValidationMessage]] {
        var replayed: [String: [ValidationMessage]] = [:]
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        // Split on "\n" by scalars: "\r\n" is a single Character, so
        // splitting the String on "\n" would miss CRLF line ends. The "\r"
        // left at the end of a CRLF line is JSON whitespace.
        for (index, line) in text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineText = String(String.UnicodeScalarView(line))
            if lineText.allSatisfy(\.isWhitespace) {
                continue
            }
            let record: UpstreamReplayRecord
            do {
                record = try decoder.decode(UpstreamReplayRecord.self, from: Data(lineText.utf8))
            } catch {
                throw UpstreamRulesError.unreadableReplayLine(index + 1, String(describing: error))
            }
            // Two records for one fixture means the file was built wrong;
            // silently keeping either would score the wrong messages.
            if nil != replayed[record.path] {
                throw UpstreamRulesError.duplicateReplayPath(record.path)
            }
            replayed[record.path] = record.messages
        }
        return replayed
    }

    // MARK: Verdicts

    /// nil when the fixture passes; otherwise why it fails. This follows
    /// TestRunner's checkFiles / checkInvalidFiles / checkHasWarningFiles /
    /// checkHasInfoFiles, with every message TestRunner would print counted
    /// as a failure (see the comment at the top of this section).
    static func failure(for fixture: UpstreamFixture, messages: [ValidationMessage], expected: String?) -> String? {
        // A non-document (I/O or internal) error means the check threw.
        // TestRunner catches the exception and prints "Exception while
        // processing file" whatever the category (it only fails some of
        // them), so it is a failure here wherever it appears.
        if let exception = messages.first(where: { "non-document-error" == $0.type }) {
            return "Exception while processing file: \(exception.message)"
        }
        let callbacks = Self.callbacks(for: messages, fileName: fixture.fileName)
        switch fixture.category {
        case .valid:
            // checkFiles(): messages are emitted, so every error, fatal error
            // and warning is printed. An error fails the file and a warning
            // fails the whole run (hasUnhandledWarning). Info messages and
            // "Typo for" errors are never printed.
            if let printed = callbacks.first(where: { !$0.isInfo }) {
                return "Expected no errors or warnings but encountered \(printed.label) \u{201c}\(printed.message)\u{201d}."
            }
            return nil

        case .invalid:
            // checkInvalidFiles(): expectingError is set, so warning() calls
            // are ignored. The first error() or fatalError() is the exception
            // compared with messages.json; that includes role="directory" and
            // a datatype warning, neither of which sets inError by being the
            // exception. Any later error(), a datatype warning included, sets
            // inError, and an invalid file needs inError.
            let exceptionIndex = callbacks.firstIndex { $0.isRealError || $0.isRoleDirectory || $0.isDatatypeWarning }
            if let exceptionIndex {
                let exception = callbacks[exceptionIndex]
                guard let expected else {
                    return "No expected message in messages file."
                }
                if !Self.upstreamMessageMatches(reported: exception.message, expected: expected) {
                    return "Expected \u{201c}\(expected)\u{201d} but instead encountered \u{201c}\(exception.message)\u{201d}."
                }
            }
            if nil == Self.firstCallbackSettingInError(in: callbacks, exceptionIndex: exceptionIndex) {
                return "Expected an error but did not encounter any."
            }
            return nil

        case .hasWarning:
            // checkHasWarningFiles(): the first warning(), error() or
            // fatalError() is the exception. Anything that sets inError (a
            // real error, or a datatype warning that isn't the exception)
            // fails the file. TestRunner only prints a mismatched message or
            // a missing warning; both fail here.
            let exceptionIndex = callbacks.firstIndex { !$0.isInfo }
            if let error = Self.firstCallbackSettingInError(in: callbacks, exceptionIndex: exceptionIndex) {
                return "Expected a warning only but encountered \(error.label) \u{201c}\(error.message)\u{201d}."
            }
            // With no inError, the exception (if any) is warning-like:
            // warning(), role="directory" or a datatype warning.
            guard let exceptionIndex else {
                return "Expected a warning but did not encounter any."
            }
            let exception = callbacks[exceptionIndex]
            guard let expected else {
                return "No expected message in messages file."
            }
            if !Self.upstreamMessageMatches(reported: exception.message, expected: expected) {
                return "Expected \u{201c}\(expected)\u{201d} but instead encountered \u{201c}\(exception.message)\u{201d}."
            }
            return nil

        case .hasInfo:
            // checkHasInfoFiles(): messages are emitted as for valid files,
            // so any error or warning is printed (and a warning fails the
            // run). The first info message must equal messages.json exactly:
            // this comparison uses String.equals, without the \p{C}
            // normalization errors and warnings get.
            if let printed = callbacks.first(where: { !$0.isInfo }) {
                return "Expected an info message only but encountered \(printed.label) \u{201c}\(printed.message)\u{201d}."
            }
            guard let info = callbacks.first(where: \.isInfo) else {
                return "Expected an info message but did not encounter any."
            }
            guard let expected else {
                return "No expected message in messages file."
            }
            if !info.message.unicodeScalars.elementsEqual(expected.unicodeScalars) {
                return "Expected \u{201c}\(expected)\u{201d} but instead encountered \u{201c}\(info.message)\u{201d}."
            }
            return nil
        }
    }

    /// In a non-emitting check (invalid and haswarn files), the first
    /// callback that sets TestRunner's inError: a real error, or a datatype
    /// warning that isn't the exception (error() returns early only for the
    /// exception itself). role="directory" never sets it.
    private static func firstCallbackSettingInError(in callbacks: [UpstreamCallback], exceptionIndex: Int?) -> UpstreamCallback? {
        for (index, callback) in callbacks.enumerated() where callback.isRealError || (callback.isDatatypeWarning && index != exceptionIndex) {
            return callback
        }
        return nil
    }

    /// Maps the port's messages to the callbacks TestRunner would have
    /// received, dropping the ones its error(), warning() and the checker's
    /// ignoreMissingLang setting would never let through.
    static func callbacks(for messages: [ValidationMessage], fileName: String) -> [UpstreamCallback] {
        messages.compactMap { message -> UpstreamCallback? in
            let text = message.message
            let isError = "error" == message.type || "non-document-error" == message.type
            let isWarning = !isError && "warning" == message.subType
            // fatalError() has no filtering. (failure(for:) has already
            // failed any fixture with a non-document error.)
            if isError, "fatal" == message.subType || "non-document-error" == message.type {
                return .fatal(text)
            }
            if isError || isWarning, text.hasPrefix(Self.roleDirectoryPrefix) {
                // error() checks the filter before isRoleDirectoryWarning.
                return Self.isFiltered(text) ? nil : .roleDirectory(text)
            }
            if isError {
                if Self.isFiltered(text) {
                    return nil
                }
                return text.contains("Typo for") ? .info(text) : .error(text)
            }
            if isWarning {
                // A warning worded "Bad value “...”" is a datatype warning
                // (e.g. a deprecated language subtag): upstream raises it as
                // a BadAttributeValueException through error(), so only
                // error()'s filter applies. Checked against every callback in
                // upstream's suite: all 46 datatype warnings start this way
                // and none of the 1,356 warning() calls do.
                //
                // TextContentChecker's "Double-check the text content of
                // element ..." warning also arrives through error(), but as a
                // DatatypeMismatchException rather than a
                // BadAttributeValueException, so TestRunner always treats it
                // as an error. (Assertions.java's VnuBadAttrValueException
                // shares the "Bad value" wording but is never a warning: all
                // three of its call sites pass warning: false.)
                if text.hasPrefix(Self.datatypeWarningPrefix) || text.hasPrefix(Self.textContentWarningPrefix) {
                    if Self.isFiltered(text) {
                        return nil
                    }
                    return text.hasPrefix(Self.textContentWarningPrefix) ? .error(text) : .datatypeWarning(text)
                }
                return Self.warningCallback(text, fileName: fileName)
            }
            // TreeBuilder raises this through warn(); only
            // MessageEmitterAdapter's display relabels it as info.
            if text.contains(Self.trailingSlashText) {
                return Self.warningCallback(text, fileName: fileName)
            }
            return .info(text)
        }
    }

    /// warning(): the filters it applies, then the warning.
    private static func warningCallback(_ text: String, fileName: String) -> UpstreamCallback? {
        if Self.isFiltered(text) || text.contains("cannot be represented as XML 1.0") || text.contains("is not serializable as XML 1.0") {
            return nil
        }
        // TestRunner sets nu.validator.checker.ignoreMissingLang, which only
        // suppresses this one warning, except while it checks a file whose
        // name contains "missing-lang".
        if text.hasPrefix(Self.missingLangPrefix), !fileName.contains("missing-lang") {
            return nil
        }
        return .warning(text)
    }

    /// What MessageEmitterAdapter.isRoleDirectoryWarning recognizes (a bad
    /// value "directory" for the role attribute), in the port's wording.
    static let roleDirectoryPrefix = "Bad value \u{201c}directory\u{201d} for attribute \u{201c}role\u{201d}"

    static let datatypeWarningPrefix = "Bad value \u{201c}"

    static let textContentWarningPrefix = "Double-check the text content of element"

    static let trailingSlashText = "Trailing slash on void elements has no effect"

    static let missingLangPrefix = "Consider adding a \u{201c}lang\u{201d} attribute"

    /// Java's "." stops at \n, \r, U+0085, U+2028 and U+2029, and its "\s"
    /// is ASCII-only; ICU's (NSRegularExpression's) differ, so spell both
    /// out for the patterns that come from Java.
    private static let javaDot = "[^\\n\\r\\u0085\\u2028\\u2029]"
    private static let javaSpace = "[ \\t\\n\\u000B\\f\\r]"

    /// MessageEmitterAdapter.DEFAULT_FILTER_STRINGS, which TestRunner's
    /// error() and warning() apply with Matcher.matches() (the whole
    /// message). The patterns are constant, so try! can't fail at run time.
    private static let defaultFilter = try! NSRegularExpression(pattern: "\\A(?:" + [
        "\(javaDot)*Authors who wish to regulate nested browsing contexts\(javaDot)*",
        "\(javaDot)*\(javaSpace)+\u{201c}report-uri\u{201d}\(javaSpace)+in\(javaSpace)+favour\(javaSpace)+of\(javaSpace)+a\(javaSpace)+new\(javaSpace)+\u{201c}report-to\u{201d}\(javaDot)*",
        "\(javaDot)*is only used for backwards compatibility with older CSP\(javaDot)*",
        "\(javaDot)*Property \u{201c}scale\u{201d} doesn't exist\(javaDot)*",
    ].joined(separator: "|") + ")\\z")

    /// TestRunner.messageMatches reorders these two parts of datetime
    /// errors because Java 8 stopped emitting them in a stable order.
    private static let datetimeParts = try! NSRegularExpression(pattern: "(Bad datetime with timezone: \(javaDot)+) (Bad date: \(javaDot)+)")

    static func isFiltered(_ message: String) -> Bool {
        let range = NSRange(message.startIndex..., in: message)
        return nil != defaultFilter.firstMatch(in: message, range: range)
    }

    /// TestRunner.messageMatches: replace every \p{C} code point (control,
    /// format, private use, surrogate, unassigned) with "?" in both strings,
    /// apply the datetime reordering, then compare exactly. String == would
    /// also equate canonically equivalent text, which Java's String.equals
    /// doesn't, so compare scalars.
    static func upstreamMessageMatches(reported: String, expected: String) -> Bool {
        let normalizedReported = reorderingDatetimeParts(replacingOtherCategory(in: reported))
        let normalizedExpected = reorderingDatetimeParts(replacingOtherCategory(in: expected))
        return normalizedReported.unicodeScalars.elementsEqual(normalizedExpected.unicodeScalars)
    }

    static func replacingOtherCategory(in text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned:
                scalars.append("?")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func reorderingDatetimeParts(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return datetimeParts.stringByReplacingMatches(in: text, range: range, withTemplate: "$2 $1")
    }
}

// MARK: - Known-failure ratchet (U0)
//
// The list of fixtures that fail under the rules above. A run fails when a
// fixture fails that isn't on the list, when a listed fixture passes or no
// longer exists (so gains are locked in by removing it), or when a
// category's pass count drops. Updating may only remove entries; adding one
// takes an explicit --accept for its path. That replaces --update-baseline's
// behavior of rewriting the whole expectation set from whatever the run
// produced, which could quietly bless a regression (review item C4).

public struct UpstreamKnownFailure: Codable, Equatable, Sendable {
    public var category: UpstreamFixtureCategory
    public var failure: String

    public init(category: UpstreamFixtureCategory, failure: String) {
        self.category = category
        self.failure = failure
    }
}

public struct UpstreamKnownFailures: Codable, Equatable, Sendable {
    /// Version 2 of the parity baseline; version 1 is parity-baseline.json's
    /// matched-set format, which this doesn't replace.
    public static let currentVersion = 2

    public var version: Int
    /// Fixtures per category (keyed by the category's raw value) when the
    /// list was written, so an update notices fixtures that disappeared.
    public var fixtureCounts: [String: Int]
    /// Passing fixtures per category when the list was written.
    public var passCounts: [String: Int]
    /// Fixture path to its recorded failure.
    public var failures: [String: UpstreamKnownFailure]

    public init(version: Int, fixtureCounts: [String: Int], passCounts: [String: Int], failures: [String: UpstreamKnownFailure]) {
        self.version = version
        self.fixtureCounts = fixtureCounts
        self.passCounts = passCounts
        self.failures = failures
    }

    /// nil when there is no list at `url` yet.
    public static func load(from url: URL) throws -> UpstreamKnownFailures? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let list = try JSONDecoder().decode(UpstreamKnownFailures.self, from: Data(contentsOf: url))
        guard currentVersion == list.version else {
            throw UpstreamRatchetError.unsupportedVersion(list.version)
        }
        // A missing or misspelled category key would read as zero and
        // silently switch off that category's count checks, so insist on
        // exactly the four categories.
        let categories = Set(UpstreamFixtureCategory.allCases.map(\.rawValue))
        for (name, counts) in [("fixtureCounts", list.fixtureCounts), ("passCounts", list.passCounts)] {
            guard categories == Set(counts.keys), counts.values.allSatisfy({ 0 <= $0 }) else {
                throw UpstreamRatchetError.invalidList("\(name) must give a non-negative count for each of \(categories.sorted().joined(separator: ", ")).")
            }
        }
        return list
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        // End with a newline so the checked-in file diffs cleanly.
        data.append(contentsOf: Array("\n".utf8))
        try data.write(to: url, options: .atomic)
    }
}

/// A per-category count (passes or fixtures) that fell below the recorded one.
public struct UpstreamCountDrop: Equatable, Sendable {
    public var category: UpstreamFixtureCategory
    public var recorded: Int
    public var current: Int
}

public struct UpstreamRatchetReport: Equatable, Sendable {
    /// Failing fixtures that aren't on the list.
    public var newFailures: [UpstreamFixtureResult] = []
    /// Listed fixtures that now pass; remove them to lock the gain in.
    public var nowPassing: [UpstreamFixtureResult] = []
    /// Listed fixtures that no longer exist (full runs only).
    public var missingEntries: [String] = []
    /// Categories with fewer passes than recorded (full runs only).
    public var passCountDrops: [UpstreamCountDrop] = []
    /// Listed fixtures still failing, but for a different reason. Not a
    /// failure: a partial fix often moves the first error.
    public var changedFailures: [UpstreamFixtureResult] = []

    public var hasFailures: Bool {
        !newFailures.isEmpty || !nowPassing.isEmpty || !missingEntries.isEmpty || !passCountDrops.isEmpty
    }
}

public struct UpstreamKnownFailuresUpdate: Equatable, Sendable {
    public var list: UpstreamKnownFailures
    public var removed: [String]
    public var added: [String]
}

public enum UpstreamRatchetError: Error, CustomStringConvertible, Sendable {
    case unsupportedVersion(Int)
    case partialRun
    case unacceptedFailures([String])
    case acceptedPathsNotFailing([String])
    case passCountDrops([UpstreamCountDrop])
    case fixtureCountDrops([UpstreamCountDrop])
    case invalidList(String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported known-failure list version \(version)."
        case .invalidList(let reason):
            return "The known-failure list is malformed: \(reason)"
        case .fixtureCountDrops(let drops):
            return "Refusing to write the known-failure list: fixtures disappeared since it was written; use --accept-removed-fixtures if that's intended:\n"
                + drops.map { "  \($0.category.rawValue): \($0.recorded) -> \($0.current)" }.joined(separator: "\n")
        case .partialRun:
            return "Refusing to write the known-failure list from a partial run (--filter, --limit or --ignore); it can't tell which skipped fixtures pass."
        case .unacceptedFailures(let paths):
            return "Refusing to add \(paths.count) new failure(s) to the known-failure list without --accept for each:\n" + paths.map { "  \($0)" }.joined(separator: "\n")
        case .acceptedPathsNotFailing(let paths):
            return "--accept names fixture(s) that don't fail (or don't exist):\n" + paths.map { "  \($0)" }.joined(separator: "\n")
        case .passCountDrops(let drops):
            return "Refusing to lower recorded pass counts by more than the accepted failures explain (were passing fixtures removed?); use --accept-removed-fixtures if that's intended:\n"
                + drops.map { "  \($0.category.rawValue): \($0.recorded) -> \($0.current)" }.joined(separator: "\n")
        }
    }
}

public enum UpstreamRatchet {
    public static func compare(_ run: UpstreamRulesRun, with list: UpstreamKnownFailures) -> UpstreamRatchetReport {
        var report = UpstreamRatchetReport()
        for result in run.results {
            let known = list.failures[result.path]
            if result.passed {
                if nil != known {
                    report.nowPassing.append(result)
                }
            } else if let known {
                if known.failure != result.failure || known.category != result.category {
                    report.changedFailures.append(result)
                }
            } else {
                report.newFailures.append(result)
            }
        }
        // A partial run says nothing about the fixtures it skipped.
        if !run.isPartial {
            let seen = Set(run.results.map(\.path))
            report.missingEntries = list.failures.keys.filter { !seen.contains($0) }.sorted()
            report.passCountDrops = countDrops(recorded: list.passCounts, current: run.passCount(for:))
        }
        return report
    }

    /// The first list, recording every current failure. The caller must
    /// make sure no list exists yet; afterwards the list can only shrink
    /// without --accept.
    public static func initialList(from run: UpstreamRulesRun) throws -> UpstreamKnownFailures {
        guard !run.isPartial else {
            throw UpstreamRatchetError.partialRun
        }
        return makeList(from: run)
    }

    /// Drops entries that now pass or no longer exist, refreshes the
    /// recorded failure reasons and pass counts, and adds only the new
    /// failures named in `accepted`.
    public static func updating(
        _ list: UpstreamKnownFailures,
        with run: UpstreamRulesRun,
        accepting accepted: Set<String>,
        allowingRemovedFixtures: Bool
    ) throws -> UpstreamKnownFailuresUpdate {
        guard !run.isPartial else {
            throw UpstreamRatchetError.partialRun
        }
        let failing = run.results.filter { !$0.passed }
        let failingPaths = Set(failing.map(\.path))
        let notFailing = accepted.subtracting(failingPaths).sorted()
        if !notFailing.isEmpty {
            throw UpstreamRatchetError.acceptedPathsNotFailing(notFailing)
        }
        let unaccepted = failing.filter { nil == list.failures[$0.path] && !accepted.contains($0.path) }.map(\.path)
        if !unaccepted.isEmpty {
            throw UpstreamRatchetError.unacceptedFailures(unaccepted)
        }

        // Fixtures may only disappear on purpose (an upstream merge that
        // deletes tests), and a category may lose passes only as fast as
        // accepted failures in it explain; anything more means passing
        // fixtures vanished. One case still gets through: a passing fixture
        // removed while a brand-new failing fixture is accepted in the same
        // category, which needs an explicit --accept for the new one.
        let added = failing.filter { nil == list.failures[$0.path] }
        if !allowingRemovedFixtures {
            let fixtureDrops = countDrops(recorded: list.fixtureCounts, current: run.total(for:))
            if !fixtureDrops.isEmpty {
                throw UpstreamRatchetError.fixtureCountDrops(fixtureDrops)
            }
            let unexplained = countDrops(recorded: list.passCounts, current: run.passCount(for:)).filter { drop in
                drop.recorded - drop.current > added.filter { drop.category == $0.category }.count
            }
            if !unexplained.isEmpty {
                throw UpstreamRatchetError.passCountDrops(unexplained)
            }
        }

        let removed = list.failures.keys.filter { !failingPaths.contains($0) }.sorted()
        return UpstreamKnownFailuresUpdate(list: makeList(from: run), removed: removed, added: added.map(\.path))
    }

    private static func makeList(from run: UpstreamRulesRun) -> UpstreamKnownFailures {
        var fixtureCounts: [String: Int] = [:]
        var passCounts: [String: Int] = [:]
        for category in UpstreamFixtureCategory.allCases {
            fixtureCounts[category.rawValue] = run.total(for: category)
            passCounts[category.rawValue] = run.passCount(for: category)
        }
        var failures: [String: UpstreamKnownFailure] = [:]
        for result in run.results where !result.passed {
            failures[result.path] = UpstreamKnownFailure(category: result.category, failure: result.failure ?? "")
        }
        return UpstreamKnownFailures(version: UpstreamKnownFailures.currentVersion, fixtureCounts: fixtureCounts, passCounts: passCounts, failures: failures)
    }

    private static func countDrops(recorded: [String: Int], current: (UpstreamFixtureCategory) -> Int) -> [UpstreamCountDrop] {
        UpstreamFixtureCategory.allCases.compactMap { category in
            let recordedCount = recorded[category.rawValue] ?? 0
            let currentCount = current(category)
            return currentCount < recordedCount ? UpstreamCountDrop(category: category, recorded: recordedCount, current: currentCount) : nil
        }
    }
}
