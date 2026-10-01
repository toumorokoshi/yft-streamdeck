#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AudioInputVolumeChangedCallback)(float volume, BOOL isMuted);

@interface AudioController : NSObject

+ (instancetype)sharedController;

- (BOOL)initializeController;
- (void)setInputVolumeChangedHandler:(nullable AudioInputVolumeChangedCallback)handler;

- (float)inputVolume;
- (BOOL)isMuted;

- (BOOL)setInputVolume:(float)volume;
- (BOOL)mute;
- (BOOL)unmute;
- (BOOL)toggleMute;

@end

NS_ASSUME_NONNULL_END
