import Foundation
import XCTest

@testable import CodeMirror

#if os(macOS) && canImport(AppKit) && canImport(WebKit)
  import AppKit
  import WebKit

  internal struct RenderedHeightMetrics: Decodable {
    let lineHeight: Double
    let naturalHeight: Double
    let width: Double
    let diagnosticsHeight: Double
    let documentPadding: Double
  }

  internal struct RenderedRowVisibility: Decodable {
    let scrollerTop: Double?
    let scrollerBottom: Double?
    let row10Top: Double?
    let row10Bottom: Double?
    let row11Top: Double?
    let row11Bottom: Double?

    var scrollerHeight: Double? {
      guard let scrollerTop, let scrollerBottom else { return nil }
      return scrollerBottom - scrollerTop
    }

    var row10FullyVisible: Bool {
      guard
        let scrollerTop,
        let scrollerBottom,
        let row10Top,
        let row10Bottom
      else { return false }
      return row10Top >= scrollerTop - 2 && row10Bottom <= scrollerBottom + 2
    }

    var row11FullyVisible: Bool {
      guard
        let scrollerTop,
        let scrollerBottom,
        let row11Top,
        let row11Bottom
      else { return false }
      return row11Top >= scrollerTop - 2 && row11Bottom <= scrollerBottom + 2
    }
  }

  internal struct RenderedLayoutMetrics: Decodable {
    let lineHeight: Double
    let naturalHeight: Double
  }

  @MainActor
  extension CodeMirrorHeightHarness {
    func metrics() async throws -> RenderedHeightMetrics {
      let value = try await evaluateString(
        """
        JSON.stringify((() => {
          const scroll = document.querySelector(".cm-scroller");
          const content = document.querySelector(".cm-content");
          const lines = [...document.querySelectorAll(".cm-line")];
          const line = lines[0] ?? content;
          const diagnostics = document.querySelector(".cm-host-diagnostics");
          const view = globalThis.__codeMirrorHeightProbe?.controller()?.view;
          const rectHeight = element => Number(element?.getBoundingClientRect?.().height ?? 0);
          const lineHeight = Number(view?.defaultLineHeight);
          const paddingTop = Number(view?.documentPadding?.top ?? 0);
          const paddingBottom = Number(view?.documentPadding?.bottom ?? 0);
          const rects = lines.map(element => element.getBoundingClientRect());
          const minTop = rects.length ? Math.min(...rects.map(rect => rect.top)) : 0;
          const maxBottom = rects.length ? Math.max(...rects.map(rect => rect.bottom)) : 0;
          const naturalHeight = Math.max(0, maxBottom - minTop + paddingTop + paddingBottom);
          return {
            lineHeight: Number.isFinite(lineHeight) && lineHeight > 0
              ? lineHeight
              : rectHeight(line),
            naturalHeight,
            width: Number(scroll?.getBoundingClientRect?.().width ?? 0),
            diagnosticsHeight: diagnostics && !diagnostics.hidden ? rectHeight(diagnostics) : 0,
            documentPadding: Number(view?.documentPadding?.top ?? 0)
              + Number(view?.documentPadding?.bottom ?? 0)
          };
        })())
        """
      )
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorHeightTests", code: 2)
      }
      return try JSONDecoder().decode(RenderedHeightMetrics.self, from: data)
    }

    func layout() async throws -> RenderedLayoutMetrics {
      let value = try await evaluateString(
        """
        JSON.stringify((() => {
          const content = document.querySelector(".cm-content");
          const lines = [...document.querySelectorAll(".cm-line")];
          const line = lines[0] ?? content;
          const view = globalThis.__codeMirrorHeightProbe?.controller()?.view;
          const lineHeight = Number(view?.defaultLineHeight);
          const paddingTop = Number(view?.documentPadding?.top ?? 0);
          const paddingBottom = Number(view?.documentPadding?.bottom ?? 0);
          const rects = lines.map(element => element.getBoundingClientRect());
          const minTop = rects.length ? Math.min(...rects.map(rect => rect.top)) : 0;
          const maxBottom = rects.length ? Math.max(...rects.map(rect => rect.bottom)) : 0;
          const naturalHeight = Math.max(0, maxBottom - minTop + paddingTop + paddingBottom);
          return {
            lineHeight: Number.isFinite(lineHeight) && lineHeight > 0
              ? lineHeight : Number(line?.getBoundingClientRect?.().height ?? 0),
            naturalHeight
          };
        })())
        """
      )
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorHeightTests", code: 7)
      }
      return try JSONDecoder().decode(RenderedLayoutMetrics.self, from: data)
    }

    func waitForAcceptedHeight(
      minimumRows: Int,
      maximumRows: Int
    ) async throws -> RenderedHeightMetrics {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          let diagnostics = await timeoutDiagnostics()
          throw NSError(
            domain: "CodeMirrorEditorHeightTests",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: diagnostics]
          )
        }
        let metrics = try await metrics()
        guard
          metrics.lineHeight > 0,
          metrics.naturalHeight >= 0,
          metrics.documentPadding.isFinite,
          metrics.documentPadding >= 0
        else {
          try await Task.sleep(nanoseconds: 25_000_000)
          continue
        }
        let contentHeight = max(0, metrics.naturalHeight - metrics.documentPadding)
        let naturalRows = contentHeight / metrics.lineHeight
        let rows = min(Double(maximumRows), max(Double(minimumRows), naturalRows))
        let expected =
          rows * metrics.lineHeight
          + metrics.documentPadding + metrics.diagnosticsHeight
        let matchesExpectedHeight =
          coordinator.intrinsicHeight.map {
            abs(Double($0) - expected) <= 2
          } ?? false
        if matchesExpectedHeight {
          return metrics
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    func waitForRenderedRows(at height: Double) async throws -> RenderedRowVisibility {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        window.setContentSize(NSSize(width: webView.frame.width, height: height))
        webView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let rows = try? await renderedRows(), let scrollerHeight = rows.scrollerHeight {
          let hasRequiredRows =
            rows.row10Top != nil && rows.row10Bottom != nil
            && rows.row11Top != nil && rows.row11Bottom != nil
          if scrollerHeight >= height - 2 && hasRequiredRows {
            return rows
          }
        }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          let diagnostics = await timeoutDiagnostics()
          throw NSError(
            domain: "CodeMirrorEditorHeightTests",
            code: 15,
            userInfo: [NSLocalizedDescriptionKey: diagnostics]
          )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    private func renderedRows() async throws -> RenderedRowVisibility {
      let value = try await evaluateString(
        """
        JSON.stringify((() => {
          const scroll = document.querySelector(".cm-scroller");
          const lines = [...document.querySelectorAll(".cm-line")];
          const rect = element => {
            const value = element?.getBoundingClientRect?.();
            return value ? {top: value.top, bottom: value.bottom} : null;
          };
          const scrollRect = rect(scroll);
          const row10 = rect(lines[9]);
          const row11 = rect(lines[10]);
          return {
            scrollerTop: scrollRect?.top ?? null,
            scrollerBottom: scrollRect?.bottom ?? null,
            row10Top: row10?.top ?? null,
            row10Bottom: row10?.bottom ?? null,
            row11Top: row11?.top ?? null,
            row11Bottom: row11?.bottom ?? null
          };
        })())
        """
      )
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorHeightTests", code: 16)
      }
      return try JSONDecoder().decode(RenderedRowVisibility.self, from: data)
    }
  }

  extension CodeMirrorEditorHeightTests {
    func assertAcceptedRows(_ metrics: RenderedHeightMetrics, height: Double) {
      XCTAssertEqual(
        (height - metrics.diagnosticsHeight - metrics.documentPadding) / metrics.lineHeight,
        max(
          3,
          min(10, max(0, metrics.naturalHeight - metrics.documentPadding) / metrics.lineHeight)
        ),
        accuracy: 0.25
      )
    }

    @MainActor
    func assertWrappedHeight(
      session: CodeMirrorSession,
      harness: CodeMirrorHeightHarness
    ) async throws {
      let wrapped = String(repeating: "wrapped-value ", count: 160)
      harness.window.setContentSize(NSSize(width: 360, height: 500))
      _ = try await session.replace(text: wrapped, preservingSelections: false)
      try await harness.waitForText(wrapped)
      let wide = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      harness.window.setContentSize(NSSize(width: 160, height: 500))
      let narrow = try await harness.waitForAcceptedHeight(minimumRows: 3, maximumRows: 10)
      XCTAssertLessThan(narrow.width, wide.width)
      XCTAssertGreaterThan(narrow.naturalHeight, wide.naturalHeight)
    }

    @MainActor
    func testCoordinatorRetiresContentSizeAfterDetach() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let harness = try CodeMirrorHeightHarness(
        session: session,
        replicaID: replicaID,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10)
      )
      defer { harness.close() }
      try await harness.waitForConfigured()
      let loadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let measurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)
      harness.coordinator.detach()
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        measurementID: measurementID,
        height: 120
      )
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      XCTAssertNil(harness.coordinator.currentHeightMeasurementID)
      XCTAssertNil(harness.coordinator.attachedLoadID)
    }

    @MainActor
    func testCoordinatorRetiresContentSizeAfterReload() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let harness = try CodeMirrorHeightHarness(
        session: session,
        replicaID: replicaID,
        heightPolicy: .contentSized(minimumVisibleRows: 3, maximumVisibleRows: 10)
      )
      defer { harness.close() }
      try await harness.waitForConfigured()
      let oldLoadID = try XCTUnwrap(harness.coordinator.attachedLoadID)
      let oldMeasurementID = try XCTUnwrap(harness.coordinator.currentHeightMeasurementID)

      harness.coordinator.webView(harness.webView, didStartProvisionalNavigation: nil)
      XCTAssertNil(harness.coordinator.currentHeightMeasurementID)
      XCTAssertNil(harness.coordinator.intrinsicHeight)
      harness.coordinator.receiveContentSize(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: oldLoadID,
        measurementID: oldMeasurementID,
        height: 120
      )
      XCTAssertNil(harness.coordinator.intrinsicHeight)
    }
  }
#endif
