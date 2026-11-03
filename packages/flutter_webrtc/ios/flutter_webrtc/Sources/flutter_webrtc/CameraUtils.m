#import "CameraUtils.h"

@implementation FlutterWebRTCPlugin (CameraUtils)

-(AVCaptureDevice*) currentDevice {
  if (!self.videoCapturer) {
    return nil;
  }
  if (self.videoCapturer.captureSession.inputs.count == 0) {
    return nil;
  }
  AVCaptureDeviceInput* deviceInput = [self.videoCapturer.captureSession.inputs objectAtIndex:0];
  return deviceInput.device;
}

- (void)mediaStreamTrackHasTorch:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
#if TARGET_OS_IPHONE
  AVCaptureDevice* device = [self currentDevice];

  if (!device) {
    NSLog(@"Video capturer is null. Can't check torch");
    result(@NO);
    return;
  }
  result(@([device isTorchModeSupported:AVCaptureTorchModeOn]));
#else
  NSLog(@"Not supported on macOS. Can't check torch");
  result(@NO);
#endif
}

- (void)mediaStreamTrackSetTorch:(RTCMediaStreamTrack*)track
                           torch:(BOOL)torch
                          result:(FlutterResult)result {
  AVCaptureDevice* device = [self currentDevice];
  if (!device) {
    NSLog(@"Video capturer is null. Can't set torch");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetTorchFailed" message:@"device is nil" details:nil]);
    return;
  }
  
  if (![device isTorchModeSupported:AVCaptureTorchModeOn]) {
    NSLog(@"Current capture device does not support torch. Can't set torch");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetTorchFailed" message:@"device does not support torch" details:nil]);
    return;
  }

  NSError* error;
  if ([device lockForConfiguration:&error] == NO) {
    NSLog(@"Failed to aquire configuration lock. %@", error.localizedDescription);
    result([FlutterError errorWithCode:@"mediaStreamTrackSetTorchFailed" message:error.localizedDescription details:nil]);
    return;
  }

  device.torchMode = torch ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
  [device unlockForConfiguration];

  result(nil);
}

- (void)mediaStreamTrackSetZoom:(RTCMediaStreamTrack*)track
                           zoomLevel:(double)zoomLevel
                          result:(FlutterResult)result {
#if TARGET_OS_IPHONE
  AVCaptureDevice* device = [self currentDevice];
  if (!device) {
    NSLog(@"Video capturer is null. Can't set zoom");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetZoomFailed" message:@"device is nil" details:nil]);
    return;
  }

  NSError* error;
  if ([device lockForConfiguration:&error] == NO) {
    NSLog(@"Failed to acquire configuration lock. %@", error.localizedDescription);
    result([FlutterError errorWithCode:@"mediaStreamTrackSetZoomFailed" message:error.localizedDescription details:nil]);
    return;
  }
  
  CGFloat desiredZoomFactor = (CGFloat)zoomLevel;
  device.videoZoomFactor = MAX(1.0, MIN(desiredZoomFactor, device.activeFormat.videoMaxZoomFactor));
  [device unlockForConfiguration];

  result(nil);
#else
  NSLog(@"Not supported on macOS. Can't set zoom");
  result([FlutterError errorWithCode:@"mediaStreamTrackSetZoomFailed" message:@"Not supported on macOS" details:nil]);
#endif
}

- (void)applyFocusMode:(NSString*)focusMode onDevice:(AVCaptureDevice *)captureDevice {
#if TARGET_OS_IPHONE
  [captureDevice lockForConfiguration:nil];
  if([@"locked" isEqualToString:focusMode]) {
      if ([captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        [captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
      }
    } else if([@"auto" isEqualToString:focusMode]) {
      if ([captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
        [captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
      } else if ([captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
        [captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
      }
  }
  [captureDevice unlockForConfiguration];
#endif
}

- (void)mediaStreamTrackSetFocusMode:(nonnull RTCMediaStreamTrack*)track
                           focusMode:(nonnull NSString*)focusMode
                          result:(nonnull FlutterResult)result {
#if TARGET_OS_IPHONE
  AVCaptureDevice *device = [self currentDevice];
  if (!device) {
    NSLog(@"Video capturer is null. Can't set focusMode");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetFocusModeFailed" message:@"device is nil" details:nil]);
    return;
  }
  self.focusMode = focusMode;
  [self applyFocusMode:focusMode onDevice:device];
  result(nil);
#else
  NSLog(@"Not supported on macOS. Can't focusMode");
  result([FlutterError errorWithCode:@"mediaStreamTrackSetFocusModeFailed" message:@"Not supported on macOS" details:nil]);
#endif
}

- (void)mediaStreamTrackSetFocusPoint:(nonnull RTCMediaStreamTrack*)track
                           focusPoint:(nonnull NSDictionary*)focusPoint
                          result:(nonnull FlutterResult)result {
#if TARGET_OS_IPHONE
  AVCaptureDevice *device = [self currentDevice];
  if (!device) {
    NSLog(@"Video capturer is null. Can't set focusPoint");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetFocusPointFailed" message:@"device is nil" details:nil]);
    return;
  }
  BOOL reset = ((NSNumber *)focusPoint[@"reset"]).boolValue;
  double x = 0.5;
  double y = 0.5;
  if (!reset) {
    x = ((NSNumber *)focusPoint[@"x"]).doubleValue;
    y = ((NSNumber *)focusPoint[@"y"]).doubleValue;
  }
  if (!device.isFocusPointOfInterestSupported) {
    NSLog(@"Focus point of interest is not supported. Can't set focusPoint");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetFocusPointFailed" message:@"Focus point of interest is not supported" details:nil]);
    return;
  }

  if (!device.isFocusPointOfInterestSupported) {
    NSLog(@"Focus point of interest is not supported. Can't set focusPoint");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetFocusPointFailed" message:@"Focus point of interest is not supported" details:nil]);
    return;
  }
  UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
  [device lockForConfiguration:nil];

  [device setFocusPointOfInterest:[self getCGPointForCoordsWithOrientation:orientation
                                                                                 x:x
                                                                                 y:y]];
  [device unlockForConfiguration];

  [self applyFocusMode:self.focusMode onDevice:device];
  result(nil);
#else
  NSLog(@"Not supported on macOS. Can't focusPoint");
  result([FlutterError errorWithCode:@"mediaStreamTrackSetFocusPointFailed" message:@"Not supported on macOS" details:nil]);
#endif
}

- (void) applyExposureMode:(NSString*)exposureMode onDevice:(AVCaptureDevice *)captureDevice {
#if TARGET_OS_IPHONE
  [captureDevice lockForConfiguration:nil];
  if([@"locked" isEqualToString:exposureMode]) {
      if ([captureDevice isExposureModeSupported:AVCaptureExposureModeAutoExpose]) {
        [captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
      }
    } else if([@"auto" isEqualToString:exposureMode]) {
      if ([captureDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
        [captureDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
      } else if ([captureDevice isExposureModeSupported:AVCaptureExposureModeAutoExpose]) {
        [captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
      }
  }
  [captureDevice unlockForConfiguration];
#endif
}

- (void)mediaStreamTrackSetExposureMode:(nonnull RTCMediaStreamTrack*)track
                           exposureMode:(nonnull NSString*)exposureMode
                          result:(nonnull FlutterResult)result{
#if TARGET_OS_IPHONE
  AVCaptureDevice *device = [self currentDevice];
  if (!device) {
    NSLog(@"Video capturer is null. Can't set exposureMode");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetExposureModeFailed" message:@"device is nil" details:nil]);
    return;
  }
  self.exposureMode = exposureMode;
  [self applyExposureMode:exposureMode onDevice:device];
  result(nil);
#else
  NSLog(@"Not supported on macOS. Can't exposureMode");
  result([FlutterError errorWithCode:@"mediaStreamTrackSetExposureModeFailed" message:@"Not supported on macOS" details:nil]);
#endif
}

#if TARGET_OS_IPHONE
- (CGPoint)getCGPointForCoordsWithOrientation:(UIDeviceOrientation)orientation
                                            x:(double)x
                                            y:(double)y {
  double oldX = x, oldY = y;
  switch (orientation) {
    case UIDeviceOrientationPortrait:  // 90 ccw
      y = 1 - oldX;
      x = oldY;
      break;
    case UIDeviceOrientationPortraitUpsideDown:  // 90 cw
      x = 1 - oldY;
      y = oldX;
      break;
    case UIDeviceOrientationLandscapeRight:  // 180
      x = 1 - x;
      y = 1 - y;
      break;
    case UIDeviceOrientationLandscapeLeft:
    default:
      // No rotation required
      break;
  }
  return CGPointMake(x, y);
}
#endif

- (void)mediaStreamTrackSetExposurePoint:(nonnull RTCMediaStreamTrack*)track
                           exposurePoint:(nonnull NSDictionary*)exposurePoint
                            result:(nonnull FlutterResult)result {
#if TARGET_OS_IPHONE
  AVCaptureDevice *device = [self currentDevice];

  if (!device) {
    NSLog(@"Video capturer is null. Can't set exposurePoint");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetExposurePointFailed" message:@"device is nil" details:nil]);
    return;
  }

  BOOL reset = ((NSNumber *)exposurePoint[@"reset"]).boolValue;
  double x = 0.5;
  double y = 0.5;
  if (!reset) {
    x = ((NSNumber *)exposurePoint[@"x"]).doubleValue;
    y = ((NSNumber *)exposurePoint[@"y"]).doubleValue;
  }
  if (!device.isExposurePointOfInterestSupported) {
    NSLog(@"Exposure point of interest is not supported. Can't set exposurePoint");
    result([FlutterError errorWithCode:@"mediaStreamTrackSetExposurePointFailed" message:@"Exposure point of interest is not supported" details:nil]);
    return;
  }
  UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
  [device lockForConfiguration:nil];
  [device setExposurePointOfInterest:[self getCGPointForCoordsWithOrientation:orientation
                                                                                    x:x
                                                                                    y:y]];
  [device unlockForConfiguration];

  [self applyExposureMode:self.exposureMode onDevice:device];
  result(nil);
#else
  NSLog(@"Not supported on macOS. Can't exposurePoint");
  result([FlutterError errorWithCode:@"mediaStreamTrackSetExposurePointFailed" message:@"Not supported on macOS" details:nil]);
#endif
}

- (void)mediaStreamTrackSwitchCamera:(RTCMediaStreamTrack*)track result:(FlutterResult)result {
  if (!self.videoCapturer) {
    NSLog(@"Video capturer is null. Can't switch camera");
    result([FlutterError errorWithCode:@"Error while switching camera"
                               message:@"Video capturer is null"
                               details:nil]);
    return;
  }
  BOOL usingFrontCamera = !self._usingFrontCamera;
  AVCaptureDevicePosition position =
      usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
  AVCaptureDevice* videoDevice = [self findDeviceForPosition:position];
  // VNVAR: cùng quy tắc với lúc mở camera: chọn định dạng theo kích thước rồi
  // FPS, chỉ dùng FPS hợp lệ của định dạng đó; không có thì báo lỗi (camera cũ
  // vẫn chạy) thay vì mở với định dạng nil / FPS 0.
  AVCaptureDeviceFormat* selectedFormat =
      videoDevice == nil ? nil
                         : [self selectFormatForDevice:videoDevice
                                           targetWidth:self._lastTargetWidth
                                          targetHeight:self._lastTargetHeight
                                             targetFps:self._lastTargetFps];
  NSInteger selectedFps = [self selectFpsForFormat:selectedFormat targetFps:self._lastTargetFps];
  if (selectedFormat == nil || selectedFps <= 0) {
    NSLog(@"[CAMERA_FPS] No usable capture format for %@ (target %ldx%ld@%ld)",
          videoDevice.localizedName, (long)self._lastTargetWidth, (long)self._lastTargetHeight,
          (long)self._lastTargetFps);
    result([FlutterError errorWithCode:@"Error while switching camera"
                               message:@"No usable capture format"
                               details:nil]);
    return;
  }
#if TARGET_OS_IPHONE
  [self.videoCapturer stopCapture];
#endif
  self._usingFrontCamera = usingFrontCamera;
  __weak FlutterWebRTCPlugin* weakSelf = self;
  [self.videoCapturer startCaptureWithDevice:videoDevice
                                      format:selectedFormat
                                         fps:selectedFps
                           completionHandler:^(NSError* error) {
                             if (error != nil) {
                               // NSError không mã hoá được qua kênh Flutter: chỉ gửi mô tả.
                               result([FlutterError errorWithCode:@"Error while switching camera"
                                                          message:error.localizedDescription
                                                          details:nil]);
                             } else {
                               // VNVAR: chỉ khoá FPS khi camera đã chạy định dạng mới.
                               [weakSelf lockFrameRate:selectedFps
                                             forDevice:videoDevice
                                        expectedFormat:selectedFormat];
                               result([NSNumber numberWithBool:usingFrontCamera]);
                             }
                           }];
}


- (AVCaptureDevice*)findDeviceForPosition:(AVCaptureDevicePosition)position {
  if (position == AVCaptureDevicePositionUnspecified) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  }
  NSArray<AVCaptureDevice*>* captureDevices = [RTCCameraVideoCapturer captureDevices];
  for (AVCaptureDevice* device in captureDevices) {
    if (device.position == position) {
      return device;
    }
  }
  return captureDevices[0];
}

- (AVCaptureDeviceFormat*)selectFormatForDevice:(AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight {
  return [self selectFormatForDevice:device
                         targetWidth:targetWidth
                        targetHeight:targetHeight
                           targetFps:self._lastTargetFps > 0 ? self._lastTargetFps : 30];
}

static Float64 VnvarFormatMaxFps(AVCaptureDeviceFormat* format) {
  Float64 maxFps = 0;
  for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges) {
    maxFps = fmax(maxFps, range.maxFrameRate);
  }
  return maxFps;
}

static BOOL VnvarIs8Bit420(FourCharCode pixelFormat) {
  return pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

- (AVCaptureDeviceFormat*)selectFormatForDevice:(AVCaptureDevice*)device
                                    targetWidth:(NSInteger)targetWidth
                                   targetHeight:(NSInteger)targetHeight
                                      targetFps:(NSInteger)targetFps {
  NSArray<AVCaptureDeviceFormat*>* formats =
      [RTCCameraVideoCapturer supportedFormatsForDevice:device];
#if TARGET_OS_IPHONE
  BOOL multiCamSession = NO;
  if (@available(iOS 13.0, *)) {
    multiCamSession =
        [self.videoCapturer.captureSession isKindOfClass:[AVCaptureMultiCamSession class]];
  }
#endif
  FourCharCode preferredPixel = [self.videoCapturer preferredOutputPixelFormat];
  Float64 wantedFps = targetFps > 0 ? (Float64)targetFps : 30;
  AVCaptureDeviceFormat* best = nil;
  long bestDiff = LONG_MAX;
  BOOL best420 = NO, bestMeets = NO, bestPreferred = NO;
  Float64 bestFps = 0;
  for (AVCaptureDeviceFormat* format in formats) {
#if TARGET_OS_IPHONE
    if (@available(iOS 13.0, *)) {
      if (multiCamSession && !format.isMultiCamSupported) continue;
    }
#endif
    CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
    long diff = labs(targetWidth - dimension.width) + labs(targetHeight - dimension.height);
    BOOL is420 = VnvarIs8Bit420(pixelFormat);
    Float64 fps = VnvarFormatMaxFps(format);
    BOOL meets = fps + 0.5 >= wantedFps;
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
    } else if (fabs(fps - bestFps) > 0.5) {
      // Đều đạt: lấy FPS tối đa thấp nhất (tránh định dạng quay chậm 120/240);
      // đều không đạt: lấy FPS cao nhất.
      better = meets ? fps < bestFps : fps > bestFps;
    } else {
      better = preferred && !bestPreferred;
    }
    if (better) {
      best = format;
      bestDiff = diff;
      best420 = is420;
      bestMeets = meets;
      bestFps = fps;
      bestPreferred = preferred;
    }
  }
  return best;
}

// ---- VNVAR: FPS hợp lệ & khoá FPS an toàn ----
// iOS ném NSInvalidArgumentException khi frame duration nằm ngoài khoảng của
// activeFormat (vd. 1/60 s khi camera còn ở định dạng tối đa 30 FPS). Trên iOS
// 26 lỗi có thể phát sinh trên luồng nội bộ của AVFoundation nên @try không
// chặn được: phải kiểm tra trước, không dựa vào bắt lỗi.

/// Khoảng FPS của [format] chứa khung 1/[fps] giây, nil nếu không có.
static AVFrameRateRange* VnvarRangeForFps(AVCaptureDeviceFormat* format, NSInteger fps) {
  if (format == nil || fps <= 0 || fps > INT32_MAX) return nil;
  CMTime duration = CMTimeMake(1, (int32_t)fps);
  for (AVFrameRateRange* range in format.videoSupportedFrameRateRanges) {
    if (CMTimeCompare(duration, range.minFrameDuration) >= 0 &&
        CMTimeCompare(duration, range.maxFrameDuration) <= 0) {
      return range;
    }
  }
  return nil;
}

static BOOL VnvarSameFormat(AVCaptureDeviceFormat* a, AVCaptureDeviceFormat* b) {
  if (a == nil || b == nil) return NO;
  if (a == b || [a isEqual:b]) return YES;
  return CMFormatDescriptionEqual(a.formatDescription, b.formatDescription) &&
         fabs(VnvarFormatMaxFps(a) - VnvarFormatMaxFps(b)) < 0.5;
}

/// iOS 18+/macOS 15+: khi autoVideoFrameRateEnabled = YES, iOS ném lỗi nếu đặt
/// frame duration. Tắt đi (gọi khi đã lockForConfiguration) để giữ FPS cố định.
/// Dùng KVC để vẫn biên dịch được với SDK cũ.
static void VnvarDisableAutoVideoFrameRate(AVCaptureDevice* device) {
  if (![device respondsToSelector:NSSelectorFromString(@"isAutoVideoFrameRateEnabled")]) return;
  if ([[device valueForKey:@"autoVideoFrameRateEnabled"] boolValue]) {
    [device setValue:@NO forKey:@"autoVideoFrameRateEnabled"];
  }
}

- (BOOL)isFps:(NSInteger)fps supportedByFormat:(AVCaptureDeviceFormat*)format {
  return VnvarRangeForFps(format, fps) != nil;
}

- (NSInteger)selectFpsForFormat:(AVCaptureDeviceFormat*)format targetFps:(NSInteger)targetFps {
  if (format == nil) return 0;
  NSInteger wanted = targetFps > 0 ? targetFps : 30;
  if (VnvarRangeForFps(format, wanted) != nil) return wanted;
  // Không đạt đúng FPS yêu cầu: lấy FPS nguyên hợp lệ gần nhất (hoà thì lấy
  // FPS thấp hơn).
  NSInteger upper = (NSInteger)ceil(VnvarFormatMaxFps(format));
  NSInteger best = 0;
  for (NSInteger fps = 1; fps <= upper; fps++) {
    if (VnvarRangeForFps(format, fps) == nil) continue;
    if (best == 0 || labs(fps - wanted) < labs(best - wanted)) best = fps;
  }
  return best;
}

- (BOOL)lockFrameRate:(NSInteger)fps
            forDevice:(AVCaptureDevice*)device
       expectedFormat:(AVCaptureDeviceFormat*)expectedFormat {
  if (device == nil || fps <= 0 || fps > INT32_MAX) {
    NSLog(@"[CAMERA_FPS] Skip lock: device %@, fps %ld", device.localizedName, (long)fps);
    return NO;
  }
  NSError* error = nil;
  if (![device lockForConfiguration:&error]) {
    NSLog(@"[CAMERA_FPS] lockForConfiguration failed: %@", error.localizedDescription);
    return NO;
  }
  BOOL ok = NO;
  AVCaptureDeviceFormat* activeFormat = device.activeFormat;
  if (expectedFormat != nil && !VnvarSameFormat(activeFormat, expectedFormat)) {
    NSLog(@"[CAMERA_FPS] Skip lock %ld fps: camera is not running the selected format "
          @"(active %@, selected %@)",
          (long)fps, activeFormat, expectedFormat);
  } else if (VnvarRangeForFps(activeFormat, fps) == nil) {
    NSLog(@"[CAMERA_FPS] Skip lock %ld fps: outside ranges %@ of active format",
          (long)fps, activeFormat.videoSupportedFrameRateRanges);
  } else {
    @try {
      VnvarDisableAutoVideoFrameRate(device);
      CMTime target = CMTimeMake(1, (int32_t)fps);
      CMTime currentMin = device.activeVideoMinFrameDuration;
      CMTime currentMax = device.activeVideoMaxFrameDuration;
      if (CMTimeCompare(currentMin, target) == 0 && CMTimeCompare(currentMax, target) == 0) {
        // Đã khoá đúng FPS: không đặt lại (tránh làm iOS bỏ cấu hình phơi sáng).
      } else if (CMTimeCompare(target, currentMin) < 0) {
        // Tăng FPS (khung ngắn hơn): giới hạn dưới trước, rồi giới hạn trên.
        device.activeVideoMinFrameDuration = target;
        device.activeVideoMaxFrameDuration = target;
      } else {
        // Giảm FPS (khung dài hơn): giới hạn trên trước, rồi giới hạn dưới.
        device.activeVideoMaxFrameDuration = target;
        device.activeVideoMinFrameDuration = target;
      }
      ok = YES;
      NSLog(@"[CAMERA_FPS] Locked %@ at %ld fps", device.localizedName, (long)fps);
    } @catch (NSException* exception) {
      NSLog(@"[CAMERA_FPS] Failed to lock %ld fps: %@", (long)fps, exception);
    }
  }
  [device unlockForConfiguration];
  return ok;
}

@end
