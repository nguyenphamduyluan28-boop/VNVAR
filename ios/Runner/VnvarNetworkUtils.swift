import Darwin
import Foundation
import Network

enum VnvarNetworkUtils {
  /// Địa chỉ LAN cho Tablet: Wi-Fi (`en0`) trước, rồi tới hotspot cá nhân của
  /// iPhone (`bridge100`, thường là 172.20.10.1). Không bao giờ trả IP của mạng
  /// di động (`pdp_ip*`).
  static func wifiIPv4Address() -> String? {
    for name in ["en0", "bridge100"] {
      if let address = ipv4Address(interfaceName: name) {
        return address
      }
    }
    return nil
  }

  private static func ipv4Address(interfaceName: String) -> String? {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let first = firstAddress else {
      return nil
    }
    defer { freeifaddrs(firstAddress) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor?.pointee {
      defer { cursor = interface.ifa_next }
      guard String(cString: interface.ifa_name) == interfaceName,
            let address = interface.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(address.pointee.sa_len)
      guard getnameinfo(
        address,
        length,
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
      ) == 0 else {
        continue
      }
      let value = String(cString: host)
      return value == "0.0.0.0" ? nil : value
    }
    return nil
  }
}

/// Đường 4G/5G dự phòng cho livestream khi mạng mặc định (thường là Wi-Fi
/// không có Internet) không đẩy được luồng.
///
/// FFmpeg đẩy vào 127.0.0.1:<cổng>; mỗi kết nối được nối tiếp tới server phát
/// bằng `NWConnection` với `requiredInterfaceType = .cellular`, nên Wi-Fi vẫn
/// phục vụ Tablet. Với RTMPS, TLS được mở ở đây tới đúng tên máy chủ (SNI +
/// kiểm tra chứng chỉ hệ thống).
final class VnvarCellularUplink {
  private let queue = DispatchQueue(label: "vnvar.cellular.uplink")
  private var listener: NWListener?
  private var targetHost: String?
  private var targetPort: Int?
  private var targetTls = false
  private var links: [ObjectIdentifier: (local: NWConnection, remote: NWConnection)] = [:]

  /// Gọi `completion` với cổng cục bộ, hoặc nil khi không có mạng di động.
  func open(host: String, port: Int, tls: Bool, completion: @escaping (Int?) -> Void) {
    queue.async {
      if let listener = self.listener,
         self.targetHost == host,
         self.targetPort == port,
         self.targetTls == tls,
         let localPort = listener.port {
        // FFmpeg chỉ mở lại khi phiên trước đã hỏng: đóng các kết nối cũ.
        self.closeLinksLocked()
        completion(Int(localPort.rawValue))
        return
      }
      self.closeLocked()
      self.checkCellularAvailable { available in
        guard available else {
          NSLog("[VNVAR-Cellular] Mobile data network is unavailable")
          completion(nil)
          return
        }
        self.startListener(host: host, port: port, tls: tls, completion: completion)
      }
    }
  }

  func close() {
    queue.async { self.closeLocked() }
  }

  private func closeLocked() {
    listener?.cancel()
    listener = nil
    targetHost = nil
    targetPort = nil
    closeLinksLocked()
  }

  private func closeLinksLocked() {
    for link in links.values {
      link.local.cancel()
      link.remote.cancel()
    }
    links.removeAll()
  }

  private func checkCellularAvailable(_ completion: @escaping (Bool) -> Void) {
    let monitor = NWPathMonitor(requiredInterfaceType: .cellular)
    var finished = false
    monitor.pathUpdateHandler = { path in
      guard !finished else { return }
      finished = true
      monitor.cancel()
      completion(path.status == .satisfied)
    }
    monitor.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 3) {
      guard !finished else { return }
      finished = true
      monitor.cancel()
      completion(false)
    }
  }

  private func startListener(
    host: String,
    port: Int,
    tls: Bool,
    completion: @escaping (Int?) -> Void
  ) {
    guard let remotePort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
      completion(nil)
      return
    }
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let newListener: NWListener
    do {
      newListener = try NWListener(using: parameters)
    } catch {
      NSLog("[VNVAR-Cellular] Cannot create local listener: %@", "\(error)")
      completion(nil)
      return
    }
    var reported = false
    newListener.stateUpdateHandler = { [weak self, weak newListener] state in
      switch state {
      case .ready:
        guard !reported else { return }
        reported = true
        let localPort = newListener?.port.map { Int($0.rawValue) }
        NSLog(
          "[VNVAR-Cellular] Uplink ready on 127.0.0.1:%ld -> %@:%ld tls=%ld",
          localPort ?? 0,
          host,
          port,
          tls ? 1 : 0
        )
        completion(localPort)
      case .failed:
        if !reported {
          reported = true
          completion(nil)
        }
        self?.closeLocked()
      default:
        break
      }
    }
    newListener.newConnectionHandler = { [weak self] local in
      self?.bridge(local: local, host: host, port: remotePort, tls: tls)
    }
    listener?.cancel()
    listener = newListener
    targetHost = host
    targetPort = port
    targetTls = tls
    newListener.start(queue: queue)
  }

  private func bridge(local: NWConnection, host: String, port: NWEndpoint.Port, tls: Bool) {
    let parameters = tls
      ? NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
      : NWParameters.tcp
    parameters.requiredInterfaceType = .cellular
    let remote = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
    let key = ObjectIdentifier(local)
    links[key] = (local, remote)
    let finish: () -> Void = { [weak self] in
      local.cancel()
      remote.cancel()
      self?.links.removeValue(forKey: key)
    }
    remote.stateUpdateHandler = { state in
      switch state {
      case .ready:
        self.pipe(from: local, to: remote, finish: finish)
        self.pipe(from: remote, to: local, finish: finish)
      case let .failed(error):
        NSLog("[VNVAR-Cellular] Link to %@ failed: %@", host, "\(error)")
        finish()
      case .waiting:
        // Không có đường 4G/5G: báo lỗi để FFmpeg kết nối lại thay vì chờ mãi.
        finish()
      default:
        break
      }
    }
    local.stateUpdateHandler = { state in
      if case .failed = state { finish() }
    }
    local.start(queue: queue)
    remote.start(queue: queue)
  }

  /// Chuyển dữ liệu một chiều; chỉ nhận tiếp khi lần gửi trước đã xong để
  /// không dồn bộ nhớ khi upload chậm.
  private func pipe(from source: NWConnection, to destination: NWConnection, finish: @escaping () -> Void) {
    source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      if let data = data, !data.isEmpty {
        destination.send(content: data, completion: .contentProcessed { sendError in
          if sendError != nil || isComplete || error != nil {
            finish()
            return
          }
          self?.pipe(from: source, to: destination, finish: finish)
        })
      } else if isComplete || error != nil {
        finish()
      } else {
        self?.pipe(from: source, to: destination, finish: finish)
      }
    }
  }
}
