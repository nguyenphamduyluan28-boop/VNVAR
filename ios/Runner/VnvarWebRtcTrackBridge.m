#import "VnvarWebRtcTrackBridge.h"
#import <AVFoundation/AVFoundation.h>
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
  @autoreleasepool {
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
}

+ (RTCCameraVideoCapturer * _Nullable)activeVideoCapturer {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (plugin != nil && plugin.videoCapturer != nil) {
    return plugin.videoCapturer;
  }
  return nil;
}

+ (AVCaptureDevice * _Nullable)activeVideoDeviceForTrackId:(NSString *)trackId {
  RTCCameraVideoCapturer *capturer = [self activeVideoCapturer];
  if (capturer != nil && capturer.captureSession != nil) {
    for (AVCaptureInput *input in capturer.captureSession.inputs) {
      if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        return ((AVCaptureDeviceInput *)input).device;
      }
    }
  }
  return nil;
}

+ (void)switchCameraForTrackId:(NSString *)trackId
                    toDeviceId:(NSString *)deviceId
                    completion:(void (^)(BOOL success, NSString * _Nullable error))completion {
  if (deviceId.length == 0) {
    if (completion) completion(NO, @"Empty deviceId");
    return;
  }
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (plugin == nil || plugin.videoCapturer == nil) {
    NSLog(@"[CAMERA] FlutterWebRTCPlugin or videoCapturer is nil");
    if (completion) completion(NO, @"Plugin or videoCapturer is nil");
    return;
  }
  RTCCameraVideoCapturer *capturer = plugin.videoCapturer;

  AVCaptureDevice *targetDevice = [AVCaptureDevice deviceWithUniqueID:deviceId];
  if (targetDevice == nil) {
    NSLog(@"[CAMERA] targetDevice with uniqueID %@ not found", deviceId);
    if (completion) completion(NO, @"Device not found");
    return;
  }

  // Check if already capturing on target device
  if (capturer.captureSession != nil) {
    for (AVCaptureInput *input in capturer.captureSession.inputs) {
      if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
        if ([((AVCaptureDeviceInput *)input).device.uniqueID isEqualToString:deviceId]) {
          if (completion) completion(YES, nil);
          return;
        }
      }
    }
  }

  NSInteger targetWidth = plugin._lastTargetWidth > 0 ? plugin._lastTargetWidth : 1920;
  NSInteger targetHeight = plugin._lastTargetHeight > 0 ? plugin._lastTargetHeight : 1080;
  NSInteger targetFps = plugin._lastTargetFps > 0 ? plugin._lastTargetFps : 30;

  NSArray<AVCaptureDeviceFormat *> *formats = [RTCCameraVideoCapturer supportedFormatsForDevice:targetDevice];
  AVCaptureDeviceFormat *selectedFormat = nil;
  long currentDiff = INT_MAX;
  for (AVCaptureDeviceFormat *format in formats) {
    CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    long diff = labs(targetWidth - dimension.width) + labs(targetHeight - dimension.height);
    if (diff < currentDiff) {
      selectedFormat = format;
      currentDiff = diff;
    }
  }
  if (selectedFormat == nil && formats.count > 0) {
    selectedFormat = formats.firstObject;
  }

  Float64 maxSupportedFps = 0;
  for (AVFrameRateRange *range in selectedFormat.videoSupportedFrameRateRanges) {
    if (range.maxFrameRate > maxSupportedFps) {
      maxSupportedFps = range.maxFrameRate;
    }
  }
  NSInteger fps = MIN(targetFps, (NSInteger)maxSupportedFps);
  if (fps <= 0) fps = 30;

#if TARGET_OS_IPHONE
  [capturer stopCapture];
#endif

  [capturer startCaptureWithDevice:targetDevice
                            format:selectedFormat
                               fps:fps
                 completionHandler:^(NSError * _Nullable error) {
    if (error != nil) {
      NSLog(@"[CAMERA] startCaptureWithDevice failed: %@", error);
      if (completion) completion(NO, error.localizedDescription);
    } else {
      NSLog(@"[CAMERA] Successfully switched iOS camera to device %@", targetDevice.localizedName);
      plugin._usingFrontCamera = (targetDevice.position == AVCaptureDevicePositionFront);
      if (completion) completion(YES, nil);
    }
  }];
}

+ (BOOL)setCameraLockForTrackId:(NSString *)trackId locked:(BOOL)locked {
  AVCaptureDevice *device = [self activeVideoDeviceForTrackId:trackId];
  if (device == nil) {
    NSLog(@"[CAMERA_LOCK] No active AVCaptureDevice found for trackId %@", trackId);
    return NO;
  }

  NSError *error = nil;
  if (![device lockForConfiguration:&error]) {
    NSLog(@"[CAMERA_LOCK] lockForConfiguration failed: %@", error);
    return NO;
  }

  @try {
    if (locked) {
      if ([device isExposureModeSupported:AVCaptureExposureModeLocked]) {
        device.exposureMode = AVCaptureExposureModeLocked;
      }
      if ([device isFocusModeSupported:AVCaptureFocusModeLocked]) {
        device.focusMode = AVCaptureFocusModeLocked;
      }
      if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
        device.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
      }
      NSLog(@"[CAMERA_LOCK] Successfully locked AE/AF/AWB on %@", device.localizedName);
    } else {
      if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
      }
      if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
        device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
      }
      if ([device isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance]) {
        device.whiteBalanceMode = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
      }
      NSLog(@"[CAMERA_LOCK] Successfully set AE/AF/AWB to Continuous Auto on %@", device.localizedName);
    }
  } @catch (NSException *exception) {
    NSLog(@"[CAMERA_LOCK] Exception during configuration: %@", exception);
    [device unlockForConfiguration];
    return NO;
  }
  [device unlockForConfiguration];
  return YES;
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
