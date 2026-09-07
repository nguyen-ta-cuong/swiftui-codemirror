import AppKit
import CodeMirror

@MainActor
private final class HostedDisabledCommandTarget: NSObject, NSMenuItemValidation {
  @objc func undo(_: Any?) {}

  @objc func redo(_: Any?) {}

  func validateMenuItem(_: NSMenuItem) -> Bool { false }
}

@MainActor
private final class HostedFindCommandTarget: NSObject, NSMenuItemValidation {
  weak var window: NSWindow?
  let session: CodeMirrorSession
  let replicaID: CodeMirrorReplicaID
  let contextID: CodeMirrorFindCommandContextID
  var onError: ((Error) -> Void)?
  var onResult: ((CodeMirrorCommandRoutingResult) -> Void)?
  var onInvoke: ((CodeMirrorCommand) -> Void)?

  init(
    session: CodeMirrorSession,
    replicaID: CodeMirrorReplicaID,
    contextID: CodeMirrorFindCommandContextID,
    window: NSWindow
  ) {
    self.session = session
    self.replicaID = replicaID
    self.contextID = contextID
    self.window = window
  }

  @objc func undo(_: Any?) {
    invoke(.undo)
  }

  @objc func redo(_: Any?) {
    invoke(.redo)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let action = menuItem.action, let command = command(for: action),
      case .find(let context) = session.focusedCommandContext(),
      context.replicaID == replicaID, context.id == contextID
    else {
      return false
    }
    menuItem.title = command == .undo ? "Undo" : "Redo"
    let availability = availability(for: command, in: context)
    return availability.isSupported && availability.isEnabled
  }

  private func invoke(_ command: CodeMirrorCommand) {
    guard let window, window.isVisible, window.isKeyWindow, NSApp.isActive,
      session.focusedReplicaID() == replicaID
    else {
      return
    }
    onInvoke?(command)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await session.routeCommand(
          command, in: replicaID, expecting: .find(contextID))
        onResult?(result)
      } catch {
        onError?(error)
      }
    }
  }

  private func command(for action: Selector) -> CodeMirrorCommand? {
    if action == #selector(HostedCommandRouter.undo(_:)) { return .undo }
    if action == #selector(HostedCommandRouter.redo(_:)) { return .redo }
    return nil
  }

  private func availability(
    for command: CodeMirrorCommand,
    in context: CodeMirrorFindCommandContext
  ) -> CodeMirrorCommandAvailability {
    command == .undo ? context.undo : context.redo
  }
}

@MainActor
public final class HostedCommandRouter: NSObject, NSMenuItemValidation {
  public weak var window: NSWindow?
  public let session: CodeMirrorSession
  public let replicaID: CodeMirrorReplicaID
  public let undoManager: UndoManager
  public var onError: ((Error) -> Void)?
  public var onResult: ((CodeMirrorCommandRoutingResult) -> Void)?
  public var onInvoke: ((CodeMirrorCommand) -> Void)?

  private static let maximumFindTargets = 32
  private var findTargets: [CodeMirrorFindCommandContextID: HostedFindCommandTarget] = [:]
  private let disabledTarget = HostedDisabledCommandTarget()

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
      NSApp.isActive,
      case .content(let focusedReplicaID) = session.focusedCommandContext(),
      focusedReplicaID == replicaID
    else {
      return false
    }
    return isUndoAvailable(for: command)
  }

  public func canRoute(action: Selector) -> Bool {
    guard let command = command(for: action) else { return false }
    return canRoute(command)
  }

  public func target(for action: Selector) -> AnyObject? {
    guard let window,
      window.isVisible,
      window.isKeyWindow,
      NSApp.isActive
    else {
      return nil
    }
    switch session.focusedCommandContext() {
    case .content(let focusedReplicaID) where focusedReplicaID == replicaID:
      return canRoute(action: action) ? self : disabledTarget
    case .find(let context) where context.replicaID == replicaID:
      return findTarget(for: context)
    case .unavailable(let focusedReplicaID) where focusedReplicaID == replicaID:
      return disabledTarget
    default:
      retireFindTargets(keeping: nil)
      return nil
    }
  }

  fileprivate func commandContextDidChange() {
    let retainedContextID: CodeMirrorFindCommandContextID?
    if case .find(let context) = session.focusedCommandContext(),
      context.replicaID == replicaID
    {
      retainedContextID = context.id
    } else {
      retainedContextID = nil
    }
    retireFindTargets(keeping: retainedContextID)
  }

  public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let action = menuItem.action else { return true }
    guard canRoute(action: action) else { return false }
    if action == #selector(undo(_:)) {
      menuItem.title = undoManager.undoMenuItemTitle
    } else if action == #selector(redo(_:)) {
      menuItem.title = undoManager.redoMenuItemTitle
    }
    return true
  }

  @objc public func undo(_ sender: Any?) {
    invoke(.undo, sender: sender)
  }

  @objc public func redo(_ sender: Any?) {
    invoke(.redo, sender: sender)
  }

  private func findTarget(for context: CodeMirrorFindCommandContext) -> HostedFindCommandTarget {
    retireFindTargets(keeping: context.id)
    if let target = findTargets[context.id] {
      return target
    }
    let target = HostedFindCommandTarget(
      session: session, replicaID: replicaID, contextID: context.id, window: window!)
    target.onError = { [weak self] error in self?.onError?(error) }
    target.onResult = { [weak self] result in self?.onResult?(result) }
    target.onInvoke = { [weak self] command in self?.onInvoke?(command) }
    findTargets[context.id] = target
    while findTargets.count > Self.maximumFindTargets {
      findTargets.removeValue(forKey: findTargets.keys.first!)
    }
    return target
  }

  private func retireFindTargets(keeping contextID: CodeMirrorFindCommandContextID?) {
    findTargets = findTargets.filter { $0.key == contextID }
  }

  private func invoke(_ command: CodeMirrorCommand, sender _: Any?) {
    guard let window, window.isVisible, window.isKeyWindow, NSApp.isActive,
      session.focusedReplicaID() == replicaID
    else {
      return
    }
    onInvoke?(command)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let result = try await session.routeCommand(
          command, in: replicaID, expecting: .contentOrCurrentFind)
        onResult?(result)
      } catch {
        onError?(error)
      }
    }
  }

  private func command(for action: Selector) -> CodeMirrorCommand? {
    if action == #selector(undo(_:)) { return .undo }
    if action == #selector(redo(_:)) { return .redo }
    return nil
  }

  private func isUndoAvailable(for command: CodeMirrorCommand) -> Bool {
    command == .undo ? undoManager.canUndo : undoManager.canRedo
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

  fileprivate func target(for action: Selector, in window: NSWindow) -> AnyObject? {
    router(for: window)?.target(for: action)
  }

  public func commandContextDidChange(in window: NSWindow, replicaID: CodeMirrorReplicaID) {
    guard let router = router(for: window), router.replicaID == replicaID else { return }
    router.commandContextDidChange()
    if window.isKeyWindow {
      NSApp.mainMenu?.update()
    }
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
      let window = keyWindow,
      let resolvedTarget = commandRouterRegistry.target(for: action, in: window)
    else {
      return super.target(forAction: action, to: target, from: sender)
    }
    return resolvedTarget
  }

  public override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
    guard target == nil,
      action == #selector(HostedCommandRouter.undo(_:))
        || action == #selector(HostedCommandRouter.redo(_:)),
      let window = keyWindow,
      let resolvedTarget = commandRouterRegistry.target(for: action, in: window)
    else {
      return super.sendAction(action, to: target, from: sender)
    }
    return super.sendAction(action, to: resolvedTarget, from: sender)
  }
}
