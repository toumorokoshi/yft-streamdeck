#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface StreamDeckPlugin : NSObject

@property (nonatomic, assign, readonly) NSInteger port;
@property (nonatomic, copy, readonly) NSString *pluginUUID;
@property (nonatomic, copy, readonly) NSString *registerEvent;
@property (nonatomic, copy, readonly) NSString *infoJson;

- (instancetype)initWithPort:(NSInteger)port
                  pluginUUID:(NSString *)pluginUUID
               registerEvent:(NSString *)registerEvent
                    infoJson:(NSString *)infoJson;

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
