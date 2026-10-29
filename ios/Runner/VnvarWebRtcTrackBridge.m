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

// ---- Chọn định dạng camera (cùng quy tắc với flutter_webrtc đã vá) ----
static Float64 VnvarFormatMaxFps(AVCaptureDeviceFormat *format) {
  Float64 maxFps = 0;
  for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
    maxFps = fmax(maxFps, range.maxFrameRate);
  }
  return maxFps;
}

static BOOL VnvarIs8Bit420(FourCharCode pixelFormat) {
  return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

static BOOL VnvarIsMultiCamSession(AVCaptureSession *session) {
  if (@available(iOS 13.0, *)) {
    return session != nil && [session isKindOfClass:[AVCaptureMultiCamSession class]];
  }
  return NO;
}

/// Phiên chụp mà capturer (sẽ) dùng có phải multi-cam không: có capturer thì
/// xem phiên thật; chưa có thì đoán như flutter_webrtc đã vá (dùng
/// AVCaptureSession thường khi WebRTC-SDK có initWithDelegate:captureSession:).
static BOOL VnvarExpectMultiCamSession(void) {
  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (plugin.videoCapturer.captureSession != nil) {
    return VnvarIsMultiCamSession(plugin.videoCapturer.captureSession);
  }
  if ([RTCCameraVideoCapturer instancesRespondToSelector:
          NSSelectorFromString(@"initWithDelegate:captureSession:")]) {
    return NO;
  }
  if (@available(iOS 13.0, *)) {
    return AVCaptureMultiCamSession.isMultiCamSupported;
  }
  return NO;
}

static BOOL VnvarFormatUsable(AVCaptureDeviceFormat *format, BOOL multiCam) {
  if (@available(iOS 13.0, *)) {
    if (multiCam && !format.isMultiCamSupported) return NO;
  }
  return YES;
}

/// Gần kích thước nhất → 8-bit 4:2:0 → đạt [fps] (lấy FPS tối đa thấp nhất vẫn
/// đạt, tránh định dạng quay chậm) → pixel format capturer ưa dùng.
static AVCaptureDeviceFormat *VnvarBestFormat(AVCaptureDevice *device, NSInteger width,
                                              NSInteger height, NSInteger fps,
                                              BOOL multiCam, FourCharCode preferredPixel) {
  Float64 wantedFps = fps > 0 ? (Float64)fps : 30;
  AVCaptureDeviceFormat *best = nil;
  long bestDiff = LONG_MAX;
  BOOL best420 = NO, bestMeets = NO, bestPreferred = NO;
  Float64 bestFps = 0;
  for (AVCaptureDeviceFormat *format in [RTCCameraVideoCapturer supportedFormatsForDevice:device]) {
    if (!VnvarFormatUsable(format, multiCam)) continue;
    CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
    long diff = labs(width - dimension.width) + labs(height - dimension.height);
    BOOL is420 = VnvarIs8Bit420(pixelFormat);
    Float64 formatFps = VnvarFormatMaxFps(format);
    BOOL meets = formatFps + 0.5 >= wantedFps;
    BOOL preferred = pixelFormat == preferredPixel;
    BOOL better;
    if (best == nil || diff < bestDiff) {
      better = YES;
    } else if (diff > bestDiff) {
      better = NO;
    } else if (is420 != best420) {
      better = is420;
    } else if (meets != bestMeets) {
      better = meets;
    } else if (fabs(formatFps - bestFps) > 0.5) {
      better = meets ? formatFps < bestFps : formatFps > bestFps;
    } else {
      better = preferred && !bestPreferred;
    }
    if (better) {
      best = format;
      bestDiff = diff;
      best420 = is420;
      bestMeets = meets;
      bestFps = formatFps;
      bestPreferred = preferred;
    }
  }
  return best;
}

+ (NSDictionary<NSString *, NSNumber *> *)maxFpsBySizeForDevice:(AVCaptureDevice *)device {
  BOOL multiCam = VnvarExpectMultiCamSession();
  NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
  for (AVCaptureDeviceFormat *format in [RTCCameraVideoCapturer supportedFormatsForDevice:device]) {
    if (!VnvarFormatUsable(format, multiCam)) continue;
    if (!VnvarIs8Bit420(CMFormatDescriptionGetMediaSubType(format.formatDescription))) continue;
    CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    NSString *key = [NSString stringWithFormat:@"%dx%d", dimension.width, dimension.height];
    NSInteger fps = MIN((NSInteger)floor(VnvarFormatMaxFps(format)), 60);
    if (fps > [result[key] integerValue]) result[key] = @(fps);
  }
  return result;
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

  // Chọn theo kích thước VÀ FPS, chỉ trong các định dạng phiên chụp hiện tại
  // mở được (trước đây chỉ theo kích thước: ống 0.5x lấy nhầm định dạng tối đa
  // 30 FPS, và có thể lấy định dạng không hỗ trợ multi-cam → iOS ném lỗi).
  BOOL multiCam = VnvarIsMultiCamSession(capturer.captureSession);
  AVCaptureDeviceFormat *selectedFormat =
      VnvarBestFormat(targetDevice, targetWidth, targetHeight, targetFps, multiCam,
                      [capturer preferredOutputPixelFormat]);
  if (selectedFormat == nil) {
    if (completion) completion(NO, @"No usable capture format");
    return;
  }
  Float64 maxSupportedFps = VnvarFormatMaxFps(selectedFormat);
  NSInteger fps = MIN(targetFps, (NSInteger)maxSupportedFps);
  if (fps <= 0) fps = 30;
  NSLog(@"[CAMERA] Switch format %@ fps %ld (target %ldx%ld@%ld, multiCam %d)",
        selectedFormat, (long)fps, (long)targetWidth, (long)targetHeight, (long)targetFps, multiCam);

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

// ---- Chế độ thể thao (main queue) ----
/// Màn trập mục tiêu (giây); 0 = tắt.
static double gVnvarSportsTargetSeconds = 0;
/// Giới hạn đang áp (có thể đã nới khi thiếu sáng).
static double gVnvarSportsCurrentSeconds = 0;
static NSString *gVnvarSportsTrackId = nil;
static dispatch_source_t gVnvarSportsTimer = nil;

/// Thời lượng một khung hình của định dạng đang chạy (giới hạn nới tối đa).
static double VnvarFrameSeconds(AVCaptureDevice *device) {
  CMTime frame = device.activeVideoMinFrameDuration;
  double seconds = CMTIME_IS_VALID(frame) ? CMTimeGetSeconds(frame) : 0;
  return seconds > 0 ? seconds : 1.0 / 30.0;
}

/// Đặt activeMaxExposureDuration (đã kẹp vào [min, max] của activeFormat, nếu
/// không iOS ném NSRangeException). Gọi khi device đã lockForConfiguration.
static double VnvarApplyMaxExposure(AVCaptureDevice *device, double seconds) {
  CMTime target = CMTimeMakeWithSeconds(seconds, 1000000);
  CMTime minimum = device.activeFormat.minExposureDuration;
  CMTime maximum = device.activeFormat.maxExposureDuration;
  if (CMTIME_IS_VALID(minimum) && CMTimeCompare(target, minimum) < 0) target = minimum;
  if (CMTIME_IS_VALID(maximum) && CMTimeCompare(target, maximum) > 0) target = maximum;
  device.activeMaxExposureDuration = target;
  return CMTimeGetSeconds(target);
}

+ (void)sportsTick {
  if (gVnvarSportsTargetSeconds <= 0 || gVnvarSportsTrackId == nil) return;
  AVCaptureDevice *device = [self activeVideoDeviceForTrackId:gVnvarSportsTrackId];
  if (device == nil) return;
  float maxIso = device.activeFormat.maxISO;
  if (maxIso <= 0) return;
  float offset = device.exposureTargetOffset;  // EV; âm = tối hơn mức AE muốn
  float iso = device.ISO;
  double exposure = CMTimeGetSeconds(device.exposureDuration);
  double current = gVnvarSportsCurrentSeconds > 0 ? gVnvarSportsCurrentSeconds
                                                  : gVnvarSportsTargetSeconds;
  double next = current;
  if (offset < -0.5f && iso >= maxIso * 0.95f) {
    // ISO kịch trần mà vẫn thiếu sáng: nới màn trập (tối đa một khung hình).
    next = MIN(current * 1.5, MAX(gVnvarSportsTargetSeconds, VnvarFrameSeconds(device)));
  } else if (current > gVnvarSportsTargetSeconds * 1.01 && offset > -0.2f && exposure > 0) {
    // Đủ sáng trở lại: siết dần về mục tiêu nếu ISO cần thiết vẫn còn dư địa.
    double tighter = MAX(gVnvarSportsTargetSeconds, current / 1.5);
    double requiredIso = iso * exposure / tighter;
    if (requiredIso < maxIso * 0.7) next = tighter;
  }
  if (fabs(next - current) < current * 0.01) return;
  NSError *error = nil;
  if (![device lockForConfiguration:&error]) return;
  @try {
    gVnvarSportsCurrentSeconds = VnvarApplyMaxExposure(device, next);
    NSLog(@"[CAMERA_SPORTS] Max exposure %.5f s (ISO %.0f/%.0f, offset %.2f EV)",
          gVnvarSportsCurrentSeconds, iso, maxIso, offset);
  } @catch (NSException *exception) {
    NSLog(@"[CAMERA_SPORTS] Exception while adapting max exposure: %@", exception);
  }
  [device unlockForConfiguration];
}

+ (void)updateSportsTimer {
  if (gVnvarSportsTargetSeconds > 0) {
    if (gVnvarSportsTimer != nil) return;
    gVnvarSportsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               dispatch_get_main_queue());
    dispatch_source_set_timer(gVnvarSportsTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                              (uint64_t)(1 * NSEC_PER_SEC), (uint64_t)(200 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gVnvarSportsTimer, ^{
      [VnvarWebRtcTrackBridge sportsTick];
    });
    dispatch_resume(gVnvarSportsTimer);
  } else if (gVnvarSportsTimer != nil) {
    dispatch_source_cancel(gVnvarSportsTimer);
    gVnvarSportsTimer = nil;
  }
}

+ (BOOL)setSportsModeForTrackId:(NSString *)trackId
             shutterDenominator:(NSInteger)shutterDenominator {
  if (![NSThread isMainThread]) {
    __block BOOL result = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
      result = [self setSportsModeForTrackId:trackId shutterDenominator:shutterDenominator];
    });
    return result;
  }
  double target = shutterDenominator > 0 ? 1.0 / (double)shutterDenominator : 0;
  if (fabs(target - gVnvarSportsTargetSeconds) > 1e-9) {
    // Đổi mức: bắt đầu lại từ màn trập mục tiêu.
    gVnvarSportsCurrentSeconds = target;
  }
  gVnvarSportsTargetSeconds = target;
  gVnvarSportsTrackId = target > 0 ? [trackId copy] : nil;
  [self updateSportsTimer];

  AVCaptureDevice *device = [self activeVideoDeviceForTrackId:trackId];
  if (device == nil) {
    NSLog(@"[CAMERA_SPORTS] No active AVCaptureDevice found for trackId %@", trackId);
    return NO;
  }
  NSError *error = nil;
  if (![device lockForConfiguration:&error]) {
    NSLog(@"[CAMERA_SPORTS] lockForConfiguration failed: %@", error);
    return NO;
  }
  BOOL ok = YES;
  @try {
    if (target > 0) {
      // Áp lại mức đang dùng (giữ phần đã nới khi thiếu sáng) cho camera vừa mở.
      double seconds = gVnvarSportsCurrentSeconds > 0 ? gVnvarSportsCurrentSeconds : target;
      gVnvarSportsCurrentSeconds = VnvarApplyMaxExposure(device, seconds);
      NSLog(@"[CAMERA_SPORTS] Max exposure limited to %.5f s", gVnvarSportsCurrentSeconds);
    } else {
      // kCMTimeInvalid: trả về giới hạn mặc định của iOS.
      device.activeMaxExposureDuration = kCMTimeInvalid;
    }
  } @catch (NSException *exception) {
    NSLog(@"[CAMERA_SPORTS] Exception while setting max exposure: %@", exception);
    ok = NO;
  }
  [device unlockForConfiguration];
  return ok;
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
