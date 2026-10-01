#import "streamdeck_plugin.h"
#import "media_controller.h"
#import "audio_controller.h"

static NSString * const kActionMicMute         = @"com.toumorokoshi.yftsandbox.micmute";
static NSString * const kActionTeamsMute       = @"com.toumorokoshi.yftsandbox.teamsmute";

static NSString * const kActionPlayPause       = @"com.toumorokoshi.yftsandbox.playpause";
static NSString * const kActionPlay            = @"com.toumorokoshi.yftsandbox.play";
static NSString * const kActionPause           = @"com.toumorokoshi.yftsandbox.pause";
static NSString * const kActionNext            = @"com.toumorokoshi.yftsandbox.next";
static NSString * const kActionPrevious        = @"com.toumorokoshi.yftsandbox.previous";

// Legacy aliases for backward compatibility
static NSString * const kActionPlayPauseLegacy = @"com.toumorokoshi.macosmedia.playpause";
static NSString * const kActionPlayLegacy      = @"com.toumorokoshi.macosmedia.play";
static NSString * const kActionPauseLegacy     = @"com.toumorokoshi.macosmedia.pause";
static NSString * const kActionNextLegacy      = @"com.toumorokoshi.macosmedia.next";
static NSString * const kActionPreviousLegacy  = @"com.toumorokoshi.macosmedia.previous";

@interface StreamDeckPlugin () <NSURLSessionWebSocketDelegate>

@property (nonatomic, assign) NSInteger port;
@property (nonatomic, copy) NSString *pluginUUID;
@property (nonatomic, copy) NSString *registerEvent;
@property (nonatomic, copy) NSString *infoJson;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *activePlayPauseContexts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *activeMicMuteContexts;

@end

@implementation StreamDeckPlugin

- (instancetype)initWithPort:(NSInteger)port
                  pluginUUID:(NSString *)pluginUUID
               registerEvent:(NSString *)registerEvent
                    infoJson:(NSString *)infoJson {
    self = [super init];
    if (self) {
        _port = port;
        _pluginUUID = [pluginUUID copy];
        _registerEvent = [registerEvent copy];
        _infoJson = [infoJson copy];
        _activePlayPauseContexts = [[NSMutableDictionary alloc] init];
        _activeMicMuteContexts = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)start {
    NSLog(@"[StreamDeckPlugin] Connecting to ws://127.0.0.1:%ld...", (long)self.port);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%ld", (long)self.port]];
    self.webSocketTask = [self.session webSocketTaskWithURL:url];
    [self.webSocketTask resume];

    // Send registration message
    [self sendRegistrationEvent];

    // Start listening for inbound messages
    [self listenForNextMessage];

    // Set up media playback state changed handler
    __weak typeof(self) weakSelf = self;
    [[MediaController sharedController] setPlaybackStateChangedHandler:^(BOOL isPlaying) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateAllPlayPauseContextsWithIsPlaying:isPlaying];
    }];

    // Set up audio input volume / mute state changed handler
    [[AudioController sharedController] setInputVolumeChangedHandler:^(float volume, BOOL isMuted) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateAllMicMuteContextsWithVolume:volume isMuted:isMuted];
    }];
}

- (void)sendRegistrationEvent {
    NSDictionary *reg = @{
        @"event": self.registerEvent,
        @"uuid": self.pluginUUID
    };
    [self sendJSON:reg];
    NSLog(@"[StreamDeckPlugin] Registered with event: %@, uuid: %@", self.registerEvent, self.pluginUUID);
}

- (void)sendJSON:(NSDictionary *)dict {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!data || error) {
        NSLog(@"[StreamDeckPlugin] Error serializing JSON: %@", error);
        return;
    }

    NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:jsonString];

    [self.webSocketTask sendMessage:message completionHandler:^(NSError * _Nullable sendError) {
        if (sendError) {
            NSLog(@"[StreamDeckPlugin] WebSocket send error: %@", sendError);
        }
    }];
}

- (void)listenForNextMessage {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            NSLog(@"[StreamDeckPlugin] WebSocket connection closed or error: %@", error.localizedDescription);
            exit(0);
        }

        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            [strongSelf handleIncomingMessageString:message.string];
        }

        // Keep listening
        [strongSelf listenForNextMessage];
    }];
}

- (void)handleIncomingMessageString:(NSString *)jsonString {
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSError *error = nil;
    NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!msg || error) {
        NSLog(@"[StreamDeckPlugin] Error parsing incoming JSON: %@", error);
        return;
    }

    NSString *event = msg[@"event"];
    NSString *action = msg[@"action"];
    NSString *context = msg[@"context"];
    NSDictionary *payload = msg[@"payload"];

    if ([event isEqualToString:@"willAppear"]) {
        [self handleWillAppearForAction:action context:context payload:payload];
    } else if ([event isEqualToString:@"willDisappear"]) {
        [self handleWillDisappearForAction:action context:context payload:payload];
    } else if ([event isEqualToString:@"keyDown"]) {
        [self handleKeyDownForAction:action context:context payload:payload];
    } else if ([event isEqualToString:@"keyUp"]) {
        [self handleKeyUpForAction:action context:context payload:payload];
    }
}

- (void)handleWillAppearForAction:(NSString *)action context:(NSString *)context payload:(NSDictionary *)payload {
    NSLog(@"[StreamDeckPlugin] Action willAppear: %@, context: %@", action, context);

    if ([action isEqualToString:kActionPlayPause] || [action isEqualToString:kActionPlayPauseLegacy]) {
        @synchronized (self.activePlayPauseContexts) {
            self.activePlayPauseContexts[context] = action;
        }

        // Sync initial media playback state
        [[MediaController sharedController] checkIsPlayingWithCompletion:^(BOOL isPlaying) {
            [self setState:(isPlaying ? 1 : 0) forContext:context];
        }];
    } else if ([action isEqualToString:kActionMicMute] || [action isEqualToString:kActionTeamsMute]) {
        @synchronized (self.activeMicMuteContexts) {
            self.activeMicMuteContexts[context] = action;
        }

        // State 0 = Muted (0%, mic_off, Red), State 1 = Live (100%/restored, mic_on, Green)
        float vol = [[AudioController sharedController] inputVolume];
        BOOL isMuted = [[AudioController sharedController] isMuted];
        NSInteger state = isMuted ? 0 : 1;
        NSString *title = isMuted ? @"0%" : [NSString stringWithFormat:@"%d%%", (int)round(vol * 100.0f)];
        [self setState:state forContext:context];
        [self setTitle:title forContext:context];
    }
}

- (void)handleWillDisappearForAction:(NSString *)action context:(NSString *)context payload:(NSDictionary *)payload {
    NSLog(@"[StreamDeckPlugin] Action willDisappear: %@, context: %@", action, context);

    if ([action isEqualToString:kActionPlayPause] || [action isEqualToString:kActionPlayPauseLegacy]) {
        @synchronized (self.activePlayPauseContexts) {
            [self.activePlayPauseContexts removeObjectForKey:context];
        }
    } else if ([action isEqualToString:kActionMicMute] || [action isEqualToString:kActionTeamsMute]) {
        @synchronized (self.activeMicMuteContexts) {
            [self.activeMicMuteContexts removeObjectForKey:context];
        }
    }
}

- (void)handleKeyDownForAction:(NSString *)action context:(NSString *)context payload:(NSDictionary *)payload {
    NSLog(@"[StreamDeckPlugin] Key down for action: %@", action);

    if ([action isEqualToString:kActionMicMute] || [action isEqualToString:kActionTeamsMute]) {
        [[AudioController sharedController] toggleMute];
    } else if ([action isEqualToString:kActionPlayPause] || [action isEqualToString:kActionPlayPauseLegacy]) {
        [[MediaController sharedController] togglePlayPause];
    } else if ([action isEqualToString:kActionPlay] || [action isEqualToString:kActionPlayLegacy]) {
        [[MediaController sharedController] play];
    } else if ([action isEqualToString:kActionPause] || [action isEqualToString:kActionPauseLegacy]) {
        [[MediaController sharedController] pause];
    } else if ([action isEqualToString:kActionNext] || [action isEqualToString:kActionNextLegacy]) {
        [[MediaController sharedController] nextTrack];
    } else if ([action isEqualToString:kActionPrevious] || [action isEqualToString:kActionPreviousLegacy]) {
        [[MediaController sharedController] previousTrack];
    }
}

- (void)handleKeyUpForAction:(NSString *)action context:(NSString *)context payload:(NSDictionary *)payload {
    // KeyUp event handled if needed
}

- (void)setState:(NSInteger)state forContext:(NSString *)context {
    if (!context) return;

    NSDictionary *msg = @{
        @"event": @"setState",
        @"context": context,
        @"payload": @{
            @"state": @(state)
        }
    };
    [self sendJSON:msg];
}

- (void)setTitle:(NSString *)title forContext:(NSString *)context {
    if (!context) return;
    NSString *safeTitle = title ?: @"";

    NSDictionary *msg = @{
        @"event": @"setTitle",
        @"context": context,
        @"payload": @{
            @"title": safeTitle,
            @"target": @(0)
        }
    };
    [self sendJSON:msg];
}

- (void)updateAllPlayPauseContextsWithIsPlaying:(BOOL)isPlaying {
    NSInteger targetState = isPlaying ? 1 : 0;
    NSArray *contexts = nil;
    @synchronized (self.activePlayPauseContexts) {
        contexts = [self.activePlayPauseContexts.allKeys copy];
    }

    for (NSString *ctx in contexts) {
        [self setState:targetState forContext:ctx];
    }
}

- (void)updateAllMicMuteContextsWithVolume:(float)volume isMuted:(BOOL)isMuted {
    // State 0 = Muted (0%, mic_off, Red), State 1 = Live (100%/restored, mic_on, Green)
    NSInteger targetState = isMuted ? 0 : 1;
    NSString *title = isMuted ? @"0%" : [NSString stringWithFormat:@"%d%%", (int)round(volume * 100.0f)];

    NSArray *contexts = nil;
    @synchronized (self.activeMicMuteContexts) {
        contexts = [self.activeMicMuteContexts.allKeys copy];
    }

    for (NSString *ctx in contexts) {
        [self setState:targetState forContext:ctx];
        [self setTitle:title forContext:ctx];
    }
}

- (void)stop {
    [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    NSLog(@"[StreamDeckPlugin] WebSocket connection opened successfully");
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    NSLog(@"[StreamDeckPlugin] WebSocket closed with code: %ld", (long)closeCode);
    exit(0);
}

@end
