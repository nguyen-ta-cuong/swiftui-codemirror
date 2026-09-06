import AppKit
import CodeMirror

@MainActor
public final class HostedCommandRouter: NSObject, NSMenuItemValidation {
  public weak var window: NSWindow?
  public let session: CodeMirrorSession
  public let replicaID: CodeMirrorReplicaID
  public let undoManager: UndoManager
  public var onError: ((Error) -> Void)?
  public var onResult: ((CodeMirrorCommandRoutingResult) -> Void)?
  public var onInvoke: ((CodeMirrorCommand) -> Void)?

  public init(
    session: CodeMirrorSession,
    replicaID: CodeMirrorReplicaID,
    window: NSWindow,
    undoManager: UndoManager
  ) {
    self.session = session
    self.replicaID = replicaID
    self.window = window
    self.undoManager = undoManager
  }

  public func canRoute(_ command: CodeMirrorCommand) -> Bool {
    guard let window,
      window.isVisible,
      window.isKeyWindow,
      NSApp.isActive
    else {
      return false
    }
    guard session.focusedEditorContentReplicaID() == replicaID else {
      return false
    }
    switch command {
    case .undo:
      return undoManager.canUndo
    case .redo:
      return undoManager.canRedo
    }
  }

  public func canRoute(action: Selector) -> Bool {
    if action == #selector(undo(_:)) {
      return canRoute(.undo)
    }
    if action == #selector(redo(_:)) {
      return canRoute(.redo)
    }
    return false
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let action = menuItem.action else { return true }
    let canRoute = canRoute(action: action)
    if canRoute {
      if action == #selector(undo(_:)) {
        menuItem.title = undoManager.undoMenuItemTitle
      } else if action == #selector(redo(_:)) {
        menuItem.title = undoManager.redoMenuItemTitle
      }
    }
    return canRoute
  }

  @objc public func undo(_ sender: Any?) {
    onInvoke?(.undo)
    route(.undo, sender: sender)
  }

  @objc public func redo(_ sender: Any?) {
    onInvoke?(.redo)
    route(.redo, sender: sender)
  }

  private func route(_ command: CodeMirrorCommand, sender _: Any?) {
    let selectedReplicaID = replicaID
    Task { @MainActor [weak self] in
      guard let self,
        let window = self.window,
        window.isVisible,
        window.isKeyWindow,
        NSApp.isActive,
        self.session.focusedReplicaID() == selectedReplicaID,
        self.isUndoAvailable(for: command)
      else {
        return
      }
      do {
        let result = try await self.session.routeCommand(command, in: selectedReplicaID)
        self.onResult?(result)
      } catch {
        self.onError?(error)
      }
    }
  }

  private func isUndoAvailable(for command: CodeMirrorCommand) -> Bool {
    switch command {
    case .undo:
      return undoManager.canUndo
    case .redo:
      return undoManager.canRedo
    }
  }
}

@MainActor
public final class HostedCommandRouterRegistry {
  private final class WeakRouter {
    weak var value: HostedCommandRouter?

    init(_ value: HostedCommandRouter) {
      self.value = value
    }
  }

  private var routers: [ObjectIdentifier: WeakRouter] = [:]

  public init() {}

  public func register(_ router: HostedCommandRouter, for window: NSWindow) {
    router.window = window
    routers[ObjectIdentifier(window)] = WeakRouter(router)
  }

  public func unregister(for window: NSWindow) {
    routers.removeValue(forKey: ObjectIdentifier(window))
  }

  fileprivate func router(for window: NSWindow) -> HostedCommandRouter? {
    let key = ObjectIdentifier(window)
    guard let router = routers[key]?.value else {
      routers.removeValue(forKey: key)
      return nil
    }
    return router
  }
}

@MainActor
public final class HostedFocusHostApplication: NSApplication {
  public let commandRouterRegistry = HostedCommandRouterRegistry()

  public override func target(forAction action: Selector, to target: Any?, from sender: Any?)
    -> Any?
  {
    guard target == nil,
      action == #selector(HostedCommandRouter.undo(_:))
        || action == #selector(HostedCommandRouter.redo(_:)),
      let window = keyWindow
    else {
      return super.target(forAction: action, to: target, from: sender)
    }
    if let router = commandRouterRegistry.router(for: window), router.canRoute(action: action) {
      return router
    }
    return super.target(forAction: action, to: target, from: sender)
  }
}
