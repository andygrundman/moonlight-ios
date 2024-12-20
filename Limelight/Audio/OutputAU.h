#pragma once

#include "TPCircularBuffer.h"
#include "AllocatedAudioBufferList.h"
#include "AUSpatialMixer.h"

#import <AudioToolbox/AudioToolbox.h>

#include <Limelight.h>

//#include <cstdio>

class OutputAU
{

public:
    OutputAU();
    OutputAU(const OutputAU&) = delete;
    OutputAU& operator=(const OutputAU&) = delete;
    ~OutputAU();

    bool prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig);
    bool initAudioUnit();
    bool initRingBuffer();
    AUSpatialMixerOutputType getSpatialMixerOutputType();

    void setCallback(void * context, AURenderCallback callback);
    void *getAudioBuffer(int *size);
    bool submitAudio(int bytesWritten);
    double getSampleRate();

    bool start();
    bool stop();
    bool isSpatial();
    OSStatus setOutputType(AUSpatialMixerOutputType outputType);

    friend OSStatus renderCallbackSpatial(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, uint32_t, uint32_t, AudioBufferList *);
    friend OSStatus renderCallbackDirect(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, uint32_t, uint32_t, AudioBufferList *);

private:
    AudioComponentInstance m_OutputAU{nullptr};
    AUSpatialMixer m_SpatialAU;

    // input stream metadata from opusConfig
    int m_sampleRate;
    int m_channelCount;
    int m_samplesPerFrame;

    // output device metadata
#if TARGET_OS_OSX
    AudioDeviceID m_OutputDeviceID{};
#endif
    AudioStreamBasicDescription m_OutputASBD;
    bool m_isSpatial;
    char *m_OutputDeviceName;
    char m_OutputTransportType[5];
    char m_OutputDataSource[5];

    // latency
    double m_OutputHardwareLatency;
    double m_TotalSoftwareLatency;
    double m_OutputSoftwareLatencyMin;
    double m_OutputSoftwareLatencyMax;

    // internal device state
    bool m_needsReinit;

    // buffers
    TPCircularBuffer m_RingBuffer;
    AllocatedAudioBufferList m_SpatialBuffer;
    double m_AudioPacketDuration;
    uint32_t m_BufferFrameSize;

    // stats
    uint32_t m_BufferSize;
    uint32_t m_BufferFilledBytes;
};
