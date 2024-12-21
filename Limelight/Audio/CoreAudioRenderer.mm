
#import "CoreAudioRenderer.h"
#import "OutputAU.h"

#include <Limelight.h>

@implementation CoreAudioRenderer
{
    OutputAU m_OutputAU;
    bool hasPlayedAudio;
}

-(instancetype)initWithConfig:(const OPUS_MULTISTREAM_CONFIGURATION *)opusConfig
{
    self = [super init];

    hasPlayedAudio = false;
    m_OutputAU.stop();

    if (!m_OutputAU.prepareForPlayback(opusConfig)) {
        return NULL;
    }

#if TARGET_OS_OSX
    // Handle macOS route changes
    m_OutputAU.initListeners();
#else
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
#endif

    return self;
}

-(void)start {
    // After the AudioUnit starts it will begin calling the callback defined in
    // prepareForPlayback() to receive PCM for playback
    m_OutputAU.start();
}

-(void)stop {
    m_OutputAU.stop();
}

-(void *)getAudioBuffer:(int *)size
{
    return m_OutputAU.getAudioBuffer(size);
}

-(BOOL)submitAudio:(int)bytesWritten
{
    if (!hasPlayedAudio) {
        hasPlayedAudio = true;

        // On first audio, set some audio session things:
        // Disable lowering volume of other audio streams
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];

#if TARGET_OS_VISION
        if (m_OutputAU.isSpatial()) {
            // define how our spatial audio works for Vision Pro:
            // XXX user can choose between FixedSpatialExperience or HeadTrackedSpatialExperience
            NSError *error;
            [session setIntendedSpatialExperience:AVAudioSessionSpatialExperienceHeadTracked options:@{
                @"AVAudioSessionSpatialExperienceOptionSoundStageSize" : AVAudioSessionSoundStageSizeLarge
                @"AVAudioSessionSpatialExperienceOptionAnchoringStrategy" : AVAudioSessionAnchoringStrategyFront
            } error:&error];
        }
#endif

    }

    return m_OutputAU.submitAudio(bytesWritten);
}

-(void)dealloc {
    DEBUG_TRACE(@"CoreAudioRenderer dealloc");
}

-(void)handleRouteChange:(NSNotification *)notification
{
    if (m_OutputAU.isSpatial()) {
        AUSpatialMixerOutputType outputType = m_OutputAU.getSpatialMixerOutputType();
        Log(LOG_I, @"CoreAudioRenderer route change -> %@", m_OutputAU.getSMOTString(outputType));
        m_OutputAU.setOutputType(outputType);
    }

    // always reinit on a change
    m_OutputAU.setNeedsReinit(true);
}

@end


//
//#if TARGET_OS_OSX
//// XXX Objective-C <-> C stuff
//OSStatus onDeviceOverload(AudioObjectID /*inObjectID*/,
//                          uint32_t /*inNumberAddresses*/,
//                          const AudioObjectPropertyAddress * /*inAddresses*/,
//                          void *inClientData)
//{
//    CoreAudioRenderer *me = (CoreAudioRenderer *)inClientData;
//    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "CoreAudioRenderer output device overload");
//    me->statsIncDeviceOverload();
//    return noErr;
//}
//
//OSStatus onAudioNeedsReinit(AudioObjectID /*inObjectID*/,
//                            uint32_t /*inNumberAddresses*/,
//                            const AudioObjectPropertyAddress * /*inAddresses*/,
//                            void *inClientData)
//{
//    CoreAudioRenderer *me = (CoreAudioRenderer *)inClientData;
//    SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION, "CoreAudioRenderer output device had a change, will reinit");
//    me->m_needsReinit = true;
//    return noErr;
//}
//#endif
//
//-(BOOL)initListeners
//{
//#if TARGET_OS_OSX
//    // events we care about on our output device
//
//    AudioObjectPropertyAddress addr{kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
//    OSStatus status = AudioObjectAddPropertyListener(m_OutputDeviceID, &addr, onDeviceOverload, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioDeviceProcessorOverload");
//        return false;
//    }
//
//    addr.mSelector = kAudioDevicePropertyDeviceHasChanged;
//    status = AudioObjectAddPropertyListener(m_OutputDeviceID, &addr, onAudioNeedsReinit, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioDevicePropertyDeviceHasChanged");
//        return false;
//    }
//
//    // non-device-specific listeners
//    addr.mSelector = kAudioHardwarePropertyServiceRestarted;
//    status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioHardwarePropertyServiceRestarted");
//        return false;
//    }
//
//    addr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
//    status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//    if (status != noErr) {
//        CA_LogError(status, "Failed to add listener for kAudioDevicePropertyIOStoppedAbnormally");
//        return false;
//    }
//#else
//    [[NSNotificationCenter defaultCenter] addObserver:self
//                                             selector:@selector(handleRouteChange:) name:AVAudioSessionRouteChangeNotification
//                                               object:nil];
//#endif
//
//    return true;
//}
//
//-(void)deinitListeners
//{
//#if TARGET_OS_OSX
//    AudioObjectPropertyAddress addr{kAudioDeviceProcessorOverload, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
//    AudioObjectRemovePropertyListener(m_OutputDeviceID, &addr, onDeviceOverload, self);
//
//    addr.mSelector = kAudioDevicePropertyDeviceHasChanged;
//    AudioObjectRemovePropertyListener(m_OutputDeviceID, &addr, onAudioNeedsReinit, self);
//
//    addr.mSelector = kAudioHardwarePropertyServiceRestarted;
//    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//
//    addr.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
//    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &addr, onAudioNeedsReinit, self);
//#endif
//}
//