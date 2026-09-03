import AVFoundation
import Foundation

private enum VnvarAudioSegmentError: LocalizedError {
  case alreadyRecording
  case cannotStart
  case noAudioFrames

  var errorDescription: String? {
    switch self {
    case .alreadyRecording:
      return "An audio segment is already recording."
    case .cannotStart:
      return "The iOS microphone recorder could not start."
    case .noAudioFrames:
      return "The microphone produced no audio frames."
    }
  }
}

/// Records the iOS microphone directly into a linear-PCM WAV sidecar.
/// RecordingService muxes the sidecar as AAC when finalizing the video.
final class VnvarAudioSegmentRecorder {
  private var recorder: AVAudioRecorder?
  private var path: String?

  func start(path: String) throws -> [String: Any] {
    guard recorder == nil else { throw VnvarAudioSegmentError.alreadyRecording }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .videoRecording,
      options: [.defaultToSpeaker, .allowBluetooth]
    )
    try session.setActive(true)

    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsFloatKey: false,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let newRecorder = try AVAudioRecorder(url: url, settings: settings)
    newRecorder.isMeteringEnabled = true
    guard newRecorder.prepareToRecord(), newRecorder.record() else {
      try? FileManager.default.removeItem(at: url)
      throw VnvarAudioSegmentError.cannotStart
    }
    recorder = newRecorder
    self.path = path
    return ["path": path, "active": true, "bytes": fileSize(path)]
  }

  func stop() throws -> [String: Any]? {
    guard let activeRecorder = recorder, let activePath = path else { return nil }
    recorder = nil
    path = nil
    let duration = activeRecorder.currentTime
    activeRecorder.stop()
    let bytes = fileSize(activePath)
    guard bytes > 44, duration > 0 else {
      try? FileManager.default.removeItem(atPath: activePath)
      throw VnvarAudioSegmentError.noAudioFrames
    }
    return ["path": activePath, "active": false, "bytes": bytes]
  }

  func status() -> [String: Any] {
    var result: [String: Any] = [
      "active": recorder?.isRecording == true,
      "bytes": path.map(fileSize) ?? 0,
    ]
    if let path = path { result["path"] = path }
    return result
  }

  private func fileSize(_ path: String) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }
}
