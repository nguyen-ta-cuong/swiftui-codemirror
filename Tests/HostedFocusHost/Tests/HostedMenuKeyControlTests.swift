import AppKit
import XCTest

@MainActor
final class HostedMenuKeyControlTests: XCTestCase {
  private struct KeyStroke {
    let characters: String
    let charactersIgnoringModifiers: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
  }

  @MainActor
  private final class HostedUndoOwner {
    let undoManager = UndoManager()
  }

  @MainActor
  private final class HostedCommandWindow: NSWindow {
    private let hostUndoManager: UndoManager

    init(
      contentRect: NSRect,
      title: String,
      undoManager: UndoManager
    ) {
      self.hostUndoManager = undoManager
      super.init(
        contentRect: contentRect,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      self.title = title
    }

    override var undoManager: UndoManager? {
      hostUndoManager
    }
  }

  func testNativeFieldRawRedoVersusMainMenuKeyEquivalent() async throws {
    let phaseTrace = HostedPhaseTrace(suffix: "menu-key-control")
    phaseTrace.record(
      "test.entry",
      details: ["test": "testNativeFieldRawRedoVersusMainMenuKeyEquivalent"])
    let owner = HostedUndoOwner()
    let field = NSTextField(frame: NSRect(x: 12, y: 12, width: 240, height: 24))
    let window = HostedCommandWindow(
      contentRect: NSRect(x: 80, y: 100, width: 640, height: 240),
      title: "Native Menu Key Control",
      undoManager: owner.undoManager
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
    container.addSubview(field)
    window.contentView = container
    let menu = installEditMenu()
    let previousMenu = NSApp.mainMenu
    NSApp.mainMenu = menu
    defer {
      phaseTrace.record("cleanup.begin", window: window)
      window.orderOut(nil)
      window.close()
      NSApp.mainMenu = previousMenu
      phaseTrace.record("cleanup.end", window: window)
    }

    phaseTrace.record("activate.before", window: window)
    do {
      try await activate(window)
      phaseTrace.record("activate.after", window: window)
    } catch {
      phaseTrace.record("activate.error", window: window, error: error)
      throw error
    }
    XCTAssertTrue(window.makeFirstResponder(field))
    recordState("field.focused", field: field, owner: owner, window: window, trace: phaseTrace)

    let insert = KeyStroke(
      characters: "n",
      charactersIgnoringModifiers: "n",
      keyCode: 45,
      modifiers: []
    )
    send(insert, to: window, trace: phaseTrace, phase: "raw.insert")
    recordState("raw.insert.after", field: field, owner: owner, window: window, trace: phaseTrace)
    XCTAssertEqual(field.stringValue, "n")

    let undo = KeyStroke(
      characters: "z",
      charactersIgnoringModifiers: "z",
      keyCode: 6,
      modifiers: [.command]
    )
    send(undo, to: window, trace: phaseTrace, phase: "raw.undo")
    recordState("raw.undo.after", field: field, owner: owner, window: window, trace: phaseTrace)
    XCTAssertEqual(field.stringValue, "")

    let redo = KeyStroke(
      characters: "Z",
      charactersIgnoringModifiers: "z",
      keyCode: 6,
      modifiers: [.command, .shift]
    )
    guard let redoKeyDown = makeEvent(redo, type: .keyDown, window: window) else {
      XCTFail("Could not create Redo key event")
      return
    }
    guard let redoKeyUp = makeEvent(redo, type: .keyUp, window: window) else {
      XCTFail("Could not create Redo key-up event")
      return
    }
    traceEvent("raw.redo.before", key: redo, window: window, trace: phaseTrace)
    NSApp.sendEvent(redoKeyDown)
    NSApp.sendEvent(redoKeyUp)
    recordState("raw.redo.after", field: field, owner: owner, window: window, trace: phaseTrace)
    XCTAssertEqual(field.stringValue, "")

    let correctedRedo = KeyStroke(
      characters: "Z",
      charactersIgnoringModifiers: "Z",
      keyCode: 6,
      modifiers: [.command, .shift]
    )
    guard let correctedRedoKeyDown = makeEvent(correctedRedo, type: .keyDown, window: window) else {
      XCTFail("Could not create corrected Redo key event")
      return
    }
    guard let correctedRedoKeyUp = makeEvent(correctedRedo, type: .keyUp, window: window) else {
      XCTFail("Could not create corrected Redo key-up event")
      return
    }
    traceEvent("raw.corrected-redo.before", key: correctedRedo, window: window, trace: phaseTrace)
    NSApp.sendEvent(correctedRedoKeyDown)
    NSApp.sendEvent(correctedRedoKeyUp)
    recordState(
      "raw.corrected-redo.after",
      field: field,
      owner: owner,
      window: window,
      trace: phaseTrace
    )
    XCTAssertEqual(field.stringValue, "n")

    if field.stringValue != "n" {
      phaseTrace.record(
        "menu.performKeyEquivalent.before",
        window: window,
        details: [
          "targetType": firstResponderType(in: window),
          "fieldValue": field.stringValue,
          "canUndo": String(owner.undoManager.canUndo),
          "canRedo": String(owner.undoManager.canRedo),
        ])
      let performed = menu.performKeyEquivalent(with: correctedRedoKeyDown)
      phaseTrace.record(
        "menu.performKeyEquivalent.after",
        window: window,
        details: [
          "performed": String(performed),
          "targetType": firstResponderType(in: window),
          "fieldValue": field.stringValue,
          "canUndo": String(owner.undoManager.canUndo),
          "canRedo": String(owner.undoManager.canRedo),
        ])
      XCTAssertTrue(performed)
    } else {
      phaseTrace.record(
        "menu.performKeyEquivalent.skipped",
        window: window,
        details: ["reason": "corrected raw Redo restored field"])
    }
    XCTAssertEqual(field.stringValue, "n")
  }

  private func installEditMenu() -> NSMenu {
    let mainMenu = NSMenu(title: "Main")
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    mainMenu.addItem(editItem)
    mainMenu.setSubmenu(editMenu, for: editItem)

    let undoItem = NSMenuItem(
      title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    undoItem.keyEquivalentModifierMask = [.command]
    let redoItem = NSMenuItem(
      title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(undoItem)
    editMenu.addItem(redoItem)
    return mainMenu
  }

  private func activate(_ window: NSWindow) async throws {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    try await waitUntil("window activation") {
      NSApp.isActive && window.isVisible && window.isKeyWindow
    }
  }

  private func send(
    _ key: KeyStroke,
    to window: NSWindow,
    trace: HostedPhaseTrace,
    phase: String
  ) {
    traceEvent(phase + ".before", key: key, window: window, trace: trace)
    guard let keyDown = makeEvent(key, type: .keyDown, window: window),
      let keyUp = makeEvent(key, type: .keyUp, window: window)
    else {
      XCTFail("Could not create key events for \(phase)")
      trace.record(phase + ".error", window: window)
      return
    }
    NSApp.sendEvent(keyDown)
    NSApp.sendEvent(keyUp)
    trace.record(
      phase + ".after",
      window: window,
      details: [
        "targetType": firstResponderType(in: window),
        "keyDownCreated": "true",
        "keyUpCreated": "true",
      ])
  }

  private func makeEvent(
    _ key: KeyStroke,
    type: NSEvent.EventType,
    window: NSWindow
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: type,
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
  }

  private func traceEvent(
    _ event: String,
    key: KeyStroke,
    window: NSWindow,
    trace: HostedPhaseTrace
  ) {
    trace.record(
      event,
      window: window,
      details: [
        "targetType": firstResponderType(in: window),
        "keyCode": String(key.keyCode),
        "modifierFlags": String(key.modifiers.rawValue),
        "characters": key.characters,
        "charactersIgnoringModifiers": key.charactersIgnoringModifiers,
      ])
  }

  private func recordState(
    _ event: String,
    field: NSTextField,
    owner: HostedUndoOwner,
    window: NSWindow,
    trace: HostedPhaseTrace
  ) {
    trace.record(
      event,
      window: window,
      details: [
        "targetType": firstResponderType(in: window),
        "fieldValue": field.stringValue,
        "canUndo": String(owner.undoManager.canUndo),
        "canRedo": String(owner.undoManager.canRedo),
      ])
  }

  private func firstResponderType(in window: NSWindow) -> String {
    window.firstResponder.map { String(reflecting: type(of: $0)) } ?? "nil"
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
          domain: "HostedMenuKeyControlTests",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(description)"]
        )
      }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
  }
}
