import Foundation
import Testing
import VNUCore
@testable import VNUParityCore

@Test func harnessMatchesExpectedValidatorMessage() throws {
    let fixtureRoot = try temporaryFixtures(name: "match")
    let messagePath = try writeFixture(
        root: fixtureRoot,
        relativePath: "html/parser/stray-end-tag-novalid.html",
        contents: "<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body></span></body></html>",
        expectedMessage: "Stray end tag \u{201c}span\u{201d}."
    )

    let run = try ParityHarness().run(configuration: ParityConfiguration(messagesPath: messagePath, fixturesRoot: fixtureRoot))

    #expect(run.summary.total == 1)
    #expect(run.summary.matched == 1)
    #expect(run.summary.regressions == 0)
}

@Test func harnessReportsRegressionAgainstBaseline() throws {
    let fixtureRoot = try temporaryFixtures(name: "regression")
    let messagePath = try writeFixture(
        root: fixtureRoot,
        relativePath: "html/parser/stray-end-tag-novalid.html",
        contents: "<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body><p>ok</p></body></html>",
        expectedMessage: "Stray end tag \u{201c}span\u{201d}."
    )
    let baselinePath = fixtureRoot.appendingPathComponent("baseline.json")
    try writeJSON(ParityBaseline(matched: ["html/parser/stray-end-tag-novalid.html": true]), to: baselinePath)

    let configuration = ParityConfiguration(messagesPath: messagePath, fixturesRoot: fixtureRoot, baselinePath: baselinePath)
    let harness = ParityHarness()
    let run = try harness.run(configuration: configuration)

    #expect(run.summary.total == 1)
    #expect(run.summary.matched == 0)
    #expect(run.summary.regressions == 1)
    #expect(harness.shouldFail(run, configuration: configuration))
}

@Test func harnessCanWriteBaseline() throws {
    let fixtureRoot = try temporaryFixtures(name: "baseline")
    let messagePath = try writeFixture(
        root: fixtureRoot,
        relativePath: "html/parser/stray-end-tag-novalid.html",
        contents: "<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body></span></body></html>",
        expectedMessage: "Stray end tag \u{201c}span\u{201d}."
    )
    let baselinePath = fixtureRoot.appendingPathComponent("parity-baseline.json")

    let run = try ParityHarness().run(configuration: ParityConfiguration(
        messagesPath: messagePath,
        fixturesRoot: fixtureRoot,
        baselinePath: baselinePath,
        updateBaseline: true
    ))
    let baseline = try JSONDecoder().decode(ParityBaseline.self, from: Data(contentsOf: baselinePath))

    #expect(run.baselineUpdated)
    #expect(baseline.matched["html/parser/stray-end-tag-novalid.html"] == true)
}

// MARK: - C4: baseline updates can't shrink or launder the baseline

@Test func harnessRefusesBaselineUpdateFromPartialRun() throws {
    let fixtureRoot = try temporaryFixtures(name: "partial-update")
    let messagePath = try writeFixture(
        root: fixtureRoot,
        relativePath: "html/parser/stray-end-tag-novalid.html",
        contents: "<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body></span></body></html>",
        expectedMessage: "Stray end tag \u{201c}span\u{201d}."
    )
    let baselinePath = fixtureRoot.appendingPathComponent("parity-baseline.json")

    #expect(throws: ParityHarnessError.self) {
        try ParityHarness().run(configuration: ParityConfiguration(messagesPath: messagePath, fixturesRoot: fixtureRoot, baselinePath: baselinePath, filter: "stray", updateBaseline: true))
    }
    #expect(throws: ParityHarnessError.self) {
        try ParityHarness().run(configuration: ParityConfiguration(messagesPath: messagePath, fixturesRoot: fixtureRoot, baselinePath: baselinePath, updateBaseline: true, failOnRegression: false))
    }
    #expect(!FileManager.default.fileExists(atPath: baselinePath.path))
}

@Test func harnessDoesNotWriteBaselineWhenSomethingRegressed() throws {
    let fixtureRoot = try temporaryFixtures(name: "regressed-update")
    let messagePath = try writeFixture(
        root: fixtureRoot,
        relativePath: "html/parser/stray-end-tag-novalid.html",
        contents: "<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body><p>ok</p></body></html>",
        expectedMessage: "Stray end tag \u{201c}span\u{201d}."
    )
    let baselinePath = fixtureRoot.appendingPathComponent("baseline.json")
    let original = ParityBaseline(matched: ["html/parser/stray-end-tag-novalid.html": true])
    try writeJSON(original, to: baselinePath)

    let run = try ParityHarness().run(configuration: ParityConfiguration(messagesPath: messagePath, fixturesRoot: fixtureRoot, baselinePath: baselinePath, updateBaseline: true))

    let onDisk = try JSONDecoder().decode(ParityBaseline.self, from: Data(contentsOf: baselinePath))
    #expect(1 == run.summary.regressions)
    #expect(!run.baselineUpdated)
    #expect(original == onDisk)
}

// MARK: - Upstream TestRunner rules (U0)

@Test func upstreamFixturesAreEnumeratedLikeTestRunner() throws {
    let root = try temporaryFixtures(name: "enumerate")
    for path in [
        "template.html",                    // top-level file: never checked
        "html/a-isvalid.html",
        "html/b-novalid.html",
        "html/c-haswarn.html",
        "html/d-hasinfo.htm",
        "html/plain.html",                  // no marker: valid
        "html/invalid/plain.html",          // an "invalid" directory forces the category...
        "html/invalid/x-haswarn.html",      // ...even over a marker
        "html/valid/y-novalid.html",
        "xhtml/e.xht",
        "xhtml/f.xhtml",
        "html/UPPER.HTML",                  // extensions are case-sensitive, as in Java
        "html/notes.txt",
        "html/skip-me-isvalid.html",
    ] {
        try writeFile(root: root, relativePath: path, contents: "x")
    }

    let fixtures = try UpstreamRulesHarness().fixtures(under: root, ignoring: ["skip-me"])

    #expect([
        UpstreamFixture(path: "html/a-isvalid.html", category: .valid),
        UpstreamFixture(path: "html/b-novalid.html", category: .invalid),
        UpstreamFixture(path: "html/c-haswarn.html", category: .hasWarning),
        UpstreamFixture(path: "html/d-hasinfo.htm", category: .hasInfo),
        UpstreamFixture(path: "html/invalid/plain.html", category: .invalid),
        UpstreamFixture(path: "html/invalid/x-haswarn.html", category: .invalid),
        UpstreamFixture(path: "html/plain.html", category: .valid),
        UpstreamFixture(path: "html/valid/y-novalid.html", category: .valid),
        UpstreamFixture(path: "xhtml/e.xht", category: .valid),
        UpstreamFixture(path: "xhtml/f.xhtml", category: .valid),
    ] == fixtures)
    #expect("application/xhtml+xml" == fixtures.first { "xhtml/e.xht" == $0.path }?.contentType)
    #expect("text/html; charset=utf-8" == fixtures.first { "html/plain.html" == $0.path }?.contentType)
}

@Test func validFixturesFailOnAnyErrorOrWarningButNotOnInfo() {
    let fixture = UpstreamFixture(path: "html/x-isvalid.html", category: .valid)
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.info("Discarding superfluous token \u{201c}link\u{201d} from value of attribute \u{201c}role\u{201d}.")], expected: nil))
    // TestRunner treats "Typo for" errors as info messages.
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.error("Bad value \u{201c}x\u{201d}: Typo for \u{201c}y\u{201d}?")], expected: nil))
    // MessageEmitterAdapter.DEFAULT_FILTER_STRINGS.
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.error("CSS: Property \u{201c}scale\u{201d} doesn't exist.")], expected: nil))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.error("Stray end tag \u{201c}li\u{201d}.")], expected: nil))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.warning("Section lacks heading.")], expected: nil))
    // role="directory" is printed as a warning, so it fails a valid file too.
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.warning("Bad value \u{201c}directory\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}ul\u{201d}.")], expected: nil))
}

@Test func missingLangWarningOnlyCountsInMissingLangFixtures() {
    let warning = ValidationMessage.warning("Consider adding a \u{201c}lang\u{201d} attribute to the \u{201c}html\u{201d} start tag to declare the language of this document.")
    #expect(nil == UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/a/x-isvalid.html", category: .valid), messages: [warning], expected: nil))
    // TestRunner tests the file name, not the directory.
    #expect(nil == UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/missing-lang/x-isvalid.html", category: .valid), messages: [warning], expected: nil))
    #expect(nil != UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/a/missing-lang-isvalid.html", category: .valid), messages: [warning], expected: nil))
}

@Test func invalidFixturesCompareTheFirstErrorExactly() {
    let fixture = UpstreamFixture(path: "html/x-novalid.html", category: .invalid)
    let expected = "Stray end tag \u{201c}li\u{201d}."
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.warning("Section lacks heading."), .error(expected), .error("Other.")], expected: expected))
    // The old harness accepted the expected message anywhere, and substrings.
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.error("Other."), .error(expected)], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.error("Stray end tag \u{201c}li\u{201d}. More.")], expected: expected))
    // Curly quotes are not folded.
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.error("Stray end tag \"li\".")], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.warning(expected)], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.error(expected)], expected: nil))
}

@Test func invalidFixtureCanBeMatchedByRoleDirectoryButStillNeedsAnError() {
    let fixture = UpstreamFixture(path: "html/x-novalid.html", category: .invalid)
    let role = "Bad value \u{201c}directory\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}ul\u{201d}."
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.warning(role), .error("Other.")], expected: role))
    #expect("Expected an error but did not encounter any." == UpstreamRulesHarness.failure(for: fixture, messages: [.warning(role)], expected: role))
}

@Test func upstreamMessageComparisonFollowsTestRunnerMessageMatches() {
    // \p{C} becomes "?" on both sides.
    #expect(UpstreamRulesHarness.upstreamMessageMatches(reported: "Bad \u{0001} char", expected: "Bad \u{0002} char"))
    #expect(UpstreamRulesHarness.upstreamMessageMatches(reported: "Zero\u{200b}width", expected: "Zero?width"))
    // Java's String.equals doesn't equate canonically equivalent text.
    #expect(!UpstreamRulesHarness.upstreamMessageMatches(reported: "caf\u{e9}", expected: "cafe\u{301}"))
    // The datetime parts are reordered on both sides.
    #expect(UpstreamRulesHarness.upstreamMessageMatches(
        reported: "Bad datetime with timezone: A. Bad date: B.",
        expected: "Bad date: B. Bad datetime with timezone: A."
    ))
}

@Test func hasWarningFixturesNeedAMatchingWarningAndNoErrors() {
    let fixture = UpstreamFixture(path: "html/x-haswarn.html", category: .hasWarning)
    let expected = "Section lacks heading."
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.info("I."), .warning(expected), .warning("Other.")], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.warning(expected), .error("E.")], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.warning("Other."), .warning(expected)], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.info(expected)], expected: expected))
}

@Test func hasInfoFixturesCompareTheFirstInfoWithoutNormalizing() {
    let fixture = UpstreamFixture(path: "html/x-hasinfo.html", category: .hasInfo)
    let typo = "Bad value \u{201c}alternat\u{201d}: Typo for \u{201c}alternate\u{201d}?"
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.info(typo)], expected: typo))
    // The port reports rel typos as info; vnu.jar's TestRunner sees an error.
    #expect(nil == UpstreamRulesHarness.failure(for: fixture, messages: [.error(typo)], expected: typo))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.info(typo), .warning("W.")], expected: typo))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [.info("A\u{0001}B")], expected: "A?B"))
    #expect(nil != UpstreamRulesHarness.failure(for: fixture, messages: [], expected: typo))
}

@Test func upstreamRulesRunChecksRealFixturesAndReplays() throws {
    let root = try temporaryFixtures(name: "upstream-run")
    try writeFile(root: root, relativePath: "html/ok-isvalid.html", contents: "<!DOCTYPE html><html lang=\"en\"><head><title>T</title></head><body><ul><li>A<li>B</ul></body></html>")
    try writeFile(root: root, relativePath: "html/stray-novalid.html", contents: "<!DOCTYPE html><html lang=\"en\"><head><title>T</title></head><body></span></body></html>")
    let messagesPath = root.appendingPathComponent("messages.json")
    try writeJSON(["html/stray-novalid.html": "Stray end tag \u{201c}span\u{201d}."], to: messagesPath)
    let configuration = UpstreamRulesConfiguration(messagesPath: messagesPath, fixturesRoot: root, ignore: [], filter: nil, limit: nil, replayPath: nil)

    let run = try UpstreamRulesHarness().run(configuration: configuration, willCheck: nil)
    // Computed outside #expect: its expansion treats rethrowing calls as throwing.
    let allPassed = run.results.allSatisfy { $0.passed }
    #expect(!run.isPartial)
    #expect(2 == run.results.count)
    #expect(allPassed)

    // Replaying recorded messages scores them instead; a fixture without a
    // record fails.
    let replayPath = root.appendingPathComponent("replay.jsonl")
    let record = UpstreamReplayRecord(path: "html/ok-isvalid.html", messages: [.error("Recorded error.")])
    try Data((String(decoding: try JSONEncoder().encode(record), as: UTF8.self) + "\n").utf8).write(to: replayPath)
    var replaying = configuration
    replaying.replayPath = replayPath
    let replayed = try UpstreamRulesHarness().run(configuration: replaying, willCheck: nil)
    let failures = replayed.results.map { $0.failure ?? "" }
    #expect(["Expected no errors or warnings but encountered error \u{201c}Recorded error.\u{201d}.", "No replayed messages for this fixture."] == failures)
}

private func ratchetRun(_ results: [(String, UpstreamFixtureCategory, Bool)], isPartial: Bool) -> UpstreamRulesRun {
    UpstreamRulesRun(
        results: results.map { UpstreamFixtureResult(path: $0.0, category: $0.1, passed: $0.2, failure: $0.2 ? nil : "F \($0.0)") },
        isPartial: isPartial
    )
}

@Test func ratchetReportsNewStaleAndMissingFailuresAndPassCountDrops() throws {
    let baseRun = ratchetRun([("a", .valid, true), ("b", .valid, false), ("c", .invalid, false), ("d", .invalid, true)], isPartial: false)
    let list = try UpstreamRatchet.initialList(from: baseRun)
    #expect(2 == list.failures.count)
    #expect(1 == list.passCounts["valid"])
    #expect(!UpstreamRatchet.compare(baseRun, with: list).hasFailures)

    // a now fails (new), b now passes (stale), c is gone (missing), and
    // d moving away drops the invalid pass count.
    let later = ratchetRun([("a", .valid, false), ("b", .valid, true)], isPartial: false)
    let report = UpstreamRatchet.compare(later, with: list)
    #expect(["a"] == report.newFailures.map(\.path))
    #expect(["b"] == report.nowPassing.map(\.path))
    #expect(["c"] == report.missingEntries)
    #expect([UpstreamCountDrop(category: .invalid, recorded: 1, current: 0)] == report.passCountDrops)
    #expect(report.hasFailures)

    // A partial run can't speak for the fixtures it skipped.
    let partial = UpstreamRatchet.compare(ratchetRun([("b", .valid, false)], isPartial: true), with: list)
    #expect(!partial.hasFailures)
}

@Test func ratchetUpdateOnlyShrinksUnlessFailuresAreAccepted() throws {
    let list = try UpstreamRatchet.initialList(from: ratchetRun([("a", .valid, true), ("b", .valid, false), ("c", .valid, false)], isPartial: false))
    let later = ratchetRun([("a", .valid, false), ("b", .valid, true), ("c", .valid, false)], isPartial: false)

    #expect(throws: UpstreamRatchetError.self) {
        try UpstreamRatchet.updating(list, with: later, accepting: [], allowingRemovedFixtures: false)
    }
    #expect(throws: UpstreamRatchetError.self) {
        try UpstreamRatchet.updating(list, with: later, accepting: ["a", "b"], allowingRemovedFixtures: false)
    }
    #expect(throws: UpstreamRatchetError.self) {
        try UpstreamRatchet.updating(list, with: ratchetRun([("a", .valid, true)], isPartial: true), accepting: [], allowingRemovedFixtures: false)
    }

    let update = try UpstreamRatchet.updating(list, with: later, accepting: ["a"], allowingRemovedFixtures: false)
    #expect(["a"] == update.added)
    #expect(["b"] == update.removed)
    #expect(Set(["a", "c"]) == Set(update.list.failures.keys))
}

@Test func ratchetUpdateRefusesUnexplainedPassCountDrops() throws {
    let list = try UpstreamRatchet.initialList(from: ratchetRun([("a", .valid, true), ("b", .valid, true), ("c", .valid, false)], isPartial: false))
    // b disappeared while passing: nothing accepted explains the drop.
    let later = ratchetRun([("a", .valid, true), ("c", .valid, false)], isPartial: false)

    #expect(throws: UpstreamRatchetError.self) {
        try UpstreamRatchet.updating(list, with: later, accepting: [], allowingRemovedFixtures: false)
    }
    let update = try UpstreamRatchet.updating(list, with: later, accepting: [], allowingRemovedFixtures: true)
    #expect(1 == update.list.passCounts["valid"])
    #expect(2 == update.list.fixtureCounts["valid"])
}

// MARK: - Fixes from the U0 review

// Datatype warnings (e.g. a deprecated language subtag) reach TestRunner
// through error(): the exception when first in an invalid or haswarn file,
// an error (inError) anywhere else. These pairs were checked against
// vnu.jar's TestRunner on equivalent fixtures.
private let datatypeWarning = ValidationMessage.warning("Bad value \u{201c}mo\u{201d} for attribute \u{201c}lang\u{201d} on element \u{201c}span\u{201d}.")
private let roleDirectory = ValidationMessage.warning("Bad value \u{201c}directory\u{201d} for attribute \u{201c}role\u{201d} on element \u{201c}ul\u{201d}.")

@Test func datatypeWarningsFollowTestRunnersErrorPath() {
    let invalid = UpstreamFixture(path: "html/x-novalid.html", category: .invalid)
    let hasWarning = UpstreamFixture(path: "html/x-haswarn.html", category: .hasWarning)
    // First in an invalid file: it is the compared exception...
    #expect(nil == UpstreamRulesHarness.failure(for: invalid, messages: [datatypeWarning, .error("E.")], expected: datatypeWarning.message))
    // ...and after role="directory" it supplies the error the file needs.
    #expect(nil == UpstreamRulesHarness.failure(for: invalid, messages: [roleDirectory, datatypeWarning], expected: roleDirectory.message))
    #expect(nil == UpstreamRulesHarness.failure(for: hasWarning, messages: [datatypeWarning], expected: datatypeWarning.message))
    // Not first in a haswarn file: an error.
    #expect(nil != UpstreamRulesHarness.failure(for: hasWarning, messages: [datatypeWarning, datatypeWarning], expected: datatypeWarning.message))
    #expect(nil != UpstreamRulesHarness.failure(for: hasWarning, messages: [.warning("W."), datatypeWarning], expected: "W."))
    // sandbox is an ordinary datatype, so its warning behaves the same.
    let sandbox = ValidationMessage.warning("Bad value \u{201c}allow-scripts allow-same-origin\u{201d} for attribute \u{201c}sandbox\u{201d} on element \u{201c}iframe\u{201d}.")
    #expect(nil == UpstreamRulesHarness.failure(for: hasWarning, messages: [sandbox], expected: sandbox.message))
}

@Test func textContentWarningCountsAsAnError() {
    // TextContentChecker raises it as a DatatypeMismatchException through
    // error(), which always sets TestRunner's inError.
    let hasWarning = UpstreamFixture(path: "html/x-haswarn.html", category: .hasWarning)
    let textContent = ValidationMessage.warning("Double-check the text content of element \u{201c}time\u{201d}: Year may be mistyped.")
    #expect(nil != UpstreamRulesHarness.failure(for: hasWarning, messages: [textContent], expected: textContent.message))
    // A meta content (CSP) bad-value warning is an ordinary datatype warning.
    let csp = ValidationMessage.warning("Bad value \u{201c}default-src 'self'; x 'none'\u{201d} for attribute \u{201c}content\u{201d} on element \u{201c}meta\u{201d}.")
    #expect(nil == UpstreamRulesHarness.failure(for: hasWarning, messages: [csp], expected: csp.message))
}

@Test func trailingSlashInfoIsAWarningToTestRunner() {
    // TreeBuilder raises it through warn(); vnu.jar only displays it as info.
    let trailingSlash = ValidationMessage.info("Trailing slash on void elements has no effect and interacts badly with unquoted attribute values.")
    #expect(nil != UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/x-isvalid.html", category: .valid), messages: [trailingSlash], expected: nil))
    #expect(nil != UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/x-hasinfo.html", category: .hasInfo), messages: [.info("I."), trailingSlash], expected: "I."))
}

@Test func nonDocumentErrorFailsEveryCategory() {
    let exception = ValidationMessage.nonDocumentError("Internal error.")
    let expected = "Stray end tag \u{201c}li\u{201d}."
    #expect(nil != UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/x-novalid.html", category: .invalid), messages: [.error(expected), exception], expected: expected))
    #expect(nil != UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/x-isvalid.html", category: .valid), messages: [exception], expected: nil))
}

@Test func filterUsesJavaRegexSemantics() {
    #expect(UpstreamRulesHarness.isFiltered("CSS: Property \u{201c}scale\u{201d} doesn't exist."))
    // Java's "." doesn't cross a line break, and Matcher.matches() needs the
    // whole message, so a second line doesn't make it match.
    #expect(!UpstreamRulesHarness.isFiltered("First line.\nCSS: Property \u{201c}scale\u{201d} doesn't exist."))
    // Java's "\s" is ASCII-only.
    #expect(UpstreamRulesHarness.isFiltered("Use \u{201c}report-uri\u{201d} in favour of a new \u{201c}report-to\u{201d}."))
    #expect(!UpstreamRulesHarness.isFiltered("Use\u{a0}\u{201c}report-uri\u{201d} in favour of a new \u{201c}report-to\u{201d}."))
    // warning()'s XML 1.0 filter.
    #expect(nil == UpstreamRulesHarness.failure(for: UpstreamFixture(path: "html/x-isvalid.html", category: .valid), messages: [.warning("The name \u{201c}x:y\u{201d} is not serializable as XML 1.0.")], expected: nil))
}

@Test func upstreamKeyQuotesLikeFileToURI() {
    #expect("html/a%20b-novalid.html" == UpstreamFixture.upstreamKey(for: "html/a b-novalid.html"))
    #expect("html/%23x%25y-isvalid.html" == UpstreamFixture.upstreamKey(for: "html/#x%y-isvalid.html"))
    #expect("html/caf\u{e9}-isvalid.html" == UpstreamFixture.upstreamKey(for: "html/caf\u{e9}-isvalid.html"))
    #expect("html/a%C2%A0b.html" == UpstreamFixture.upstreamKey(for: "html/a\u{a0}b.html"))
    #expect("html/(a)!~*';:@&=+$,.html" == UpstreamFixture.upstreamKey(for: "html/(a)!~*';:@&=+$,.html"))
}

@Test func nestedDirectoriesKeepTheForcedCategoryAndOddFilesAreSkipped() throws {
    let root = try temporaryFixtures(name: "nested")
    try writeFile(root: root, relativePath: "html/invalid/sub/x-isvalid.html", contents: "x")
    try writeFile(root: root, relativePath: "html/valid/sub/x-novalid.html", contents: "x")
    // A dangling symlink isn't a regular file (Java's File.isFile()).
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("html/dangling-isvalid.html").path, withDestinationPath: "/nonexistent/target.html")

    let fixtures = try UpstreamRulesHarness().fixtures(under: root, ignoring: [])

    #expect([
        UpstreamFixture(path: "html/invalid/sub/x-isvalid.html", category: .invalid),
        UpstreamFixture(path: "html/valid/sub/x-novalid.html", category: .valid),
    ] == fixtures)
}

@Test func anyIgnoreFilterOrLimitMakesARunPartial() {
    let base = UpstreamRulesConfiguration(messagesPath: URL(fileURLWithPath: "/m.json"), fixturesRoot: URL(fileURLWithPath: "/t"), ignore: [], filter: nil, limit: nil, replayPath: nil)
    #expect(!base.isPartial)
    var ignoring = base
    ignoring.ignore = ["html-its"]
    #expect(ignoring.isPartial)
    var filtering = base
    filtering.filter = "meter"
    #expect(filtering.isPartial)
    var limiting = base
    limiting.limit = 10
    #expect(limiting.isPartial)
}

@Test func harnessRefusesBaselineUpdateWithLimit() throws {
    let fixtureRoot = try temporaryFixtures(name: "limit-update")
    let messagePath = try writeFixture(
        root: fixtureRoot,
        relativePath: "html/parser/stray-end-tag-novalid.html",
        contents: "<!DOCTYPE html><html lang=\"en\"><head><title>Test</title></head><body></span></body></html>",
        expectedMessage: "Stray end tag \u{201c}span\u{201d}."
    )
    #expect(throws: ParityHarnessError.self) {
        try ParityHarness().run(configuration: ParityConfiguration(messagesPath: messagePath, fixturesRoot: fixtureRoot, baselinePath: fixtureRoot.appendingPathComponent("b.json"), limit: 1, updateBaseline: true))
    }
}

@Test func ratchetUpdateAcceptsAFixtureThatUsedToPass() throws {
    // The ordinary "accept a regression" path: a passing fixture now fails
    // and nothing else changes; --accept for it is enough.
    let list = try UpstreamRatchet.initialList(from: ratchetRun([("a", .valid, true), ("b", .valid, false)], isPartial: false))
    let later = ratchetRun([("a", .valid, false), ("b", .valid, false)], isPartial: false)

    let update = try UpstreamRatchet.updating(list, with: later, accepting: ["a"], allowingRemovedFixtures: false)

    #expect(["a"] == update.added)
    #expect(0 == update.list.passCounts["valid"])
}

@Test func ratchetReportsChangedFailureReasonsWithoutFailing() throws {
    let list = try UpstreamRatchet.initialList(from: ratchetRun([("a", .valid, false)], isPartial: false))
    let later = UpstreamRulesRun(results: [UpstreamFixtureResult(path: "a", category: .valid, passed: false, failure: "Different.")], isPartial: false)

    let report = UpstreamRatchet.compare(later, with: list)

    #expect(["a"] == report.changedFailures.map(\.path))
    #expect(!report.hasFailures)
}

@Test func knownFailureListCountsAreValidatedOnLoad() throws {
    let root = try temporaryFixtures(name: "list-validation")
    let path = root.appendingPathComponent("list.json")
    let good = try UpstreamRatchet.initialList(from: ratchetRun([("a", .valid, true)], isPartial: false))
    try good.write(to: path)
    #expect(good == (try UpstreamKnownFailures.load(from: path)))

    var misspelled = good
    misspelled.passCounts["valdi"] = misspelled.passCounts.removeValue(forKey: "valid")
    try misspelled.write(to: path)
    #expect(throws: UpstreamRatchetError.self) {
        try UpstreamKnownFailures.load(from: path)
    }

    var negative = good
    negative.fixtureCounts["invalid"] = -1
    try negative.write(to: path)
    #expect(throws: UpstreamRatchetError.self) {
        try UpstreamKnownFailures.load(from: path)
    }
}

@Test func replayFilesMayUseCRLFButNotRepeatAPath() throws {
    let root = try temporaryFixtures(name: "replay-format")
    try writeFile(root: root, relativePath: "html/ok-isvalid.html", contents: "x")
    let messagesPath = root.appendingPathComponent("messages.json")
    try writeJSON([String: String](), to: messagesPath)
    let record = String(decoding: try JSONEncoder().encode(UpstreamReplayRecord(path: "html/ok-isvalid.html", messages: [])), as: UTF8.self)
    var configuration = UpstreamRulesConfiguration(messagesPath: messagesPath, fixturesRoot: root, ignore: [], filter: nil, limit: nil, replayPath: root.appendingPathComponent("replay.jsonl"))

    try Data((record + "\r\n").utf8).write(to: configuration.replayPath!)
    let run = try UpstreamRulesHarness().run(configuration: configuration, willCheck: nil)
    let passed = run.results.map(\.passed)
    #expect([true] == passed)

    configuration.replayPath = root.appendingPathComponent("duplicate.jsonl")
    try Data((record + "\n" + record + "\n").utf8).write(to: configuration.replayPath!)
    #expect(throws: UpstreamRulesError.self) {
        try UpstreamRulesHarness().run(configuration: configuration, willCheck: nil)
    }
}

private func writeFile(root: URL, relativePath: String, contents: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

private func temporaryFixtures(name: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vnu-parity-tests")
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult
private func writeFixture(
    root: URL,
    relativePath: String,
    contents: String,
    expectedMessage: String
) throws -> URL {
    let fixtureURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: fixtureURL)
    let messagesURL = root.appendingPathComponent("messages.json")
    try writeJSON([relativePath: expectedMessage], to: messagesURL)
    return messagesURL
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}
