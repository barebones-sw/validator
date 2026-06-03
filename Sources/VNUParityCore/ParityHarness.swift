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

    public var description: String {
        switch self {
        case .invalidMessagesJSON(let url):
            return "Could not decode NuValidator messages JSON at \(url.path)."
        case .baselineVersion(let version):
            return "Unsupported parity baseline version \(version)."
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
        let expectations = try loadExpectations(from: configuration.messagesPath)
        let baseline = try configuration.baselinePath.flatMap(loadBaseline(from:))
        let cases = selectCases(from: expectations, filter: configuration.filter, limit: configuration.limit)
        let results = cases.map { path, expected -> ParityCaseResult in
            evaluate(path: path, expectedMessage: expected, baseline: baseline, fixturesRoot: configuration.fixturesRoot)
        }

        if configuration.updateBaseline, let baselinePath = configuration.baselinePath {
            try writeBaseline(from: results, to: baselinePath)
        }

        let regressions = results.filter { $0.previouslyMatched == true && !$0.matched }.count
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

        return ParityRun(summary: summary, results: results, baselineUpdated: configuration.updateBaseline && configuration.baselinePath != nil)
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
