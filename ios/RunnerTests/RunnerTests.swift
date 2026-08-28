import Flutter
@testable import Runner
import UIKit
import XCTest

class RunnerTests: XCTestCase {
  func testEmptyNalDoesNotCreateRtpPayload() {
    XCTAssertTrue(VnvarRtpPacketizer.payloads(for: Data()).isEmpty)
  }

  func testSmallNalUsesSingleRtpPayload() {
    let nal = Data([0x65, 0x01, 0x02, 0x03])
    XCTAssertEqual(VnvarRtpPacketizer.payloads(for: nal), [nal])
  }

  func testLargeNalUsesFuAWithStartAndEndBits() throws {
    var nal = Data([0x65])
    nal.append(Data(repeating: 0xAB, count: 3_000))
    let payloads = VnvarRtpPacketizer.payloads(for: nal)
    XCTAssertGreaterThan(payloads.count, 1)
    let first = try XCTUnwrap(payloads.first)
    let last = try XCTUnwrap(payloads.last)
    XCTAssertEqual(first[0] & 0x1F, 28)
    XCTAssertEqual(first[1] & 0x80, 0x80)
    XCTAssertEqual(last[1] & 0x40, 0x40)
    XCTAssertEqual(first[1] & 0x1F, 5)
    XCTAssertEqual(last[1] & 0x1F, 5)
  }

  func testRtpHeaderContainsSequenceTimestampAndMarker() {
    let packet = VnvarRtpPacketizer.packet(
      payload: Data([1, 2, 3]),
      sequence: 0x1234,
      timestamp: 0x01020304,
      marker: true
    )
    XCTAssertEqual(
      Data(packet.prefix(8)),
      Data([0x80, 0xE0, 0x12, 0x34, 1, 2, 3, 4])
    )
    XCTAssertEqual(packet.count, 15)
  }

  func testL16AudioRtpHeaderUsesPayload97WithoutMarker() {
    let packet = VnvarRtpPacketizer.audioPacket(
      payload: Data([0x12, 0x34, 0xFE, 0xDC]),
      sequence: 0x4567,
      timestamp: 0x10203040
    )
    XCTAssertEqual(
      Data(packet.prefix(8)),
      Data([0x80, 0x61, 0x45, 0x67, 0x10, 0x20, 0x30, 0x40])
    )
    XCTAssertEqual(Data(packet.suffix(4)), Data([0x12, 0x34, 0xFE, 0xDC]))
  }
}
