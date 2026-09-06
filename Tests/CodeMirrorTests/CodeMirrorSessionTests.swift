import XCTest

@testable import CodeMirror

#if os(macOS) && canImport(AppKit) && canImport(WebKit)
  import AppKit
  import WebKit
#endif

@MainActor
private final class FocusProbe {
  var value = false
}

@MainActor
final class CodeMirrorSessionTests: XCTestCase {
  func testAcceptedUTF16DeltaValidatesRemovedTextAndSuppressesDuplicate() throws {
    var events: [CodeMirrorEvent] = []
    let session = CodeMirrorSession(initialText: "a😀c") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false },
      send: { command in
        commands.append(command)
      })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))

    let transaction = CodeMirrorTransaction(
      sessionID: session.id,
      replicaID: replicaID,
      loadID: loadID,
      baseRevision: .zero,
      revision: CodeMirrorRevision(1),
      changes: [
        CodeMirrorChange(rangeUTF16: 1..<3, insertedText: "x", removedText: "😀")
      ],
      selectionBefore: CodeMirrorSelection(anchorUTF16: 3, headUTF16: 3),
      selectionAfter: CodeMirrorSelection(anchorUTF16: 2, headUTF16: 2)
    )
    session.receive(.transaction(transaction))
    session.receive(.transaction(transaction))

    let snapshot = try session.snapshot()
    XCTAssertEqual(snapshot.text, "axc")
    XCTAssertEqual(snapshot.revision, CodeMirrorRevision(1))
    XCTAssertEqual(
      events.compactMap { event in
        if case .transaction(let transaction, _) = event {
          return transaction.changes.first?.removedText
        }
        return nil
      }, ["😀"])
    XCTAssertTrue(
      commands.contains { command in
        if case .acknowledge(let revision) = command { return revision == CodeMirrorRevision(1) }
        return false
      })
  }

  func testMismatchedRemovedTextIsRejectedWithoutChangingAcceptedText() throws {
    var errors: [CodeMirrorSessionError] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      if case .failure(_, let error) = event {
        errors.append(error)
      }
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(replicaID: replicaID, isFocused: { false }, send: { _ in })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    session.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          baseRevision: .zero,
          revision: CodeMirrorRevision(1),
          changes: [
            CodeMirrorChange(rangeUTF16: 0..<6, insertedText: "other", removedText: "wrong")
          ],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 5, headUTF16: 5)
        )))

    XCTAssertEqual(errors, [.malformedChange])
    XCTAssertEqual(try session.snapshot().text, "source")
  }

  func testReadyEventWaitsForConfiguredContentHandshake() throws {
    var events: [CodeMirrorEvent] = []
    let session = CodeMirrorSession(initialText: "initial") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { commands.append($0) })

    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    XCTAssertFalse(
      events.contains {
        if case .ready = $0 { return true }
        return false
      })
    XCTAssertTrue(
      commands.contains {
        if case .configure = $0 { return true }
        return false
      })

    session.receive(.configured(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    XCTAssertTrue(
      events.contains {
        if case .ready = $0 { return true }
        return false
      })
  }

  func testSurrogateSplitIsRejectedWithoutChangingAcceptedText() throws {
    var errors: [CodeMirrorSessionError] = []
    let session = CodeMirrorSession(initialText: "😀") { event in
      if case .failure(_, let error) = event {
        errors.append(error)
      }
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(replicaID: replicaID, isFocused: { false }, send: { _ in })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    session.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          baseRevision: .zero,
          revision: CodeMirrorRevision(1),
          changes: [CodeMirrorChange(rangeUTF16: 1..<1, insertedText: "x")],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0)
        )))

    XCTAssertEqual(errors, [.malformedChange])
    XCTAssertEqual(try session.snapshot().text, "😀")
  }

  func testTwoReplicasSynchronizeWithoutEchoingTransaction() throws {
    var events: [CodeMirrorEvent] = []
    let session = CodeMirrorSession(initialText: "one") { event in
      events.append(event)
      return .accept
    }
    let firstID = CodeMirrorReplicaID()
    let secondID = CodeMirrorReplicaID()
    var firstCommands: [CodeMirrorHostCommand] = []
    var secondCommands: [CodeMirrorHostCommand] = []
    let firstLoadID = try session.attach(
      replicaID: firstID, isFocused: { false },
      send: {
        firstCommands.append($0)
      })
    let secondLoadID = try session.attach(
      replicaID: secondID, isFocused: { false },
      send: {
        secondCommands.append($0)
      })
    session.receive(.ready(sessionID: session.id, replicaID: firstID, loadID: firstLoadID))
    session.receive(.ready(sessionID: session.id, replicaID: secondID, loadID: secondLoadID))
    firstCommands.removeAll()
    secondCommands.removeAll()

    session.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: session.id,
          replicaID: firstID,
          loadID: firstLoadID,
          baseRevision: .zero,
          revision: CodeMirrorRevision(1),
          changes: [CodeMirrorChange(rangeUTF16: 3..<3, insertedText: "!")],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 3, headUTF16: 3),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 4, headUTF16: 4)
        )))

    XCTAssertEqual(
      events.filter {
        if case .transaction = $0 { return true }
        return false
      }.count, 1)
    XCTAssertTrue(
      firstCommands.contains {
        if case .acknowledge = $0 { return true }
        return false
      })
    XCTAssertTrue(
      secondCommands.contains { command in
        if case .reconcile(let snapshot, let preserveLocalChanges) = command {
          return snapshot.text == "one!" && preserveLocalChanges
        }
        return false
      })
  }

  func testReplacementDispositionReconcilesAuthoritativeText() throws {
    let session = CodeMirrorSession(initialText: "one") { event in
      if case .transaction = event {
        return .replace(authoritativeText: "host")
      }
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false },
      send: {
        commands.append($0)
      })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    commands.removeAll()

    session.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          baseRevision: .zero,
          revision: CodeMirrorRevision(1),
          changes: [CodeMirrorChange(rangeUTF16: 3..<3, insertedText: "!")],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 3, headUTF16: 3),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 4, headUTF16: 4)
        )))

    XCTAssertEqual(try session.snapshot().text, "host")
    XCTAssertTrue(
      commands.contains { command in
        if case .reconcile(let snapshot, let preserveLocalChanges) = command {
          return snapshot.text == "host" && !preserveLocalChanges
        }
        return false
      })
  }

  func testCompositionTransactionsPreserveIdentityAndAdvanceSource() throws {
    let compositionID = UUID()
    var phases: [CodeMirrorCompositionPhase] = []
    let session = CodeMirrorSession(initialText: "") { event in
      if case .transaction(let transaction, _) = event {
        phases.append(transaction.composition)
      }
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(replicaID: replicaID, isFocused: { false }, send: { _ in })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))

    let transactions: [(CodeMirrorCompositionPhase, Int, String)] = [
      (.began(compositionID), 0, "a"),
      (.updated(compositionID), 1, "b"),
      (.ended(compositionID), 2, "c"),
    ]
    for (index, item) in transactions.enumerated() {
      session.receive(
        .transaction(
          CodeMirrorTransaction(
            sessionID: session.id,
            replicaID: replicaID,
            loadID: loadID,
            baseRevision: CodeMirrorRevision(UInt64(index)),
            revision: CodeMirrorRevision(UInt64(index + 1)),
            changes: [CodeMirrorChange(rangeUTF16: item.1..<item.1, insertedText: item.2)],
            selectionBefore: CodeMirrorSelection(anchorUTF16: item.1, headUTF16: item.1),
            selectionAfter: CodeMirrorSelection(anchorUTF16: item.1 + 1, headUTF16: item.1 + 1),
            composition: item.0
          )))
    }

    XCTAssertEqual(phases, transactions.map { $0.0 })
    XCTAssertEqual(try session.snapshot().text, "abc")
  }

  func testProgrammaticReplacementHasNoEventAndUndoCommandIsForwarded() async throws {
    var events: [CodeMirrorEvent] = []
    let session = CodeMirrorSession(initialText: "one") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false },
      send: {
        commands.append($0)
      })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    events.removeAll()
    commands.removeAll()

    let snapshot = try await session.replace(
      expectedRevision: .zero,
      changes: [CodeMirrorChange(rangeUTF16: 0..<3, insertedText: "two")],
      selection: CodeMirrorSelection(anchorUTF16: 3, headUTF16: 3),
      in: replicaID
    )
    session.receive(
      .command(
        sessionID: session.id, replicaID: replicaID, loadID: loadID, revision: snapshot.revision,
        command: .undo))

    XCTAssertEqual(snapshot.text, "two")
    XCTAssertTrue(
      events.contains {
        if case .command(_, .undo) = $0 { return true }
        return false
      })
    XCTAssertFalse(
      events.contains {
        if case .transaction = $0 { return true }
        return false
      })
    XCTAssertTrue(
      commands.contains {
        if case .apply(let value) = $0 { return value.text == "two" }
        return false
      })
  }

  func testFlushTimeoutKeepsSourceAndInvalidationResumesPendingFlush() async throws {
    let session = CodeMirrorSession(
      initialText: "content",
      configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 10)
    ) { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false },
      send: {
        commands.append($0)
      })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    do {
      _ = try await session.flush()
      XCTFail("flush unexpectedly succeeded")
    } catch {
      XCTAssertEqual(error as? CodeMirrorSessionError, .timeout)
    }
    XCTAssertEqual(try session.snapshot().text, "content")

    let pending = Task { @MainActor in try await session.flush() }
    await Task.yield()
    session.invalidate()
    let invalidationResult = await pending.result
    if case .failure(let error) = invalidationResult {
      XCTAssertEqual(error as? CodeMirrorSessionError, .invalidated)
    } else {
      XCTFail("invalidation did not resume flush")
    }
    XCTAssertTrue(
      commands.contains {
        if case .invalidate = $0 { return true }
        return false
      })
  }

  func testConflictingFlushFailureMapsToRecoverableError() async throws {
    let session = CodeMirrorSession(initialText: "local") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { commands.append($0) })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))

    let pending = Task { @MainActor in try await session.flush() }
    var requestID: UUID?
    for _ in 0..<10 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command -> UUID? in
          if case .flush(let value) = command { return value }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("flush request was not sent")
      return
    }
    session.receive(
      .flushResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        requestID: requestID,
        success: false,
        code: "conflictingEdit"
      ))

    let result = await pending.result
    if case .failure(let error) = result {
      XCTAssertEqual(error as? CodeMirrorSessionError, .conflictingEdit)
    } else {
      XCTFail("conflicting flush unexpectedly succeeded")
    }
    XCTAssertEqual(try session.snapshot().text, "local")
  }

  func testFocusedReplicaUsesLiveNativeProviderAndClearsAfterTeardown() throws {
    let focus = FocusProbe()
    let session = CodeMirrorSession(initialText: "") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { focus.value }, send: { _ in })

    XCTAssertNil(session.focusedReplicaID())
    focus.value = true
    XCTAssertEqual(session.focusedReplicaID(), replicaID)
    focus.value = false
    XCTAssertNil(session.focusedReplicaID())
    session.detach(replicaID: replicaID, loadID: loadID)
    focus.value = true
    XCTAssertNil(session.focusedReplicaID())
  }

  func testInvalidatedSessionDoesNotReportFocus() throws {
    let session = CodeMirrorSession(initialText: "") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    _ = try session.attach(replicaID: replicaID, isFocused: { true }, send: { _ in })
    XCTAssertEqual(session.focusedReplicaID(), replicaID)
    session.invalidate()
    XCTAssertNil(session.focusedReplicaID())
  }

  #if os(macOS) && canImport(AppKit) && canImport(WebKit)
    func testFocusedReplicaUsesActualWindowResponderAndTeardown() throws {
      let session = CodeMirrorSession(initialText: "") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
      let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.contentView = container
      container.addSubview(webView)
      coordinator.attach(webView: webView)
      defer {
        coordinator.detach()
        window.orderOut(nil)
        window.close()
      }

      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      XCTAssertTrue(window.makeFirstResponder(webView))
      guard window.isKeyWindow else {
        throw XCTSkip(
          "The package test host is inactive; key-window responder verification needs an app host.")
      }
      XCTAssertEqual(session.focusedReplicaID(), replicaID)

      let precedingField = NSTextField(frame: NSRect(x: 12, y: 12, width: 200, height: 24))
      precedingField.stringValue = "Before editor"
      let followingField = NSTextField(frame: NSRect(x: 12, y: 48, width: 200, height: 24))
      followingField.stringValue = "After editor"
      container.addSubview(precedingField)
      container.addSubview(followingField)
      precedingField.nextKeyView = webView
      webView.nextKeyView = followingField
      followingField.nextKeyView = webView
      guard let loadID = coordinator.attachedLoadID else {
        XCTFail("coordinator did not attach a native load")
        return
      }

      session.receive(
        .focusTraversal(
          sessionID: session.id, replicaID: replicaID, loadID: loadID, forward: true))
      XCTAssertTrue(window.firstResponder === followingField)
      XCTAssertNil(session.focusedReplicaID())

      XCTAssertTrue(window.makeFirstResponder(webView))
      session.receive(
        .focusTraversal(
          sessionID: session.id, replicaID: replicaID, loadID: loadID, forward: false))
      XCTAssertTrue(window.firstResponder === precedingField)

      XCTAssertTrue(window.makeFirstResponder(followingField))
      session.receive(
        .focusTraversal(
          sessionID: session.id, replicaID: replicaID, loadID: loadID, forward: true))
      XCTAssertTrue(window.firstResponder === followingField)
      XCTAssertNil(session.focusedReplicaID())

      XCTAssertTrue(window.makeFirstResponder(webView))
      container.isHidden = true
      XCTAssertNil(session.focusedReplicaID())
      container.isHidden = false
      XCTAssertTrue(window.makeFirstResponder(webView))
      XCTAssertEqual(session.focusedReplicaID(), replicaID)

      window.resignKey()
      XCTAssertNil(session.focusedReplicaID())

      window.makeKeyAndOrderFront(nil)
      XCTAssertTrue(window.makeFirstResponder(webView))
      XCTAssertEqual(session.focusedReplicaID(), replicaID)
      coordinator.detach()
      XCTAssertNil(session.focusedReplicaID())
    }
  #endif
}
