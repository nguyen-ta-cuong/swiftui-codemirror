import AppKit
import CodeMirrorHostedFocusHost
import WebKit
import XCTest

@testable import CodeMirror

@MainActor
final class HostedF4CommandRoutingTests: XCTestCase {
  private struct KeyStroke {
    let characters: String
    let charactersIgnoringModifiers: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
  }

  private static let commandUndo = KeyStroke(
    characters: "z", charactersIgnoringModifiers: "z", keyCode: 6, modifiers: [.command])
  private static let commandRedo = KeyStroke(
    characters: "Z", charactersIgnoringModifiers: "Z", keyCode: 6, modifiers: [.command, .shift])
  private static let insertExclamation = KeyStroke(
    characters: "!", charactersIgnoringModifiers: "!", keyCode: 18, modifiers: [.shift])
  private static let insertQuestion = KeyStroke(
    characters: "?", charactersIgnoringModifiers: "?", keyCode: 44, modifiers: [.shift])
  private static let insertNative = KeyStroke(
    characters: "n", charactersIgnoringModifiers: "n", keyCode: 45, modifiers: [])
  private static let insertFind = KeyStroke(
    characters: "q", charactersIgnoringModifiers: "q", keyCode: 12, modifiers: [])

  private struct MenuDispatch {
    let enabled: Bool
    let sent: Bool
    let targetIsHostedRouter: Bool
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
  private final class UndoOwner {
    let name: String
    let undoManager = UndoManager()
    private let target = NSObject()
    private(set) var commandPhases: [String] = []
    private(set) var replacementCount = 0
    private(set) var errors: [Error] = []

    init(name: String) {
      self.name = name
    }

    func handle(_ command: CodeMirrorCommand) {
      switch command {
      case .undo:
        undoManager.undo()
      case .redo:
        undoManager.redo()
      }
    }

    func registerUndo(
      from previous: CodeMirrorSnapshot,
      to current: CodeMirrorSnapshot,
      session: CodeMirrorSession,
      replicaID: CodeMirrorReplicaID
    ) {
      undoManager.registerUndo(withTarget: target) { [weak self, weak session] _ in
        guard let self, let session else { return }
        self.commandPhases.append(
          self.undoManager.isUndoing
            ? "\(self.name).undo"
            : self.undoManager.isRedoing ? "\(self.name).redo" : "\(self.name).outside"
        )
        do {
          let live = try session.snapshot()
          let replacement = try session.replaceImmediately(
            expectedRevision: live.revision,
            changes: [
              CodeMirrorChange(
                rangeUTF16: 0..<live.text.utf16.count,
                insertedText: previous.text,
                removedText: live.text
              )
            ],
            selection: previous.selections[replicaID],
            in: replicaID
          )
          self.replacementCount += 1
          self.registerUndo(from: live, to: replacement, session: session, replicaID: replicaID)
        } catch {
          self.errors.append(error)
        }
      }
      _ = current
    }
  }

  @MainActor
  private final class CommandWindow: NSWindow {
    private let ownerUndoManager: UndoManager

    init(contentRect: NSRect, title: String, undoManager: UndoManager) {
      ownerUndoManager = undoManager
      super.init(
        contentRect: contentRect,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      self.title = title
    }

    override var undoManager: UndoManager? {
      ownerUndoManager
    }
  }

  func testContentMenuAndKeyboardRouteToTheOwningUndoManager() async throws {
    let trace = HostedPhaseTrace(suffix: "f4-content-menu")
    trace.record(
      "test.entry",
      details: ["test": "testContentMenuAndKeyboardRouteToTheOwningUndoManager"])
    guard let application = NSApp as? HostedFocusHostApplication else {
      XCTFail("host application did not use HostedFocusHostApplication")
      return
    }

    let ownerA = UndoOwner(name: "windowA")
    let ownerB = UndoOwner(name: "windowB")
    let inlineID = CodeMirrorReplicaID()
    let detachedID = CodeMirrorReplicaID()
    let otherID = CodeMirrorReplicaID()
    var eventsA: [(CodeMirrorReplicaID, CodeMirrorCommand)] = []
    var eventsB: [(CodeMirrorReplicaID, CodeMirrorCommand)] = []
    var routeResultsA: [CodeMirrorCommandRoutingResult] = []
    var transactionsA = 0
    var transactionsB = 0

    let sessionA = CodeMirrorSession(initialText: "one") { event in
      switch event {
      case .command(let replicaID, let command):
        eventsA.append((replicaID, command))
        ownerA.handle(command)
      case .transaction:
        transactionsA += 1
      default:
        break
      }
      return .accept
    }
    let sessionB = CodeMirrorSession(initialText: "one") { event in
      switch event {
      case .command(let replicaID, let command):
        eventsB.append((replicaID, command))
        ownerB.handle(command)
      case .transaction:
        transactionsB += 1
      default:
        break
      }
      return .accept
    }

    let menu = installEditMenu()
    let previousMenu = NSApp.mainMenu
    NSApp.mainMenu = menu.menu
    let windowA = CommandWindow(
      contentRect: NSRect(x: 60, y: 100, width: 760, height: 520),
      title: "F4 Window A",
      undoManager: ownerA.undoManager
    )
    let windowB = CommandWindow(
      contentRect: NSRect(x: 860, y: 100, width: 520, height: 420),
      title: "F4 Window B",
      undoManager: ownerB.undoManager
    )
    let detachedWindow = CommandWindow(
      contentRect: NSRect(x: 60, y: 660, width: 760, height: 320),
      title: "F4 Detached Window A",
      undoManager: ownerA.undoManager
    )
    windowA.isReleasedWhenClosed = false
    windowB.isReleasedWhenClosed = false
    detachedWindow.isReleasedWhenClosed = false
    let containerA = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    let containerB = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
    let detachedContainer = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 320))
    let fieldA = NSTextField(frame: NSRect(x: 16, y: 12, width: 240, height: 24))
    let inlineCoordinator = CodeMirrorEditorCoordinator(session: sessionA, replicaID: inlineID)
    let detachedCoordinator = CodeMirrorEditorCoordinator(session: sessionA, replicaID: detachedID)
    let otherCoordinator = CodeMirrorEditorCoordinator(session: sessionB, replicaID: otherID)
    let inlineWebView = makeWebView(
      for: inlineCoordinator, frame: NSRect(x: 0, y: 270, width: 760, height: 240))
    let detachedWebView = makeWebView(
      for: detachedCoordinator, frame: NSRect(x: 0, y: 30, width: 760, height: 280))
    let otherWebView = makeWebView(
      for: otherCoordinator, frame: NSRect(x: 0, y: 30, width: 520, height: 360))
    windowA.contentView = containerA
    windowB.contentView = containerB
    detachedWindow.contentView = detachedContainer
    containerA.addSubview(fieldA)
    containerA.addSubview(inlineWebView)
    detachedContainer.addSubview(detachedWebView)
    containerB.addSubview(otherWebView)
    inlineCoordinator.attach(webView: inlineWebView)
    detachedCoordinator.attach(webView: detachedWebView)
    otherCoordinator.attach(webView: otherWebView)
    let routerAInline = HostedCommandRouter(
      session: sessionA,
      replicaID: inlineID,
      window: windowA,
      undoManager: ownerA.undoManager
    )
    let routerADetached = HostedCommandRouter(
      session: sessionA,
      replicaID: detachedID,
      window: detachedWindow,
      undoManager: ownerA.undoManager
    )
    let routerB = HostedCommandRouter(
      session: sessionB,
      replicaID: otherID,
      window: windowB,
      undoManager: ownerB.undoManager
    )
    routerAInline.onResult = { result in
      routeResultsA.append(result)
      trace.record("routerA.inline.result", details: ["result": result.rawValue])
    }
    routerADetached.onResult = { result in
      trace.record("routerA.detached.result", details: ["result": result.rawValue])
    }
    routerAInline.onError = { error in
      trace.record("routerA.inline.error", error: error)
    }
    routerADetached.onError = { error in
      trace.record("routerA.detached.error", error: error)
    }
    routerAInline.onInvoke = { command in
      trace.record("routerA.inline.invoke", details: ["command": command.rawValue])
    }
    routerADetached.onInvoke = { command in
      trace.record("routerA.detached.invoke", details: ["command": command.rawValue])
    }
    application.commandRouterRegistry.register(routerAInline, for: windowA)
    application.commandRouterRegistry.register(routerADetached, for: detachedWindow)
    application.commandRouterRegistry.register(routerB, for: windowB)
    defer {
      trace.record("cleanup.begin", window: windowA)
      inlineCoordinator.detach()
      detachedCoordinator.detach()
      otherCoordinator.detach()
      application.commandRouterRegistry.unregister(for: windowA)
      application.commandRouterRegistry.unregister(for: detachedWindow)
      application.commandRouterRegistry.unregister(for: windowB)
      windowA.orderOut(nil)
      detachedWindow.orderOut(nil)
      windowB.orderOut(nil)
      windowA.close()
      detachedWindow.close()
      windowB.close()
      NSApp.mainMenu = previousMenu
      trace.record("cleanup.end", window: windowA)
    }

    try await traceAwait(trace, "ready.configured") {
      try await waitUntil("F4 replicas configured") {
        inlineCoordinator.pageIsReady && inlineCoordinator.pageIsConfigured
          && detachedCoordinator.pageIsReady && detachedCoordinator.pageIsConfigured
          && otherCoordinator.pageIsReady && otherCoordinator.pageIsConfigured
      }
    }
    try await activate(windowA)
    try await focusContent(inlineWebView, in: windowA, session: sessionA, replicaID: inlineID)
    XCTAssertEqual(sessionA.focusedEditorContentReplicaID(), inlineID)

    let initiallyDisabled = dispatch(
      menu.undoItem, window: windowA, trace: trace, phase: "menu.content.initial")
    XCTAssertFalse(initiallyDisabled.enabled)
    XCTAssertFalse(initiallyDisabled.sent)

    let beforeEditA = try sessionA.snapshot()
    send(Self.insertExclamation, to: windowA, trace: trace, phase: "keyboard.content.insert")
    try await waitForSnapshotText(sessionA, equals: "!one")
    _ = try await traceAwait(trace, "flush.content.insert") {
      try await sessionA.flush()
    }
    let afterEditA = try sessionA.snapshot()
    ownerA.registerUndo(
      from: beforeEditA, to: afterEditA, session: sessionA, replicaID: inlineID)
    menu.undoItem.menu?.update()
    XCTAssertTrue(menu.undoItem.isEnabled)
    let transactionsAfterEditA = transactionsA

    let beforeKeyboardUndo = eventsA.count
    _ = try await sessionA.flush()
    send(Self.commandUndo, to: windowA, trace: trace, phase: "keyboard.content.undo")
    try await waitForCommandCount({ eventsA.count }, equals: beforeKeyboardUndo + 1)
    XCTAssertEqual(eventsA.last?.0, inlineID)
    XCTAssertEqual(eventsA.last?.1, .undo)
    try await waitForSnapshotText(sessionA, equals: "one")
    XCTAssertEqual(transactionsA, transactionsAfterEditA)

    try await activate(detachedWindow)
    try await focusContent(
      detachedWebView, in: detachedWindow, session: sessionA, replicaID: detachedID)
    XCTAssertEqual(sessionA.focusedEditorContentReplicaID(), detachedID)
    _ = try await sessionA.flush()
    let beforeMenuRedo = eventsA.count
    let menuRedo = dispatch(
      menu.redoItem, window: detachedWindow, trace: trace, phase: "menu.content.redo")
    XCTAssertTrue(menuRedo.enabled)
    XCTAssertTrue(menuRedo.sent)
    try await traceAwait(trace, "command.content.redo") {
      try await waitForCommandCount({ eventsA.count }, equals: beforeMenuRedo + 1)
    }
    trace.record("command.content.redo.count", details: ["count": String(eventsA.count)])
    XCTAssertEqual(eventsA.last?.0, detachedID)
    XCTAssertEqual(eventsA.last?.1, .redo)
    try await waitForSnapshotText(sessionA, equals: "!one")
    XCTAssertEqual(transactionsA, transactionsAfterEditA)
    XCTAssertEqual(ownerA.replacementCount, 2)
    XCTAssertEqual(ownerA.commandPhases, ["windowA.undo", "windowA.redo"])
    XCTAssertTrue(ownerA.errors.isEmpty)

    try await activate(windowA)
    XCTAssertTrue(windowA.makeFirstResponder(fieldA))
    let documentTextBeforeNativeControls = try sessionA.snapshot().text
    let documentEventsBeforeNativeControls = eventsA.count
    send(Self.insertNative, to: windowA, trace: trace, phase: "keyboard.native-field.insert")
    XCTAssertEqual(fieldA.stringValue, "n")
    XCTAssertEqual(eventsA.count, documentEventsBeforeNativeControls)
    send(Self.commandUndo, to: windowA, trace: trace, phase: "keyboard.native-field.undo")
    XCTAssertEqual(fieldA.stringValue, "")
    XCTAssertEqual(eventsA.count, documentEventsBeforeNativeControls)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeNativeControls)
    send(Self.commandRedo, to: windowA, trace: trace, phase: "keyboard.native-field.redo")
    XCTAssertEqual(fieldA.stringValue, "n")
    XCTAssertEqual(eventsA.count, documentEventsBeforeNativeControls)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeNativeControls)

    send(Self.insertNative, to: windowA, trace: trace, phase: "keyboard.native-field.insert-menu")
    XCTAssertEqual(fieldA.stringValue, "nn")
    let menuFieldUndo = dispatch(
      menu.undoItem, window: windowA, trace: trace, phase: "menu.native-field.undo")
    XCTAssertTrue(menuFieldUndo.enabled)
    XCTAssertTrue(menuFieldUndo.sent)
    XCTAssertFalse(menuFieldUndo.targetIsHostedRouter)
    XCTAssertEqual(fieldA.stringValue, "n")
    XCTAssertEqual(eventsA.count, documentEventsBeforeNativeControls)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeNativeControls)
    let menuFieldRedo = dispatch(
      menu.redoItem, window: windowA, trace: trace, phase: "menu.native-field.redo")
    XCTAssertTrue(menuFieldRedo.enabled)
    XCTAssertTrue(menuFieldRedo.sent)
    XCTAssertFalse(menuFieldRedo.targetIsHostedRouter)
    XCTAssertEqual(fieldA.stringValue, "nn")
    XCTAssertEqual(eventsA.count, documentEventsBeforeNativeControls)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeNativeControls)

    try await focusContent(inlineWebView, in: windowA, session: sessionA, replicaID: inlineID)
    menu.undoItem.menu?.update()
    let selectedRouter = menu.undoItem.action.flatMap {
      NSApp.target(forAction: $0, to: nil, from: menu.undoItem)
    }
    XCTAssertTrue((selectedRouter as AnyObject?) === routerAInline)
    _ = try await sessionA.showFind(in: inlineID)
    try await focusFindInput(inlineWebView)
    send(Self.insertFind, to: windowA, trace: trace, phase: "keyboard.find.insert")
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    let eventsBeforeFind = eventsA.count
    let routeResultsBeforeFind = routeResultsA.count
    let documentTextBeforeFind = try sessionA.snapshot().text
    let ownerAReplacementsBeforeFind = ownerA.replacementCount
    let ownerACommandPhasesBeforeFind = ownerA.commandPhases
    try await waitUntil("Find presentation focus") {
      sessionA.focusedReplicaID() == inlineID
        && sessionA.focusedEditorContentReplicaID() == nil
    }

    send(Self.commandUndo, to: windowA, trace: trace, phase: "keyboard.find.undo")
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: ""
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind)

    send(Self.commandRedo, to: windowA, trace: trace, phase: "keyboard.find.redo")
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind)

    trace.record(
      "menu.find.selected-router.before",
      window: windowA,
      details: [
        "targetType": selectedRouter.map { String(reflecting: type(of: $0)) } ?? "nil",
        "activeElement": "cm-search-input",
      ])
    let findUndo =
      menu.undoItem.action.map {
        NSApp.sendAction($0, to: selectedRouter, from: menu.undoItem)
      } == true
    trace.record(
      "menu.find.selected-router.after",
      window: windowA,
      details: ["sent": String(findUndo)])
    XCTAssertTrue(findUndo)
    try await traceAwait(trace, "router.find.selected-cache-change") {
      try await waitUntil("embedded Find route result") {
        routeResultsA.count == routeResultsBeforeFind + 1
      }
    }
    XCTAssertEqual(routeResultsA.last, .handledByEmbeddedControl)
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind)
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: ""
    )
    let findMenuRedo = performKeyEquivalent(
      Self.commandRedo,
      item: menu.redoItem,
      window: windowA,
      trace: trace,
      phase: "menu.find.redo"
    )
    XCTAssertTrue(findMenuRedo.enabled)
    XCTAssertTrue(findMenuRedo.sent)
    XCTAssertFalse(findMenuRedo.targetIsHostedRouter)
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 1)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)

    let findMenuUndo = performKeyEquivalent(
      Self.commandUndo,
      item: menu.undoItem,
      window: windowA,
      trace: trace,
      phase: "menu.find.undo"
    )
    XCTAssertTrue(findMenuUndo.enabled)
    XCTAssertTrue(findMenuUndo.sent)
    XCTAssertFalse(findMenuUndo.targetIsHostedRouter)
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: ""
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 1)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)

    let findMenuRedoAgain = performKeyEquivalent(
      Self.commandRedo,
      item: menu.redoItem,
      window: windowA,
      trace: trace,
      phase: "menu.find.redo-again"
    )
    XCTAssertTrue(findMenuRedoAgain.enabled)
    XCTAssertTrue(findMenuRedoAgain.sent)
    XCTAssertFalse(findMenuRedoAgain.targetIsHostedRouter)
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 1)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind)
    XCTAssertEqual(ownerA.commandPhases, ownerACommandPhasesBeforeFind)

    menu.undoItem.menu?.update()
    guard let undoAction = menu.undoItem.action,
      let targetWhileFind = NSApp.target(forAction: undoAction, to: nil, from: menu.undoItem)
    else {
      XCTFail("Find focus did not provide a native Undo target")
      return
    }
    trace.record(
      "menu.reverse-find-to-content.selected",
      window: windowA,
      details: [
        "targetType": String(reflecting: type(of: targetWhileFind)),
        "targetIsHostedRouter": String(targetWhileFind is HostedCommandRouter),
        "activeElement": "cm-search-input",
      ])
    XCTAssertFalse(targetWhileFind is HostedCommandRouter)

    try await traceAwait(trace, "focus.reverse-content") {
      try await focusContentWithoutPresentation(inlineWebView, in: windowA)
    }
    let eventsBeforeStaleTarget = eventsA.count
    let routeResultsBeforeStaleTarget = routeResultsA.count
    let documentTextBeforeStaleTarget = try sessionA.snapshot().text
    let transactionsBeforeStaleTarget = transactionsA
    let ownerAReplacementsBeforeStaleTarget = ownerA.replacementCount
    let ownerACommandPhasesBeforeStaleTarget = ownerA.commandPhases
    let findQueryBeforeStaleTarget = try await evaluateString(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')"
    )
    trace.record(
      "menu.reverse-find-to-content.selected.before",
      window: windowA,
      details: ["targetType": String(reflecting: type(of: targetWhileFind))])
    let staleTargetSent = NSApp.sendAction(undoAction, to: targetWhileFind, from: menu.undoItem)
    trace.record(
      "menu.reverse-find-to-content.selected.after",
      window: windowA,
      details: ["sent": String(staleTargetSent)])
    try await traceAwait(trace, "command.reverse-find-to-content.selected.settle") {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeStaleTarget)
    XCTAssertEqual(eventsA.count, eventsBeforeStaleTarget)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeStaleTarget)
    XCTAssertEqual(ownerA.commandPhases, ownerACommandPhasesBeforeStaleTarget)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeStaleTarget)
    XCTAssertEqual(transactionsA, transactionsBeforeStaleTarget)
    let findQueryAfterStaleTarget = try await evaluateString(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')"
    )
    XCTAssertEqual(
      findQueryAfterStaleTarget,
      findQueryBeforeStaleTarget
    )

    try await traceAwait(trace, "focus.reverse-content.presentation") {
      try await waitUntil("content presentation focus") {
        sessionA.focusedEditorContentReplicaID() == inlineID
      }
    }
    let eventsBeforeReverseContent = eventsA.count
    let routeResultsBeforeReverseContent = routeResultsA.count
    let reverseContentUndo = performKeyEquivalent(
      Self.commandUndo,
      item: menu.undoItem,
      window: windowA,
      trace: trace,
      phase: "menu.reverse-find-to-content.undo"
    )
    XCTAssertTrue(reverseContentUndo.enabled)
    XCTAssertTrue(reverseContentUndo.sent)
    XCTAssertTrue(reverseContentUndo.targetIsHostedRouter)
    try await traceAwait(trace, "command.reverse-find-to-content.undo") {
      try await waitForCommandCount(
        { eventsA.count }, equals: eventsBeforeReverseContent + 1)
      try await waitUntil("content route result") {
        routeResultsA.count == routeResultsBeforeReverseContent + 1
      }
    }
    XCTAssertEqual(eventsA.last?.0, inlineID)
    XCTAssertEqual(eventsA.last?.1, .undo)
    XCTAssertEqual(routeResultsA.last, .forwardedToHost)
    XCTAssertEqual(try sessionA.snapshot().text, "one")
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind + 1)
    XCTAssertEqual(
      ownerA.commandPhases,
      ownerACommandPhasesBeforeFind + ["windowA.undo"]
    )
    XCTAssertEqual(transactionsA, transactionsAfterEditA)

    try await activate(windowB)
    try await focusContent(otherWebView, in: windowB, session: sessionB, replicaID: otherID)
    let beforeEditB = try sessionB.snapshot()
    send(Self.insertQuestion, to: windowB, trace: trace, phase: "keyboard.windowB.insert")
    try await waitForSnapshotText(sessionB, equals: "?one")
    _ = try await sessionB.flush()
    let afterEditB = try sessionB.snapshot()
    ownerB.registerUndo(from: beforeEditB, to: afterEditB, session: sessionB, replicaID: otherID)
    let beforeOwnerA = ownerA.commandPhases
    let beforeMenuB = eventsB.count
    let menuB = dispatch(menu.undoItem, window: windowB, trace: trace, phase: "menu.windowB.undo")
    XCTAssertTrue(menuB.enabled)
    XCTAssertTrue(menuB.sent)
    try await waitForCommandCount({ eventsB.count }, equals: beforeMenuB + 1)
    XCTAssertEqual(eventsB.last?.0, otherID)
    XCTAssertEqual(eventsB.last?.1, .undo)
    try await waitForSnapshotText(sessionB, equals: "one")
    XCTAssertEqual(ownerA.commandPhases, beforeOwnerA)
    XCTAssertEqual(transactionsB, 0)
    XCTAssertTrue(ownerB.errors.isEmpty)
  }

  private func installEditMenu() -> (menu: NSMenu, undoItem: NSMenuItem, redoItem: NSMenuItem) {
    let mainMenu = NSMenu(title: "Main")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    mainMenu.addItem(editItem)
    mainMenu.setSubmenu(editMenu, for: editItem)
    let undoItem = NSMenuItem(
      title: "Undo", action: #selector(HostedCommandRouter.undo(_:)), keyEquivalent: "z")
    undoItem.keyEquivalentModifierMask = [.command]
    let redoItem = NSMenuItem(
      title: "Redo", action: #selector(HostedCommandRouter.redo(_:)), keyEquivalent: "Z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(undoItem)
    editMenu.addItem(redoItem)
    return (mainMenu, undoItem, redoItem)
  }

  private func dispatch(
    _ item: NSMenuItem,
    window: NSWindow,
    trace: HostedPhaseTrace,
    phase: String
  ) -> MenuDispatch {
    item.menu?.update()
    let action = item.action
    let target = action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }
    let enabled = item.isEnabled
    let targetIsHostedRouter = target is HostedCommandRouter
    trace.record(
      phase + ".validated",
      window: window,
      details: [
        "menu": item.menu?.title ?? "nil",
        "targetType": target.map { String(reflecting: type(of: $0)) } ?? "nil",
        "enabled": String(enabled),
        "targetIsHostedRouter": String(targetIsHostedRouter),
      ])
    let sent = enabled && action.map { NSApp.sendAction($0, to: nil, from: item) } == true
    trace.record(
      phase + ".after",
      window: window,
      details: [
        "menu": item.menu?.title ?? "nil",
        "targetType": target.map { String(reflecting: type(of: $0)) } ?? "nil",
        "enabled": String(enabled),
        "sent": String(sent),
        "targetIsHostedRouter": String(targetIsHostedRouter),
      ])
    return MenuDispatch(
      enabled: enabled, sent: sent, targetIsHostedRouter: targetIsHostedRouter)
  }

  private func makeWebView(for coordinator: CodeMirrorEditorCoordinator, frame: NSRect) -> WKWebView
  {
    let contentController = WKUserContentController()
    contentController.add(coordinator, name: CodeMirrorEditorCoordinator.messageHandlerName)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = contentController
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    return WKWebView(frame: frame, configuration: configuration)
  }

  private func activate(_ window: NSWindow) async throws {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    try await waitUntil("window activation") {
      NSApp.isActive && window.isVisible && window.isKeyWindow
    }
  }

  private func focusContent(
    _ webView: WKWebView,
    in window: NSWindow,
    session: CodeMirrorSession,
    replicaID: CodeMirrorReplicaID
  ) async throws {
    XCTAssertTrue(window.makeFirstResponder(webView))
    try await waitUntil("native CodeMirror responder") { window.firstResponder === webView }
    try await waitForDOMValue(
      webView,
      script:
        "(() => { const content = document.querySelector('.cm-content'); content?.focus(); return String(document.activeElement === content); })()",
      equals: "true"
    )
    try await waitUntil("content focus scope") {
      session.focusedEditorContentReplicaID() == replicaID
    }
  }

  private func focusContentWithoutPresentation(_ webView: WKWebView, in window: NSWindow)
    async
    throws
  {
    XCTAssertTrue(window.makeFirstResponder(webView))
    try await waitUntil("native CodeMirror responder") { window.firstResponder === webView }
    try await waitForDOMValue(
      webView,
      script:
        "(() => { const content = document.querySelector('.cm-content'); content?.focus(); return String(document.activeElement === content); })()",
      equals: "true"
    )
  }

  private func focusFindInput(_ webView: WKWebView) async throws {
    try await waitForDOMValue(
      webView,
      script:
        "(() => { const input = document.querySelector('.cm-search input'); if (!input) { return 'missing'; } input.focus(); return String(document.activeElement === input); })()",
      equals: "true"
    )
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
        "modifierFlags": String(key.modifiers.rawValue),
        "targetType": window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil",
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

  private func performKeyEquivalent(
    _ key: KeyStroke,
    item: NSMenuItem,
    window: NSWindow,
    trace: HostedPhaseTrace,
    phase: String
  ) -> MenuDispatch {
    let owningMenu = item.menu
    owningMenu?.update()
    let target = item.action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }
    let enabled = item.isEnabled
    let targetIsHostedRouter = target is HostedCommandRouter
    let responderUndoManager = window.firstResponder?.undoManager
    trace.record(
      phase + ".validated",
      window: window,
      details: [
        "menu": owningMenu?.title ?? "nil",
        "targetType": target.map { String(reflecting: type(of: $0)) } ?? "nil",
        "enabled": String(enabled),
        "targetIsHostedRouter": String(targetIsHostedRouter),
        "responderCanUndo": String(responderUndoManager?.canUndo ?? false),
        "responderCanRedo": String(responderUndoManager?.canRedo ?? false),
        "characters": key.characters,
        "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
      ])
    guard enabled,
      let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: key.modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: key.characters,
        charactersIgnoringModifiers: key.charactersIgnoringModifiers,
        isARepeat: false,
        keyCode: key.keyCode
      )
    else {
      trace.record(
        phase + ".after",
        window: window,
        details: [
          "enabled": String(enabled),
          "performed": "false",
          "targetIsHostedRouter": String(targetIsHostedRouter),
        ])
      return MenuDispatch(
        enabled: enabled, sent: false, targetIsHostedRouter: targetIsHostedRouter)
    }
    let performed = owningMenu?.performKeyEquivalent(with: event) == true
    trace.record(
      phase + ".after",
      window: window,
      details: [
        "menu": owningMenu?.title ?? "nil",
        "targetType": target.map { String(reflecting: type(of: $0)) } ?? "nil",
        "enabled": String(enabled),
        "performed": String(performed),
        "targetIsHostedRouter": String(targetIsHostedRouter),
      ])
    return MenuDispatch(
      enabled: enabled, sent: performed, targetIsHostedRouter: targetIsHostedRouter)
  }

  private func traceAwait<T>(
    _ trace: HostedPhaseTrace,
    _ phase: String,
    operation: @MainActor () async throws -> T
  ) async throws -> T {
    trace.record(phase + ".before")
    do {
      let value = try await operation()
      trace.record(phase + ".after")
      return value
    } catch {
      trace.record(phase + ".error", error: error)
      throw error
    }
  }

  private func waitForSnapshotText(_ session: CodeMirrorSession, equals expected: String)
    async throws
  {
    try await waitUntil("session snapshot") { (try? session.snapshot().text) == expected }
  }

  private func waitForCommandCount(
    _ count: @escaping @MainActor () -> Int,
    equals expected: Int
  ) async throws {
    try await waitUntil("command event") { count() == expected }
  }

  private func waitForDOMValue(
    _ webView: WKWebView,
    script: String,
    equals expected: String
  ) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ 2_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
      if (try? await evaluateString(webView, script: script)) == expected { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    throw NSError(
      domain: "HostedF4CommandRoutingTests",
      code: 4,
      userInfo: [NSLocalizedDescriptionKey: "timed out waiting for DOM value"]
    )
  }

  private func waitUntil(
    _ description: String,
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
    while !condition() {
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        throw NSError(
          domain: "HostedF4CommandRoutingTests",
          code: 1,
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
                  domain: "HostedF4CommandRoutingTests",
                  code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "JavaScript value was not a String"]
                )))
          }
        }
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        evaluation.finish(
          .failure(
            NSError(
              domain: "HostedF4CommandRoutingTests",
              code: 3,
              userInfo: [NSLocalizedDescriptionKey: "JavaScript evaluation timed out"]
            )))
      }
    }
  }
}
