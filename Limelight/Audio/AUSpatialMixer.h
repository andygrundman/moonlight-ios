#pragma once

#include "TPCircularBuffer.h"
#include "CoreAudioHelpers.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioTypes/CoreAudioTypes.h>

class AUSpatialMixer
{
public:
    AUSpatialMixer();
    AUSpatialMixer(const AUSpatialMixer& other) = delete;
    AUSpatialMixer& operator=(const AUSpatialMixer& other) = delete;
    ~AUSpatialMixer();

    AudioUnit _Nonnull & getMixer();

    bool setup(AUSpatialMixerOutputType outputType, double inSampleRate, double outSampleRate, int inChannelCount);
    OSStatus setStreamFormatAndACL(float inSampleRate, AudioChannelLayoutTag inLayoutTag, AudioUnitScope inScope, AudioUnitElement inElement);

    double getAudioUnitLatency();
    void setRingBufferPtr(const TPCircularBuffer* _Nonnull buffer);

    OSStatus setOutputType(AUSpatialMixerOutputType outputType);

    void process(AudioBufferList* __nullable outputABL, const AudioTimeStamp* __nullable inTimeStamp, float inNumberFrames);

    friend OSStatus inputCallback(void * _Nonnull, AudioUnitRenderActionFlags *_Nullable,
                                  const AudioTimeStamp * _Nullable, uint32_t, uint32_t, AudioBufferList * _Nonnull);

private:
    AudioUnit _Nonnull m_Mixer;
    const TPCircularBuffer* _Nonnull m_RingBufferPtr; // pointer to RingBuffer in OutputAU

    double m_AudioUnitLatency;
    bool m_HeadTracking;
    bool m_PersonalizedHRTF;
};
