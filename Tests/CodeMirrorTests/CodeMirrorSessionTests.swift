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

  func testMalformedWireRangesFailBeforeConstructionAndDoNotMutateSession() throws {
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

    func body(from: Int, to: Int) -> [String: Any] {
      [
        "type": "transaction",
        "sessionID": session.id.rawValue.uuidString,
        "replicaID": replicaID.rawValue.uuidString,
        "loadID": loadID.uuidString,
        "baseRevision": 0,
        "revision": 1,
        "changes": [
          [
            "fromUTF16": from,
            "toUTF16": to,
            "insertedText": "x",
            "removedText": "",
          ]
        ],
        "selectionBefore": ["anchorUTF16": 0, "headUTF16": 0],
        "selectionAfter": ["anchorUTF16": 1, "headUTF16": 1],
      ]
    }

    for invalidRange in [(2, 1), (-1, 0)] {
      XCTAssertThrowsError(
        try CodeMirrorInboundMessage.decode(
          body(from: invalidRange.0, to: invalidRange.1))
      ) { error in
        XCTAssertEqual(error as? CodeMirrorSessionError, .malformedChange)
      }
    }

    let outOfBounds = try CodeMirrorInboundMessage.decode(body(from: 0, to: 99))
    session.receive(outOfBounds)

    XCTAssertEqual(errors, [.malformedChange])
    XCTAssertEqual(try session.snapshot().text, "source")
    XCTAssertEqual(try session.snapshot().revision, .zero)
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

  func testPreservedSelectionsStayOnScalarBoundariesForReplacementAndReconciliation() async throws {
    let session = CodeMirrorSession(initialText: "ab") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(replicaID: replicaID, isFocused: { false }, send: { _ in })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    session.receive(
      .selection(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        selection: CodeMirrorSelection(anchorUTF16: 1, headUTF16: 1)
      ))

    let replaced = try await session.replace(text: "😀", preservingSelections: true)
    XCTAssertEqual(replaced.text, "😀")
    XCTAssertEqual(
      replaced.selections[replicaID],
      CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0)
    )

    session.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          baseRevision: replaced.revision,
          revision: CodeMirrorRevision(replaced.revision.rawValue + 1),
          changes: [CodeMirrorChange(rangeUTF16: 0..<0, insertedText: "x")],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 1, headUTF16: 1)
        )))
    XCTAssertEqual(try session.snapshot().text, "x😀")

    var shouldReplaceAuthoritatively = true
    let authoritativeSession = CodeMirrorSession(initialText: "ab") { event in
      if shouldReplaceAuthoritatively, case .transaction = event {
        shouldReplaceAuthoritatively = false
        return .replace(authoritativeText: "😀")
      }
      return .accept
    }
    let authoritativeReplicaID = CodeMirrorReplicaID()
    let authoritativeLoadID = try authoritativeSession.attach(
      replicaID: authoritativeReplicaID, isFocused: { false }, send: { _ in })
    authoritativeSession.receive(
      .ready(
        sessionID: authoritativeSession.id,
        replicaID: authoritativeReplicaID,
        loadID: authoritativeLoadID
      ))
    authoritativeSession.receive(
      .selection(
        sessionID: authoritativeSession.id,
        replicaID: authoritativeReplicaID,
        loadID: authoritativeLoadID,
        revision: .zero,
        selection: CodeMirrorSelection(anchorUTF16: 1, headUTF16: 1)
      ))
    authoritativeSession.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: authoritativeSession.id,
          replicaID: authoritativeReplicaID,
          loadID: authoritativeLoadID,
          baseRevision: .zero,
          revision: CodeMirrorRevision(1),
          changes: [CodeMirrorChange(rangeUTF16: 1..<1, insertedText: "x")],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 1, headUTF16: 1),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 1, headUTF16: 1)
        )))

    let authoritativeSnapshot = try authoritativeSession.snapshot()
    XCTAssertEqual(authoritativeSnapshot.text, "😀")
    XCTAssertEqual(
      authoritativeSnapshot.selections[authoritativeReplicaID],
      CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0)
    )
    authoritativeSession.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: authoritativeSession.id,
          replicaID: authoritativeReplicaID,
          loadID: authoritativeLoadID,
          baseRevision: authoritativeSnapshot.revision,
          revision: CodeMirrorRevision(authoritativeSnapshot.revision.rawValue + 1),
          changes: [CodeMirrorChange(rangeUTF16: 0..<0, insertedText: "x")],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 1, headUTF16: 1)
        )))
    XCTAssertEqual(try authoritativeSession.snapshot().text, "x😀")
  }

  func testReplaceImmediatelyRejectsInvalidAndStaleChangesAtomically() throws {
    let session = CodeMirrorSession(initialText: "one") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let unknownReplicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { commands.append($0) })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    commands.removeAll()

    XCTAssertThrowsError(
      try session.replaceImmediately(
        expectedRevision: CodeMirrorRevision(1),
        changes: [CodeMirrorChange(rangeUTF16: 0..<3, insertedText: "two")],
        in: replicaID
      )
    ) { error in
      XCTAssertEqual(
        error as? CodeMirrorSessionError,
        .staleRevision(expected: .zero, actual: CodeMirrorRevision(1)))
    }
    XCTAssertThrowsError(
      try session.replaceImmediately(
        expectedRevision: .zero,
        changes: [CodeMirrorChange(rangeUTF16: 4..<4, insertedText: "two")],
        in: replicaID
      )
    ) { error in
      XCTAssertEqual(error as? CodeMirrorSessionError, .malformedChange)
    }
    XCTAssertThrowsError(
      try session.replaceImmediately(
        expectedRevision: .zero,
        changes: [CodeMirrorChange(rangeUTF16: 0..<3, insertedText: "two")],
        in: unknownReplicaID
      )
    ) { error in
      XCTAssertEqual(error as? CodeMirrorSessionError, .replicaUnavailable)
    }

    XCTAssertEqual(try session.snapshot().text, "one")
    XCTAssertEqual(try session.snapshot().revision, .zero)
    XCTAssertTrue(commands.isEmpty)
  }

  func testResolvedAppearanceTracksEnvironmentWithoutMutatingCallerConfiguration() throws {
    let configuration = CodeMirrorConfiguration(
      appearance: CodeMirrorAppearance(colorScheme: .system))
    let dark = resolvedCodeMirrorAppearance(
      configuration: configuration,
      environmentScheme: .dark,
      systemIncreaseContrast: true,
      accessibilityReduceMotion: true,
      accessibilityReduceTransparency: true
    )
    let light = resolvedCodeMirrorAppearance(
      configuration: configuration,
      environmentScheme: .light,
      systemIncreaseContrast: false,
      accessibilityReduceMotion: false,
      accessibilityReduceTransparency: false
    )

    XCTAssertEqual(
      dark,
      CodeMirrorAppearance(
        colorScheme: .dark, increaseContrast: true, reduceMotion: true, reduceTransparency: true))
    XCTAssertEqual(light, CodeMirrorAppearance(colorScheme: .light))
    XCTAssertEqual(configuration.appearance.colorScheme, .system)
    XCTAssertFalse(configuration.appearance.increaseContrast)
    XCTAssertFalse(configuration.appearance.reduceMotion)
    XCTAssertFalse(configuration.appearance.reduceTransparency)
  }

  func testReplicaAppearanceUpdatesSkipIdenticalBroadcasts() throws {
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { commands.append($0) })
    let dark = CodeMirrorAppearance(colorScheme: .dark, increaseContrast: true)
    let light = CodeMirrorAppearance(colorScheme: .light)

    session.update(appearance: dark, for: replicaID)
    session.update(appearance: light, for: replicaID)
    session.update(appearance: light, for: replicaID)
    session.update(configuration: session.configuration)

    let configurations = commands.compactMap { command -> CodeMirrorConfiguration? in
      if case .updateConfiguration(let configuration) = command { return configuration }
      return nil
    }
    XCTAssertEqual(configurations.map(\.appearance), [dark, light])
    XCTAssertEqual(session.configuration.appearance.colorScheme, .system)
    session.detach(replicaID: replicaID, loadID: loadID)
  }

  #if os(macOS)
    func testReplaceImmediatelySupportsSynchronousUndoRedoWithoutEchoTransactions() throws {
      var events: [CodeMirrorEvent] = []
      let session = CodeMirrorSession(initialText: "one") { event in
        events.append(event)
        return .accept
      }
      let inlineReplicaID = CodeMirrorReplicaID()
      let detachedReplicaID = CodeMirrorReplicaID()
      var inlineCommands: [CodeMirrorHostCommand] = []
      var detachedCommands: [CodeMirrorHostCommand] = []
      let inlineLoadID = try session.attach(
        replicaID: inlineReplicaID, isFocused: { false }, send: { inlineCommands.append($0) })
      let detachedLoadID = try session.attach(
        replicaID: detachedReplicaID, isFocused: { false }, send: { detachedCommands.append($0) })
      session.receive(
        .ready(sessionID: session.id, replicaID: inlineReplicaID, loadID: inlineLoadID))
      session.receive(
        .ready(sessionID: session.id, replicaID: detachedReplicaID, loadID: detachedLoadID))
      inlineCommands.removeAll()
      detachedCommands.removeAll()

      let undoManager = UndoManager()
      let undoTarget = NSObject()
      var hostSnapshot = try session.snapshot()
      var callbackPhases: [String] = []

      func registerUndo(from previous: CodeMirrorSnapshot, to current: CodeMirrorSnapshot) {
        undoManager.registerUndo(withTarget: undoTarget) { _ in
          callbackPhases.append(
            undoManager.isUndoing ? "undo" : undoManager.isRedoing ? "redo" : "outside")
          let currentText = hostSnapshot.text
          let replacement = try! session.replaceImmediately(
            expectedRevision: hostSnapshot.revision,
            changes: [
              CodeMirrorChange(
                rangeUTF16: 0..<currentText.utf16.count,
                insertedText: previous.text,
                removedText: currentText)
            ],
            selection: previous.selections[inlineReplicaID],
            in: inlineReplicaID
          )
          hostSnapshot = replacement
          registerUndo(from: current, to: replacement)
        }
      }

      let before = hostSnapshot
      let after = try session.replaceImmediately(
        expectedRevision: before.revision,
        changes: [
          CodeMirrorChange(
            rangeUTF16: 0..<before.text.utf16.count,
            insertedText: "two",
            removedText: before.text)
        ],
        selection: CodeMirrorSelection(anchorUTF16: 3, headUTF16: 3),
        in: inlineReplicaID
      )
      hostSnapshot = after
      registerUndo(from: before, to: after)

      undoManager.undo()
      XCTAssertEqual(hostSnapshot.text, "one")
      XCTAssertEqual(hostSnapshot.revision, CodeMirrorRevision(2))
      XCTAssertTrue(undoManager.canRedo)

      undoManager.redo()
      XCTAssertEqual(hostSnapshot.text, "two")
      XCTAssertEqual(hostSnapshot.revision, CodeMirrorRevision(3))
      XCTAssertTrue(undoManager.canUndo)
      XCTAssertEqual(callbackPhases, ["undo", "redo"])
      XCTAssertFalse(
        events.contains {
          if case .transaction = $0 { return true }
          return false
        })

      func applyTexts(_ commands: [CodeMirrorHostCommand]) -> [String] {
        commands.compactMap { command in
          if case .apply(let snapshot) = command { return snapshot.text }
          return nil
        }
      }
      XCTAssertEqual(applyTexts(inlineCommands), ["two", "one", "two"])
      XCTAssertEqual(applyTexts(detachedCommands), ["two", "one", "two"])
    }
  #endif

  #if os(macOS) && canImport(AppKit) && canImport(WebKit)
    func testStalledReadyTimesOutRequiredCommandsWithoutRetainingQueuedFormats() async throws {
      let session = CodeMirrorSession(
        initialText: "{\"value\": 1}",
        configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 1)
      ) { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
      coordinator.attach(webView: webView)
      defer { coordinator.detach() }

      do {
        _ = try await session.format(in: replicaID)
        XCTFail("format unexpectedly succeeded before the page became ready")
      } catch {
        XCTAssertEqual(error as? CodeMirrorSessionError, .timeout)
      }
      XCTAssertEqual(coordinator.pendingFormatCommandCount, 0)

      for index in 0..<40 {
        do {
          if index.isMultiple(of: 2) {
            _ = try await session.format(in: replicaID)
          } else {
            _ = try await session.flush()
          }
          XCTFail("required operation unexpectedly succeeded before the page became ready")
        } catch {
          XCTAssertEqual(error as? CodeMirrorSessionError, .timeout)
        }
      }
      XCTAssertLessThanOrEqual(coordinator.pendingRequiredCommandCount, 32)
    }

    func testStalledReadyRejectsRequiredQueueOverflowWithRecoverableFailures() async throws {
      let session = CodeMirrorSession(
        initialText: "{\"value\": 1}",
        configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 5_000)
      ) { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
      coordinator.attach(webView: webView)

      let tasks = (0..<40).map { _ in
        Task { @MainActor in
          do {
            return Result<CodeMirrorSnapshot, CodeMirrorSessionError>.success(
              try await session.format(in: replicaID))
          } catch let error as CodeMirrorSessionError {
            return Result<CodeMirrorSnapshot, CodeMirrorSessionError>.failure(error)
          } catch {
            return Result<CodeMirrorSnapshot, CodeMirrorSessionError>.failure(.transportFailure)
          }
        }
      }
      for _ in 0..<20 {
        await Task.yield()
      }
      XCTAssertLessThanOrEqual(coordinator.pendingRequiredCommandCount, 32)
      coordinator.detach()

      var results: [Result<CodeMirrorSnapshot, CodeMirrorSessionError>] = []
      for task in tasks {
        results.append(await task.value)
      }
      XCTAssertEqual(results.count, 40)
      XCTAssertTrue(
        results.contains { result in
          if case .failure(.transportFailure) = result { return true }
          return false
        })
      XCTAssertTrue(
        results.allSatisfy { result in
          if case .failure = result { return true }
          return false
        })
    }

    func testCoordinatorCoalescesPreReadyCommandsAndRetainsFlushFormat() async throws {
      let session = CodeMirrorSession(initialText: "source") { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
      coordinator.attach(webView: webView)

      for index in 0..<20 {
        session.update(
          appearance: CodeMirrorAppearance(
            colorScheme: index.isMultiple(of: 2) ? .dark : .light,
            increaseContrast: index.isMultiple(of: 3)),
          for: replicaID)
        let snapshot = try session.snapshot()
        _ = try session.replaceImmediately(
          expectedRevision: snapshot.revision,
          changes: [
            CodeMirrorChange(
              rangeUTF16: 0..<snapshot.text.utf16.count,
              insertedText: "source\(index)")
          ],
          in: replicaID
        )
      }

      let flushTask = Task { @MainActor in try await session.flush() }
      let formatTask = Task { @MainActor in try await session.format(in: replicaID) }
      for _ in 0..<20 {
        await Task.yield()
      }
      XCTAssertEqual(coordinator.pendingCommandCount, 4)

      coordinator.detach()
      let flushResult = await flushTask.result
      let formatResult = await formatTask.result
      if case .failure(let error) = flushResult {
        XCTAssertEqual(error as? CodeMirrorSessionError, .replicaUnavailable)
      } else {
        XCTFail("detaching a pending flush unexpectedly succeeded")
      }
      if case .failure(let error) = formatResult {
        XCTAssertEqual(error as? CodeMirrorSessionError, .replicaUnavailable)
      } else {
        XCTFail("detaching a pending format unexpectedly succeeded")
      }
    }
  #endif

  func testDetachingPendingFlushFailsInsteadOfCountingMissingReplicaAsAcknowledged() async throws {
    let session = CodeMirrorSession(
      initialText: "content",
      configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 1_000)
    ) { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(replicaID: replicaID, isFocused: { false }, send: { _ in })
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))

    let pending = Task { @MainActor in try await session.flush() }
    for _ in 0..<10 {
      await Task.yield()
    }
    session.detach(replicaID: replicaID, loadID: loadID)

    let result = await pending.result
    if case .failure(let error) = result {
      XCTAssertEqual(error as? CodeMirrorSessionError, .replicaUnavailable)
    } else {
      XCTFail("detaching the pending replica unexpectedly acknowledged flush")
    }
    XCTAssertEqual(try session.snapshot().text, "content")
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
