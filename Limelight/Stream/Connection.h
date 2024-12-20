//
//  Connection.h
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ConnectionCallbacks.h"
#import "CoreAudioRenderer.h"
#import "VideoDecoderRenderer.h"
#import "StreamConfiguration.h"
#import "BandwidthTracker.h"
#import "Plot.h"

#define CONN_TEST_SERVER "ios.conntest.moonlight-stream.org"

typedef struct {
    uint32_t opusBytesReceived;                 // total Opus bytes received
    double opusKbitsPerSec;                     // current Opus bitrate in kbps, not including FEC overhead
    uint32_t decodedSamples;                    // total packets decoded
    uint32_t droppedSamples;                    // total packets lost to the network
    uint64_t decodeDurationUs;                  // cumulative render time, microseconds
    uint32_t lastRtt;                           // network latency from enet, milliseconds
    CFTimeInterval startTime;                   // timestamp stats were started, microseconds
} audio_stats_t;

@interface Connection : NSOperation <NSStreamDelegate>

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks;
-(void) terminate;
-(void) main;
-(BandwidthTracker *) getBwTracker;
-(BOOL) getVideoStats:(video_stats_t*)stats;
-(NSString *) getAudioStatsString;
-(NSString*) getActiveCodecName;

@end
