import Foundation

private enum VnvarAudioSegmentError: LocalizedError {
  case alreadyRecording
  case trackNotFound
  case unsupportedFormat(Int, Int, Int)
  case noAudioFrames

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      return "An audio segment is already recording."
    case .trackNotFound:
      return "The local WebRTC audio track was not found."
    case let .unsupportedFormat(rate, channels, bits):
      return "Unsupported PCM format: \(rate)Hz/\(channels)ch/\(bits)bit."
    case .noAudioFrames:
      return "The microphone produced no audio frames."
    }
  }
}

/// Writes the local WebRTC microphone PCM to a WAV sidecar. RecordingService
/// muxes this sidecar with the video MP4 when the segment is finalized.
final class VnvarAudioSegmentRecorder {
  private let queue = DispatchQueue(label: "vnvar.recording.audio-segment")
  private var sink: VnvarWebRtcAudioSink?
  private var handle: FileHandle?
  private var path: String?
  private var sampleRate = 0
  private var channels = 0
  private var bitsPerSample = 0
  private var pcmBytes: UInt64 = 0
  private var formatError: Error?

  func start(path: String, trackId: String) throws -> [String: Any] {
    guard sink == nil else { throw VnvarAudioSegmentError.alreadyRecording }
    guard let newSink = VnvarWebRtcAudioSink(trackId: trackId) else {
      throw VnvarAudioSegmentError.trackNotFound
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0, count: 44))
    let newHandle = try FileHandle(forWritingTo: url)
    try newHandle.seek(toOffset: 44)
    queue.sync {
      self.path = path
      self.handle = newHandle
      self.sampleRate = 0
      self.channels = 0
      self.bitsPerSample = 0
      self.pcmBytes = 0
      self.formatError = nil
    }
    newSink.onPcm = { [weak self] pcm, rate, channels, bits in
      self?.append(pcm, sampleRate: rate, channels: channels, bitsPerSample: bits)
    }
    sink = newSink
    return ["path": path, "active": true, "bytes": 44]
  }

  func stop() throws -> [String: Any]? {
    guard let activeSink = sink else { return nil }
    sink = nil
    activeSink.close()
    return try queue.sync {
      guard let activeHandle = handle, let activePath = path else { return nil }
      defer { reset() }
      if let formatError = formatError {
        try? activeHandle.close()
        try? FileManager.default.removeItem(atPath: activePath)
        throw formatError
      }
      guard sampleRate > 0, channels > 0, bitsPerSample == 16, pcmBytes > 0 else {
        try? activeHandle.close()
        try? FileManager.default.removeItem(atPath: activePath)
        throw VnvarAudioSegmentError.noAudioFrames
      }
      let dataSize = UInt32(min(pcmBytes, UInt64(UInt32.max)))
      let header = wavHeader(
        dataSize: dataSize,
        sampleRate: UInt32(sampleRate),
        channels: UInt16(channels),
        bitsPerSample: UInt16(bitsPerSample)
      )
      try activeHandle.seek(toOffset: 0)
      try activeHandle.write(contentsOf: header)
      try activeHandle.synchronize()
      try activeHandle.close()
      return ["path": activePath, "active": false, "bytes": Int(dataSize) + 44]
    }
  }

  func status() -> [String: Any] {
    queue.sync {
      var result: [String: Any] = [
        "active": handle != nil,
        "bytes": Int(pcmBytes) + (handle == nil ? 0 : 44),
      ]
      if let path = path { result["path"] = path }
      return result
    }
  }

  private func append(_ pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) {
    guard !pcm.isEmpty else { return }
    queue.async { [weak self] in
      guard let self = self, let handle = self.handle, self.formatError == nil else { return }
      guard sampleRate > 0, channels > 0, bitsPerSample == 16 else {
        self.formatError = VnvarAudioSegmentError.unsupportedFormat(sampleRate, channels, bitsPerSample)
        return
      }
      if self.sampleRate == 0 {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
      } else if self.sampleRate != sampleRate || self.channels != channels || self.bitsPerSample != bitsPerSample {
        self.formatError = VnvarAudioSegmentError.unsupportedFormat(sampleRate, channels, bitsPerSample)
        return
      }
      do {
        try handle.write(contentsOf: pcm)
        self.pcmBytes += UInt64(pcm.count)
      } catch {
        self.formatError = error
      }
    }
  }

  private func reset() {
    handle = nil
    path = nil
    sampleRate = 0
    channels = 0
    bitsPerSample = 0
    pcmBytes = 0
    formatError = nil
  }

  private func wavHeader(
    dataSize: UInt32,
    sampleRate: UInt32,
    channels: UInt16,
    bitsPerSample: UInt16
  ) -> Data {
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * UInt32(blockAlign)
    var data = Data()
    data.append("RIFF".data(using: .ascii)!)
    data.appendLittleEndian(36 &+ dataSize)
    data.append("WAVEfmt ".data(using: .ascii)!)
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channels)
    data.appendLittleEndian(sampleRate)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(blockAlign)
    data.appendLittleEndian(bitsPerSample)
    data.append("data".data(using: .ascii)!)
    data.appendLittleEndian(dataSize)
    return data
  }
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
