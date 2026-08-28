import Darwin
import Foundation

enum VnvarNetworkUtils {
  static func wifiIPv4Address() -> String? {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let first = firstAddress else {
      return nil
    }
    defer { freeifaddrs(firstAddress) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor?.pointee {
      defer { cursor = interface.ifa_next }
      guard String(cString: interface.ifa_name) == "en0",
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
