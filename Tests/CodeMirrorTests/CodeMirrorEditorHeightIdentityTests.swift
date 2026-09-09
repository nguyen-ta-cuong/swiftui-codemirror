import Foundation
import XCTest

@testable import CodeMirror

#if os(macOS) && canImport(AppKit)
  import AppKit
#endif

nonisolated final class CodeMirrorEditorHeightIdentityTests: XCTestCase {
  func testFillPolicySerializesAndNormalizesMinimumRows() {
    let policy = CodeMirrorEditorHeightPolicy.fillsAvailableScrollViewport(minimumVisibleRows: 3)
    XCTAssertEqual(policy.normalized, policy)
    XCTAssertEqual(policy.payload["mode"] as? String, "fillsAvailableScrollViewport")
    XCTAssertEqual(policy.payload["minimumVisibleRows"] as? Int, 3)
    XCTAssertEqual(
      CodeMirrorEditorHeightPolicy.fillsAvailableScrollViewport(minimumVisibleRows: -1).normalized,
      .fillsAvailableScrollViewport(minimumVisibleRows: 0)
    )
  }

  func testContentSizeMessageDecodesItsNativeIdentityAndHeight() throws {
    let sessionID = CodeMirrorSessionID()
    let replicaID = CodeMirrorReplicaID()
    let loadID = UUID()
    let measurementID = UUID()
    let message = try CodeMirrorInboundMessage.decode([
      "type": "contentSize",
      "sessionID": sessionID.rawValue.uuidString,
      "replicaID": replicaID.rawValue.uuidString,
      "loadID": loadID.uuidString,
      "measurementID": measurementID.uuidString,
      "height": 180.5
    ])

    guard case .contentSize(let contentSize) = message else {
      XCTFail("content size did not decode")
      return
    }
    XCTAssertEqual(contentSize.sessionID, sessionID)
    XCTAssertEqual(contentSize.replicaID, replicaID)
    XCTAssertEqual(contentSize.loadID, loadID)
    XCTAssertEqual(contentSize.measurementID, measurementID)
    XCTAssertEqual(contentSize.height, 180.5)
    XCTAssertThrowsError(
      try CodeMirrorInboundMessage.decode([
        "type": "contentSize",
        "sessionID": sessionID.rawValue.uuidString,
        "replicaID": replicaID.rawValue.uuidString,
        "loadID": loadID.uuidString,
        "height": 180.5
      ]))
    XCTAssertThrowsError(
      try CodeMirrorInboundMessage.decode([
        "type": "contentSize",
        "sessionID": sessionID.rawValue.uuidString,
        "replicaID": replicaID.rawValue.uuidString,
        "loadID": loadID.uuidString,
        "measurementID": "not-a-uuid",
        "height": 180.5
      ]))
  }

  #if os(macOS) && canImport(AppKit) && canImport(WebKit)
    @MainActor
    private func makeHarness(
      session: CodeMirrorSession,
      replicaID: CodeMirrorReplicaID
    ) throws -> CodeMirrorHeightHarness {
      try CodeMirrorHeightHarness(
        session: session,
        replicaID: replicaID,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10)
      )
    }

    @MainActor
    private func assertIgnored(
      _ harness: CodeMirrorHeightHarness,
      contentSize: CodeMirrorContentSize,
      baseline: CGFloat?
    ) {
      harness.coordinator.receiveContentSize(
        sessionID: contentSize.sessionID,
        replicaID: contentSize.replicaID,
        loadID: contentSize.loadID,
        measurementID: contentSize.measurementID,
        height: contentSize.height
      )
      XCTAssertEqual(harness.coordinator.intrinsicHeight, baseline)
    }

    @MainActor
    private func assertMismatchedIdentities(_ harness: CodeMirrorHeightHarness) throws {
      let sessionID = harness.session.id
      let replicaID = harness.replicaID
      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let measurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)
      let baseline = harness.coordinator.intrinsicHeight

      assertIgnored(
        harness,
        contentSize: CodeMirrorContentSize(
          sessionID: CodeMirrorSessionID(),
          replicaID: replicaID,
          loadID: loadID,
          measurementID: measurementID,
          height: 181
        ),
        baseline: baseline)
      assertIgnored(
        harness,
        contentSize: CodeMirrorContentSize(
          sessionID: sessionID,
          replicaID: CodeMirrorReplicaID(),
          loadID: loadID,
          measurementID: measurementID,
          height: 181
        ),
        baseline: baseline)
      assertIgnored(
        harness,
        contentSize: CodeMirrorContentSize(
          sessionID: sessionID,
          replicaID: replicaID,
          loadID: UUID(),
          measurementID: measurementID,
          height: 181
        ),
        baseline: baseline)
      assertIgnored(
        harness,
        contentSize: CodeMirrorContentSize(
          sessionID: sessionID,
          replicaID: replicaID,
          loadID: loadID,
          measurementID: UUID(),
          height: 181
        ),
        baseline: baseline)
    }

    @MainActor
    func testCoordinatorAcceptsOnlyCurrentFiniteConfiguredContentSize() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let harness = try makeHarness(session: session, replicaID: replicaID)
      defer { harness.close() }
      try await harness.waitForConfigured()
      try assertMismatchedIdentities(harness)

      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let measurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)

      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: measurementID,
        height: 180
      )
      XCTAssertEqual(harness.coordinator.intrinsicHeight, 180)
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: measurementID,
        height: 180
      )
      XCTAssertEqual(harness.coordinator.intrinsicHeight, 180)
    }

    @MainActor
    func testCoordinatorRejectsNonFiniteAndOutOfRangeContentSize() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let harness = try makeHarness(session: session, replicaID: replicaID)
      defer { harness.close() }
      try await harness.waitForConfigured()
      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let measurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: measurementID,
        height: 180
      )

      for height in [-1.0, 4097.0, .infinity, .nan] {
        harness.coordinator.receiveContentSize(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          measurementID: measurementID,
          height: height
        )
      }
      XCTAssertEqual(harness.coordinator.intrinsicHeight, 180)
    }

    @MainActor
    func testCoordinatorRefreshesMeasurementTokenForHeightPolicyUpdate() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let harness = try makeHarness(session: session, replicaID: replicaID)
      defer { harness.close() }
      try await harness.waitForConfigured()
      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let measurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)

      harness.coordinator.update(
        heightPolicy: .contentSized(minimumVisibleRows: 4, maximumVisibleRows: 10))
      let refreshedMeasurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)
      XCTAssertNotEqual(refreshedMeasurementID, measurementID)
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      assertIgnored(
        harness,
        contentSize: CodeMirrorContentSize(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          measurementID: measurementID,
          height: 181
        ),
        baseline: nil)
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: refreshedMeasurementID,
        height: 182
      )
      XCTAssertEqual(harness.coordinator.intrinsicHeight, 182)

      harness.coordinator.update(
        heightPolicy: .fillsAvailableScrollViewport(minimumVisibleRows: 0))
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: refreshedMeasurementID,
        height: 200
      )
      XCTAssertNil(harness.coordinator.intrinsicHeight)
    }

    @MainActor
    func testCoordinatorRefreshesMeasurementTokenForConfigurationUpdate() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let harness = try makeHarness(session: session, replicaID: replicaID)
      defer { harness.close() }
      try await harness.waitForConfigured()
      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let previousMeasurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)

      var configuration = session.configuration
      configuration.wrapsLines.toggle()
      session.update(configuration: configuration)
      try await harness.waitUntil("configuration measurement token") {
        harness.coordinator.currentHeightMeasurementID != previousMeasurementID
      }

      let refreshedMeasurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)
      XCTAssertNotEqual(refreshedMeasurementID, previousMeasurementID)
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      assertIgnored(
        harness,
        contentSize: CodeMirrorContentSize(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          measurementID: previousMeasurementID,
          height: 181
        ),
        baseline: nil)
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: refreshedMeasurementID,
        height: 182
      )
      XCTAssertEqual(harness.coordinator.intrinsicHeight, 182)
    }

  #endif
}
