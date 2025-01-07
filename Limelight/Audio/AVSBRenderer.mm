
#import "AVSBRenderer.h"
#import "AVSync.h"
#import "TPCircularBuffer.h"
#import "CoreAudioHelpers.h"
#include "AudioStats.h"

#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <pthread/qos.h>
#include <string.h>
#include <Limelight.h>

#define BUFFER_DURATION_MS 50

@interface AVSBRenderer ()
- (void)feedAudio;
- (bool)queueNextSampleBuffer:(CMTime *)outTimestamp;
@end

static AVSampleBufferRenderSynchronizer *renderSynchronizerInstance;

@implementation AVSBRenderer
{
    AVSampleBufferAudioRenderer *_audioRenderer;
    AVSampleBufferRenderSynchronizer *_renderSynchronizer;
    dispatch_queue_t _queue;
    bool _needsQOS;
    dispatch_semaphore_t _readReady;
    TPCircularBuffer _ringBuffer;

    AVAudioChannelLayout *_channelLayout;
    AVAudioFormat *_format;
    CMAudioFormatDescriptionRef _formatDescription;

    bool _needsReinit;
    uint32_t _firstPts;       // value of first pts packet we receive, used to offset future packets
    CMTime _nextPts;

    // opus metadata
    struct {
        int samplesPerFrame;
        int channels;
        double sampleRate;
        double frameDuration;
    } _opus;

    // hardware metadata
    struct {
        double sampleRate;
        int outputChannels;
        CFTimeInterval outputLatency;
        CFTimeInterval bufferDuration;
        CFStringRef deviceName;
    } _hw;

    // stats
    dispatch_queue_t _statsQueue;
    uint32_t _bitrateSum;
    uint32_t _opusPackets;
    double _opusToEnqueueTime; // average time from receiving an opus packet to enqueueing its PCM with AVSampleBuffer.
}

+(AVSampleBufferRenderSynchronizer *)getRenderSynchronizer
{
    if (!renderSynchronizerInstance) {
        renderSynchronizerInstance = [[AVSampleBufferRenderSynchronizer alloc] init];
    }
    return renderSynchronizerInstance;
}

-(instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)inOpusConfig
{
    self = [super init];

    _opus.samplesPerFrame = inOpusConfig->samplesPerFrame;
    _opus.channels        = inOpusConfig->channelCount;
    _opus.sampleRate      = 48000.0;
    _opus.frameDuration   = (_opus.samplesPerFrame / (_opus.sampleRate / 1000.0)) / 1000.0;
    _needsQOS             = true;

    AudioChannelLayoutTag layoutTag
        = _opus.channels == 6 ? kAudioChannelLayoutTag_WAVE_5_1_B
        : _opus.channels == 8 ? kAudioChannelLayoutTag_WAVE_7_1
        :                       kAudioChannelLayoutTag_Stereo;
    _channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:layoutTag];

    _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:_opus.sampleRate
                                              interleaved:YES
                                            channelLayout:_channelLayout];

    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                                     [_format streamDescription],
                                                     sizeof(AudioChannelLayout),
                                                     [_channelLayout layout],
                                                     0, NULL, NULL,
                                                     &_formatDescription);
    if (status != noErr) {
        CA_LogError(status, "Error calling CMAudioFormatDescriptionCreate");
        return nil;
    }
    DEBUG_TRACE(@"formatDescription %@", _formatDescription);

    // init ring buffer, entries = 10 when duration = 50ms and packet size 5ms
    int bufferEntries = BUFFER_DURATION_MS / (_opus.frameDuration * 1000);

    int ringBufferSize = bufferEntries * (sizeof(PCMHeader) + _opus.channels * _opus.samplesPerFrame * 4);
    bool ok = TPCircularBufferInit(&_ringBuffer, ringBufferSize);
    if (!ok) {
        CA_LogError(-1, "TPCircularBufferInit failed");
        return nil;
    }
    DEBUG_TRACE(@"AVSB ringBuffer created for %d entries, size %d", bufferEntries, ringBufferSize);

    // init AVSB
    _audioRenderer      = [[AVSampleBufferAudioRenderer alloc] init];
    //_renderSynchronizer = [[AVSampleBufferRenderSynchronizer alloc] init];
    _renderSynchronizer = [AVSBRenderer getRenderSynchronizer];

    if (_audioRenderer == nil || _renderSynchronizer == nil) {
        CA_LogError(-1, "Could not init AVSampleBufferAudioRenderer");
        return nil;
    }

    if (@available(macOS 12.0, iOS 14.5, tvOS 14.5, *)) {
        _renderSynchronizer.delaysRateChangeUntilHasSufficientMediaData = NO;
    }

    // init high-priority queue used by our feedAudio method
    _queue = dispatch_queue_create("com.moonlight.AVSampleBufferAudioRenderer",
                                   dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));

    // stats run on a background priroity queue
    _statsQueue = dispatch_queue_create("com.moonlight.AudioStats",
                                        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));

    if (@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)) {
        // enables Multichannel control center badge and spatial audio options
        [_audioRenderer setAllowedAudioSpatializationFormats:AVAudioSpatializationFormatMonoStereoAndMultichannel];
    }

    [_renderSynchronizer addRenderer:_audioRenderer];

    // setup AVAudioSession
    NSError *error = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];

    { // samplerate
        [session setPreferredSampleRate:_opus.sampleRate error:&error];
        if (error != nil) {
            CA_LogError(-1, "AVSB failed to set preferred samplerate to %.0f: %@", _opus.sampleRate, error.localizedDescription);
            // maybe ok?
        }
        DEBUG_TRACE(@"AVSB setPreferredSampleRate %f", _opus.sampleRate);
    }

    {   // session category & mode
        // AVAudioSessionModeMoviePlayback says: "When you set this mode, the audio session uses
        // signal processing to enhance movie playback for certain audio routes such as built-in speaker or headphones."
        // This may be required for spatial audio processsing
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeMoviePlayback
                     options:AVAudioSessionCategoryOptionMixWithOthers
                       error:&error];
        if (error != nil) {
            CA_LogError(-1, "failed to setCategory: %@", error.localizedDescription);
            return nil;
        }
        DEBUG_TRACE(@"AVSB setCategory:AVAudioSessionCategoryPlayback");
    }

    { // set buffer to match the packet size (5 or 10 ms)
        [session setPreferredIOBufferDuration:_opus.frameDuration
                                        error:&error];
        if (error != nil) {
            CA_LogError(-1, "AVSB failed to setPreferredIOBufferDuration to %f: %@", _opus.frameDuration, error.localizedDescription);
            return nil;
        }
        DEBUG_TRACE(@"AVSB setPreferredIOBufferDuration %f", _opus.frameDuration);
    }

#if TARGET_OS_VISION
    {
        // define the spatial rendering for VisionOS

        // AVAudioSessionSpatialExperienceHeadTracked, AVAudioSessionSpatialExperienceFixed, AVAudioSessionSpatialExperienceBypassed
        [session setIntendedSpatialExperience:AVAudioSessionSpatialExperienceFixed options:@{
            // SoundStageSize can be AVAudioSessionSoundStageSizeAutomatic, Small, Medium, Large
            @"AVAudioSessionSpatialExperienceOptionSoundStageSize" : @(AVAudioSessionSoundStageSizeLarge),
            // AVAudioSessionAnchoringStrategyAutomatic, AVAudioSessionAnchoringStrategyScene, AVAudioSessionAnchoringStrategyFront
            @"AVAudioSessionSpatialExperienceOptionAnchoringStrategy" : @(AVAudioSessionAnchoringStrategyFront)
        } error:&error];
        DEBUG_TRACE(@"AVSB setIntendedSpatialExperience");
        if (error != nil) {
            CA_LogError(-1, "AVSB failed to setIntendedSpatialExperience: %@", error.localizedDescription);
        }
    }
#endif

    // multichannel (non-spatial HDMI devices)
    if (_opus.channels > 2) {
        bool isSpatialAudioEnabled = false;

        if (@available(iOS 15.0, tvOS 15.0, *)) {
            // not sure what this does...
            [session setSupportsMultichannelContent:YES error:&error];
            if (error != nil) {
                Log(LOG_W, @"Warning: failed to setSupportsMultichannelContent:YES: %@", error.localizedDescription);
                // probably ok to continue
            }
            else {
                DEBUG_TRACE(@"AVSB setSupportsMultichannelContent:YES");
            }
        }

        for (AVAudioSessionPortDescription *output in session.currentRoute.outputs) {
            if (@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)) {
                if ([output isSpatialAudioEnabled]) {
                    isSpatialAudioEnabled = true;
                    break;
                }
            }
            if ([output.portType isEqualToString:AVAudioSessionPortHeadphones]) {
                isSpatialAudioEnabled = true;
                break;
            }
        }

        if (!isSpatialAudioEnabled) {
            NSError *error = nil;
            NSInteger maxChannels = [session maximumOutputNumberOfChannels];
            NSInteger prefChannels = MIN(maxChannels, _opus.channels);
            [session setPreferredOutputNumberOfChannels:prefChannels error:&error];
            if (error != nil) {
                Log(LOG_W, @"Warning: failed to setPreferredOutputNumberOfChannels to %d: %@", prefChannels, error.localizedDescription);
                // probably ok to continue
            }
            DEBUG_TRACE(@"setPreferredOutputNumberOfChannels:%d", (int)prefChannels);
        }
    }

    { // notifications
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(handleRouteChange:)
                       name:AVAudioSessionRouteChangeNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(handleResetNotification:)
                       name:AVAudioSessionMediaServicesWereResetNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(handleFlushedNotification:)
                       name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
                     object:nil];
    }

    _needsReinit = false;

    return self;
}

-(void)dealloc {
    DEBUG_TRACE(@"AVSB dealloc");

    [self stop];

    dispatch_sync(_queue, ^{
        TPCircularBufferCleanup(&self->_ringBuffer);
        if (self->_formatDescription) CFRelease(self->_formatDescription);
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self->_audioRenderer = nil;
        self->_renderSynchronizer = nil;
    });
}

-(void)resetStats {
    dispatch_sync(_statsQueue, ^{
        _bitrateSum = 0;
        _opusPackets = 0;
        _opusToEnqueueTime = 0.0;
    });
}

-(void)start {
    NSError *error = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];

    [session setActive:YES withOptions:AVAudioSessionRouteSharingPolicyLongFormAudio error:&error];
    //[session setActive:YES error:&error];
    if (error != nil) {
        CA_LogError(-1, "AVSB failed to setActive:YES: %@", error.localizedDescription);
        return;
    }
    DEBUG_TRACE(@"AVSB start, setActive:YES");
    

    // refresh the items we changed
    _hw.sampleRate     = [session sampleRate];
    _hw.bufferDuration = [session IOBufferDuration];
    _hw.outputChannels = (int)[session outputNumberOfChannels];
    _hw.outputLatency  = [session outputLatency];

    if (_hw.deviceName)
        CFRelease(_hw.deviceName);
    _hw.deviceName = CFStringCreateCopy(kCFAllocatorDefault, (__bridge CFStringRef)session.currentRoute.outputs.firstObject.portName);

    DEBUG_TRACE(@"AVSB %@ running at sampleRate %.2f %d-channel, with IOBufferDuration %f, latency %f",
                _hw.deviceName, _hw.sampleRate, _hw.outputChannels, _hw.bufferDuration, _hw.outputLatency);



    // Reset our stats to 0
    [self resetStats];

    _nextPts = CMTimeMake(0, 1000);

    // Prep semaphore for waiting in a no-audio situation
    _readReady = dispatch_semaphore_create(0);

    // The startup flow is:
    // audio.init()
    // audio.start()
    // AudioReceiveThreadProc is created for processing RTP packets
    //   audio.decodeAndPlaySample()

    // So we can't prime the buffer here, but must return and wait on the semaphore for incoming audio data

    dispatch_async(_queue, ^{
        [self feedAudio];
    });
}

-(void)feedAudio
{
    if (_needsReinit)
        return;

    CMTime playTime;
    while (dispatch_semaphore_wait(_readReady, DISPATCH_TIME_FOREVER) == 0) {
        // new data has arrived!
        if ([self queueNextSampleBuffer:&playTime]) {
//            dispatch_async(_statsQueue, ^{
//                DEBUG_TRACE(@"via semaphore, buffer queued for playback at %lld", playTime.value);
//            });

            if ([_renderSynchronizer rate] != 1.0) {
                [_renderSynchronizer setRate:1.0 time:playTime];
            }
        }

        // check status of last enqueue
        if (_audioRenderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            Log(LOG_E, @"AVSB enqueueSampleBuffer failed: %@", _audioRenderer.error);
            _needsReinit = true;
        }

        if (_needsReinit)
            break;

        // temporary 5s stats ticker
        static CFTimeInterval lastStatsDisplay = 0.0;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - lastStatsDisplay > 5.0) {
            lastStatsDisplay = now;
            dispatch_async(_statsQueue, ^{
                [self getAudioStatsString];
            });
        }
    }
}

-(bool)queueNextSampleBuffer:(CMTime*)outTimestamp {
    OSStatus status = noErr;
    CMBlockBufferRef blockBuffer = NULL;
    CMSampleBufferRef sampleBuffer = NULL;
    int inNumberFrames = int(_opus.sampleRate * _opus.frameDuration);
    int wantedBytes = sizeof(PCMHeader) + (inNumberFrames * _opus.channels * 4);

    // Pull audio from ring buffer
    uint32_t availableBytes;
    char *sourceBuffer = (char *)TPCircularBufferTail(&_ringBuffer, &availableBytes);

    if (availableBytes < wantedBytes) {
        //        DEBUG_TRACE(@"AVSB queueNextSampleBuffer(frames=%d) has no audio, availableBytes %d, wantedBytes %d",
        //                    inNumberFrames, availableBytes, wantedBytes);
        return false;
    }

    // ensure header is present and valid
    PCMHeader header;
    memcpy(&header, sourceBuffer, sizeof(PCMHeader));

    bool headerValid = (strncmp(header.identifier, HEADER_IDENTIFIER, HEADER_IDENTIFIER_SIZE) == 0);
    assert(headerValid == true);

    wantedBytes -= sizeof(PCMHeader);
    sourceBuffer += sizeof(PCMHeader);

    // copy PCM into CMBlockBuffer, this takes 2 API calls
    status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                                wantedBytes,
                                                kCFAllocatorDefault, NULL, 0,
                                                wantedBytes,
                                                0,
                                                &blockBuffer);
    if (status != noErr) {
        CA_LogError(status, "Error calling CMBlockBufferCreateWithMemoryBlock");
        return false;
    }

    status = CMBlockBufferReplaceDataBytes(sourceBuffer, blockBuffer, 0, wantedBytes);
    if (status != noErr) {
        CA_LogError(status, "Error calling CMBlockBufferReplaceDataBytes");
        CFRelease(blockBuffer);
        return false;
    }
    TPCircularBufferConsume(&_ringBuffer, wantedBytes + sizeof(PCMHeader));

    // construct CMSampleBuffer with timing metadata
    // XXX A Sunshine bug causes pts to stop advancing if the system stops producing audio
    // so pts is not usable at the moment
    if (_firstPts == 0) {
        _firstPts = header.pts;
    }

    // to determine when the next packet should be played we have several choices:
    // _nextPts: the value we calculated after the last frame, using pts + duration
    // streamPts: the incoming stream's timestamp data, it should be the most accurate
    // currentPts: the time used by the synchronizer. We aren't yet using this as intended (by letting it manage the video playback)
    //CMTime currentPts = [_renderSynchronizer currentTime];
    CMTime streamPts  = CMTimeMake(header.pts, 1000);
//    DEBUG_TRACE(@"AVSB comparing _nextPts %f, currentPts %f, streamPts %f",
//                CMTimeGetSeconds(_nextPts), CMTimeGetSeconds(currentPts), CMTimeGetSeconds(streamPts));

    if (CMTimeCompare(streamPts, _nextPts) == 1) {
        DEBUG_TRACE(@"AVSB audio pts adjusted to streamPts %f (+%f)",
                    CMTimeGetSeconds(streamPts), CMTimeGetSeconds(CMTimeSubtract(streamPts, _nextPts)));
        _nextPts = streamPts;
    }

    CMSampleTimingInfo sampleTimingInfo[] = {(CMSampleTimingInfo) {
        .duration              = CMTimeMake(1, _opus.sampleRate),
        .presentationTimeStamp = _nextPts,
        .decodeTimeStamp       = kCMTimeInvalid
    }};
    size_t sampleSizeArray[] = {(size_t)_opus.channels * 4};
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       _formatDescription,
                                       inNumberFrames,
                                       1, sampleTimingInfo,
                                       1, sampleSizeArray,
                                       &sampleBuffer);
    if (status != noErr) {
        CA_LogError(status, "Error calling CMSampleBufferCreateReady");
        CFRelease(blockBuffer);
        return false;
    }

    //DEBUG_TRACE(@"constructed SampleBuffer: %@", sampleBuffer);

    // Compute the time of the next sample.
    CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetOutputDuration(sampleBuffer);
    _nextPts = CMTimeAdd(pts, duration);

    dispatch_async(_statsQueue, ^{
//        DEBUG_TRACE(@"AVSB audio pts %f, duration %f / raw pts %d",
//                    CMTimeGetSeconds(pts), CMTimeGetSeconds(duration), header.pts);
        self->_opusToEnqueueTime += (CACurrentMediaTime() - ((double)header.decodeStartTimeNanos / 1e9));
        self->_opusPackets++;
    });

    [[AVSync sharedInstance] setAudioPtsAndCurrentTime:pts currentTime:[_renderSynchronizer currentTime]];

    [_audioRenderer enqueueSampleBuffer:sampleBuffer];

    CFRelease(blockBuffer);
    CFRelease(sampleBuffer);

    if (outTimestamp)
        *outTimestamp = pts;

    return true;
}

-(void)stop
{
    // stop playback
    dispatch_sync(_queue, ^{
        [_renderSynchronizer setRate:0];
        [_audioRenderer stopRequestingMediaData];
        [_audioRenderer flush];
        DEBUG_TRACE(@"AVSB stop, renderSynchronizer setRate:0");

        TPCircularBufferClear(&_ringBuffer);

        _firstPts = 0;

        if (_hw.deviceName)
            CFRelease(_hw.deviceName);

        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO error:&error];
        if (error != nil) {
            CA_LogError(-1, "failed to setActive:NO: %@, ignoring...", error.localizedDescription);
        }
    });
}

-(void *)getAudioBuffer:(int *)size
{
    // This provides a buffer for the Opus API to write into.
    uint32_t bytesFree;
    void *ptr = TPCircularBufferHead(&_ringBuffer, &bytesFree);
    *size = bytesFree;

    return ptr;
}

-(bool)submitAudio:(int)bytesWritten opusBytes:(int)opusBytes
{
    // Called after Opus has decoded bytesWritten bytes of PCM into our buffer

    if (_needsReinit) {
        // If an audio device has changed, this flag will be set. Break out
        // so we can be recreated.
        return false;
    }

    // ensure the audio decoder thread (our caller) runs at QoS user-initiated,
    // the same as our AVSB queue reader
    if (_needsQOS) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
        _needsQOS = false;
    }

    // drop packet if we've fallen behind Moonlight's queue by at least 30 ms
//    int pendingAudio = LiGetPendingAudioDuration();
//    if (pendingAudio > 30) {
//        DEBUG_TRACE(@"submitAudio skip-ahead, pending audio duration: %d ms", pendingAudio);
//        return true;
//    }

    // Advance the write pointer
    TPCircularBufferProduce(&_ringBuffer, bytesWritten);

    // signal the reader in case it's waiting
    dispatch_semaphore_signal(_readReady);

    // accumulate stats
    dispatch_async(_statsQueue, ^{
        //DEBUG_TRACE(@"AVSB submitAudio bytesWritten %d, opusBytes %d", bytesWritten, opusBytes);
        self->_bitrateSum += opusBytes;

        //int pendingAudio = LiGetPendingAudioDuration();
        //DEBUG_TRACE(@"pending audio duration: %d ms", pendingAudio);
    });

    return true;
}

- (void)handleRouteChange:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    if (!userInfo) {
        return;
    }

    NSNumber *reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey];
    if (!reasonValue) {
        return;
    }

    DEBUG_TRACE(@"AVSB routeChange, reason: %@", reasonValue);

    switch (reasonValue.integerValue) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: {
            AVAudioSession *session = [AVAudioSession sharedInstance];
            for (AVAudioSessionPortDescription *output in session.currentRoute.outputs) {
                if ([output.portType isEqualToString:AVAudioSessionPortHeadphones]) {
                    // headphonesConnected = YES;
                }
                DEBUG_TRACE(@"AVSB AVAudioSessionRouteChangeReasonNewDeviceAvailable: %@, isSpatialAudioEnabled: %@", output.portType, output.isSpatialAudioEnabled);
            }
            break;
        }

        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: {
            AVAudioSessionRouteDescription *previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey];
            if (previousRoute) {
                for (AVAudioSessionPortDescription *output in previousRoute.outputs) {
                    if ([output.portType isEqualToString:AVAudioSessionPortHeadphones]) {
                        // headphonesConnected = NO;
                    }
                    DEBUG_TRACE(@"AVSB AVAudioSessionRouteChangeReasonOldDeviceUnavailable: %@", output.portType);
                }
            }
            break;
        }

        default:
            break;
    }

    _needsReinit = true;
}

-(void)handleResetNotification:(NSNotification *)notification
{
    DEBUG_TRACE(@"AVSB AVAudioSessionMediaServicesWereResetNotification, name: %@", notification.name);

    // always reinit on a change
    _needsReinit = true;
}

-(void)handleFlushedNotification:(NSNotification *)notification
{
    NSValue *flushTime = [notification.userInfo objectForKey:AVSampleBufferAudioRendererFlushTimeKey];
    double time = CMTimeGetSeconds(flushTime.CMTimeValue);
    Log(LOG_I, @"AVSB renderer flush: at %f, time %f", time, CMTimeGetSeconds(_renderSynchronizer.currentTime));
}

// update rate is based on how often we're called
-(NSString *)getAudioStatsString
{
    static EWMA bitrateAvg(0.9);
    static EWMA decodeTimeAvg(0.2);
    static CFTimeInterval lastTick = CACurrentMediaTime();
    CFTimeInterval now = CACurrentMediaTime();

    // add a new sample to the bitrate moving average
    bitrateAvg.addSample((double)(_bitrateSum * 8) / 1000.0 / (now - lastTick));

    // track audio decode time as the sum of opus decode -> ring buffer and ring buffer -> processing -> output
    // it doesn't include RTP processing time but probably should
    decodeTimeAvg.addSample((_opusToEnqueueTime / 1000.0) / _opusPackets);

    dispatch_async(_statsQueue, ^{
        lastTick = now;
        self->_bitrateSum = 0;
        self->_opusToEnqueueTime = 0.0;
        self->_opusPackets = 0;
    });

    uint32_t freeBytes = 0;
    TPCircularBufferTail(&_ringBuffer, &freeBytes);
    uint32_t pcmBytes = _ringBuffer.length - freeBytes;
    double pcmDuration = pcmBytes * 1.0 / (_opus.channels * _opus.sampleRate * sizeof(float));

    double audioDelay;
    double avOffset = [[AVSync sharedInstance] getAVSyncOffsets:&audioDelay];

    NSString *out = [NSString stringWithFormat:@" / Audio: %dch Opus @ %.0f kbps\n / Audio buffer: %.0f%% full (%.2f ms)\n / Audio buffer delay %.2f ms\n / %@ latency: %.2f ms",
                     _opus.channels, bitrateAvg.getOutput(),
                     (double)(pcmBytes * 100.0 / _ringBuffer.length), pcmDuration * 1000.0, audioDelay, _hw.deviceName, _hw.outputLatency * 1000.0];

    DEBUG_TRACE(@"buffer %.2f %% full, PCM bytes %d (%.2f ms), free %d, bitrate %.0f kbps, avOffset %f, audioDelay %f, latency %f",
                (double)(pcmBytes * 100.0 / _ringBuffer.length), pcmBytes, pcmDuration * 1000.0, freeBytes, bitrateAvg.getOutput(),
                avOffset, audioDelay, _hw.outputLatency);

    return out;
}

@end
