//
//  Connection.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/19/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Connection.h"
#import "Utils.h"
#import "CoreAudioHelpers.h"

#import <VideoToolbox/VideoToolbox.h>

#define SDL_MAIN_HANDLED
#import <SDL.h>

#include "Limelight.h"
#include "opus_multistream.h"

#define AUDIOUNIT_DECODER 1
#define AUDIOQUEUE_DECODER 0
#define AVSB_DECODER 0

@implementation Connection {
    SERVER_INFORMATION _serverInfo;
    STREAM_CONFIGURATION _streamConfig;
    CONNECTION_LISTENER_CALLBACKS _clCallbacks;
    DECODER_RENDERER_CALLBACKS _drCallbacks;
    AUDIO_RENDERER_CALLBACKS _arCallbacks;
    char _hostString[256];
    char _appVersionString[32];
    char _gfeVersionString[32];
    char _rtspSessionUrl[128];
}

static NSLock* initLock;
static OpusMSDecoder* opusDecoder;
static id<ConnectionCallbacks> _callbacks;
static int lastFrameNumber;
static int activeVideoFormat;
static video_stats_t currentVideoStats;
static video_stats_t lastVideoStats;
static NSLock* videoStatsLock;
static VideoDecoderRenderer* renderer;

static OPUS_MULTISTREAM_CONFIGURATION opusConfig;
static bool audioIsStopping = false;
#if AUDIOUNIT_DECODER
static CoreAudioRenderer* audioRenderer;
#elif AUDIOQUEUE_DECODER
static AQRenderer* aqRenderer;
#elif AVSB_DECODER
static AVSBRenderer* avsbRenderer;
#endif

int DrDecoderSetup(int videoFormat, int width, int height, int redrawRate, void* context, int drFlags)
{
    [renderer setupWithVideoFormat:videoFormat width:width height:height frameRate:redrawRate];
    lastFrameNumber = 0;
    activeVideoFormat = videoFormat;
    memset(&currentVideoStats, 0, sizeof(currentVideoStats));
    memset(&lastVideoStats, 0, sizeof(lastVideoStats));
    return 0;
}

void DrStart(void)
{
    [renderer start];
}

void DrStop(void)
{
    [renderer stop];
}

-(BOOL) getVideoStats:(video_stats_t*)stats
{
    // We return lastVideoStats because it is a complete 1 second window
    [videoStatsLock lock];
    if (lastVideoStats.endTime != 0) {
        memcpy(stats, &lastVideoStats, sizeof(*stats));
        [videoStatsLock unlock];
        return YES;
    }
    
    // No stats yet
    [videoStatsLock unlock];
    return NO;
}

-(NSString *)getAudioStatsString
{
#if AUDIOUNIT_DECODER
    return [audioRenderer getAudioStatsString];
#elif AVSB_DECODER
    return [avsbRenderer getAudioStatsString];
#endif

    return NULL;
}

-(NSString*) getActiveCodecName
{
    switch (activeVideoFormat)
    {
        case VIDEO_FORMAT_H264:
            return @"H.264";
        case VIDEO_FORMAT_H265:
            return @"HEVC";
        case VIDEO_FORMAT_H265_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"HEVC Main 10 HDR";
            }
            else {
                return @"HEVC Main 10 SDR";
            }
        case VIDEO_FORMAT_AV1_MAIN8:
            return @"AV1";
        case VIDEO_FORMAT_AV1_MAIN10:
            if (LiGetCurrentHostDisplayHdrMode()) {
                return @"AV1 10-bit HDR";
            }
            else {
                return @"AV1 10-bit SDR";
            }
        default:
            return @"UNKNOWN";
    }
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit)
{
    int offset = 0;
    int ret;
    unsigned char* data = (unsigned char*) malloc(decodeUnit->fullLength);
    if (data == NULL) {
        // A frame was lost due to OOM condition
        return DR_NEED_IDR;
    }
    
    CFTimeInterval now = CACurrentMediaTime();
    if (!lastFrameNumber) {
        currentVideoStats.startTime = now;
        lastFrameNumber = decodeUnit->frameNumber;
    }
    else {
        // Flip stats roughly every second
        if (now - currentVideoStats.startTime >= 1.0f) {
            currentVideoStats.endTime = now;
            
            [videoStatsLock lock];
            lastVideoStats = currentVideoStats;
            [videoStatsLock unlock];
            
            memset(&currentVideoStats, 0, sizeof(currentVideoStats));
            currentVideoStats.startTime = now;
        }
        
        // Any frame number greater than m_LastFrameNumber + 1 represents a dropped frame
        currentVideoStats.networkDroppedFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        currentVideoStats.totalFrames += decodeUnit->frameNumber - (lastFrameNumber + 1);
        lastFrameNumber = decodeUnit->frameNumber;
    }
    
    if (decodeUnit->frameHostProcessingLatency != 0) {
        if (currentVideoStats.minHostProcessingLatency == 0 || decodeUnit->frameHostProcessingLatency < currentVideoStats.minHostProcessingLatency) {
            currentVideoStats.minHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        if (decodeUnit->frameHostProcessingLatency > currentVideoStats.maxHostProcessingLatency) {
            currentVideoStats.maxHostProcessingLatency = decodeUnit->frameHostProcessingLatency;
        }
        
        currentVideoStats.framesWithHostProcessingLatency++;
        currentVideoStats.totalHostProcessingLatency += decodeUnit->frameHostProcessingLatency;
    }
    
    currentVideoStats.receivedFrames++;
    currentVideoStats.totalFrames++;

    PLENTRY entry = decodeUnit->bufferList;
    while (entry != NULL) {
        // Submit parameter set NALUs directly since no copy is required by the decoder
        if (entry->bufferType != BUFFER_TYPE_PICDATA) {
            ret = [renderer submitDecodeBuffer:(unsigned char*)entry->data
                                        length:entry->length
                                    bufferType:entry->bufferType
                                     decodeUnit:decodeUnit];
            if (ret != DR_OK) {
                free(data);
                return ret;
            }
        }
        else {
            memcpy(&data[offset], entry->data, entry->length);
            offset += entry->length;
        }

        entry = entry->next;
    }

    // This function will take our picture data buffer
    return [renderer submitDecodeBuffer:data
                                 length:offset
                             bufferType:BUFFER_TYPE_PICDATA
                             decodeUnit:decodeUnit];
}

#if AUDIOUNIT_DECODER
int ArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION inOpusConfig, void* context, int flags) {
    int err;
    audioRenderer = [[CoreAudioRenderer alloc] initWithConfig:inOpusConfig];
    if (!audioRenderer) {
        Log(LOG_E, @"Failed to initialize audio subsystem\n");
        return -1;
    }

    opusConfig = *inOpusConfig;
    opusDecoder = opus_multistream_decoder_create(opusConfig.sampleRate,
                                                  opusConfig.channelCount,
                                                  opusConfig.streams,
                                                  opusConfig.coupledStreams,
                                                  opusConfig.mapping,
                                                  &err);

    if (opusDecoder == NULL) {
        Log(LOG_E, @"Failed to create Opus decoder");
        ArCleanup();
        return -1;
    }

    return 0;
}

void ArStart(void) {
    audioIsStopping = false;
    [audioRenderer start];
}

void ArStop(void) {
    [audioRenderer stop];
    audioIsStopping = true;
}

void ArCleanup(void) {
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
}

void ArDecodeAndPlaySample(char* sampleData, int sampleLength) {
    if (audioIsStopping)
        return;

    CFTimeInterval decodeStartTime = CACurrentMediaTime();

    int sampleSize = sizeof(float);
    int frameSize = sampleSize * opusConfig.channelCount;
    int desiredBufferSize = frameSize * opusConfig.samplesPerFrame;
    void* buffer = [audioRenderer getAudioBuffer:&desiredBufferSize];

    int samplesDecoded = opus_multistream_decode_float(opusDecoder, (unsigned char*)sampleData, sampleLength,
                                                   (float*)buffer, desiredBufferSize / frameSize, 0);

    if (samplesDecoded < 0) {
        if (samplesDecoded != OPUS_BUFFER_TOO_SMALL) {
            // OPUS_BUFFER_TOO_SMALL (-2) is a normal situation when sometimes we get Opus packets that are all 0's
            Log(LOG_E, @"opus decode error: %d", samplesDecoded);
        }
        return;
    }

    static int lastBufferSize = 0;
    if (desiredBufferSize != lastBufferSize) {
        // light logging only if changed
        Log(LOG_I, @"opus decoder: %d samples, %d opus bytes, %d PCM bytes",
            samplesDecoded, sampleLength, desiredBufferSize);
        lastBufferSize = desiredBufferSize;
    }

    // Update desiredSize with the number of bytes actually populated by the decoding operation
    if (samplesDecoded > 0) {
        desiredBufferSize = frameSize * samplesDecoded;
    }
    else {
        desiredBufferSize = 0;
    }

    if (![audioRenderer submitAudio:desiredBufferSize opusBytes:sampleLength decodeStartTime:decodeStartTime]) {
        // something changed or broke, reinit the audio
        Log(LOG_I, @"CoreAudioRenderer needs to reinitialize...");
        ArCleanup();
        ArInit(-1, &opusConfig, NULL, -1); // XXX we don't use the other params but this is still gross
    }
}
#endif

#if AUDIOQUEUE_DECODER
/// AudioQueue implementation
/// Very close to the original pre-SDL implementation, I am mostly doing it to learn the API.

int AudioQueueArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION inOpusConfig, void* context, int flags) {
    int err;
    opusConfig = *inOpusConfig;
    opusDecoder = opus_multistream_decoder_create(opusConfig.sampleRate,
                                                  opusConfig.channelCount,
                                                  opusConfig.streams,
                                                  opusConfig.coupledStreams,
                                                  opusConfig.mapping,
                                                  &err);

    if (opusDecoder == NULL) {
        Log(LOG_E, @"Failed to create Opus decoder");
        AudioQueueArCleanup();
        return -1;
    }

    aqRenderer = [[AQRenderer alloc] initWithConfig:inOpusConfig];
    if (!aqRenderer) {
        Log(LOG_E, @"Failed to initialize AQRenderer\n");
        return -1;
    }

    return 0;
}

void AudioQueueArStart(void) {
    audioIsStopping = false;
    [aqRenderer start];
}

void AudioQueueArStop(void) {
    [aqRenderer stop];
    audioIsStopping = true;
}

void AudioQueueArCleanup(void) {
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
}

void AudioQueueArDecodeAndPlaySample(char* sampleData, int sampleLength) {
    if (audioIsStopping)
        return;

    int sampleSize = sizeof(float);
    int frameSize = sampleSize * opusConfig.channelCount;
    int desiredBufferSize = frameSize * opusConfig.samplesPerFrame;
    void* buffer = [aqRenderer getAudioBuffer:&desiredBufferSize];

    int samplesDecoded = opus_multistream_decode_float(opusDecoder, (unsigned char*)sampleData, sampleLength,
                                                   (float*)buffer, (int)(desiredBufferSize * 1.0 / frameSize), 0);

    if (samplesDecoded < 0) {
        Log(LOG_E, @"opus decode error: %d", samplesDecoded);
        return;
    }

    static int lastBufferSize = 0;
    if (desiredBufferSize != lastBufferSize) {
        // light logging only if changed
        Log(LOG_I, @"opus decoder: %d samples, %d opus bytes, %d PCM bytes",
            samplesDecoded, sampleLength, desiredBufferSize);
        lastBufferSize = desiredBufferSize;
    }

    // Update desiredSize with the number of bytes actually populated by the decoding operation
    int bytesDecoded = 0;
    if (samplesDecoded > 0) {
        bytesDecoded = frameSize * samplesDecoded;
    }

    if (![aqRenderer submitAudio:bytesDecoded]) {
        // something changed or broke, reinit the audio
        Log(LOG_I, @"AQR needs to reinitialize...");
        AudioQueueArCleanup();
        AudioQueueArInit(-1, &opusConfig, NULL, -1); // XXX we don't use the other params but this is still gross
    }
}
#endif

#if AVSB_DECODER
/// AVSampleBufferAudioRenderer implementation
/// The "correct" way to play spatial audio, but latency is very bad

int AVSBArInit(int audioConfiguration, POPUS_MULTISTREAM_CONFIGURATION inOpusConfig, void* context, int flags) {
    int err;
    opusConfig = *inOpusConfig;
    opusDecoder = opus_multistream_decoder_create(opusConfig.sampleRate,
                                                  opusConfig.channelCount,
                                                  opusConfig.streams,
                                                  opusConfig.coupledStreams,
                                                  opusConfig.mapping,
                                                  &err);

    if (opusDecoder == NULL) {
        Log(LOG_E, @"Failed to create Opus decoder");
        AVSBArCleanup();
        return -1;
    }

    avsbRenderer = [[AVSBRenderer alloc] initWithConfig:inOpusConfig];
    if (!avsbRenderer) {
        Log(LOG_E, @"Failed to initialize AVSBRenderer\n");
        AVSBArCleanup();
        return -1;
    }

    return 0;
}

void AVSBArStart(void) {
    audioIsStopping = false;
    [avsbRenderer start];
}

void AVSBArStop(void) {
    [avsbRenderer stop];
    audioIsStopping = true;
}

void AVSBArCleanup(void) {
    if (opusDecoder != NULL) {
        opus_multistream_decoder_destroy(opusDecoder);
        opusDecoder = NULL;
    }
    avsbRenderer = NULL;
}

static inline void addPCMHeader(PCMHeader *header, uint32_t pts) {
    strncpy(header->identifier, HEADER_IDENTIFIER, HEADER_IDENTIFIER_SIZE);
    header->pts = pts;
    header->decodeStartTimeNanos = (uint64_t)(CACurrentMediaTime() * 1e9);
}

void AVSBArDecodeWithTimestamp(char* sampleData, int sampleLength, uint32_t pts) {
    if (audioIsStopping)
        return;

    // drop data before decoding if we've got at least 30ms of backlog
    int pendingAudio = LiGetPendingAudioDuration();
    if (pendingAudio > 100) {
        DEBUG_TRACE(@"AVSB skip-ahead, pending audio %d ms. Dropping %d Opus bytes @ %d", pendingAudio, sampleLength, pts);
        return;
    }

    // This getAudioBuffer works differently to the others, and only returns bytesFree in buffer
    int bytesFree = 0;
    char* buffer = [avsbRenderer getAudioBuffer:&bytesFree];

    int bytesNeeded = opusConfig.samplesPerFrame * opusConfig.channelCount * 4;
    if (bytesFree < sizeof(PCMHeader) + bytesNeeded) {
        // buffer doesn't have enough space for our header + one full frame
        Log(LOG_E, @"not enough space in buffer for decoded audio: bytesFree %d, bytesNeeded %d",
            bytesFree, sizeof(PCMHeader) + bytesNeeded);
        return;

        // XXX this should really block and wait for the buffer space
    }

    // encode the decodeStartTime and pts into a 16 byte "header" before the PCM
    // The code that reads this from the ring buffer is disconnected from this writer,
    // so this is the easiest way to add some metadata about the audio packet.
    addPCMHeader((PCMHeader *)buffer, pts);
    buffer += sizeof(PCMHeader);

    int samplesFree = bytesFree / (opusConfig.channelCount * 4);
    int samplesDecoded = opus_multistream_decode_float(opusDecoder, (unsigned char*)sampleData, sampleLength,
                                                   (float*)buffer, samplesFree, 0);

    if (samplesDecoded < 0) {
        Log(LOG_E, @"opus decode error: %d, opusBytes %d, bytesFree %d, samplesFree %d",
            samplesDecoded, sampleLength, bytesFree, samplesFree);
        return;
    }

    int bytesDecoded = samplesDecoded * opusConfig.channelCount * 4;

    static int lastSamplesDecoded = 0;
    if (samplesDecoded != lastSamplesDecoded) {
        // light logging only if changed
        Log(LOG_I, @"opus decoded: %d samples, %d opus bytes, %d PCM bytes",
            samplesDecoded, sampleLength, bytesDecoded);
        lastSamplesDecoded = samplesDecoded;
    }

    // we also wrote PCMHeader to the buffer
    bytesDecoded += sizeof(PCMHeader);

    if (![avsbRenderer submitAudio:bytesDecoded opusBytes:sampleLength]) {
        // something changed or broke, reinit the audio
        Log(LOG_I, @"AVSB needs to reinitialize...");
        AVSBArCleanup();
        AVSBArInit(-1, &opusConfig, NULL, -1); // XXX we don't use the other params but this is still gross
    }
}
#endif

void ClStageStarting(int stage)
{
    [_callbacks stageStarting:LiGetStageName(stage)];
}

void ClStageComplete(int stage)
{
    [_callbacks stageComplete:LiGetStageName(stage)];
}

void ClStageFailed(int stage, int errorCode)
{
    [_callbacks stageFailed:LiGetStageName(stage) withError:errorCode portTestFlags:LiGetPortFlagsFromStage(stage)];
}

void ClConnectionStarted(void)
{
    [_callbacks connectionStarted];
}

void ClConnectionTerminated(int errorCode)
{
    [_callbacks connectionTerminated: errorCode];
}

void ClLogMessage(const char* format, ...)
{
    va_list va;
    va_start(va, format);
    vfprintf(stderr, format, va);
    va_end(va);
}

void ClRumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor)
{
    [_callbacks rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

void ClConnectionStatusUpdate(int status)
{
    [_callbacks connectionStatusUpdate:status];
}

void ClSetHdrMode(bool enabled)
{
    [renderer setHdrMode:enabled];
    [_callbacks setHdrMode:enabled];
}

void ClRumbleTriggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor)
{
    [_callbacks rumbleTriggers:controllerNumber leftTrigger:leftTriggerMotor rightTrigger:rightTriggerMotor];
}

void ClSetMotionEventState(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz)
{
    [_callbacks setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

void ClSetControllerLED(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b)
{
    [_callbacks setControllerLed:controllerNumber r:r g:g b:b];
}

-(void) terminate
{
    // Interrupt any action blocking LiStartConnection(). This is
    // thread-safe and done outside initLock on purpose, since we
    // won't be able to acquire it if LiStartConnection is in
    // progress.
    LiInterruptConnection();
    
    // We dispatch this async to get out because this can be invoked
    // on a thread inside common and we don't want to deadlock. It also avoids
    // blocking on the caller's thread waiting to acquire initLock.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [initLock lock];
        LiStopConnection();
        [initLock unlock];
    });
}

-(id) initWithConfig:(StreamConfiguration*)config renderer:(VideoDecoderRenderer*)myRenderer connectionCallbacks:(id<ConnectionCallbacks>)callbacks
{
    self = [super init];

    // Use a lock to ensure that only one thread is initializing
    // or deinitializing a connection at a time.
    if (initLock == nil) {
        initLock = [[NSLock alloc] init];
    }
    
    if (videoStatsLock == nil) {
        videoStatsLock = [[NSLock alloc] init];
    }
    
    NSString *rawAddress = [Utils addressPortStringToAddress:config.host];
    strncpy(_hostString,
            [rawAddress cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_hostString) - 1);
    strncpy(_appVersionString,
            [config.appVersion cStringUsingEncoding:NSUTF8StringEncoding],
            sizeof(_appVersionString) - 1);
    if (config.gfeVersion != nil) {
        strncpy(_gfeVersionString,
                [config.gfeVersion cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_gfeVersionString) - 1);
    }
    if (config.rtspSessionUrl != nil) {
        strncpy(_rtspSessionUrl,
                [config.rtspSessionUrl cStringUsingEncoding:NSUTF8StringEncoding],
                sizeof(_rtspSessionUrl) - 1);
    }

    LiInitializeServerInformation(&_serverInfo);
    _serverInfo.address = _hostString;
    _serverInfo.serverInfoAppVersion = _appVersionString;
    if (config.gfeVersion != nil) {
        _serverInfo.serverInfoGfeVersion = _gfeVersionString;
    }
    if (config.rtspSessionUrl != nil) {
        _serverInfo.rtspSessionUrl = _rtspSessionUrl;
    }
    _serverInfo.serverCodecModeSupport = config.serverCodecModeSupport;

    renderer = myRenderer;
    _callbacks = callbacks;

    LiInitializeStreamConfiguration(&_streamConfig);
    _streamConfig.width = config.width;
    _streamConfig.height = config.height;
    _streamConfig.fps = config.frameRate;
    _streamConfig.bitrate = config.bitRate;
    _streamConfig.supportedVideoFormats = config.supportedVideoFormats;
    _streamConfig.audioConfiguration = config.audioConfiguration;
    
    // Since we require iOS 12 or above, we're guaranteed to be running
    // on a 64-bit device with ARMv8 crypto instructions, so we don't
    // need to check for that here.
    _streamConfig.encryptionFlags = ENCFLG_ALL;
    
    if ([Utils isActiveNetworkVPN]) {
        // Force remote streaming mode when a VPN is connected
        _streamConfig.streamingRemotely = STREAM_CFG_REMOTE;
        _streamConfig.packetSize = 1024;
    }
    else {
        // Detect remote streaming automatically based on the IP address of the target
        _streamConfig.streamingRemotely = STREAM_CFG_AUTO;
        _streamConfig.packetSize = 1392;
    }

    memcpy(_streamConfig.remoteInputAesKey, [config.riKey bytes], [config.riKey length]);
    memset(_streamConfig.remoteInputAesIv, 0, 16);
    int riKeyId = htonl(config.riKeyId);
    memcpy(_streamConfig.remoteInputAesIv, &riKeyId, sizeof(riKeyId));

    LiInitializeVideoCallbacks(&_drCallbacks);
    _drCallbacks.setup = DrDecoderSetup;
    _drCallbacks.start = DrStart;
    _drCallbacks.stop = DrStop;
    _drCallbacks.capabilities = CAPABILITY_PULL_RENDERER |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC |
                                CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1;

    LiInitializeAudioCallbacks(&_arCallbacks);

    _arCallbacks.init = ArInit;
    _arCallbacks.start = ArStart;
    _arCallbacks.stop = ArStop;
    _arCallbacks.cleanup = ArCleanup;
    _arCallbacks.decodeAndPlaySample = ArDecodeAndPlaySample;
    _arCallbacks.capabilities = CAPABILITY_SUPPORTS_ARBITRARY_AUDIO_DURATION;

    LiInitializeConnectionCallbacks(&_clCallbacks);
    _clCallbacks.stageStarting = ClStageStarting;
    _clCallbacks.stageComplete = ClStageComplete;
    _clCallbacks.stageFailed = ClStageFailed;
    _clCallbacks.connectionStarted = ClConnectionStarted;
    _clCallbacks.connectionTerminated = ClConnectionTerminated;
    _clCallbacks.logMessage = ClLogMessage;
    _clCallbacks.rumble = ClRumble;
    _clCallbacks.connectionStatusUpdate = ClConnectionStatusUpdate;
    _clCallbacks.setHdrMode = ClSetHdrMode;
    _clCallbacks.rumbleTriggers = ClRumbleTriggers;
    _clCallbacks.setMotionEventState = ClSetMotionEventState;
    _clCallbacks.setControllerLED = ClSetControllerLED;

    return self;
}

-(void) main
{
    [initLock lock];
    LiStartConnection(&_serverInfo,
                      &_streamConfig,
                      &_clCallbacks,
                      &_drCallbacks,
                      &_arCallbacks,
                      NULL, 0,
                      NULL, 0);
    [initLock unlock];
}

@end
