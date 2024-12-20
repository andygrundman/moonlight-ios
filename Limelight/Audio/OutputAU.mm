#include "OutputAU.h"
#include "CoreAudioHelpers.h"

#include <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <IOKit/audio/IOAudioTypes.h>
#endif

#include <stdexcept>

#define kMaxBufferSize 4096

OutputAU::OutputAU()
    : m_SpatialBuffer(2, kMaxBufferSize)
{
    AudioComponentDescription description;
    description.componentType = kAudioUnitType_Output;
#if TARGET_OS_IPHONE
    description.componentSubType = kAudioUnitSubType_RemoteIO;
#elif TARGET_OS_OSX
    description.componentSubType = kAudioUnitSubType_HALOutput;
#endif
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    description.componentFlags = 0;
    description.componentFlagsMask = 0;

    auto comp = AudioComponentFindNext(nil, &description);
    if (!comp) {
        return;
    }

    OSStatus status = AudioComponentInstanceNew(comp, &m_OutputAU);
    if (status != noErr) {
        CA_LogError(status, "Failed to create an instance of HALOutput or RemoteIO");
        throw std::runtime_error("Failed to create an instance of HALOutput or RemoteIO");
    }
}

OutputAU::~OutputAU()
{
    if (m_OutputAU) {
        AudioComponentInstanceDispose(m_OutputAU);
    }
}

// Warning: realtime callback function
OSStatus renderCallbackSpatial(void                       * __nullable inRefCon,
                               AudioUnitRenderActionFlags * __nullable ioActionFlags,
                               const AudioTimeStamp       * __nullable inTimeStamp,
                               uint32_t                       inBusNumber,
                               uint32_t                       inNumberFrames,
                               AudioBufferList            * __nullable ioData)
{
    OutputAU *me = (OutputAU *)inRefCon;
    AudioBufferList *spatialBuffer = me->m_SpatialBuffer.get();

    // Set the byte size with the output audio buffer list.
    for (uint32_t i = 0; i < spatialBuffer->mNumberBuffers; i++) {
        spatialBuffer->mBuffers[i].mDataByteSize = inNumberFrames * sizeof(float);
    }

    // Process the input frames with the audio unit spatial mixer.
    me->m_SpatialAU.process(spatialBuffer, inTimeStamp, inNumberFrames);

    // Copy the temporary buffer to the output.
    for (uint32_t i = 0; i < spatialBuffer->mNumberBuffers; i++) {
        // Accelerate version of memcpy(ioData->mBuffers[i].mData, spatialBuffer->mBuffers[i].mData, inNumberFrames * sizeof(float));
        //memcpy(ioData->mBuffers[i].mData, spatialBuffer->mBuffers[i].mData, inNumberFrames * sizeof(float));
        vDSP_mmov((const float *)spatialBuffer->mBuffers[i].mData, (float *)ioData->mBuffers[i].mData, 1, inNumberFrames * sizeof(float), 1, 1);
    }

    return noErr;
}

// Warning: realtime callback function
OSStatus renderCallbackDirect(void                       * __nullable inRefCon,
                              AudioUnitRenderActionFlags * __nullable ioActionFlags,
                              const AudioTimeStamp       * __nullable inTimeStamp,
                              uint32_t                       inBusNumber,
                              uint32_t                       inNumberFrames,
                              AudioBufferList            * __nullable ioData)
{
    OutputAU *me = (OutputAU *)inRefCon;
    int bytesToCopy = ioData->mBuffers[0].mDataByteSize;
    float *targetBuffer = (float *)ioData->mBuffers[0].mData;

    // Pull audio from playthrough buffer
    uint32_t availableBytes;
    float *buffer = (float *)TPCircularBufferTail(&me->m_RingBuffer, &availableBytes);

    if ((int)availableBytes < bytesToCopy) {
        // write silence if not enough buffered data is available
        // faster version of memset(targetBuffer, 0, bytesToCopy);
        memset(targetBuffer, 0, bytesToCopy);
        //vDSP_vclr(targetBuffer, 1, bytesToCopy);
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    }
    else {
        // faster version of memcpy(targetBuffer, buffer, MIN(bytesToCopy, (int)availableBytes));
        memcpy(targetBuffer, buffer, MIN(bytesToCopy, (int)availableBytes));
        //vDSP_mmov(buffer, targetBuffer, 1, MIN(bytesToCopy, (int)availableBytes), 1, 1);
        TPCircularBufferConsume(&me->m_RingBuffer, MIN(bytesToCopy, (int)availableBytes));
    }

    return noErr;
}

bool OutputAU::prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig)
{
    OSStatus status = noErr;

    m_sampleRate      = opusConfig->sampleRate;
    m_channelCount    = opusConfig->channelCount;
    m_samplesPerFrame = opusConfig->samplesPerFrame;

    // Request the OS set our buffer close to the Opus packet size
    m_AudioPacketDuration = (m_samplesPerFrame / (m_sampleRate / 1000)) / 1000.0;

    if (!initAudioUnit()) {
        DEBUG_TRACE(@"initAudioUnit failed");
        return false;
    }

    if (!initRingBuffer()) {
        DEBUG_TRACE(@"initRingBuffer failed");
        return false;
    }

    AUSpatialMixerOutputType outputType = getSpatialMixerOutputType();
    DEBUG_TRACE(@"OutputAU getSpatialMixerOutputType = %d", outputType);

    m_isSpatial = false;
    if (m_channelCount > 2) {
        if (outputType != kSpatialMixerOutputType_ExternalSpeakers) {
            m_isSpatial = true;
        }
    }

    // indicate the format our callback will provide samples in
    AudioStreamBasicDescription streamDesc;
    memset(&streamDesc, 0, sizeof(AudioStreamBasicDescription));
    streamDesc.mSampleRate       = m_sampleRate;
    streamDesc.mFormatID         = kAudioFormatLinearPCM;
    streamDesc.mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    streamDesc.mFramesPerPacket  = 1;
    streamDesc.mChannelsPerFrame = (uint32_t)m_channelCount;
    streamDesc.mBitsPerChannel   = 32;
    streamDesc.mBytesPerPacket   = 4 * m_channelCount;
    streamDesc.mBytesPerFrame    = streamDesc.mBytesPerPacket;

    if (m_isSpatial) {
        // when the spatial mixer is used, the callback becomes non-interleaved
        streamDesc.mFormatFlags    |= kAudioFormatFlagIsNonInterleaved;
        streamDesc.mBytesPerPacket = 4;
        streamDesc.mBytesPerFrame  = 4;

        if (!m_SpatialAU.setup(outputType, m_sampleRate * 1.0, getSampleRate(), m_channelCount)) {
            DEBUG_TRACE(@"m_SpatialAU.setup failed");
            return false;
        }

        setCallback(this, renderCallbackSpatial);

        Log(LOG_I, @"OutputAU is using spatial audio output");
    }
    else {
        // direct CoreAudio, for stereo or when enough real channels are available (HDMI)
        setCallback(this, renderCallbackDirect);

        Log(LOG_I, @"OutputAU is using passthrough audio output");
    }

    status = AudioUnitSetProperty(m_OutputAU, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamDesc, sizeof(streamDesc));
    if (status != noErr) {
        CA_LogError(status, "Failed to set output stream format");
        return false;
    }

    return true;
}

bool OutputAU::initAudioUnit()
{
    // Initialize the audio unit interface to begin configuring it.
    OSStatus status = AudioUnitInitialize(m_OutputAU);
    if (status != noErr) {
        CA_LogError(status, "Failed to initialize the output audio unit");
        return false;
    }

    /* macOS:
     * disable OutputAU input IO
     * enable OutputAU output IO
     * get system default output AudioDeviceID  (todo: allow user to choose specific device from list)
     * set OutputAU to AudioDeviceID
     * get device's AudioStreamBasicDescription (format, bit depth, samplerate, etc)
     * get device name
     * get output buffer frame size
     * get output buffer min/max
     * set output buffer frame size
     */

    m_OutputSoftwareLatencyMin = 0.0;
    m_OutputSoftwareLatencyMax = 0.0;
    m_TotalSoftwareLatency     = 0.0025; // Opus has 2.5ms of initial delay

#if TARGET_OS_OSX
    constexpr AudioUnitElement outputElement{0};
    constexpr AudioUnitElement inputElement{1};

    {
        uint32_t enableIO = 0;
        status = AudioUnitSetProperty(m_OutputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputElement, &enableIO, sizeof(enableIO));
        if (status != noErr) {
            CA_LogError(status, "Failed to disable the input on AUHAL");
            return false;
        }

        enableIO = 1;
        status = AudioUnitSetProperty(m_OutputAU, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputElement, &enableIO, sizeof(enableIO));
        if (status != noErr) {
            CA_LogError(status, "Failed to enable the output on AUHAL");
            return false;
        }
    }

    {
        uint32_t size = sizeof(AudioDeviceID);
        AudioObjectPropertyAddress addr{kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, outputElement, nil, &size, &m_OutputDeviceID);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the default output device");
            return false;
        }
    }

    {
        CFStringRef name;
        uint32_t nameSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress addr{kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addr, 0, nil, &nameSize, &name);
        if (status != noErr) {
            CA_LogError(status, "Failed to get name of output device");
            return false;
        }
        setOutputDeviceName(name);
        CFRelease(name);
        DEBUG_TRACE(@"OutputAU default output device ID: %d, name: %s", m_OutputDeviceID, m_OutputDeviceName);
    }

    {
        // Set the current device to the default output device.
        // This should be done only after I/O is enabled on the output audio unit.
        status = AudioUnitSetProperty(m_OutputAU, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputElement, &m_OutputDeviceID, sizeof(AudioDeviceID));
        if (status != noErr) {
            CA_LogError(status, "Failed to set the default output device");
            return false;
        }
    }

    {
        uint32_t streamFormatSize = sizeof(AudioStreamBasicDescription);
        AudioObjectPropertyAddress addr{kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addr, 0, nil, &streamFormatSize, &m_OutputASBD);
        if (status != noErr) {
            CA_LogError(status, "Failed to get output device AudioStreamBasicDescription");
            return false;
        }
        CA_PrintASBD("OutputAU output format:", &m_OutputASBD);
    }

    // Buffer:
    // The goal here is to set the system buffer to our desired value, which is currently in m_AudioPacketDuration.
    // First we get the current value, and the range of allowed values, set our value, and then query to find the actual value.
    // We also query the hardware latency (e.g. Bluetooth delay for AirPods), but this is just for fun

    {
        uint32_t bufferFrameSize = 0;
        uint32_t size = sizeof(uint32_t);
        AudioObjectPropertyAddress addr{kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addr, 0, nil, &size, &bufferFrameSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device buffer frame size");
            return false;
        }
        DEBUG_TRACE(@"OutputAU output current BufferFrameSize %d", bufferFrameSize);
    }

    {
        AudioValueRange avr;
        uint32_t size = sizeof(AudioValueRange);
        AudioObjectPropertyAddress addr{kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addr, 0, nil, &size, &avr);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device buffer frame size range");
            return false;
        }
        m_OutputSoftwareLatencyMin = avr.mMinimum / m_OutputASBD.mSampleRate;
        m_OutputSoftwareLatencyMax = avr.mMaximum / m_OutputASBD.mSampleRate;
        DEBUG_TRACE(@"OutputAU output BufferFrameSizeRange: %.0f - %.0f", avr.mMinimum, avr.mMaximum);
    }

    // The latency values we have access to are:
    // kAudioDevicePropertyBufferFrameSize    our requested buffer as close to Opus packet size as possible
    //   + kAudioDevicePropertySafetyOffset   an additional CoreAudio buffer
    //   + kAudioUnitProperty_Latency         processing latency of OutputAU (+ SpatialAU in spatial mode)
    //   = total software latency
    // kAudioDevicePropertyLatency = hardware latency

    {
        double desiredBufferFrameSize = m_AudioPacketDuration;
        desiredBufferFrameSize = qMax(qMin(desiredBufferFrameSize, m_OutputSoftwareLatencyMax), m_OutputSoftwareLatencyMin);
        uint32_t bufferFrameSize = (uint32_t)(desiredBufferFrameSize * m_OutputASBD.mSampleRate);
        AudioObjectPropertyAddress addrSet{kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
        status = AudioObjectSetPropertyData(m_OutputDeviceID, &addrSet, 0, NULL, sizeof(uint32_t), &bufferFrameSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to set the output device buffer frame size");
            return false;
        }
        DEBUG_TRACE(@"OutputAU output requested BufferFrameSize of %d (%0.3f ms)", bufferFrameSize, desiredBufferFrameSize * 1000.0);

        // see what we got
        uint32_t size = sizeof(uint32_t);
        AudioObjectPropertyAddress addrGet{kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addrGet, 0, nil, &size, &m_BufferFrameSize);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device buffer frame size");
            return false;
        }
        double bufferFrameLatency = (double)m_BufferFrameSize / m_OutputASBD.mSampleRate;
        m_TotalSoftwareLatency += bufferFrameLatency;
        DEBUG_TRACE(@"OutputAU output now has actual BufferFrameSize of %d (%0.3f ms)", m_BufferFrameSize, bufferFrameLatency * 1000.0);
    }

    {
        uint32_t safetyOffsetLatency = 0;
        uint32_t size = sizeof(safetyOffsetLatency);
        AudioObjectPropertyAddress addrGet{kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addrGet, 0, nil, &size, &safetyOffsetLatency);
        if (status != noErr) {
            CA_LogError(status, "Failed to get safety offset latency");
            return false;
        }
        m_TotalSoftwareLatency += (double)safetyOffsetLatency / m_OutputASBD.mSampleRate;
        DEBUG_TRACE(@"OutputAU OutputAU safety latency: %0.2f ms", ((double)safetyOffsetLatency / m_OutputASBD.mSampleRate) * 1000.0);
    }

    {
        uint32_t latencyFrames;
        uint32_t size = sizeof(uint32_t);
        AudioObjectPropertyAddress addr{kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        status = AudioObjectGetPropertyData(m_OutputDeviceID, &addr, 0, nil, &size, &latencyFrames);
        if (status != noErr) {
            CA_LogError(status, "Failed to get the output device hardware latency");
            return false;
        }
        m_OutputHardwareLatency = (double)latencyFrames / m_OutputASBD.mSampleRate;
        DEBUG_TRACE(@"OutputAU output hardware latency: %d (%0.2f ms)", latencyFrames, m_OutputHardwareLatency * 1000.0);
    }
#endif

    {
        double audioUnitLatency = 0.0;
        uint32_t size = sizeof(audioUnitLatency);
        status = AudioUnitGetProperty(m_OutputAU, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &audioUnitLatency, &size);
        if (status != noErr) {
            CA_LogError(status, "Failed to get OutputAU AudioUnit latency");
            return false;
        }
        m_TotalSoftwareLatency += audioUnitLatency;
        DEBUG_TRACE(@"OutputAU AudioUnit latency: %0.2f ms", audioUnitLatency * 1000.0);
    }

    return true;
}

bool OutputAU::initRingBuffer()
{
    // Always buffer at least 2 packets, up to 30ms worth of packets
    int packetsToBuffer = MAX(2, (int)ceil(0.030 / m_AudioPacketDuration));

    bool ok = TPCircularBufferInit(&m_RingBuffer,
                                   sizeof(float) *
                                   m_channelCount *
                                   m_samplesPerFrame *
                                   packetsToBuffer);
    if (!ok) return false;

    // Spatial mixer code needs to be able to read from the ring buffer
    m_SpatialAU.setRingBufferPtr(&m_RingBuffer);

    // real length will be larger than requested due to memory page alignment
    m_BufferSize = m_RingBuffer.length;
    DEBUG_TRACE(@"OutputAU ring buffer init, %d packets (%d bytes)", packetsToBuffer, m_BufferSize);

    return true;
}

AUSpatialMixerOutputType OutputAU::getSpatialMixerOutputType()
{
#if TARGET_OS_OSX

    // Check if headphones are plugged in.
    UInt32 dataSource{};
    UInt32 size = sizeof(dataSource);

    AudioObjectPropertyAddress addTransType{kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectGetPropertyData(m_OutputDeviceID, &addTransType, 0, nullptr, &size, &dataSource);
    if (status != noErr) {
        CA_LogError(status, "Failed to get the transport type of output device");
        return kSpatialMixerOutputType_ExternalSpeakers;
    }

    CA_FourCC(dataSource, m_OutputTransportType);
    DEBUG_TRACE(@"OutputAU output transport type %s", m_OutputTransportType);

    if (dataSource == kAudioDeviceTransportTypeHDMI) {
        dataSource = kIOAudioOutputPortSubTypeExternalSpeaker;
    } else if (dataSource == kAudioDeviceTransportTypeBluetooth || dataSource == kAudioDeviceTransportTypeUSB) {
        dataSource = kIOAudioOutputPortSubTypeHeadphones;
    } else {
        AudioObjectPropertyAddress theAddress{kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};

        status = AudioObjectGetPropertyData(m_OutputDeviceID, &theAddress, 0, nullptr, &size, &dataSource);
        if (status != noErr) {
            CA_LogError(status, "Couldn't determine default audio device type, defaulting to ExternalSpeakers");
            return kSpatialMixerOutputType_ExternalSpeakers;
        }
    }

    CA_FourCC(dataSource, m_OutputDataSource);
    DEBUG_TRACE(@"OutputAU output data source %s", m_OutputDataSource);

    switch (dataSource) {
        case kIOAudioOutputPortSubTypeInternalSpeaker:
            return kSpatialMixerOutputType_BuiltInSpeakers;
            break;

        case kIOAudioOutputPortSubTypeHeadphones:
            return kSpatialMixerOutputType_Headphones;
            break;

        case kIOAudioOutputPortSubTypeExternalSpeaker:
            return kSpatialMixerOutputType_ExternalSpeakers;
            break;

        default:
            return kSpatialMixerOutputType_Headphones;
            break;
    }

#else

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];

    if ([audioSession.currentRoute.outputs count] != 1) {
        DEBUG_TRACE(@"OutputAU current route has multiple outputs, spatial audio disabled");
        return kSpatialMixerOutputType_ExternalSpeakers;
    }
    else {
        NSString* pType = audioSession.currentRoute.outputs.firstObject.portType;
        if (   [pType isEqualToString:AVAudioSessionPortHeadphones]
            || [pType isEqualToString:AVAudioSessionPortBluetoothA2DP]
            || [pType isEqualToString:AVAudioSessionPortBluetoothLE]
            || [pType isEqualToString:AVAudioSessionPortBluetoothHFP])
        {
            return kSpatialMixerOutputType_Headphones;
        }
        else if ([pType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            return kSpatialMixerOutputType_BuiltInSpeakers;
        }
        else {
            return kSpatialMixerOutputType_ExternalSpeakers;
        }
    }

#endif
}

void OutputAU::setCallback(void *context, AURenderCallback callback)
{
    AURenderCallbackStruct renderCallback{ callback, context };

    OSStatus status = AudioUnitSetProperty(m_OutputAU, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Output, 0, &renderCallback, sizeof(renderCallback));
    if (status != noErr) {
        CA_LogError(status, "Failed to set output render callback");
    }
}

void *OutputAU::getAudioBuffer(int *size)
{
    // This provides a buffer for the Opus API to write into.
    //
    // We must always write a full frame of audio. If we don't,
    // the reader will get out of sync with the writer and our
    // channels will get all mixed up. To ensure this is always
    // the case, round our bytes free down to the next multiple
    // of our frame size.
    uint32_t bytesFree;
    void *ptr = TPCircularBufferHead(&m_RingBuffer, &bytesFree);
    int bytesPerFrame = m_channelCount * sizeof(float);
    *size = MIN(*size, (int)(bytesFree / bytesPerFrame) * bytesPerFrame);

    m_BufferFilledBytes = m_RingBuffer.length - bytesFree;

    return ptr;
}

bool OutputAU::submitAudio(int bytesWritten)
{
    // Called after Opus has decoded bytesWritten bytes of PCM into our buffer

    if (m_needsReinit) {
        // If an audio device has changed, this flag will be set. Break out
        // so we can be recreated.
        return false;
    }

    if (bytesWritten == 0) {
        // Nothing to do
        return true;
    }

    // drop packet if we've fallen behind Moonlight's queue by at least 30 ms
    if (LiGetPendingAudioDuration() > 30) {
        return true;
    }

    // Advance the write pointer
    TPCircularBufferProduce(&m_RingBuffer, bytesWritten);

    return true;
}

double OutputAU::getSampleRate()
{
#if TARGET_OS_OSX
    AudioStreamBasicDescription asbd = {};
    uint32_t streamFormatSize = sizeof(AudioStreamBasicDescription);
    AudioObjectPropertyAddress streamFormatAddress{kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};

    OSStatus status = AudioObjectGetPropertyData(m_OutputDeviceID, &streamFormatAddress, 0, nil, &streamFormatSize, &asbd);
    if (status != noErr) {
        return -1;
    }
    return asbd.mSampleRate;
#else
    double outSampleRate = 0.0;
    uint32_t size = sizeof(double);
    OSStatus status = AudioUnitGetProperty(m_OutputAU, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &outSampleRate, &size);
    if (status != noErr) {
        return -1;
    }
    return outSampleRate;
#endif
}

bool OutputAU::start()
{
    return AudioOutputUnitStart(m_OutputAU) == noErr;
}

bool OutputAU::stop()
{
    return AudioOutputUnitStop(m_OutputAU) == noErr;
}

bool OutputAU::isSpatial()
{
    return m_isSpatial;
}

OSStatus OutputAU::setOutputType(AUSpatialMixerOutputType outputType)
{
    return m_SpatialAU.setOutputType(outputType);
}
