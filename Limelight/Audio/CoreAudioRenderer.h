#pragma once

#include <Limelight.h>

@interface CoreAudioRenderer : NSObject

- (instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION*)opusConfig;

- (void)start;
- (void)stop;
- (void *)getAudioBuffer:(int *)size;
- (BOOL)submitAudio:(int)bytesWritten;
- (void)handleRouteChange:(NSNotification *)notification;

@end

