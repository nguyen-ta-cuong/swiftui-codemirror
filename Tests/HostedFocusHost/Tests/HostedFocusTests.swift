import AppKit
import WebKit
import XCTest

@testable import CodeMirror

@MainActor
private final class HostedFocusApplicationDelegate: NSObject, NSApplicationDelegate {}

@MainActor
final class HostedFocusTests: XCTestCase {
  private var applicationDelegate: HostedFocusApplicationDelegate?

  func testHostedFocusTraversalDiagnosticsAndTeardown() throws {
    NSApp.setActivationPolicy(.regular)

    let source =
      "{\n" + String(repeating: "  \"line\": 1,\n", count: 100)
      + "  \"unterminated\": "
    let session = CodeMirrorSession(
      initialText: source,
      configuration: CodeMirrorConfiguration(language: .json)
    ) { _ in .accept }
    let inlineReplicaID = CodeMirrorReplicaID()
    let detachedReplicaID = CodeMirrorReplicaID()
    let inlineCoordinator = CodeMirrorEditorCoordinator(
      session: session, replicaID: inlineReplicaID)
    let detachedCoordinator = CodeMirrorEditorCoordinator(
      session: session, replicaID: detachedReplicaID)
    let inlineWebView = makeWebView(
      for: inlineCoordinator, frame: NSRect(x: 0, y: 0, width: 640, height: 420))
    let detachedWebView = makeWebView(
      for: detachedCoordinator, frame: NSRect(x: 0, y: 0, width: 640, height: 420))
    let precedingField = NSTextField(frame: NSRect(x: 12, y: 12, width: 220, height: 24))
    let followingField = NSTextField(frame: NSRect(x: 12, y: 48, width: 220, height: 24))
    precedingField.stringValue = "Before editor"
    followingField.stringValue = "After editor"
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    let window = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.becomesKeyOnlyIfNeeded = false
    window.contentView = container
    container.addSubview(precedingField)
    container.addSubview(inlineWebView)
    container.addSubview(followingField)
    inlineWebView.frame = NSRect(x: 0, y: 80, width: 640, height: 380)
    precedingField.nextKeyView = inlineWebView
    inlineWebView.nextKeyView = followingField
    followingField.nextKeyView = precedingField
    window.initialFirstResponder = precedingField
    window.recalculateKeyViewLoop()
    inlineCoordinator.attach(webView: inlineWebView)
    detachedCoordinator.attach(webView: detachedWebView)
    defer {
      inlineCoordinator.detach()
      detachedCoordinator.detach()
      window.orderOut(nil)
      window.close()
    }

    activate(window)
    let frontmostApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
    let delegateDescription = String(describing: NSApp.delegate)
    XCTAssertTrue(
      window.isKeyWindow,
      "host window did not become key (app active: \(NSApp.isActive), policy: \(NSApp.activationPolicy().rawValue), running policy: \(NSRunningApplication.current.activationPolicy.rawValue), frontmost: \(frontmostApplication), delegate: \(delegateDescription))"
    )
    guard window.isKeyWindow else { return }
    XCTAssertTrue(window.makeFirstResponder(inlineWebView))
    guard window.firstResponder === inlineWebView else { return }
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)
    XCTAssertNotEqual(session.focusedReplicaID(), detachedReplicaID)

    guard let inlineLoadID = inlineCoordinator.attachedLoadID else {
      XCTFail("inline coordinator did not attach")
      return
    }
    session.receive(
      .focusTraversal(
        sessionID: session.id,
        replicaID: inlineReplicaID,
        loadID: inlineLoadID,
        forward: true
      ))
    XCTAssertTrue(
      isFirstResponder(of: followingField, in: window),
      "forward responder was \(String(describing: window.firstResponder))"
    )

    XCTAssertTrue(window.makeFirstResponder(inlineWebView))
    session.receive(
      .focusTraversal(
        sessionID: session.id,
        replicaID: inlineReplicaID,
        loadID: inlineLoadID,
        forward: false
      ))
    XCTAssertTrue(
      isFirstResponder(of: precedingField, in: window),
      "backward responder was \(String(describing: window.firstResponder))"
    )

    XCTAssertTrue(window.makeFirstResponder(followingField))
    session.receive(
      .focusTraversal(
        sessionID: session.id,
        replicaID: inlineReplicaID,
        loadID: inlineLoadID,
        forward: true
      ))
    XCTAssertTrue(
      isFirstResponder(of: followingField, in: window),
      "native-field forward responder was \(String(describing: window.firstResponder))"
    )
    XCTAssertNil(session.focusedReplicaID())

    XCTAssertTrue(window.makeFirstResponder(inlineWebView))
    container.isHidden = true
    XCTAssertNil(session.focusedReplicaID())
    container.isHidden = false
    XCTAssertTrue(window.makeFirstResponder(inlineWebView))
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)

    let diagnosticMetrics = try waitForDiagnostics(
      inlineWebView,
      coordinator: inlineCoordinator
    )
    XCTAssertFalse(diagnosticMetrics.panelHidden)
    XCTAssertGreaterThan(diagnosticMetrics.panelHeight, 0)
    XCTAssertLessThanOrEqual(diagnosticMetrics.editorBottom, diagnosticMetrics.panelTop + 1)
    XCTAssertLessThanOrEqual(diagnosticMetrics.lastLineBottom, diagnosticMetrics.scrollerBottom + 1)

    window.orderOut(nil)
    runLoop(for: 0.1)
    XCTAssertNil(session.focusedReplicaID())

    activate(window)
    XCTAssertTrue(window.isKeyWindow)
    XCTAssertTrue(window.makeFirstResponder(inlineWebView))
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)

    detachedCoordinator.detach()
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)
    inlineCoordinator.detach()
    XCTAssertNil(session.focusedReplicaID())
  }

  private struct DiagnosticMetrics: Decodable {
    let panelHidden: Bool
    let panelHeight: Double
    let panelTop: Double
    let editorBottom: Double
    let lastLineBottom: Double
    let scrollerBottom: Double
  }

  @MainActor
  private final class JavaScriptEvaluation {
    var result: Result<String, Error>?
  }

  private func waitForDiagnostics(
    _ webView: WKWebView,
    coordinator: CodeMirrorEditorCoordinator
  ) throws -> DiagnosticMetrics {
    for _ in 0..<200 {
      runLoop(for: 0.025)
      if coordinator.pageIsReady {
        break
      }
    }
    guard coordinator.pageIsReady else {
      throw NSError(
        domain: "HostedFocusTests", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "CodeMirror page did not send ready"
        ])
    }
    for _ in 0..<200 {
      runLoop(for: 0.025)
      if coordinator.pageIsConfigured {
        break
      }
    }
    guard coordinator.pageIsConfigured else {
      throw NSError(
        domain: "HostedFocusTests", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: "CodeMirror page did not complete configure"
        ])
    }
    let value: String
    do {
      value = try evaluate(
        webView,
        """
        (() => {
          const panel = document.querySelector('.cm-host-diagnostics');
          const editor = document.querySelector('.cm-editor');
          const scroller = document.querySelector('.cm-scroller');
          const lastLine = document.querySelector('.cm-line:last-child');
          scroller.scrollTop = scroller.scrollHeight;
          const panelRect = panel.getBoundingClientRect();
          const editorRect = editor.getBoundingClientRect();
          const lastLineRect = lastLine.getBoundingClientRect();
          const scrollerRect = scroller.getBoundingClientRect();
          return JSON.stringify({
            panelHidden: panel.hidden,
            panelHeight: panelRect.height,
            panelTop: panelRect.top,
            editorBottom: editorRect.bottom,
            lastLineBottom: lastLineRect.bottom,
            scrollerBottom: scrollerRect.bottom
          });
        })()
        """
      )
    } catch {
      throw NSError(
        domain: "HostedFocusTests",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "diagnostic evaluation failed: \(error)"]
      )
    }
    guard let data = value.data(using: .utf8) else {
      throw NSError(domain: "HostedFocusTests", code: 1)
    }
    return try JSONDecoder().decode(DiagnosticMetrics.self, from: data)
  }

  private func evaluate(_ webView: WKWebView, _ script: String) throws -> String {
    let evaluation = JavaScriptEvaluation()
    webView.evaluateJavaScript(script) { value, error in
      Task { @MainActor in
        if let error {
          evaluation.result = .failure(error)
        } else if let value = value as? String {
          evaluation.result = .success(value)
        } else {
          evaluation.result = .failure(NSError(domain: "HostedFocusTests", code: 2))
        }
      }
    }
    let deadline = Date(timeIntervalSinceNow: 5)
    while evaluation.result == nil, Date() < deadline {
      RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.025)))
    }
    guard let result = evaluation.result else {
      throw NSError(
        domain: "HostedFocusTests", code: 6,
        userInfo: [
          NSLocalizedDescriptionKey: "JavaScript evaluation callback timed out"
        ])
    }
    return try result.get()
  }

  private func runLoop(for interval: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
  }

  private func isFirstResponder(of field: NSTextField, in window: NSWindow) -> Bool {
    window.firstResponder === field || window.firstResponder === field.currentEditor()
  }

  private func makeWebView(
    for coordinator: CodeMirrorEditorCoordinator, frame: NSRect
  ) -> WKWebView {
    let contentController = WKUserContentController()
    contentController.add(coordinator, name: CodeMirrorEditorCoordinator.messageHandlerName)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = contentController
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return WKWebView(frame: frame, configuration: configuration)
  }

  private func activate(_ window: NSWindow) {
    window.level = .floating
    if NSApp.delegate == nil {
      applicationDelegate = HostedFocusApplicationDelegate()
      NSApp.delegate = applicationDelegate
    }
    NSApp.finishLaunching()
    if !NSApp.setActivationPolicy(.regular) {
      _ = NSApp.setActivationPolicy(.accessory)
    }
    NSApp.unhide(nil)
    NSRunningApplication.current.activate(options: [
      .activateAllWindows, .activateIgnoringOtherApps,
    ])
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    for _ in 0..<20 where !window.isKeyWindow {
      NSRunningApplication.current.activate(options: [
        .activateAllWindows, .activateIgnoringOtherApps,
      ])
      window.makeKey()
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
      runLoop(for: 0.05)
    }
  }
}
