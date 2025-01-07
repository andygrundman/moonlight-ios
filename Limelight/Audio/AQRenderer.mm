
#import "AQRenderer.h"
#import "TPCircularBuffer.h"
#import "CoreAudioHelpers.h"

#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <Limelight.h>

#define AUDIO_QUEUE_BUFFERS 3
#define BUFFER_DURATION_MS 80

// global used by FillOutputBuffer
static OPUS_MULTISTREAM_CONFIGURATION opusConfig;

// forward declaration
void FillOutputBuffer(void *, AudioQueueRef, AudioQueueBufferRef);

@implementation AQRenderer
{
    AudioQueueRef _audioQueue;
    AudioQueueBufferRef _audioBuffers[AUDIO_QUEUE_BUFFERS];
    AudioChannelLayout _channelLayout;
    TPCircularBuffer _ringBuffer;

    int _samplesPerFrame;
    int _channels;
    int _sampleRateOpus;
    int _sampleRateHW;
    double _bufferDuration;
    bool _needsReinit;
}

-(void)dealloc
{
    if (_audioQueue != nil) {
        [self stop];
    }
}

static void logAudioQueueProperty(AudioQueueRef aq, AudioQueuePropertyID inID) {
    uint32_t propertySize;

    OSStatus status = AudioQueueGetPropertySize(aq, inID, &propertySize);
    if (status == noErr && propertySize > 0) {
        // there is valid cookie data to be fetched;  get it
        Byte *value = (Byte *)malloc(propertySize);
        status = AudioQueueGetProperty(aq, inID, value, &propertySize);
        if (status != noErr) {
            DEBUG_TRACE(@"AQR AudioQueueGetProperty(%d) size %d:", inID, propertySize);
            CA_HexDump((const uint8_t *)value, propertySize);
        }
        else {
            CA_LogError(status, "AQR AudioQueueGetProperty failed");
        }
        free(value);
    }
    else {
        CA_LogError(status, "AQR AudioQueueGetPropertySize failed");
    }
}

void FillOutputBuffer(void *userData,
                             AudioQueueRef inAQ,
                             AudioQueueBufferRef inBuffer) {
    TPCircularBuffer *_ringBufferPtr = (TPCircularBuffer *)userData;

    inBuffer->mAudioDataByteSize = opusConfig.channelCount * opusConfig.samplesPerFrame * sizeof(float);
    assert(inBuffer->mAudioDataByteSize == inBuffer->mAudioDataBytesCapacity);

    // Pull PCM from ring buffer
    uint32_t availableBytes;
    unsigned char *buffer = (unsigned char *)TPCircularBufferTail(_ringBufferPtr, &availableBytes);

    if (availableBytes >= inBuffer->mAudioDataByteSize) {
        //memcpy(buffer, inBuffer->mAudioData, availableBytes);
        vDSP_mmov((const float *)inBuffer->mAudioData, (float *)buffer, 1, inBuffer->mAudioDataByteSize, 1, 1);
        TPCircularBufferConsume(_ringBufferPtr, inBuffer->mAudioDataByteSize);

        AudioTimeStamp outActualStartTime;
        OSStatus status = AudioQueueEnqueueBufferWithParameters(inAQ, inBuffer, 0, NULL,
                                                                0, 0, 0, NULL, NULL, &outActualStartTime);
        if (status != noErr) {
            DEBUG_TRACE(@"AQR error calling AudioQueueEnqueueBufferWithParameters: %d", status);
        }

        DEBUG_TRACE(@"AQR FillOutputBuffer filled %d, will play at %f", inBuffer->mAudioDataByteSize, outActualStartTime.mHostTime);

        static int once = 0;
        if (once++ < 5) {
            DEBUG_TRACE(@"inBuffer->mAudioData:");
            CA_HexDump((const uint8_t *)inBuffer->mAudioData, 128);
        }
    }
    else {
        vDSP_vclr((float *)inBuffer->mAudioData, 1, inBuffer->mAudioDataByteSize);
        DEBUG_TRACE(@"AQR FillOutputBuffer starved, wanted %d, buffer only had %d", inBuffer->mAudioDataByteSize, availableBytes);
    }
}

-(instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)inOpusConfig
{
    self = [super init];

    opusConfig       = *inOpusConfig;
    _samplesPerFrame = inOpusConfig->samplesPerFrame;
    _channels        = inOpusConfig->channelCount;
    _sampleRateOpus  = inOpusConfig->sampleRate;

    // init ring buffer, entries = 16 when duration = 80ms and packet size 5ms
    int bufferEntries = BUFFER_DURATION_MS / (_samplesPerFrame / (_sampleRateOpus / 1000.0));

    int ringBufferSize = bufferEntries * _channels * _samplesPerFrame * sizeof(float);
    bool ok = TPCircularBufferInit(&_ringBuffer, ringBufferSize);
    if (!ok) {
        CA_LogError(-1, "TPCircularBufferInit failed");
        return nil;
    }
    DEBUG_TRACE(@"AQR ringBuffer created for %d entries, size %d", bufferEntries, ringBufferSize);

    //

    // setup AVAudioSession
    NSError *error = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];

    { // samplerate, not sure this makes sense but I saw it somewhere
        double currentSampleRatee = [session sampleRate];
        [session setPreferredSampleRate:currentSampleRatee error:&error];
        if (error != nil) {
            CA_LogError(-1, "failed to set preferred samplerate to %.0f: %@", _sampleRateHW, error.localizedDescription);
            // maybe ok?
        }
        double actualSampleRate = [session sampleRate];
        DEBUG_TRACE(@"AQR setPreferredSampleRate %f, got %f", _sampleRateHW, actualSampleRate);
        _sampleRateHW = actualSampleRate;
    }

    { // session category
        [session setCategory:AVAudioSessionCategoryPlayback
                 withOptions:AVAudioSessionCategoryOptionMixWithOthers
                       error:&error];
        if (error != nil) {
            CA_LogError(-1, "failed to setCategory: %@", error.localizedDescription);
            return nil;
        }
        DEBUG_TRACE(@"AQR setCategory:AVAudioSessionCategoryPlayback");
    }

    { // set buffer to 5ms
        double wantedBuffer = (_samplesPerFrame / (_sampleRateOpus / 1000.0)) / 1000.0;
        [session setPreferredIOBufferDuration:wantedBuffer
                                        error:&error];
        if (error != nil) {
            CA_LogError(-1, "AQR failed to setPreferredIOBufferDuration to %f: %@", wantedBuffer, error.localizedDescription);
            return nil;
        }
        // query again to determine the real value
        _bufferDuration = [session IOBufferDuration];
        DEBUG_TRACE(@"AQR setPreferredIOBufferDuration %f, actual %f", wantedBuffer, _bufferDuration);
    }

    { // multichannel
        // XXX correct setting for spatial?
        NSError *error = nil;
        Log(LOG_I, @"Multichannel output is available, will use passthrough mode");
        [session setPreferredOutputNumberOfChannels:_channels error:&error];
        if (error != nil) {
            Log(LOG_W, @"Warning: failed to setPreferredOutputNumberOfChannels to %d: %@", _channels, error.localizedDescription);
            // probably ok to continue
        }
    }

    { // notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleRouteChange:)
                                                     name:AVAudioSessionRouteChangeNotification
                                                   object:nil];
    }

    return self;
}

-(void)start {
    NSError *error = nil;
    AVAudioSession* session = [AVAudioSession sharedInstance];

    [session setActive: YES error:&error];
    if (error != nil) {
        CA_LogError(-1, "AQR failed to setActive:YES: %@", error.localizedDescription);
        return;
    }
    DEBUG_TRACE(@"AQR setActive:YES");

    // setup AudioQueue
    AudioStreamBasicDescription streamDesc;
    memset(&streamDesc, 0, sizeof(AudioStreamBasicDescription));
    streamDesc.mSampleRate       = 48000.0;
    streamDesc.mFormatID         = kAudioFormatLinearPCM;
    streamDesc.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    streamDesc.mFramesPerPacket  = 1;
    streamDesc.mChannelsPerFrame = (uint32_t)_channels;
    streamDesc.mBitsPerChannel   = 32;
    streamDesc.mBytesPerPacket   = 4 * _channels;
    streamDesc.mBytesPerFrame    = streamDesc.mBytesPerPacket;

    // setup AudioQueue
    OSStatus status = AudioQueueNewOutput(&streamDesc, FillOutputBuffer, &_ringBuffer,
                                          NULL, NULL, 0, &_audioQueue);
    if (status != noErr) {
        CA_LogError(status, "Error calling AudioQueueNewOutput");
        return;
    }

    if (status != noErr) {
        CA_LogError(status, "Error calling AudioQueueNewOutputWithDispatchQueue");
        return;
    }

    // We need to specify a channel layout for surround sound configurations
    memset(&_channelLayout, 0, sizeof(AudioChannelLayout));
    switch (_channels) {
        case 2:
            _channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
            break;
        case 6:
            _channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_WAVE_5_1_B; // L R C LFE Rls Rrs
            break;
        case 8:
            _channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_WAVE_7_1; // L R C LFE Rls Rrs Ls Rs
            break;
        default:
            // Unsupported channel layout
            Log(LOG_E, @"Unsupported channel count: %d\n", _channels);
            return;
    }
    status = AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_ChannelLayout, &_channelLayout, sizeof(_channelLayout));
    if (status != noErr) {
        CA_LogError(status, "AQR Error configuring ChannelLayout");
        return;
    }

    // init buffers
    for (int i = 0; i < AUDIO_QUEUE_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(_audioQueue, streamDesc.mBytesPerFrame * _samplesPerFrame, &_audioBuffers[i]);
        if (status != noErr) {
            CA_LogError(status, "AQR error calling AudioQueueAllocateBuffer");
            return;
        }

        FillOutputBuffer(&_ringBuffer, _audioQueue, _audioBuffers[i]);
    }

//    // prime the buffers
//    uint32_t framesPrimed = 0;
//    status = AudioQueuePrime(_audioQueue, 1, &framesPrimed);
//    if (status != noErr) {
//        CA_LogError(status, "AQR Error running AudioQueuePrime");
//        return nil;
//    }
//    DEBUG_TRACE(@"AQR AudioQueuePrime primed %d frames", framesPrimed);

    // start!
    status = AudioQueueStart(_audioQueue, nil);
    if (status != noErr) {
        CA_LogError(status, "AQR error calling AudioQueueStart");
        return;
    }
    DEBUG_TRACE(@"AQR AudioQueueStart");

    // check some AudioQueue properties
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_IsRunning);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_ConverterError);
//    logAudioQueueProperty(_audioQueue, kAudioQueueDeviceProperty_SampleRate);
//    logAudioQueueProperty(_audioQueue, kAudioQueueDeviceProperty_NumberChannels);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_ChannelLayout);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_CurrentDevice);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_DecodeBufferSizeFrames);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_MagicCookie);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_MaximumOutputPacketSize);
//    logAudioQueueProperty(_audioQueue, kAudioQueueProperty_StreamDescription);
}

-(void)stop {
    // stop queue
    OSStatus status = AudioQueueStop(_audioQueue, YES);
    if (status != noErr) {
        CA_LogError(status, "AQR error calling AudioQueueStop, ignoring...");
    }

    AudioQueueDispose(_audioQueue, YES);

    TPCircularBufferCleanup(&_ringBuffer);

    NSError *error = nil;
    [[AVAudioSession sharedInstance] setActive:NO error:&error];
    if (error != nil) {
        CA_LogError(-1, "failed to setActive:NO: %@, ignoring...", error.localizedDescription);
    }
}

-(void *)getAudioBuffer:(int *)size
{
    // This provides a buffer for the Opus API to write into.
    //
    // We must always write a full frame of audio. If we don't,
    // the reader will get out of sync with the writer and our
    // channels will get all mixed up. To ensure this is always
    // the case, round our bytes free down to the next multiple
    // of our frame size.
    uint32_t bytesFree;
    void *ptr = TPCircularBufferHead(&_ringBuffer, &bytesFree);
    int bytesPerFrame = _channels * sizeof(float);
    DEBUG_TRACE(@"getAudioBuffer wanted %d, bytesFree %d, allowed %d", *size, bytesFree, MIN(*size, (int)(bytesFree / bytesPerFrame) * bytesPerFrame));
    *size = MIN(*size, (int)(bytesFree / bytesPerFrame) * bytesPerFrame);

    return ptr;
}

-(bool)submitAudio:(int)bytesWritten
{
    // Called after Opus has decoded bytesWritten bytes of PCM into our buffer

    if (_needsReinit) {
        // If an audio device has changed, this flag will be set. Break out
        // so we can be recreated.
        return false;
    }

    // drop packet if we've fallen behind Moonlight's queue by at least 30 ms
//    int pendingAudio = LiGetPendingAudioDuration();
//    if (pendingAudio > 30) {
//        DEBUG_TRACE(@"submitAudio skip-ahead, pending audio duration: %d ms", pendingAudio);
//        return true;
//    }

    // Advance the write pointer
    TPCircularBufferProduce(&_ringBuffer, bytesWritten);

    return true;
}

-(void)handleRouteChange:(NSNotification *)notification
{
    Log(LOG_I, @"AQR route change");

    // always reinit on a change
    _needsReinit = true;

    [self stop];
}

@end
