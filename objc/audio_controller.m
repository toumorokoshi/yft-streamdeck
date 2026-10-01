#import "audio_controller.h"
#import <CoreAudio/CoreAudio.h>

@interface AudioController () {
    AudioDeviceID _currentInputDeviceID;
    AudioObjectPropertyListenerBlock _deviceVolumeListenerBlock;
    AudioObjectPropertyListenerBlock _defaultDeviceListenerBlock;
    float _lastUnmutedVolume;
}

@property (nonatomic, copy, nullable) AudioInputVolumeChangedCallback volumeChangedHandler;

@end

@implementation AudioController

+ (instancetype)sharedController {
    static AudioController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[AudioController alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentInputDeviceID = kAudioObjectUnknown;
        _lastUnmutedVolume = 1.0f;
        [self initializeController];
    }
    return self;
}

- (void)dealloc {
    [self removeDeviceListeners];
    [self removeDefaultDeviceListener];
}

- (BOOL)initializeController {
    [self setupDefaultDeviceListener];
    [self updateCurrentInputDevice];

    float currentVol = [self inputVolume];
    if (currentVol > 0.05f) {
        _lastUnmutedVolume = currentVol;
    }

    return YES;
}

- (void)setInputVolumeChangedHandler:(nullable AudioInputVolumeChangedCallback)handler {
    _volumeChangedHandler = [handler copy];
}

#pragma mark - Device Discovery

- (AudioDeviceID)getDefaultInputDeviceID {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &deviceID);
    if (err != noErr || deviceID == kAudioObjectUnknown) {
        NSLog(@"[AudioController] Failed to get default input device, err: %d", (int)err);
        return kAudioObjectUnknown;
    }
    return deviceID;
}

- (BOOL)getVolumeAddressForDevice:(AudioDeviceID)deviceID address:(AudioObjectPropertyAddress *)outAddr {
    if (deviceID == kAudioObjectUnknown || !outAddr) return NO;

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };

    if (AudioObjectHasProperty(deviceID, &addr)) {
        *outAddr = addr;
        return YES;
    }

    // Try channel 1
    addr.mElement = 1;
    if (AudioObjectHasProperty(deviceID, &addr)) {
        *outAddr = addr;
        return YES;
    }

    return NO;
}

- (void)updateCurrentInputDevice {
    AudioDeviceID newDeviceID = [self getDefaultInputDeviceID];
    if (newDeviceID == _currentInputDeviceID && _currentInputDeviceID != kAudioObjectUnknown) {
        return;
    }

    [self removeDeviceListeners];
    _currentInputDeviceID = newDeviceID;
    [self setupDeviceListeners];
}

#pragma mark - Listeners

- (void)setupDefaultDeviceListener {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    __weak typeof(self) weakSelf = self;
    _defaultDeviceListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSLog(@"[AudioController] Default input device changed.");
            [strongSelf updateCurrentInputDevice];
            [strongSelf notifyVolumeChanged];
        });
    };

    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &addr, dispatch_get_main_queue(), _defaultDeviceListenerBlock);
}

- (void)removeDefaultDeviceListener {
    if (_defaultDeviceListenerBlock) {
        AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &addr, dispatch_get_main_queue(), _defaultDeviceListenerBlock);
        _defaultDeviceListenerBlock = nil;
    }
}

- (void)setupDeviceListeners {
    if (_currentInputDeviceID == kAudioObjectUnknown) return;

    AudioObjectPropertyAddress volAddr;
    if (![self getVolumeAddressForDevice:_currentInputDeviceID address:&volAddr]) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    _deviceVolumeListenerBlock = ^(UInt32 inNumberAddresses, const AudioObjectPropertyAddress *inAddresses) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf notifyVolumeChanged];
        });
    };

    AudioObjectAddPropertyListenerBlock(_currentInputDeviceID, &volAddr, dispatch_get_main_queue(), _deviceVolumeListenerBlock);
}

- (void)removeDeviceListeners {
    if (_currentInputDeviceID != kAudioObjectUnknown && _deviceVolumeListenerBlock) {
        AudioObjectPropertyAddress volAddr;
        if ([self getVolumeAddressForDevice:_currentInputDeviceID address:&volAddr]) {
            AudioObjectRemovePropertyListenerBlock(_currentInputDeviceID, &volAddr, dispatch_get_main_queue(), _deviceVolumeListenerBlock);
        }
        _deviceVolumeListenerBlock = nil;
    }
}

- (void)notifyVolumeChanged {
    float vol = [self inputVolume];
    BOOL muted = [self isMuted];
    if (vol > 0.05f) {
        _lastUnmutedVolume = vol;
    }
    if (self.volumeChangedHandler) {
        self.volumeChangedHandler(vol, muted);
    }
}

#pragma mark - Volume & Mute Operations

- (float)inputVolume {
    if (_currentInputDeviceID != kAudioObjectUnknown) {
        AudioObjectPropertyAddress volAddr;
        if ([self getVolumeAddressForDevice:_currentInputDeviceID address:&volAddr]) {
            Float32 vol = 0.0f;
            UInt32 size = sizeof(vol);
            OSStatus err = AudioObjectGetPropertyData(_currentInputDeviceID, &volAddr, 0, NULL, &size, &vol);
            if (err == noErr) {
                return (float)vol;
            }
        }
    }

    // AppleScript fallback
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:@"input volume of (get volume settings)"];
    NSAppleEventDescriptor *desc = [as executeAndReturnError:nil];
    if (desc) {
        NSInteger intVol = [desc int32Value];
        return (float)intVol / 100.0f;
    }

    return 0.0f;
}

- (BOOL)isMuted {
    float vol = [self inputVolume];
    return (vol <= 0.001f);
}

- (BOOL)setInputVolume:(float)volume {
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;

    BOOL success = NO;

    if (_currentInputDeviceID != kAudioObjectUnknown) {
        AudioObjectPropertyAddress volAddr;
        if ([self getVolumeAddressForDevice:_currentInputDeviceID address:&volAddr]) {
            Float32 val = (Float32)volume;
            OSStatus err = AudioObjectSetPropertyData(_currentInputDeviceID, &volAddr, 0, NULL, sizeof(val), &val);
            if (err == noErr) {
                success = YES;
            } else {
                NSLog(@"[AudioController] CoreAudio set volume failed: %d", (int)err);
            }
        }
    }

    if (!success) {
        // AppleScript fallback
        int intVol = (int)round(volume * 100.0f);
        NSString *script = [NSString stringWithFormat:@"set volume input volume %d", intVol];
        NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
        NSDictionary *errDict = nil;
        [as executeAndReturnError:&errDict];
        success = (errDict == nil);
    }

    if (success) {
        if (volume > 0.05f) {
            _lastUnmutedVolume = volume;
        }
        // If listener block is not registered, notify manually
        if (!_deviceVolumeListenerBlock) {
            [self notifyVolumeChanged];
        }
    }

    return success;
}

- (BOOL)mute {
    float current = [self inputVolume];
    if (current > 0.05f) {
        _lastUnmutedVolume = current;
    }
    return [self setInputVolume:0.0f];
}

- (BOOL)unmute {
    float targetVolume = _lastUnmutedVolume;
    if (targetVolume <= 0.05f) {
        targetVolume = 1.0f;
    }
    return [self setInputVolume:targetVolume];
}

- (BOOL)toggleMute {
    if ([self isMuted]) {
        return [self unmute];
    } else {
        return [self mute];
    }
}

@end
