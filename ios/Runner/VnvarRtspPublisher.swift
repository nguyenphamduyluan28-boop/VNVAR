import CoreGraphics
import Foundation

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

    encoder.onFormat = { [weak self] sps, pps in
      guard let self = self else { return }
      self.server.updateFormat(sps: sps, pps: pps)
      self.stateQueue.async {
        let wasReady = self.formatReady
        self.formatReady = true
        self.errorReported = false
        if !wasReady {
          DispatchQueue.main.async { self.onEncoderConfigured?() }
        }
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

  func start() throws {
    let shouldStart = stateQueue.sync { () -> Bool in
      guard !running else { return false }
      running = true
      return true
    }
    guard shouldStart else { return }
    do {
      try server.start()
    } catch {
      stateQueue.sync { running = false }
      throw error
    }
    track.add(self)
  }

  func stop() {
    let wasRunning = stateQueue.sync { () -> Bool in
      let value = running
      running = false
      formatReady = false
      return value
    }
    if wasRunning { track.remove(self) }
    audioSink?.close()
    frameQueue.sync {}
    encoder.stop()
    server.stop()
  }

  func setSize(_ size: CGSize) {}

  func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame = frame else { return }
    observeCaptureFrame()
    let state = stateQueue.sync { () -> (running: Bool, ready: Bool, accept: Bool) in
      guard running, !framePending else { return (running, formatReady, false) }
      framePending = true
      return (running, formatReady, true)
    }
    guard state.accept else { return }
    if state.ready && !server.hasPlayingClients {
      stateQueue.async { self.framePending = false }
      return
    }
    frameQueue.async { [weak self] in
      autoreleasepool {
        guard let self = self else { return }
        guard self.stateQueue.sync(execute: { self.running }) else {
          self.stateQueue.async { self.framePending = false }
          return
        }
        guard let pixelBuffer = VnvarWebRtcTrackBridge.copyPixelBuffer(for: frame) else {
          self.stateQueue.async { self.framePending = false }
          self.reportError("Cannot convert WebRTC frame to CVPixelBuffer")
          return
        }
        self.encoder.encode(
          pixelBuffer: pixelBuffer,
          timestampNs: frame.timeStampNs
        ) { [weak self] in
          self?.stateQueue.async { self?.framePending = false }
        }
      }
    }
  }

  private func observeCaptureFrame() {
    stateQueue.async { [weak self] in
      guard let self = self, self.running else { return }
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
            self.stateQueue.sync(execute: { self.running }),
            !pcm.isEmpty else { return }
      let sampleCount = pcm.count / MemoryLayout<Int16>.size
      let frameCount = sampleCount / channels
      guard frameCount > 0 else { return }
      var networkPcm = Data(capacity: frameCount * 2)
      pcm.withUnsafeBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for frame in 0..<frameCount {
          var sum = 0
          for channel in 0..<channels {
            sum += Int(samples[frame * channels + channel])
          }
          let mono = Int16(clamping: sum / channels)
          let value = UInt16(bitPattern: mono)
          networkPcm.append(UInt8((value >> 8) & 0xFF))
          networkPcm.append(UInt8(value & 0xFF))
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
    minimumBitrate = max(500_000, maximum / 4)
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
