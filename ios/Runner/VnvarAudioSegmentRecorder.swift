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
///
/// Mọi trạng thái (recorder, path, pcmOffset, pcmGeneration...) chỉ được đọc/ghi
/// trên `queue`: start/stop/status chạy đồng bộ trên nó, timer đọc PCM và xử lý
/// gián đoạn âm thanh cũng chạy trên nó.
final class VnvarAudioSegmentRecorder {
  var onPcm: ((Data) -> Void)?
  /// Có ai cần PCM lúc này không (ví dụ client RTSP đang nhận tiếng). Gọi trên
  /// luồng nền của timer. nil = luôn đọc khi có onPcm (hành vi cũ).
  var isPcmNeeded: (() -> Bool)?
  /// Gián đoạn AVAudioSession: state "began" | "ended", resumed = đã ghi tiếp
  /// được sau khi gián đoạn kết thúc. Gọi trên `queue` (không phải main).
  var onInterruption: ((_ state: String, _ resumed: Bool) -> Void)?
  private let queue = DispatchQueue(
    label: "vnvar.audio.segment.recorder",
    qos: .userInitiated
  )
  private let queueKey = DispatchSpecificKey<Void>()
  private var recorder: AVAudioRecorder?
  private var path: String?
  private var pcmTimer: DispatchSourceTimer?
  private var pcmOffset: UInt64 = 0
  private var pcmGeneration: UInt64 = 0
  // Wall-clock (ms since epoch) của mẫu âm đầu tiên của segment cho đồng bộ
  // A/V (hợp đồng C2): mốc record(atTime:) quy đổi sang epoch, trừ inputLatency.
  // Chỉ gán khi start; không đổi khi ghi tiếp sau gián đoạn.
  private var firstSampleEpochMs: Double?
  /// Độ trễ hẹn giờ bắt đầu ghi (giây) trên đồng hồ thiết bị.
  static let scheduledStartDelay: TimeInterval = 0.05
  private var interruptionObserver: NSObjectProtocol?
  private var interrupted = false

  init() {
    queue.setSpecific(key: queueKey, value: ())
  }

  deinit {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    pcmTimer?.cancel()
    recorder?.stop()
  }

  /// queue.sync an toàn: chạy thẳng nếu đã ở trên `queue` (tránh deadlock).
  private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try work()
    }
    return try queue.sync(execute: work)
  }

  func start(path: String) throws -> [String: Any] {
    try onQueue { try startLocked(path: path) }
  }

  private func startLocked(path: String) throws -> [String: Any] {
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
    guard newRecorder.prepareToRecord() else {
      try? FileManager.default.removeItem(at: url)
      throw VnvarAudioSegmentError.cannotStart
    }
    // Hẹn giờ bắt đầu trên đồng hồ thiết bị âm thanh để biết chính xác mốc mẫu
    // đầu, thay vì lấy Date() sau khi record() trả về (trễ không xác định).
    // Đọc deviceCurrentTime và Date() liền nhau để quy đổi sang epoch.
    let deviceNow = newRecorder.deviceCurrentTime
    let wallNow = Date().timeIntervalSince1970
    let startDeviceTime = deviceNow + Self.scheduledStartDelay
    let firstSampleMs: Double
    if newRecorder.record(atTime: startDeviceTime) {
      firstSampleMs = Self.epochMsForFirstSample(
        wallNowSeconds: wallNow,
        deviceNow: deviceNow,
        startDeviceTime: startDeviceTime,
        inputLatency: session.inputLatency
      )
    } else if newRecorder.record() {
      // Fallback hành vi cũ: mốc = lúc record() trả về, vẫn bù inputLatency.
      let fallbackNow = Date().timeIntervalSince1970
      firstSampleMs = Self.epochMsForFirstSample(
        wallNowSeconds: fallbackNow,
        deviceNow: 0,
        startDeviceTime: 0,
        inputLatency: session.inputLatency
      )
    } else {
      try? FileManager.default.removeItem(at: url)
      throw VnvarAudioSegmentError.cannotStart
    }
    // Chỉ gán ở đây (bắt đầu segment). Ghi tiếp sau gián đoạn (record() trong
    // handleInterruption) KHÔNG được ghi đè mốc này.
    firstSampleEpochMs = firstSampleMs
    recorder = newRecorder
    self.path = path
    interrupted = false
    pcmGeneration &+= 1
    startPcmTail(path: path)
    observeInterruptions()
    return ["path": path, "active": true, "bytes": fileSize(path)]
  }

  func stop() throws -> [String: Any]? {
    try onQueue { try stopLocked() }
  }

  private func stopLocked() throws -> [String: Any]? {
    guard let activeRecorder = recorder, let activePath = path else { return nil }
    recorder = nil
    path = nil
    pcmTimer?.cancel()
    pcmTimer = nil
    pcmGeneration &+= 1
    removeInterruptionObserver()
    interrupted = false
    let firstSample = firstSampleEpochMs
    firstSampleEpochMs = nil
    let duration = activeRecorder.currentTime
    activeRecorder.stop()
    let bytes = fileSize(activePath)
    guard bytes > 44, duration > 0 else {
      try? FileManager.default.removeItem(atPath: activePath)
      throw VnvarAudioSegmentError.noAudioFrames
    }
    var result: [String: Any] = ["path": activePath, "active": false, "bytes": bytes]
    if let firstSample = firstSample {
      result["firstSampleEpochMs"] = firstSample
    }
    return result
  }

  private func observeInterruptions() {
    guard interruptionObserver == nil else { return }
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: nil
    ) { [weak self] notification in
      self?.handleInterruption(notification)
    }
  }

  private func removeInterruptionObserver() {
    if let observer = interruptionObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    interruptionObserver = nil
  }

  /// Có thể được gọi trên bất kỳ luồng nào: chuyển sang `queue`.
  private func handleInterruption(_ notification: Notification) {
    guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
    queue.async { [weak self] in
      guard let self = self, let activeRecorder = self.recorder else { return }
      switch type {
      case .began:
        self.interrupted = true
        NSLog("[VNVAR-AUDIO] Audio session interrupted")
        self.onInterruption?("began", false)
      case .ended:
        // Luôn thử ghi tiếp (kể cả khi thiếu .shouldResume): ứng dụng đang quay.
        // Không đụng tới firstSampleEpochMs: mốc mẫu đầu của segment giữ nguyên.
        var resumed = false
        do {
          try AVAudioSession.sharedInstance().setActive(true)
          resumed = activeRecorder.record()
        } catch {
          NSLog(
            "[VNVAR-AUDIO] Cannot reactivate audio session: %@",
            String(describing: error)
          )
        }
        self.interrupted = !resumed
        NSLog("[VNVAR-AUDIO] Audio interruption ended; resumed=%ld", resumed ? 1 : 0)
        self.onInterruption?("ended", resumed)
      @unknown default:
        break
      }
    }
  }

  /// Chạy trên `queue`.
  private func startPcmTail(path: String) {
    pcmOffset = 0
    let generation = pcmGeneration
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(40))
    // Một FileHandle cho cả segment thay vì mở/đóng file 25 lần mỗi giây. Chỉ
    // được dùng trong event/cancel handler của timer, vốn chạy tuần tự.
    var fileHandle: FileHandle?
    var readErrorLogged = false
    timer.setEventHandler { [weak self] in
      guard let self = self, self.pcmGeneration == generation else { return }
      if fileHandle == nil {
        fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      }
      guard let handle = fileHandle else { return }
      // Dùng API FileHandle ném lỗi Swift (iOS 13.4+). API cũ (seek(toFileOffset:),
      // readData, seekToEndOfFile, closeFile) ném NSException khi lỗi I/O, Swift
      // không bắt được và app sẽ văng giữa lúc đang quay.
      do {
        if self.pcmOffset == 0 {
          try handle.seek(toOffset: 0)
          let header = try handle.read(upToCount: 4_096) ?? Data()
          guard let range = header.range(of: Data("data".utf8)) else { return }
          self.pcmOffset = UInt64(range.upperBound + 4)
        }
        guard self.isPcmNeeded?() ?? (self.onPcm != nil) else {
          // Không ai nghe: không đọc/copy dữ liệu, chỉ nhảy tới cuối phần đã ghi
          // để khi có người nghe không phát lại tiếng cũ.
          let end = try handle.seekToEnd()
          if end > self.pcmOffset {
            self.pcmOffset = end - (end - self.pcmOffset) % 2
          }
          return
        }
        try handle.seek(toOffset: self.pcmOffset)
        // Đọc toàn bộ phần đã ghi (tối đa 1 giây). AVAudioRecorder ghi theo từng
        // đợt; đọc cố định 100 ms mỗi nhịp khiến luồng RTSP bị khoảng lặng khi
        // đợt ghi đến muộn và không bao giờ đuổi kịp phần tồn sau đó.
        guard let data = try handle.read(upToCount: 96_000), !data.isEmpty else {
          return
        }
        let aligned = data.count - (data.count % 2)
        guard aligned > 0 else { return }
        self.pcmOffset += UInt64(aligned)
        self.onPcm?(Data(data.prefix(aligned)))
      } catch {
        // Lỗi I/O: đóng file, nhịp sau mở lại. Chỉ ghi log lần đầu để không
        // lặp 25 lần/giây. Ghi âm (AVAudioRecorder) không bị ảnh hưởng.
        if !readErrorLogged {
          readErrorLogged = true
          NSLog("[VNVAR-AUDIO] PCM tail read failed: %@", String(describing: error))
        }
        try? handle.close()
        fileHandle = nil
      }
    }
    timer.setCancelHandler {
      try? fileHandle?.close()
      fileHandle = nil
    }
    pcmTimer = timer
    timer.resume()
  }

  func status() -> [String: Any] {
    onQueue { () -> [String: Any] in
      var result: [String: Any] = [
        "active": recorder?.isRecording == true,
        "bytes": path.map(fileSize) ?? 0,
        "interrupted": interrupted,
      ]
      if let path = path { result["path"] = path }
      return result
    }
  }

  /// Hàm thuần: quy đổi thời điểm bắt đầu trên đồng hồ thiết bị âm thanh
  /// (`deviceCurrentTime`) sang ms epoch, rồi trừ độ trễ đầu vào (mẫu đầu được
  /// micro thu sớm hơn lúc ghi vào file một khoảng `inputLatency`).
  /// `wallNowSeconds` và `deviceNow` phải được đo cùng lúc. Latency âm/NaN/vô
  /// cực bị bỏ qua (coi như 0).
  static func epochMsForFirstSample(
    wallNowSeconds: TimeInterval,
    deviceNow: TimeInterval,
    startDeviceTime: TimeInterval,
    inputLatency: TimeInterval
  ) -> Double {
    let latency = inputLatency.isFinite && inputLatency > 0 ? inputLatency : 0
    let startEpochSeconds = wallNowSeconds + (startDeviceTime - deviceNow)
    return (startEpochSeconds - latency) * 1000
  }

  private func fileSize(_ path: String) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }
}
