import SwiftUI
import WebKit

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

internal func resolvedCodeMirrorAppearance(
  configuration: CodeMirrorConfiguration,
  environmentScheme: CodeMirrorColorScheme,
  systemIncreaseContrast: Bool,
  accessibilityReduceMotion: Bool,
  accessibilityReduceTransparency: Bool
) -> CodeMirrorAppearance {
  let configuredAppearance = configuration.appearance
  return CodeMirrorAppearance(
    colorScheme: configuredAppearance.colorScheme == .system
      ? environmentScheme : configuredAppearance.colorScheme,
    increaseContrast: configuredAppearance.increaseContrast || systemIncreaseContrast,
    reduceMotion: configuredAppearance.reduceMotion || accessibilityReduceMotion,
    reduceTransparency: configuredAppearance.reduceTransparency
      || accessibilityReduceTransparency
  )
}

#if canImport(AppKit)
  @MainActor
  internal final class CodeMirrorWebView: WKWebView {
    override var undoManager: UndoManager? { nil }
  }

  @MainActor
  public struct CodeMirrorEditor: NSViewRepresentable {
    public typealias NSViewType = WKWebView

    public let session: CodeMirrorSession
    public let replicaID: CodeMirrorReplicaID

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    public init(session: CodeMirrorSession, replicaID: CodeMirrorReplicaID = CodeMirrorReplicaID())
    {
      self.session = session
      self.replicaID = replicaID
    }

    public func makeCoordinator() -> AnyObject {
      CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
    }

    public func makeNSView(context: Context) -> WKWebView {
      let coordinator = context.coordinator as! CodeMirrorEditorCoordinator
      let configuration = makeWebViewConfiguration(coordinator: coordinator)
      let webView = CodeMirrorWebView(frame: .zero, configuration: configuration)
      webView.setValue(false, forKey: "drawsBackground")
      coordinator.attach(webView: webView)
      coordinator.update(appearance: resolvedAppearance)
      return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
      let coordinator = context.coordinator as! CodeMirrorEditorCoordinator
      coordinator.update(appearance: resolvedAppearance)
      coordinator.update(webView: nsView)
    }

    public static func dismantleNSView(_ nsView: WKWebView, coordinator: AnyObject) {
      (coordinator as? CodeMirrorEditorCoordinator)?.detach()
    }

    private var resolvedAppearance: CodeMirrorAppearance {
      resolvedCodeMirrorAppearance(
        configuration: session.configuration,
        environmentScheme: colorScheme == .dark ? .dark : .light,
        systemIncreaseContrast: systemIncreaseContrast,
        accessibilityReduceMotion: accessibilityReduceMotion,
        accessibilityReduceTransparency: accessibilityReduceTransparency
      )
    }

    private var systemIncreaseContrast: Bool {
      #if canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      #elseif canImport(UIKit)
        UIAccessibilityDarkerSystemColorsEnabled()
      #else
        false
      #endif
    }

    private func makeWebViewConfiguration(coordinator: CodeMirrorEditorCoordinator)
      -> WKWebViewConfiguration
    {
      let contentController = WKUserContentController()
      contentController.add(coordinator, name: CodeMirrorEditorCoordinator.messageHandlerName)

      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController = contentController
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      return configuration
    }
  }
#elseif canImport(UIKit)
  @MainActor
  public struct CodeMirrorEditor: UIViewRepresentable {
    public typealias UIViewType = WKWebView

    public let session: CodeMirrorSession
    public let replicaID: CodeMirrorReplicaID

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    public init(session: CodeMirrorSession, replicaID: CodeMirrorReplicaID = CodeMirrorReplicaID())
    {
      self.session = session
      self.replicaID = replicaID
    }

    public func makeCoordinator() -> AnyObject {
      CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
    }

    public func makeUIView(context: Context) -> WKWebView {
      let coordinator = context.coordinator as! CodeMirrorEditorCoordinator
      let configuration = makeWebViewConfiguration(coordinator: coordinator)
      let webView = WKWebView(frame: .zero, configuration: configuration)
      webView.isOpaque = false
      coordinator.attach(webView: webView)
      coordinator.update(appearance: resolvedAppearance)
      return webView
    }

    public func updateUIView(_ uiView: WKWebView, context: Context) {
      let coordinator = context.coordinator as! CodeMirrorEditorCoordinator
      coordinator.update(appearance: resolvedAppearance)
      coordinator.update(webView: uiView)
    }

    public static func dismantleUIView(_ uiView: WKWebView, coordinator: AnyObject) {
      (coordinator as? CodeMirrorEditorCoordinator)?.detach()
    }

    private var resolvedAppearance: CodeMirrorAppearance {
      resolvedCodeMirrorAppearance(
        configuration: session.configuration,
        environmentScheme: colorScheme == .dark ? .dark : .light,
        systemIncreaseContrast: systemIncreaseContrast,
        accessibilityReduceMotion: accessibilityReduceMotion,
        accessibilityReduceTransparency: accessibilityReduceTransparency
      )
    }

    private var systemIncreaseContrast: Bool {
      #if canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      #elseif canImport(UIKit)
        UIAccessibilityDarkerSystemColorsEnabled()
      #else
        false
      #endif
    }

    private func makeWebViewConfiguration(coordinator: CodeMirrorEditorCoordinator)
      -> WKWebViewConfiguration
    {
      let contentController = WKUserContentController()
      contentController.add(coordinator, name: CodeMirrorEditorCoordinator.messageHandlerName)

      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController = contentController
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      return configuration
    }
  }
#endif

@MainActor
internal final class CodeMirrorEditorCoordinator: NSObject {
  static let messageHandlerName = "codeMirrorHost"
  private static let maximumPendingRequiredCommands = 32

  private weak var webView: WKWebView?
  private weak var session: CodeMirrorSession?
  private let replicaID: CodeMirrorReplicaID
  private var loadID: UUID?
  private var allowedReadRoot: URL?
  private var isReady = false
  private var isConfigured = false
  private var acceptsReady = false
  private var isAwaitingInitialNavigation = false
  private var pendingCommands: [CodeMirrorHostCommand] = []
  private var lifecycleID = UUID()

  internal var attachedLoadID: UUID? { loadID }
  internal var pendingCommandCount: Int { pendingCommands.count }
  internal var pendingRequiredCommandCount: Int {
    pendingCommands.reduce(into: 0) { count, command in
      if case .format = command { count += 1 }
      if case .flush = command { count += 1 }
      if case .routeCommand = command { count += 1 }
    }
  }
  internal var pendingFormatCommandCount: Int {
    pendingCommands.reduce(into: 0) { count, command in
      if case .format = command { count += 1 }
    }
  }
  internal var pendingConfigurationAppearances: [CodeMirrorAppearance] {
    pendingCommands.compactMap { command in
      switch command {
      case .configure(let configuration, _, _, _), .updateConfiguration(let configuration):
        return configuration.appearance
      default:
        return nil
      }
    }
  }
  internal var pageIsReady: Bool { isReady }
  internal var pageIsConfigured: Bool { isConfigured }
  internal var initialNavigationPending: Bool { isAwaitingInitialNavigation }

  init(session: CodeMirrorSession, replicaID: CodeMirrorReplicaID) {
    self.session = session
    self.replicaID = replicaID
  }

  private func attachSessionReplica() throws -> UUID {
    guard let session else {
      throw CodeMirrorSessionError.replicaUnavailable
    }
    return try session.attach(
      replicaID: replicaID,
      isFocused: { [weak self] in
        self?.isNativeFocused ?? false
      },
      send: { [weak self] command in
        self?.send(command)
      },
      traverseFocus: { [weak self] forward in
        self?.traverseNativeFocus(forward: forward)
      },
      operationDidFinish: { [weak self] command in
        self?.removePendingOperation(command)
      }
    )
  }

  func attach(webView: WKWebView) {
    lifecycleID = UUID()
    acceptsReady = false
    isReady = false
    isConfigured = false
    isAwaitingInitialNavigation = true
    self.webView = webView
    webView.navigationDelegate = self
    webView.uiDelegate = self
    do {
      loadID = try attachSessionReplica()
    } catch let error as CodeMirrorSessionError {
      isAwaitingInitialNavigation = false
      session?.reportTransportFailure(replicaID: replicaID, loadID: loadID ?? UUID())
      _ = error
      return
    } catch {
      isAwaitingInitialNavigation = false
      session?.reportTransportFailure(replicaID: replicaID, loadID: loadID ?? UUID())
      return
    }
    guard
      let indexURL = Bundle.module.url(
        forResource: "index", withExtension: "html", subdirectory: "web.bundle"),
      let bundleURL = Bundle.module.url(forResource: "web.bundle", withExtension: nil)
    else {
      isAwaitingInitialNavigation = false
      session?.reportTransportFailure(replicaID: replicaID, loadID: loadID ?? UUID())
      return
    }
    allowedReadRoot = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    webView.loadFileURL(indexURL, allowingReadAccessTo: bundleURL)
  }

  func update(webView: WKWebView) {
    guard self.webView === webView else { return }
  }

  func update(appearance: CodeMirrorAppearance) {
    session?.update(appearance: appearance, for: replicaID)
  }

  func detach() {
    let detachingLifecycleID = lifecycleID
    if isReady {
      evaluate(.invalidate, lifecycleID: detachingLifecycleID)
    }
    lifecycleID = UUID()
    acceptsReady = false
    isAwaitingInitialNavigation = false
    if let loadID {
      session?.detach(replicaID: replicaID, loadID: loadID)
    }
    webView?.configuration.userContentController.removeScriptMessageHandler(
      forName: Self.messageHandlerName)
    webView?.navigationDelegate = nil
    webView?.uiDelegate = nil
    webView?.stopLoading()
    webView = nil
    session = nil
    loadID = nil
    allowedReadRoot = nil
    pendingCommands.removeAll()
    isReady = false
    isConfigured = false
  }

  private func send(_ command: CodeMirrorHostCommand) {
    guard webView != nil else { return }
    guard isReady else {
      if !enqueuePending(command) {
        session?.failQueuedOperation(command)
      }
      return
    }
    if case .configure = command {
      evaluate(command)
      return
    }
    guard isConfigured else {
      if !enqueuePending(command) {
        session?.failQueuedOperation(command)
      }
      return
    }
    evaluate(command)
  }

  @discardableResult
  private func enqueuePending(_ command: CodeMirrorHostCommand) -> Bool {
    switch command {
    case .configure:
      replacePending(
        where: { command in
          if case .configure = command { return true }
          return false
        }, with: command)
    case .updateConfiguration:
      replacePending(
        where: { command in
          if case .updateConfiguration = command { return true }
          return false
        }, with: command)
    case .apply, .reconcile:
      replacePending(
        where: { command in
          switch command {
          case .apply, .reconcile: return true
          default: return false
          }
        }, with: command)
    case .acknowledge:
      replacePending(
        where: { command in
          if case .acknowledge = command { return true }
          return false
        }, with: command)
    case .selection:
      replacePending(
        where: { command in
          if case .selection = command { return true }
          return false
        }, with: command)
    case .focus:
      replacePending(
        where: { command in
          if case .focus = command { return true }
          return false
        }, with: command)
    case .showFind:
      replacePending(
        where: { command in
          if case .showFind = command { return true }
          return false
        }, with: command)
    case .format, .flush, .routeCommand:
      guard pendingRequiredCommandCount < Self.maximumPendingRequiredCommands else {
        return false
      }
      pendingCommands.append(command)
    case .invalidate:
      replacePending(
        where: { command in
          if case .invalidate = command { return true }
          return false
        }, with: command)
    }
    return true
  }

  private func removePendingOperation(_ command: CodeMirrorHostCommand) {
    switch command {
    case .format(let requestID):
      pendingCommands.removeAll { command in
        if case .format(let queuedRequestID) = command {
          return queuedRequestID == requestID
        }
        return false
      }
    case .flush(let requestID):
      pendingCommands.removeAll { command in
        if case .flush(let queuedRequestID) = command {
          return queuedRequestID == requestID
        }
        return false
      }
    case .routeCommand(let requestID, _):
      pendingCommands.removeAll { command in
        if case .routeCommand(let queuedRequestID, _) = command {
          return queuedRequestID == requestID
        }
        return false
      }
    default:
      break
    }
  }

  private func replacePending(
    where matches: (CodeMirrorHostCommand) -> Bool,
    with command: CodeMirrorHostCommand
  ) {
    if let index = pendingCommands.lastIndex(where: matches) {
      pendingCommands[index] = command
    } else {
      pendingCommands.append(command)
    }
  }

  private func evaluate(_ command: CodeMirrorHostCommand, lifecycleID: UUID? = nil) {
    guard let webView else { return }
    let commandLifecycleID = lifecycleID ?? self.lifecycleID
    webView.callAsyncJavaScript(
      "CodeMirrorHost.receive(command)",
      arguments: ["command": command.payload],
      in: nil,
      in: .page
    ) { [weak self] result in
      guard case .failure = result else { return }
      Task { @MainActor [weak self] in
        guard let self, self.lifecycleID == commandLifecycleID else { return }
        self.transportFailed()
      }
    }
  }

  private func transportFailed() {
    acceptsReady = false
    isReady = false
    isConfigured = false
    isAwaitingInitialNavigation = false
    lifecycleID = UUID()
    let queued = pendingCommands
    pendingCommands.removeAll()
    for command in queued {
      session?.failQueuedOperation(command)
    }
    guard let loadID else { return }
    session?.clearFocusScope(replicaID: replicaID, loadID: loadID)
    session?.reportTransportFailure(replicaID: replicaID, loadID: loadID)
    session?.detach(replicaID: replicaID, loadID: loadID)
    self.loadID = nil
  }

  private var isNativeFocused: Bool {
    #if os(macOS)
      guard let webView, isVisibleInHierarchy(webView), let window = webView.window,
        window.isVisible, window.isKeyWindow
      else {
        return false
      }
      guard let responder = window.firstResponder as? NSView,
        responder === webView || responder.isDescendant(of: webView)
      else {
        return false
      }
      return true
    #elseif os(iOS)
      guard let webView, isVisibleInHierarchy(webView), let window = webView.window,
        !window.isHidden, window.isKeyWindow
      else {
        return false
      }
      return webView.isFirstResponder
    #else
      return false
    #endif
  }

  #if os(macOS)
    private func isVisibleInHierarchy(_ view: NSView) -> Bool {
      var current: NSView? = view
      while let visibleView = current {
        guard !visibleView.isHidden, visibleView.alphaValue > 0 else { return false }
        current = visibleView.superview
      }
      return true
    }

    private func traverseNativeFocus(forward: Bool) {
      guard isNativeFocused, let webView, let window = webView.window else { return }
      if forward {
        window.selectKeyView(following: webView)
      } else {
        window.selectKeyView(preceding: webView)
      }
    }
  #elseif os(iOS)
    private func isVisibleInHierarchy(_ view: UIView) -> Bool {
      var current: UIView? = view
      while let visibleView = current {
        guard !visibleView.isHidden, visibleView.alpha > 0 else { return false }
        current = visibleView.superview
      }
      return true
    }

    private func traverseNativeFocus(forward: Bool) {
      guard forward, isNativeFocused, let webView else { return }
      webView.next?.becomeFirstResponder()
    }
  #endif

  private func isLocalURL(_ url: URL?) -> Bool {
    guard let url, url.isFileURL, let allowedReadRoot else { return false }
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    let root =
      allowedReadRoot.path.hasSuffix("/") ? allowedReadRoot.path : allowedReadRoot.path + "/"
    return path == allowedReadRoot.path || path.hasPrefix(root)
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == Self.messageHandlerName, message.frameInfo.isMainFrame else { return }
    do {
      let inbound = try CodeMirrorInboundMessage.decode(message.body)
      guard acceptsReady else { return }
      let normalizedInbound: CodeMirrorInboundMessage
      if case .ready = inbound {
        isReady = true
        guard let session, let loadID else { return }
        normalizedInbound = .ready(sessionID: session.id, replicaID: replicaID, loadID: loadID)
      } else if case .configured(let sessionID, let configuredReplicaID, let configuredLoadID) =
        inbound
      {
        guard let session, let loadID,
          sessionID == session.id, configuredReplicaID == replicaID, configuredLoadID == loadID
        else {
          transportFailed()
          return
        }
        normalizedInbound = inbound
      } else {
        normalizedInbound = inbound
      }
      session?.receive(normalizedInbound)
      if case .configured = normalizedInbound {
        isConfigured = true
        let queued = pendingCommands
        pendingCommands.removeAll()
        for command in queued {
          guard session?.hasPendingOperation(command) != false else { continue }
          evaluate(command)
        }
      }
    } catch {
      transportFailed()
    }
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard navigationAction.targetFrame?.isMainFrame == true,
      isLocalURL(navigationAction.request.url)
    else {
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
  ) {
    decisionHandler(isLocalURL(navigationResponse.response.url) ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard self.webView === webView else { return }
    if isAwaitingInitialNavigation {
      isAwaitingInitialNavigation = false
      return
    }
    let hadLivePage = isReady || isConfigured
    let previousLoadID = loadID
    isReady = false
    isConfigured = false
    acceptsReady = false
    lifecycleID = UUID()
    let queued = pendingCommands
    pendingCommands.removeAll()
    for command in queued {
      session?.failQueuedOperation(command)
    }
    if let previousLoadID {
      if hadLivePage {
        session?.reportTransportFailure(replicaID: replicaID, loadID: previousLoadID)
      }
      session?.detach(replicaID: replicaID, loadID: previousLoadID)
    }
    self.loadID = nil
    do {
      self.loadID = try attachSessionReplica()
    } catch {
      if let previousLoadID {
        session?.reportTransportFailure(replicaID: replicaID, loadID: previousLoadID)
      }
      return
    }
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard self.webView === webView else { return }
    acceptsReady = true
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    transportFailed()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    transportFailed()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    transportFailed()
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }
}

extension CodeMirrorEditorCoordinator: WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {}
