import Flutter
import Network
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

  func testRtcpSenderReportContainsClockAndCounters() {
    let report = VnvarRtpPacketizer.senderReport(
      ntpTimestamp: 0x0102030405060708,
      rtpTimestamp: 0x11223344,
      packetCount: 9,
      octetCount: 1_200
    )

    XCTAssertEqual(report.count, 28)
    XCTAssertEqual(Data(report[0..<4]), Data([0x80, 200, 0, 6]))
    XCTAssertEqual(Data(report[8..<16]), Data([1, 2, 3, 4, 5, 6, 7, 8]))
    XCTAssertEqual(Data(report[16..<20]), Data([0x11, 0x22, 0x33, 0x44]))
    XCTAssertEqual(Data(report[20..<24]), Data([0, 0, 0, 9]))
    XCTAssertEqual(Data(report[24..<28]), Data([0, 0, 4, 0xB0]))
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
  // MARK: - FU-A / marker

  func testFuAMiddleFragmentsHaveNeitherStartNorEndBit() {
    var nal = Data([0x65])
    nal.append(Data(repeating: 0x11, count: VnvarRtpPacketizer.maxPayloadBytes * 3))
    let payloads = VnvarRtpPacketizer.payloads(for: nal)
    XCTAssertGreaterThanOrEqual(payloads.count, 3)
    for (index, payload) in payloads.enumerated() {
      XCTAssertLessThanOrEqual(payload.count, VnvarRtpPacketizer.maxPayloadBytes)
      XCTAssertEqual(payload[0] & 0x1F, 28)
      // NRI của NAL gốc được giữ trong FU indicator.
      XCTAssertEqual(payload[0] & 0x60, nal[0] & 0x60)
      let start = payload[1] & 0x80 != 0
      let end = payload[1] & 0x40 != 0
      XCTAssertEqual(start, index == 0)
      XCTAssertEqual(end, index == payloads.count - 1)
    }
  }

  func testMarkerBitIsSetOnlyOnLastPacketOfAccessUnit() {
    // Cách ClientSession.send gắn marker: gói cuối của NAL cuối trong access unit.
    var idr = Data([0x65])
    idr.append(Data(repeating: 0x22, count: 4_000))
    let nals = [Data([0x67, 0x42, 0x00, 0x1F]), Data([0x68, 0xCE]), idr]
    var packets: [Data] = []
    var sequence: UInt16 = 10
    for (nalIndex, nal) in nals.enumerated() {
      let payloads = VnvarRtpPacketizer.payloads(for: nal)
      for (payloadIndex, payload) in payloads.enumerated() {
        packets.append(VnvarRtpPacketizer.packet(
          payload: payload,
          sequence: sequence,
          timestamp: 90_000,
          marker: nalIndex == nals.count - 1 && payloadIndex == payloads.count - 1
        ))
        sequence &+= 1
      }
    }
    XCTAssertGreaterThan(packets.count, 3)
    for (index, packet) in packets.enumerated() {
      XCTAssertLessThanOrEqual(packet.count, 12 + VnvarRtpPacketizer.maxPayloadBytes)
      XCTAssertEqual(packet[1] & 0x80 != 0, index == packets.count - 1)
      XCTAssertEqual(packet[1] & 0x7F, VnvarRtpPacketizer.payloadType)
    }
  }

  // MARK: - RTCP feedback

  func testRtcpFirRequestsKeyFrame() throws {
    let packet = Data([
      0x84, 206, 0x00, 0x04, // PSFB FMT=4 (FIR), 20 bytes
      0, 0, 0, 1,            // sender SSRC
      0, 0, 0, 0,            // media SSRC (unused for FIR)
      0x56, 0x4E, 0x56, 0x52, // FCI: target SSRC
      7, 0, 0, 0,            // FCI: seq nr + reserved
    ])
    let feedback = try XCTUnwrap(VnvarRtcpFeedback.parse(packet))
    XCTAssertTrue(feedback.requestsKeyFrame)
    XCTAssertNil(feedback.fractionLost)
  }

  func testRtcpFirWithoutFciIsIgnored() {
    let packet = Data([
      0x84, 206, 0x00, 0x02,
      0, 0, 0, 1,
      0, 0, 0, 0,
    ])
    XCTAssertNil(VnvarRtcpFeedback.parse(packet))
  }

  func testRtcpRembDoesNotRequestKeyFrame() {
    let packet = Data([
      0x8F, 206, 0x00, 0x04, // PSFB FMT=15 (REMB)
      0, 0, 0, 1,
      0, 0, 0, 0,
      0x52, 0x45, 0x4D, 0x42, // "REMB"
      0x01, 0x0A, 0x00, 0x00,
    ])
    XCTAssertNil(VnvarRtcpFeedback.parse(packet))
  }

  func testCompoundRtcpReceiverReportAndPliAreBothParsed() throws {
    var packet = Data([
      0x81, 201, 0x00, 0x07, // RR, one report block, 32 bytes
      0, 0, 0, 1,
    ])
    packet.append(contentsOf: [0x56, 0x4E, 0x56, 0x52, 26]) // ~10% lost
    packet.append(Data(repeating: 0, count: 19))
    packet.append(contentsOf: [
      0x81, 206, 0x00, 0x02, // PLI
      0, 0, 0, 1,
      0x56, 0x4E, 0x56, 0x52,
    ])
    let feedback = try XCTUnwrap(VnvarRtcpFeedback.parse(packet))
    XCTAssertTrue(feedback.requestsKeyFrame)
    XCTAssertEqual(try XCTUnwrap(feedback.fractionLost), 26.0 / 256.0, accuracy: 0.0001)
  }

  func testRtcpWithTrailingGarbageIsRejected() {
    let packet = Data([
      0x81, 206, 0x00, 0x02,
      0, 0, 0, 1,
      0x56, 0x4E, 0x56, 0x52,
      0x00, 0x00,
    ])
    XCTAssertNil(VnvarRtcpFeedback.parse(packet))
  }

  // MARK: - Bitrate controller

  func testRtspBitrateFloorNeverExceedsCeiling() {
    for maximum in [100_000, 250_000, 300_000, 499_999, 500_000, 1_000_000, 8_000_000] {
      let controller = VnvarRtspBitrateController(maximumBitrate: maximum)
      XCTAssertLessThanOrEqual(controller.minimumBitrate, controller.maximumBitrate)
      XCTAssertEqual(controller.currentBitrate, controller.maximumBitrate)
    }
  }

  func testRtspBitrateWithLowCeilingStaysAtCeiling() {
    var controller = VnvarRtspBitrateController(maximumBitrate: 300_000)
    XCTAssertEqual(controller.minimumBitrate, 300_000)
    XCTAssertNil(controller.report(fractionLost: 0.5))
    XCTAssertEqual(controller.currentBitrate, 300_000)
    for _ in 0..<6 { XCTAssertNil(controller.report(fractionLost: 0)) }
    XCTAssertEqual(controller.currentBitrate, 300_000)
  }

  // MARK: - RTCP loss tracker (trung vị client mạng)

  func testLossTrackerIgnoresLoopbackReports() {
    var tracker = VnvarRtcpLossTracker()
    let relay = UUID()
    XCTAssertFalse(tracker.record(client: relay, isLoopback: true, fractionLost: 0.9, now: 0))
    XCTAssertNil(tracker.medianFractionLost(activeClients: [relay], now: 0))
  }

  func testLossTrackerUsesMedianSoOneWeakTabletDoesNotDragOthers() throws {
    var tracker = VnvarRtcpLossTracker()
    let good1 = UUID()
    let good2 = UUID()
    let weak = UUID()
    let relay = UUID()
    tracker.record(client: good1, isLoopback: false, fractionLost: 0.0, now: 1)
    tracker.record(client: good2, isLoopback: false, fractionLost: 0.01, now: 1)
    tracker.record(client: weak, isLoopback: false, fractionLost: 0.40, now: 1)
    tracker.record(client: relay, isLoopback: true, fractionLost: 1.0, now: 1)
    let median = try XCTUnwrap(tracker.medianFractionLost(
      activeClients: [good1, good2, weak, relay],
      now: 1
    ))
    XCTAssertEqual(median, 0.01, accuracy: 0.0001)

    // Hai client: lấy trung vị thấp hơn, một máy yếu không hạ bitrate chung.
    var pair = VnvarRtcpLossTracker()
    pair.record(client: good1, isLoopback: false, fractionLost: 0.0, now: 1)
    pair.record(client: weak, isLoopback: false, fractionLost: 0.40, now: 1)
    XCTAssertEqual(
      try XCTUnwrap(pair.medianFractionLost(activeClients: [good1, weak], now: 1)),
      0.0,
      accuracy: 0.0001
    )
  }

  func testLossTrackerDropsExpiredAndInactiveClients() throws {
    var tracker = VnvarRtcpLossTracker()
    let stale = UUID()
    let paused = UUID()
    let fresh = UUID()
    tracker.record(client: stale, isLoopback: false, fractionLost: 0.0, now: 0)
    tracker.record(client: paused, isLoopback: false, fractionLost: 0.0, now: 9)
    tracker.record(client: fresh, isLoopback: false, fractionLost: 0.30, now: 9)
    let median = try XCTUnwrap(tracker.medianFractionLost(
      activeClients: [stale, fresh],
      now: 10
    ))
    XCTAssertEqual(median, 0.30, accuracy: 0.0001)
    tracker.remove(client: fresh)
    XCTAssertNil(tracker.medianFractionLost(activeClients: [stale, fresh], now: 10))
  }

  func testWeakTabletAloneAmongHealthyOnesDoesNotReduceBitrate() {
    var tracker = VnvarRtcpLossTracker()
    var controller = VnvarRtspBitrateController(maximumBitrate: 8_000_000)
    let clients = (0..<3).map { _ in UUID() }
    tracker.record(client: clients[0], isLoopback: false, fractionLost: 0.5, now: 0)
    tracker.record(client: clients[1], isLoopback: false, fractionLost: 0.0, now: 0)
    tracker.record(client: clients[2], isLoopback: false, fractionLost: 0.0, now: 0)
    let median = tracker.medianFractionLost(activeClients: Set(clients), now: 0) ?? 0
    XCTAssertNil(controller.report(fractionLost: median))
    XCTAssertEqual(controller.currentBitrate, 8_000_000)
  }

  // MARK: - H.264 encoder

  func testDataRateLimitsAllowPeakAboveAverage() {
    let limits = VnvarH264Encoder.dataRateLimits(forAverageBitrate: 4_000_000)
    XCTAssertEqual(limits, [750_000, 1])
    XCTAssertGreaterThan(limits[0] * 8, 4_000_000)
  }

  func testStoppingAnUnstartedEncoderIsIdempotent() {
    var encoder: VnvarH264Encoder? = VnvarH264Encoder(bitrate: 2_000_000, fps: 30)
    encoder?.stop()
    encoder?.stop()
    // deinit gọi stop() lần nữa: không được treo/crash.
    encoder = nil
    XCTAssertNil(encoder)
  }

  func testAudioFirstSampleConvertsDeviceTimeToEpoch() {
    let ms = VnvarAudioSegmentRecorder.epochMsForFirstSample(
      wallNowSeconds: 1_700_000_000.0,
      deviceNow: 100.0,
      startDeviceTime: 100.05,
      inputLatency: 0
    )
    XCTAssertEqual(ms, 1_700_000_000_050.0, accuracy: 0.01)
  }

  func testAudioFirstSampleSubtractsInputLatency() {
    let ms = VnvarAudioSegmentRecorder.epochMsForFirstSample(
      wallNowSeconds: 1_700_000_000.0,
      deviceNow: 100.0,
      startDeviceTime: 100.05,
      inputLatency: 0.012
    )
    XCTAssertEqual(ms, 1_700_000_000_038.0, accuracy: 0.01)
  }

  func testAudioFirstSampleIgnoresInvalidLatency() {
    for latency in [-0.5, Double.nan, Double.infinity] {
      let ms = VnvarAudioSegmentRecorder.epochMsForFirstSample(
        wallNowSeconds: 1_000.0,
        deviceNow: 5.0,
        startDeviceTime: 5.0,
        inputLatency: latency
      )
      XCTAssertEqual(ms, 1_000_000.0, accuracy: 0.01)
    }
  }

  // MARK: Luồng RTSP overlay (C5)

  func testOverlayWithCanvasSizeCoversWholeCanvas() {
    let rect = VnvarOverlayGeometry.fittedRect(
      imageSize: CGSize(width: 1920, height: 1080),
      canvasSize: CGSize(width: 1920, height: 1080)
    )
    XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
  }

  func testSmallerOverlayWithSameAspectIsScaledUpToCanvas() {
    let rect = VnvarOverlayGeometry.fittedRect(
      imageSize: CGSize(width: 1280, height: 720),
      canvasSize: CGSize(width: 1920, height: 1080)
    )
    XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
    XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
    XCTAssertEqual(rect.width, 1920, accuracy: 0.001)
    XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
  }

  func testOverlayWithDifferentAspectIsFittedAndCentered() {
    // Ảnh dọc trên canvas ngang: giữ tỉ lệ, căn giữa theo chiều ngang.
    let rect = VnvarOverlayGeometry.fittedRect(
      imageSize: CGSize(width: 1080, height: 1920),
      canvasSize: CGSize(width: 1920, height: 1080)
    )
    XCTAssertEqual(rect.height, 1080, accuracy: 0.001)
    XCTAssertEqual(rect.width, 607.5, accuracy: 0.001)
    XCTAssertEqual(rect.minX, (1920 - 607.5) / 2, accuracy: 0.001)
    XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
  }

  func testOverlayGeometryRejectsEmptySizes() {
    XCTAssertEqual(
      VnvarOverlayGeometry.fittedRect(
        imageSize: .zero,
        canvasSize: CGSize(width: 1920, height: 1080)
      ),
      .zero
    )
    XCTAssertEqual(
      VnvarOverlayGeometry.fittedRect(
        imageSize: CGSize(width: 10, height: 10),
        canvasSize: .zero
      ),
      .zero
    )
  }

  func testOverlayTransformMapsSourceExtentOntoTargetRect() {
    let extent = CGRect(x: 10, y: 20, width: 100, height: 50)
    let target = CGRect(x: 0, y: 30, width: 200, height: 100)
    let transform = VnvarOverlayGeometry.transform(from: extent, to: target)
    let mapped = extent.applying(transform)
    XCTAssertEqual(mapped.minX, target.minX, accuracy: 0.001)
    XCTAssertEqual(mapped.minY, target.minY, accuracy: 0.001)
    XCTAssertEqual(mapped.width, target.width, accuracy: 0.001)
    XCTAssertEqual(mapped.height, target.height, accuracy: 0.001)
  }

  func testLoopbackOnlyServerAcceptsOnlyLoopbackClients() throws {
    let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 8555))
    let ipv4Loopback = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
    let ipv6Loopback = NWEndpoint.hostPort(host: .ipv6(.loopback), port: port)
    let lan = NWEndpoint.hostPort(host: NWEndpoint.Host("192.168.1.20"), port: port)
    XCTAssertTrue(VnvarRtspServer.allowsConnection(from: ipv4Loopback, loopbackOnly: true))
    XCTAssertTrue(VnvarRtspServer.allowsConnection(from: ipv6Loopback, loopbackOnly: true))
    XCTAssertFalse(VnvarRtspServer.allowsConnection(from: lan, loopbackOnly: true))
    // Luồng chính 8554 cho tablet giữ nguyên: nhận cả client mạng LAN.
    XCTAssertTrue(VnvarRtspServer.allowsConnection(from: lan, loopbackOnly: false))
  }

  func testStoppingAnUnstartedLoopbackServerIsIdempotent() {
    let server = VnvarRtspServer(port: 8555, loopbackOnly: true)
    XCTAssertTrue(server.loopbackOnly)
    server.stop()
    server.stop()
    XCTAssertFalse(server.hasPlayingClients)
  }

  func testOverlayCompositorRejectsMissingImage() {
    XCTAssertThrowsError(
      try VnvarOverlayCompositor(overlayPath: "/nonexistent/vnvar-overlay.png")
    )
  }
}
