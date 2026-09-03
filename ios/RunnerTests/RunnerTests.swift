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

  func testRtpSequenceCanWrapFromMaximumToZero() {
    var sequence = UInt16.max
    let lastPacket = VnvarRtpPacketizer.packet(
      payload: Data([0x01]),
      sequence: sequence,
      timestamp: 1,
      marker: true
    )
    sequence &+= 1
    let firstPacket = VnvarRtpPacketizer.packet(
      payload: Data([0x02]),
      sequence: sequence,
      timestamp: 2,
      marker: true
    )

    XCTAssertEqual(Data(lastPacket[2..<4]), Data([0xFF, 0xFF]))
    XCTAssertEqual(Data(firstPacket[2..<4]), Data([0x00, 0x00]))
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

  func testEmptyL16AudioPayloadStillProducesAValidRtpHeader() {
    let packet = VnvarRtpPacketizer.audioPacket(
      payload: Data(),
      sequence: 1,
      timestamp: 2
    )

    XCTAssertEqual(packet.count, 12)
    XCTAssertEqual(packet[0], 0x80)
    XCTAssertEqual(packet[1], 97)
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

  func testStoppingAnUnstartedRtspServerIsIdempotent() {
    let server = VnvarRtspServer(port: 0)

    server.stop()
    server.stop()
  }

  func testUnstartedAudioRecorderHasStableEmptyState() throws {
    let recorder = VnvarAudioSegmentRecorder()

    XCTAssertNil(try recorder.stop())
    let status = recorder.status()
    XCTAssertEqual(status["active"] as? Bool, false)
    XCTAssertEqual(status["bytes"] as? Int, 0)
    XCTAssertNil(status["path"])
  }

  func testRtcpReceiverReportParsesWorstFractionLost() throws {
    var packet = Data([
      0x82, 201, 0x00, 0x0D, // RR with two report blocks, 56 bytes
      0, 0, 0, 1,            // sender SSRC
    ])
    packet.append(contentsOf: [0, 0, 0, 2, 13])
    packet.append(Data(repeating: 0, count: 19))
    packet.append(contentsOf: [0, 0, 0, 3, 64])
    packet.append(Data(repeating: 0, count: 19))

    let feedback = try XCTUnwrap(VnvarRtcpFeedback.parse(packet))
    let fractionLost = try XCTUnwrap(feedback.fractionLost)
    XCTAssertEqual(fractionLost, 0.25, accuracy: 0.0001)
    XCTAssertFalse(feedback.requestsKeyFrame)
  }

  func testRtcpPliRequestsKeyFrame() throws {
    let packet = Data([
      0x81, 206, 0x00, 0x02,
      0, 0, 0, 1,
      0x56, 0x4E, 0x56, 0x52,
    ])

    let feedback = try XCTUnwrap(VnvarRtcpFeedback.parse(packet))
    XCTAssertTrue(feedback.requestsKeyFrame)
    XCTAssertNil(feedback.fractionLost)
  }

  func testMalformedRtcpIsRejected() {
    XCTAssertNil(VnvarRtcpFeedback.parse(Data([0x81, 206, 0, 10])))
    XCTAssertNil(VnvarRtcpFeedback.parse(Data([0x41, 206, 0, 2])))
  }

  func testRtspBitrateDropsFastAndRecoversSlowly() {
    var controller = VnvarRtspBitrateController(maximumBitrate: 8_000_000)

    XCTAssertEqual(controller.report(fractionLost: 0.20), 6_000_000)
    XCTAssertNil(controller.report(fractionLost: 0.01))
    XCTAssertNil(controller.report(fractionLost: 0.01))
    XCTAssertEqual(controller.report(fractionLost: 0.01), 6_600_000)
  }

  func testRtspBitrateNeverDropsBelowItsFloor() {
    var controller = VnvarRtspBitrateController(maximumBitrate: 8_000_000)
    for _ in 0..<20 { _ = controller.report(fractionLost: 1) }

    XCTAssertEqual(controller.currentBitrate, 2_000_000)
    XCTAssertNil(controller.report(fractionLost: 1))
  }
}
