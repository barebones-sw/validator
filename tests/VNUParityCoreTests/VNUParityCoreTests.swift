import Foundation
import Testing
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
