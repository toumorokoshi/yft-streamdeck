#import "media_controller.h"
#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/ev_keymap.h>
#include <dlfcn.h>

// MediaRemote command definitions
static const int kMRPlay = 0;
static const int kMRPause = 1;
static const int kMRTogglePlayPause = 2;
static const int kMRNextTrack = 3;
static const int kMRPreviousTrack = 4;

typedef Boolean (*MRMediaRemoteSendCommandFn)(int command, void *options);
typedef void (*MRMediaRemoteGetNowPlayingApplicationIsPlayingFn)(dispatch_queue_t queue, void (^completion)(Boolean isPlaying));
typedef void (*MRMediaRemoteGetNowPlayingInfoFn)(dispatch_queue_t queue, void (^completion)(CFDictionaryRef information));
typedef void (*MRMediaRemoteRegisterForNowPlayingNotificationsFn)(dispatch_queue_t queue);

@interface MediaController () {
    void *_mediaRemoteHandle;
    MRMediaRemoteSendCommandFn _sendCommand;
    MRMediaRemoteGetNowPlayingApplicationIsPlayingFn _getIsPlaying;
    MRMediaRemoteGetNowPlayingInfoFn _getInfo;
    MRMediaRemoteRegisterForNowPlayingNotificationsFn _registerNotifications;
    BOOL _lastKnownIsPlaying;
}

@property (nonatomic, copy, nullable) MediaPlaybackStateCallback stateChangedHandler;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;

@end

@implementation MediaController

+ (instancetype)sharedController {
    static MediaController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[MediaController alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastKnownIsPlaying = NO;
        [self initializeController];
    }
    return self;
}

- (BOOL)initializeController {
    if (_mediaRemoteHandle) {
        return YES;
    }

    _mediaRemoteHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!_mediaRemoteHandle) {
        NSLog(@"[MediaController] Warning: Could not open MediaRemote.framework");
        return NO;
    }

    _sendCommand = (MRMediaRemoteSendCommandFn)dlsym(_mediaRemoteHandle, "MRMediaRemoteSendCommand");
    _getIsPlaying = (MRMediaRemoteGetNowPlayingApplicationIsPlayingFn)dlsym(_mediaRemoteHandle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    _getInfo = (MRMediaRemoteGetNowPlayingInfoFn)dlsym(_mediaRemoteHandle, "MRMediaRemoteGetNowPlayingInfo");
    _registerNotifications = (MRMediaRemoteRegisterForNowPlayingNotificationsFn)dlsym(_mediaRemoteHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");

    if (_registerNotifications) {
        _registerNotifications(dispatch_get_main_queue());
        NSLog(@"[MediaController] Registered for system media notifications");
    }

    // Observe system media notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMediaNotification:)
                                                 name:nil
                                               object:nil];

    // Also run a lightweight periodic polling timer to detect external changes (e.g. AirPods, browser clicks)
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                      target:self
                                                    selector:@selector(pollPlaybackState)
                                                    userInfo:nil
                                                     repeats:YES];

    return YES;
}

- (void)setPlaybackStateChangedHandler:(nullable MediaPlaybackStateCallback)handler {
    _stateChangedHandler = [handler copy];
    // Immediate query on handler registration
    [self checkIsPlayingWithCompletion:^(BOOL isPlaying) {
        if (self->_stateChangedHandler) {
            self->_stateChangedHandler(isPlaying);
        }
    }];
}

- (void)handleMediaNotification:(NSNotification *)note {
    NSString *name = note.name;
    if ([name containsString:@"MediaRemote"] || [name containsString:@"NowPlaying"]) {
        [self pollPlaybackState];
    }
}

- (void)pollPlaybackState {
    __weak typeof(self) weakSelf = self;
    [self checkIsPlayingWithCompletion:^(BOOL isPlaying) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (isPlaying != strongSelf->_lastKnownIsPlaying) {
            strongSelf->_lastKnownIsPlaying = isPlaying;
            if (strongSelf.stateChangedHandler) {
                strongSelf.stateChangedHandler(isPlaying);
            }
        }
    }];
}

- (void)postAuxKey:(int)key {
    NSEvent *downEvent = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                            location:NSMakePoint(0, 0)
                                       modifierFlags:0xa00
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:8
                                               data1:(key << 16) | (0xa << 8)
                                               data2:-1];
    CGEventPost(kCGHIDEventTap, [downEvent CGEvent]);

    NSEvent *upEvent = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                          location:NSMakePoint(0, 0)
                                     modifierFlags:0xb00
                                         timestamp:0
                                      windowNumber:0
                                           context:nil
                                           subtype:8
                                             data1:(key << 16) | (0xb << 8)
                                             data2:-1];
    CGEventPost(kCGHIDEventTap, [upEvent CGEvent]);
}

- (void)executeAppleScriptFallback:(NSString *)command {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *scriptText = [NSString stringWithFormat:
            @"tell application \"System Events\" to set pNames to name of processes\n"
            @"if pNames contains \"Spotify\" then\n"
            @"  tell application \"Spotify\" to %@\n"
            @"else if pNames contains \"Music\" then\n"
            @"  tell application \"Music\" to %@\n"
            @"end if", command, command];

        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptText];
        NSDictionary *errorInfo = nil;
        [script executeAndReturnError:&errorInfo];
        if (errorInfo) {
            NSLog(@"[MediaController] AppleScript fallback notice: %@", errorInfo[NSAppleScriptErrorMessage]);
        }
    });
}

- (BOOL)togglePlayPause {
    BOOL success = NO;
    if (_sendCommand) {
        success = _sendCommand(kMRTogglePlayPause, NULL);
    }

    if (!success) {
        // Fallback: system media key or AppleScript
        [self postAuxKey:NX_KEYTYPE_PLAY];
        [self executeAppleScriptFallback:@"playpause"];
        success = YES;
    }

    // Schedule quick state verification
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self pollPlaybackState];
    });

    return success;
}

- (BOOL)play {
    BOOL success = NO;
    if (_sendCommand) {
        success = _sendCommand(kMRPlay, NULL);
    }
    if (!success) {
        [self postAuxKey:NX_KEYTYPE_PLAY];
        [self executeAppleScriptFallback:@"play"];
        success = YES;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self pollPlaybackState];
    });

    return success;
}

- (BOOL)pause {
    BOOL success = NO;
    if (_sendCommand) {
        success = _sendCommand(kMRPause, NULL);
    }
    if (!success) {
        [self postAuxKey:NX_KEYTYPE_PLAY];
        [self executeAppleScriptFallback:@"pause"];
        success = YES;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self pollPlaybackState];
    });

    return success;
}

- (BOOL)nextTrack {
    BOOL success = NO;
    if (_sendCommand) {
        success = _sendCommand(kMRNextTrack, NULL);
    }
    if (!success) {
        [self postAuxKey:NX_KEYTYPE_FAST];
        [self executeAppleScriptFallback:@"next track"];
        success = YES;
    }
    return success;
}

- (BOOL)previousTrack {
    BOOL success = NO;
    if (_sendCommand) {
        success = _sendCommand(kMRPreviousTrack, NULL);
    }
    if (!success) {
        [self postAuxKey:NX_KEYTYPE_REWIND];
        [self executeAppleScriptFallback:@"previous track"];
        success = YES;
    }
    return success;
}

- (void)checkIsPlayingWithCompletion:(void (^)(BOOL isPlaying))completion {
    if (_getIsPlaying) {
        _getIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            completion(isPlaying ? YES : NO);
        });
    } else {
        completion(NO);
    }
}

- (void)getNowPlayingInfoWithCompletion:(void (^)(NSString * _Nullable title, NSString * _Nullable artist))completion {
    if (_getInfo) {
        _getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
            if (!information) {
                completion(nil, nil);
                return;
            }
            NSDictionary *info = (__bridge NSDictionary *)information;
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            completion(title, artist);
        });
    } else {
        completion(nil, nil);
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.pollTimer invalidate];
    if (_mediaRemoteHandle) {
        dlclose(_mediaRemoteHandle);
        _mediaRemoteHandle = NULL;
    }
}

@end
