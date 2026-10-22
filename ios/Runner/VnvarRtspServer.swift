import Foundation
import Network

struct VnvarVideoRecoveryGate {
  private(set) var awaitingKeyFrame = true

  mutating func beginPlaying() {
    awaitingKeyFrame = true
  }

  mutating func shouldSend(isKeyFrame: Bool) -> Bool {
    guard !awaitingKeyFrame || isKeyFrame else { return false }
    if isKeyFrame { awaitingKeyFrame = false }
    return true
  }

  /// Marks the reference chain as broken and returns whether the encoder
  /// should be asked for a fresh keyframe.
  mutating func didDrop(isKeyFrame: Bool) -> Bool {
    let shouldRequestKeyFrame = !awaitingKeyFrame || isKeyFrame
    awaitingKeyFrame = true
    return shouldRequestKeyFrame
  }
}

/// Giữ báo cáo RTCP Receiver Report gần nhất của từng client mạng để quyết
/// định bitrate theo TRUNG VỊ fraction lost, không để một tablet mạng yếu (hay
/// relay FFmpeg loopback) kéo bitrate của mọi người xem xuống.
struct VnvarRtcpLossTracker {
  /// Báo cáo cũ hơn chừng này (giây) bị bỏ.
  static let reportLifetime: TimeInterval = 5
  private var reports: [UUID: (fractionLost: Double, uptime: TimeInterval)] = [:]

  /// Trả false khi báo cáo bị bỏ qua (client loopback: relay FFmpeg cục bộ
  /// không phản ánh chất lượng mạng Wi-Fi).
  @discardableResult
  mutating func record(
    client: UUID,
    isLoopback: Bool,
    fractionLost: Double,
    now: TimeInterval
  ) -> Bool {
    guard !isLoopback else { return false }
    reports[client] = (fractionLost: min(1, max(0, fractionLost)), uptime: now)
    return true
  }

  mutating func remove(client: UUID) {
    reports.removeValue(forKey: client)
  }

  /// Trung vị fraction lost của các client trong [activeClients] (client mạng
  /// đang PLAY) có báo cáo còn hạn. Khi số client chẵn lấy giá trị giữa thấp
  /// hơn: với hai tablet, một máy mạng yếu không đủ để hạ bitrate chung.
  mutating func medianFractionLost(
    activeClients: Set<UUID>,
    now: TimeInterval
  ) -> Double? {
    reports = reports.filter {
      activeClients.contains($0.key) && now - $0.value.uptime <= Self.reportLifetime
    }
    let values = reports.values.map { $0.fractionLost }.sorted()
    guard !values.isEmpty else { return nil }
    return values[(values.count - 1) / 2]
  }
}

/// C6: chính sách thử bind lại cổng RTSP overlay khi listener lỗi lúc khởi
/// động (EADDRINUSE: phiên vừa dừng chưa nhả hẳn cổng). Thuần để kiểm thử.
enum VnvarListenerBindRetryPolicy {
  /// Số lần thử lại tối đa (không tính lần đầu).
  static let maximumRetries = 5
  static let retryDelay: TimeInterval = 0.3
  /// Không bắt đầu lần thử mới khi đã quá chừng này giây kể từ lần đầu (Dart
  /// chờ `startOverlayRtsp` 8 s; còn phải chờ encoder ra SPS/PPS).
  static let retryWindow: TimeInterval = 5.0

  /// [failedAttempt]: số thứ tự lần thử vừa lỗi (1 = lần đầu).
  /// [elapsed]: số giây kể từ lần thử đầu.
  static func shouldRetry(failedAttempt: Int, elapsed: TimeInterval) -> Bool {
    guard failedAttempt >= 1, failedAttempt <= maximumRetries else { return false }
    guard elapsed.isFinite, elapsed >= 0 else { return false }
    return elapsed + retryDelay < retryWindow
  }
}

final class VnvarRtspServer {
  var onPlayRequested: (() -> Void)?
  var onReceiverReport: ((Double) -> Void)?
  var onPictureLossIndication: (() -> Void)?
  var onError: ((String) -> Void)?
  var onReady: (() -> Void)?

  private let queue = DispatchQueue(label: "vnvar.rtsp.server")
  private let queueKey = DispatchSpecificKey<Void>()
  private let port: Int
  // Luồng RTSP overlay (bảng tỉ số) chỉ phục vụ FFmpeg cục bộ: bind 127.0.0.1
  // và từ chối mọi kết nối không phải loopback.
  let loopbackOnly: Bool
  private var listener: NWListener?
  private var sessions: [UUID: ClientSession] = [:]
  private var sps: Data?
  private var pps: Data?
  private var audioAvailable = false
  // Tablet (client RTSP qua mạng) có nhận tiếng không; relay livestream cục bộ
  // (loopback) luôn nhận tiếng.
  private var remoteAudioEnabled = false
  private let maximumClients = 4
  // Relay livestream cục bộ (FFmpeg qua 127.0.0.1) có hạn mức riêng: client
  // mạng LAN treo không được chiếm hết chỗ khiến livestream không mở lại được.
  private let maximumLoopbackClients = 2
  // Client chưa PLAY (hoặc đang PAUSE) mà im lặng quá lâu thường là kết nối
  // half-open (tablet mất Wi-Fi): thu hồi để không giữ chỗ mãi.
  private let idleSessionTimeout: TimeInterval = 60
  // Phiên đã SETUP mà không PLAY (client bỏ dở, trình dò cổng) chỉ được giữ
  // chỗ chừng này; reaper chạy mỗi 5 s nên bị thu hồi sau ~10–15 s.
  private let unplayedSetupTimeout: TimeInterval = 10
  private var idleReaper: DispatchSourceTimer?
  // Bản sao có khoá của trạng thái phát, chỉ cập nhật trên `queue`. Luồng capture
  // WebRTC đọc nó mỗi khung: không được queue.sync sang hàng đợi đang
  // packetize/gửi (làm nghẽn capture và giảm FPS ghi).
  private let playingStateLock = NSLock()
  private var cachedHasPlayingClients = false
  private var cachedHasPlayingAudioClients = false
  private var lossTracker = VnvarRtcpLossTracker()

  init(port: Int, loopbackOnly: Bool = false) {
    self.port = port
    self.loopbackOnly = loopbackOnly
    queue.setSpecific(key: queueKey, value: ())
  }

  func start() throws {
    guard listener == nil else { return }
    guard (1...65_535).contains(port),
          let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
      throw ServerError.invalidPort
    }
    let parameters = NWParameters.tcp
    // Do not enable SO_REUSEPORT-style binding here. During a camera/profile
    // restart iOS may keep the previous nexus flow alive briefly; endpoint
    // reuse then makes the new listener fail with errno 17 (File exists) and
    // every viewer sees Connection refused. A single exclusive listener is
    // safer and the Dart retry path handles the short handoff window. The
    // loopback overlay server (C6) is re-bound by AppDelegate.startOverlayRtsp
    // (VnvarListenerBindRetryPolicy) when the listener fails during startup.
    let listener: NWListener
    if loopbackOnly {
      // Cổng nằm trong requiredLocalEndpoint; không truyền thêm `on:` để hai
      // nguồn cổng không xung đột (giống VnvarCellularUplink).
      parameters.requiredLocalEndpoint = .hostPort(
        host: .ipv4(.loopback),
        port: endpointPort
      )
      listener = try NWListener(using: parameters)
    } else {
      listener = try NWListener(using: parameters, on: endpointPort)
    }
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in
      guard let self = self else { return }
      switch state {
      case .ready:
        self.onReady?()
      case let .failed(error):
        self.onError?("RTSP listener failed: \(error)")
        self.stopLocked()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      // NWListener invokes this handler on its own queue. Keep acceptance on
      // that queue; dispatching back onto the same serial queue creates a
      // short window where a connection can be cancelled before it is started.
      self?.accept(connection)
    }
    // Tạo timer trước khi listener chạy: nếu listener lỗi ngay, stopLocked()
    // (chạy trên queue) chắc chắn thấy và huỷ được nó.
    startIdleReaper()
    listener.start(queue: queue)
  }

  private func startIdleReaper() {
    idleReaper?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 5, repeating: 5)
    timer.setEventHandler { [weak self] in self?.reapIdleSessions() }
    idleReaper = timer
    timer.resume()
  }

  /// Chạy trên `queue`. Đóng các phiên không phát (chưa PLAY/đang PAUSE) đã im
  /// lặng quá `idleSessionTimeout`, và các phiên đã SETUP nhưng chưa từng PLAY
  /// quá `unplayedSetupTimeout`.
  private func reapIdleSessions() {
    let now = ProcessInfo.processInfo.systemUptime
    let idle = sessions.values.filter { session in
      guard !session.playing else { return false }
      if now - session.lastActivityUptime > idleSessionTimeout { return true }
      if !session.hasPlayed,
         let setupUptime = session.setupUptime,
         now - setupUptime > unplayedSetupTimeout {
        return true
      }
      return false
    }
    for session in idle {
      NSLog("[VNVAR-RTSP] Closing idle RTSP session")
      close(session)
    }
  }

  func stop() {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      stopLocked()
    } else {
      queue.sync { stopLocked() }
    }
  }

  func updateFormat(sps: Data, pps: Data) {
    queue.async { [weak self] in
      self?.sps = sps
      self?.pps = pps
    }
  }

  func setAudioAvailable(_ available: Bool) {
    queue.async { [weak self] in self?.audioAvailable = available }
  }

  func setRemoteAudioEnabled(_ enabled: Bool) {
    queue.async { [weak self] in self?.remoteAudioEnabled = enabled }
  }

  private func offersAudio(to session: ClientSession) -> Bool {
    audioAvailable && (session.isLoopback || remoteAudioEnabled)
  }

  func sendAccessUnit(
    nals: [Data],
    timestamp: UInt32,
    isKeyFrame: Bool
  ) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let playing = self.sessions.values.filter(\.playing)
      guard !playing.isEmpty else { return }
      var recoveryNals = nals
      if isKeyFrame {
        // A tablet returning from CheckVAR creates a fresh decoder. Supplying
        // SPS/PPS only in DESCRIBE is not sufficient for every Android player;
        // send them in-band with each IDR so the live view can recover without
        // restarting the iPhone camera or the RTSP connection.
        let nalTypes = Set(nals.compactMap { $0.first.map { $0 & 0x1F } })
        if !nalTypes.contains(8), let pps = self.pps {
          recoveryNals.insert(pps, at: 0)
        }
        if !nalTypes.contains(7), let sps = self.sps {
          recoveryNals.insert(sps, at: 0)
        }
      }
      var shouldRequestKeyFrame = false
      for session in playing {
        if session.send(
          nals: recoveryNals,
          timestamp: timestamp,
          isKeyFrame: isKeyFrame
        ) {
          shouldRequestKeyFrame = true
        }
      }
      if shouldRequestKeyFrame {
        self.onPlayRequested?()
      }
    }
  }

  func sendAudio(pcm: Data, timestamp: UInt32) {
    queue.async { [weak self] in
      guard let self = self, self.audioAvailable else { return }
      for session in self.sessions.values
      where session.playing && session.audioConfigured {
        session.sendAudio(pcm: pcm, timestamp: timestamp)
      }
    }
  }

  /// An toàn gọi từ mọi luồng; không chặn chờ `queue`.
  var hasPlayingClients: Bool {
    playingStateLock.lock()
    defer { playingStateLock.unlock() }
    return cachedHasPlayingClients
  }

  /// An toàn gọi từ mọi luồng; không chặn chờ `queue`.
  var hasPlayingAudioClients: Bool {
    playingStateLock.lock()
    defer { playingStateLock.unlock() }
    return cachedHasPlayingAudioClients
  }

  /// Chạy trên `queue` sau mọi thay đổi `sessions` / `playing` / `audioConfigured`.
  private func refreshPlayingState() {
    let playing = sessions.values.contains(where: \.playing)
    let playingAudio = sessions.values.contains { $0.playing && $0.audioConfigured }
    playingStateLock.lock()
    cachedHasPlayingClients = playing
    cachedHasPlayingAudioClients = playingAudio
    playingStateLock.unlock()
  }

  /// Quyết định nhận kết nối theo chế độ server. Thuần, để kiểm thử.
  static func allowsConnection(from endpoint: NWEndpoint, loopbackOnly: Bool) -> Bool {
    !loopbackOnly || isLoopbackEndpoint(endpoint)
  }

  static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
    ClientSession.isLoopbackEndpoint(endpoint)
  }

  private func accept(_ connection: NWConnection) {
    // Phòng thủ thêm khi bind loopback không có hiệu lực trên một bản iOS nào đó.
    guard Self.allowsConnection(from: connection.endpoint, loopbackOnly: loopbackOnly) else {
      NSLog("[VNVAR-RTSP] Rejecting non-loopback client on loopback-only server")
      connection.cancel()
      return
    }
    let loopback = ClientSession.isLoopbackEndpoint(connection.endpoint)
    func countFull() -> Bool {
      let sameKind = sessions.values.filter { $0.isLoopback == loopback }.count
      return sameKind >= (loopback ? maximumLoopbackClients : maximumClients)
    }
    if countFull() {
      // Thử thu hồi phiên treo trước khi từ chối client mới.
      reapIdleSessions()
    }
    guard !countFull() else {
      if loopback {
        NSLog("[VNVAR-RTSP] Rejecting loopback client: limit reached")
      } else {
        NSLog("[VNVAR-RTSP] Rejecting network client: limit reached")
      }
      connection.cancel()
      return
    }
    let session = ClientSession(connection: connection, queue: queue)
    sessions[session.id] = session
    connection.stateUpdateHandler = { [weak self, weak session] state in
      guard let self = self, let session = session else { return }
      switch state {
      case .ready:
        self.receive(session)
      case .failed, .cancelled:
        // Network.framework already owns teardown in these terminal states.
        // Cancelling again causes redundant endpoint inspection on a socket
        // that never reached .ready (the copy_connected_* console warnings).
        session.markConnectionTerminal()
        self.detach(session)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receive(_ session: ClientSession) {
    session.connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1024
    ) { [weak self, weak session] data, _, isComplete, error in
      guard let self = self, let session = session else { return }
      self.queue.async {
        if let data = data, !data.isEmpty {
          session.lastActivityUptime = ProcessInfo.processInfo.systemUptime
          session.input.append(data)
          guard session.input.count <= ClientSession.maximumInputBytes else {
            self.close(session)
            return
          }
          self.processInput(session)
        }
        if error != nil {
          session.markConnectionTerminal()
          self.detach(session)
        } else if isComplete {
          self.close(session)
        } else {
          self.receive(session)
        }
      }
    }
  }

  private func processInput(_ session: ClientSession) {
    while !session.input.isEmpty {
      if session.input.first == 0x24 {
        guard session.input.count >= 4 else { return }
        let start = session.input.startIndex
        let channel = session.input[session.input.index(start, offsetBy: 1)]
        let lengthHigh = session.input[session.input.index(start, offsetBy: 2)]
        let lengthLow = session.input[session.input.index(start, offsetBy: 3)]
        let length = (Int(lengthHigh) << 8) | Int(lengthLow)
        guard session.input.count >= 4 + length else { return }
        let payloadStart = session.input.index(start, offsetBy: 4)
        let payloadEnd = session.input.index(payloadStart, offsetBy: length)
        let payload = session.input.subdata(in: payloadStart..<payloadEnd)
        session.input.removeSubrange(start..<payloadEnd)
        processInterleaved(payload, channel: channel, session: session)
        continue
      }
      let delimiter = Data([13, 10, 13, 10])
      guard let headerRange = session.input.range(of: delimiter) else { return }
      let headerEnd = headerRange.upperBound
      let headerData = session.input.subdata(in: session.input.startIndex..<headerEnd)
      guard let text = String(data: headerData, encoding: .isoLatin1) else {
        close(session)
        return
      }
      let contentLength = headerValue("content-length", in: text)
        .flatMap(Int.init) ?? 0
      guard contentLength >= 0,
            contentLength <= ClientSession.maximumBodyBytes else {
        close(session)
        return
      }
      guard contentLength <= session.input.distance(
        from: headerEnd,
        to: session.input.endIndex
      ) else { return }
      let bodyEnd = session.input.index(headerEnd, offsetBy: contentLength)
      session.input.removeSubrange(session.input.startIndex..<bodyEnd)
      handle(text, session: session)
    }
  }

  private func processInterleaved(
    _ payload: Data,
    channel: UInt8,
    session: ClientSession
  ) {
    guard session.videoConfigured,
          channel == (session.videoRtpChannel &+ 1),
          let feedback = VnvarRtcpFeedback.parse(payload) else { return }
    if feedback.requestsKeyFrame {
      onPictureLossIndication?()
    }
    if let fractionLost = feedback.fractionLost {
      let now = ProcessInfo.processInfo.systemUptime
      // RR của relay FFmpeg loopback không phản ánh mạng tới tablet: bỏ qua.
      guard lossTracker.record(
        client: session.id,
        isLoopback: session.isLoopback,
        fractionLost: fractionLost,
        now: now
      ) else { return }
      let activeClients = Set(
        sessions.values.filter { $0.playing && !$0.isLoopback }.map(\.id)
      )
      if let median = lossTracker.medianFractionLost(
        activeClients: activeClients,
        now: now
      ) {
        onReceiverReport?(median)
      }
    }
  }

  private func handle(_ request: String, session: ClientSession) {
    let lines = request.components(separatedBy: "\r\n")
    let requestLine = lines.first ?? ""
    let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
    let cseq = headerValue("cseq", in: request) ?? "0"
    // Mọi nhánh có thể đổi playing/audioConfigured: cập nhật bản sao có khoá.
    defer { refreshPlayingState() }
    switch method.uppercased() {
    case "OPTIONS":
      session.respond(
        cseq: cseq,
        headers: "Public: OPTIONS, DESCRIBE, SETUP, PLAY, PAUSE, GET_PARAMETER, TEARDOWN\r\n"
      )
    case "DESCRIBE":
      describe(cseq: cseq, session: session)
    case "SETUP":
      setup(
        cseq: cseq,
        requestLine: requestLine,
        transport: headerValue("transport", in: request) ?? "",
        session: session
      )
    case "PLAY":
      guard session.videoConfigured else {
        session.sendText(
          "RTSP/1.0 455 Method Not Valid in This State\r\nCSeq: \(cseq)\r\n\r\n"
        )
        return
      }
      var rtpInfo = "url=track0"
      if audioAvailable && session.audioConfigured {
        rtpInfo += ",url=track1"
      }
      session.respond(
        cseq: cseq,
        headers: "Session: \(session.sessionId)\r\nRTP-Info: \(rtpInfo)\r\n"
      )
      session.beginPlaying()
      onPlayRequested?()
    case "PAUSE":
      session.playing = false
      session.respond(cseq: cseq, headers: "Session: \(session.sessionId)\r\n")
    case "GET_PARAMETER":
      session.respond(cseq: cseq, headers: "Session: \(session.sessionId)\r\n")
    case "TEARDOWN":
      session.playing = false
      session.respond(cseq: cseq, headers: "Session: \(session.sessionId)\r\n")
      close(session)
    default:
      session.sendText("RTSP/1.0 405 Method Not Allowed\r\nCSeq: \(cseq)\r\n\r\n")
    }
  }

  private func describe(cseq: String, session: ClientSession) {
    guard let sps = sps, let pps = pps else {
      session.sendText(
        "RTSP/1.0 503 Service Unavailable\r\n" +
          "CSeq: \(cseq)\r\nRetry-After: 1\r\n\r\n"
      )
      return
    }
    let profile = sps.count >= 4
      ? String(format: "%02X%02X%02X", sps[1], sps[2], sps[3])
      : "42E01F"
    let sdp =
      "v=0\r\n" +
      "o=- 0 0 IN IP4 0.0.0.0\r\n" +
      "s=VNVAR Camera\r\n" +
      "c=IN IP4 0.0.0.0\r\n" +
      "t=0 0\r\n" +
      "a=control:*\r\n" +
      "m=video 0 RTP/AVP 96\r\n" +
      "a=rtpmap:96 H264/90000\r\n" +
      "a=fmtp:96 packetization-mode=1;profile-level-id=\(profile);" +
      "sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())\r\n" +
      "a=control:track0\r\n" +
      (offersAudio(to: session)
        ? "m=audio 0 RTP/AVP 97\r\n" +
          "a=rtpmap:97 L16/48000/1\r\n" +
          "a=control:track1\r\n"
        : "")
    let length = sdp.data(using: .utf8)?.count ?? 0
    session.sendText(
      "RTSP/1.0 200 OK\r\n" +
        "CSeq: \(cseq)\r\n" +
        "Content-Type: application/sdp\r\n" +
        "Content-Length: \(length)\r\n\r\n" +
        sdp
    )
  }

  private func setup(
    cseq: String,
    requestLine: String,
    transport: String,
    session: ClientSession
  ) {
    guard transport.localizedCaseInsensitiveContains("TCP") ||
            transport.localizedCaseInsensitiveContains("interleaved") else {
      session.sendText(
        "RTSP/1.0 461 Unsupported Transport\r\nCSeq: \(cseq)\r\n\r\n"
      )
      return
    }
    let isAudio = requestLine.localizedCaseInsensitiveContains("track1")
    if isAudio && !offersAudio(to: session) {
      session.sendText("RTSP/1.0 404 Not Found\r\nCSeq: \(cseq)\r\n\r\n")
      return
    }
    var channel: UInt8 = isAudio ? 2 : 0
    if let range = transport.range(
      of: #"interleaved=(\d+)"#,
      options: .regularExpression
    ) {
      let value = transport[range]
        .split(separator: "=")
        .last
        .flatMap { UInt8($0) }
      channel = min(value ?? channel, 254)
    }
    if session.setupUptime == nil {
      session.setupUptime = ProcessInfo.processInfo.systemUptime
    }
    if isAudio {
      session.audioRtpChannel = channel
      session.audioConfigured = true
    } else {
      session.videoRtpChannel = channel
      session.videoConfigured = true
    }
    session.respond(
      cseq: cseq,
      headers: "Session: \(session.sessionId)\r\n" +
        "Transport: RTP/AVP/TCP;unicast;interleaved=" +
        "\(channel)-\(channel + 1)\r\n"
    )
  }

  private func headerValue(_ name: String, in request: String) -> String? {
    let prefix = name.lowercased() + ":"
    for line in request.components(separatedBy: "\r\n").dropFirst() {
      if line.lowercased().hasPrefix(prefix) {
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  private func detach(_ session: ClientSession) {
    sessions.removeValue(forKey: session.id)
    session.connection.stateUpdateHandler = nil
    lossTracker.remove(client: session.id)
    refreshPlayingState()
  }

  private func close(_ session: ClientSession) {
    detach(session)
    session.cancelIfNeeded()
  }

  private func stopLocked() {
    idleReaper?.cancel()
    idleReaper = nil
    listener?.cancel()
    listener = nil
    sessions.values.forEach { session in
      session.connection.stateUpdateHandler = nil
      session.cancelIfNeeded()
    }
    sessions.removeAll()
    lossTracker = VnvarRtcpLossTracker()
    refreshPlayingState()
  }

  private enum ServerError: Error {
    case invalidPort
  }

  private final class ClientSession {
    static let maximumInputBytes = 256 * 1_024
    static let maximumBodyBytes = 64 * 1_024
    let id = UUID()
    let sessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let connection: NWConnection
    let queue: DispatchQueue
    var input = Data()
    var playing = false
    var videoRtpChannel: UInt8 = 0
    var audioRtpChannel: UInt8 = 2
    var videoConfigured = false
    var audioConfigured = false
    var videoSequence = UInt16.random(in: UInt16.min...UInt16.max)
    var audioSequence = UInt16.random(in: UInt16.min...UInt16.max)
    var pendingSends = 0
    var lastActivityUptime = ProcessInfo.processInfo.systemUptime
    // Thời điểm SETUP đầu tiên; dùng để thu hồi phiên SETUP mà không PLAY.
    var setupUptime: TimeInterval?
    private(set) var hasPlayed = false
    // A new client, or one whose network queue overflowed, must start again at
    // an IDR frame. Sending dependent P-frames after dropping an access unit
    // produces green/yellow macroblocks until the next keyframe.
    private var recoveryGate = VnvarVideoRecoveryGate()
    // Relay livestream cục bộ (FFmpeg qua 127.0.0.1) chỉ ngừng đọc khi upload
    // RTMP khựng: cho hàng chờ dài hơn và không đóng nó sau 2 giây, nếu không
    // livestream phải khởi động lại và mất tiếng.
    let isLoopback: Bool
    private let maximumPendingSends: Int
    private let sendStallTimeout: TimeInterval
    private var sendProgressUptime: TimeInterval = 0
    private var stallCheckGeneration = 0
    private var connectionTerminal = false
    private var videoPacketCount: UInt32 = 0
    private var videoOctetCount: UInt32 = 0
    private var lastSenderReportUptime: TimeInterval = 0
    private var audioPacketCount: UInt32 = 0
    private var audioOctetCount: UInt32 = 0
    private var lastAudioSenderReportUptime: TimeInterval = 0

    init(connection: NWConnection, queue: DispatchQueue) {
      self.connection = connection
      self.queue = queue
      let loopback = ClientSession.isLoopbackEndpoint(connection.endpoint)
      isLoopback = loopback
      maximumPendingSends = loopback ? 4_096 : 384
      sendStallTimeout = loopback ? 10 : 2
    }

    fileprivate static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
      guard case let .hostPort(host, _) = endpoint else { return false }
      switch host {
      case let .ipv4(address):
        return address == IPv4Address.loopback
      case let .ipv6(address):
        return address == IPv6Address.loopback
      case let .name(name, _):
        return name == "localhost"
      @unknown default:
        return false
      }
    }

    func respond(cseq: String, headers: String) {
      sendText("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\(headers)\r\n")
    }

    func sendText(_ value: String) {
      guard !connectionTerminal else { return }
      guard let data = value.data(using: .isoLatin1) else { return }
      connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func beginPlaying() {
      recoveryGate.beginPlaying()
      playing = true
      hasPlayed = true
    }

    /// Returns true when the encoder should be asked for a fresh keyframe.
    func send(
      nals: [Data],
      timestamp: UInt32,
      isKeyFrame: Bool
    ) -> Bool {
      // A slow RTSP reader must not create an unbounded Network.framework queue.
      // Build payloads first. Sequence numbers are assigned only after the
      // complete access unit has passed admission, so a locally dropped frame
      // does not look like RTP packet loss to the receiver.
      var payloads: [(data: Data, marker: Bool)] = []
      for (nalIndex, nal) in nals.enumerated() {
        let nalPayloads = VnvarRtpPacketizer.payloads(for: nal)
        for (payloadIndex, payload) in nalPayloads.enumerated() {
          payloads.append((
            data: payload,
            marker: nalIndex == nals.count - 1 &&
              payloadIndex == nalPayloads.count - 1
          ))
        }
      }
      guard !payloads.isEmpty else { return false }
      guard recoveryGate.shouldSend(isKeyFrame: isKeyFrame) else {
        return false
      }
      guard pendingSends == 0 ||
              pendingSends + payloads.count <= maximumPendingSends else {
        NSLog(
          "[VNVAR-RTSP] Client %@ congested: pending=%d incoming=%d; waiting for IDR",
          String(sessionId),
          pendingSends,
          payloads.count
        )
        return recoveryGate.didDrop(isKeyFrame: isKeyFrame)
      }

      for payload in payloads {
        let packet = VnvarRtpPacketizer.packet(
          payload: payload.data,
          sequence: videoSequence,
          timestamp: timestamp,
          marker: payload.marker
        )
        videoSequence &+= 1
        videoPacketCount &+= 1
        videoOctetCount &+= UInt32(truncatingIfNeeded: payload.data.count)
        sendInterleaved(packet, channel: videoRtpChannel, admitted: true)
      }
      sendVideoSenderReportIfDue(rtpTimestamp: timestamp)
      return false
    }

    private func sendVideoSenderReportIfDue(rtpTimestamp: UInt32) {
      let now = ProcessInfo.processInfo.systemUptime
      guard now - lastSenderReportUptime >= 2 else { return }
      lastSenderReportUptime = now
      let report = VnvarRtpPacketizer.senderReport(
        ntpTimestamp: VnvarRtpPacketizer.currentNtpTimestamp(),
        rtpTimestamp: rtpTimestamp,
        packetCount: videoPacketCount,
        octetCount: videoOctetCount
      )
      sendInterleaved(report, channel: videoRtpChannel &+ 1)
    }

    func sendAudio(pcm: Data, timestamp: UInt32) {
      guard audioConfigured, !pcm.isEmpty else { return }
      let maximum = VnvarRtpPacketizer.maxPayloadBytes & ~1
      var offset = 0
      while offset < pcm.count {
        let size = min(maximum, pcm.count - offset) & ~1
        guard size > 0 else { break }
        let packet = VnvarRtpPacketizer.audioPacket(
          payload: pcm.subdata(in: offset..<(offset + size)),
          sequence: audioSequence,
          timestamp: timestamp &+ UInt32(offset / 2)
        )
        if sendInterleaved(packet, channel: audioRtpChannel) {
          audioSequence &+= 1
          audioPacketCount &+= 1
          audioOctetCount &+= UInt32(truncatingIfNeeded: size)
        }
        offset += size
      }
      sendAudioSenderReportIfDue(
        rtpTimestamp: timestamp &+ UInt32(truncatingIfNeeded: pcm.count / 2)
      )
    }

    /// Sender Report cho audio cùng đồng hồ NTP với video, để FFmpeg và trình
    /// phát ghép hình–tiếng đúng thời điểm.
    private func sendAudioSenderReportIfDue(rtpTimestamp: UInt32) {
      let now = ProcessInfo.processInfo.systemUptime
      guard now - lastAudioSenderReportUptime >= 2 else { return }
      lastAudioSenderReportUptime = now
      let report = VnvarRtpPacketizer.senderReport(
        ssrc: 0x564E4155,
        ntpTimestamp: VnvarRtpPacketizer.currentNtpTimestamp(),
        rtpTimestamp: rtpTimestamp,
        packetCount: audioPacketCount,
        octetCount: audioOctetCount
      )
      sendInterleaved(report, channel: audioRtpChannel &+ 1)
    }

    @discardableResult
    private func sendInterleaved(
      _ packet: Data,
      channel: UInt8,
      admitted: Bool = false
    ) -> Bool {
      guard !connectionTerminal,
            admitted || pendingSends < maximumPendingSends else { return false }
      var interleaved = Data(capacity: packet.count + 4)
      interleaved.append(0x24)
      interleaved.append(channel)
      interleaved.append(UInt8((packet.count >> 8) & 0xFF))
      interleaved.append(UInt8(packet.count & 0xFF))
      interleaved.append(packet)
      let wasIdle = pendingSends == 0
      pendingSends += 1
      if wasIdle {
        sendProgressUptime = ProcessInfo.processInfo.systemUptime
        scheduleStallCheck()
      }
      connection.send(
        content: interleaved,
        completion: .contentProcessed { [weak self] error in
          guard let self = self else { return }
          self.queue.async {
            self.pendingSends = max(0, self.pendingSends - 1)
            self.sendProgressUptime = ProcessInfo.processInfo.systemUptime
            if error != nil {
              self.cancelIfNeeded()
            } else if self.pendingSends == 0 {
              self.stallCheckGeneration &+= 1
            }
          }
        }
      )
      return true
    }

    private func scheduleStallCheck() {
      stallCheckGeneration &+= 1
      let generation = stallCheckGeneration
      queue.asyncAfter(deadline: .now() + sendStallTimeout) { [weak self] in
        self?.checkForSendStall(generation: generation)
      }
    }

    private func checkForSendStall(generation: Int) {
      guard generation == stallCheckGeneration, pendingSends > 0 else { return }
      let elapsed = ProcessInfo.processInfo.systemUptime - sendProgressUptime
      if elapsed >= sendStallTimeout {
        NSLog(
          "[VNVAR-RTSP] Closing stalled client %@ after %.2f seconds",
          String(sessionId),
          elapsed
        )
        cancelIfNeeded()
        return
      }
      queue.asyncAfter(
        deadline: .now() + max(0.01, sendStallTimeout - elapsed)
      ) { [weak self] in
        self?.checkForSendStall(generation: generation)
      }
    }

    func markConnectionTerminal() {
      connectionTerminal = true
      stallCheckGeneration &+= 1
    }

    func cancelIfNeeded() {
      guard !connectionTerminal else { return }
      connectionTerminal = true
      stallCheckGeneration &+= 1
      connection.cancel()
    }
  }
}
