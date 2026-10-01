#import <Foundation/Foundation.h>
#import "media_controller.h"
#import "audio_controller.h"
#import "streamdeck_plugin.h"

static void printUsage(const char *progName) {
    printf("yft sandbox - OpenDeck & Stream Deck Plugin\n\n");
    printf("Usage:\n");
    printf("  %s -port <port> -pluginUUID <uuid> -registerEvent <event> -info <info>\n\n", progName);
    printf("Standalone CLI testing options:\n");
    printf("  --toggle       Toggle media play/pause on macOS\n");
    printf("  --play         Start media playback on macOS\n");
    printf("  --pause        Pause media playback on macOS\n");
    printf("  --next         Skip to next track on macOS\n");
    printf("  --previous     Return to previous track on macOS\n");
    printf("  --status       Print current playback status (JSON)\n");
    printf("  --toggle-mic   Toggle microphone mute (0%% vs 100%%/restored)\n");
    printf("  --mute         Mute microphone (set input volume to 0%%)\n");
    printf("  --unmute       Unmute microphone (restore input volume / 100%%)\n");
    printf("  --mic-status   Print current microphone volume and mute status (JSON)\n");
    printf("  --help         Print this help message\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSInteger port = 0;
        NSString *pluginUUID = nil;
        NSString *registerEvent = nil;
        NSString *infoJson = nil;

        // Parse command line arguments
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];

            if ([arg isEqualToString:@"--toggle"]) {
                BOOL ok = [[MediaController sharedController] togglePlayPause];
                printf("Play/Pause toggled: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--play"]) {
                BOOL ok = [[MediaController sharedController] play];
                printf("Play command sent: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--pause"]) {
                BOOL ok = [[MediaController sharedController] pause];
                printf("Pause command sent: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--next"]) {
                BOOL ok = [[MediaController sharedController] nextTrack];
                printf("Next track command sent: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--previous"]) {
                BOOL ok = [[MediaController sharedController] previousTrack];
                printf("Previous track command sent: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--status"]) {
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                __block BOOL playing = NO;
                [[MediaController sharedController] checkIsPlayingWithCompletion:^(BOOL isPlaying) {
                    playing = isPlaying;
                    dispatch_semaphore_signal(sem);
                }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
                printf("{\"isPlaying\": %s}\n", playing ? "true" : "false");
                return 0;
            } else if ([arg isEqualToString:@"--toggle-mic"]) {
                BOOL ok = [[AudioController sharedController] toggleMute];
                printf("Mic mute toggled: %s (current muted: %s)\n",
                       ok ? "success" : "failed",
                       [[AudioController sharedController] isMuted] ? "true" : "false");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--mute"]) {
                BOOL ok = [[AudioController sharedController] mute];
                printf("Mic muted: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--unmute"]) {
                BOOL ok = [[AudioController sharedController] unmute];
                printf("Mic unmuted: %s\n", ok ? "success" : "failed");
                return ok ? 0 : 1;
            } else if ([arg isEqualToString:@"--mic-status"]) {
                float vol = [[AudioController sharedController] inputVolume];
                BOOL muted = [[AudioController sharedController] isMuted];
                int pct = (int)round(vol * 100.0f);
                printf("{\"isMuted\": %s, \"volume\": %.2f, \"percentage\": %d}\n",
                       muted ? "true" : "false", vol, pct);
                return 0;
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printUsage(argv[0]);
                return 0;
            } else if ([arg isEqualToString:@"-port"] || [arg isEqualToString:@"--port"]) {
                if (i + 1 < argc) {
                    port = atoi(argv[++i]);
                }
            } else if ([arg isEqualToString:@"-pluginUUID"] || [arg isEqualToString:@"--pluginUUID"]) {
                if (i + 1 < argc) {
                    pluginUUID = [NSString stringWithUTF8String:argv[++i]];
                }
            } else if ([arg isEqualToString:@"-registerEvent"] || [arg isEqualToString:@"--registerEvent"]) {
                if (i + 1 < argc) {
                    registerEvent = [NSString stringWithUTF8String:argv[++i]];
                }
            } else if ([arg isEqualToString:@"-info"] || [arg isEqualToString:@"--info"]) {
                if (i + 1 < argc) {
                    infoJson = [NSString stringWithUTF8String:argv[++i]];
                }
            }
        }

        if (port <= 0 || !pluginUUID || !registerEvent) {
            NSLog(@"[yft sandbox] Incomplete parameters provided. Showing usage:");
            printUsage(argv[0]);
            return 1;
        }

        NSLog(@"[yft sandbox] Starting plugin for port: %ld, UUID: %@, event: %@",
              (long)port, pluginUUID, registerEvent);

        StreamDeckPlugin *plugin = [[StreamDeckPlugin alloc] initWithPort:port
                                                               pluginUUID:pluginUUID
                                                            registerEvent:registerEvent
                                                                 infoJson:infoJson];
        [plugin start];

        // Keep the run loop running for WebSocket and notifications
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
