import Foundation

enum ValidatorXPC {
    static let serviceIdentifier = "com.barebones.nu-validator-swift.xpc"
    static let errorDomain = "com.barebones.nu-validator-swift.xpc.error"

    static func interface() -> NSXPCInterface {
        NSXPCInterface(with: ValidatorXPCChecking.self)
    }
}

@objc(VNUValidatorXPCChecking)
protocol ValidatorXPCChecking {
    func checkSource(
        _ source: NSString,
        filename: NSString?,
        contentType: NSString?,
        options: NSDictionary,
        withReply reply: @escaping (NSString?, NSError?) -> Void
    )
}
