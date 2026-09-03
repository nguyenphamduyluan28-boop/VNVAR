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

final class VnvarRtspServer {
  var onPlayRequested: (() -> Void)?
  var onError: ((String) -> Void)?
  var onReady: (() -> Void)?

  private let queue = DispatchQueue(label: "vnvar.rtsp.server")
  private let port: Int
  private var listener: NWListener?
  private var sessions: [UUID: ClientSession] = [:]
  private var sps: Data?
  private var pps: Data?
  private var audioAvailable = false
  private let maximumClients = 4

  init(port: Int) {
    self.port = port
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
    // safer and the Dart retry path handles the short handoff window.
    let listener = try NWListener(using: parameters, on: endpointPort)
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
      self?.queue.async { self?.accept(connection) }
    }
    listener.start(queue: queue)
  }

  func stop() {
    queue.sync { stopLocked() }
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

  func sendAccessUnit(
    nals: [Data],
    timestamp: UInt32,
    isKeyFrame: Bool
  ) {
    queue.async { [weak self] in
      guard let self = self else { return }
      let playing = self.sessions.values.filter(\.playing)
      guard !playing.isEmpty else { return }
      var shouldRequestKeyFrame = false
      for session in playing {
        if session.send(
          nals: nals,
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
      for session in self.sessions.values where session.playing {
        session.sendAudio(pcm: pcm, timestamp: timestamp)
      }
    }
  }

  var hasPlayingClients: Bool {
    queue.sync { sessions.values.contains(where: \.playing) }
  }

  var hasPlayingAudioClients: Bool {
    queue.sync {
      sessions.values.contains { $0.playing && $0.audioConfigured }
    }
  }

  private func accept(_ connection: NWConnection) {
    guard sessions.count < maximumClients else {
      NSLog("[VNVAR-RTSP] Rejecting client: limit %d reached", maximumClients)
      connection.cancel()
      return
    }
    let session = ClientSession(connection: connection, queue: queue)
    sessions[session.id] = session
    connection.stateUpdateHandler = { [weak self, weak session] state in
      guard let self = self, let session = session else { return }
      if case .failed = state { self.remove(session) }
      if case .cancelled = state { self.remove(session) }
    }
    connection.start(queue: queue)
    receive(session)
  }

  private func receive(_ session: ClientSession) {
    session.connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1024
    ) { [weak self, weak session] data, _, isComplete, error in
      guard let self = self, let session = session else { return }
      self.queue.async {
        if let data = data, !data.isEmpty {
          session.input.append(data)
          guard session.input.count <= ClientSession.maximumInputBytes else {
            self.remove(session)
            return
          }
          self.processInput(session)
        }
        if isComplete || error != nil {
          self.remove(session)
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
        let length = (Int(session.input[2]) << 8) | Int(session.input[3])
        guard session.input.count >= 4 + length else { return }
        session.input.removeFirst(4 + length)
        continue
      }
      let delimiter = Data([13, 10, 13, 10])
      guard let headerRange = session.input.range(of: delimiter) else { return }
      let headerEnd = headerRange.upperBound
      let headerData = session.input.subdata(in: 0..<headerEnd)
      guard let text = String(data: headerData, encoding: .isoLatin1) else {
        session.connection.cancel()
        return
      }
      let contentLength = headerValue("content-length", in: text)
        .flatMap(Int.init) ?? 0
      guard contentLength >= 0,
            contentLength <= ClientSession.maximumBodyBytes else {
        session.connection.cancel()
        return
      }
      guard session.input.count >= headerEnd + contentLength else { return }
      session.input.removeFirst(headerEnd + contentLength)
      handle(text, session: session)
    }
  }

  private func handle(_ request: String, session: ClientSession) {
    let lines = request.components(separatedBy: "\r\n")
    let requestLine = lines.first ?? ""
    let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
    let cseq = headerValue("cseq", in: request) ?? "0"
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
      session.connection.cancel()
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
      "t=0 0\r\n" +
      "a=control:*\r\n" +
      "m=video 0 RTP/AVP 96\r\n" +
      "a=rtpmap:96 H264/90000\r\n" +
      "a=fmtp:96 packetization-mode=1;profile-level-id=\(profile);" +
      "sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())\r\n" +
      "a=control:track0\r\n" +
      (audioAvailable
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
    if isAudio && !audioAvailable {
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

  private func remove(_ session: ClientSession) {
    sessions.removeValue(forKey: session.id)
    session.connection.cancel()
  }

  private func stopLocked() {
    listener?.cancel()
    listener = nil
    sessions.values.forEach { $0.connection.cancel() }
    sessions.removeAll()
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
    // A new client, or one whose network queue overflowed, must start again at
    // an IDR frame. Sending dependent P-frames after dropping an access unit
    // produces green/yellow macroblocks until the next keyframe.
    private var recoveryGate = VnvarVideoRecoveryGate()
    private let maximumPendingSends = 384
    private let sendStallTimeout: TimeInterval = 2
    private var sendProgressUptime: TimeInterval = 0
    private var stallCheckGeneration = 0

    init(connection: NWConnection, queue: DispatchQueue) {
      self.connection = connection
      self.queue = queue
    }

    func respond(cseq: String, headers: String) {
      sendText("RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\n\(headers)\r\n")
    }

    func sendText(_ value: String) {
      guard let data = value.data(using: .isoLatin1) else { return }
      connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func beginPlaying() {
      recoveryGate.beginPlaying()
      playing = true
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
        sendInterleaved(packet, channel: videoRtpChannel, admitted: true)
      }
      return false
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
        }
        offset += size
      }
    }

    @discardableResult
    private func sendInterleaved(
      _ packet: Data,
      channel: UInt8,
      admitted: Bool = false
    ) -> Bool {
      guard admitted || pendingSends < maximumPendingSends else { return false }
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
              self.connection.cancel()
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
        connection.cancel()
        return
      }
      queue.asyncAfter(
        deadline: .now() + max(0.01, sendStallTimeout - elapsed)
      ) { [weak self] in
        self?.checkForSendStall(generation: generation)
      }
    }
  }
}
