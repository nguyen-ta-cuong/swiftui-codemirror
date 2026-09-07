import AppKit
import Foundation
import WebKit
import XCTest

@testable import CodeMirror

final class HostedPhaseTrace {
  private let fileHandle: FileHandle?
  private let startTime = DispatchTime.now().uptimeNanoseconds

  init(suffix: String? = nil) {
    let environment = ProcessInfo.processInfo.environment
    guard
      let path = environment["NW_HOSTED_TRACE_PATH"]
        ?? environment["TEST_RUNNER_NW_HOSTED_TRACE_PATH"], !path.isEmpty
    else {
      fileHandle = nil
      return
    }

    let baseURL = URL(fileURLWithPath: path)
    let url: URL
    if let suffix, !suffix.isEmpty {
      let fileExtension = baseURL.pathExtension
      let stem = baseURL.deletingPathExtension().path
      let fileName =
        fileExtension.isEmpty
        ? "\(stem)-\(suffix)"
        : "\(stem)-\(suffix).\(fileExtension)"
      url = URL(fileURLWithPath: fileName)
    } else {
      url = baseURL
    }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data())
    fileHandle = try? FileHandle(forWritingTo: url)
  }

  deinit {
    try? fileHandle?.close()
  }

  @MainActor
  func record(
    _ event: String,
    window: NSWindow? = nil,
    details: [String: String] = [:],
    error: Error? = nil
  ) {
    guard let fileHandle else { return }

    var payload: [String: Any] = [
      "event": event,
      "elapsedMilliseconds":
        Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000,
      "mainThread": Thread.isMainThread,
      "appRunning": NSApp.isRunning,
      "appActive": NSApp.isActive,
      "activationPolicy": NSApp.activationPolicy().rawValue,
      "appWindowCount": NSApp.windows.count,
      "appKeyWindowPresent": NSApp.keyWindow != nil,
    ]
    if let window {
      payload["windowVisible"] = window.isVisible
      payload["windowKey"] = window.isKeyWindow
      payload["windowMain"] = window.isMainWindow
      payload["windowCanBecomeKey"] = window.canBecomeKey
      if let firstResponder = window.firstResponder {
        payload["windowFirstResponderType"] = String(reflecting: type(of: firstResponder))
      } else {
        payload["windowFirstResponderType"] = "nil"
      }
    }
    for (key, value) in details {
      payload["detail." + key] = value
    }
    if let error {
      let nsError = error as NSError
      payload["errorType"] = String(reflecting: type(of: error))
      payload["errorDomain"] = nsError.domain
      payload["errorCode"] = nsError.code
    }

    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
      return
    }
    try? fileHandle.write(contentsOf: data + Data([0x0A]))
    try? fileHandle.synchronize()
  }
}

@MainActor
final class HostedFocusTests: XCTestCase {
  private let phaseTrace = HostedPhaseTrace()

  func testHostedFocusTraversalDiagnosticsAndTeardown() async throws {
    phaseTrace.record("test.entry")
    phaseTrace.record("session.window.construction.begin")
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
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "CodeMirror Hosted Focus"
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

    phaseTrace.record("session.window.construction.end", window: window)
    phaseTrace.record("coordinator.inline.attach.before", window: window)
    inlineCoordinator.attach(webView: inlineWebView)
    phaseTrace.record("coordinator.inline.attach.after", window: window)
    phaseTrace.record("coordinator.detached.attach.before", window: window)
    detachedCoordinator.attach(webView: detachedWebView)
    phaseTrace.record("coordinator.detached.attach.after", window: window)
    defer {
      phaseTrace.record("defer.cleanup.begin", window: window)
      phaseTrace.record("defer.inline.detach.before", window: window)
      inlineCoordinator.detach()
      phaseTrace.record("defer.inline.detach.after", window: window)
      phaseTrace.record("defer.detached.detach.before", window: window)
      detachedCoordinator.detach()
      phaseTrace.record("defer.detached.detach.after", window: window)
      phaseTrace.record("defer.window.orderOut.before", window: window)
      window.orderOut(nil)
      phaseTrace.record("defer.window.orderOut.after", window: window)
      phaseTrace.record("defer.window.close.before", window: window)
      window.close()
      phaseTrace.record("defer.window.close.after", window: window)
      phaseTrace.record("defer.cleanup.end", window: window)
    }

    try await activateWithTrace(window, phase: "activate.initial")
    phaseTrace.record("focus.windowKey.assert.before", window: window)
    XCTAssertTrue(
      window.isKeyWindow,
      "host window did not become key (\(activationDiagnostics(for: window)))"
    )
    phaseTrace.record("focus.windowKey.assert.after", window: window)
    guard window.isKeyWindow else { return }
    phaseTrace.record("focus.inline.makeFirstResponder.before", window: window)
    let madeInlineFirstResponder = window.makeFirstResponder(inlineWebView)
    phaseTrace.record(
      "focus.inline.makeFirstResponder.after",
      window: window,
      details: ["accepted": String(madeInlineFirstResponder)]
    )
    phaseTrace.record("focus.inline.makeFirstResponder.assert.before", window: window)
    XCTAssertTrue(madeInlineFirstResponder)
    phaseTrace.record("focus.inline.makeFirstResponder.assert.after", window: window)
    phaseTrace.record("focus.inlineResponder.guard.before", window: window)
    guard window.firstResponder === inlineWebView else {
      phaseTrace.record("focus.inlineResponder.guard.failed", window: window)
      return
    }
    phaseTrace.record("focus.inlineResponder.guard.after", window: window)
    phaseTrace.record("focus.replica.assertions.before", window: window)
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)
    XCTAssertNotEqual(session.focusedReplicaID(), detachedReplicaID)
    phaseTrace.record("focus.replica.assertions.after", window: window)

    phaseTrace.record("coordinator.inline.loadID.before", window: window)
    guard let inlineLoadID = inlineCoordinator.attachedLoadID else {
      phaseTrace.record("coordinator.inline.loadID.missing", window: window)
      XCTFail("inline coordinator did not attach")
      return
    }
    phaseTrace.record("coordinator.inline.loadID.after", window: window)
    session.receive(
      .focusTraversal(
        sessionID: session.id,
        replicaID: inlineReplicaID,
        loadID: inlineLoadID,
        forward: true
      ))
    phaseTrace.record("focus.forward.assert.before", window: window)
    XCTAssertTrue(
      isFirstResponder(of: followingField, in: window),
      "forward responder was \(String(describing: window.firstResponder))"
    )
    phaseTrace.record("focus.forward.assert.after", window: window)

    phaseTrace.record("focus.backward.makeFirstResponder.before", window: window)
    let madeInlineForBackwardTraversal = window.makeFirstResponder(inlineWebView)
    phaseTrace.record(
      "focus.backward.makeFirstResponder.after",
      window: window,
      details: ["accepted": String(madeInlineForBackwardTraversal)]
    )
    phaseTrace.record("focus.backward.makeFirstResponder.assert.before", window: window)
    XCTAssertTrue(madeInlineForBackwardTraversal)
    phaseTrace.record("focus.backward.makeFirstResponder.assert.after", window: window)
    session.receive(
      .focusTraversal(
        sessionID: session.id,
        replicaID: inlineReplicaID,
        loadID: inlineLoadID,
        forward: false
      ))
    phaseTrace.record("focus.backward.assert.before", window: window)
    XCTAssertTrue(
      isFirstResponder(of: precedingField, in: window),
      "backward responder was \(String(describing: window.firstResponder))"
    )
    phaseTrace.record("focus.backward.assert.after", window: window)

    phaseTrace.record("focus.nativeField.makeFirstResponder.before", window: window)
    let madeFollowingFirstResponder = window.makeFirstResponder(followingField)
    phaseTrace.record(
      "focus.nativeField.makeFirstResponder.after",
      window: window,
      details: ["accepted": String(madeFollowingFirstResponder)]
    )
    phaseTrace.record("focus.nativeField.makeFirstResponder.assert.before", window: window)
    XCTAssertTrue(madeFollowingFirstResponder)
    phaseTrace.record("focus.nativeField.makeFirstResponder.assert.after", window: window)
    session.receive(
      .focusTraversal(
        sessionID: session.id,
        replicaID: inlineReplicaID,
        loadID: inlineLoadID,
        forward: true
      ))
    phaseTrace.record("focus.nativeField.assert.before", window: window)
    XCTAssertTrue(
      isFirstResponder(of: followingField, in: window),
      "native-field forward responder was \(String(describing: window.firstResponder))"
    )
    phaseTrace.record("focus.nativeField.assert.after", window: window)
    phaseTrace.record("focus.nativeField.replica.assert.before", window: window)
    XCTAssertNil(session.focusedReplicaID())
    phaseTrace.record("focus.nativeField.replica.assert.after", window: window)

    phaseTrace.record("focus.hiddenAncestor.makeFirstResponder.before", window: window)
    let madeInlineForHiddenAncestor = window.makeFirstResponder(inlineWebView)
    phaseTrace.record(
      "focus.hiddenAncestor.makeFirstResponder.after",
      window: window,
      details: ["accepted": String(madeInlineForHiddenAncestor)]
    )
    phaseTrace.record("focus.hiddenAncestor.makeFirstResponder.assert.before", window: window)
    XCTAssertTrue(madeInlineForHiddenAncestor)
    phaseTrace.record("focus.hiddenAncestor.makeFirstResponder.assert.after", window: window)
    container.isHidden = true
    phaseTrace.record("focus.hiddenAncestor.assert.before", window: window)
    XCTAssertNil(session.focusedReplicaID())
    phaseTrace.record("focus.hiddenAncestor.assert.after", window: window)
    container.isHidden = false
    phaseTrace.record("focus.hiddenAncestor.restore.makeFirstResponder.before", window: window)
    let madeInlineAfterHiddenAncestor = window.makeFirstResponder(inlineWebView)
    phaseTrace.record(
      "focus.hiddenAncestor.restore.makeFirstResponder.after",
      window: window,
      details: ["accepted": String(madeInlineAfterHiddenAncestor)]
    )
    phaseTrace.record(
      "focus.hiddenAncestor.restore.makeFirstResponder.assert.before", window: window)
    XCTAssertTrue(madeInlineAfterHiddenAncestor)
    phaseTrace.record(
      "focus.hiddenAncestor.restore.makeFirstResponder.assert.after", window: window)
    phaseTrace.record("focus.hiddenAncestor.restore.assert.before", window: window)
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)
    phaseTrace.record("focus.hiddenAncestor.restore.assert.after", window: window)

    phaseTrace.record("js.metrics.before", window: window)
    let diagnosticMetrics: DiagnosticMetrics
    do {
      diagnosticMetrics = try await waitForDiagnostics(
        inlineWebView,
        coordinator: inlineCoordinator
      )
      phaseTrace.record("js.metrics.after", window: window)
    } catch {
      phaseTrace.record("js.metrics.error", window: window, error: error)
      throw error
    }
    phaseTrace.record("diagnostics.assertions.before", window: window)
    XCTAssertFalse(diagnosticMetrics.panelHidden)
    XCTAssertGreaterThan(diagnosticMetrics.panelHeight, 0)
    XCTAssertLessThanOrEqual(diagnosticMetrics.editorBottom, diagnosticMetrics.panelTop + 1)
    XCTAssertLessThanOrEqual(diagnosticMetrics.lastLineBottom, diagnosticMetrics.scrollerBottom + 1)
    phaseTrace.record("diagnostics.assertions.after", window: window)

    phaseTrace.record("window.orderOut.before", window: window)
    window.orderOut(nil)
    phaseTrace.record("window.orderOut.after", window: window)
    phaseTrace.record("window.orderOut.wait.before", window: window)
    do {
      try await waitUntil("host window resigns after ordering out") {
        !window.isKeyWindow && session.focusedReplicaID() == nil
      }
      phaseTrace.record("window.orderOut.wait.after", window: window)
    } catch {
      phaseTrace.record("window.orderOut.wait.error", window: window, error: error)
      throw error
    }
    phaseTrace.record("window.orderOut.assert.before", window: window)
    XCTAssertNil(session.focusedReplicaID())
    phaseTrace.record("window.orderOut.assert.after", window: window)

    try await activateWithTrace(window, phase: "activate.reactivation")
    phaseTrace.record("focus.reactivation.windowKey.assert.before", window: window)
    XCTAssertTrue(window.isKeyWindow)
    phaseTrace.record("focus.reactivation.windowKey.assert.after", window: window)
    phaseTrace.record("focus.reactivation.makeFirstResponder.before", window: window)
    let madeInlineAfterReactivation = window.makeFirstResponder(inlineWebView)
    phaseTrace.record(
      "focus.reactivation.makeFirstResponder.after",
      window: window,
      details: ["accepted": String(madeInlineAfterReactivation)]
    )
    phaseTrace.record("focus.reactivation.makeFirstResponder.assert.before", window: window)
    XCTAssertTrue(madeInlineAfterReactivation)
    phaseTrace.record("focus.reactivation.makeFirstResponder.assert.after", window: window)
    phaseTrace.record("focus.reactivation.replica.assert.before", window: window)
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)
    phaseTrace.record("focus.reactivation.replica.assert.after", window: window)

    phaseTrace.record("detach.detached.before", window: window)
    detachedCoordinator.detach()
    phaseTrace.record("detach.detached.after", window: window)
    phaseTrace.record("detach.detachedReplica.assert.before", window: window)
    XCTAssertEqual(session.focusedReplicaID(), inlineReplicaID)
    phaseTrace.record("detach.detachedReplica.assert.after", window: window)
    phaseTrace.record("detach.inline.before", window: window)
    inlineCoordinator.detach()
    phaseTrace.record("detach.inline.after", window: window)
    phaseTrace.record("detach.inlineReplica.assert.before", window: window)
    XCTAssertNil(session.focusedReplicaID())
    phaseTrace.record("detach.inlineReplica.assert.after", window: window)
    phaseTrace.record("test.completed", window: window)
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
    private var continuation: CheckedContinuation<String, Error>?
    private var didFinish = false

    func start(_ continuation: CheckedContinuation<String, Error>) {
      self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
      guard !didFinish else { return }
      didFinish = true
      let continuation = continuation
      self.continuation = nil
      continuation?.resume(with: result)
    }
  }

  private func waitForDiagnostics(
    _ webView: WKWebView,
    coordinator: CodeMirrorEditorCoordinator
  ) async throws -> DiagnosticMetrics {
    phaseTrace.record(
      "ready.wait.before",
      window: webView.window,
      details: [
        "pageReady": String(coordinator.pageIsReady),
        "pageConfigured": String(coordinator.pageIsConfigured),
      ]
    )
    do {
      try await waitUntil("CodeMirror ready") { coordinator.pageIsReady }
      phaseTrace.record("ready.wait.after", window: webView.window)
    } catch {
      phaseTrace.record("ready.wait.error", window: webView.window, error: error)
      throw NSError(
        domain: "HostedFocusTests", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey:
            "CodeMirror page did not send ready (\(await pageDiagnostics(webView, coordinator: coordinator))); wait error: \(error)"
        ])
    }
    phaseTrace.record(
      "configured.wait.before",
      window: webView.window,
      details: ["pageConfigured": String(coordinator.pageIsConfigured)]
    )
    do {
      try await waitUntil("CodeMirror configure") { coordinator.pageIsConfigured }
      phaseTrace.record("configured.wait.after", window: webView.window)
    } catch {
      phaseTrace.record("configured.wait.error", window: webView.window, error: error)
      throw NSError(
        domain: "HostedFocusTests", code: 4,
        userInfo: [
          NSLocalizedDescriptionKey:
            "CodeMirror page did not complete configure (\(await pageDiagnostics(webView, coordinator: coordinator))); wait error: \(error)"
        ])
    }
    let value: String
    do {
      phaseTrace.record("js.metrics.evaluate.before", window: webView.window)
      value = try await evaluate(
        webView,
        """
        (async () => {
          const panel = document.querySelector('.cm-host-diagnostics');
          const editor = document.querySelector('.cm-editor');
          const scroller = document.querySelector('.cm-scroller');
          if (!panel || !editor || !scroller) {
            throw new Error('diagnostic layout elements are missing');
          }
          scroller.scrollTop = scroller.scrollHeight;
          await new Promise(resolve => requestAnimationFrame(resolve));
          await new Promise(resolve => requestAnimationFrame(resolve));
          await new Promise(resolve => setTimeout(resolve, 0));
          const lastLine = document.querySelector('.cm-line:last-child');
          if (!lastLine) {
            throw new Error('virtualized last line is missing after scroll settlement');
          }
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
      phaseTrace.record("js.metrics.evaluate.after", window: webView.window)
    } catch {
      phaseTrace.record("js.metrics.evaluate.error", window: webView.window, error: error)
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

  private func pageDiagnostics(
    _ webView: WKWebView,
    coordinator: CodeMirrorEditorCoordinator
  ) async -> String {
    let jsState: String
    do {
      jsState = try await evaluate(
        webView,
        """
        JSON.stringify({
          readyState: document.readyState,
          hasBody: Boolean(document.body),
          hasEditor: Boolean(document.querySelector('.cm-editor')),
          hasDiagnostics: Boolean(document.querySelector('.cm-host-diagnostics'))
        })
        """,
        timeoutNanoseconds: 1_000_000_000
      )
    } catch {
      jsState = "jsError=\(error)"
    }
    return
      "assetURL=\(webView.url?.absoluteString ?? "nil"), loading=\(webView.isLoading), title=\(webView.title ?? "nil"), pageReady=\(coordinator.pageIsReady), pageConfigured=\(coordinator.pageIsConfigured), \(jsState), launch=\(launchCompletionState())"
  }

  private func evaluate(
    _ webView: WKWebView,
    _ script: String,
    timeoutNanoseconds: UInt64 = 5_000_000_000
  ) async throws -> String {
    let evaluation = JavaScriptEvaluation()
    let functionBody = "return await (\n" + script + "\n);"
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<String, Error>) in
      evaluation.start(continuation)
      webView.callAsyncJavaScript(
        functionBody,
        arguments: [:],
        in: nil,
        in: .page
      ) { result in
        Task { @MainActor in
          switch result {
          case .success(let value):
            if let value = value as? String {
              evaluation.finish(.success(value))
            } else {
              evaluation.finish(
                .failure(NSError(domain: "HostedFocusTests", code: 2)))
            }
          case .failure(let error):
            evaluation.finish(.failure(error))
          }
        }
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        evaluation.finish(
          .failure(
            NSError(
              domain: "HostedFocusTests", code: 6,
              userInfo: [
                NSLocalizedDescriptionKey: "JavaScript evaluation callback timed out"
              ])))
      }
    }
  }

  private func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: @escaping () -> Bool
  ) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
    while !condition() {
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw NSError(
          domain: "HostedFocusTests", code: 7,
          userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for \(description)"
          ])
      }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
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
    return CodeMirrorWebView(frame: frame, configuration: configuration)
  }

  private func activateWithTrace(_ window: NSWindow, phase: String) async throws {
    phaseTrace.record(phase + ".before", window: window)
    do {
      try await activate(window)
      phaseTrace.record(phase + ".after", window: window)
    } catch {
      phaseTrace.record(phase + ".error", window: window, error: error)
      throw error
    }
  }

  private func activate(_ window: NSWindow) async throws {
    let before = activationDiagnostics(for: window)
    let policyResult = NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    let activationResult = NSRunningApplication.current.activate(options: [
      .activateAllWindows, .activateIgnoringOtherApps,
    ])
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    do {
      try await waitUntil("ordinary host window activation") {
        NSApp.isActive && window.isVisible && window.isKeyWindow
      }
    } catch {
      throw NSError(
        domain: "HostedFocusTests",
        code: 8,
        userInfo: [
          NSLocalizedDescriptionKey:
            "ordinary host window activation failed (setActivationPolicy.regular=\(policyResult), runningApplication.activate=\(activationResult), before=\(before), after=\(activationDiagnostics(for: window)), wait error=\(error)"
        ])
    }
  }

  private func activationDiagnostics(for window: NSWindow) -> String {
    let windows = NSApp.windows.map { candidate in
      "title=\(candidate.title.isEmpty ? "<untitled>" : candidate.title),visible=\(candidate.isVisible),key=\(candidate.isKeyWindow),main=\(candidate.isMainWindow)"
    }.joined(separator: ";")
    return
      "running=\(NSApp.isRunning),active=\(NSApp.isActive),policy=\(NSApp.activationPolicy().rawValue),runningPolicy=\(NSRunningApplication.current.activationPolicy.rawValue),canBecomeKey=\(window.canBecomeKey),visible=\(window.isVisible),key=\(window.isKeyWindow),keyWindow=\(NSApp.keyWindow?.title ?? "nil"),windows=[\(windows)],delegate=\(String(describing: NSApp.delegate)),launch=\(launchCompletionState())"
  }

  private func launchCompletionState() -> String {
    guard let delegate = NSApp.delegate as? NSObject else { return "unavailable" }
    let selector = NSSelectorFromString("didFinishLaunching")
    guard delegate.responds(to: selector) else { return "unreported" }
    return String(describing: delegate.value(forKey: "didFinishLaunching"))
  }
}
