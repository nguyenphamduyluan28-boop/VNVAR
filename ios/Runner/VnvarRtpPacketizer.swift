import Foundation

enum VnvarRtpPacketizer {
  static let payloadType: UInt8 = 96
  static let clockRate: UInt64 = 90_000
  static let maxPayloadBytes = 1_200

  static func payloads(for nal: Data) -> [Data] {
    guard !nal.isEmpty else { return [] }
    if nal.count <= maxPayloadBytes { return [nal] }

    let nalHeader = nal[nal.startIndex]
    let fuIndicator = (nalHeader & 0xE0) | 28
    let nalType = nalHeader & 0x1F
    let body = nal.dropFirst()
    let fragmentSize = maxPayloadBytes - 2
    var result: [Data] = []
    var offset = 0
    while offset < body.count {
      let size = min(fragmentSize, body.count - offset)
      let isFirst = offset == 0
      let isLast = offset + size == body.count
      var fragment = Data(capacity: size + 2)
      fragment.append(fuIndicator)
      fragment.append(
        nalType | (isFirst ? 0x80 : 0) | (isLast ? 0x40 : 0)
      )
      let start = body.index(body.startIndex, offsetBy: offset)
      let end = body.index(start, offsetBy: size)
      fragment.append(contentsOf: body[start..<end])
      result.append(fragment)
      offset += size
    }
    return result
  }

  static func packet(
    payload: Data,
    sequence: UInt16,
    timestamp: UInt32,
    marker: Bool,
    ssrc: UInt32 = 0x564E5652
  ) -> Data {
    var packet = Data(capacity: 12 + payload.count)
    packet.append(0x80)
    packet.append(payloadType | (marker ? 0x80 : 0))
    appendUInt16(sequence, to: &packet)
    appendUInt32(timestamp, to: &packet)
    appendUInt32(ssrc, to: &packet)
    packet.append(payload)
    return packet
  }

  static func audioPacket(
    payload: Data,
    sequence: UInt16,
    timestamp: UInt32,
    payloadType: UInt8 = 97,
    ssrc: UInt32 = 0x564E4155
  ) -> Data {
    var packet = Data(capacity: 12 + payload.count)
    packet.append(0x80)
    packet.append(payloadType)
    appendUInt16(sequence, to: &packet)
    appendUInt32(timestamp, to: &packet)
    appendUInt32(ssrc, to: &packet)
    packet.append(payload)
    return packet
  }

  private static func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }

  private static func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }
}
