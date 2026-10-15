import CoreMedia
import Foundation
import VideoToolbox

final class VnvarH264Encoder {
  typealias FormatHandler = (_ sps: Data, _ pps: Data) -> Void
  typealias AccessUnitHandler = (
    _ nals: [Data],
    _ rtpTimestamp: UInt32,
    _ isKeyFrame: Bool
  ) -> Void

  var onFormat: FormatHandler?
  var onAccessUnit: AccessUnitHandler?
  var onError: ((String) -> Void)?

  private let queue = DispatchQueue(label: "vnvar.rtsp.h264.encoder")
  private let queueKey = DispatchSpecificKey<Void>()
  // Bảo vệ encodeQueued, pendingCompletion, pendingFrameToken, nextFrameToken.
  private let admissionLock = NSLock()
  private let maximumBitrate: Int
  private var currentBitrate: Int
  private let fps: Int
  private var session: VTCompressionSession?
  private var dimensions: (width: Int, height: Int)?
  private var forceNextKeyFrame = true
  private var stopped = false
  private var lastParameterSets: (sps: Data, pps: Data)?
  private var encodeQueued = false
  private var pendingCompletion: (() -> Void)?
  // Mã của khung đang nằm trong VideoToolbox (0 = chưa có). Truyền qua
  // sourceFrameRefcon để nhận ra callback muộn của phiên đã bị huỷ.
  private var pendingFrameToken: UInt = 0
  private var nextFrameToken: UInt = 0

  /// Khung chờ VideoToolbox lâu hơn chừng này coi như mất callback: nhả khung
  /// và tạo lại phiên, thay vì để RTSP đứng hình vĩnh viễn.
  private static let stallTimeout: TimeInterval = 1.0

  init(bitrate: Int, fps: Int) {
    maximumBitrate = max(250_000, bitrate)
    currentBitrate = max(250_000, bitrate)
    self.fps = max(1, min(fps, 60))
    queue.setSpecific(key: queueKey, value: ())
  }

  func encode(
    pixelBuffer: CVPixelBuffer,
    timestampNs: Int64,
    completion: @escaping () -> Void
  ) {
    admissionLock.lock()
    guard !encodeQueued else {
      admissionLock.unlock()
      completion()
      return
    }
    encodeQueued = true
    pendingCompletion = completion
    nextFrameToken &+= 1
    if nextFrameToken == 0 { nextFrameToken = 1 }
    let token = nextFrameToken
    pendingFrameToken = token
    admissionLock.unlock()
    // Publisher cũng chỉ cho một khung chạy cùng lúc, nên khi callback bị mất sẽ
    // không có khung mới nào tới để phát hiện: tự hẹn giờ kiểm tra từng khung.
    queue.asyncAfter(deadline: .now() + Self.stallTimeout) { [weak self] in
      self?.recoverIfStalled(token: token)
    }
    queue.async { [weak self] in
      guard let self = self else {
        completion()
        return
      }
      guard !self.stopped else {
        self.finishPendingFrame(token: token)
        return
      }
      do {
        try self.ensureSession(for: pixelBuffer)
        guard let session = self.session else {
          self.finishPendingFrame(token: token)
          return
        }
        let timestamp = CMTime(value: timestampNs, timescale: 1_000_000_000)
        var options: CFDictionary?
        if self.forceNextKeyFrame {
          self.forceNextKeyFrame = false
          options = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(
          session,
          imageBuffer: pixelBuffer,
          presentationTimeStamp: timestamp,
          duration: CMTime(value: 1, timescale: CMTimeScale(self.fps)),
          frameProperties: options,
          sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: token),
          infoFlagsOut: nil
        )
        guard status == noErr else {
          throw EncoderError.operation("encode", status)
        }
      } catch EncoderError.operation(_, let status) where Self.isSessionLost(status) {
        // iOS huỷ phiên phần cứng (ví dụ khi app ra nền): tạo lại ở khung sau
        // thay vì lỗi mãi với cùng một phiên hỏng.
        NSLog("[VNVAR-RTSP] VideoToolbox session lost (%d); recreating", status)
        self.resetSession()
        self.finishPendingFrame(token: token)
      } catch {
        self.finishPendingFrame(token: token)
        self.report(error)
      }
    }
  }

  func requestKeyFrame() {
    queue.async { [weak self] in self?.forceNextKeyFrame = true }
  }

  func updateBitrate(_ bitrate: Int) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let target = min(self.maximumBitrate, max(250_000, bitrate))
      guard target != self.currentBitrate else { return }
      self.currentBitrate = target
      guard let session = self.session else { return }
      // Some older hardware encoders do not accept live property changes.
      // Keep streaming with the previous native value instead of restarting.
      self.setIfSupported(
        kVTCompressionPropertyKey_AverageBitRate,
        value: target,
        on: session
      )
      self.setIfSupported(
        kVTCompressionPropertyKey_DataRateLimits,
        value: [target / 8, 1],
        on: session
      )
    }
  }

  func stop() {
    // Gọi từ chính hàng đợi encoder thì queue.sync sẽ treo cứng: chạy thẳng.
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      stopLocked()
    } else {
      queue.sync { stopLocked() }
    }
  }

  private func stopLocked() {
    stopped = true
    if let session = session {
      VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
      VTCompressionSessionInvalidate(session)
    }
    session = nil
    dimensions = nil
    lastParameterSets = nil
    finishPendingFrame()
  }

  /// Chạy trên `queue`. Huỷ phiên hiện tại để khung kế tiếp tạo phiên mới.
  private func resetSession() {
    if let session = session {
      VTCompressionSessionInvalidate(session)
    }
    session = nil
    dimensions = nil
    lastParameterSets = nil
    forceNextKeyFrame = true
  }

  /// Chạy trên `queue` sau `stallTimeout` kể từ khi khung [token] vào encoder.
  private func recoverIfStalled(token: UInt) {
    admissionLock.lock()
    let stalled = encodeQueued && pendingFrameToken == token
    admissionLock.unlock()
    guard stalled, !stopped else { return }
    NSLog(
      "[VNVAR-RTSP] VideoToolbox returned no frame within %.1fs; recreating encoder session",
      Self.stallTimeout
    )
    resetSession()
    finishPendingFrame(token: token)
  }

  private static func isSessionLost(_ status: OSStatus) -> Bool {
    Int(status) == Int(kVTInvalidSessionErr) ||
      Int(status) == Int(kVTVideoEncoderMalfunctionErr)
  }

  private func ensureSession(for pixelBuffer: CVPixelBuffer) throws {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if let dimensions = dimensions,
       dimensions.width == width,
       dimensions.height == height,
       session != nil {
      return
    }

    if let session = session {
      VTCompressionSessionInvalidate(session)
      self.session = nil
    }
    var newSession: VTCompressionSession?
    let status = VTCompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      width: Int32(width),
      height: Int32(height),
      codecType: kCMVideoCodecType_H264,
      encoderSpecification: nil,
      imageBufferAttributes: nil,
      compressedDataAllocator: nil,
      outputCallback: vnvarH264OutputCallback,
      refcon: Unmanaged.passUnretained(self).toOpaque(),
      compressionSessionOut: &newSession
    )
    guard status == noErr, let newSession = newSession else {
      throw EncoderError.operation("create", status)
    }

    do {
      try set(kVTCompressionPropertyKey_RealTime, value: true, on: newSession)
      try set(kVTCompressionPropertyKey_AllowFrameReordering, value: false, on: newSession)
      try set(
        kVTCompressionPropertyKey_ProfileLevel,
        value: kVTProfileLevel_H264_Main_AutoLevel,
        on: newSession
      )
      try set(kVTCompressionPropertyKey_AverageBitRate, value: currentBitrate, on: newSession)
      try set(kVTCompressionPropertyKey_ExpectedFrameRate, value: fps, on: newSession)
      try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps, on: newSession)
      // Keep at most one frame inside VideoToolbox. A deep encoder queue makes
      // 4K preview and recording appear frozen several seconds behind live.
      setIfSupported(
        kVTCompressionPropertyKey_MaxFrameDelayCount,
        value: 1,
        on: newSession
      )
      try set(
        kVTCompressionPropertyKey_DataRateLimits,
        value: [currentBitrate / 8, 1],
        on: newSession
      )
      let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(newSession)
      guard prepareStatus == noErr else {
        throw EncoderError.operation("prepare", prepareStatus)
      }
    } catch {
      VTCompressionSessionInvalidate(newSession)
      throw error
    }
    session = newSession
    dimensions = (width, height)
    lastParameterSets = nil
    forceNextKeyFrame = true
  }

  private func set(
    _ key: CFString,
    value: Any,
    on session: VTCompressionSession
  ) throws {
    let status = VTSessionSetProperty(
      session,
      key: key,
      value: value as CFTypeRef
    )
    guard status == noErr else {
      throw EncoderError.operation("property \(key)", status)
    }
  }

  @discardableResult
  private func setIfSupported(
    _ key: CFString,
    value: Any,
    on session: VTCompressionSession
  ) -> Bool {
    let status = VTSessionSetProperty(
      session,
      key: key,
      value: value as CFTypeRef
    )
    if status != noErr {
      NSLog(
        "[VNVAR-RTSP] VideoToolbox ignored optional property %@ (%d)",
        String(describing: key),
        status
      )
    }
    return status == noErr
  }

  fileprivate func handle(status: OSStatus, sampleBuffer: CMSampleBuffer?, token: UInt) {
    admissionLock.lock()
    let isCurrentFrame = encodeQueued && pendingFrameToken == token
    admissionLock.unlock()
    // Callback muộn của khung đã được watchdog nhả / phiên đã huỷ: bỏ qua để
    // không nhả nhầm khung mới và không gửi lại dữ liệu cũ.
    guard isCurrentFrame else { return }
    defer { finishPendingFrame(token: token) }
    if Self.isSessionLost(status) {
      NSLog("[VNVAR-RTSP] VideoToolbox session lost in callback (%d); recreating", status)
      queue.async { [weak self] in self?.resetSession() }
      return
    }
    guard status == noErr,
          let sampleBuffer = sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer) else {
      if status != noErr { report(EncoderError.operation("callback", status)) }
      return
    }
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
          let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
      report(EncoderError.invalidOutput)
      return
    }

    let parameterSets = parameterSets(from: format)
    if let parameterSets = parameterSets,
       (lastParameterSets?.sps != parameterSets.sps ||
        lastParameterSets?.pps != parameterSets.pps) {
      lastParameterSets = (parameterSets.sps, parameterSets.pps)
      onFormat?(parameterSets.sps, parameterSets.pps)
    }
    let nals = lengthPrefixedNals(
      from: dataBuffer,
      headerLength: parameterSets?.headerLength ?? 4
    )
    guard !nals.isEmpty else { return }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false
    ) as? [[CFString: Any]]
    let isKeyFrame = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    guard seconds.isFinite else {
      report(EncoderError.invalidTimestamp)
      return
    }
    let timestamp = UInt32(
      truncatingIfNeeded: UInt64(max(0, seconds * 90_000))
    )
    onAccessUnit?(nals, timestamp, isKeyFrame)
  }

  /// Nhả khung đang chờ. Có [token] thì chỉ nhả khi đúng khung đó vẫn đang chờ
  /// (tránh watchdog/callback muộn nhả nhầm khung mới).
  private func finishPendingFrame(token: UInt? = nil) {
    admissionLock.lock()
    if let token = token, !encodeQueued || pendingFrameToken != token {
      admissionLock.unlock()
      return
    }
    encodeQueued = false
    let completion = pendingCompletion
    pendingCompletion = nil
    admissionLock.unlock()
    completion?()
  }

  private func parameterSets(
    from format: CMFormatDescription
  ) -> (sps: Data, pps: Data, headerLength: Int)? {
    var values: [Data] = []
    var nalHeaderLength: Int32 = 0
    for index in 0...1 {
      var pointer: UnsafePointer<UInt8>?
      var size = 0
      var count = 0
      var headerLength: Int32 = 0
      let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format,
        parameterSetIndex: index,
        parameterSetPointerOut: &pointer,
        parameterSetSizeOut: &size,
        parameterSetCountOut: &count,
        nalUnitHeaderLengthOut: &headerLength
      )
      guard status == noErr, let pointer = pointer, size > 0 else { return nil }
      guard (1...4).contains(Int(headerLength)) else { return nil }
      nalHeaderLength = headerLength
      values.append(Data(bytes: pointer, count: size))
    }
    return (values[0], values[1], Int(nalHeaderLength))
  }

  private func lengthPrefixedNals(
    from block: CMBlockBuffer,
    headerLength: Int
  ) -> [Data] {
    let length = CMBlockBufferGetDataLength(block)
    guard (1...4).contains(headerLength), length > headerLength else { return [] }
    var bytes = Data(count: length)
    let status = bytes.withUnsafeMutableBytes {
      (destination: UnsafeMutableRawBufferPointer) -> OSStatus in
      CMBlockBufferCopyDataBytes(
        block,
        atOffset: 0,
        dataLength: length,
        destination: destination.baseAddress!
      )
    }
    guard status == kCMBlockBufferNoErr else { return [] }

    var result: [Data] = []
    var offset = 0
    while offset + headerLength <= bytes.count {
      let size = bytes.withUnsafeBytes { raw -> Int in
        let base = raw.bindMemory(to: UInt8.self).baseAddress! + offset
        var value = 0
        for index in 0..<headerLength {
          value = (value << 8) | Int(base[index])
        }
        return value
      }
      offset += headerLength
      guard size > 0, offset + size <= bytes.count else { break }
      result.append(bytes.subdata(in: offset..<(offset + size)))
      offset += size
    }
    return result
  }

  private func report(_ error: Error) {
    onError?(String(describing: error))
  }

  private enum EncoderError: Error, CustomStringConvertible {
    case operation(String, OSStatus)
    case invalidOutput
    case invalidTimestamp

    var description: String {
      switch self {
      case let .operation(name, status):
        return "VideoToolbox \(name) failed (\(status))"
      case .invalidOutput:
        return "VideoToolbox returned an invalid H.264 sample"
      case .invalidTimestamp:
        return "VideoToolbox returned an invalid frame timestamp"
      }
    }
  }
}

private let vnvarH264OutputCallback: VTCompressionOutputCallback = {
  refcon,
  sourceFrameRefcon,
  status,
  _,
  sampleBuffer in
  guard let refcon = refcon else { return }
  let encoder = Unmanaged<VnvarH264Encoder>
    .fromOpaque(refcon)
    .takeUnretainedValue()
  encoder.handle(
    status: status,
    sampleBuffer: sampleBuffer,
    token: UInt(bitPattern: sourceFrameRefcon)
  )
}
