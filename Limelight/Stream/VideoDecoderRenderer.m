//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;
@import VideoToolbox;

#import "DataManager.h"
#import "TemporarySettings.h"
#import "VideoDecoderRenderer.h"
#import "FrameQueue.h"
#import "StreamView.h"
#import "Plot.h"
#import "PlatformThreads.h"
#import "MetalViewController.h"
#import "ImGuiPlots.h"

#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>
#include <mach/mach_time.h>

// Define for extra logging related to frame pacing
#define DISPLAYLINK_VERBOSE

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

@implementation VideoDecoderRenderer {
    dispatch_queue_t _sq, _vtq;
    StreamView* _view;
    id<ConnectionCallbacks> _callbacks;
    float _streamAspectRatio;
    int _videoFormat;
    int _frameRate;

    NSMutableArray *_parameterSetBuffers;
    NSData *_masteringDisplayColorVolume;
    NSData *_contentLightLevelInfo;
    CMVideoFormatDescriptionRef _formatDesc;
    VTDecompressionSessionRef _decompressionSession;

    FrameQueue *_frameQueue;
}

- (id)initWithView:(StreamView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio
{
    self = [super init];

    _sq = dispatch_queue_create("com.moonlight.VideoDecoderRenderer",
                                 dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

    // Video decoder needs to run at the highest priority since DisplayLink waits on it
    _vtq = dispatch_queue_create("com.moonlight.VideoDecoderRenderer.VTDecoder",
                                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));

    _view = view;
    _callbacks = callbacks;
    _streamAspectRatio = aspectRatio;
    _parameterSetBuffers = [[NSMutableArray alloc] init];

    DataManager* dataMan = [[DataManager alloc] init];

    _frameQueue = [FrameQueue sharedInstance];
    [_frameQueue start];
    [_frameQueue setHighWaterMark:(int)[[dataMan getSettings].frameQueueSize integerValue]];

    if (_formatDesc != nil) {
        CFRelease(_formatDesc);
        _formatDesc = nil;
    }

    if (_decompressionSession != nil){
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = nil;
    }

    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate
{
    self->_videoFormat = videoFormat;
    self->_frameRate = frameRate;

    // reset plot data in case we've already used it for a previous renderer
    [[ImGuiPlots sharedInstance] clearData];

    // RENDER_METAL begins in StreamFrameViewController
}

- (void)setupDecompressionSessionWithAttributes:(NSDictionary *)destinationPixelBufferAttributes {
    if (_decompressionSession != NULL) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = nil;
    }

    int status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                              _formatDesc,
                                              nil,
                                              (__bridge CFDictionaryRef)destinationPixelBufferAttributes,
                                              nil,
                                              &_decompressionSession);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create VTDecompressionSession, status %d", status);
    }
}

- (void)setupDecompressionSession {
#if TARGET_OS_SIMULATOR
    NSNumber *pixelFormat = @(kCVPixelFormatType_32BGRA);
#else
    NSNumber *pixelFormat = nil;
    if (self->_videoFormat & VIDEO_FORMAT_MASK_YUV444) {
        pixelFormat = @(kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange);
    }
    else {
        pixelFormat = @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    }
#endif

    NSDictionary *destinationPixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : pixelFormat,
        (id)kVTDecompressionPropertyKey_GeneratePerFrameHDRDisplayMetadata : @YES,
        (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder : @YES
    };

    return [self setupDecompressionSessionWithAttributes:destinationPixelBufferAttributes];
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

- (void)cleanup
{
    [_frameQueue stop];

    if (_decompressionSession != NULL) {
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = nil;
    }
}

#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (void)updateAnnexBBufferForRange:(CMBlockBufferRef)frameBuffer dataBlock:(CMBlockBufferRef)dataBuffer offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(frameBuffer);

    // Append a 4 byte buffer to the frame block for the length prefix
    status = CMBlockBufferAppendMemoryBlock(frameBuffer, NULL,
                                            NAL_LENGTH_PREFIX_SIZE,
                                            kCFAllocatorDefault, NULL, 0,
                                            NAL_LENGTH_PREFIX_SIZE, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
        return;
    }

    // Write the length prefix to the new buffer
    const int dataLength = nalLength - NALU_START_PREFIX_SIZE;
    const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
        (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
    status = CMBlockBufferReplaceDataBytes(lengthBytes, frameBuffer,
                                           oldOffset, NAL_LENGTH_PREFIX_SIZE);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
        return;
    }

    // Attach the data buffer to the frame buffer by reference
    status = CMBlockBufferAppendBufferReference(frameBuffer, dataBuffer, offset + NALU_START_PREFIX_SIZE, dataLength, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
        return;
    }
}

- (NSData*)getAv1CodecConfigurationBox:(NSData*)frameData  {
    AVIOContext* ioctx = NULL;
    int err;

    err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t*)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
        // Fall-through to close and free buffer
    }

    // Close the dynbuf and get the underlying buffer back (which we must free)
    uint8_t* av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);

    Log(LOG_I, @"av1C block is %d bytes", av1cBufLen);

    // Only return data if ff_isom_write_av1c() was successful
    NSData* data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }
    else {
        data = nil;
    }

    av_free(av1cBuf);
    return data;
}

// Much of this logic comes from Chrome
- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData*)frameData {
    NSMutableDictionary* extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext* cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return nil;
    }

    AVPacket avPacket = {};
    avPacket.data = (uint8_t*)frameData.bytes;
    avPacket.size = (int)frameData.length;

    // Read the sequence header OBU
    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (__bridge NSString*)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");

    // We use the value for YUV without alpha, same as Chrome
    // https://developer.apple.com/library/archive/qa/qa1183/_index.html
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);

    CodedBitstreamAV1Context* bitstreamCtx = (CodedBitstreamAV1Context*)cbsCtx->priv_data;
    AV1RawSequenceHeader* seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame!");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

    switch (seqHeader->color_config.color_primaries) {
        case 1: // CP_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;

        case 6: // CP_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;

        case 9: // CP_BT_2020
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;

        default:
            Log(LOG_W, @"Unsupported color_primaries value: %d", seqHeader->color_config.color_primaries);
            break;
    }

    switch (seqHeader->color_config.transfer_characteristics) {
        case 1: // TC_BT_709
        case 6: // TC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;

        case 7: // TC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;

        case 8: // TC_LINEAR
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_Linear);
            break;

        case 14: // TC_BT_2020_10_BIT
        case 15: // TC_BT_2020_12_BIT
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;

        case 16: // TC_SMPTE_2084
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;

        case 17: // TC_HLG
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;

        default:
            Log(LOG_W, @"Unsupported transfer_characteristics value: %d", seqHeader->color_config.transfer_characteristics);
            break;
    }

    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: // MC_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;

        case 6: // MC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;

        case 7: // MC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;

        case 9: // MC_BT_2020_NCL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;

        default:
            Log(LOG_W, @"Unsupported matrix_coefficients value: %d", seqHeader->color_config.matrix_coefficients);
            break;
    }

    Log(LOG_I, @"AV1 video range: %@", seqHeader->color_config.color_range == 1 ? @"full" : @"limited");
    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));

    // Progressive content
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));

    switch (seqHeader->color_config.chroma_sample_position) {
        case 1: // CSP_VERTICAL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_Left);
            break;

        case 2: // CSP_COLOCATED
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_TopLeft);
            break;

        default:
            Log(LOG_W, @"Unsupported chroma_sample_position value: %d", seqHeader->color_config.chroma_sample_position);
            break;
    }

    if (_contentLightLevelInfo) {
        SET_EXTENSION(kCMFormatDescriptionExtension_ContentLightLevelInfo, _contentLightLevelInfo);
    }

    if (_masteringDisplayColorVolume) {
        SET_EXTENSION(kCMFormatDescriptionExtension_MasteringDisplayColorVolume, _masteringDisplayColorVolume);
    }

    // Referenced the VP9 code in Chrome that performs a similar function
    // https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/mac/vt_config_util.mm;drc=977dc02c431b4979e34c7792bc3d646f649dacb4;l=155
    extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
    @{
        @"av1C" : [self getAv1CodecConfigurationBox:frameData],
    };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);

#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION

    // AV1 doesn't have a special format description function like H.264 and HEVC have, so we just use the generic one
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width, bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &formatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }

    LogOnce(LOG_I, @"AV1 extensions: %@", extensions);
    LogOnce(LOG_I, @"AV1 format description: %@", formatDesc);

    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}

#pragma mark VideoRecv thread - Decoder

// This function must free data for bufferType == BUFFER_TYPE_PICDATA
- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
               decodeUnit:(PDECODE_UNIT)du
          decodeStartTime:(CFTimeInterval)decodeStartTime
{
    OSStatus status;

    // Construct a new format description object each time we receive an IDR frame
    if (du->frameType == FRAME_TYPE_IDR) {
        if (bufferType != BUFFER_TYPE_PICDATA) {
            if (bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS) {
                // Add new parameter set into the parameter set array
                int startLen = data[2] == 0x01 ? 3 : 4;
                [_parameterSetBuffers addObject:[NSData dataWithBytes:&data[startLen] length:length - startLen]];
            }

            // Data is NOT to be freed here. It's a direct usage of the caller's buffer.

            // No frame data to submit for these NALUs
            return DR_OK;
        }

        // Create the new format description when we get the first picture data buffer of an IDR frame.
        // This is the only way we know that there is no more CSD for this frame.
        //
        // NB: This logic depends on the fact that we submit all picture data in one buffer!

        // Free the old format description
        if (_formatDesc != NULL) {
            CFRelease(_formatDesc);
            _formatDesc = NULL;
        }

        if (_videoFormat & VIDEO_FORMAT_MASK_H264) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [_parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = _parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }

            Log(LOG_I, @"Constructing new H264 format description");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &_formatDesc);
            if (status != noErr) {
                Log(LOG_E, @"Failed to create H264 format description: %d", (int)status);
                _formatDesc = NULL;
            }

            LogOnce(LOG_I, @"H264 format description: %@", _formatDesc);

            // Free parameter set buffers after submission
            [_parameterSetBuffers removeAllObjects];
        }
        else if (_videoFormat & VIDEO_FORMAT_MASK_H265) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [_parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = _parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }

            Log(LOG_I, @"Constructing new HEVC format description");

            NSMutableDictionary* videoFormatParams = [[NSMutableDictionary alloc] init];

            if (_contentLightLevelInfo) {
                [videoFormatParams setObject:_contentLightLevelInfo forKey:(__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo];
            }

            if (_masteringDisplayColorVolume) {
                [videoFormatParams setObject:_masteringDisplayColorVolume forKey:(__bridge NSString*)kCMFormatDescriptionExtension_MasteringDisplayColorVolume];
            }

            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         (__bridge CFDictionaryRef)videoFormatParams,
                                                                         &_formatDesc);

            if (status != noErr) {
                Log(LOG_E, @"Failed to create HEVC format description: %d", (int)status);
                _formatDesc = NULL;
            }

            LogOnce(LOG_I, @"HEVC format description: %@", _formatDesc);

            // Free parameter set buffers after submission
            [_parameterSetBuffers removeAllObjects];
        }
        else if (_videoFormat & VIDEO_FORMAT_MASK_AV1) {
            NSData* fullFrameData = [NSData dataWithBytesNoCopy:data length:length freeWhenDone:NO];

            Log(LOG_I, @"Constructing new AV1 format description");
            _formatDesc = [self createAV1FormatDescriptionForIDRFrame:fullFrameData];
        }
        else {
            // Unsupported codec!
            abort();
        }
    }

    if (_formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_NEED_IDR;
    }

    // Now we're decoding actual frame data here
    CMBlockBufferRef frameBlockBuffer;
    CMBlockBufferRef dataBlockBuffer;

    status = CMBlockBufferCreateWithMemoryBlock(NULL, data, length, kCFAllocatorDefault, NULL, 0, length, 0, &dataBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        free(data);
        return DR_NEED_IDR;
    }

    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced

    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &frameBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return DR_NEED_IDR;
    }

    // H.264 and HEVC formats require NAL prefix fixups from Annex B to length-delimited
    if (_videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        int lastOffset = -1;
        for (int i = 0; i < length - NALU_START_PREFIX_SIZE; i++) {
            // Search for a NALU
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                // It's the start of a new NALU
                if (lastOffset != -1) {
                    // We've seen a start before this so enqueue that NALU
                    [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:i - lastOffset];
                }

                lastOffset = i;
            }
        }

        if (lastOffset != -1) {
            // Enqueue the remaining data
            [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:length - lastOffset];
        }
    }
    else {
        // For formats that require no length-changing fixups, just append a reference to the raw data block
        status = CMBlockBufferAppendBufferReference(frameBlockBuffer, dataBlockBuffer, 0, length, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
            return DR_NEED_IDR;
        }
    }

    // Set the current frame's pts, in RTP 90khz units. We will set the duration
    // later in FrameQueue because it requires the next frame's timestamp.
    CMSampleTimingInfo sampleTiming = {
        .duration              = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake((int64_t)du->rtpTimestamp, 90000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  _formatDesc, 1, 1,
                                  &sampleTiming, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        return DR_NEED_IDR;
    }

    OSStatus decodeStatus = [self decodeFrameWithSampleBuffer:sampleBuffer
                                                  frameNumber:du->frameNumber
                                                    frameType:du->frameType
                                              decodeStartTime:decodeStartTime];
    // Dereference the buffers
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);

    return (decodeStatus == noErr) ? DR_OK : DR_NEED_IDR;
}

- (OSStatus)decodeFrameWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            frameNumber:(int)frameNumber
                              frameType:(int)frameType
                        decodeStartTime:(CFTimeInterval)decodeStartTime {
  if (frameType == FRAME_TYPE_IDR || _decompressionSession == nil) {
    [self setupDecompressionSession];
  }

  OSStatus status = VTDecompressionSessionDecodeFrameWithOutputHandler(
      _decompressionSession,
      sampleBuffer,
      0,
      NULL,
      ^(OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef _Nullable imageBuffer, CMTime presentationTimestamp, CMTime presentationDuration) {
          if (status != noErr || !imageBuffer) {
            NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
            Log(LOG_E, @"Decompression session error: %@", error);
            LiRequestIdrFrame();
            return;
          }

          // retain the pixelBuffer here so it survives the dispatch
          CVPixelBufferRef pixelBuffer = CVPixelBufferRetain((CVPixelBufferRef)imageBuffer);

          // Dispatch onto our higher priority queue
          dispatch_async(self->_vtq, ^{
              Frame *frame = [[Frame alloc] initWithPixelBufffer:pixelBuffer frameNumber:frameNumber frameType:frameType pts:presentationTimestamp];
              [frame setFormatDesc:self->_formatDesc];

              int framesDropped = [self->_frameQueue enqueue:frame withSlackSize:3];

              static PlotMetrics frameQueueMetrics = {};
              [[ImGuiPlots sharedInstance] observeFloatReturnMetrics:PLOT_QUEUED_FRAMES value:[self->_frameQueue count] plotMetrics:&frameQueueMetrics];
              [self safeCopyMetricsTo:&self->_frameQueueMetrics from:&frameQueueMetrics];

              [[ImGuiPlots sharedInstance] observeFloat:PLOT_DROPPED value:framesDropped];

              // It's important we capture host metrics on the incoming thread, as this frame object
              // may have been dropped by the above enqueue
              static CFTimeInterval lastHostFrame = 0.0f;
              if (lastHostFrame != 0) {
                [[ImGuiPlots sharedInstance] observeFloat:PLOT_HOST_FRAMETIME value:(frame.pts - lastHostFrame) * 1000.0];
              }
              lastHostFrame = frame.pts;

              // Decode time is not graphed because it is marked as hidden, but we can use the same mechanism for the value used by stats
              static PlotMetrics decodeMetrics = {};
              [[ImGuiPlots sharedInstance] observeFloatReturnMetrics:PLOT_DECODE value:(CACurrentMediaTime() - decodeStartTime) * 1000.0 plotMetrics:&decodeMetrics];
              [self safeCopyMetricsTo:&self->_decodeMetrics from:&decodeMetrics];
          });
      });

  return status;
}

- (void)setHdrMode:(BOOL)enabled {
    SS_HDR_METADATA hdrMetadata;

    BOOL hasMetadata = enabled && LiGetHdrMetadata(&hdrMetadata);
    BOOL metadataChanged = NO;

    if (hasMetadata && hdrMetadata.displayPrimaries[0].x != 0 && hdrMetadata.maxDisplayLuminance != 0) {
        // This data is all in big-endian
        struct {
          vector_ushort2 primaries[3];
          vector_ushort2 white_point;
          uint32_t luminance_max;
          uint32_t luminance_min;
        } __attribute__((packed, aligned(4))) mdcv;

        // mdcv is in GBR order while SS_HDR_METADATA is in RGB order
        mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata.displayPrimaries[1].x);
        mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata.displayPrimaries[1].y);
        mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata.displayPrimaries[2].x);
        mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata.displayPrimaries[2].y);
        mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata.displayPrimaries[0].x);
        mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata.displayPrimaries[0].y);

        mdcv.white_point.x = __builtin_bswap16(hdrMetadata.whitePoint.x);
        mdcv.white_point.y = __builtin_bswap16(hdrMetadata.whitePoint.y);

        // These luminance values are in 10000ths of a nit
        mdcv.luminance_max = __builtin_bswap32((uint32_t)hdrMetadata.maxDisplayLuminance * 10000);
        mdcv.luminance_min = __builtin_bswap32(hdrMetadata.minDisplayLuminance);

        NSData* newMdcv = [NSData dataWithBytes:&mdcv length:sizeof(mdcv)];
        if (_masteringDisplayColorVolume == nil || ![newMdcv isEqualToData:_masteringDisplayColorVolume]) {
            _masteringDisplayColorVolume = newMdcv;
            metadataChanged = YES;

            Log(LOG_I, @"HDR Mastering Display Color Volume: G(%d,%d) B(%d,%d) R(%d,%d) white point(%d,%d) luminance (%d,%d)",
                mdcv.primaries[0].x, mdcv.primaries[0].y,
                mdcv.primaries[1].x, mdcv.primaries[1].y,
                mdcv.primaries[2].x, mdcv.primaries[2].y,
                mdcv.white_point.x, mdcv.white_point.y,
                mdcv.luminance_max, mdcv.luminance_min);
        }
    }
    else if (_masteringDisplayColorVolume != nil) {
        _masteringDisplayColorVolume = nil;
        metadataChanged = YES;
    }

    if (hasMetadata && hdrMetadata.maxContentLightLevel != 0 && hdrMetadata.maxFrameAverageLightLevel != 0) {
        // This data is all in big-endian
        struct {
            uint16_t max_content_light_level;
            uint16_t max_frame_average_light_level;
        } __attribute__((packed, aligned(2))) cll;

        cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
        cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

        NSData* newCll = [NSData dataWithBytes:&cll length:sizeof(cll)];
        if (_contentLightLevelInfo == nil || ![newCll isEqualToData:_contentLightLevelInfo]) {
            _contentLightLevelInfo = newCll;
            metadataChanged = YES;

            Log(LOG_I, @"HDR maxCLL: %d maxFALL: %d",
                cll.max_content_light_level, cll.max_frame_average_light_level);
        }
    }
    else if (_contentLightLevelInfo != nil) {
        _contentLightLevelInfo = nil;
        metadataChanged = YES;
    }

    // If the metadata changed, request an IDR frame to re-create the CMVideoFormatDescription
    if (metadataChanged) {
        LiRequestIdrFrame();
    }
}

- (void)safeCopyMetricsTo:(PlotMetrics *)dst from:(PlotMetrics *)src {
    if (dst != nil && src != nil) {
        dispatch_sync(_sq, ^{
            memcpy(dst, src, sizeof(PlotMetrics));
        });
    }
}

- (void)getAllStats:(video_stats_t *)stats {
    dispatch_sync(_sq, ^{
        memcpy(&stats->decodeMetrics, &_decodeMetrics, sizeof(PlotMetrics));
        memcpy(&stats->frameQueueMetrics, &_frameQueueMetrics, sizeof(PlotMetrics));
        [_frameQueue.frameDropMetrics copyMetrics:&stats->frameDropMetrics];
    });
}

@end
