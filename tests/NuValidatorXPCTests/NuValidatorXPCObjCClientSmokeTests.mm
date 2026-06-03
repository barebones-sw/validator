#import <XCTest/XCTest.h>
#import "VNUValidatorXPC.h"

@interface NuValidatorXPCObjCClientSmokeTests : XCTestCase
@end

@implementation NuValidatorXPCObjCClientSmokeTests

- (void)testObjectiveCClientReceivesValidatorJSON
{
    NSXPCConnection *connection =
        [[NSXPCConnection alloc] initWithServiceName:VNUValidatorXPCServiceIdentifier];
    connection.remoteObjectInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(VNUValidatorXPCChecking)];
    [connection resume];

    XCTestExpectation *expectation = [self expectationWithDescription:@"validator XPC reply"];
    __block NSString *replyJSON = nil;
    __block NSError *replyError = nil;
    __block BOOL didFinish = NO;
    void (^finish)(void) = ^{
        if (!didFinish) {
            didFinish = YES;
            [expectation fulfill];
        }
    };

    id<VNUValidatorXPCChecking> checker =
        [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            replyError = error;
            finish();
        }];

    [checker checkSource:@"<!doctype html><title>xpc objc</title>"
                filename:@"objc-smoke.html"
             contentType:@"text/html; charset=utf-8"
                 options:@{ VNUValidatorXPCOptionShowSource: @YES }
               withReply:^(NSString *json, NSError *error) {
                   replyJSON = json;
                   replyError = error;
                   finish();
               }];

    [self waitForExpectations:@[expectation] timeout:10.0];
    [connection invalidate];

    XCTAssertNil(replyError);
    XCTAssertNotNil(replyJSON);

    NSData *jsonData = [replyJSON dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNotNil(jsonData);
    if (jsonData == nil) {
        return;
    }

    NSError *jsonError = nil;
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:jsonData
                                                             options:0
                                                               error:&jsonError];
    XCTAssertNil(jsonError);
    XCTAssertTrue([response isKindOfClass:[NSDictionary class]]);
    if (![response isKindOfClass:[NSDictionary class]]) {
        return;
    }
    XCTAssertEqualObjects(response[@"url"], @"objc-smoke.html");
    XCTAssertNotNil(response[@"source"]);

    NSArray *messages = response[@"messages"];
    XCTAssertTrue([messages isKindOfClass:[NSArray class]]);
    XCTAssertTrue([messages count] > 0);
    if (![messages isKindOfClass:[NSArray class]] || [messages count] == 0) {
        return;
    }
    NSDictionary *firstMessage = messages.firstObject;
    XCTAssertEqualObjects(firstMessage[@"subType"], @"warning");
}

@end
