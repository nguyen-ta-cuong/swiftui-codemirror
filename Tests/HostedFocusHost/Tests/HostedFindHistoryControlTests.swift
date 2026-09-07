import AppKit
import CodeMirrorHostedFocusHost
import Foundation
import WebKit
import XCTest

@testable import CodeMirror

@MainActor
final class HostedFindHistoryControlTests: XCTestCase {
  private struct KeyStroke {
    let characters: String
    let charactersIgnoringModifiers: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
  }

  private final class Evaluation {
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false

    func start(_ continuation: CheckedContinuation<String, Error>) {
      self.continuation = continuation
    }

    func finish(_ result: Result<String, Error>) {
      guard !finished else { return }
      finished = true
      let continuation = self.continuation
      self.continuation = nil
      continuation?.resume(with: result)
    }
  }

  @MainActor
  private final class DocumentUndoProbe {
    let manager = UndoManager()
    private let target = NSObject()
    private(set) var invocationCount = 0

    func seed() {
      manager.registerUndo(withTarget: target) { [weak self] _ in
        self?.invocationCount += 1
      }
      manager.setActionName("Document Edit")
    }
  }

  @MainActor
  private final class CommandWindow: NSWindow {
    private let ownerUndoManager: UndoManager

    init(contentRect: NSRect, undoManager: UndoManager) {
      ownerUndoManager = undoManager
      super.init(
        contentRect: contentRect,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      isReleasedWhenClosed = false
      title = "Find Isolation Control"
    }

    override var undoManager: UndoManager? {
      ownerUndoManager
    }
  }

  private static let insertFind = KeyStroke(
    characters: "q",
    charactersIgnoringModifiers: "q",
    keyCode: 12,
    modifiers: []
  )
  private static let commandUndo = KeyStroke(
    characters: "z",
    charactersIgnoringModifiers: "z",
    keyCode: 6,
    modifiers: [.command]
  )
  private static let commandRedo = KeyStroke(
    characters: "Z",
    charactersIgnoringModifiers: "Z",
    keyCode: 6,
    modifiers: [.command, .shift]
  )

  func testFindHistoryUsesLocalWebViewHistoryWithoutNativeRegistration() async throws {
    guard let traceURL = traceURL(suffix: "find-isolation") else {
      XCTFail("NW_HOSTED_TRACE_PATH is required for Find isolation evidence")
      return
    }
    let trace = HostedPhaseTrace(suffix: "find-isolation")
    trace.record(
      "test.entry",
      details: ["test": "testFindHistoryUsesLocalWebViewHistoryWithoutNativeRegistration"])
    guard
      FileManager.default.fileExists(atPath: traceURL.path),
      let traceContents = try? String(contentsOf: traceURL, encoding: .utf8),
      traceContents.contains("\"event\":\"test.entry\"")
    else {
      XCTFail("hosted trace entry was not written to (traceURL.path)")
      return
    }
    guard let application = NSApp as? HostedFocusHostApplication else {
      XCTFail("host application did not use HostedFocusHostApplication")
      return
    }

    let source = "controlled editor source"
    let undoProbe = DocumentUndoProbe()
    undoProbe.seed()
    var hostCommandCount = 0
    var routeResults: [CodeMirrorCommandRoutingResult] = []
    let session = CodeMirrorSession(initialText: source) { event in
      if case .command = event {
        hostCommandCount += 1
      }
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
    let webView = makeWebView(for: coordinator)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
    container.addSubview(webView)
    webView.frame = container.bounds
    let window = CommandWindow(
      contentRect: NSRect(x: 100, y: 100, width: 720, height: 420),
      undoManager: undoProbe.manager
    )
    window.contentView = container
    let router = HostedCommandRouter(
      session: session,
      replicaID: replicaID,
      window: window,
      undoManager: undoProbe.manager
    )
    router.onResult = { result in
      routeResults.append(result)
      trace.record("router.result", window: window, details: ["result": result.rawValue])
    }
    router.onError = { error in
      trace.record("router.error", window: window, error: error)
    }
    application.commandRouterRegistry.register(router, for: window)
    let menu = installEditMenu()
    let previousMenu = NSApp.mainMenu
    NSApp.mainMenu = menu.menu
    trace.record("session.window.construction.after", window: window)
    coordinator.attach(webView: webView)
    trace.record("coordinator.attach.after", window: window)
    defer {
      trace.record("cleanup.begin", window: window)
      coordinator.detach()
      application.commandRouterRegistry.unregister(for: window)
      window.orderOut(nil)
      window.close()
      NSApp.mainMenu = previousMenu
      trace.record("cleanup.end", window: window)
    }

    XCTAssertNil(webView.undoManager)
    XCTAssertTrue(window.undoManager === undoProbe.manager)
    XCTAssertTrue(router.undoManager === undoProbe.manager)

    try await waitUntil("CodeMirror ready and configured") {
      coordinator.pageIsReady && coordinator.pageIsConfigured
    }
    trace.record("ready.configured.after", window: window)
    try await activate(window, trace: trace)
    XCTAssertTrue(window.makeFirstResponder(webView))
    try await waitUntil("WebView native focus") { window.firstResponder === webView }
    try await session.showFind(in: replicaID)
    _ = try await waitForDOMValue(
      webView,
      script:
        "(() => { const input = document.querySelector('.cm-search input'); input?.focus(); return String(document.activeElement === input); })()",
      equals: "true"
    )
    try await waitUntil("Find command context") {
      if case .find(let context) = session.focusedCommandContext() {
        return context.replicaID == replicaID
      }
      return false
    }
    trace.record("find.focus.after", window: window)

    trace.record("find.input-order.install.before", window: window)
    try await installFindInputOrderProbe(webView)
    trace.record("find.input-order.install.after", window: window)
    send(Self.insertFind, to: window, trace: trace, phase: "find.insert")
    _ = try await waitForDOMValue(
      webView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    trace.record("find.input-order.export.before", window: window)
    do {
      let inputOrder = try await collectFindInputOrderProbe(webView)
      var details = [
        "inputOrderJSON": inputOrder,
        "findContextSource": "native session presentation snapshot",
        "findContextID": "unavailable",
        "undoSupported": "unavailable",
        "undoEnabled": "unavailable",
        "jsLiveContextID": "unavailable: controller instance is not exposed",
        "pendingGeneration": "unavailable: controller instance is not exposed",
        "pendingPresent": "unavailable: controller instance is not exposed",
        "retainedCurrentValue": "unavailable: controller instance is not exposed",
      ]
      if case .find(let context) = session.focusedCommandContext() {
        details["findContextID"] = context.id.rawValue.uuidString
        details["undoSupported"] = String(context.undo.isSupported)
        details["undoEnabled"] = String(context.undo.isEnabled)
      }
      trace.record("find.input-order.export.after", window: window, details: details)
    } catch {
      trace.record("find.input-order.export.error", window: window, error: error)
      throw error
    }
    let sourceAfterFind = try session.snapshot()
    XCTAssertEqual(sourceAfterFind.text, source)
    XCTAssertEqual(hostCommandCount, 0)
    XCTAssertTrue(undoProbe.manager.canUndo)
    let documentActionName = undoProbe.manager.undoMenuItemTitle
    let editMenu = menu.undoItem.menu
    XCTAssertNotNil(editMenu)
    editMenu?.update()
    XCTAssertTrue(menu.undoItem.isEnabled)
    guard
      let retainedFindTarget = NSApp.target(
        forAction: #selector(HostedCommandRouter.undo(_:)),
        to: nil,
        from: menu.undoItem
      )
    else {
      XCTFail("Find target was not registered in the native menu route")
      return
    }
    trace.record(
      "find.target.captured",
      window: window,
      details: ["targetType": String(reflecting: type(of: retainedFindTarget))]
    )
    XCTAssertFalse(retainedFindTarget is HostedCommandRouter)

    send(Self.commandUndo, to: window, trace: trace, phase: "find.raw.undo")
    _ = try await waitForDOMValue(
      webView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: ""
    )
    try await waitUntil("Find raw Undo settles") {
      hostCommandCount == 0 && routeResults.isEmpty
    }
    XCTAssertEqual(try session.snapshot().text, source)
    XCTAssertEqual(hostCommandCount, 0)
    XCTAssertEqual(undoProbe.invocationCount, 0)
    XCTAssertTrue(undoProbe.manager.canUndo)
    XCTAssertEqual(undoProbe.manager.undoMenuItemTitle, documentActionName)
    editMenu?.update()
    XCTAssertFalse(menu.undoItem.isEnabled)

    send(Self.commandUndo, to: window, trace: trace, phase: "find.raw.empty.undo")
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(try session.snapshot().text, source)
    XCTAssertEqual(hostCommandCount, 0)
    XCTAssertEqual(undoProbe.invocationCount, 0)
    XCTAssertTrue(undoProbe.manager.canUndo)

    let sent = NSApp.sendAction(
      #selector(HostedCommandRouter.undo(_:)),
      to: retainedFindTarget,
      from: menu.undoItem
    )
    XCTAssertTrue(sent)
    try await waitUntil("retained Find target result") { routeResults.count == 1 }
    XCTAssertEqual(routeResults, [.unavailable])
    XCTAssertEqual(try session.snapshot().text, source)
    XCTAssertEqual(hostCommandCount, 0)
    XCTAssertEqual(undoProbe.invocationCount, 0)
    XCTAssertTrue(undoProbe.manager.canUndo)

    send(Self.commandRedo, to: window, trace: trace, phase: "find.raw.empty.redo")
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(try session.snapshot().text, source)
    XCTAssertEqual(hostCommandCount, 0)
    trace.record(
      "find.isolation.after",
      window: window,
      details: [
        "webViewUndoManager": webView.undoManager == nil ? "nil" : "present",
        "windowUndoManager": window.undoManager === undoProbe.manager ? "owner" : "other",
        "routerUndoManager": router.undoManager === undoProbe.manager ? "owner" : "other",
        "ownerInvocationCount": String(undoProbe.invocationCount),
        "hostCommandCount": String(hostCommandCount),
        "routeResultCount": String(routeResults.count),
      ])
  }

  private func installFindInputOrderProbe(_ webView: WKWebView) async throws {
    let installed = try await evaluateString(
      webView,
      script: """
        (() => {
          const input = document.querySelector('.cm-search input');
          if (!input || document.activeElement !== input) throw new Error('Find input is not focused');
          if (globalThis.__hostedFindInputOrderProbe) throw new Error('Find order probe already installed');
          const entries = [];
          const timers = new Set();
          let sequence = 0;
          let beforeInputCount = 0;
          let dropped = 0;
          let active = true;
          const record = (phase, metadata) => {
            if (!active) return;
            if (entries.length >= 32) { dropped += 1; return; }
            entries.push({
              sequence: ++sequence, phase, ...metadata,
              currentDOMValue: input.value.slice(0, 64),
              currentDOMValueUTF16Length: input.value.length,
              exactInputFocused: document.activeElement === input
            });
          };
          const observe = event => {
            if (event.target !== input || document.activeElement !== input) return;
            const metadata = {
              eventSequence: sequence + 1,
              inputType: String(event.inputType || '').slice(0, 64),
              isTrusted: event.isTrusted,
              defaultPrevented: event.defaultPrevented
            };
            record(event.type, metadata);
            if (event.type !== 'beforeinput' || ++beforeInputCount > 8) return;
            queueMicrotask(() => record('beforeinput.microtask', metadata));
            const timer = setTimeout(() => {
              timers.delete(timer);
              record('beforeinput.timer', metadata);
            }, 0);
            timers.add(timer);
          };
          document.addEventListener('beforeinput', observe, { capture: true, passive: true });
          document.addEventListener('input', observe, { capture: true, passive: true });
          globalThis.__hostedFindInputOrderProbe = {
            collect() {
              return JSON.stringify({
                entries, dropped, pendingTimerCount: timers.size,
                currentDOMValue: input.value.slice(0, 64),
                currentDOMValueUTF16Length: input.value.length,
                exactInputFocused: document.activeElement === input
              });
            },
            dispose() {
              active = false;
              document.removeEventListener('beforeinput', observe, true);
              document.removeEventListener('input', observe, true);
              for (const timer of timers) clearTimeout(timer);
              timers.clear();
            }
          };
          return 'installed';
        })()
        """
    )
    XCTAssertEqual(installed, "installed")
  }

  private func collectFindInputOrderProbe(_ webView: WKWebView) async throws -> String {
    let value = try await webView.callAsyncJavaScript(
      """
      await new Promise(resolve => setTimeout(resolve, 0));
      const probe = globalThis.__hostedFindInputOrderProbe;
      if (!probe) throw new Error('Find order probe is missing');
      const output = probe.collect();
      probe.dispose();
      delete globalThis.__hostedFindInputOrderProbe;
      return output;
      """,
      arguments: [:],
      in: nil,
      contentWorld: .page
    )
    guard let output = value as? String else {
      throw NSError(
        domain: "HostedFindHistoryControlTests",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Find input order was not a String"]
      )
    }
    return output
  }

  private func installEditMenu() -> (menu: NSMenu, undoItem: NSMenuItem) {
    let menu = NSMenu(title: "Main")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    menu.addItem(editItem)
    menu.setSubmenu(editMenu, for: editItem)
    let undoItem = NSMenuItem(
      title: "Undo", action: #selector(HostedCommandRouter.undo(_:)), keyEquivalent: "z")
    undoItem.keyEquivalentModifierMask = [.command]
    let redoItem = NSMenuItem(
      title: "Redo", action: #selector(HostedCommandRouter.redo(_:)), keyEquivalent: "Z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(undoItem)
    editMenu.addItem(redoItem)
    return (menu, undoItem)
  }

  private func makeWebView(for coordinator: CodeMirrorEditorCoordinator) -> WKWebView {
    let contentController = WKUserContentController()
    contentController.add(coordinator, name: CodeMirrorEditorCoordinator.messageHandlerName)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = contentController
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return CodeMirrorWebView(frame: .zero, configuration: configuration)
  }

  private func activate(_ window: NSWindow, trace: HostedPhaseTrace) async throws {
    trace.record("activation.before", window: window)
    let policyResult = NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    let runningApplicationResult = NSRunningApplication.current.activate(options: [
      .activateAllWindows, .activateIgnoringOtherApps,
    ])
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    trace.record(
      "activation.after",
      window: window,
      details: [
        "setActivationPolicyRegular": String(policyResult),
        "runningApplicationActivate": String(runningApplicationResult),
        "nsAppActivate": "called",
      ])
    try await waitUntil("window activation", timeoutNanoseconds: 30_000_000_000) {
      NSApp.isActive && window.isVisible && window.isKeyWindow
    }
    trace.record("activation.wait.after", window: window)
  }

  private func send(
    _ key: KeyStroke,
    to window: NSWindow,
    trace: HostedPhaseTrace,
    phase: String
  ) {
    trace.record(
      phase + ".before",
      window: window,
      details: [
        "keyCode": String(key.keyCode),
        "characters": key.characters,
        "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
      ])
    let timestamp = ProcessInfo.processInfo.systemUptime
    let keyDown = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: key.modifiers,
      timestamp: timestamp,
      windowNumber: window.windowNumber,
      context: nil,
      characters: key.characters,
      charactersIgnoringModifiers: key.charactersIgnoringModifiers,
      isARepeat: false,
      keyCode: key.keyCode
    )
    let keyUp = NSEvent.keyEvent(
      with: .keyUp,
      location: .zero,
      modifierFlags: key.modifiers,
      timestamp: timestamp,
      windowNumber: window.windowNumber,
      context: nil,
      characters: key.characters,
      charactersIgnoringModifiers: key.charactersIgnoringModifiers,
      isARepeat: false,
      keyCode: key.keyCode
    )
    XCTAssertNotNil(keyDown)
    XCTAssertNotNil(keyUp)
    if let keyDown { NSApp.sendEvent(keyDown) }
    if let keyUp { NSApp.sendEvent(keyUp) }
    trace.record(
      phase + ".after",
      window: window,
      details: ["keyDownCreated": String(keyDown != nil), "keyUpCreated": String(keyUp != nil)])
  }

  private func waitForDOMValue(
    _ webView: WKWebView,
    script: String,
    equals expected: String
  ) async throws -> String {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ 5_000_000_000
    var lastValue = ""
    while DispatchTime.now().uptimeNanoseconds < deadline {
      lastValue = try await evaluateString(webView, script: script)
      if lastValue == expected {
        return lastValue
      }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw NSError(
      domain: "HostedFindHistoryControlTests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "timed out waiting for DOM value",
        "lastValue": lastValue,
      ]
    )
  }

  private func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
    while !condition() {
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw NSError(
          domain: "HostedFindHistoryControlTests",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: "timed out waiting for (description)"]
        )
      }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
  }

  private func evaluateString(_ webView: WKWebView, script: String) async throws -> String {
    let evaluation = Evaluation()
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<String, Error>) in
      evaluation.start(continuation)
      webView.evaluateJavaScript(script) { value, error in
        Task { @MainActor in
          if let error {
            evaluation.finish(.failure(error))
          } else if let value = value as? String {
            evaluation.finish(.success(value))
          } else {
            evaluation.finish(
              .failure(
                NSError(
                  domain: "HostedFindHistoryControlTests",
                  code: 3,
                  userInfo: [NSLocalizedDescriptionKey: "JavaScript value was not a String"]
                )))
          }
        }
      }
    }
  }

  private func traceURL(suffix: String) -> URL? {
    let environment = ProcessInfo.processInfo.environment
    guard
      let path = environment["NW_HOSTED_TRACE_PATH"]
        ?? environment["TEST_RUNNER_NW_HOSTED_TRACE_PATH"],
      !path.isEmpty
    else {
      return nil
    }
    let baseURL = URL(fileURLWithPath: path)
    let fileExtension = baseURL.pathExtension
    let stem = baseURL.deletingPathExtension().path
    let fileName =
      fileExtension.isEmpty
      ? "\(stem)-\(suffix)"
      : "\(stem)-\(suffix).\(fileExtension)"
    return URL(fileURLWithPath: fileName)
  }
}
