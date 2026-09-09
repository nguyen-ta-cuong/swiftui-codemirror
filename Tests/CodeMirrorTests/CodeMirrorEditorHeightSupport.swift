import Foundation

@testable import CodeMirror

#if os(macOS) && canImport(AppKit) && canImport(WebKit)
  import AppKit
  import WebKit

  internal struct RenderedDiagnosticsState: Decodable {
    let visible: Bool
    let hasText: Bool
  }

  internal struct HeightProbeState: Decodable {
    let installed: Bool
    let installCount: Int
    let receiveCount: Int
    let startCount: Int
    let globalErrors: [String]
    let unhandledRejections: [String]

    var diagnosticDescription: String {
      "installed=\(installed), installs=\(installCount), receives=\(receiveCount), "
        + "starts=\(startCount), errors=\(globalErrors), rejections=\(unhandledRejections)"
    }
  }

  @MainActor
  internal final class HeightMessageForwarder: NSObject, WKScriptMessageHandler {
    weak var coordinator: CodeMirrorEditorCoordinator?
    private(set) var nativeDurations: [Double] = []

    func reset() {
      nativeDurations.removeAll()
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      let started = DispatchTime.now().uptimeNanoseconds
      coordinator?.userContentController(userContentController, didReceive: message)
      let elapsed = DispatchTime.now().uptimeNanoseconds &- started
      guard
        let body = message.body as? [String: Any],
        body["type"] as? String == "contentSize"
      else { return }
      nativeDurations.append(Double(elapsed) / 1_000_000)
    }
  }

  internal enum HeightProbe {
    static let scriptTemplate = """
      (() => {
        let hostValue;
        let controllerValue;
        const collectDurations = __COLLECT_DURATIONS__;
        const state = {
          javascriptMilliseconds: [],
          pendingStart: null,
          installed: false,
          installCount: 0,
          receiveCount: 0,
          startCount: 0,
          globalErrors: [],
          unhandledRejections: []
        };
        const record = (target, value) => {
          if (target.length < 4) {
            target.push(String(value ?? "").slice(0, 512));
          }
        };
        window.addEventListener("error", event => {
          record(state.globalErrors, event.message || event.error || "unknown error");
        });
        window.addEventListener("unhandledrejection", event => {
          record(state.unhandledRejections, event.reason || "unknown rejection");
        });
        const install = host => {
          if (!host || host.__heightProbeInstalled
            || typeof host.receive !== "function" || typeof host.start !== "function") return;
          const receive = host.receive;
          const start = host.start;
          host.receive = function(command) {
            state.receiveCount += 1;
            if (command?.type === "setHeightPolicy") {
              state.pendingStart = performance.now();
            }
            return receive.call(this, command);
          };
          host.start = function(postMessage, documentRef) {
            state.startCount += 1;
            const fallback = postMessage ?? (message =>
              window.webkit.messageHandlers.codeMirrorHost.postMessage(message));
            controllerValue = start.call(this, message => {
              if (collectDurations && message?.type === "contentSize"
                && state.pendingStart !== null) {
                state.javascriptMilliseconds.push(performance.now() - state.pendingStart);
                state.pendingStart = null;
              }
              return fallback(message);
            }, documentRef);
            return controllerValue;
          };
          host.__heightProbeInstalled = true;
          state.installed = true;
          state.installCount += 1;
        };
        Object.defineProperty(globalThis, "CodeMirrorHost", {
          configurable: true,
          get: () => hostValue,
          set: value => {
            hostValue = value;
            queueMicrotask(() => install(hostValue));
          }
        });
        globalThis.__codeMirrorHeightProbe = {
          controller: () => controllerValue,
          clear: () => {
            state.javascriptMilliseconds = [];
            state.pendingStart = null;
          },
          values: () => state.javascriptMilliseconds.slice(),
          state: () => ({
            installed: state.installed,
            installCount: state.installCount,
            receiveCount: state.receiveCount,
            startCount: state.startCount,
            globalErrors: state.globalErrors.slice(),
            unhandledRejections: state.unhandledRejections.slice()
          })
        };
      })();
      """

    static func script(instrument: Bool) -> String {
      scriptTemplate.replacingOccurrences(
        of: "__COLLECT_DURATIONS__",
        with: instrument ? "true" : "false"
      )
    }
  }

  @MainActor
  internal final class CodeMirrorHeightHarness {
    private typealias VoidContinuation = CheckedContinuation<Void, Error>
    private typealias StringContinuation = CheckedContinuation<String, Error>

    let session: CodeMirrorSession
    let replicaID: CodeMirrorReplicaID
    let coordinator: CodeMirrorEditorCoordinator
    let forwarder: HeightMessageForwarder
    let webView: CodeMirrorWebView
    let window: NSWindow

    init(
      session: CodeMirrorSession,
      replicaID: CodeMirrorReplicaID = CodeMirrorReplicaID(),
      heightPolicy: CodeMirrorEditorHeightPolicy,
      frame: NSRect = NSRect(x: 0, y: 0, width: 360, height: 500),
      instrument: Bool = false
    ) throws {
      let application = NSApplication.shared
      if application.activationPolicy() != .regular {
        guard application.setActivationPolicy(.regular) else {
          throw NSError(
            domain: "CodeMirrorEditorHeightTests",
            code: 13,
            userInfo: [NSLocalizedDescriptionKey: "Unable to set regular activation policy"]
          )
        }
      }
      self.session = session
      self.replicaID = replicaID
      let coordinator = CodeMirrorEditorCoordinator(
        session: session, replicaID: replicaID, heightPolicy: heightPolicy)
      let forwarder = HeightMessageForwarder()
      forwarder.coordinator = coordinator
      let contentController = WKUserContentController()
      contentController.addUserScript(
        WKUserScript(
          source: HeightProbe.script(instrument: instrument),
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true
        )
      )
      contentController.add(forwarder, name: CodeMirrorEditorCoordinator.messageHandlerName)
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController = contentController
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      let webView = CodeMirrorWebView(frame: frame, configuration: configuration)
      webView.autoresizingMask = [.width, .height]
      let window = NSWindow(
        contentRect: frame,
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      self.coordinator = coordinator
      self.forwarder = forwarder
      self.webView = webView
      self.window = window
      window.contentView = webView
      window.makeKeyAndOrderFront(application)
      application.activate(ignoringOtherApps: true)
      webView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      coordinator.attach(webView: webView)
    }

    func close() {
      coordinator.detach()
      window.close()
    }

    func evaluate(_ script: String) async throws {
      try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
        webView.evaluateJavaScript(script) { _, error in
          Task { @MainActor in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume()
            }
          }
        }
      }
    }

    func evaluateString(_ script: String) async throws -> String {
      try await withCheckedThrowingContinuation { (continuation: StringContinuation) in
        webView.evaluateJavaScript(script) { value, error in
          Task { @MainActor in
            if let error {
              continuation.resume(throwing: error)
            } else if let value = value as? String {
              continuation.resume(returning: value)
            } else {
              continuation.resume(
                throwing: NSError(domain: "CodeMirrorEditorHeightTests", code: 1)
              )
            }
          }
        }
      }
    }

    func waitUntil(_ description: String, condition: @escaping () -> Bool) async throws {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while !condition() {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(
            domain: "CodeMirrorEditorHeightTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"]
          )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    func waitForConfigured() async throws {
      try await waitUntil("configured handshake") {
        self.coordinator.pageIsConfigured && self.coordinator.attachedLoadID != nil
      }
      try await waitForDocumentVisible()
    }

    func waitForText(_ expected: String) async throws {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        let snapshot = try await session.flush()
        if snapshot.text == expected { return }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorHeightTests", code: 4)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    func waitForTextLength(_ expected: Int) async throws {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        let snapshot = try await session.flush()
        if snapshot.text.utf16.count == expected { return }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorHeightTests", code: 9)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    func diagnosticsState() async throws -> RenderedDiagnosticsState {
      let value = try await evaluateString(
        """
        JSON.stringify((() => {
          const panel = document.querySelector(".cm-host-diagnostics");
          return {
            visible: Boolean(panel && !panel.hidden && panel.getBoundingClientRect().height > 0),
            hasText: Boolean(panel?.textContent?.trim())
          };
        })())
        """
      )
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorHeightTests", code: 10)
      }
      return try JSONDecoder().decode(RenderedDiagnosticsState.self, from: data)
    }

    func waitForDiagnostics(visible: Bool) async throws {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        let state = try await diagnosticsState()
        if visible ? state.visible && state.hasText : !state.visible { return }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw NSError(domain: "CodeMirrorEditorHeightTests", code: 11)
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }

    func sendContentSizedPolicy(minimumRows: Int, maximumRows: Int) async throws {
      coordinator.update(
        heightPolicy: .contentSized(
          minimumVisibleRows: minimumRows, maximumVisibleRows: maximumRows))
    }

    func clearProbe() async throws {
      try await evaluate("globalThis.__codeMirrorHeightProbe?.clear()")
    }

    func probeDurations() async throws -> [Double] {
      let value = try await evaluateString(
        "JSON.stringify(globalThis.__codeMirrorHeightProbe?.values() ?? [])")
      guard let data = value.data(using: .utf8) else {
        throw NSError(domain: "CodeMirrorEditorHeightTests", code: 6)
      }
      return try JSONDecoder().decode([Double].self, from: data)
    }

    func waitForProbeDuration(after count: Int) async throws -> [Double] {
      let deadline = DispatchTime.now().uptimeNanoseconds &+ 10_000_000_000
      while true {
        let values = try await probeDurations()
        if values.count > count { return values }
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          let diagnostics = await timeoutDiagnostics()
          throw NSError(
            domain: "CodeMirrorEditorHeightTests",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: diagnostics]
          )
        }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
    }
  }

  internal func renderedLineFixture(_ count: Int) -> String {
    (1...count).map { "row-\($0)" }.joined(separator: "\n")
  }

  internal func percentile(_ values: [Double], at probability: Double) -> Double {
    guard !values.isEmpty else { return .infinity }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * probability)) - 1))
    return sorted[index]
  }
#endif
