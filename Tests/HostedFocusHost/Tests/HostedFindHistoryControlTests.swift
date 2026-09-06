import AppKit
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

  private struct HistoryObservation: Decodable {
    let command: String
    let activeElement: String
    let inputValueBefore: String
    let inputValueAfter: String
    let queryCommandSupported: Bool
    let queryCommandEnabled: Bool
    let result: Bool
  }

  private enum HistoryCommand: String {
    case undo
    case redo
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

  private static let insertFind = KeyStroke(
    characters: "q",
    charactersIgnoringModifiers: "q",
    keyCode: 12,
    modifiers: []
  )

  func testFindInputNativeHistoryControl() async throws {
    guard let traceURL = traceURL(suffix: "find-history-control") else {
      XCTFail("NW_HOSTED_TRACE_PATH is required for hosted history evidence")
      return
    }
    let trace = HostedPhaseTrace(suffix: "find-history-control")
    trace.record("test.entry", details: ["test": "testFindInputNativeHistoryControl"])
    guard
      FileManager.default.fileExists(atPath: traceURL.path),
      let traceContents = try? String(contentsOf: traceURL, encoding: .utf8),
      traceContents.contains("\"event\":\"test.entry\"")
    else {
      XCTFail("hosted trace entry was not written to \(traceURL.path)")
      return
    }
    let source = "controlled editor source"
    var hostCommandCount = 0
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
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 720, height: 420),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.title = "Find History Control"
    window.contentView = container
    trace.record("session.window.construction.after", window: window)
    coordinator.attach(webView: webView)
    trace.record("coordinator.attach.after", window: window)
    defer {
      trace.record("cleanup.begin", window: window)
      coordinator.detach()
      window.orderOut(nil)
      window.close()
      trace.record("cleanup.end", window: window)
    }

    try await waitUntil("CodeMirror ready and configured") {
      coordinator.pageIsReady && coordinator.pageIsConfigured
    }
    trace.record("ready.configured.after", window: window)
    trace.record("activation.before", window: window, details: activationDiagnostics())
    let policyResult = NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    let runningApplicationResult = NSRunningApplication.current.activate(options: [
      .activateAllWindows, .activateIgnoringOtherApps,
    ])
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    let activationDetails = activationDiagnostics(
      policyResult: policyResult,
      runningApplicationResult: runningApplicationResult
    )
    trace.record("activation.after", window: window, details: activationDetails)
    do {
      try await waitUntil(
        "ordinary window activation",
        timeoutNanoseconds: 30_000_000_000
      ) {
        NSApp.isActive && window.isVisible && window.isKeyWindow
      }
      trace.record(
        "activation.wait.after",
        window: window,
        details: activationDiagnostics(
          policyResult: policyResult,
          runningApplicationResult: runningApplicationResult
        ))
    } catch {
      trace.record(
        "activation.wait.error",
        window: window,
        details: activationDiagnostics(
          policyResult: policyResult,
          runningApplicationResult: runningApplicationResult
        ),
        error: error
      )
      throw error
    }
    XCTAssertTrue(window.makeFirstResponder(webView))
    try await waitUntil("web view native focus") { window.firstResponder === webView }

    try await session.showFind(in: replicaID)
    let focusResult = try await waitForDOMValue(
      webView,
      script: """
        (() => {
          const input = document.querySelector('.cm-search input');
          if (!input) { return 'missing'; }
          input.focus();
          return JSON.stringify({
            activeElement: document.activeElement === input ? 'cm-search-input' :
              (document.activeElement?.tagName ?? 'none')
          });
        })()
        """,
      equals: "cm-search-input"
    )
    trace.record(
      "focus.find.after",
      window: window,
      details: ["activeElement": focusResult, "hostCommandCount": String(hostCommandCount)])

    send(Self.insertFind, to: window)
    let insertedValue = try await waitForDOMValue(
      webView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    trace.record(
      "native.insert.after",
      window: window,
      details: [
        "activeElement": try await activeElementDescription(webView),
        "findValue": insertedValue,
        "hostCommandCount": String(hostCommandCount),
      ])
    XCTAssertEqual(insertedValue, "q")
    XCTAssertEqual(try session.snapshot().text, source)
    XCTAssertEqual(hostCommandCount, 0)

    let undo = try await executeFindHistoryCommand(.undo, in: webView)
    trace.record(
      "find.undo.after",
      window: window,
      details: [
        "activeElement": undo.activeElement,
        "beforeValue": undo.inputValueBefore,
        "afterValue": undo.inputValueAfter,
        "queryCommandSupported": String(undo.queryCommandSupported),
        "queryCommandEnabled": String(undo.queryCommandEnabled),
        "result": String(undo.result),
        "hostCommandCount": String(hostCommandCount),
      ])

    let redo = try await executeFindHistoryCommand(.redo, in: webView)
    trace.record(
      "find.redo.after",
      window: window,
      details: [
        "activeElement": redo.activeElement,
        "beforeValue": redo.inputValueBefore,
        "afterValue": redo.inputValueAfter,
        "queryCommandSupported": String(redo.queryCommandSupported),
        "queryCommandEnabled": String(redo.queryCommandEnabled),
        "result": String(redo.result),
        "hostCommandCount": String(hostCommandCount),
      ])

    XCTAssertEqual(undo.command, HistoryCommand.undo.rawValue)
    XCTAssertEqual(undo.activeElement, "cm-search-input")
    XCTAssertEqual(undo.inputValueBefore, "q")
    XCTAssertTrue(
      undo.queryCommandSupported,
      "Find undo must be supported; trace contains the observed command state"
    )
    XCTAssertTrue(
      undo.queryCommandEnabled,
      "Find undo must be enabled; trace contains the observed command state"
    )
    XCTAssertTrue(undo.result, "Find undo must execute; trace contains the observed command state")
    XCTAssertEqual(undo.inputValueAfter, "")

    XCTAssertEqual(redo.command, HistoryCommand.redo.rawValue)
    XCTAssertEqual(redo.activeElement, "cm-search-input")
    XCTAssertEqual(redo.inputValueBefore, "")
    XCTAssertTrue(
      redo.queryCommandSupported,
      "Find redo must be supported; trace contains the observed command state"
    )
    XCTAssertTrue(
      redo.queryCommandEnabled,
      "Find redo must be enabled; trace contains the observed command state"
    )
    XCTAssertTrue(redo.result, "Find redo must execute; trace contains the observed command state")
    XCTAssertEqual(redo.inputValueAfter, "q")
    XCTAssertEqual(try session.snapshot().text, source)
    XCTAssertEqual(hostCommandCount, 0)
  }

  private func makeWebView(for coordinator: CodeMirrorEditorCoordinator) -> WKWebView {
    let contentController = WKUserContentController()
    contentController.add(coordinator, name: CodeMirrorEditorCoordinator.messageHandlerName)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = contentController
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return WKWebView(frame: .zero, configuration: configuration)
  }

  private func send(_ key: KeyStroke, to window: NSWindow) {
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
  }

  private func activeElementDescription(_ webView: WKWebView) async throws -> String {
    try await waitForDOMValue(
      webView,
      script: """
        (() => {
          const input = document.querySelector('.cm-search input');
          if (!input) { return 'missing'; }
          return document.activeElement === input ? 'cm-search-input' :
            (document.activeElement?.tagName ?? 'none');
        })()
        """,
      equals: "cm-search-input"
    )
  }

  private func executeFindHistoryCommand(
    _ command: HistoryCommand,
    in webView: WKWebView
  ) async throws -> HistoryObservation {
    let script = """
      const input = document.querySelector('.cm-search input');
      const activeElement = document.activeElement === input
        ? 'cm-search-input'
        : (document.activeElement?.tagName ?? 'none');
      const requestedCommand = command;
      if (!input || document.activeElement !== input) {
        return JSON.stringify({
          command: requestedCommand,
          activeElement,
          inputValueBefore: input?.value ?? '',
          inputValueAfter: input?.value ?? '',
          queryCommandSupported: false,
          queryCommandEnabled: false,
          result: false
        });
      }
      const inputValueBefore = input.value;
      const queryCommandSupported = document.queryCommandSupported(requestedCommand);
      const queryCommandEnabled = document.queryCommandEnabled(requestedCommand);
      const result = document.execCommand(requestedCommand);
      return JSON.stringify({
        command: requestedCommand,
        activeElement,
        inputValueBefore,
        inputValueAfter: input.value,
        queryCommandSupported,
        queryCommandEnabled,
        result
      });
      """
    let evaluation = Evaluation()
    let json = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<String, Error>) in
      evaluation.start(continuation)
      webView.callAsyncJavaScript(
        script,
        arguments: ["command": command.rawValue],
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
                .failure(
                  NSError(
                    domain: "HostedFindHistoryControlTests",
                    code: 4,
                    userInfo: [
                      NSLocalizedDescriptionKey:
                        "Find history JavaScript value was not a String"
                    ])))
            }
          case .failure(let error):
            evaluation.finish(.failure(error))
          }
        }
      }
    }
    return try JSONDecoder().decode(HistoryObservation.self, from: Data(json.utf8))
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

  private func activationDiagnostics(
    policyResult: Bool? = nil,
    runningApplicationResult: Bool? = nil
  ) -> [String: String] {
    let runningApplication = NSRunningApplication.current
    let bundle = Bundle.main
    let hostBundleIdentifier = bundle.bundleIdentifier ?? "nil"
    let hostApplications: String
    if let bundleIdentifier = bundle.bundleIdentifier {
      hostApplications = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      )
      .sorted { $0.processIdentifier < $1.processIdentifier }
      .map { application in
        "pid=\(application.processIdentifier),path=\(application.bundleURL?.path ?? application.executableURL?.path ?? "nil")"
      }
      .joined(separator: ";")
    } else {
      hostApplications = ""
    }
    let frontmostApplication = NSWorkspace.shared.frontmostApplication
    var details = [
      "processIdentifier": String(ProcessInfo.processInfo.processIdentifier),
      "currentProcessIdentifier": String(runningApplication.processIdentifier),
      "currentActivationPolicy": String(runningApplication.activationPolicy.rawValue),
      "currentIsFinishedLaunching": String(runningApplication.isFinishedLaunching),
      "currentIsTerminated": String(runningApplication.isTerminated),
      "currentBundleURL": runningApplication.bundleURL?.path ?? "nil",
      "currentExecutableURL": runningApplication.executableURL?.path ?? "nil",
      "mainBundleURL": bundle.bundleURL.path,
      "mainNSPrincipalClass": infoValue("NSPrincipalClass"),
      "mainLSUIElement": infoValue("LSUIElement"),
      "mainLSBackgroundOnly": infoValue("LSBackgroundOnly"),
      "nsAppClass": String(reflecting: type(of: NSApp)),
      "nsAppDelegateType": NSApp.delegate.map { String(reflecting: type(of: $0)) } ?? "nil",
      "delegateDidFinishLaunching": launchCompletionState(),
      "frontmostProcessIdentifier": frontmostApplication.map {
        String($0.processIdentifier)
      } ?? "nil",
      "frontmostBundleIdentifier": frontmostApplication?.bundleIdentifier ?? "nil",
      "hostBundleIdentifier": hostBundleIdentifier,
      "hostRunningApplications": hostApplications,
    ]
    if let policyResult {
      details["setActivationPolicyRegular"] = String(policyResult)
    }
    if let runningApplicationResult {
      details["runningApplicationActivate"] = String(runningApplicationResult)
    }
    return details
  }

  private func infoValue(_ key: String) -> String {
    String(describing: Bundle.main.object(forInfoDictionaryKey: key) ?? "nil")
  }

  private func launchCompletionState() -> String {
    guard let delegate = NSApp.delegate as? NSObject else { return "unavailable" }
    let selector = NSSelectorFromString("didFinishLaunching")
    guard delegate.responds(to: selector) else { return "unreported" }
    return String(describing: delegate.value(forKey: "didFinishLaunching"))
  }

  private func waitForDOMValue(
    _ webView: WKWebView,
    script: String,
    equals expected: String
  ) async throws -> String {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ 3_000_000_000
    var lastValue = ""
    while DispatchTime.now().uptimeNanoseconds < deadline {
      lastValue = try await evaluateString(webView, script: script)
      if lastValue == expected || (expected == "cm-search-input" && lastValue.contains(expected)) {
        return expected == "cm-search-input" ? expected : lastValue
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
          userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(description)"]
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
}
