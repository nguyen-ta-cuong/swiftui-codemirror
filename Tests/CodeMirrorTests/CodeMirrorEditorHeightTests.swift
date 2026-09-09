import Foundation
import XCTest

@testable import CodeMirror

#if os(macOS) && canImport(AppKit)
  import AppKit
#endif

nonisolated final class CodeMirrorEditorHeightTests: XCTestCase {
  func testHeightPolicyValidatesRowsAndSerializesItsMode() {
    let valid = CodeMirrorEditorHeightPolicy.contentSized(
      minimumVisibleRows: 3, maximumVisibleRows: 10)
    let invalidMinimum = CodeMirrorEditorHeightPolicy.contentSized(
      minimumVisibleRows: -1, maximumVisibleRows: 10)
    let invalidMaximum = CodeMirrorEditorHeightPolicy.contentSized(
      minimumVisibleRows: 10, maximumVisibleRows: 3)

    XCTAssertEqual(valid.normalized, valid)
    XCTAssertEqual(
      invalidMinimum.normalized,
      .fillsAvailableScrollViewport(minimumVisibleRows: 0))
    XCTAssertEqual(
      invalidMaximum.normalized,
      .fillsAvailableScrollViewport(minimumVisibleRows: 0))
    XCTAssertEqual(valid.payload["mode"] as? String, "contentSized")
    XCTAssertEqual(valid.payload["minimumVisibleRows"] as? Int, 3)
    XCTAssertEqual(valid.payload["maximumVisibleRows"] as? Int, 10)
  }

  #if os(macOS) && canImport(AppKit) && canImport(WebKit)
    @MainActor
    func testRenderedContentSizedHeightUsesRowsWrappingAndCap() async throws {
      let configuration = CodeMirrorConfiguration(wrapsLines: true)
      let session = CodeMirrorSession(initialText: "row-1", configuration: configuration) { _ in
        .accept
      }
      let harness = try CodeMirrorHeightHarness(
        session: session,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10)
      )
      defer { harness.close() }
      try await harness.waitForConfigured()

      let initial = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let initialHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))
      assertAcceptedRows(initial, height: initialHeight)

      let sixLines = renderedLineFixture(6)
      _ = try await session.replace(text: sixLines, preservingSelections: false)
      try await harness.waitForText(sixLines)
      let six = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let sixHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))
      let sixNaturalRows = max(0, six.naturalHeight - six.documentPadding) / six.lineHeight
      XCTAssertGreaterThan(sixNaturalRows, 5)
      assertAcceptedRows(six, height: sixHeight)

      let twelveLines = renderedLineFixture(12)
      _ = try await session.replace(text: twelveLines, preservingSelections: false)
      try await harness.waitForText(twelveLines)
      let twelve = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let twelveHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))
      let twelveNaturalRows =
        max(0, twelve.naturalHeight - twelve.documentPadding) / twelve.lineHeight
      XCTAssertGreaterThanOrEqual(twelveNaturalRows, 11)
      assertAcceptedRows(twelve, height: twelveHeight)
      let twelveRows = try await harness.waitForRenderedRows(at: twelveHeight)
      XCTAssertTrue(twelveRows.row10FullyVisible)
      XCTAssertFalse(twelveRows.row11FullyVisible)

      let sixteenLines = renderedLineFixture(16)
      _ = try await session.replace(text: sixteenLines, preservingSelections: false)
      try await harness.waitForText(sixteenLines)
      let sixteen = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let sixteenHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))
      let sixteenNaturalRows =
        max(0, sixteen.naturalHeight - sixteen.documentPadding) / sixteen.lineHeight
      XCTAssertGreaterThanOrEqual(sixteenNaturalRows, 15)
      assertAcceptedRows(sixteen, height: sixteenHeight)
      let sixteenRows = try await harness.waitForRenderedRows(at: sixteenHeight)
      XCTAssertTrue(sixteenRows.row10FullyVisible)
      XCTAssertFalse(sixteenRows.row11FullyVisible)

      try await assertWrappedHeight(session: session, harness: harness)
    }

    @MainActor
    func testRenderedDiagnosticsHeightIsAddedAndCleared() async throws {
      let configuration = CodeMirrorConfiguration(language: .json, wrapsLines: true)
      let validText = "{\"active\":true}"
      let session = CodeMirrorSession(initialText: validText, configuration: configuration) { _ in
        .accept
      }
      let harness = try CodeMirrorHeightHarness(
        session: session,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10)
      )
      defer { harness.close() }
      try await harness.waitForConfigured()
      _ = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let baselineHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))

      let invalidText = "{"
      _ = try await session.replace(text: invalidText, preservingSelections: false)
      try await harness.waitForText(invalidText)
      try await harness.waitForDiagnostics(visible: true)
      let invalid = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let invalidHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))
      XCTAssertGreaterThan(invalid.diagnosticsHeight, 0)
      XCTAssertGreaterThan(invalidHeight, baselineHeight)
      XCTAssertEqual(
        invalidHeight,
        max(
          3,
          min(10, max(0, invalid.naturalHeight - invalid.documentPadding) / invalid.lineHeight)
        ) * invalid.lineHeight + invalid.documentPadding + invalid.diagnosticsHeight,
        accuracy: 2
      )

      _ = try await session.replace(text: validText, preservingSelections: false)
      try await harness.waitForText(validText)
      try await harness.waitForDiagnostics(visible: false)
      let restored = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      let restoredHeight = Double(try XCTUnwrap(harness.coordinator.intrinsicHeight))
      XCTAssertEqual(restored.diagnosticsHeight, 0, accuracy: 0.5)
      XCTAssertLessThan(restoredHeight, invalidHeight)
      XCTAssertEqual(
        restoredHeight,
        max(
          3,
          min(
            10,
            max(0, restored.naturalHeight - restored.documentPadding) / restored.lineHeight
          )
        ) * restored.lineHeight + restored.documentPadding,
        accuracy: 2
      )
      XCTAssertGreaterThanOrEqual(restoredHeight, baselineHeight - 2)
    }

    @MainActor
    func testSharedSessionKeepsContentSizedAndFillReplicasIndependent() async throws {
      let session = CodeMirrorSession(initialText: "shared") { _ in .accept }
      let inline = try CodeMirrorHeightHarness(
        session: session,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10),
        frame: NSRect(x: 0, y: 0, width: 360, height: 500),
        instrument: true
      )
      let detached = try CodeMirrorHeightHarness(
        session: session,
        heightPolicy: .fillsAvailableScrollViewport(minimumVisibleRows: 0),
        frame: NSRect(x: 400, y: 0, width: 360, height: 500)
      )
      defer {
        inline.close()
        detached.close()
      }
      try await inline.waitForConfigured()
      try await detached.waitForConfigured()
      _ = try await inline.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      try await detached.waitForText("shared")
      XCTAssertNotNil(inline.coordinator.intrinsicHeight)
      XCTAssertNil(detached.coordinator.intrinsicHeight)
      XCTAssertTrue(detached.forwarder.nativeDurations.isEmpty)

      let updatedText = "updated shared source"
      _ = try await session.replace(text: updatedText, preservingSelections: false)
      try await inline.waitForText(updatedText)
      try await detached.waitForText(updatedText)
      XCTAssertEqual(try session.snapshot().text, updatedText)

      inline.coordinator.update(
        heightPolicy: .fillsAvailableScrollViewport(minimumVisibleRows: 0))
      try await inline.waitUntil("inline fill transition") {
        inline.coordinator.intrinsicHeight == nil
      }
      XCTAssertNil(inline.coordinator.intrinsicHeight)

      detached.coordinator.update(
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10))
      _ = try await detached.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      XCTAssertNotNil(detached.coordinator.intrinsicHeight)
      XCTAssertNil(inline.coordinator.intrinsicHeight)
    }

    @MainActor
    func testRenderedHeightLatencyBudgetsAcrossDocumentSizes() async throws {
      let session = CodeMirrorSession(initialText: "seed") { _ in .accept }
      let harness = try CodeMirrorHeightHarness(
        session: session,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10),
        instrument: true
      )
      defer { harness.close() }
      try await harness.waitForConfigured()
      let fixtures = [
        ("1KiB", 1_024),
        ("256KiB", 256 * 1_024),
        ("1MiB", 1_024 * 1_024),
        ("1MiB+1", 1_024 * 1_024 + 1)
      ]

      for (name, byteCount) in fixtures {
        let source = String(repeating: "x", count: byteCount)
        _ = try await session.replace(text: source, preservingSelections: false)
        try await harness.waitForTextLength(source.utf16.count)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await harness.clearProbe()
        harness.forwarder.reset()
        for sample in 0..<30 {
          let minimumRows = sample.isMultiple(of: 2) ? 9 : 10
          let nativeCount = harness.forwarder.nativeDurations.count
          try await harness.sendContentSizedPolicy(minimumRows: minimumRows, maximumRows: 10)
          _ = try await harness.waitForProbeDuration(after: sample)
          try await harness.waitUntil("\(name) native report \(sample)") {
            harness.forwarder.nativeDurations.count > nativeCount
          }
          let layout = try await harness.layout()
          XCTAssertGreaterThan(layout.lineHeight, 0)
          XCTAssertGreaterThan(layout.naturalHeight, 0)
        }
        let javascriptDurations = try await harness.probeDurations()
        let nativeDurations = harness.forwarder.nativeDurations
        XCTAssertEqual(javascriptDurations.count, 30)
        XCTAssertEqual(nativeDurations.count, 30)
        XCTAssertLessThanOrEqual(percentile(javascriptDurations, at: 0.95), 100)
        XCTAssertLessThanOrEqual(javascriptDurations.max() ?? .infinity, 250)
        XCTAssertLessThanOrEqual(percentile(nativeDurations, at: 0.95), 5)
        XCTAssertLessThanOrEqual(nativeDurations.max() ?? .infinity, 16.7)
      }
    }

  #endif
}

#if os(macOS) && canImport(AppKit) && canImport(WebKit)
  @MainActor
  extension CodeMirrorHeightHarness {
    private var hasRenderableDocumentWindow: Bool {
      let screenFrame = window.screen?.frame ?? .zero
      let visibleIntersection = window.frame.intersection(screenFrame)
      let attached = webView.window === window
      let renderableFrame =
        webView.frame.width.isFinite
        && webView.frame.height.isFinite
        && webView.frame.width > 0
        && webView.frame.height > 0
      return coordinator.pageIsConfigured
        && coordinator.attachedLoadID != nil
        && window.isVisible
        && !window.isMiniaturized
        && window.isOnActiveSpace
        && !visibleIntersection.isEmpty
        && attached
        && !webView.isHidden
        && renderableFrame
    }

    func waitForDocumentVisible() async throws {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        let visible = (try? await evaluateString("String(document.visibilityState)")) == "visible"
        if visible && hasRenderableDocumentWindow {
          return
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          let documentVisibility =
            (try? await evaluateString("String(document.visibilityState)")) ?? "unavailable"
          let application = NSApplication.shared
          let screenFrame = window.screen?.frame ?? .zero
          let visibleIntersection = window.frame.intersection(screenFrame)
          let webViewWindow = webView.window
          let webViewWindowIdentity =
            webViewWindow.map {
              String(describing: ObjectIdentifier($0))
            } ?? "nil"
          let details = [
            "application.active=\(application.isActive)",
            "application.activationPolicy=\(application.activationPolicy())",
            "window.visible=\(window.isVisible)",
            "window.key=\(window.isKeyWindow)",
            "window.miniaturized=\(window.isMiniaturized)",
            "window.onActiveSpace=\(window.isOnActiveSpace)",
            "window.occlusionState=\(window.occlusionState.rawValue)",
            "window.frame=\(window.frame)",
            "window.screenFrame=\(screenFrame)",
            "window.visibleIntersection=\(visibleIntersection)",
            "webView.windowIdentity=\(webViewWindowIdentity)",
            "webView.hidden=\(webView.isHidden)",
            "webView.frame=\(webView.frame)",
            "document.visibilityState=\(documentVisibility)"
          ].joined(separator: "; ")
          throw NSError(
            domain: "CodeMirrorEditorHeightTests",
            code: 14,
            userInfo: [NSLocalizedDescriptionKey: details]
          )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    func probeState() async throws -> HeightProbeState {
      let value = try await evaluateString(
        """
        JSON.stringify(globalThis.__codeMirrorHeightProbe?.state() ?? {
          installed: false,
          installCount: 0,
          receiveCount: 0,
          startCount: 0,
          globalErrors: [],
          unhandledRejections: []
        })
        """
      )
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorHeightTests", code: 12)
      }
      return try JSONDecoder().decode(HeightProbeState.self, from: data)
    }

    private func renderedRowGeometry() async throws -> String {
      try await evaluateString(
        """
        JSON.stringify((() => {
          const view = globalThis.__codeMirrorHeightProbe?.controller()?.view;
          const scroll = document.querySelector(".cm-scroller");
          const lines = [...document.querySelectorAll(".cm-line")];
          const rect = element => {
            const value = element?.getBoundingClientRect();
            return value ? {top: value.top, bottom: value.bottom, height: value.height,
              left: value.left, right: value.right, width: value.width} : null;
          };
          return {defaultLineHeight: view?.defaultLineHeight,
            documentPadding: view?.documentPadding,
            scaleY: view?.scaleY, lineCount: lines.length, scroller: rect(scroll),
            clientHeight: scroll?.clientHeight, scrollHeight: scroll?.scrollHeight,
            rows: [1, 10, 11].map(index => ({index, rect: rect(lines[index - 1])}))};
        })())
        """
      )
    }

    func timeoutDiagnostics() async -> String {
      let originalGeometry = (try? await renderedRowGeometry()) ?? "unavailable"
      if let height = coordinator.intrinsicHeight, height.isFinite, height > 0, height <= 4_096 {
        window.setContentSize(NSSize(width: webView.frame.width, height: height))
        webView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
      }
      let cappedGeometry = (try? await renderedRowGeometry()) ?? "unavailable"
      let renderedMetrics: String
      if let metrics = try? await self.metrics() {
        renderedMetrics = [
          "lineHeight=\(metrics.lineHeight)",
          "naturalHeight=\(metrics.naturalHeight)",
          "width=\(metrics.width)",
          "diagnosticsHeight=\(metrics.diagnosticsHeight)",
          "documentPadding=\(metrics.documentPadding)"
        ].joined(separator: ", ")
      } else {
        renderedMetrics = "unavailable"
      }
      let probeDescription: String
      if let probe = try? await probeState() {
        probeDescription = probe.diagnosticDescription
      } else {
        probeDescription = "unavailable"
      }
      let documentVisibility =
        (try? await evaluateString("String(document.visibilityState)")) ?? "unavailable"
      let webViewWindowVisible = webView.window.map { String(describing: $0.isVisible) } ?? "nil"
      let windowOcclusionState = String(describing: window.occlusionState.rawValue)
      return [
        "configured=\(coordinator.pageIsConfigured)",
        "loadID=\(coordinator.attachedLoadID?.uuidString ?? "nil")",
        "policy=\(coordinator.currentHeightPolicy)",
        "intrinsicHeight=\(String(describing: coordinator.intrinsicHeight))",
        "metrics=\(renderedMetrics)",
        "originalGeometry=\(originalGeometry)",
        "cappedGeometry=\(cappedGeometry)",
        "probe=\(probeDescription)",
        "document.visibilityState=\(documentVisibility)",
        "webView.window?.isVisible=\(webViewWindowVisible)",
        "window.occlusionState=\(windowOcclusionState)"
      ].joined(separator: "; ")
    }

  }
#endif
