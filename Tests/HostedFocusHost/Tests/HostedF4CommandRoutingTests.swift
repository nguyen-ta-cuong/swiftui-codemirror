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

  private struct FindState: Equatable {
    let value: String
    let activeElement: String
  }

  private struct FindMenuObservation: Equatable {
    let find: FindState
    let fieldEqualsPreFind: Bool
    let fieldUTF16Length: Int
    let windowCanUndo: Bool
    let windowCanRedo: Bool
    let responderCanUndo: Bool
    let responderCanRedo: Bool
    let windowUndoManager: String
    let responderUndoManager: String
    let groupingLevel: Int
    let undoActionName: String
    let redoActionName: String
    let ownerReplacementCount: Int
    let ownerCommandPhases: [String]
    let eventCount: Int
    let routeResultCount: Int
    let snapshot: CodeMirrorSnapshot
    let transactionCount: Int
  }

  private struct FindMenuAttempt {
    let enabled: Bool
    let attempted: Bool
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
    private static let documentActionName = "Document Edit"

    let name: String
    let undoManager = UndoManager()
    private let trace: HostedPhaseTrace
    private let target = NSObject()
    private(set) var commandPhases: [String] = []
    private(set) var replacementCount = 0
    private(set) var errors: [Error] = []

    init(name: String, trace: HostedPhaseTrace) {
      self.name = name
      self.trace = trace
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
      let isDirectDocumentRegistration = !undoManager.isUndoing && !undoManager.isRedoing
      let beforeBegin = undoManager.groupingLevel
      var afterBegin = beforeBegin
      if isDirectDocumentRegistration {
        trace.record("document.\(name).group.begin.before", details: traceDetails)
        undoManager.beginUndoGrouping()
        afterBegin = undoManager.groupingLevel
        trace.record(
          "document.\(name).group.begin.after",
          details: traceDetails.merging([
            "beforeBegin": String(beforeBegin),
            "afterBegin": String(afterBegin),
          ]) { _, new in new })
      }
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
      if isDirectDocumentRegistration {
        let beforeEnd = undoManager.groupingLevel
        trace.record("document.\(name).group.end.before", details: traceDetails)
        undoManager.endUndoGrouping()
        let afterEnd = undoManager.groupingLevel
        trace.record(
          "document.\(name).group.end.after",
          details: traceDetails.merging([
            "beforeBegin": String(beforeBegin),
            "afterBegin": String(afterBegin),
            "beforeEnd": String(beforeEnd),
            "afterEnd": String(afterEnd),
          ]) { _, new in new })
        XCTAssertEqual(afterEnd, beforeEnd - 1)
        undoManager.setActionName(Self.documentActionName)
      }
      _ = current
    }

    var traceDetails: [String: String] {
      [
        "groupingLevel": String(undoManager.groupingLevel),
        "undoActionName": undoManager.undoActionName,
        "redoActionName": undoManager.redoActionName,
      ]
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

  @MainActor
  private final class ContextWindowMap {
    var values: [CodeMirrorReplicaID: NSWindow] = [:]
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

    let ownerA = UndoOwner(name: "windowA", trace: trace)
    let ownerB = UndoOwner(name: "windowB", trace: trace)
    let inlineID = CodeMirrorReplicaID()
    let detachedID = CodeMirrorReplicaID()
    let otherID = CodeMirrorReplicaID()
    var eventsA: [(CodeMirrorReplicaID, CodeMirrorCommand)] = []
    var eventsB: [(CodeMirrorReplicaID, CodeMirrorCommand)] = []
    var routeResultsA: [CodeMirrorCommandRoutingResult] = []
    var detachedRouteResultsA: [CodeMirrorCommandRoutingResult] = []
    var transactionsA = 0
    var transactionsB = 0
    let contextWindows = ContextWindowMap()

    let sessionA = CodeMirrorSession(initialText: "one") { event in
      switch event {
      case .command(let replicaID, let command):
        eventsA.append((replicaID, command))
        ownerA.handle(command)
      case .transaction:
        transactionsA += 1
      case .commandContextChanged(let replicaID):
        if let window = contextWindows.values[replicaID] {
          application.commandRouterRegistry.commandContextDidChange(
            in: window, replicaID: replicaID)
        }
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
      case .commandContextChanged(let replicaID):
        if let window = contextWindows.values[replicaID] {
          application.commandRouterRegistry.commandContextDidChange(
            in: window, replicaID: replicaID)
        }
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
    contextWindows.values[inlineID] = windowA
    contextWindows.values[detachedID] = detachedWindow
    contextWindows.values[otherID] = windowB
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
      detachedRouteResultsA.append(result)
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
    XCTAssertEqual(sessionA.focusedCommandContext(), .content(inlineID))

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
    XCTAssertEqual(sessionA.focusedCommandContext(), .content(detachedID))
    _ = try await sessionA.flush()
    let beforeMenuRedo = eventsA.count
    guard let editMenu = menu.redoItem.menu else {
      XCTFail("Redo menu item has no owning Edit menu")
      return
    }
    editMenu.update()
    let redoIndex = editMenu.index(of: menu.redoItem)
    let redoEnabled = menu.redoItem.isEnabled
    trace.record(
      "menu.content.redo.validated",
      window: detachedWindow,
      details: [
        "menu": editMenu.title,
        "index": String(redoIndex),
        "enabled": String(redoEnabled),
      ])
    XCTAssertTrue(redoEnabled)
    XCTAssertGreaterThanOrEqual(redoIndex, 0)
    guard redoEnabled, redoIndex >= 0 else { return }
    trace.record(
      "menu.content.redo.attempt",
      window: detachedWindow,
      details: ["menu": editMenu.title, "index": String(redoIndex)])
    editMenu.performActionForItem(at: redoIndex)
    trace.record(
      "menu.content.redo.after",
      window: detachedWindow,
      details: ["menu": editMenu.title, "index": String(redoIndex), "attempted": "true"])
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
    let contentRearmBefore = try sessionA.snapshot()
    send(Self.insertQuestion, to: windowA, trace: trace, phase: "keyboard.content.rearm.insert")
    try await waitUntil("content rearm edit") {
      guard let text = try? sessionA.snapshot().text else { return false }
      return text != contentRearmBefore.text
    }
    _ = try await sessionA.flush()
    let contentRearmAfter = try sessionA.snapshot()
    ownerA.registerUndo(
      from: contentRearmBefore, to: contentRearmAfter, session: sessionA, replicaID: inlineID)
    trace.record("document.rearm.registration", details: ownerA.traceDetails)

    let fieldValueBeforeFind = fieldA.stringValue
    let fieldUTF16LengthBeforeFind = fieldValueBeforeFind.utf16.count
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
    trace.record("menu.find.actual.undo.grouping", details: ownerA.traceDetails)
    let eventsBeforeFind = eventsA.count
    let routeResultsBeforeFind = routeResultsA.count
    let documentTextBeforeFind = try sessionA.snapshot().text
    let ownerAReplacementsBeforeFind = ownerA.replacementCount
    let ownerACommandPhasesBeforeFind = ownerA.commandPhases
    try await waitUntil("Find presentation focus") {
      sessionA.focusedReplicaID() == inlineID
        && sessionA.focusedCommandContext() != nil
        && !self.isContentContext(sessionA.focusedCommandContext(), replicaID: inlineID)
    }

    let documentSnapshotBeforeFind = try sessionA.snapshot()
    let transactionsBeforeFind = transactionsA
    let observeCurrentFindMenuState: @MainActor () async throws -> FindMenuObservation = {
      try await self.observeFindMenuState(
        webView: inlineWebView,
        window: windowA,
        field: fieldA,
        fieldValueBeforeFind: fieldValueBeforeFind,
        owner: ownerA,
        session: sessionA,
        eventCount: eventsA.count,
        routeResultCount: routeResultsA.count,
        documentBaseline: documentSnapshotBeforeFind,
        transactionCount: transactionsA
      )
    }

    let actualFindUndoBefore = try await observeCurrentFindMenuState()
    recordFindMenuState(
      "menu.find.actual.undo.before",
      observation: actualFindUndoBefore,
      documentBaseline: documentSnapshotBeforeFind,
      window: windowA,
      trace: trace
    )
    XCTAssertEqual(actualFindUndoBefore.find.value, "q")
    let actualFindUndo = performFindMenuAction(
      menu.undoItem,
      window: windowA,
      trace: trace,
      phase: "menu.find.actual.undo"
    )
    XCTAssertTrue(actualFindUndo.enabled)
    XCTAssertTrue(actualFindUndo.attempted)
    let actualFindUndoAfter = try await settleFindMenuAction(
      "menu.find.actual.undo.settle",
      before: actualFindUndoBefore,
      expectedFindValue: "",
      expectedRouteResultCount: routeResultsBeforeFind + 1,
      observe: observeCurrentFindMenuState,
      trace: trace
    )
    recordFindMenuState(
      "menu.find.actual.undo.after",
      observation: actualFindUndoAfter,
      documentBaseline: documentSnapshotBeforeFind,
      window: windowA,
      trace: trace
    )
    XCTAssertEqual(actualFindUndoAfter.find.value, "")
    assertFindMenuIsolation(
      actualFindUndoAfter,
      expectedFindValue: "",
      documentBaseline: documentSnapshotBeforeFind,
      baselineEventCount: eventsBeforeFind,
      baselineRouteResultCount: routeResultsBeforeFind + 1,
      baselineOwnerReplacementCount: ownerAReplacementsBeforeFind,
      baselineOwnerCommandPhases: ownerACommandPhasesBeforeFind,
      baselineTransactionCount: transactionsBeforeFind,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    let actualFindRedoBefore = try await observeCurrentFindMenuState()
    recordFindMenuState(
      "menu.find.actual.redo.before",
      observation: actualFindRedoBefore,
      documentBaseline: documentSnapshotBeforeFind,
      window: windowA,
      trace: trace
    )
    XCTAssertEqual(actualFindRedoBefore.find.value, "")
    let actualFindRedo = performFindMenuAction(
      menu.redoItem,
      window: windowA,
      trace: trace,
      phase: "menu.find.actual.redo"
    )
    XCTAssertTrue(actualFindRedo.enabled)
    XCTAssertTrue(actualFindRedo.attempted)
    let actualFindRedoAfter = try await settleFindMenuAction(
      "menu.find.actual.redo.settle",
      before: actualFindRedoBefore,
      expectedFindValue: "q",
      expectedRouteResultCount: routeResultsBeforeFind + 2,
      observe: observeCurrentFindMenuState,
      trace: trace
    )
    recordFindMenuState(
      "menu.find.actual.redo.after",
      observation: actualFindRedoAfter,
      documentBaseline: documentSnapshotBeforeFind,
      window: windowA,
      trace: trace
    )
    XCTAssertEqual(actualFindRedoAfter.find.value, "q")
    assertFindMenuIsolation(
      actualFindRedoAfter,
      expectedFindValue: "q",
      documentBaseline: documentSnapshotBeforeFind,
      baselineEventCount: eventsBeforeFind,
      baselineRouteResultCount: routeResultsBeforeFind + 2,
      baselineOwnerReplacementCount: ownerAReplacementsBeforeFind,
      baselineOwnerCommandPhases: ownerACommandPhasesBeforeFind,
      baselineTransactionCount: transactionsBeforeFind,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    send(Self.commandUndo, to: windowA, trace: trace, phase: "keyboard.find.undo")
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: ""
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 2)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind)
    let rawInlineUndo = try await observeCurrentFindMenuState()
    assertFindMenuIsolation(
      rawInlineUndo,
      expectedFindValue: "",
      documentBaseline: documentSnapshotBeforeFind,
      baselineEventCount: eventsBeforeFind,
      baselineRouteResultCount: routeResultsBeforeFind + 2,
      baselineOwnerReplacementCount: ownerAReplacementsBeforeFind,
      baselineOwnerCommandPhases: ownerACommandPhasesBeforeFind,
      baselineTransactionCount: transactionsBeforeFind,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    send(Self.commandRedo, to: windowA, trace: trace, phase: "keyboard.find.redo")
    try await waitForDOMValue(
      inlineWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    XCTAssertEqual(eventsA.count, eventsBeforeFind)
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 2)
    XCTAssertEqual(try sessionA.snapshot().text, documentTextBeforeFind)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind)
    let rawInlineRedo = try await observeCurrentFindMenuState()
    assertFindMenuIsolation(
      rawInlineRedo,
      expectedFindValue: "q",
      documentBaseline: documentSnapshotBeforeFind,
      baselineEventCount: eventsBeforeFind,
      baselineRouteResultCount: routeResultsBeforeFind + 2,
      baselineOwnerReplacementCount: ownerAReplacementsBeforeFind,
      baselineOwnerCommandPhases: ownerACommandPhasesBeforeFind,
      baselineTransactionCount: transactionsBeforeFind,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

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
        routeResultsA.count == routeResultsBeforeFind + 3
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
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 4)
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
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 5)
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
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeFind + 6)
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

    let detachedFindBaseline = try sessionA.snapshot()
    let detachedFindTransactions = transactionsA
    let detachedFindEvents = eventsA.count
    let detachedFindReplacements = ownerA.replacementCount
    let detachedFindPhases = ownerA.commandPhases
    try await activate(detachedWindow)
    _ = try await sessionA.showFind(in: detachedID)
    try await focusFindInput(detachedWebView)
    send(Self.insertFind, to: detachedWindow, trace: trace, phase: "keyboard.detached-find.insert")
    try await waitForDOMValue(
      detachedWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    try await waitUntil("detached Find presentation focus") {
      sessionA.focusedReplicaID() == detachedID
        && !self.isContentContext(sessionA.focusedCommandContext(), replicaID: detachedID)
    }
    let detachedFindResultsBefore = detachedRouteResultsA.count
    let observeDetachedFind: @MainActor () async throws -> FindMenuObservation = {
      try await self.observeFindMenuState(
        webView: detachedWebView,
        window: detachedWindow,
        field: fieldA,
        fieldValueBeforeFind: fieldValueBeforeFind,
        owner: ownerA,
        session: sessionA,
        eventCount: eventsA.count,
        routeResultCount: detachedRouteResultsA.count,
        documentBaseline: detachedFindBaseline,
        transactionCount: transactionsA
      )
    }
    let detachedUndoBefore = try await observeDetachedFind()
    let detachedUndo = performFindMenuAction(
      menu.undoItem,
      window: detachedWindow,
      trace: trace,
      phase: "menu.detached-find.undo"
    )
    XCTAssertTrue(detachedUndo.enabled)
    XCTAssertTrue(detachedUndo.attempted)
    let detachedUndoAfter = try await settleFindMenuAction(
      "menu.detached-find.undo.settle",
      before: detachedUndoBefore,
      expectedFindValue: "",
      expectedRouteResultCount: detachedFindResultsBefore + 1,
      observe: observeDetachedFind,
      trace: trace
    )
    assertFindMenuIsolation(
      detachedUndoAfter,
      expectedFindValue: "",
      documentBaseline: detachedFindBaseline,
      baselineEventCount: detachedFindEvents,
      baselineRouteResultCount: detachedFindResultsBefore + 1,
      baselineOwnerReplacementCount: detachedFindReplacements,
      baselineOwnerCommandPhases: detachedFindPhases,
      baselineTransactionCount: detachedFindTransactions,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    let detachedRedoBefore = try await observeDetachedFind()
    let detachedRedo = performFindMenuAction(
      menu.redoItem,
      window: detachedWindow,
      trace: trace,
      phase: "menu.detached-find.redo"
    )
    XCTAssertTrue(detachedRedo.enabled)
    XCTAssertTrue(detachedRedo.attempted)
    let detachedRedoAfter = try await settleFindMenuAction(
      "menu.detached-find.redo.settle",
      before: detachedRedoBefore,
      expectedFindValue: "q",
      expectedRouteResultCount: detachedFindResultsBefore + 2,
      observe: observeDetachedFind,
      trace: trace
    )
    assertFindMenuIsolation(
      detachedRedoAfter,
      expectedFindValue: "q",
      documentBaseline: detachedFindBaseline,
      baselineEventCount: detachedFindEvents,
      baselineRouteResultCount: detachedFindResultsBefore + 2,
      baselineOwnerReplacementCount: detachedFindReplacements,
      baselineOwnerCommandPhases: detachedFindPhases,
      baselineTransactionCount: detachedFindTransactions,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    send(Self.commandUndo, to: detachedWindow, trace: trace, phase: "keyboard.detached-find.undo")
    try await waitForDOMValue(
      detachedWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: ""
    )
    XCTAssertEqual(detachedRouteResultsA.count, detachedFindResultsBefore + 2)
    XCTAssertEqual(eventsA.count, detachedFindEvents)
    XCTAssertEqual(try sessionA.snapshot(), detachedFindBaseline)
    let rawDetachedUndo = try await observeDetachedFind()
    assertFindMenuIsolation(
      rawDetachedUndo,
      expectedFindValue: "",
      documentBaseline: detachedFindBaseline,
      baselineEventCount: detachedFindEvents,
      baselineRouteResultCount: detachedFindResultsBefore + 2,
      baselineOwnerReplacementCount: detachedFindReplacements,
      baselineOwnerCommandPhases: detachedFindPhases,
      baselineTransactionCount: detachedFindTransactions,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    send(Self.commandRedo, to: detachedWindow, trace: trace, phase: "keyboard.detached-find.redo")
    try await waitForDOMValue(
      detachedWebView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')",
      equals: "q"
    )
    XCTAssertEqual(detachedRouteResultsA.count, detachedFindResultsBefore + 2)
    XCTAssertEqual(eventsA.count, detachedFindEvents)
    XCTAssertEqual(try sessionA.snapshot(), detachedFindBaseline)
    let rawDetachedRedo = try await observeDetachedFind()
    assertFindMenuIsolation(
      rawDetachedRedo,
      expectedFindValue: "q",
      documentBaseline: detachedFindBaseline,
      baselineEventCount: detachedFindEvents,
      baselineRouteResultCount: detachedFindResultsBefore + 2,
      baselineOwnerReplacementCount: detachedFindReplacements,
      baselineOwnerCommandPhases: detachedFindPhases,
      baselineTransactionCount: detachedFindTransactions,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    let detachedKeyEquivalentUndoBefore = try await observeDetachedFind()
    let detachedKeyEquivalentUndo = performKeyEquivalent(
      Self.commandUndo,
      item: menu.undoItem,
      window: detachedWindow,
      trace: trace,
      phase: "menu.detached-find.key-equivalent.undo"
    )
    XCTAssertTrue(detachedKeyEquivalentUndo.enabled)
    XCTAssertTrue(detachedKeyEquivalentUndo.sent)
    XCTAssertFalse(detachedKeyEquivalentUndo.targetIsHostedRouter)
    let detachedKeyEquivalentUndoAfter = try await settleFindMenuAction(
      "menu.detached-find.key-equivalent.undo.settle",
      before: detachedKeyEquivalentUndoBefore,
      expectedFindValue: "",
      expectedRouteResultCount: detachedFindResultsBefore + 3,
      observe: observeDetachedFind,
      trace: trace
    )
    XCTAssertEqual(detachedRouteResultsA.last, .handledByEmbeddedControl)
    assertFindMenuIsolation(
      detachedKeyEquivalentUndoAfter,
      expectedFindValue: "",
      documentBaseline: detachedFindBaseline,
      baselineEventCount: detachedFindEvents,
      baselineRouteResultCount: detachedFindResultsBefore + 3,
      baselineOwnerReplacementCount: detachedFindReplacements,
      baselineOwnerCommandPhases: detachedFindPhases,
      baselineTransactionCount: detachedFindTransactions,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    let detachedKeyEquivalentRedoBefore = try await observeDetachedFind()
    let detachedKeyEquivalentRedo = performKeyEquivalent(
      Self.commandRedo,
      item: menu.redoItem,
      window: detachedWindow,
      trace: trace,
      phase: "menu.detached-find.key-equivalent.redo"
    )
    XCTAssertTrue(detachedKeyEquivalentRedo.enabled)
    XCTAssertTrue(detachedKeyEquivalentRedo.sent)
    XCTAssertFalse(detachedKeyEquivalentRedo.targetIsHostedRouter)
    let detachedKeyEquivalentRedoAfter = try await settleFindMenuAction(
      "menu.detached-find.key-equivalent.redo.settle",
      before: detachedKeyEquivalentRedoBefore,
      expectedFindValue: "q",
      expectedRouteResultCount: detachedFindResultsBefore + 4,
      observe: observeDetachedFind,
      trace: trace
    )
    XCTAssertEqual(detachedRouteResultsA.last, .handledByEmbeddedControl)
    assertFindMenuIsolation(
      detachedKeyEquivalentRedoAfter,
      expectedFindValue: "q",
      documentBaseline: detachedFindBaseline,
      baselineEventCount: detachedFindEvents,
      baselineRouteResultCount: detachedFindResultsBefore + 4,
      baselineOwnerReplacementCount: detachedFindReplacements,
      baselineOwnerCommandPhases: detachedFindPhases,
      baselineTransactionCount: detachedFindTransactions,
      baselineFieldUTF16Length: fieldUTF16LengthBeforeFind
    )

    try await traceAwait(trace, "focus.reverse-content") {
      try await activate(windowA)
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
      try await waitUntil("stale Find route result") {
        routeResultsA.count == routeResultsBeforeStaleTarget + 1
      }
    }
    XCTAssertEqual(routeResultsA.count, routeResultsBeforeStaleTarget + 1)
    XCTAssertEqual(routeResultsA.last, .unavailable)
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
        self.isContentContext(sessionA.focusedCommandContext(), replicaID: inlineID)
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
    XCTAssertEqual(try sessionA.snapshot().text, contentRearmBefore.text)
    XCTAssertEqual(ownerA.replacementCount, ownerAReplacementsBeforeFind + 1)
    XCTAssertEqual(
      ownerA.commandPhases,
      ownerACommandPhasesBeforeFind + ["windowA.undo"]
    )
    XCTAssertEqual(transactionsA, transactionsBeforeFind)

    try await activate(windowB)
    try await focusContent(otherWebView, in: windowB, session: sessionB, replicaID: otherID)
    let beforeEditB = try sessionB.snapshot()
    send(Self.insertQuestion, to: windowB, trace: trace, phase: "keyboard.windowB.insert")
    try await waitForSnapshotText(sessionB, equals: "?one")
    _ = try await sessionB.flush()
    let afterEditB = try sessionB.snapshot()
    let transactionsAfterEditB = transactionsB
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
    XCTAssertEqual(transactionsB, transactionsAfterEditB)
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

  private func findState(in webView: WKWebView) async throws -> FindState {
    let value = try await evaluateString(
      webView,
      script: "String(document.querySelector('.cm-search input')?.value ?? '')"
    )
    let activeElement = try await evaluateString(
      webView,
      script:
        "String(document.activeElement === document.querySelector('.cm-search input') ? 'cm-search-input' : 'other')"
    )
    return FindState(value: value, activeElement: activeElement)
  }

  private func isContentContext(
    _ context: CodeMirrorFocusedCommandContext?,
    replicaID: CodeMirrorReplicaID
  ) -> Bool {
    if case .content(let focusedReplicaID) = context {
      return focusedReplicaID == replicaID
    }
    return false
  }

  private func undoManagerRelationship(_ manager: UndoManager?, owner: UndoManager) -> String {
    guard let manager else { return "none" }
    return manager === owner ? "owner" : "other"
  }

  private func observeFindMenuState(
    webView: WKWebView,
    window: NSWindow,
    field: NSTextField,
    fieldValueBeforeFind: String,
    owner: UndoOwner,
    session: CodeMirrorSession,
    eventCount: Int,
    routeResultCount: Int,
    documentBaseline: CodeMirrorSnapshot,
    transactionCount: Int
  ) async throws -> FindMenuObservation {
    let find = try await findState(in: webView)
    let snapshot = try session.snapshot()
    let windowUndoManager = window.undoManager
    let responderUndoManager = window.firstResponder?.undoManager
    return FindMenuObservation(
      find: find,
      fieldEqualsPreFind: field.stringValue == fieldValueBeforeFind,
      fieldUTF16Length: field.stringValue.utf16.count,
      windowCanUndo: windowUndoManager?.canUndo ?? false,
      windowCanRedo: windowUndoManager?.canRedo ?? false,
      responderCanUndo: responderUndoManager?.canUndo ?? false,
      responderCanRedo: responderUndoManager?.canRedo ?? false,
      windowUndoManager: undoManagerRelationship(windowUndoManager, owner: owner.undoManager),
      responderUndoManager: undoManagerRelationship(responderUndoManager, owner: owner.undoManager),
      groupingLevel: owner.undoManager.groupingLevel,
      undoActionName: owner.undoManager.undoActionName,
      redoActionName: owner.undoManager.redoActionName,
      ownerReplacementCount: owner.replacementCount,
      ownerCommandPhases: owner.commandPhases,
      eventCount: eventCount,
      routeResultCount: routeResultCount,
      snapshot: snapshot,
      transactionCount: transactionCount
    )
  }

  private func recordFindMenuState(
    _ phase: String,
    observation: FindMenuObservation,
    documentBaseline: CodeMirrorSnapshot,
    window: NSWindow,
    trace: HostedPhaseTrace
  ) {
    trace.record(
      phase,
      window: window,
      details: [
        "findValue": observation.find.value,
        "activeElement": observation.find.activeElement,
        "fieldEqualsPreFind": String(observation.fieldEqualsPreFind),
        "fieldUTF16Length": String(observation.fieldUTF16Length),
        "windowCanUndo": String(observation.windowCanUndo),
        "windowCanRedo": String(observation.windowCanRedo),
        "responderCanUndo": String(observation.responderCanUndo),
        "responderCanRedo": String(observation.responderCanRedo),
        "windowUndoManager": observation.windowUndoManager,
        "responderUndoManager": observation.responderUndoManager,
        "groupingLevel": String(observation.groupingLevel),
        "undoActionName": observation.undoActionName,
        "redoActionName": observation.redoActionName,
        "ownerReplacementCount": String(observation.ownerReplacementCount),
        "ownerCommandPhases": observation.ownerCommandPhases.joined(separator: "|"),
        "eventCount": String(observation.eventCount),
        "routeResultCount": String(observation.routeResultCount),
        "snapshotRevision": String(observation.snapshot.revision.rawValue),
        "snapshotEqualBaseline": String(observation.snapshot == documentBaseline),
        "transactionCount": String(observation.transactionCount),
      ])
  }

  private func assertFindMenuIsolation(
    _ observation: FindMenuObservation,
    expectedFindValue: String,
    documentBaseline: CodeMirrorSnapshot,
    baselineEventCount: Int,
    baselineRouteResultCount: Int,
    baselineOwnerReplacementCount: Int,
    baselineOwnerCommandPhases: [String],
    baselineTransactionCount: Int,
    baselineFieldUTF16Length: Int
  ) {
    XCTAssertEqual(observation.find.value, expectedFindValue)
    XCTAssertEqual(observation.find.activeElement, "cm-search-input")
    XCTAssertTrue(observation.fieldEqualsPreFind)
    XCTAssertEqual(observation.fieldUTF16Length, baselineFieldUTF16Length)
    XCTAssertEqual(observation.eventCount, baselineEventCount)
    XCTAssertEqual(observation.routeResultCount, baselineRouteResultCount)
    XCTAssertEqual(observation.ownerReplacementCount, baselineOwnerReplacementCount)
    XCTAssertEqual(observation.ownerCommandPhases, baselineOwnerCommandPhases)
    XCTAssertEqual(observation.snapshot.revision, documentBaseline.revision)
    XCTAssertEqual(observation.snapshot, documentBaseline)
    XCTAssertEqual(observation.transactionCount, baselineTransactionCount)
  }

  private func performFindMenuAction(
    _ item: NSMenuItem,
    window: NSWindow,
    trace: HostedPhaseTrace,
    phase: String
  ) -> FindMenuAttempt {
    guard let owningMenu = item.menu else {
      XCTFail("Find menu item has no owning menu")
      return FindMenuAttempt(enabled: false, attempted: false)
    }
    owningMenu.update()
    let target = item.action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }
    let index = owningMenu.index(of: item)
    let enabled = item.isEnabled
    let targetType = target.map { String(reflecting: type(of: $0)) } ?? "nil"
    trace.record(
      phase + ".validated",
      window: window,
      details: [
        "menu": owningMenu.title,
        "index": String(index),
        "enabled": String(enabled),
        "targetType": targetType,
        "attempted": "false",
      ])
    guard enabled, index >= 0 else {
      trace.record(
        phase + ".after",
        window: window,
        details: [
          "menu": owningMenu.title,
          "index": String(index),
          "enabled": String(enabled),
          "targetType": targetType,
          "attempted": "false",
        ])
      return FindMenuAttempt(enabled: enabled, attempted: false)
    }
    owningMenu.performActionForItem(at: index)
    trace.record(
      phase + ".after",
      window: window,
      details: [
        "menu": owningMenu.title,
        "index": String(index),
        "enabled": String(enabled),
        "targetType": targetType,
        "attempted": "true",
      ])
    return FindMenuAttempt(enabled: enabled, attempted: true)
  }

  private func settleFindMenuAction(
    _ phase: String,
    before: FindMenuObservation,
    expectedFindValue: String,
    expectedRouteResultCount: Int,
    observe: @escaping @MainActor () async throws -> FindMenuObservation,
    trace: HostedPhaseTrace
  ) async throws -> FindMenuObservation {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ 2_000_000_000
    var current = try await observe()
    while current.find.value != expectedFindValue
      || current.routeResultCount != expectedRouteResultCount
    {
      guard DispatchTime.now().uptimeNanoseconds < deadline else {
        trace.record(
          phase + ".timeout",
          details: [
            "changed": String(current != before),
            "findValueExpected": expectedFindValue,
            "findValueObserved": current.find.value,
            "routeResultCountExpected": String(expectedRouteResultCount),
            "routeResultCountObserved": String(current.routeResultCount),
            "timeout": "2000ms",
          ])
        return current
      }
      try await Task.sleep(nanoseconds: 25_000_000)
      current = try await observe()
    }
    trace.record(phase + ".changed", details: ["changed": "true"])
    return current
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
    return CodeMirrorWebView(frame: frame, configuration: configuration)
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
      self.isContentContext(session.focusedCommandContext(), replicaID: replicaID)
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
