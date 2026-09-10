#import "VnvarWebRtcTrackBridge.h"
#import <CoreImage/CoreImage.h>
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/FlutterRTCAudioSink.h>
#import <math.h>

@implementation VnvarWebRtcTrackBridge

+ (RTCVideoTrack * _Nullable)videoTrackForId:(NSString *)trackId {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (plugin == nil || trackId.length == 0) {
    return nil;
  }
  RTCMediaStreamTrack *track = [plugin trackForId:trackId peerConnectionId:nil];
  if (![track isKindOfClass:[RTCVideoTrack class]]) {
    return nil;
  }
  return (RTCVideoTrack *)track;
}

+ (CVPixelBufferRef _Nullable)copyPixelBufferForFrame:(RTCVideoFrame *)frame {
  id<RTCI420Buffer> source = [frame.buffer toI420];
  if (source == nil) {
    return nil;
  }

  // RTSP clients cannot renegotiate video dimensions in the middle of an
  // active H.264 session. Keep one stable encoded canvas for the lifetime of
  // the capture profile even when WebRTC changes frame.rotation.
  // Recording may keep the original 4K track, but encoding a second 4K H.264
  // stream for RTSP competes with MediaRecorder for VideoToolbox resources.
  // That contention is especially visible when CheckVAR rotates the recorder:
  // the live encoder can stop producing decodable frames. Cap only the RTSP
  // copy at 1080p; the source track and recorded CheckVAR clip remain 4K.
  const CGFloat outputScale = MIN(
      1.0,
      MIN(1920.0 / (CGFloat)source.width,
          1080.0 / (CGFloat)source.height));
  const int outputWidth = MAX(2, ((int)floor(source.width * outputScale)) & ~1);
  const int outputHeight = MAX(2, ((int)floor(source.height * outputScale)) & ~1);
  int rotatedWidth = source.width;
  int rotatedHeight = source.height;
  if (frame.rotation == RTCVideoRotation_90 ||
      frame.rotation == RTCVideoRotation_270) {
    rotatedWidth = source.height;
    rotatedHeight = source.width;
  }
  RTCI420Buffer *rotated = [[RTCI420Buffer alloc] initWithWidth:rotatedWidth
                                                        height:rotatedHeight];
  [RTCYUVHelper I420Rotate:source.dataY
                srcStrideY:source.strideY
                      srcU:source.dataU
                srcStrideU:source.strideU
                      srcV:source.dataV
                srcStrideV:source.strideV
                      dstY:(uint8_t *)rotated.dataY
                dstStrideY:rotated.strideY
                      dstU:(uint8_t *)rotated.dataU
                dstStrideU:rotated.strideU
                      dstV:(uint8_t *)rotated.dataV
                dstStrideV:rotated.strideV
                     width:source.width
                    height:source.height
                      mode:frame.rotation];

  NSDictionary *attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVPixelBufferRef pixelBuffer = nil;
  CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      rotatedWidth,
      rotatedHeight,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      (__bridge CFDictionaryRef)attributes,
      &pixelBuffer);
  if (status != kCVReturnSuccess || pixelBuffer == nil) {
    return nil;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  uint8_t *dstY = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
  uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
  const size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  const size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  [RTCYUVHelper I420ToNV12:rotated.dataY
                srcStrideY:rotated.strideY
                      srcU:rotated.dataU
                srcStrideU:rotated.strideU
                      srcV:rotated.dataV
                srcStrideV:rotated.strideV
                      dstY:dstY
                dstStrideY:(int)dstYStride
                     dstUV:dstUV
               dstStrideUV:(int)dstUVStride
                     width:rotated.width
                    height:rotated.height];
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  if (rotatedWidth == outputWidth && rotatedHeight == outputHeight) {
    return pixelBuffer;
  }

  // Portrait and landscape have opposite aspect ratios. Fit the fully rotated
  // image inside the stable encoder canvas instead of cropping court content.
  // The resulting letterbox is preferable to changing SPS dimensions, which
  // freezes the tablet decoder until the phone returns to its initial angle.
  CVPixelBufferRef stableBuffer = nil;
  status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      outputWidth,
      outputHeight,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      (__bridge CFDictionaryRef)attributes,
      &stableBuffer);
  if (status != kCVReturnSuccess || stableBuffer == nil) {
    CVPixelBufferRelease(pixelBuffer);
    return nil;
  }

  CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
  const CGFloat scale = MIN((CGFloat)outputWidth / rotatedWidth,
                            (CGFloat)outputHeight / rotatedHeight);
  CIImage *scaled = [image imageByApplyingTransform:
      CGAffineTransformMakeScale(scale, scale)];
  const CGFloat offsetX = ((CGFloat)outputWidth - scaled.extent.size.width) / 2.0;
  const CGFloat offsetY = ((CGFloat)outputHeight - scaled.extent.size.height) / 2.0;
  CIImage *positioned = [scaled imageByApplyingTransform:
      CGAffineTransformMakeTranslation(offsetX - scaled.extent.origin.x,
                                       offsetY - scaled.extent.origin.y)];
  const CGRect outputBounds = CGRectMake(0, 0, outputWidth, outputHeight);
  CIImage *background = [[[CIImage alloc]
      initWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
      imageByCroppingToRect:outputBounds];
  CIImage *composited = [positioned imageByCompositingOverImage:background];
  static CIContext *context;
  static CGColorSpaceRef colorSpace;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    context = [CIContext contextWithOptions:@{
      kCIContextUseSoftwareRenderer: @NO,
    }];
    colorSpace = CGColorSpaceCreateDeviceRGB();
  });
  [context render:composited
   toCVPixelBuffer:stableBuffer
            bounds:outputBounds
        colorSpace:colorSpace];
  CVPixelBufferRelease(pixelBuffer);
  return stableBuffer;
}

@end

@implementation VnvarWebRtcAudioSink {
  FlutterRTCAudioSink *_sink;
  BOOL _closed;
}

- (instancetype _Nullable)initWithTrackId:(NSString *)trackId {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  RTCMediaStreamTrack *track = [plugin trackForId:trackId peerConnectionId:nil];
  if (plugin == nil || trackId.length == 0 ||
      ![track isKindOfClass:[RTCAudioTrack class]]) return nil;
  self = [super init];
  if (self) {
    _sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:(RTCAudioTrack *)track];
    __weak VnvarWebRtcAudioSink *weakSelf = self;
    _sink.bufferCallback = ^(CMSampleBufferRef sampleBuffer) {
      VnvarWebRtcAudioSink *strongSelf = weakSelf;
      if (strongSelf == nil || strongSelf->_closed || strongSelf.onPcm == nil) return;
      CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
      CMAudioFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
      const AudioStreamBasicDescription *format = description == nil
          ? nil : CMAudioFormatDescriptionGetStreamBasicDescription(description);
      if (block == nil || format == nil || format->mFormatID != kAudioFormatLinearPCM) return;
      size_t totalLength = CMBlockBufferGetDataLength(block);
      if (totalLength == 0) return;
      NSMutableData *pcm = [NSMutableData dataWithLength:totalLength];
      OSStatus status = CMBlockBufferCopyDataBytes(
          block, 0, totalLength, pcm.mutableBytes);
      if (status != kCMBlockBufferNoErr) return;
      strongSelf.onPcm(
          pcm,
          (NSInteger)llround(format->mSampleRate),
          (NSInteger)format->mChannelsPerFrame,
          (NSInteger)format->mBitsPerChannel);
    };
  }
  return self;
}

- (void)close {
  if (_closed) return;
  _closed = YES;
  _sink.bufferCallback = nil;
  [_sink close];
  _sink = nil;
  self.onPcm = nil;
}

- (void)dealloc { [self close]; }
@end
