#pragma once

#include "TPCircularBuffer.h"
#include "AllocatedAudioBufferList.h"
#include "AUSpatialMixer.h"
#include "AudioStats.h"

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
    void setCallback(void * context, AURenderCallback callback);
    bool start();
    void refreshDeviceProperties();
    void *getAudioBuffer(int *size);
    bool submitAudio(int bytesWritten, int opusBytes, CFTimeInterval decodeStartTime);
    NSString * getAudioStatsString();
    bool stop();

    AUSpatialMixerOutputType getSpatialMixerOutputType();
    NSString *getSMOTString(AUSpatialMixerOutputType type);
    double getSampleRate();
    bool isSpatial();
    OSStatus setOutputType(AUSpatialMixerOutputType outputType);
    void setNeedsReinit(bool value);

    friend OSStatus renderCallbackSpatial(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, uint32_t, uint32_t, AudioBufferList *);
    friend OSStatus renderCallbackDirect(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, uint32_t, uint32_t, AudioBufferList *);

private:
    AudioComponentInstance m_OutputAU{nullptr};
    AUSpatialMixer m_SpatialAU;

    // input stream metadata from opusConfig
    double m_sampleRateOpus;
    double m_sampleRateHW;
    int m_channelCount;
    int m_samplesPerFrame;
    double m_IOBufferDuration;

    // output device metadata
#if TARGET_OS_OSX
    AudioDeviceID m_OutputDeviceID{};
#endif
    AudioStreamBasicDescription m_OutputASBD;
    bool m_isSpatial;
    char *m_OutputDeviceName;
    char m_OutputTransportType[5];
    char m_OutputDataSource[5];
    int m_outputChannels;
    const NSString *m_outputType;

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
    uint32_t m_bitrateSum; // XXX atomic?
    uint32_t m_opusPackets;
    double m_opusToPCMTime;
    double m_PCMToOutputTime;
};
