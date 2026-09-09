import Foundation
import XCTest

@testable import CodeMirror

#if os(macOS) && canImport(AppKit)
  import AppKit
#endif

#if os(macOS) && canImport(AppKit) && canImport(WebKit)
  import SwiftUI
  import WebKit

  private struct PositiveFillMetrics: Decodable {
    let lineHeight: Double
    let documentPadding: Double
    let diagnosticMetricsValid: Bool
    let diagnosticNaturalHeight: Double
    let diagnosticHeight: Double
    let diagnosticRectHeight: Double
    let width: Double
    let rowsFullyVisible: Bool
  }

  private enum PositiveFillProbe {
    static let script = """
      JSON.stringify((() => {
        const scroll = document.querySelector(".cm-scroller");
        const lines = [...document.querySelectorAll(".cm-line")].slice(0, 3);
        const panel = document.querySelector(".cm-host-diagnostics");
        const view = globalThis.__codeMirrorHeightProbe?.controller()?.view;
        const rect = element => element?.getBoundingClientRect?.();
        const scrollRect = rect(scroll);
        const lineRects = lines.map(rect);
        const style = panel ? getComputedStyle(panel) : null;
        const number = value => {
          const result = Number.parseFloat(value);
          return Number.isFinite(result) && result >= 0 ? result : 0;
        };
        const finiteNumber = value => {
          const result = Number.parseFloat(value);
          return Number.isFinite(result) && result >= 0 ? result : null;
        };
        const finiteGeometry = value => Number.isFinite(value) ? value : null;
        const paddingTop = number(view?.documentPadding?.top);
        const paddingBottom = number(view?.documentPadding?.bottom);
        const visiblePanel = Boolean(panel && !panel.hidden);
        const naturalHeight = visiblePanel ? Number(panel.scrollHeight) : 0;
        const borderTop = visiblePanel ? finiteNumber(style?.borderTopWidth) : 0;
        const borderBottom = visiblePanel ? finiteNumber(style?.borderBottomWidth) : 0;
        const maxHeight = visiblePanel ? finiteNumber(style?.maxHeight) : 0;
        const diagnosticMetricsValid = !visiblePanel || (
          Number.isFinite(naturalHeight) && naturalHeight >= 0
            && borderTop !== null && borderBottom !== null && maxHeight !== null
        );
        const rawDiagnosticHeight = diagnosticMetricsValid && visiblePanel
          ? naturalHeight + borderTop + borderBottom : 0;
        const diagnosticHeight = diagnosticMetricsValid && visiblePanel
          ? Math.min(rawDiagnosticHeight, maxHeight) : 0;
        const rowsFullyVisible = Boolean(
          scrollRect && lineRects.length === 3
            && lineRects.every(line => line
              && line.top >= scrollRect.top - 2
              && line.bottom <= scrollRect.bottom + 2)
        );
        return {
          lineHeight: number(view?.defaultLineHeight),
          documentPadding: paddingTop + paddingBottom,
          diagnosticMetricsValid,
          diagnosticNaturalHeight: rawDiagnosticHeight,
          diagnosticHeight,
          diagnosticRectHeight: panel && !panel.hidden ? number(rect(panel)?.height) : 0,
          width: number(scrollRect?.width),
          rowsFullyVisible,
          scrollerTop: finiteGeometry(scrollRect?.top),
          scrollerBottom: finiteGeometry(scrollRect?.bottom),
          scrollerHeight: finiteGeometry(scrollRect?.height),
          lineGeometry: lineRects.map(line => ({
            top: finiteGeometry(line?.top),
            bottom: finiteGeometry(line?.bottom),
            height: finiteGeometry(line?.height)
          }))
        };
      })())
      """
  }

  nonisolated final class CodeMirrorEditorFillHeightTests: XCTestCase {
    @MainActor
    func testRenderedFillHeightKeepsRowsAndDiagnosticsInsideTheFloor() async throws {
      let valid = jsonFixture(12)
      let invalid = jsonFixture(12, invalid: true)
      let session = CodeMirrorSession(
        initialText: valid,
        configuration: CodeMirrorConfiguration(
          language: .json,
          wrapsLines: true,
          diagnosticPresentationPolicy: CodeMirrorDiagnosticPresentationPolicy(
            consequence: String(repeating: "diagnostic detail ", count: 40)
          )
        )
      ) { _ in .accept }
      let harness = try CodeMirrorHeightHarness(
        session: session,
        heightPolicy: .fillsAvailableScrollViewport(minimumVisibleRows: 3),
        frame: NSRect(x: 0, y: 0, width: 360, height: 500)
      )
      defer { harness.close() }
      try await harness.waitForConfigured()

      _ = try await waitForPositiveFillHeight(harness, minimumRows: 3)
      let baselineHeight = try XCTUnwrap(harness.coordinator.minimumHeight)
      try await assertRowsAtAcceptedFloor(harness)
      try await assertLargerProposalPreservesFloor(
        harness, expectedHeight: baselineHeight)

      try await constrainDiagnostics(harness)
      _ = try await session.replace(text: invalid, preservingSelections: false)
      try await harness.waitForText(invalid)
      try await harness.waitForDiagnostics(visible: true)
      let invalidMetrics = try await waitForPositiveFillHeight(harness, minimumRows: 3)
      let invalidHeight = try XCTUnwrap(harness.coordinator.minimumHeight)
      XCTAssertGreaterThan(invalidHeight, baselineHeight)
      XCTAssertTrue(invalidMetrics.diagnosticMetricsValid)
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      try await assertRowsAtAcceptedFloor(harness)
      XCTAssertGreaterThan(invalidMetrics.diagnosticHeight, invalidMetrics.diagnosticRectHeight)

      harness.window.setContentSize(NSSize(width: 220, height: 500))
      let narrowMetrics = try await waitForPositiveFillHeight(harness, minimumRows: 3)
      XCTAssertLessThan(narrowMetrics.width, invalidMetrics.width)
      XCTAssertGreaterThan(
        narrowMetrics.diagnosticNaturalHeight, invalidMetrics.diagnosticNaturalHeight)
      try await assertRowsAtAcceptedFloor(harness)

      _ = try await session.replace(text: valid, preservingSelections: false)
      try await harness.waitForText(valid)
      try await harness.waitForDiagnostics(visible: false)
      let restored = try await waitForPositiveFillHeight(harness, minimumRows: 3)
      let restoredHeight = try XCTUnwrap(harness.coordinator.minimumHeight)
      XCTAssertEqual(restoredHeight, baselineHeight, accuracy: 2)
      XCTAssertEqual(restored.diagnosticHeight, 0, accuracy: 0.5)
      try await assertRowsAtAcceptedFloor(harness)

      try await assertZeroFillRejectsStaleReport(harness)
    }

    @MainActor
    func testHostedFillSizingUsesFiniteWidthAndBothHeightProposals() async throws {
      let session = CodeMirrorSession(
        initialText: jsonFixture(6),
        configuration: CodeMirrorConfiguration(language: .json, wrapsLines: true)
      ) { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let editor = CodeMirrorEditor(
        session: session,
        replicaID: replicaID,
        heightPolicy: .fillsAvailableScrollViewport(minimumVisibleRows: 3)
      )
      let hostingView = NSHostingView(rootView: editor)
      hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 120)
      let window = NSWindow(
        contentRect: hostingView.frame,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      window.contentView = hostingView
      window.makeKeyAndOrderFront(NSApplication.shared)
      NSApplication.shared.activate(ignoringOtherApps: true)
      defer {
        window.contentView = nil
        window.close()
      }

      let webView = try await waitForHostedWebView(hostingView)
      let floor = try await waitForHostedFloor(webView, in: hostingView)
      let below = try await waitForHostedLayout(
        hostingView,
        webView: webView,
        width: 360,
        proposalHeight: floor - 10,
        expectedHeight: floor
      )
      XCTAssertEqual(below.width, 360, accuracy: 2)
      XCTAssertEqual(below.height, floor, accuracy: 2)

      let above = try await waitForHostedLayout(
        hostingView,
        webView: webView,
        width: 360,
        proposalHeight: floor + 40,
        expectedHeight: floor + 40
      )
      XCTAssertEqual(above.width, 360, accuracy: 2)
      XCTAssertEqual(above.height, floor + 40, accuracy: 2)
    }

    @MainActor
    private func assertLargerProposalPreservesFloor(
      _ harness: CodeMirrorHeightHarness, expectedHeight: CGFloat
    ) async throws {
      harness.window.setContentSize(NSSize(width: 360, height: 720))
      let metrics = try await waitForPositiveFillHeight(harness, minimumRows: 3)
      let actualHeight = try XCTUnwrap(harness.coordinator.minimumHeight)
      XCTAssertEqual(actualHeight, expectedHeight, accuracy: 2)
      XCTAssertTrue(metrics.rowsFullyVisible)
    }

    @MainActor
    private func assertZeroFillRejectsStaleReport(
      _ harness: CodeMirrorHeightHarness
    ) async throws {
      let sessionID = harness.session.id
      let replicaID = harness.replicaID
      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let measurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)
      harness.coordinator.update(
        heightPolicy: .fillsAvailableScrollViewport(minimumVisibleRows: 0))
      try await harness.waitUntil("fill floor retirement") {
        harness.coordinator.minimumHeight == nil
      }
      harness.coordinator.receiveContentSize(
        sessionID: sessionID,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: measurementID,
        height: 4096
      )
      XCTAssertNil(harness.coordinator.minimumHeight)
      harness.coordinator.detach()
      XCTAssertNil(harness.coordinator.attachedLoadID)
      XCTAssertNil(harness.coordinator.currentHeightMeasurementID)
    }

    @MainActor
    private func waitForPositiveFillHeight(
      _ harness: CodeMirrorHeightHarness, minimumRows: Int
    ) async throws -> PositiveFillMetrics {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        let metrics = try await positiveFillMetrics(harness)
        let expected =
          Double(minimumRows) * metrics.lineHeight
          + metrics.documentPadding + metrics.diagnosticHeight
        let measuredHeight = harness.coordinator.minimumHeight.map(Double.init)
        let matches =
          metrics.diagnosticMetricsValid
          && (measuredHeight.map { abs($0 - expected) <= 2 } ?? false)
        if matches { return metrics }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorFillHeightTests", code: 1)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    @MainActor
    private func waitForRowsAtAcceptedFloor(
      _ harness: CodeMirrorHeightHarness
    ) async throws -> PositiveFillMetrics {
      let acceptedHeight = try XCTUnwrap(harness.coordinator.minimumHeight)
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        harness.window.setContentSize(
          NSSize(width: harness.webView.frame.width, height: acceptedHeight))
        harness.webView.layoutSubtreeIfNeeded()
        harness.window.displayIfNeeded()
        let metrics = try await positiveFillMetrics(harness)
        if metrics.rowsFullyVisible {
          return metrics
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          let rawMetrics = (try? await positiveFillJSON(harness)) ?? "<unavailable>"
          throw NSError(
            domain: "CodeMirrorEditorFillHeightTests",
            code: 5,
            userInfo: [
              NSLocalizedDescriptionKey:
                "acceptedHeight=\(acceptedHeight), "
                + "webViewFrame=\(harness.webView.frame), "
                + "rawMetrics=\(rawMetrics)"
            ]
          )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    @MainActor
    private func assertRowsAtAcceptedFloor(
      _ harness: CodeMirrorHeightHarness
    ) async throws {
      let metrics = try await waitForRowsAtAcceptedFloor(harness)
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      XCTAssertTrue(metrics.rowsFullyVisible)
    }

    @MainActor
    private func positiveFillMetrics(
      _ harness: CodeMirrorHeightHarness
    ) async throws -> PositiveFillMetrics {
      let value = try await positiveFillJSON(harness)
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorFillHeightTests", code: 2)
      }
      return try JSONDecoder().decode(PositiveFillMetrics.self, from: data)
    }

    @MainActor
    private func positiveFillJSON(
      _ harness: CodeMirrorHeightHarness
    ) async throws -> String {
      try await harness.evaluateString(PositiveFillProbe.script)
    }

    @MainActor
    private func constrainDiagnostics(_ harness: CodeMirrorHeightHarness) async throws {
      try await harness.evaluate(
        """
        (() => {
          const panel = document.querySelector(".cm-host-diagnostics");
          if (panel) {
            panel.style.height = "4px";
            panel.style.maxHeight = "80px";
          }
        })()
        """
      )
    }

    @MainActor
    private func waitForHostedWebView(
      _ hostingView: NSHostingView<CodeMirrorEditor>
    ) async throws -> CodeMirrorWebView {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        hostingView.layoutSubtreeIfNeeded()
        if let webView = embeddedWebView(in: hostingView) {
          return webView
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorFillHeightTests", code: 3)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    @MainActor
    private func waitForHostedFloor(
      _ webView: CodeMirrorWebView, in hostingView: NSHostingView<CodeMirrorEditor>
    ) async throws -> CGFloat {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        hostingView.layoutSubtreeIfNeeded()
        if let height = webView.minimumHeight, height.isFinite, height >= 0 {
          return height
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorFillHeightTests", code: 4)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    @MainActor
    private func waitForHostedLayout(
      _ hostingView: NSHostingView<CodeMirrorEditor>,
      webView: CodeMirrorWebView,
      width: CGFloat,
      proposalHeight: CGFloat,
      expectedHeight: CGFloat
    ) async throws -> CGSize {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        hostingView.setFrameSize(NSSize(width: width, height: proposalHeight))
        hostingView.layoutSubtreeIfNeeded()
        let size = webView.frame.size
        if abs(size.width - width) <= 2 && abs(size.height - expectedHeight) <= 2 {
          return size
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorFillHeightTests", code: 6)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    @MainActor
    private func embeddedWebView(in view: NSView) -> CodeMirrorWebView? {
      if let webView = view as? CodeMirrorWebView {
        return webView
      }
      for subview in view.subviews {
        if let webView = embeddedWebView(in: subview) {
          return webView
        }
      }
      return nil
    }

    private func jsonFixture(_ count: Int, invalid: Bool = false) -> String {
      var rows = (1...count).map { #"    {"id": \#($0), "value": "row-\#($0)"}"# }
      if let firstRow = rows.first {
        rows[0] = "\(firstRow.prefix(5))\n      \(firstRow.dropFirst(5))"
      }
      return "{\n  \"rows\": [\n\(rows.joined(separator: ",\n"))\n  ]\(invalid ? "," : "")\n}\n"
    }
  }
#endif
