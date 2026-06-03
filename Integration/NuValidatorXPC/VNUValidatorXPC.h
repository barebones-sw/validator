#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define VNUValidatorXPCServiceIdentifier @"com.barebones.nu-validator-swift.xpc"

#define VNUValidatorXPCOptionShowSource @"showsource"
#define VNUValidatorXPCOptionASCIIQuotes @"asciiquotes"
#define VNUValidatorXPCOptionParser @"parser"
#define VNUValidatorXPCOptionLevel @"level"

@protocol VNUValidatorXPCChecking

- (void)checkSource:(NSString *)source
           filename:(nullable NSString *)filename
        contentType:(nullable NSString *)contentType
            options:(NSDictionary<NSString *, id> *)options
          withReply:(void (^)(NSString *_Nullable json, NSError *_Nullable error))reply;

@end

NS_ASSUME_NONNULL_END
