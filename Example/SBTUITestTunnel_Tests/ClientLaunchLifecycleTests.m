@import XCTest;
@import SBTUITestTunnelClient;
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>

@interface SBTUITestTunnelClient (LifecycleTesting)
- (BOOL)usesIPCTunnel;
@end

@interface SBTLaunchTestApplication : NSObject
@property (nonatomic, copy) NSArray *launchArguments;
@property (nonatomic, copy) NSDictionary *launchEnvironment;
@end
@implementation SBTLaunchTestApplication
@end

// This client uses the real HTTP probe and command path, with a fixture native
// launcher instead of XCUIApplication so installation delay is deterministic.
@interface SBTLaunchHTTPTestClient : SBTUITestTunnelClient
@end
@implementation SBTLaunchHTTPTestClient
- (BOOL)usesIPCTunnel { return NO; }
@end

@interface SBTLaunchHTTPServer : NSObject
@property (nonatomic, strong) dispatch_source_t source;
@property (nonatomic, assign) NSTimeInterval responseDelay;
- (BOOL)startOnPort:(NSInteger)port;
- (void)stop;
@end
@implementation SBTLaunchHTTPServer
- (BOOL)startOnPort:(NSInteger)port
{
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) { return NO; }
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(listener, 16) < 0) {
        close(listener);
        return NO;
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{SBTUITunnelResponseResultKey: @"YES"} options:0 error:nil];
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)body.length];
    NSMutableData *response = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:body];
    self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, listener, 0, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    NSTimeInterval responseDelay = self.responseDelay;
    dispatch_source_set_event_handler(self.source, ^{
        int connection = accept(listener, NULL, NULL);
        if (connection < 0) { return; }
        struct timeval timeout = {.tv_sec = 1};
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        int noSignal = 1;
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        char buffer[4096];
        if (recv(connection, buffer, sizeof(buffer), 0) > 0) {
            [NSThread sleepForTimeInterval:responseDelay];
            send(connection, response.bytes, response.length, 0);
        }
        close(connection);
    });
    dispatch_source_set_cancel_handler(self.source, ^{ close(listener); });
    dispatch_resume(self.source);
    return YES;
}
- (void)stop
{
    if (self.source) {
        dispatch_source_cancel(self.source);
        self.source = nil;
    }
}
- (void)dealloc { [self stop]; }
@end

@interface SBTLaunchTestDelegate : NSObject <SBTUITestTunnelClientDelegate>
@property (nonatomic, copy) void (^launchAction)(SBTUITestTunnelClient *);
@property (nonatomic, strong) NSMutableArray<NSError *> *errors;
@property (nonatomic, assign) BOOL shutdownOnMainThread;
@end
@implementation SBTLaunchTestDelegate
- (void)tunnelClientIsReadyToLaunch:(SBTUITestTunnelClient *)sender
{
    if (self.launchAction) { self.launchAction(sender); }
}
- (void)tunnelClient:(SBTUITestTunnelClient *)sender didShutdownWithError:(NSError *)error
{
    if (error) {
        self.shutdownOnMainThread = NSThread.isMainThread;
        [self.errors addObject:error];
    }
}
@end

@interface ClientLaunchLifecycleTests : XCTestCase
@property (nonatomic, strong) SBTLaunchTestApplication *application;
@property (nonatomic, strong) SBTLaunchHTTPTestClient *client;
@property (nonatomic, strong) SBTLaunchTestDelegate *launchDelegate;
@end

@implementation ClientLaunchLifecycleTests
- (void)setUp
{
    [super setUp];
    [SBTUITestTunnelClient setConnectionTimeout:6.0];
    self.application = [SBTLaunchTestApplication new];
    self.application.launchArguments = @[@"original"];
    self.application.launchEnvironment = @{@"original": @"value"};
    self.client = [[SBTLaunchHTTPTestClient alloc] initWithApplication:(XCUIApplication *)self.application];
    self.launchDelegate = [SBTLaunchTestDelegate new];
    self.launchDelegate.errors = [NSMutableArray new];
    self.client.delegate = self.launchDelegate;
}
- (void)tearDown
{
    [self.client terminate];
    [SBTUITestTunnelClient setConnectionTimeout:30.0];
    [super tearDown];
}
- (void)runLoopFor:(NSTimeInterval)seconds
{
    NSTimeInterval end = NSProcessInfo.processInfo.systemUptime + seconds;
    while (NSProcessInfo.processInfo.systemUptime < end) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}
- (void)runLoopUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout
{
    NSTimeInterval end = NSProcessInfo.processInfo.systemUptime + timeout;
    while (!condition() && NSProcessInfo.processInfo.systemUptime < end) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}
- (void)testCompletedHandshakeSurvivesSlowNativeLaunchReturn
{
    SBTLaunchHTTPServer *server = [SBTLaunchHTTPServer new];
    __block NSUInteger startupCalls = 0;
    __weak typeof(self) weakSelf = self;
    self.launchDelegate.launchAction = ^(SBTUITestTunnelClient *sender) {
        NSInteger port = [weakSelf.application.launchEnvironment[SBTUITunneledApplicationLaunchEnvironmentPortKey] integerValue];
        XCTAssertTrue([server startOnPort:port]);
        [weakSelf runLoopFor:7.0];
        XCTAssertEqual(startupCalls, 1u);
    };
    [self.client launchTunnelWithStartupBlock:^{ startupCalls++; }];
    XCTAssertEqual(self.launchDelegate.errors.count, 0u);
    [server stop];
}
- (void)testRealHTTPHandshakeAfterNativeLaunchExceedsConnectionTimeout
{
    SBTLaunchHTTPTestClient *client = [[SBTLaunchHTTPTestClient alloc] initWithApplication:(XCUIApplication *)self.application];
    client.delegate = self.launchDelegate;
    SBTLaunchHTTPServer *server = [SBTLaunchHTTPServer new];
    __block NSUInteger startupCalls = 0;
    __weak typeof(self) weakSelf = self;
    self.launchDelegate.launchAction = ^(SBTUITestTunnelClient *sender) {
        NSInteger port = [weakSelf.application.launchEnvironment[SBTUITunneledApplicationLaunchEnvironmentPortKey] integerValue];
        // Exceed both the configured budget and the old two-second polling
        // delay, so the old SDK resets its port while native launch is pending.
        [weakSelf runLoopFor:9.0];
        XCTAssertTrue([server startOnPort:port]);
        [weakSelf runLoopUntil:^BOOL{ return startupCalls == 1; } timeout:3.0];
        XCTAssertEqual(startupCalls, 1u);
    };
    @try {
        [client launchTunnelWithStartupBlock:^{ startupCalls++; }];
        XCTAssertEqual(self.launchDelegate.errors.count, 0u);
        XCTAssertEqual(startupCalls, 1u);
    } @finally {
        [client terminate];
        [server stop];
    }
}
- (void)testUnavailableServerStillTimesOutAfterNativeLaunch
{
    __weak typeof(self) weakSelf = self;
    self.launchDelegate.launchAction = ^(SBTUITestTunnelClient *sender) { [weakSelf runLoopFor:3.0]; };
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    [self.client launchTunnel];
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
    XCTAssertGreaterThanOrEqual(elapsed, 9.0);
    XCTAssertLessThan(elapsed, 10.5);
    XCTAssertEqual(self.launchDelegate.errors.count, 1u);
    XCTAssertTrue(self.launchDelegate.shutdownOnMainThread);
    XCTAssertEqualObjects(self.application.launchArguments, (@[@"original"]));
    XCTAssertEqualObjects(self.application.launchEnvironment, (@{@"original": @"value"}));
    [self runLoopFor:1.0];
    XCTAssertEqual(self.launchDelegate.errors.count, 1u);
}
- (void)testNativeLaunchExceptionCancelsPolling
{
    NSException *original = [NSException exceptionWithName:@"NativeLaunchFailure" reason:@"fixture" userInfo:nil];
    self.launchDelegate.launchAction = ^(SBTUITestTunnelClient *sender) { @throw original; };
    @try {
        [self.client launchTunnel];
        XCTFail(@"Native launch should throw");
    } @catch (NSException *exception) {
        XCTAssertEqual(exception, original);
    }
    XCTAssertNil([self.client valueForKey:@"launchState"]);
    XCTAssertEqualObjects(self.application.launchEnvironment, (@{@"original": @"value"}));
    [self runLoopFor:2.5];
    XCTAssertEqual(self.launchDelegate.errors.count, 0u);
}
- (void)testDefaultShutdownHandlerFailsWithAssertionsDisabled
{
    SEL selector = @selector(tunnelClient:didShutdownWithError:);
    void (*shutdown)(id, SEL, SBTUITestTunnelClient *, NSError *) =
        (void *)class_getMethodImplementation(SBTUITunneledApplication.class, selector);
    NSError *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Tunnel unavailable"}];
    XCTAssertThrowsSpecificNamed(shutdown([NSObject new], selector, self.client, error), NSException, NSInternalInconsistencyException);
}
@end
