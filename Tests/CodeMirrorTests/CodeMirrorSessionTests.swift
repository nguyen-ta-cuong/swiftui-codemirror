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
private func sendCommandContext(
  _ session: CodeMirrorSession,
  replicaID: CodeMirrorReplicaID,
  loadID: UUID,
  sequence: UInt64,
  scope: CodeMirrorCommandContextScope,
  findContextID: CodeMirrorFindCommandContextID? = nil,
  undo: CodeMirrorCommandAvailability = CodeMirrorCommandAvailability(
    isSupported: false, isEnabled: false),
  redo: CodeMirrorCommandAvailability = CodeMirrorCommandAvailability(
    isSupported: false, isEnabled: false),
  revision: CodeMirrorRevision = .zero
) {
  session.receive(
    .commandContext(
      sessionID: session.id,
      replicaID: replicaID,
      loadID: loadID,
      revision: revision,
      sequence: sequence,
      scope: scope,
      findContextID: findContextID,
      undo: undo,
      redo: redo
    ))
}

private func makeTestTheme() -> CodeMirrorTheme {
  CodeMirrorTheme(
    background: CodeMirrorRGBA(red: 0.08, green: 0.09, blue: 0.1, alpha: 1)!,
    foreground: CodeMirrorRGBA(red: 0.9, green: 0.91, blue: 0.92, alpha: 1)!,
    gutterBackground: CodeMirrorRGBA(red: 0.06, green: 0.07, blue: 0.08, alpha: 1)!,
    gutterForeground: CodeMirrorRGBA(red: 0.55, green: 0.57, blue: 0.6, alpha: 0.95)!,
    border: CodeMirrorRGBA(red: 0.25, green: 0.27, blue: 0.3, alpha: 0.8)!,
    caret: CodeMirrorRGBA(red: 0.98, green: 0.8, blue: 0.3, alpha: 1)!,
    activeLineFill: CodeMirrorRGBA(red: 0.2, green: 0.22, blue: 0.25, alpha: 0.65)!
  )
}

@MainActor
private func routeRequestID(
  in commands: [CodeMirrorHostCommand], command expected: CodeMirrorCommand
) -> UUID? {
  for command in commands {
    guard case .routeCommand(let requestID, let request) = command,
      request.command == expected
    else {
      continue
    }
    return requestID
  }
  return nil
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

  func testRGBAValidatesNormalizedFiniteComponentsAndRejectsInvalidDecode() throws {
    let color = try XCTUnwrap(
      CodeMirrorRGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
    XCTAssertEqual(color.red, 0.1)
    XCTAssertEqual(color.green, 0.2)
    XCTAssertEqual(color.blue, 0.3)
    XCTAssertEqual(color.alpha, 0.4)

    for component in [Double.nan, Double.infinity, -Double.infinity, -0.01, 1.01] {
      XCTAssertNil(CodeMirrorRGBA(red: component, green: 0.2, blue: 0.3))
      XCTAssertNil(CodeMirrorRGBA(red: 0.1, green: component, blue: 0.3))
      XCTAssertNil(CodeMirrorRGBA(red: 0.1, green: 0.2, blue: component))
      XCTAssertNil(CodeMirrorRGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: component))
    }

    let encoded = try JSONEncoder().encode(color)
    XCTAssertEqual(try JSONDecoder().decode(CodeMirrorRGBA.self, from: encoded), color)
    let invalid = Data(#"{"red":1.1,"green":0.2,"blue":0.3,"alpha":1}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(CodeMirrorRGBA.self, from: invalid))
  }

  func testThemeAndAppearanceCodableRoundTrip() throws {
    let theme = makeTestTheme()
    let appearance = CodeMirrorAppearance(colorScheme: .dark, theme: theme)
    let encoded = try JSONEncoder().encode(appearance)
    XCTAssertEqual(try JSONDecoder().decode(CodeMirrorAppearance.self, from: encoded), appearance)
  }

  func testReplicaThemeUsesNumericPayloadWithoutMutatingSharedConfiguration() throws {
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    var commands: [CodeMirrorHostCommand] = []
    let loadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { commands.append($0) })
    let theme = makeTestTheme()
    let appearance = CodeMirrorAppearance(colorScheme: .dark, theme: theme)

    session.update(appearance: appearance, for: replicaID)

    guard let command = commands.last,
      case .updateConfiguration(let configuration) = command
    else {
      return XCTFail("theme update did not produce a configuration command")
    }
    XCTAssertEqual(configuration.appearance.theme, theme)
    XCTAssertNil(session.configuration.appearance.theme)
    let payload = command.payload
    let configurationPayload = try XCTUnwrap(payload["configuration"] as? [String: Any])
    let appearancePayload = try XCTUnwrap(configurationPayload["appearance"] as? [String: Any])
    let themePayload = try XCTUnwrap(appearancePayload["theme"] as? [String: Any])
    let backgroundPayload = try XCTUnwrap(themePayload["background"] as? [String: Any])
    XCTAssertEqual((backgroundPayload["red"] as? NSNumber)?.doubleValue, theme.background.red)
    XCTAssertEqual((backgroundPayload["alpha"] as? NSNumber)?.doubleValue, theme.background.alpha)
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
    func testInitialNavigationRetainsReplicaIdentityAppearanceAndQueuedOperation() async throws {
      let session = CodeMirrorSession(
        initialText: "source",
        configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 5_000)
      ) { _ in .accept }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
      coordinator.attach(webView: webView)
      defer { coordinator.detach() }

      guard let initialLoadID = coordinator.attachedLoadID else {
        XCTFail("coordinator did not attach its initial replica")
        return
      }
      let appearance = CodeMirrorAppearance(
        colorScheme: .dark, increaseContrast: true, reduceTransparency: true)
      session.update(appearance: appearance, for: replicaID)
      let formatTask = Task { @MainActor in try await session.format(in: replicaID) }

      for _ in 0..<80 {
        if !coordinator.initialNavigationPending { break }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
      XCTAssertFalse(coordinator.initialNavigationPending)
      XCTAssertEqual(coordinator.attachedLoadID, initialLoadID)
      XCTAssertEqual(coordinator.pendingConfigurationAppearances, [appearance])
      XCTAssertEqual(coordinator.pendingFormatCommandCount, 1)

      coordinator.detach()
      let result = await formatTask.result
      if case .failure(let error) = result {
        XCTAssertEqual(error as? CodeMirrorSessionError, .replicaUnavailable)
      } else {
        XCTFail("detaching the initial pre-ready replica unexpectedly completed format")
      }
    }

    func testReplacementBeforeReadyRetiresOldLoadAndIgnoresDelayedMessages() async throws {
      var readyEvents: [CodeMirrorEvent] = []
      let session = CodeMirrorSession(
        initialText: "source",
        configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 5_000)
      ) { event in
        readyEvents.append(event)
        return .accept
      }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
      coordinator.attach(webView: webView)
      defer { coordinator.detach() }

      guard let oldLoadID = coordinator.attachedLoadID else {
        XCTFail("coordinator did not attach its initial replica")
        return
      }
      for _ in 0..<80 {
        if !coordinator.initialNavigationPending { break }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
      XCTAssertFalse(coordinator.initialNavigationPending)

      let pending = Task { @MainActor in try await session.format(in: replicaID) }
      for _ in 0..<20 {
        if coordinator.pendingFormatCommandCount == 1 { break }
        await Task.yield()
      }
      coordinator.webView(webView, didStartProvisionalNavigation: nil)

      guard let replacementLoadID = coordinator.attachedLoadID else {
        XCTFail("replacement navigation did not attach a new replica")
        return
      }
      XCTAssertNotEqual(replacementLoadID, oldLoadID)
      let result = await pending.result
      if case .failure(let error) = result {
        XCTAssertEqual(error as? CodeMirrorSessionError, .transportFailure)
      } else {
        XCTFail("replacement navigation unexpectedly retained the old format")
      }

      session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: oldLoadID))
      session.receive(.configured(sessionID: session.id, replicaID: replicaID, loadID: oldLoadID))
      sendCommandContext(
        session,
        replicaID: replicaID,
        loadID: oldLoadID,
        sequence: 1,
        scope: .content
      )
      XCTAssertFalse(
        readyEvents.contains {
          if case .ready = $0 { return true }
          return false
        })
      XCTAssertNil(session.focusedCommandContext())
    }

    func testCoordinatorFailureRetiresPendingOperationAndIgnoresDelayedOldMessages() async throws {
      var events: [CodeMirrorEvent] = []
      let session = CodeMirrorSession(
        initialText: "source",
        configuration: CodeMirrorConfiguration(commandTimeoutMilliseconds: 5_000)
      ) { event in
        events.append(event)
        return .accept
      }
      let replicaID = CodeMirrorReplicaID()
      let coordinator = CodeMirrorEditorCoordinator(session: session, replicaID: replicaID)
      let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
      coordinator.attach(webView: webView)
      defer { coordinator.detach() }

      guard let loadID = coordinator.attachedLoadID else {
        XCTFail("coordinator did not attach its replica")
        return
      }
      for _ in 0..<80 {
        if !coordinator.initialNavigationPending { break }
        try await Task.sleep(nanoseconds: 25_000_000)
      }
      let pending = Task { @MainActor in try await session.flush() }
      for _ in 0..<20 {
        if coordinator.pendingRequiredCommandCount == 1 { break }
        await Task.yield()
      }
      coordinator.webView(
        webView,
        didFailProvisionalNavigation: nil,
        withError: NSError(domain: "CodeMirrorTests", code: 1)
      )

      let result = await pending.result
      if case .failure(let error) = result {
        XCTAssertEqual(error as? CodeMirrorSessionError, .transportFailure)
      } else {
        XCTFail("failed navigation unexpectedly completed flush")
      }
      XCTAssertNil(coordinator.attachedLoadID)

      session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
      session.receive(.configured(sessionID: session.id, replicaID: replicaID, loadID: loadID))
      session.receive(
        .failure(
          sessionID: session.id, replicaID: replicaID, loadID: loadID, code: "transportFailure"))
      XCTAssertFalse(
        events.contains {
          if case .ready = $0 { return true }
          return false
        })
      XCTAssertEqual(try session.snapshot().text, "source")
    }

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
          if case .failure(.timeout) = result { return true }
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

  func testFocusTraversalForwardsRapidDirectionsOnlyWhileNativeFocused() throws {
    let focus = FocusProbe()
    var directions: [Bool] = []
    let session = CodeMirrorSession(initialText: "") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { _ in },
      traverseFocus: { directions.append($0) }
    )

    focus.value = true
    session.receive(
      .focusTraversal(
        sessionID: session.id, replicaID: replicaID, loadID: loadID, forward: true))
    session.receive(
      .focusTraversal(
        sessionID: session.id, replicaID: replicaID, loadID: loadID, forward: false))
    focus.value = false
    session.receive(
      .focusTraversal(
        sessionID: session.id, replicaID: replicaID, loadID: loadID, forward: true))

    XCTAssertEqual(directions, [true, false])
  }

  func testInvalidatedSessionDoesNotReportFocus() throws {
    let session = CodeMirrorSession(initialText: "") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    _ = try session.attach(replicaID: replicaID, isFocused: { true }, send: { _ in })
    XCTAssertEqual(session.focusedReplicaID(), replicaID)
    session.invalidate()
    XCTAssertNil(session.focusedReplicaID())
  }

  func testCommandContextTracksScopeAvailabilityAndIgnoresStaleReports() throws {
    let focus = FocusProbe()
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { _ in }
    )

    focus.value = true
    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 2,
      scope: .content
    )
    XCTAssertEqual(session.focusedReplicaID(), replicaID)
    XCTAssertEqual(session.focusedCommandContext(), .content(replicaID))

    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 1,
      scope: .unavailable
    )
    XCTAssertEqual(session.focusedCommandContext(), .content(replicaID))

    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 3,
      scope: .find,
      findContextID: CodeMirrorFindCommandContextID(rawValue: UUID()),
      undo: CodeMirrorCommandAvailability(isSupported: true, isEnabled: true)
    )
    XCTAssertEqual(session.focusedReplicaID(), replicaID)
    guard case .find(let findContext) = session.focusedCommandContext() else {
      XCTFail("Find context was not accepted")
      return
    }
    XCTAssertTrue(findContext.undo.isEnabled)

    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 2,
      scope: .content
    )
    XCTAssertEqual(session.focusedCommandContext(), .find(findContext))
  }

  func testCommandContextEventsDeduplicateAndClearAcrossReplicaLifecycle() throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { _ in }
    )
    focus.value = true

    let contextChanges: () -> [CodeMirrorReplicaID] = {
      events.compactMap { event in
        if case .commandContextChanged(let eventReplicaID) = event {
          return eventReplicaID
        }
        return nil
      }
    }

    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .content)
    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 2, scope: .content)
    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .unavailable)
    XCTAssertEqual(contextChanges(), [replicaID])

    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 3,
      scope: .find,
      findContextID: CodeMirrorFindCommandContextID(rawValue: UUID()),
      undo: CodeMirrorCommandAvailability(isSupported: true, isEnabled: true)
    )
    XCTAssertEqual(contextChanges().count, 2)

    session.clearFocusScope(replicaID: replicaID, loadID: loadID)
    XCTAssertEqual(contextChanges().count, 3)
    XCTAssertEqual(session.focusedCommandContext(), .unavailable(replicaID))

    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 4, scope: .content)
    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: loadID))
    XCTAssertEqual(contextChanges().count, 5)

    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .content)
    session.reportTransportFailure(replicaID: replicaID, loadID: loadID)
    XCTAssertEqual(contextChanges().count, 7)

    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .content)
    session.detach(replicaID: replicaID, loadID: loadID)
    XCTAssertEqual(contextChanges().count, 9)

    let replacementLoadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { _ in }
    )
    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: replacementLoadID,
      sequence: 1,
      scope: .content
    )
    let finalLoadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { _ in }
    )
    XCTAssertEqual(contextChanges().count, 11)

    sendCommandContext(
      session, replicaID: replicaID, loadID: finalLoadID, sequence: 1, scope: .content)
    session.invalidate()
    XCTAssertEqual(contextChanges().count, 13)
  }

  func testCommandContextClearsAndReemitsAfterRevisionChanges() throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true

    func contextChangeCount() -> Int {
      events.reduce(into: 0) { count, event in
        if case .commandContextChanged = event { count += 1 }
      }
    }

    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .content)
    XCTAssertEqual(session.focusedCommandContext(), .content(replicaID))
    XCTAssertEqual(contextChangeCount(), 1)

    session.receive(
      .transaction(
        CodeMirrorTransaction(
          sessionID: session.id,
          replicaID: replicaID,
          loadID: loadID,
          baseRevision: .zero,
          revision: CodeMirrorRevision(1),
          changes: [
            CodeMirrorChange(
              rangeUTF16: 0..<6,
              insertedText: "updated",
              removedText: "source"
            )
          ],
          selectionBefore: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0),
          selectionAfter: CodeMirrorSelection(anchorUTF16: 7, headUTF16: 7)
        )))
    XCTAssertEqual(session.focusedCommandContext(), .unavailable(replicaID))
    XCTAssertEqual(contextChangeCount(), 2)

    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 1,
      scope: .content,
      revision: CodeMirrorRevision(1)
    )
    XCTAssertEqual(session.focusedCommandContext(), .content(replicaID))
    XCTAssertEqual(contextChangeCount(), 3)

    _ = try session.replaceImmediately(
      expectedRevision: CodeMirrorRevision(1),
      changes: [
        CodeMirrorChange(
          rangeUTF16: 0..<7,
          insertedText: "replaced",
          removedText: "updated"
        )
      ],
      in: replicaID
    )
    XCTAssertEqual(session.focusedCommandContext(), .unavailable(replicaID))
    XCTAssertEqual(contextChangeCount(), 4)

    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 1,
      scope: .content,
      revision: CodeMirrorRevision(2)
    )
    XCTAssertEqual(session.focusedCommandContext(), .content(replicaID))
    XCTAssertEqual(contextChangeCount(), 5)
    XCTAssertTrue(
      commands.contains { command in
        if case .apply = command { return true }
        return false
      })
  }

  func testLowercaseFindContextIDRoundTripsIntoSerializedRouteRequest() async throws {
    let focus = FocusProbe()
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let lowerContextID = "01234567-89ab-cdef-0123-456789abcdef"
    let message = try CodeMirrorInboundMessage.decode([
      "type": "commandContext",
      "sessionID": session.id.rawValue.uuidString,
      "replicaID": replicaID.rawValue.uuidString,
      "loadID": loadID.uuidString,
      "revision": 0,
      "contextSequence": 1,
      "commandScope": "find",
      "findContextID": lowerContextID,
      "undoSupported": true,
      "undoEnabled": true,
      "redoSupported": true,
      "redoEnabled": false,
    ])
    session.receive(message)
    guard case .find(let context) = session.focusedCommandContext() else {
      XCTFail("lowercase Find context report was not accepted")
      return
    }
    XCTAssertEqual(context.id.rawValue.uuidString.lowercased(), lowerContextID)

    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .find(context.id))
    }
    var requestID: UUID?
    var routePayload: [String: Any]?
    for _ in 0..<20 where requestID == nil {
      await Task.yield()
      for command in commands {
        guard case .routeCommand(let value, let request) = command,
          request.command == .undo
        else {
          continue
        }
        requestID = value
        routePayload = command.payload
        break
      }
    }
    guard let requestID, let routePayload else {
      XCTFail("Find route request was not sent")
      return
    }
    XCTAssertEqual(routePayload["expectation"] as? String, "find")
    XCTAssertEqual(routePayload["findContextID"] as? String, lowerContextID)

    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .find(context.id),
        result: .handledByEmbeddedControl
      ))
    let result = try await pending.value
    XCTAssertEqual(result, .handledByEmbeddedControl)
  }

  func testRouteCommandForwardsOnceAndFailsClosedWhenFocusChanges() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .content)

    let forwardedTask = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<10 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    let forwardedResult = try await forwardedTask.value
    XCTAssertEqual(forwardedResult, .forwardedToHost)
    XCTAssertEqual(
      events.compactMap { event in
        if case .command(let eventReplicaID, let command) = event {
          return (eventReplicaID, command)
        }
        return nil
      }.count,
      1
    )

    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    XCTAssertEqual(
      events.compactMap { event in
        if case .command = event { return event }
        return nil
      }.count,
      1
    )

    let changingFocusTask = Task { @MainActor in
      try await session.routeCommand(.redo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var changingFocusRequestID: UUID?
    for _ in 0..<10 where changingFocusRequestID == nil {
      await Task.yield()
      changingFocusRequestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .redo {
            return value
          }
          return nil
        }.first
    }
    guard let changingFocusRequestID else {
      XCTFail("redo route command was not sent")
      return
    }
    focus.value = false
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: changingFocusRequestID,
        command: .redo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    let changingFocusResult = await changingFocusTask.result
    if case .success(let result) = changingFocusResult {
      XCTAssertEqual(result, .unavailable)
    } else {
      XCTFail("route command failed instead of returning unavailable after focus changed")
    }
    XCTAssertEqual(
      events.compactMap { event in
        if case .command = event { return event }
        return nil
      }.count,
      1
    )
  }

  func testRouteCommandRejectsResponseFromStaleCurrentRevision() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<10 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }

    let replacement = try session.replaceImmediately(
      expectedRevision: .zero,
      changes: [CodeMirrorChange(rangeUTF16: 0..<6, insertedText: "new")],
      in: replicaID
    )
    XCTAssertEqual(replacement.revision, CodeMirrorRevision(1))
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))

    let staleResult = try await pending.value
    XCTAssertEqual(staleResult, .unavailable)
    XCTAssertEqual(try session.snapshot().text, "new")
    XCTAssertFalse(
      events.contains {
        if case .command = $0 { return true }
        return false
      })
  }

  func testRouteCommandIgnoresWrongIdentityAndCommandWithoutPublishing() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<20 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }

    session.receive(
      .commandRouteResult(
        sessionID: CodeMirrorSessionID(),
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: UUID(),
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .redo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))

    let result = await pending.result
    if case .success(let value) = result {
      XCTAssertEqual(value, .unavailable)
    } else {
      XCTFail("wrong route identity unexpectedly failed the request")
    }
    XCTAssertFalse(
      events.contains {
        if case .command = $0 { return true }
        return false
      })

    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    XCTAssertFalse(
      events.contains {
        if case .command = $0 { return true }
        return false
      })
  }

  func testRouteCommandInvalidationResumesWithoutPublishing() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<20 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }

    session.invalidate()
    let result = await pending.result
    if case .failure(let error) = result {
      XCTAssertEqual(error as? CodeMirrorSessionError, .invalidated)
    } else {
      XCTFail("invalidating the session unexpectedly completed route command")
    }
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    XCTAssertFalse(
      events.contains {
        if case .command = $0 { return true }
        return false
      })
  }

  func testRouteCommandUsesResultAfterCachedFocusChanges() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    sendCommandContext(
      session, replicaID: replicaID, loadID: loadID, sequence: 1, scope: .content)
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<10 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }
    let findContextID = CodeMirrorFindCommandContextID(rawValue: UUID())
    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 2,
      scope: .find,
      findContextID: findContextID,
      undo: CodeMirrorCommandAvailability(isSupported: true, isEnabled: true)
    )
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .handledByEmbeddedControl
      ))

    let embeddedResult = try await pending.value
    XCTAssertEqual(embeddedResult, .handledByEmbeddedControl)
    XCTAssertFalse(
      events.contains {
        if case .command = $0 { return true }
        return false
      })
  }

  func testReplacingReplicaRetiresOldPageMessagesAndPendingRoute() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let oldLoadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<10 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }

    let newLoadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    XCTAssertNotEqual(oldLoadID, newLoadID)
    let replacementResult = await pending.result
    if case .failure(let error) = replacementResult {
      XCTAssertEqual(error as? CodeMirrorSessionError, .replicaUnavailable)
    } else {
      XCTFail("replacing a replica unexpectedly acknowledged its old route")
    }

    session.receive(
      .configured(sessionID: session.id, replicaID: replicaID, loadID: oldLoadID))
    sendCommandContext(
      session, replicaID: replicaID, loadID: oldLoadID, sequence: 1, scope: .content)
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: oldLoadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    XCTAssertFalse(
      events.contains { event in
        if case .command = event { return true }
        return false
      })
    XCTAssertEqual(session.focusedCommandContext(), .unavailable(replicaID))

    session.receive(.ready(sessionID: session.id, replicaID: replicaID, loadID: newLoadID))
    session.receive(.configured(sessionID: session.id, replicaID: replicaID, loadID: newLoadID))
    sendCommandContext(
      session, replicaID: replicaID, loadID: newLoadID, sequence: 1, scope: .content)
    XCTAssertEqual(session.focusedCommandContext(), .content(replicaID))
    XCTAssertTrue(
      events.contains { event in
        if case .ready(let eventReplicaID, let eventLoadID) = event {
          return eventReplicaID == replicaID && eventLoadID == newLoadID
        }
        return false
      })
  }

  func testFindRouteRejectsForwardedResultWithoutPublishingDocumentCommand() async throws {
    let focus = FocusProbe()
    var events: [CodeMirrorEvent] = []
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      events.append(event)
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let contextID = CodeMirrorFindCommandContextID(rawValue: UUID())
    sendCommandContext(
      session,
      replicaID: replicaID,
      loadID: loadID,
      sequence: 1,
      scope: .find,
      findContextID: contextID,
      undo: CodeMirrorCommandAvailability(isSupported: true, isEnabled: true)
    )
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .find(contextID))
    }
    var requestID: UUID?
    for _ in 0..<20 where requestID == nil {
      await Task.yield()
      requestID = routeRequestID(in: commands, command: .undo)
    }
    guard let requestID else {
      XCTFail("Find route command was not sent")
      return
    }
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .find(contextID),
        result: .forwardedToHost
      ))
    let result = try await pending.value
    XCTAssertEqual(result, .unavailable)
    XCTAssertFalse(
      events.contains { event in
        if case .command = event { return true }
        return false
      })
  }

  func testRouteCommandIgnoresWrongReplicaResultUntilCancellation() async throws {
    let focus = FocusProbe()
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true
    let pending = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var requestID: UUID?
    for _ in 0..<10 where requestID == nil {
      await Task.yield()
      requestID =
        commands.compactMap { command in
          if case .routeCommand(let value, let request) = command, request.command == .undo {
            return value
          }
          return nil
        }.first
    }
    guard let requestID else {
      XCTFail("route command was not sent")
      return
    }

    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: CodeMirrorReplicaID(),
        loadID: loadID,
        revision: .zero,
        requestID: requestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .forwardedToHost
      ))
    pending.cancel()
    let result = await pending.result
    if case .failure(let error) = result {
      XCTAssertEqual(error as? CodeMirrorSessionError, .timeout)
    } else {
      XCTFail("a wrong-replica route result unexpectedly completed the request")
    }
  }

  func testRouteCommandCancellationAndOverflowAreRecoverable() async throws {
    let focus = FocusProbe()
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    _ = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true

    let pending = (0..<32).map { _ in
      Task { @MainActor in
        try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
      }
    }
    for _ in 0..<40 {
      await Task.yield()
    }
    let overflowTask = Task { @MainActor in
      try await session.routeCommand(.redo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    let overflow = await overflowTask.result
    if case .failure(let error) = overflow {
      XCTAssertEqual(error as? CodeMirrorSessionError, .timeout)
    } else {
      XCTFail("route command overflow unexpectedly succeeded")
    }

    pending[0].cancel()
    let cancellation = await pending[0].result
    if case .failure(let error) = cancellation {
      XCTAssertEqual(error as? CodeMirrorSessionError, .timeout)
    } else {
      XCTFail("cancelled route command unexpectedly succeeded")
    }
    for task in pending.dropFirst() {
      task.cancel()
      _ = await task.result
    }
    XCTAssertEqual(
      commands.filter {
        if case .routeCommand = $0 { return true }
        return false
      }.count, 32)
  }

  func testPendingOperationsShareOneBudgetAcrossFlushFormatAndRoute() async throws {
    let focus = FocusProbe()
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    _ = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true

    let flushTasks = (0..<11).map { _ in
      Task { @MainActor in
        do {
          _ = try await session.flush()
          return Result<Void, CodeMirrorSessionError>.success(())
        } catch let error as CodeMirrorSessionError {
          return Result<Void, CodeMirrorSessionError>.failure(error)
        } catch {
          return Result<Void, CodeMirrorSessionError>.failure(.transportFailure)
        }
      }
    }
    let formatTasks = (0..<11).map { _ in
      Task { @MainActor in
        do {
          _ = try await session.format(in: replicaID)
          return Result<Void, CodeMirrorSessionError>.success(())
        } catch let error as CodeMirrorSessionError {
          return Result<Void, CodeMirrorSessionError>.failure(error)
        } catch {
          return Result<Void, CodeMirrorSessionError>.failure(.transportFailure)
        }
      }
    }
    let routeTasks = (0..<10).map { _ in
      Task { @MainActor in
        do {
          _ = try await session.routeCommand(
            .undo, in: replicaID, expecting: .contentOrCurrentFind)
          return Result<Void, CodeMirrorSessionError>.success(())
        } catch let error as CodeMirrorSessionError {
          return Result<Void, CodeMirrorSessionError>.failure(error)
        } catch {
          return Result<Void, CodeMirrorSessionError>.failure(.transportFailure)
        }
      }
    }

    func requiredCommandCount() -> Int {
      commands.reduce(into: 0) { count, command in
        switch command {
        case .flush, .format, .routeCommand:
          count += 1
        default:
          break
        }
      }
    }

    for _ in 0..<100 where requiredCommandCount() < 32 {
      await Task.yield()
    }
    XCTAssertEqual(requiredCommandCount(), 32)

    let overflowTask = Task { @MainActor in
      do {
        _ = try await session.routeCommand(
          .redo, in: replicaID, expecting: .contentOrCurrentFind)
        return Result<Void, CodeMirrorSessionError>.success(())
      } catch let error as CodeMirrorSessionError {
        return Result<Void, CodeMirrorSessionError>.failure(error)
      } catch {
        return Result<Void, CodeMirrorSessionError>.failure(.transportFailure)
      }
    }
    let overflow = await overflowTask.value
    if case .failure(.timeout) = overflow {
    } else {
      XCTFail("the shared pending-operation budget did not reject overflow")
    }
    XCTAssertEqual(requiredCommandCount(), 32)
    XCTAssertEqual(try session.snapshot().text, "source")

    session.invalidate()
    for task in flushTasks {
      _ = await task.value
    }
    for task in formatTasks {
      _ = await task.value
    }
    for task in routeTasks {
      _ = await task.value
    }
  }

  func testPendingOperationBudgetRecoversAfterCompletion() async throws {
    let focus = FocusProbe()
    var commands: [CodeMirrorHostCommand] = []
    let session = CodeMirrorSession(initialText: "source") { _ in .accept }
    let replicaID = CodeMirrorReplicaID()
    let loadID = try session.attach(
      replicaID: replicaID,
      isFocused: { focus.value },
      send: { commands.append($0) }
    )
    focus.value = true

    let flushTask = Task { @MainActor in try await session.flush() }
    let formatTask = Task { @MainActor in try await session.format(in: replicaID) }
    let routeTask = Task { @MainActor in
      try await session.routeCommand(.undo, in: replicaID, expecting: .contentOrCurrentFind)
    }
    var flushRequestID: UUID?
    var formatRequestID: UUID?
    var routeRequestID: UUID?
    for _ in 0..<100 where flushRequestID == nil || formatRequestID == nil || routeRequestID == nil
    {
      await Task.yield()
      flushRequestID =
        commands.compactMap { command in
          if case .flush(let requestID) = command { return requestID }
          return nil
        }.first
      formatRequestID =
        commands.compactMap { command in
          if case .format(let requestID) = command { return requestID }
          return nil
        }.first
      routeRequestID =
        commands.compactMap { command in
          if case .routeCommand(let requestID, _) = command { return requestID }
          return nil
        }.first
    }
    guard let flushRequestID, let formatRequestID, let routeRequestID else {
      XCTFail("mixed pending operation commands were not sent")
      session.invalidate()
      _ = await flushTask.result
      _ = await formatTask.result
      _ = await routeTask.result
      return
    }

    session.receive(
      .flushResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        requestID: flushRequestID,
        success: true,
        code: nil
      ))
    session.receive(
      .formatResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        requestID: formatRequestID,
        success: true
      ))
    session.receive(
      .commandRouteResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        revision: .zero,
        requestID: routeRequestID,
        command: .undo,
        expectation: .contentOrCurrentFind,
        result: .unavailable
      ))
    let flushSnapshot = try await flushTask.value
    let formatSnapshot = try await formatTask.value
    let routeResult = try await routeTask.value
    XCTAssertEqual(flushSnapshot.text, "source")
    XCTAssertEqual(formatSnapshot.text, "source")
    XCTAssertEqual(routeResult, .unavailable)

    let recoveredFlush = Task { @MainActor in try await session.flush() }
    var recoveredRequestID: UUID?
    for _ in 0..<20 where recoveredRequestID == nil {
      await Task.yield()
      recoveredRequestID =
        commands.compactMap { command in
          if case .flush(let requestID) = command, requestID != flushRequestID {
            return requestID
          }
          return nil
        }.last
    }
    guard let recoveredRequestID else {
      XCTFail("operation budget did not recover after completion")
      session.invalidate()
      _ = await recoveredFlush.result
      return
    }
    session.receive(
      .flushResult(
        sessionID: session.id,
        replicaID: replicaID,
        loadID: loadID,
        requestID: recoveredRequestID,
        success: true,
        code: nil
      ))
    let recoveredSnapshot = try await recoveredFlush.value
    XCTAssertEqual(recoveredSnapshot.text, "source")
  }

  func testDetachedAndReplacedReplicasDoNotRetainAcceptedRevisionKeys() throws {
    var transactionTexts: [String] = []
    var errors: [CodeMirrorSessionError] = []
    let session = CodeMirrorSession(initialText: "source") { event in
      switch event {
      case .transaction(_, let snapshot):
        transactionTexts.append(snapshot.text)
      case .failure(_, let error):
        errors.append(error)
      default:
        break
      }
      return .accept
    }
    let replicaID = CodeMirrorReplicaID()
    let firstLoadID = try session.attach(replicaID: replicaID, isFocused: { false }, send: { _ in })

    func receive(
      _ loadID: UUID,
      baseRevision: CodeMirrorRevision,
      revision: CodeMirrorRevision,
      text: String,
      removedText: String
    ) {
      session.receive(
        .transaction(
          CodeMirrorTransaction(
            sessionID: session.id,
            replicaID: replicaID,
            loadID: loadID,
            baseRevision: baseRevision,
            revision: revision,
            changes: [
              CodeMirrorChange(
                rangeUTF16: 0..<removedText.utf16.count,
                insertedText: text,
                removedText: removedText
              )
            ],
            selectionBefore: CodeMirrorSelection(anchorUTF16: 0, headUTF16: 0),
            selectionAfter: CodeMirrorSelection(
              anchorUTF16: text.utf16.count, headUTF16: text.utf16.count)
          )))
    }

    receive(
      firstLoadID,
      baseRevision: .zero,
      revision: CodeMirrorRevision(1),
      text: "first",
      removedText: "source"
    )
    XCTAssertEqual(try session.snapshot().text, "first")

    let replacementLoadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { _ in })
    receive(
      replacementLoadID,
      baseRevision: .zero,
      revision: CodeMirrorRevision(1),
      text: "stale replacement",
      removedText: "source"
    )
    XCTAssertEqual(errors.count, 1)
    XCTAssertEqual(try session.snapshot().text, "first")
    receive(
      replacementLoadID,
      baseRevision: CodeMirrorRevision(1),
      revision: CodeMirrorRevision(2),
      text: "second",
      removedText: "first"
    )
    XCTAssertEqual(try session.snapshot().text, "second")

    session.detach(replicaID: replicaID, loadID: replacementLoadID)
    let detachedReplacementLoadID = try session.attach(
      replicaID: replicaID, isFocused: { false }, send: { _ in })
    receive(
      detachedReplacementLoadID,
      baseRevision: CodeMirrorRevision(1),
      revision: CodeMirrorRevision(2),
      text: "stale detached",
      removedText: "first"
    )
    XCTAssertEqual(errors.count, 2)
    XCTAssertEqual(try session.snapshot().text, "second")
    receive(
      detachedReplacementLoadID,
      baseRevision: CodeMirrorRevision(2),
      revision: CodeMirrorRevision(3),
      text: "third",
      removedText: "second"
    )
    XCTAssertEqual(try session.snapshot().text, "third")
    XCTAssertEqual(transactionTexts, ["first", "second", "third"])
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
      window.isReleasedWhenClosed = false
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
