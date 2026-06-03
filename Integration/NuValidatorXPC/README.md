# NuValidator XPC Integration

`NuValidatorXPC.xpc` is the app-embedded checker endpoint intended for BBEdit-style clients. It accepts already-loaded document source, validates it with the Swift checker in an XPC service process, and replies with the same JSON shape returned by the HTTP API.

The service identifier is:

```objc
@"com.barebones.nu-validator-swift.xpc"
```

## Embedding

For an app-hosted client, build the `NuValidatorXPC` target and embed the resulting service in the host app:

```text
Host.app/Contents/XPCServices/NuValidatorXPC.xpc
```

The service target embeds `VNUSwiftCore.framework` and the small shared `VNUCore.framework` in its own `Contents/Frameworks` directory, so the host app does not need to link either validator framework. `VNUServiceCore.framework` is only needed by apps that vend the HTTP API; BBEdit-style XPC clients do not need it.

In Xcode, add a Copy Files phase to the host app target:

```text
Destination: Wrapper
Subpath:     $(CONTENTS_FOLDER_PATH)/XPCServices
File:        NuValidatorXPC.xpc
Options:     Code Sign On Copy
```

The host app should include `VNUValidatorXPC.h` and use the protocol declared there when creating the remote object interface.

## Calling

```objc
#import "VNUValidatorXPC.h"

NSXPCConnection *connection =
    [[NSXPCConnection alloc] initWithServiceName:VNUValidatorXPCServiceIdentifier];
connection.remoteObjectInterface =
    [NSXPCInterface interfaceWithProtocol:@protocol(VNUValidatorXPCChecking)];
[connection resume];

id<VNUValidatorXPCChecking> checker =
    [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        // Present or log the connection error.
    }];

[checker checkSource:sourceString
             filename:displayFilename
          contentType:@"text/html; charset=utf-8"
              options:@{ VNUValidatorXPCOptionShowSource: @YES }
            withReply:^(NSString *json, NSError *error) {
                // Parse json as the normal Nu Validator JSON response.
            }];
```

The service always replies with JSON. Supported option keys are:

```text
showsource      YES/"yes" includes the source object in JSON output.
asciiquotes     YES/"yes" renders ASCII quotes in generated messages.
parser          "html", "xml", or "xmldtd".
level           "warning" or "error" to filter lower-severity messages.
```

`filename` is optional and is echoed as the result URL/display name. `contentType` is optional; if omitted, the service uses `text/html; charset=utf-8`.
