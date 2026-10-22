// ClientLaunchFixture.m
//
// Copyright (C) 2026 Subito.it S.r.l (www.subito.it)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "ClientLaunchFixture.h"
#import <objc/runtime.h>

@interface HTTPLaunchTestClient : SBTUITestTunnelClient
@end
@implementation HTTPLaunchTestClient
- (BOOL)usesIPCTunnel { return NO; }
@end

static NSException *CatchException(void (^block)(void))
{
    @try { block(); }
    @catch (NSException *exception) { return exception; }
    return nil;
}

@interface ClientLaunchFixture () <SBTUITestTunnelClientDelegate>
@property (nonatomic, readwrite, strong) SBTUITestTunnelClient *client;
@property (nonatomic, readwrite, copy) NSArray<NSError *> *errors;
@property (nonatomic, readwrite) BOOL shutdownOnMainThread;
@end

@implementation ClientLaunchFixture
- (instancetype)init
{
    if ((self = [super init])) {
        _launchArguments = @[@"original"];
        _launchEnvironment = @{@"original": @"value"};
        _errors = @[];
        _client = [[HTTPLaunchTestClient alloc] initWithApplication:(XCUIApplication *)self];
        _client.delegate = self;
    }
    return self;
}
- (uint16_t)port
{
    return (uint16_t)[self.launchEnvironment[SBTUITunneledApplicationLaunchEnvironmentPortKey] integerValue];
}
- (void)tunnelClientIsReadyToLaunch:(SBTUITestTunnelClient *)sender
{
    if (self.nativeException) { @throw self.nativeException; }
    if (self.nativeLaunch) { self.nativeLaunch(); }
}
- (void)tunnelClient:(SBTUITestTunnelClient *)sender didShutdownWithError:(NSError *)error
{
    if (error) {
        self.shutdownOnMainThread = NSThread.isMainThread;
        self.errors = [self.errors arrayByAddingObject:error];
    }
}
- (NSException *)launchCatchingException
{
    return CatchException(^{ [self.client launchTunnel]; });
}
+ (NSException *)defaultShutdownExceptionForError:(NSError *)error
{
    // Invoke the actual delegate implementation without constructing an XCUIApplication.
    SEL selector = @selector(tunnelClient:didShutdownWithError:);
    void (*shutdown)(id, SEL, SBTUITestTunnelClient *, NSError *) =
        (void *)class_getMethodImplementation(SBTUITunneledApplication.class, selector);
    return CatchException(^{ shutdown([NSObject new], selector, nil, error); });
}
@end
