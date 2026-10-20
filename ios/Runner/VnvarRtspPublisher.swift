import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

final class VnvarRtspPublisher: NSObject, RTCVideoRenderer {
  var onEncoderConfigured: (() -> Void)?
  var onEncoderError: ((String) -> Void)?
  var onServerReady: (() -> Void)?
  var onCapturePerformance: ((_ actualFps: Double, _ requestedFps: Int) -> Void)?

  private let track: RTCVideoTrack
  private let audioSink: VnvarWebRtcAudioSink?
  private let server: VnvarRtspServer
  private let encoder: VnvarH264Encoder
  private let stateQueue = DispatchQueue(label: "vnvar.rtsp.publisher.state")
  private let frameQueue = DispatchQueue(label: "vnvar.rtsp.publisher.frames")
  private let frameQueueKey = DispatchSpecificKey<Void>()
  // Bảo vệ running/formatReady/framePending. renderFrame chạy trên luồng
  // capture WebRTC mỗi khung: chỉ lấy khoá ngắn, không bao giờ queue.sync
  // sang hàng đợi khác (làm nghẽn capture và giảm FPS ghi).
  private let gateLock = NSLock()
  private var running = false
  private var formatReady = false
  private var framePending = false
  private var errorReported = false
  private var bitrateController: VnvarRtspBitrateController
  private var performanceWindowStart = ProcessInfo.processInfo.systemUptime
  private var performanceFrameCount = 0
  private let requestedFps: Int
  private let maximumBitrate: Int
  // Timestamp RTP âm thanh tiếp theo (đơn vị mẫu 48 kHz). Tăng theo số mẫu
  // thực để không có khe hở/chồng lấn giữa các gói; chỉ neo lại theo đồng hồ
  // khi lệch quá xa (sau khi micro khởi động lại giữa hai segment).
  private var nextAudioTimestamp: UInt64?
  var audioAvailable: Bool { audioSink != nil || nativeAudioAvailable }
  private let nativeAudioAvailable: Bool

  init(
    track: RTCVideoTrack,
    audioTrackId: String?,
    nativeAudioAvailable: Bool,
    port: Int,
    bitrate: Int,
    fps: Int
  ) {
    self.track = track
    audioSink = audioTrackId.flatMap { VnvarWebRtcAudioSink(trackId: $0) }
    self.nativeAudioAvailable = nativeAudioAvailable
    server = VnvarRtspServer(port: port)
    encoder = VnvarH264Encoder(bitrate: bitrate, fps: fps)
    bitrateController = VnvarRtspBitrateController(maximumBitrate: bitrate)
    maximumBitrate = max(250_000, bitrate)
    requestedFps = max(1, fps)
    super.init()
    frameQueue.setSpecific(key: frameQueueKey, value: ())

    encoder.onFormat = { [weak self] sps, pps in
      guard let self = self else { return }
      self.server.updateFormat(sps: sps, pps: pps)
      let wasReady = self.withGate { () -> Bool in
        let value = self.formatReady
        self.formatReady = true
        return value
      }
      self.stateQueue.async { self.errorReported = false }
      if !wasReady {
        DispatchQueue.main.async { self.onEncoderConfigured?() }
      }
    }
    encoder.onAccessUnit = { [weak self] nals, timestamp, isKeyFrame in
      self?.server.sendAccessUnit(
        nals: nals,
        timestamp: timestamp,
        isKeyFrame: isKeyFrame
      )
    }
    encoder.onError = { [weak self] message in self?.reportError(message) }
    server.onPlayRequested = { [weak self] in self?.encoder.requestKeyFrame() }
    server.onPictureLossIndication = { [weak self] in
      self?.encoder.requestKeyFrame()
    }
    server.onReceiverReport = { [weak self] fractionLost in
      guard let self = self else { return }
      self.stateQueue.async {
        if let bitrate = self.bitrateController.report(fractionLost: fractionLost) {
          self.encoder.updateBitrate(bitrate)
        }
      }
    }
    server.onError = { [weak self] message in self?.reportError(message) }
    server.onReady = { [weak self] in
      DispatchQueue.main.async { self?.onServerReady?() }
    }
    server.setAudioAvailable(audioSink != nil || nativeAudioAvailable)
    audioSink?.onPcm = { [weak self] pcm, sampleRate, channels, bits in
      self?.handleAudio(
        pcm,
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bits
      )
    }
  }

  /// Bitrate mục tiêu do bộ thích ứng livestream đặt. Báo cáo RTCP từ Tablet
  /// chỉ được hạ thấp hơn mức này.
  func setTargetBitrate(_ bitrate: Int) {
    stateQueue.async { [weak self] in
      guard let self = self else { return }
      let target = min(self.maximumBitrate, max(250_000, bitrate))
      self.bitrateController = VnvarRtspBitrateController(maximumBitrate: target)
      self.encoder.updateBitrate(target)
    }
  }

  func setRemoteAudioEnabled(_ enabled: Bool) {
    server.setRemoteAudioEnabled(enabled)
  }

  func sendNativePcm(_ pcm: Data) {
    guard nativeAudioAvailable else { return }
    handleAudio(pcm, sampleRate: 48_000, channels: 1, bitsPerSample: 16)
  }

  /// Có client RTSP đang nhận tiếng: chỉ khi đó mới cần đọc PCM từ file ghi âm.
  var needsNativeAudio: Bool {
    nativeAudioAvailable && server.hasPlayingAudioClients
  }

  func start() throws {
    let shouldStart = withGate { () -> Bool in
      guard !running else { return false }
      running = true
      return true
    }
    guard shouldStart else { return }
    do {
      try server.start()
    } catch {
      withGate { running = false }
      throw error
    }
    track.add(self)
  }

  func stop() {
    let wasRunning = withGate { () -> Bool in
      let value = running
      running = false
      formatReady = false
      return value
    }
    if wasRunning { track.remove(self) }
    audioSink?.close()
    // Chờ các khung đang xử lý xong. Nếu stop() chạy ngay trên frameQueue thì
    // không thể tự chờ chính mình (sẽ treo cứng): bỏ qua bước này.
    if DispatchQueue.getSpecific(key: frameQueueKey) == nil {
      frameQueue.sync {}
    }
    encoder.stop()
    server.stop()
    // Nhả pool CVPixelBuffer dùng để chuyển khung WebRTC sang canvas RTSP.
    VnvarWebRtcTrackBridge.releaseConversionResources()
  }

  /// Khoá ngắn quanh running/formatReady/framePending. Không gọi lồng nhau và
  /// không gọi callback/hàng đợi khác trong [work] (NSLock không đệ quy).
  private func withGate<T>(_ work: () -> T) -> T {
    gateLock.lock()
    defer { gateLock.unlock() }
    return work()
  }

  private var isRunning: Bool {
    withGate { running }
  }

  private func releaseFramePending() {
    withGate { framePending = false }
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame = frame else { return }
    observeCaptureFrame()
    // Chỉ khoá ngắn + đọc cờ có khoá của server: luồng capture không chờ
    // stateQueue hay hàng đợi gửi RTSP.
    let state = withGate { () -> (ready: Bool, accept: Bool) in
      guard running, !framePending else { return (formatReady, false) }
      framePending = true
      return (formatReady, true)
    }
    guard state.accept else { return }
    if state.ready && !server.hasPlayingClients {
      releaseFramePending()
      return
    }
    frameQueue.async { [weak self] in
      autoreleasepool {
        guard let self = self else { return }
        guard self.isRunning else {
          self.releaseFramePending()
          return
        }
        guard let pixelBuffer = VnvarWebRtcTrackBridge.copyPixelBuffer(for: frame) else {
          self.releaseFramePending()
          self.reportError("Cannot convert WebRTC frame to CVPixelBuffer")
          return
        }
        self.encoder.encode(
          pixelBuffer: pixelBuffer,
          timestampNs: frame.timeStampNs
        ) { [weak self] in
          self?.releaseFramePending()
        }
      }
    }
  }

  private func observeCaptureFrame() {
    stateQueue.async { [weak self] in
      guard let self = self, self.isRunning else { return }
      self.performanceFrameCount += 1
      let now = ProcessInfo.processInfo.systemUptime
      let elapsed = now - self.performanceWindowStart
      guard elapsed >= 5 else { return }
      let actualFps = Double(self.performanceFrameCount) / elapsed
      self.performanceFrameCount = 0
      self.performanceWindowStart = now
      DispatchQueue.main.async {
        self.onCapturePerformance?(actualFps, self.requestedFps)
      }
    }
  }

  private func handleAudio(
    _ pcm: Data,
    sampleRate: Int,
    channels: Int,
    bitsPerSample: Int
  ) {
    guard server.hasPlayingAudioClients else { return }
    guard sampleRate == 48_000, channels > 0, bitsPerSample == 16 else {
      reportError(
        "Unsupported WebRTC audio format: \(sampleRate)Hz/\(channels)ch/\(bitsPerSample)bit"
      )
      return
    }
    // RTCVideoFrame.timeStampNs and systemUptime are monotonic clocks. The
    // audio clock is anchored to the same time base, then advanced by the real
    // sample count. Stamping every chunk with its arrival time made bursty
    // AVAudioRecorder writes overlap or leave gaps, heard as audio dropouts.
    let chunkFrames = UInt64(pcm.count / MemoryLayout<Int16>.size / max(channels, 1))
    let timestamp: UInt32 = stateQueue.sync {
      let now = UInt64(ProcessInfo.processInfo.systemUptime * 48_000)
      let expectedStart = now > chunkFrames ? now - chunkFrames : 0
      let tolerance: UInt64 = 48_000 / 2
      if let next = nextAudioTimestamp,
         next + tolerance >= expectedStart,
         next <= expectedStart + tolerance {
        nextAudioTimestamp = next + chunkFrames
        return UInt32(truncatingIfNeeded: next)
      }
      nextAudioTimestamp = expectedStart + chunkFrames
      return UInt32(truncatingIfNeeded: expectedStart)
    }
    frameQueue.async { [weak self] in
      guard let self = self,
            self.isRunning,
            !pcm.isEmpty else { return }
      let sampleCount = pcm.count / MemoryLayout<Int16>.size
      let frameCount = sampleCount / channels
      guard frameCount > 0 else { return }
      // Ghi thẳng vào bộ đệm cấp sẵn (big-endian cho RTP L16) thay vì append
      // từng byte vào Data.
      var networkPcm = Data(count: frameCount * MemoryLayout<UInt16>.size)
      networkPcm.withUnsafeMutableBytes { output in
        let destination = output.bindMemory(to: UInt16.self)
        pcm.withUnsafeBytes { raw in
          let samples = raw.bindMemory(to: Int16.self)
          if channels == 1 {
            for frame in 0..<frameCount {
              destination[frame] = UInt16(bitPattern: samples[frame]).bigEndian
            }
          } else {
            for frame in 0..<frameCount {
              var sum = 0
              for channel in 0..<channels {
                sum += Int(samples[frame * channels + channel])
              }
              let mono = Int16(clamping: sum / channels)
              destination[frame] = UInt16(bitPattern: mono).bigEndian
            }
          }
        }
      }
      self.server.sendAudio(pcm: networkPcm, timestamp: timestamp)
    }
  }

  private func reportError(_ message: String) {
    stateQueue.async { [weak self] in
      guard let self = self, !self.errorReported else { return }
      self.errorReported = true
      DispatchQueue.main.async { self.onEncoderError?(message) }
    }
  }
}

struct VnvarRtspBitrateController {
  let maximumBitrate: Int
  let minimumBitrate: Int
  private(set) var currentBitrate: Int
  private var healthyReports = 0

  init(maximumBitrate: Int) {
    let maximum = max(250_000, maximumBitrate)
    self.maximumBitrate = maximum
    // Sàn không được vượt trần (ví dụ trần 300 kbps < sàn 500 kbps).
    minimumBitrate = min(maximum, max(500_000, maximum / 4))
    currentBitrate = maximum
  }

  mutating func report(fractionLost: Double) -> Int? {
    let loss = min(1, max(0, fractionLost))
    if loss >= 0.10 {
      healthyReports = 0
      let reduced = max(minimumBitrate, Int(Double(currentBitrate) * 0.75))
      guard reduced != currentBitrate else { return nil }
      currentBitrate = reduced
      return currentBitrate
    }
    if loss <= 0.02 {
      healthyReports += 1
      guard healthyReports >= 3 else { return nil }
      healthyReports = 0
      let increased = min(maximumBitrate, Int(Double(currentBitrate) * 1.10))
      guard increased != currentBitrate else { return nil }
      currentBitrate = increased
      return currentBitrate
    }
    healthyReports = 0
    return nil
  }
}

// MARK: - Luồng RTSP overlay (bảng tỉ số) cho livestream iOS

/// Hình học chồng ảnh overlay lên canvas. Thuần (không phụ thuộc GPU) để
/// kiểm thử. Toạ độ theo Core Image: gốc ở góc dưới-trái.
enum VnvarOverlayGeometry {
  /// Khung đích để ảnh overlay vừa canvas: giữ tỉ lệ, căn giữa. Ảnh cùng
  /// kích thước canvas (trường hợp thường gặp) cho đúng bounds của canvas.
  static func fittedRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          canvasSize.width > 0, canvasSize.height > 0,
          imageSize.width.isFinite, imageSize.height.isFinite else {
      return .zero
    }
    let scale = min(
      canvasSize.width / imageSize.width,
      canvasSize.height / imageSize.height
    )
    let width = imageSize.width * scale
    let height = imageSize.height * scale
    return CGRect(
      x: (canvasSize.width - width) / 2,
      y: (canvasSize.height - height) / 2,
      width: width,
      height: height
    )
  }

  /// Biến đổi đưa [extent] (extent của CIImage nguồn) về đúng [rect].
  static func transform(from extent: CGRect, to rect: CGRect) -> CGAffineTransform {
    guard extent.width > 0, extent.height > 0 else { return .identity }
    return CGAffineTransform(translationX: rect.minX, y: rect.minY)
      .scaledBy(x: rect.width / extent.width, y: rect.height / extent.height)
      .translatedBy(x: -extent.minX, y: -extent.minY)
  }
}

/// Chồng ảnh PNG bảng tỉ số lên canvas camera bằng Core Image rồi render một
/// lần vào CVPixelBuffer NV12 từ pool riêng. Mọi hàm trừ `setOverlayPath`
/// chỉ được gọi trên hàng đợi khung của publisher overlay.
final class VnvarOverlayCompositor {
  enum CompositorError: Error, CustomStringConvertible {
    case cannotLoadOverlay(String)

    var description: String {
      switch self {
      case let .cannotLoadOverlay(path):
        return "Cannot load overlay image at \(path)"
      }
    }
  }

  /// Kiểm mtime ảnh overlay tối đa 2 lần/giây (dự phòng khi Dart quên gọi
  /// updateOverlayImage).
  static let modificationCheckInterval: TimeInterval = 0.5

  private let context: CIContext
  private let outputColorSpace = CGColorSpaceCreateDeviceRGB()
  private let overlayColorSpace =
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  private let pathLock = NSLock()
  private var overlayPath: String
  private var reloadRequested = false

  private var sourceOverlay: CIImage?
  private var loadedModification: Date?
  private var lastModificationCheck: TimeInterval = 0
  // Overlay đã scale/đặt vị trí sẵn theo canvas, nằm trong buffer BGRA
  // IOSurface: GPU đọc trực tiếp mỗi khung, không giải mã PNG lại.
  private var preparedOverlay: CIImage?
  private var preparedWidth = 0
  private var preparedHeight = 0
  private var outputPool: CVPixelBufferPool?
  private var outputPoolWidth = 0
  private var outputPoolHeight = 0

  init(overlayPath: String) throws {
    self.overlayPath = overlayPath
    let options: [CIContextOption: Any] = [
      .cacheIntermediates: false,
      .useSoftwareRenderer: false,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      context = CIContext(mtlDevice: device, options: options)
    } else {
      context = CIContext(options: options)
    }
    let modification = VnvarOverlayCompositor.modificationDate(of: overlayPath)
    guard let image = VnvarOverlayCompositor.loadImage(path: overlayPath) else {
      throw CompositorError.cannotLoadOverlay(overlayPath)
    }
    sourceOverlay = image
    loadedModification = modification
    lastModificationCheck = ProcessInfo.processInfo.systemUptime
  }

  /// An toàn từ mọi luồng. Ảnh được nạp lại ở khung kế tiếp.
  func setOverlayPath(_ path: String) {
    pathLock.lock()
    overlayPath = path
    reloadRequested = true
    pathLock.unlock()
  }

  /// Trả buffer NV12 kích thước bằng extent của [canvas] (gốc (0,0)).
  func render(canvas: CIImage) -> CVPixelBuffer? {
    let extent = canvas.extent
    guard extent.width.isFinite, extent.height.isFinite else { return nil }
    let width = Int(extent.width.rounded())
    let height = Int(extent.height.rounded())
    guard width > 0, height > 0 else { return nil }
    var base = canvas
    if extent.origin != .zero {
      base = base.transformed(
        by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
      )
    }
    refreshOverlayIfNeeded(width: width, height: height)
    let composed = preparedOverlay.map { $0.composited(over: base) } ?? base
    guard let output = makeOutputBuffer(width: width, height: height) else {
      return nil
    }
    context.render(
      composed,
      to: output,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      colorSpace: outputColorSpace
    )
    return output
  }

  func releaseResources() {
    preparedOverlay = nil
    preparedWidth = 0
    preparedHeight = 0
    outputPool = nil
    outputPoolWidth = 0
    outputPoolHeight = 0
    context.clearCaches()
  }

  private func refreshOverlayIfNeeded(width: Int, height: Int) {
    pathLock.lock()
    let path = overlayPath
    var reload = reloadRequested
    reloadRequested = false
    pathLock.unlock()

    let now = ProcessInfo.processInfo.systemUptime
    if !reload, now - lastModificationCheck >= Self.modificationCheckInterval {
      lastModificationCheck = now
      if let modification = Self.modificationDate(of: path),
         modification != loadedModification {
        reload = true
      }
    }
    if reload {
      // Lấy mtime TRƯỚC khi đọc: nếu file bị thay giữa chừng, lần kiểm sau
      // thấy mtime khác và nạp lại.
      let modification = Self.modificationDate(of: path)
      if let image = Self.loadImage(path: path) {
        sourceOverlay = image
        loadedModification = modification
        preparedOverlay = nil
      } else {
        // Giữ ảnh cũ; mtime cũ được giữ nên lần kiểm sau sẽ thử lại.
        NSLog("[VNVAR-RTSP-OVERLAY] Cannot load overlay %@; keeping previous", path)
      }
      lastModificationCheck = now
    }
    if preparedOverlay == nil || preparedWidth != width || preparedHeight != height {
      prepareOverlay(width: width, height: height)
    }
  }

  private func prepareOverlay(width: Int, height: Int) {
    preparedOverlay = nil
    preparedWidth = width
    preparedHeight = height
    guard let source = sourceOverlay else { return }
    let sourceExtent = source.extent
    guard !sourceExtent.isInfinite, !sourceExtent.isEmpty else { return }
    let canvasRect = CGRect(x: 0, y: 0, width: width, height: height)
    let target = VnvarOverlayGeometry.fittedRect(
      imageSize: sourceExtent.size,
      canvasSize: canvasRect.size
    )
    guard !target.isEmpty else { return }
    let positioned = source.transformed(
      by: VnvarOverlayGeometry.transform(from: sourceExtent, to: target)
    )
    let transparent = CIImage(color: CIColor.clear).cropped(to: canvasRect)
    let image = positioned.composited(over: transparent).cropped(to: canvasRect)

    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &buffer
    )
    guard status == kCVReturnSuccess, let overlayBuffer = buffer else {
      NSLog("[VNVAR-RTSP-OVERLAY] Cannot allocate overlay buffer (%d)", status)
      return
    }
    context.render(
      image,
      to: overlayBuffer,
      bounds: canvasRect,
      colorSpace: overlayColorSpace
    )
    preparedOverlay = CIImage(
      cvPixelBuffer: overlayBuffer,
      options: [.colorSpace: overlayColorSpace]
    )
  }

  private func makeOutputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if outputPool == nil || outputPoolWidth != width || outputPoolHeight != height {
      outputPool = nil
      let pixelAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      let poolAttributes: [String: Any] = [
        kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
      ]
      var pool: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        poolAttributes as CFDictionary,
        pixelAttributes as CFDictionary,
        &pool
      )
      guard status == kCVReturnSuccess, let createdPool = pool else { return nil }
      outputPool = createdPool
      outputPoolWidth = width
      outputPoolHeight = height
    }
    guard let pool = outputPool else { return nil }
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
    return status == kCVReturnSuccess ? buffer : nil
  }

  private static func modificationDate(of path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }

  /// Đọc toàn bộ file vào bộ nhớ trước (ảnh chụp nhất quán dù Dart thay file
  /// bằng rename ngay sau đó).
  private static func loadImage(path: String) -> CIImage? {
    guard !path.isEmpty,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          !data.isEmpty else { return nil }
    return CIImage(data: data, options: [.applyOrientationProperty: true])
  }
}

/// Luồng RTSP thứ hai CHỈ loopback (mặc định 127.0.0.1:8555/camera), chỉ
/// video H.264 = khung camera (cùng track WebRTC, cùng canvas với luồng chính)
/// chồng ảnh bảng tỉ số. FFmpeg phía Dart chỉ copy luồng này lên RTMP. Luồng
/// chính 8554 cho tablet không bị ảnh hưởng.
final class VnvarOverlayRtspPublisher: NSObject, RTCVideoRenderer {
  var onServerReady: (() -> Void)?
  var onEncoderConfigured: (() -> Void)?
  var onError: ((String) -> Void)?

  /// Số khung lỗi chồng ảnh liên tiếp trước khi báo lỗi lên Dart (một lần
  /// cấp phát buffer hụt không đáng dừng livestream).
  private static let maximumConsecutiveFrameFailures = 30

  private let track: RTCVideoTrack
  private let server: VnvarRtspServer
  private let encoder: VnvarH264Encoder
  private let compositor: VnvarOverlayCompositor
  private let stateQueue = DispatchQueue(label: "vnvar.rtsp.overlay.state")
  private let frameQueue = DispatchQueue(label: "vnvar.rtsp.overlay.frames")
  private let frameQueueKey = DispatchSpecificKey<Void>()
  // Cùng cơ chế với VnvarRtspPublisher: renderFrame chạy trên luồng capture,
  // chỉ lấy khoá ngắn, bỏ khung khi khung trước chưa xong.
  private let gateLock = NSLock()
  private var running = false
  private var formatReady = false
  private var framePending = false
  private var errorReported = false
  // Chỉ truy cập trên frameQueue.
  private var consecutiveFrameFailures = 0

  init(
    track: RTCVideoTrack,
    port: Int,
    bitrate: Int,
    fps: Int,
    overlayPath: String
  ) throws {
    compositor = try VnvarOverlayCompositor(overlayPath: overlayPath)
    self.track = track
    server = VnvarRtspServer(port: port, loopbackOnly: true)
    // GOP 2 s cho RTMP; SPS/PPS được server chèn lại trước mỗi IDR.
    encoder = VnvarH264Encoder(bitrate: bitrate, fps: fps, keyFrameIntervalSeconds: 2)
    super.init()
    frameQueue.setSpecific(key: frameQueueKey, value: ())

    encoder.onFormat = { [weak self] sps, pps in
      guard let self = self else { return }
      self.server.updateFormat(sps: sps, pps: pps)
      let wasReady = self.withGate { () -> Bool in
        let value = self.formatReady
        self.formatReady = true
        return value
      }
      if !wasReady {
        DispatchQueue.main.async { [weak self] in self?.onEncoderConfigured?() }
      }
    }
    encoder.onAccessUnit = { [weak self] nals, timestamp, isKeyFrame in
      self?.server.sendAccessUnit(nals: nals, timestamp: timestamp, isKeyFrame: isKeyFrame)
    }
    encoder.onError = { [weak self] message in self?.reportError(message) }
    server.onPlayRequested = { [weak self] in self?.encoder.requestKeyFrame() }
    server.onPictureLossIndication = { [weak self] in self?.encoder.requestKeyFrame() }
    server.onError = { [weak self] message in self?.reportError(message) }
    server.onReady = { [weak self] in
      DispatchQueue.main.async { [weak self] in self?.onServerReady?() }
    }
    server.setAudioAvailable(false)
  }

  func start() throws {
    let shouldStart = withGate { () -> Bool in
      guard !running else { return false }
      running = true
      return true
    }
    guard shouldStart else { return }
    do {
      try server.start()
    } catch {
      withGate { running = false }
      throw error
    }
    track.add(self)
  }

  func stop() {
    let wasRunning = withGate { () -> Bool in
      let value = running
      running = false
      formatReady = false
      return value
    }
    if wasRunning { track.remove(self) }
    if DispatchQueue.getSpecific(key: frameQueueKey) == nil {
      frameQueue.sync {}
    }
    encoder.stop()
    server.stop()
    let compositor = self.compositor
    frameQueue.async { compositor.releaseResources() }
  }

  func setTargetBitrate(_ bitrate: Int) {
    // Encoder tự kẹp vào [250 kbps, bitrate lúc start].
    encoder.updateBitrate(bitrate)
  }

  func updateOverlayImage(path: String) {
    compositor.setOverlayPath(path)
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame = frame else { return }
    let state = withGate { () -> (ready: Bool, accept: Bool) in
      guard running, !framePending else { return (formatReady, false) }
      framePending = true
      return (formatReady, true)
    }
    guard state.accept else { return }
    // Đã có SPS/PPS mà FFmpeg chưa PLAY: không tốn GPU/encoder.
    if state.ready && !server.hasPlayingClients {
      releaseFramePending()
      return
    }
    frameQueue.async { [weak self] in
      guard let self = self else { return }
      autoreleasepool {
        guard self.isRunning else {
          self.releaseFramePending()
          return
        }
        guard let canvas = VnvarWebRtcTrackBridge.canvasImage(for: frame),
              let pixelBuffer = self.compositor.render(canvas: canvas) else {
          self.releaseFramePending()
          self.consecutiveFrameFailures += 1
          if self.consecutiveFrameFailures >= Self.maximumConsecutiveFrameFailures {
            self.reportError("Cannot compose overlay frame")
          }
          return
        }
        self.consecutiveFrameFailures = 0
        self.encoder.encode(
          pixelBuffer: pixelBuffer,
          timestampNs: frame.timeStampNs
        ) { [weak self] in
          self?.releaseFramePending()
        }
      }
    }
  }

  private func withGate<T>(_ work: () -> T) -> T {
    gateLock.lock()
    defer { gateLock.unlock() }
    return work()
  }

  private var isRunning: Bool {
    withGate { running }
  }

  private func releaseFramePending() {
    withGate { framePending = false }
  }

  private func reportError(_ message: String) {
    stateQueue.async { [weak self] in
      guard let self = self, !self.errorReported else { return }
      self.errorReported = true
      DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
  }
}
