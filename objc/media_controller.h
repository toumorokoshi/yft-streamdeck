#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MediaPlaybackStateCallback)(BOOL isPlaying);

@interface MediaController : NSObject

+ (instancetype)sharedController;

- (BOOL)initializeController;
- (void)setPlaybackStateChangedHandler:(nullable MediaPlaybackStateCallback)handler;

- (BOOL)togglePlayPause;
- (BOOL)play;
- (BOOL)pause;
- (BOOL)nextTrack;
- (BOOL)previousTrack;

- (void)checkIsPlayingWithCompletion:(void (^)(BOOL isPlaying))completion;
- (void)getNowPlayingInfoWithCompletion:(void (^)(NSString * _Nullable title, NSString * _Nullable artist))completion;

@end

NS_ASSUME_NONNULL_END
