import Foundation

public enum ValidationJSON {
    public static func encode(_ result: ValidationResult) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(result)) ?? Data(#"{"messages":[]}"#.utf8)
    }
}
