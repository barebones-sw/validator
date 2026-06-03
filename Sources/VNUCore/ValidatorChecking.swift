import Foundation

public protocol ValidatorChecking: Sendable {
    func check(input: DocumentInput, options: CheckerOptions) -> ValidationResult
}
