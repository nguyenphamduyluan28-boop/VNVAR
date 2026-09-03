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

  func testFuAFragmentsReconstructOriginalNal() {
    var nal = Data([0x61])
    nal.append(Data((0..<5_000).map { UInt8($0 % 251) }))

    let payloads = VnvarRtpPacketizer.payloads(for: nal)
    XCTAssertGreaterThan(payloads.count, 1)

    var reconstructed = Data([nal[0]])
    for payload in payloads {
      XCTAssertLessThanOrEqual(
        payload.count,
        VnvarRtpPacketizer.maxPayloadBytes
      )
      reconstructed.append(payload.dropFirst(2))
    }
    XCTAssertEqual(reconstructed, nal)
  }

  func testNalAtPayloadLimitIsNotFragmented() {
    let nal = Data(
      repeating: 0x55,
      count: VnvarRtpPacketizer.maxPayloadBytes
    )
    XCTAssertEqual(VnvarRtpPacketizer.payloads(for: nal), [nal])
  }

  func testNalOverPayloadLimitIsFragmented() {
    let nal = Data(
      repeating: 0x65,
      count: VnvarRtpPacketizer.maxPayloadBytes + 1
    )
    let payloads = VnvarRtpPacketizer.payloads(for: nal)
    XCTAssertEqual(payloads.count, 2)
    XCTAssertTrue(payloads.allSatisfy {
      $0.count <= VnvarRtpPacketizer.maxPayloadBytes
    })
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
    XCTAssertEqual(Data(packet[8..<12]), Data([0x56, 0x4E, 0x56, 0x52]))
  }

  func testRtpHeaderWithoutMarkerUsesPayloadType96() {
    let packet = VnvarRtpPacketizer.packet(
      payload: Data([0x01]),
      sequence: UInt16.max,
      timestamp: 7,
      marker: false
    )
    XCTAssertEqual(packet[1], 96)
    XCTAssertEqual(Data(packet[2..<4]), Data([0xFF, 0xFF]))
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

  func testRecoveryGateRejectsPFramesUntilFirstKeyFrame() {
    var gate = VnvarVideoRecoveryGate()

    XCTAssertTrue(gate.awaitingKeyFrame)
    XCTAssertFalse(gate.shouldSend(isKeyFrame: false))
    XCTAssertTrue(gate.shouldSend(isKeyFrame: true))
    XCTAssertFalse(gate.awaitingKeyFrame)
    XCTAssertTrue(gate.shouldSend(isKeyFrame: false))
  }

  func testRecoveryGateResetsWheneverPlaybackBegins() {
    var gate = VnvarVideoRecoveryGate()
    XCTAssertTrue(gate.shouldSend(isKeyFrame: true))
    XCTAssertFalse(gate.awaitingKeyFrame)

    gate.beginPlaying()

    XCTAssertTrue(gate.awaitingKeyFrame)
    XCTAssertFalse(gate.shouldSend(isKeyFrame: false))
  }

  func testDroppingPFrameBreaksReferenceChainAndRequestsKeyFrame() {
    var gate = VnvarVideoRecoveryGate()
    XCTAssertTrue(gate.shouldSend(isKeyFrame: true))

    XCTAssertTrue(gate.didDrop(isKeyFrame: false))
    XCTAssertTrue(gate.awaitingKeyFrame)
    XCTAssertFalse(gate.shouldSend(isKeyFrame: false))
  }

  func testDroppingRequestedKeyFrameRequestsAnotherOne() {
    var gate = VnvarVideoRecoveryGate()

    XCTAssertTrue(gate.didDrop(isKeyFrame: true))
    XCTAssertTrue(gate.awaitingKeyFrame)
  }

  func testRepeatedPFramesWhileWaitingDoNotSpamKeyFrameRequests() {
    var gate = VnvarVideoRecoveryGate()

    XCTAssertFalse(gate.didDrop(isKeyFrame: false))
    XCTAssertFalse(gate.shouldSend(isKeyFrame: false))
    XCTAssertTrue(gate.awaitingKeyFrame)
  }
}
