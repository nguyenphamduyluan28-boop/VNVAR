#import "VnvarWebRtcTrackBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
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

// RTSP clients cannot renegotiate video dimensions in the middle of an active
// H.264 session. Keep one stable encoded canvas for the lifetime of the capture
// profile even when WebRTC changes frame.rotation.
// Recording may keep the original 4K track, but encoding a second 4K H.264
// stream for RTSP competes with MediaRecorder for VideoToolbox resources. That
// contention is especially visible when CheckVAR rotates the recorder: the live
// encoder can stop producing decodable frames. Cap only the RTSP copy at 1080p;
// the source track and recorded CheckVAR clip remain 4K.
static void VnvarOutputSize(int sourceWidth, int sourceHeight,
                            int *outputWidth, int *outputHeight) {
  const CGFloat outputScale = MIN(
      1.0,
      MIN(1920.0 / (CGFloat)MAX(1, sourceWidth),
          1080.0 / (CGFloat)MAX(1, sourceHeight)));
  *outputWidth = MAX(2, ((int)floor(sourceWidth * outputScale)) & ~1);
  *outputHeight = MAX(2, ((int)floor(sourceHeight * outputScale)) & ~1);
}

static CIContext *VnvarSharedCIContext(CGColorSpaceRef *colorSpaceOut) {
  static CIContext *context;
  static CGColorSpaceRef colorSpace;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    context = [CIContext contextWithOptions:@{
      kCIContextUseSoftwareRenderer: @NO,
    }];
    colorSpace = CGColorSpaceCreateDeviceRGB();
  });
  if (colorSpaceOut != NULL) *colorSpaceOut = colorSpace;
  return context;
}

// Pool NV12 cho canvas RTSP: tránh cấp phát IOSurface mới mỗi khung. Chỉ
// truy cập trong @synchronized; được nhả bởi +releaseConversionResources.
static CVPixelBufferPoolRef gVnvarOutputPool = NULL;
static int gVnvarOutputPoolWidth = 0;
static int gVnvarOutputPoolHeight = 0;

static CVPixelBufferRef VnvarCreateOutputBuffer(int width, int height) {
  CVPixelBufferRef buffer = NULL;
  @synchronized ([VnvarWebRtcTrackBridge class]) {
    if (gVnvarOutputPool == NULL ||
        gVnvarOutputPoolWidth != width ||
        gVnvarOutputPoolHeight != height) {
      if (gVnvarOutputPool != NULL) {
        CVPixelBufferPoolRelease(gVnvarOutputPool);
        gVnvarOutputPool = NULL;
      }
      NSDictionary *pixelAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
      };
      NSDictionary *poolAttributes = @{
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @3,
      };
      CVPixelBufferPoolRef pool = NULL;
      CVReturn poolStatus = CVPixelBufferPoolCreate(
          kCFAllocatorDefault,
          (__bridge CFDictionaryRef)poolAttributes,
          (__bridge CFDictionaryRef)pixelAttributes,
          &pool);
      if (poolStatus == kCVReturnSuccess && pool != NULL) {
        gVnvarOutputPool = pool;
        gVnvarOutputPoolWidth = width;
        gVnvarOutputPoolHeight = height;
      }
    }
    if (gVnvarOutputPool != NULL) {
      CVReturn status = CVPixelBufferPoolCreatePixelBuffer(
          kCFAllocatorDefault, gVnvarOutputPool, &buffer);
      if (status != kCVReturnSuccess) buffer = NULL;
    }
  }
  if (buffer != NULL) return buffer;
  // Pool lỗi: cấp phát trực tiếp như trước.
  NSDictionary *attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
  };
  CVReturn status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      (__bridge CFDictionaryRef)attributes,
      &buffer);
  return status == kCVReturnSuccess ? buffer : NULL;
}

// Portrait and landscape have opposite aspect ratios. Fit the fully rotated
// image inside the stable encoder canvas instead of cropping court content.
// The resulting letterbox is preferable to changing SPS dimensions, which
// freezes the tablet decoder until the phone returns to its initial angle.
static CIImage *VnvarFittedImage(CIImage *image,
                                 int outputWidth,
                                 int outputHeight) {
  const CGRect extent = image.extent;
  const CGFloat scale = MIN((CGFloat)outputWidth / MAX(1.0, extent.size.width),
                            (CGFloat)outputHeight / MAX(1.0, extent.size.height));
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
  return [positioned imageByCompositingOverImage:background];
}

static void VnvarRenderFitted(CIImage *image,
                              CVPixelBufferRef destination,
                              int outputWidth,
                              int outputHeight) {
  const CGRect outputBounds = CGRectMake(0, 0, outputWidth, outputHeight);
  CIImage *composited = VnvarFittedImage(image, outputWidth, outputHeight);
  CGColorSpaceRef colorSpace = NULL;
  CIContext *context = VnvarSharedCIContext(&colorSpace);
  [context render:composited
   toCVPixelBuffer:destination
            bounds:outputBounds
        colorSpace:colorSpace];
}

// WebRTC rotation = góc cần xoay THEO CHIỀU KIM ĐỒNG HỒ để hiển thị đúng
// (giống libyuv kRotate90). CGImagePropertyOrientation .right nghĩa là ảnh
// được hiển thị sau khi xoay 90° theo chiều kim đồng hồ.
static CGImagePropertyOrientation VnvarOrientation(RTCVideoRotation rotation) {
  switch (rotation) {
    case RTCVideoRotation_90:
      return kCGImagePropertyOrientationRight;
    case RTCVideoRotation_180:
      return kCGImagePropertyOrientationDown;
    case RTCVideoRotation_270:
      return kCGImagePropertyOrientationLeft;
    default:
      return kCGImagePropertyOrientationUp;
  }
}

// Đường nhanh cho khung camera (RTCCVPixelBuffer): không chuyển qua I420 trên
// CPU. Crop/xoay/scale đều do Core Image trên GPU, ghi thẳng vào buffer NV12
// từ pool. Không cần crop/xoay/scale và đã là NV12 thì đưa thẳng buffer gốc
// cho VideoToolbox (giống RTCVideoEncoderH264 của WebRTC). Trả NULL để caller
// rơi về đường I420.
static CVPixelBufferRef VnvarCopyFromNativeBuffer(RTCCVPixelBuffer *buffer,
                                                  RTCVideoRotation rotation) {
  CVPixelBufferRef source = buffer.pixelBuffer;
  if (source == NULL) return NULL;
  const int bufferWidth = (int)CVPixelBufferGetWidth(source);
  const int bufferHeight = (int)CVPixelBufferGetHeight(source);
  if (bufferWidth <= 0 || bufferHeight <= 0 ||
      buffer.cropWidth <= 0 || buffer.cropHeight <= 0 ||
      buffer.cropX < 0 || buffer.cropY < 0 ||
      buffer.cropX + buffer.cropWidth > bufferWidth ||
      buffer.cropY + buffer.cropHeight > bufferHeight) {
    return NULL;
  }
  // Canvas theo kích thước logic (chưa xoay) của khung, như đường I420.
  int outputWidth = 0;
  int outputHeight = 0;
  VnvarOutputSize(buffer.width, buffer.height, &outputWidth, &outputHeight);

  const BOOL cropped = buffer.cropX != 0 || buffer.cropY != 0 ||
      buffer.cropWidth != bufferWidth || buffer.cropHeight != bufferHeight;
  const OSType format = CVPixelBufferGetPixelFormatType(source);
  const BOOL isNV12 =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  if (!cropped && rotation == RTCVideoRotation_0 && isNV12 &&
      bufferWidth == outputWidth && bufferHeight == outputHeight) {
    return CVPixelBufferRetain(source);
  }

  CIImage *image = [CIImage imageWithCVPixelBuffer:source];
  if (image == nil) return NULL;
  if (cropped) {
    // Gốc toạ độ Core Image ở góc dưới-trái; cropY tính từ hàng trên cùng.
    const CGRect cropRect = CGRectMake(
        buffer.cropX,
        bufferHeight - buffer.cropY - buffer.cropHeight,
        buffer.cropWidth,
        buffer.cropHeight);
    image = [image imageByCroppingToRect:cropRect];
  }
  if (rotation != RTCVideoRotation_0) {
    image = [image imageByApplyingCGOrientation:VnvarOrientation(rotation)];
  }
  CVPixelBufferRef destination = VnvarCreateOutputBuffer(outputWidth, outputHeight);
  if (destination == NULL) return NULL;
  VnvarRenderFitted(image, destination, outputWidth, outputHeight);
  return destination;
}

// Như VnvarCopyFromNativeBuffer nhưng KHÔNG render: trả đồ thị CIImage của
// canvas (crop/xoay/letterbox) để luồng overlay chồng ảnh rồi render một lần.
static CIImage *VnvarCanvasImageFromNativeBuffer(RTCCVPixelBuffer *buffer,
                                                 RTCVideoRotation rotation) {
  CVPixelBufferRef source = buffer.pixelBuffer;
  if (source == NULL) return nil;
  const int bufferWidth = (int)CVPixelBufferGetWidth(source);
  const int bufferHeight = (int)CVPixelBufferGetHeight(source);
  if (bufferWidth <= 0 || bufferHeight <= 0 ||
      buffer.cropWidth <= 0 || buffer.cropHeight <= 0 ||
      buffer.cropX < 0 || buffer.cropY < 0 ||
      buffer.cropX + buffer.cropWidth > bufferWidth ||
      buffer.cropY + buffer.cropHeight > bufferHeight) {
    return nil;
  }
  int outputWidth = 0;
  int outputHeight = 0;
  VnvarOutputSize(buffer.width, buffer.height, &outputWidth, &outputHeight);
  CIImage *image = [CIImage imageWithCVPixelBuffer:source];
  if (image == nil) return nil;
  const BOOL cropped = buffer.cropX != 0 || buffer.cropY != 0 ||
      buffer.cropWidth != bufferWidth || buffer.cropHeight != bufferHeight;
  if (!cropped && rotation == RTCVideoRotation_0 &&
      bufferWidth == outputWidth && bufferHeight == outputHeight) {
    return image;
  }
  if (cropped) {
    const CGRect cropRect = CGRectMake(
        buffer.cropX,
        bufferHeight - buffer.cropY - buffer.cropHeight,
        buffer.cropWidth,
        buffer.cropHeight);
    image = [image imageByCroppingToRect:cropRect];
  }
  if (rotation != RTCVideoRotation_0) {
    image = [image imageByApplyingCGOrientation:VnvarOrientation(rotation)];
  }
  return [VnvarFittedImage(image, outputWidth, outputHeight)
      imageByCroppingToRect:CGRectMake(0, 0, outputWidth, outputHeight)];
}

+ (CIImage * _Nullable)canvasImageForFrame:(RTCVideoFrame *)frame {
  @autoreleasepool {
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
      CIImage *native = VnvarCanvasImageFromNativeBuffer(
          (RTCCVPixelBuffer *)frame.buffer, frame.rotation);
      if (native != nil) return native;
    }
    // Đường I420 (hiếm): dùng lại bộ chuyển đổi đầy đủ rồi bọc CIImage. CIImage
    // giữ (retain) CVPixelBuffer nên có thể nhả tham chiếu của mình ngay.
    CVPixelBufferRef converted = [self copyPixelBufferForFrame:frame];
    if (converted == NULL) return nil;
    CIImage *image = [CIImage imageWithCVPixelBuffer:converted];
    CVPixelBufferRelease(converted);
    return image;
  }
}

+ (void)releaseConversionResources {
  @synchronized ([VnvarWebRtcTrackBridge class]) {
    if (gVnvarOutputPool != NULL) {
      CVPixelBufferPoolRelease(gVnvarOutputPool);
      gVnvarOutputPool = NULL;
    }
    gVnvarOutputPoolWidth = 0;
    gVnvarOutputPoolHeight = 0;
  }
}

+ (CVPixelBufferRef _Nullable)copyPixelBufferForFrame:(RTCVideoFrame *)frame {
  @autoreleasepool {
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
      CVPixelBufferRef native = VnvarCopyFromNativeBuffer(
          (RTCCVPixelBuffer *)frame.buffer, frame.rotation);
      if (native != NULL) {
        return native;
      }
    }

    // Đường dự phòng cho buffer I420 (hoặc khi đường nhanh thất bại).
    id<RTCI420Buffer> source = [frame.buffer toI420];
    if (source == nil) {
      return nil;
    }

    int outputWidth = 0;
    int outputHeight = 0;
    VnvarOutputSize(source.width, source.height, &outputWidth, &outputHeight);
    int rotatedWidth = source.width;
    int rotatedHeight = source.height;
    if (frame.rotation == RTCVideoRotation_90 ||
        frame.rotation == RTCVideoRotation_270) {
      rotatedWidth = source.height;
      rotatedHeight = source.width;
    }
    // Không xoay thì dùng thẳng buffer nguồn, bỏ một lượt sao chép toàn khung.
    id<RTCI420Buffer> rotated = source;
    if (frame.rotation != RTCVideoRotation_0) {
      RTCI420Buffer *rotatedBuffer =
          [[RTCI420Buffer alloc] initWithWidth:rotatedWidth height:rotatedHeight];
      [RTCYUVHelper I420Rotate:source.dataY
                    srcStrideY:source.strideY
                          srcU:source.dataU
                    srcStrideU:source.strideU
                          srcV:source.dataV
                    srcStrideV:source.strideV
                          dstY:(uint8_t *)rotatedBuffer.dataY
                    dstStrideY:rotatedBuffer.strideY
                          dstU:(uint8_t *)rotatedBuffer.dataU
                    dstStrideU:rotatedBuffer.strideU
                          dstV:(uint8_t *)rotatedBuffer.dataV
                    dstStrideV:rotatedBuffer.strideV
                         width:source.width
                        height:source.height
                          mode:frame.rotation];
      rotated = rotatedBuffer;
    }

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

    CVPixelBufferRef stableBuffer = VnvarCreateOutputBuffer(outputWidth, outputHeight);
    if (stableBuffer == NULL) {
      CVPixelBufferRelease(pixelBuffer);
      return nil;
    }
    CIImage *image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    VnvarRenderFitted(image, stableBuffer, outputWidth, outputHeight);
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

+ (float)setExposureBiasForTrackId:(NSString *)trackId bias:(float)bias {
  AVCaptureDevice *device = [self activeVideoDeviceForTrackId:trackId];
  if (device == nil) {
    NSLog(@"[CAMERA_EV] No active AVCaptureDevice found for trackId %@", trackId);
    return NAN;
  }
  NSError *error = nil;
  if (![device lockForConfiguration:&error]) {
    NSLog(@"[CAMERA_EV] lockForConfiguration failed: %@", error);
    return NAN;
  }
  float clamped = MAX(device.minExposureTargetBias, MIN(device.maxExposureTargetBias, bias));
  @try {
    [device setExposureTargetBias:clamped completionHandler:nil];
  } @catch (NSException *exception) {
    NSLog(@"[CAMERA_EV] Exception while setting exposure bias: %@", exception);
    [device unlockForConfiguration];
    return NAN;
  }
  [device unlockForConfiguration];
  return clamped;
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
