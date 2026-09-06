import Foundation

internal enum CodeMirrorHostCommand: Sendable {
  case configure(
    configuration: CodeMirrorConfiguration, snapshot: CodeMirrorSnapshot,
    replicaID: CodeMirrorReplicaID, loadID: UUID)
  case updateConfiguration(CodeMirrorConfiguration)
  case apply(CodeMirrorSnapshot)
  case reconcile(snapshot: CodeMirrorSnapshot, preserveLocalChanges: Bool)
  case acknowledge(revision: CodeMirrorRevision)
  case focus
  case showFind
  case routeCommand(requestID: UUID, command: CodeMirrorCommand)
  case format(requestID: UUID)
  case flush(requestID: UUID)
  case selection(CodeMirrorSelection)
  case invalidate
}

internal enum CodeMirrorInboundMessage {
  case ready(sessionID: CodeMirrorSessionID?, replicaID: CodeMirrorReplicaID?, loadID: UUID?)
  case configured(sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID)
  case focusTraversal(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID, forward: Bool)
  case focusScope(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID,
    sequence: UInt64, scope: CodeMirrorFocusScope)
  case transaction(CodeMirrorTransaction)
  case selection(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID,
    revision: CodeMirrorRevision, selection: CodeMirrorSelection)
  case command(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID,
    revision: CodeMirrorRevision, command: CodeMirrorCommand)
  case commandRouteResult(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID,
    revision: CodeMirrorRevision, requestID: UUID, command: CodeMirrorCommand,
    result: CodeMirrorCommandRoutingResult)
  case formatResult(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID, requestID: UUID,
    success: Bool)
  case flushResult(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID, requestID: UUID,
    success: Bool, code: String?)
  case failure(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID?, loadID: UUID?, code: String)

  static func decode(_ body: Any) throws -> CodeMirrorInboundMessage {
    guard JSONSerialization.isValidJSONObject(body) else {
      throw CodeMirrorSessionError.transportFailure
    }
    let data = try JSONSerialization.data(withJSONObject: body)
    let message = try JSONDecoder().decode(WireMessage.self, from: data)
    return try message.decodeMessage()
  }
}

internal enum CodeMirrorFocusScope: String, Equatable, Sendable {
  case content
  case embeddedControl
  case other
}

private struct WireSelection: Codable {
  let anchorUTF16: Int
  let headUTF16: Int

  var value: CodeMirrorSelection {
    CodeMirrorSelection(anchorUTF16: anchorUTF16, headUTF16: headUTF16)
  }
}

private struct WireChange: Codable {
  let fromUTF16: Int
  let toUTF16: Int
  let insertedText: String
  let removedText: String
}

private struct WireComposition: Codable {
  let phase: String
  let id: String?
}

private struct WireMessage: Codable {
  let type: String
  let sessionID: String?
  let replicaID: String?
  let loadID: String?
  let baseRevision: UInt64?
  let revision: UInt64?
  let requestID: String?
  let changes: [WireChange]?
  let selectionBefore: WireSelection?
  let selectionAfter: WireSelection?
  let selection: WireSelection?
  let composition: WireComposition?
  let command: String?
  let focusSequence: UInt64?
  let focusScope: String?
  let result: String?
  let direction: String?
  let success: Bool?
  let code: String?

  func decodeMessage() throws -> CodeMirrorInboundMessage {
    switch type {
    case "ready":
      return .ready(
        sessionID: try sessionID.map { try $0.sessionID() },
        replicaID: try replicaID.map { try $0.replicaID() },
        loadID: try loadID.map { try $0.uuid() }
      )
    case "configured":
      return .configured(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid()
      )
    case "focusTraversal":
      guard let direction, direction == "next" || direction == "previous" else {
        throw CodeMirrorSessionError.transportFailure
      }
      return .focusTraversal(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        forward: direction == "next"
      )
    case "focusScope":
      guard let focusScope, let scope = CodeMirrorFocusScope(rawValue: focusScope) else {
        throw CodeMirrorSessionError.transportFailure
      }
      return .focusScope(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        sequence: try focusSequence.required(),
        scope: scope
      )
    case "transaction":
      return .transaction(try transaction())
    case "selection":
      return .selection(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        revision: CodeMirrorRevision(try revision.required()),
        selection: try selection.required().value
      )
    case "command":
      guard let command, let command = CodeMirrorCommand(rawValue: command) else {
        throw CodeMirrorSessionError.unsupportedCommand
      }
      return .command(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        revision: CodeMirrorRevision(try revision.required()),
        command: command
      )
    case "commandRouteResult":
      guard let command, let command = CodeMirrorCommand(rawValue: command),
        let result, let result = CodeMirrorCommandRoutingResult(rawValue: result)
      else {
        throw CodeMirrorSessionError.transportFailure
      }
      return .commandRouteResult(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        revision: CodeMirrorRevision(try revision.required()),
        requestID: try requestID.required().uuid(),
        command: command,
        result: result
      )
    case "formatResult":
      return .formatResult(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        requestID: try requestID.required().uuid(),
        success: success ?? false
      )
    case "flushResult":
      return .flushResult(
        sessionID: try sessionID.required().sessionID(),
        replicaID: try replicaID.required().replicaID(),
        loadID: try loadID.required().uuid(),
        requestID: try requestID.required().uuid(),
        success: success ?? false,
        code: code
      )
    case "failure":
      let parsedSessionID = try sessionID.map { try $0.sessionID() }
      let parsedReplicaID = try replicaID.map { try $0.replicaID() }
      let parsedLoadID = try loadID.map { try $0.uuid() }
      guard let parsedSessionID else {
        throw CodeMirrorSessionError.transportFailure
      }
      return .failure(
        sessionID: parsedSessionID, replicaID: parsedReplicaID, loadID: parsedLoadID,
        code: code ?? "transportFailure")
    default:
      throw CodeMirrorSessionError.transportFailure
    }
  }

  private func transaction() throws -> CodeMirrorTransaction {
    let wireChanges = try changes.required()
    var previousEnd = 0
    let changes = try wireChanges.map { wireChange in
      guard wireChange.fromUTF16 >= 0,
        wireChange.toUTF16 >= wireChange.fromUTF16,
        wireChange.fromUTF16 >= previousEnd
      else {
        throw CodeMirrorSessionError.malformedChange
      }
      previousEnd = wireChange.toUTF16
      return CodeMirrorChange(
        rangeUTF16: wireChange.fromUTF16..<wireChange.toUTF16,
        insertedText: wireChange.insertedText,
        removedText: wireChange.removedText
      )
    }
    let composition = try decodeComposition(composition)
    return CodeMirrorTransaction(
      sessionID: try sessionID.required().sessionID(),
      replicaID: try replicaID.required().replicaID(),
      loadID: try loadID.required().uuid(),
      baseRevision: CodeMirrorRevision(try baseRevision.required()),
      revision: CodeMirrorRevision(try revision.required()),
      changes: changes,
      selectionBefore: try selectionBefore.required().value,
      selectionAfter: try selectionAfter.required().value,
      composition: composition
    )
  }

  private func decodeComposition(_ value: WireComposition?) throws -> CodeMirrorCompositionPhase {
    guard let value else {
      return .none
    }
    if value.phase == "none" {
      return .none
    }
    guard let id = value.id.flatMap(UUID.init(uuidString:)) else {
      throw CodeMirrorSessionError.malformedChange
    }
    switch value.phase {
    case "began":
      return .began(id)
    case "updated":
      return .updated(id)
    case "ended":
      return .ended(id)
    default:
      throw CodeMirrorSessionError.malformedChange
    }
  }
}

extension Optional {
  fileprivate func required() throws -> Wrapped {
    guard let value = self else {
      throw CodeMirrorSessionError.transportFailure
    }
    return value
  }
}

extension String {
  fileprivate func uuid() throws -> UUID {
    guard let value = UUID(uuidString: self) else {
      throw CodeMirrorSessionError.transportFailure
    }
    return value
  }

  fileprivate func sessionID() throws -> CodeMirrorSessionID {
    CodeMirrorSessionID(try uuid())
  }

  fileprivate func replicaID() throws -> CodeMirrorReplicaID {
    CodeMirrorReplicaID(try uuid())
  }
}

extension CodeMirrorHostCommand {
  var payload: [String: Any] {
    switch self {
    case .configure(let configuration, let snapshot, let replicaID, let loadID):
      return [
        "type": "configure",
        "sessionID": snapshot.sessionID.rawValue.uuidString,
        "replicaID": replicaID.rawValue.uuidString,
        "loadID": loadID.uuidString,
        "revision": NSNumber(value: snapshot.revision.rawValue),
        "text": snapshot.text,
        "selections": selectionsPayload(snapshot.selections),
        "configuration": configurationPayload(configuration),
      ]
    case .updateConfiguration(let configuration):
      return [
        "type": "updateConfiguration",
        "configuration": configurationPayload(configuration),
      ]
    case .apply(let snapshot):
      return [
        "type": "apply",
        "revision": NSNumber(value: snapshot.revision.rawValue),
        "text": snapshot.text,
        "selections": selectionsPayload(snapshot.selections),
      ]
    case .reconcile(let snapshot, let preserveLocalChanges):
      return [
        "type": "reconcile",
        "revision": NSNumber(value: snapshot.revision.rawValue),
        "text": snapshot.text,
        "selections": selectionsPayload(snapshot.selections),
        "preserveLocalChanges": preserveLocalChanges,
      ]
    case .acknowledge(let revision):
      return [
        "type": "acknowledge",
        "revision": NSNumber(value: revision.rawValue),
      ]
    case .focus:
      return ["type": "focus"]
    case .showFind:
      return ["type": "showFind"]
    case .routeCommand(let requestID, let command):
      return [
        "type": "routeCommand",
        "requestID": requestID.uuidString,
        "command": command.rawValue,
      ]
    case .format(let requestID):
      return ["type": "format", "requestID": requestID.uuidString]
    case .flush(let requestID):
      return ["type": "flush", "requestID": requestID.uuidString]
    case .selection(let selection):
      return ["type": "selection", "selection": selectionPayload(selection)]
    case .invalidate:
      return ["type": "invalidate"]
    }
  }
}

private func configurationPayload(_ configuration: CodeMirrorConfiguration) -> [String: Any] {
  [
    "language": configuration.language.rawValue,
    "isReadOnly": configuration.isReadOnly,
    "wrapsLines": configuration.wrapsLines,
    "showsLineNumbers": configuration.showsLineNumbers,
    "commandTimeoutMilliseconds": configuration.commandTimeoutMilliseconds,
    "maximumPendingTransactions": configuration.maximumPendingTransactions,
    "editorName": configuration.editorName ?? "",
    "appearance": [
      "colorScheme": configuration.appearance.colorScheme.rawValue,
      "increaseContrast": configuration.appearance.increaseContrast,
      "reduceMotion": configuration.appearance.reduceMotion,
      "reduceTransparency": configuration.appearance.reduceTransparency,
    ],
  ]
}

private func selectionsPayload(_ selections: [CodeMirrorReplicaID: CodeMirrorSelection])
  -> [[String: Any]]
{
  selections.map { replicaID, selection in
    [
      "replicaID": replicaID.rawValue.uuidString,
      "anchorUTF16": selection.anchorUTF16,
      "headUTF16": selection.headUTF16,
    ]
  }
}

private func selectionPayload(_ selection: CodeMirrorSelection) -> [String: Any] {
  [
    "anchorUTF16": selection.anchorUTF16,
    "headUTF16": selection.headUTF16,
  ]
}

@MainActor
public final class CodeMirrorSession {
  private static let maximumPendingRouteCommands = 32

  public let id: CodeMirrorSessionID
  public private(set) var configuration: CodeMirrorConfiguration

  private var sourceText: String
  private var currentRevision: CodeMirrorRevision
  private var selections: [CodeMirrorReplicaID: CodeMirrorSelection]
  private var replicas: [CodeMirrorReplicaID: ReplicaConnection] = [:]
  private var acceptedRevisions: [CodeMirrorReplicaID: Set<UInt64>] = [:]
  private var pendingFlushes: [UUID: PendingFlush] = [:]
  private var pendingFormats: [UUID: PendingFormat] = [:]
  private var pendingRouteCommands: [UUID: PendingRouteCommand] = [:]
  private var replicaAppearances: [CodeMirrorReplicaID: CodeMirrorAppearance] = [:]
  private var lastSentConfigurations: [CodeMirrorReplicaID: CodeMirrorConfiguration] = [:]
  private var focusScopes: [CodeMirrorReplicaID: FocusScopeReport] = [:]
  private var isInvalidated = false
  private let onEvent: @MainActor (CodeMirrorEvent) -> CodeMirrorEventDisposition

  private struct ReplicaConnection {
    let loadID: UUID
    let send: @MainActor (CodeMirrorHostCommand) -> Void
    let isFocused: @MainActor () -> Bool
    let traverseFocus: @MainActor (Bool) -> Void
    let operationDidFinish: @MainActor (CodeMirrorHostCommand) -> Void
  }

  private struct FocusScopeReport {
    let loadID: UUID
    let sequence: UInt64
    let scope: CodeMirrorFocusScope
  }

  @MainActor
  private final class PendingFlush {
    let continuation: CheckedContinuation<CodeMirrorSnapshot, Error>
    var waitingFor: Set<CodeMirrorReplicaID>
    var timeoutTask: Task<Void, Never>?

    init(
      continuation: CheckedContinuation<CodeMirrorSnapshot, Error>,
      waitingFor: Set<CodeMirrorReplicaID>
    ) {
      self.continuation = continuation
      self.waitingFor = waitingFor
    }
  }

  @MainActor
  private final class PendingFormat {
    let continuation: CheckedContinuation<CodeMirrorSnapshot, Error>
    let replicaID: CodeMirrorReplicaID
    var timeoutTask: Task<Void, Never>?

    init(
      continuation: CheckedContinuation<CodeMirrorSnapshot, Error>,
      replicaID: CodeMirrorReplicaID
    ) {
      self.continuation = continuation
      self.replicaID = replicaID
    }
  }

  @MainActor
  private final class PendingRouteCommand {
    let continuation: CheckedContinuation<CodeMirrorCommandRoutingResult, Error>
    let replicaID: CodeMirrorReplicaID
    let loadID: UUID
    let revision: CodeMirrorRevision
    let command: CodeMirrorCommand
    var timeoutTask: Task<Void, Never>?

    init(
      continuation: CheckedContinuation<CodeMirrorCommandRoutingResult, Error>,
      replicaID: CodeMirrorReplicaID,
      loadID: UUID,
      revision: CodeMirrorRevision,
      command: CodeMirrorCommand
    ) {
      self.continuation = continuation
      self.replicaID = replicaID
      self.loadID = loadID
      self.revision = revision
      self.command = command
    }
  }

  public init(
    id: CodeMirrorSessionID = CodeMirrorSessionID(),
    initialText: String,
    configuration: CodeMirrorConfiguration = CodeMirrorConfiguration(),
    onEvent: @escaping @MainActor (CodeMirrorEvent) -> CodeMirrorEventDisposition
  ) {
    self.id = id
    self.sourceText = initialText
    self.configuration = configuration.normalized
    self.currentRevision = .zero
    self.selections = [:]
    self.onEvent = onEvent
  }

  public func update(configuration: CodeMirrorConfiguration) {
    guard !isInvalidated else { return }
    self.configuration = configuration.normalized
    for replicaID in replicas.keys {
      sendConfigurationIfChanged(for: replicaID)
    }
  }

  internal func update(appearance: CodeMirrorAppearance, for replicaID: CodeMirrorReplicaID) {
    guard !isInvalidated, replicas[replicaID] != nil else { return }
    replicaAppearances[replicaID] = appearance
    sendConfigurationIfChanged(for: replicaID)
  }

  public func snapshot() throws -> CodeMirrorSnapshot {
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    return currentSnapshot
  }

  public func focusedReplicaID() -> CodeMirrorReplicaID? {
    guard !isInvalidated else { return nil }
    return replicas.first(where: { $0.value.isFocused() })?.key
  }

  public func focusedEditorContentReplicaID() -> CodeMirrorReplicaID? {
    guard !isInvalidated else { return nil }
    return replicas.first { replicaID, replica in
      replica.isFocused()
        && focusScopes[replicaID]?.loadID == replica.loadID
        && focusScopes[replicaID]?.scope == .content
    }?.key
  }

  public func routeCommand(
    _ command: CodeMirrorCommand,
    in replicaID: CodeMirrorReplicaID
  ) async throws -> CodeMirrorCommandRoutingResult {
    await Task.yield()
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    let replica = try replica(replicaID)
    guard replica.isFocused() else {
      return .unavailable
    }
    guard pendingRouteCommands.count < Self.maximumPendingRouteCommands else {
      throw CodeMirrorSessionError.timeout
    }
    let requestID = UUID()
    let revision = currentRevision
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<CodeMirrorCommandRoutingResult, Error>) in
          guard !Task.isCancelled else {
            continuation.resume(throwing: CodeMirrorSessionError.timeout)
            return
          }
          let pending = PendingRouteCommand(
            continuation: continuation,
            replicaID: replicaID,
            loadID: replica.loadID,
            revision: revision,
            command: command
          )
          pending.timeoutTask = timeoutTask { [weak self] in
            self?.finishPendingRouteCommand(requestID, with: .timeout)
          }
          pendingRouteCommands[requestID] = pending
          replicas[replicaID]?.send(.routeCommand(requestID: requestID, command: command))
        }
      },
      onCancel: { [weak self] in
        Task { @MainActor in
          self?.finishPendingRouteCommand(requestID, with: .timeout)
        }
      })
  }

  public func flush() async throws -> CodeMirrorSnapshot {
    await Task.yield()
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    let replicaIDs = Set(replicas.keys)
    guard !replicaIDs.isEmpty else {
      return try snapshot()
    }
    let requestID = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let pending = PendingFlush(continuation: continuation, waitingFor: replicaIDs)
      pending.timeoutTask = timeoutTask { [weak self] in
        self?.timeoutFlush(requestID)
      }
      pendingFlushes[requestID] = pending
      for replicaID in replicaIDs {
        guard pendingFlushes[requestID] != nil else { break }
        replicas[replicaID]?.send(.flush(requestID: requestID))
      }
    }
  }

  public func replace(
    expectedRevision: CodeMirrorRevision,
    changes: [CodeMirrorChange],
    selection: CodeMirrorSelection? = nil,
    in replicaID: CodeMirrorReplicaID? = nil
  ) async throws -> CodeMirrorSnapshot {
    await Task.yield()
    return try replaceImmediately(
      expectedRevision: expectedRevision,
      changes: changes,
      selection: selection,
      in: replicaID
    )
  }

  public func replaceImmediately(
    expectedRevision: CodeMirrorRevision,
    changes: [CodeMirrorChange],
    selection: CodeMirrorSelection? = nil,
    in replicaID: CodeMirrorReplicaID? = nil
  ) throws -> CodeMirrorSnapshot {
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    guard expectedRevision == currentRevision else {
      throw CodeMirrorSessionError.staleRevision(
        expected: currentRevision, actual: expectedRevision)
    }
    return try applyProgrammaticChanges(changes, selection: selection, in: replicaID)
  }

  public func replace(text: String, preservingSelections: Bool) async throws -> CodeMirrorSnapshot {
    await Task.yield()
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    let previousSelections = preservingSelections ? selections : [:]
    let change = CodeMirrorChange(
      rangeUTF16: 0..<sourceText.utf16.count,
      insertedText: text
    )
    _ = try applyProgrammaticChanges([change], selection: nil, in: nil, broadcast: false)
    if preservingSelections {
      selections = previousSelections.mapValues { normalizedSelection($0, in: text) }
    }
    let snapshot = currentSnapshot
    for replica in replicas.values {
      replica.send(.apply(snapshot))
    }
    return snapshot
  }

  public func focus(_ replicaID: CodeMirrorReplicaID) async throws {
    await Task.yield()
    try replica(replicaID).send(.focus)
  }

  public func showFind(in replicaID: CodeMirrorReplicaID) async throws {
    await Task.yield()
    try replica(replicaID).send(.showFind)
  }

  public func format(in replicaID: CodeMirrorReplicaID) async throws -> CodeMirrorSnapshot {
    await Task.yield()
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    _ = try replica(replicaID)
    let requestID = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let pending = PendingFormat(continuation: continuation, replicaID: replicaID)
      pending.timeoutTask = timeoutTask { [weak self] in
        self?.timeoutFormat(requestID)
      }
      pendingFormats[requestID] = pending
      replicas[replicaID]?.send(.format(requestID: requestID))
    }
  }

  public func setSelection(_ selection: CodeMirrorSelection, in replicaID: CodeMirrorReplicaID)
    async throws
  {
    await Task.yield()
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    guard isValid(selection: selection, in: sourceText) else {
      throw CodeMirrorSessionError.malformedChange
    }
    try replica(replicaID).send(.selection(selection))
    selections[replicaID] = selection
  }

  public func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    for replica in replicas.values {
      replica.send(.invalidate)
    }
    for requestID in Array(pendingFlushes.keys) {
      finishPendingFlush(requestID, with: .invalidated)
    }
    for requestID in Array(pendingFormats.keys) {
      finishPendingFormat(requestID, with: .invalidated)
    }
    for requestID in Array(pendingRouteCommands.keys) {
      finishPendingRouteCommand(requestID, with: .invalidated)
    }
    replicas.removeAll()
    replicaAppearances.removeAll()
    lastSentConfigurations.removeAll()
    focusScopes.removeAll()
  }

  internal func attach(
    replicaID: CodeMirrorReplicaID,
    isFocused: @escaping @MainActor () -> Bool,
    send: @escaping @MainActor (CodeMirrorHostCommand) -> Void,
    traverseFocus: @escaping @MainActor (Bool) -> Void = { _ in },
    operationDidFinish: @escaping @MainActor (CodeMirrorHostCommand) -> Void = { _ in }
  ) throws -> UUID {
    guard !isInvalidated else {
      throw CodeMirrorSessionError.invalidated
    }
    if let oldReplica = replicas[replicaID] {
      oldReplica.send(.invalidate)
      removeReplicaFromPendingOperations(replicaID)
      replicas.removeValue(forKey: replicaID)
    }
    replicaAppearances.removeValue(forKey: replicaID)
    focusScopes.removeValue(forKey: replicaID)
    lastSentConfigurations[replicaID] = configuration
    let loadID = UUID()
    replicas[replicaID] = ReplicaConnection(
      loadID: loadID, send: send, isFocused: isFocused, traverseFocus: traverseFocus,
      operationDidFinish: operationDidFinish)
    return loadID
  }

  internal func detach(replicaID: CodeMirrorReplicaID, loadID: UUID) {
    guard replicas[replicaID]?.loadID == loadID else { return }
    removeReplicaFromPendingOperations(replicaID)
    replicas.removeValue(forKey: replicaID)
    replicaAppearances.removeValue(forKey: replicaID)
    lastSentConfigurations.removeValue(forKey: replicaID)
    focusScopes.removeValue(forKey: replicaID)
  }

  internal func clearFocusScope(replicaID: CodeMirrorReplicaID, loadID: UUID) {
    guard matches(replicaID: replicaID, loadID: loadID) else { return }
    focusScopes.removeValue(forKey: replicaID)
    failRouteCommands(for: replicaID, loadID: loadID, with: .replicaUnavailable)
  }

  internal func receive(_ message: CodeMirrorInboundMessage) {
    guard !isInvalidated else { return }
    switch message {
    case .ready(let sessionID?, let replicaID?, let loadID?):
      receiveReady(sessionID: sessionID, replicaID: replicaID, loadID: loadID)
    case .ready:
      return
    case .configured(let sessionID, let replicaID, let loadID):
      receiveConfigured(sessionID: sessionID, replicaID: replicaID, loadID: loadID)
    case .focusTraversal(let sessionID, let replicaID, let loadID, let forward):
      receiveFocusTraversal(
        sessionID: sessionID, replicaID: replicaID, loadID: loadID, forward: forward)
    case .focusScope(let sessionID, let replicaID, let loadID, let sequence, let scope):
      receiveFocusScope(
        sessionID: sessionID, replicaID: replicaID, loadID: loadID, sequence: sequence, scope: scope
      )
    case .transaction(let transaction):
      receiveTransaction(transaction)
    case .selection(let sessionID, let replicaID, let loadID, let revision, let selection):
      receiveSelection(
        sessionID: sessionID, replicaID: replicaID, loadID: loadID, revision: revision,
        selection: selection)
    case .command(let sessionID, let replicaID, let loadID, let revision, let command):
      receiveCommand(
        sessionID: sessionID, replicaID: replicaID, loadID: loadID, revision: revision,
        command: command)
    case .commandRouteResult(
      let sessionID, let replicaID, let loadID, let revision, let requestID, let command, let result
    ):
      receiveCommandRouteResult(
        sessionID: sessionID,
        replicaID: replicaID,
        loadID: loadID,
        revision: revision,
        requestID: requestID,
        command: command,
        result: result
      )
    case .formatResult(let sessionID, let replicaID, let loadID, let requestID, let success):
      receiveFormatResult(
        sessionID: sessionID, replicaID: replicaID, loadID: loadID, requestID: requestID,
        success: success)
    case .flushResult(
      let sessionID, let replicaID, let loadID, let requestID, let success, let code):
      receiveFlushResult(
        sessionID: sessionID, replicaID: replicaID, loadID: loadID, requestID: requestID,
        success: success, code: code)
    case .failure(let sessionID, let replicaID, let loadID, let code):
      receiveFailure(sessionID: sessionID, replicaID: replicaID, loadID: loadID, code: code)
    }
  }

  internal func reportTransportFailure(replicaID: CodeMirrorReplicaID, loadID: UUID) {
    guard matches(replicaID: replicaID, loadID: loadID) else { return }
    publishFailure(replicaID: replicaID, error: .transportFailure)
    failOperations(for: replicaID, with: .transportFailure)
  }

  internal func hasPendingOperation(_ command: CodeMirrorHostCommand) -> Bool {
    switch command {
    case .routeCommand(let requestID, _):
      return pendingRouteCommands[requestID] != nil
    case .format(let requestID):
      return pendingFormats[requestID] != nil
    case .flush(let requestID):
      return pendingFlushes[requestID] != nil
    default:
      return true
    }
  }

  internal func failQueuedOperation(_ command: CodeMirrorHostCommand) {
    switch command {
    case .routeCommand(let requestID, _):
      finishPendingRouteCommand(requestID, with: .transportFailure)
    case .format(let requestID):
      finishPendingFormat(requestID, with: .transportFailure)
    case .flush(let requestID):
      finishPendingFlush(requestID, with: .transportFailure)
    default:
      break
    }
  }

  private var currentSnapshot: CodeMirrorSnapshot {
    CodeMirrorSnapshot(
      sessionID: id,
      revision: currentRevision,
      text: sourceText,
      selections: selections
    )
  }

  private func receiveReady(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID) else { return }
    focusScopes.removeValue(forKey: replicaID)
    let effectiveConfiguration = effectiveConfiguration(for: replicaID)
    lastSentConfigurations[replicaID] = effectiveConfiguration
    replicas[replicaID]?.send(
      .configure(
        configuration: effectiveConfiguration,
        snapshot: currentSnapshot,
        replicaID: replicaID,
        loadID: loadID
      ))
  }

  private func receiveFocusScope(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    sequence: UInt64,
    scope: CodeMirrorFocusScope
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID) else { return }
    if let previous = focusScopes[replicaID], previous.loadID == loadID,
      sequence <= previous.sequence
    {
      return
    }
    focusScopes[replicaID] = FocusScopeReport(loadID: loadID, sequence: sequence, scope: scope)
  }

  private func receiveConfigured(
    sessionID: CodeMirrorSessionID, replicaID: CodeMirrorReplicaID, loadID: UUID
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID) else { return }
    if case .invalidate = onEvent(.ready(replicaID: replicaID, loadID: loadID)) {
      invalidate()
    }
  }

  private func receiveFocusTraversal(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    forward: Bool
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID),
      replicas[replicaID]?.isFocused() == true
    else {
      return
    }
    replicas[replicaID]?.traverseFocus(forward)
  }

  private func receiveTransaction(_ transaction: CodeMirrorTransaction) {
    guard transaction.sessionID == id,
      matches(replicaID: transaction.replicaID, loadID: transaction.loadID)
    else {
      return
    }
    if hasAccepted(transaction) {
      return
    }
    do {
      let accepted = try validatedTransaction(transaction)
      let proposedSnapshot = accepted.snapshot
      sourceText = proposedSnapshot.text
      currentRevision = accepted.transaction.revision
      selections[accepted.transaction.replicaID] = accepted.transaction.selectionAfter
      remember(accepted.transaction)
      let disposition = onEvent(.transaction(accepted.transaction, snapshot: proposedSnapshot))
      switch disposition {
      case .accept:
        replicas[accepted.transaction.replicaID]?.send(
          .acknowledge(revision: accepted.transaction.revision))
        synchronizeReplicas(excluding: accepted.transaction.replicaID)
      case .replace(let authoritativeText):
        sourceText = authoritativeText
        selections = selections.mapValues { normalizedSelection($0, in: authoritativeText) }
        synchronizeReplicas(with: currentSnapshot)
        replicas[accepted.transaction.replicaID]?.send(
          .reconcile(snapshot: currentSnapshot, preserveLocalChanges: false))
      case .invalidate:
        invalidate()
      }
    } catch let error as CodeMirrorSessionError {
      publishFailure(replicaID: transaction.replicaID, error: error)
      replicas[transaction.replicaID]?.send(
        .reconcile(snapshot: currentSnapshot, preserveLocalChanges: true))
    } catch {
      publishFailure(replicaID: transaction.replicaID, error: .malformedChange)
      replicas[transaction.replicaID]?.send(
        .reconcile(snapshot: currentSnapshot, preserveLocalChanges: true))
    }
  }

  private func receiveSelection(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    revision: CodeMirrorRevision,
    selection: CodeMirrorSelection
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID) else { return }
    guard revision == currentRevision, isValid(selection: selection, in: sourceText) else {
      publishFailure(
        replicaID: replicaID, error: .staleRevision(expected: currentRevision, actual: revision))
      return
    }
    selections[replicaID] = selection
    if case .invalidate = onEvent(
      .selection(replicaID: replicaID, revision: revision, selection: selection))
    {
      invalidate()
    }
  }

  private func receiveCommand(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    revision: CodeMirrorRevision,
    command: CodeMirrorCommand
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID) else { return }
    guard revision == currentRevision else {
      publishFailure(
        replicaID: replicaID, error: .staleRevision(expected: currentRevision, actual: revision))
      return
    }
    if case .invalidate = onEvent(.command(replicaID: replicaID, command: command)) {
      invalidate()
    }
  }

  private func receiveCommandRouteResult(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    revision: CodeMirrorRevision,
    requestID: UUID,
    command: CodeMirrorCommand,
    result: CodeMirrorCommandRoutingResult
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID),
      let pending = pendingRouteCommands.removeValue(forKey: requestID)
    else {
      return
    }
    pending.timeoutTask?.cancel()
    replicas[pending.replicaID]?.operationDidFinish(
      .routeCommand(requestID: requestID, command: pending.command))
    guard pending.replicaID == replicaID, pending.loadID == loadID,
      pending.revision == revision, revision == currentRevision, pending.command == command,
      replicas[replicaID]?.isFocused() == true
    else {
      pending.continuation.resume(returning: .unavailable)
      return
    }
    guard result == .forwardedToHost else {
      pending.continuation.resume(returning: result)
      return
    }
    if case .invalidate = onEvent(.command(replicaID: replicaID, command: command)) {
      invalidate()
    }
    pending.continuation.resume(returning: .forwardedToHost)
  }

  private func receiveFormatResult(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    requestID: UUID,
    success: Bool
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID),
      let pending = pendingFormats.removeValue(forKey: requestID)
    else {
      return
    }
    pending.timeoutTask?.cancel()
    replicas[pending.replicaID]?.operationDidFinish(.format(requestID: requestID))
    if success {
      pending.continuation.resume(returning: currentSnapshot)
    } else {
      pending.continuation.resume(throwing: CodeMirrorSessionError.formatUnavailable)
    }
  }

  private func receiveFlushResult(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    requestID: UUID,
    success: Bool,
    code: String?
  ) {
    guard sessionID == id, matches(replicaID: replicaID, loadID: loadID),
      let pending = pendingFlushes[requestID]
    else {
      return
    }
    guard success else {
      finishPendingFlush(
        requestID,
        with: code.map(sessionError(for:)) ?? .compositionInProgress
      )
      return
    }
    pending.waitingFor.remove(replicaID)
    replicas[replicaID]?.operationDidFinish(.flush(requestID: requestID))
    guard pending.waitingFor.isEmpty else { return }
    pendingFlushes.removeValue(forKey: requestID)
    pending.timeoutTask?.cancel()
    pending.continuation.resume(returning: currentSnapshot)
  }

  private func receiveFailure(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID?,
    loadID: UUID?,
    code: String
  ) {
    guard sessionID == id else { return }
    if let replicaID, let loadID, !matches(replicaID: replicaID, loadID: loadID) {
      return
    }
    publishFailure(replicaID: replicaID, error: sessionError(for: code))
  }

  private func validatedTransaction(_ transaction: CodeMirrorTransaction) throws
    -> ValidatedTransaction
  {
    guard transaction.baseRevision == currentRevision,
      transaction.revision.rawValue == transaction.baseRevision.rawValue + 1
    else {
      throw CodeMirrorSessionError.staleRevision(
        expected: currentRevision, actual: transaction.baseRevision)
    }
    var previousEnd = 0
    var resolvedChanges: [CodeMirrorChange] = []
    for change in transaction.changes {
      guard change.rangeUTF16.lowerBound >= previousEnd,
        isValid(range: change.rangeUTF16, in: sourceText)
      else {
        throw CodeMirrorSessionError.malformedChange
      }
      let removedText = text(in: change.rangeUTF16, from: sourceText)
      guard change.removedText == removedText else {
        throw CodeMirrorSessionError.malformedChange
      }
      resolvedChanges.append(
        CodeMirrorChange(
          rangeUTF16: change.rangeUTF16,
          insertedText: change.insertedText,
          removedText: removedText
        ))
      previousEnd = change.rangeUTF16.upperBound
    }
    let newText = applying(resolvedChanges, to: sourceText)
    guard isValid(selection: transaction.selectionAfter, in: newText),
      isValid(selection: transaction.selectionBefore, in: sourceText)
    else {
      throw CodeMirrorSessionError.malformedChange
    }
    let resolvedTransaction = CodeMirrorTransaction(
      sessionID: transaction.sessionID,
      replicaID: transaction.replicaID,
      loadID: transaction.loadID,
      baseRevision: transaction.baseRevision,
      revision: transaction.revision,
      changes: resolvedChanges,
      selectionBefore: transaction.selectionBefore,
      selectionAfter: transaction.selectionAfter,
      composition: transaction.composition
    )
    return ValidatedTransaction(
      transaction: resolvedTransaction,
      snapshot: CodeMirrorSnapshot(
        sessionID: id,
        revision: transaction.revision,
        text: newText,
        selections: selections.merging([transaction.replicaID: transaction.selectionAfter]) {
          _, new in new
        }
      ))
  }

  private struct ValidatedTransaction {
    let transaction: CodeMirrorTransaction
    let snapshot: CodeMirrorSnapshot
  }

  private func applyProgrammaticChanges(
    _ changes: [CodeMirrorChange],
    selection: CodeMirrorSelection?,
    in replicaID: CodeMirrorReplicaID?,
    broadcast: Bool = true
  ) throws -> CodeMirrorSnapshot {
    if let replicaID {
      _ = try replica(replicaID)
    }
    let resolved = try resolve(changes, against: sourceText)
    let newText = applying(resolved, to: sourceText)
    if let selection, !isValid(selection: selection, in: newText) {
      throw CodeMirrorSessionError.malformedChange
    }
    sourceText = newText
    currentRevision = CodeMirrorRevision(currentRevision.rawValue + 1)
    if let replicaID, let selection {
      selections[replicaID] = selection
    }
    let snapshot = currentSnapshot
    if broadcast {
      for replica in replicas.values {
        replica.send(.apply(snapshot))
      }
    }
    return snapshot
  }

  private func effectiveConfiguration(for replicaID: CodeMirrorReplicaID)
    -> CodeMirrorConfiguration
  {
    guard let appearance = replicaAppearances[replicaID] else { return configuration }
    return configuration.withAppearance(appearance)
  }

  private func sendConfigurationIfChanged(for replicaID: CodeMirrorReplicaID) {
    guard let replica = replicas[replicaID] else { return }
    let effectiveConfiguration = effectiveConfiguration(for: replicaID)
    guard lastSentConfigurations[replicaID] != effectiveConfiguration else { return }
    lastSentConfigurations[replicaID] = effectiveConfiguration
    replica.send(.updateConfiguration(effectiveConfiguration))
  }

  private func resolve(_ changes: [CodeMirrorChange], against text: String) throws
    -> [CodeMirrorChange]
  {
    var previousEnd = 0
    var result: [CodeMirrorChange] = []
    for change in changes {
      guard change.rangeUTF16.lowerBound >= previousEnd,
        isValid(range: change.rangeUTF16, in: text)
      else {
        throw CodeMirrorSessionError.malformedChange
      }
      result.append(
        CodeMirrorChange(
          rangeUTF16: change.rangeUTF16,
          insertedText: change.insertedText,
          removedText: self.text(in: change.rangeUTF16, from: text)
        ))
      previousEnd = change.rangeUTF16.upperBound
    }
    return result
  }

  private func replica(_ replicaID: CodeMirrorReplicaID) throws -> ReplicaConnection {
    guard !isInvalidated, let replica = replicas[replicaID] else {
      throw isInvalidated
        ? CodeMirrorSessionError.invalidated : CodeMirrorSessionError.replicaUnavailable
    }
    return replica
  }

  private func matches(replicaID: CodeMirrorReplicaID, loadID: UUID) -> Bool {
    replicas[replicaID]?.loadID == loadID
  }

  private func synchronizeReplicas(excluding replicaID: CodeMirrorReplicaID) {
    synchronizeReplicas(with: currentSnapshot, excluding: replicaID)
  }

  private func synchronizeReplicas(
    with snapshot: CodeMirrorSnapshot, excluding replicaID: CodeMirrorReplicaID? = nil
  ) {
    for (id, replica) in replicas where id != replicaID {
      replica.send(.reconcile(snapshot: snapshot, preserveLocalChanges: true))
    }
  }

  private func publishFailure(replicaID: CodeMirrorReplicaID?, error: CodeMirrorSessionError) {
    let disposition = onEvent(.failure(replicaID: replicaID, error: error))
    if case .invalidate = disposition {
      invalidate()
    }
  }

  private func remember(_ transaction: CodeMirrorTransaction) {
    var revisions = acceptedRevisions[transaction.replicaID, default: []]
    revisions.insert(transaction.revision.rawValue)
    if revisions.count > 256, let oldest = revisions.min() {
      revisions.remove(oldest)
    }
    acceptedRevisions[transaction.replicaID] = revisions
  }

  private func hasAccepted(_ transaction: CodeMirrorTransaction) -> Bool {
    acceptedRevisions[transaction.replicaID]?.contains(transaction.revision.rawValue) == true
  }

  private func validUTF16Offset(_ offset: Int, in text: String) -> Bool {
    let units = Array(text.utf16)
    guard offset >= 0, offset <= units.count else { return false }
    guard offset > 0, offset < units.count else { return true }
    let previous = units[offset - 1]
    let next = units[offset]
    let isHighSurrogate = (0xD800...0xDBFF).contains(Int(previous))
    let isLowSurrogate = (0xDC00...0xDFFF).contains(Int(next))
    return !(isHighSurrogate && isLowSurrogate)
  }

  private func isValid(range: Range<Int>, in text: String) -> Bool {
    range.lowerBound >= 0 && range.lowerBound <= range.upperBound
      && validUTF16Offset(range.lowerBound, in: text)
      && validUTF16Offset(range.upperBound, in: text)
  }

  private func isValid(selection: CodeMirrorSelection, in text: String) -> Bool {
    validUTF16Offset(selection.anchorUTF16, in: text)
      && validUTF16Offset(selection.headUTF16, in: text)
  }

  private func normalizedSelection(_ selection: CodeMirrorSelection, in text: String)
    -> CodeMirrorSelection
  {
    return CodeMirrorSelection(
      anchorUTF16: normalizedUTF16Offset(selection.anchorUTF16, in: text),
      headUTF16: normalizedUTF16Offset(selection.headUTF16, in: text)
    )
  }

  private func normalizedUTF16Offset(_ offset: Int, in text: String) -> Int {
    let limit = text.utf16.count
    var normalized = min(max(offset, 0), limit)
    while normalized > 0 && !validUTF16Offset(normalized, in: text) {
      normalized -= 1
    }
    return normalized
  }

  private func text(in range: Range<Int>, from text: String) -> String {
    String(decoding: Array(text.utf16)[range], as: UTF16.self)
  }

  private func applying(_ changes: [CodeMirrorChange], to text: String) -> String {
    var units = Array(text.utf16)
    for change in changes.reversed() {
      units.replaceSubrange(change.rangeUTF16, with: change.insertedText.utf16)
    }
    return String(decoding: units, as: UTF16.self)
  }

  private func sessionError(for code: String) -> CodeMirrorSessionError {
    switch code {
    case "compositionInProgress": return .compositionInProgress
    case "formatUnavailable": return .formatUnavailable
    case "conflictingEdit": return .conflictingEdit
    case "unsupportedCommand": return .unsupportedCommand
    case "timeout": return .timeout
    default: return .transportFailure
    }
  }

  private func timeoutTask(_ operation: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    let nanoseconds = UInt64(configuration.commandTimeoutMilliseconds) * 1_000_000
    return Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: nanoseconds)
        guard !Task.isCancelled else { return }
        operation()
      } catch {
      }
    }
  }

  private func timeoutFlush(_ requestID: UUID) {
    finishPendingFlush(requestID, with: .timeout)
  }

  private func timeoutFormat(_ requestID: UUID) {
    finishPendingFormat(requestID, with: .timeout)
  }

  private func finishPendingFlush(_ requestID: UUID, with error: CodeMirrorSessionError) {
    guard let pending = pendingFlushes.removeValue(forKey: requestID) else { return }
    pending.timeoutTask?.cancel()
    for replicaID in pending.waitingFor {
      replicas[replicaID]?.operationDidFinish(.flush(requestID: requestID))
    }
    pending.continuation.resume(throwing: error)
  }

  private func finishPendingFormat(_ requestID: UUID, with error: CodeMirrorSessionError) {
    guard let pending = pendingFormats.removeValue(forKey: requestID) else { return }
    pending.timeoutTask?.cancel()
    replicas[pending.replicaID]?.operationDidFinish(.format(requestID: requestID))
    pending.continuation.resume(throwing: error)
  }

  private func finishPendingRouteCommand(
    _ requestID: UUID,
    with error: CodeMirrorSessionError
  ) {
    guard let pending = pendingRouteCommands.removeValue(forKey: requestID) else { return }
    pending.timeoutTask?.cancel()
    replicas[pending.replicaID]?.operationDidFinish(
      .routeCommand(requestID: requestID, command: pending.command))
    pending.continuation.resume(throwing: error)
  }

  private func removeReplicaFromPendingOperations(_ replicaID: CodeMirrorReplicaID) {
    let flushRequestIDs = Array(pendingFlushes.keys)
    for requestID in flushRequestIDs {
      guard let pending = pendingFlushes[requestID] else { continue }
      guard pending.waitingFor.contains(replicaID) else { continue }
      finishPendingFlush(requestID, with: .replicaUnavailable)
    }
    let formatRequestIDs = Array(pendingFormats.keys)
    for requestID in formatRequestIDs {
      guard let pending = pendingFormats[requestID], pending.replicaID == replicaID else {
        continue
      }
      finishPendingFormat(requestID, with: .replicaUnavailable)
    }
    let routeRequestIDs = Array(pendingRouteCommands.keys)
    for requestID in routeRequestIDs {
      guard let pending = pendingRouteCommands[requestID], pending.replicaID == replicaID else {
        continue
      }
      finishPendingRouteCommand(requestID, with: .replicaUnavailable)
    }
  }

  private func failRouteCommands(
    for replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    with error: CodeMirrorSessionError
  ) {
    let requestIDs = Array(pendingRouteCommands.keys)
    for requestID in requestIDs {
      guard let pending = pendingRouteCommands[requestID], pending.replicaID == replicaID,
        pending.loadID == loadID
      else {
        continue
      }
      finishPendingRouteCommand(requestID, with: error)
    }
  }

  private func failOperations(
    for replicaID: CodeMirrorReplicaID, with error: CodeMirrorSessionError
  ) {
    let flushRequestIDs = Array(pendingFlushes.keys)
    for requestID in flushRequestIDs {
      guard let pending = pendingFlushes[requestID], pending.waitingFor.contains(replicaID) else {
        continue
      }
      finishPendingFlush(requestID, with: error)
    }
    let formatRequestIDs = Array(pendingFormats.keys)
    for requestID in formatRequestIDs {
      guard let pending = pendingFormats[requestID], pending.replicaID == replicaID else {
        continue
      }
      finishPendingFormat(requestID, with: error)
    }
    let routeRequestIDs = Array(pendingRouteCommands.keys)
    for requestID in routeRequestIDs {
      guard let pending = pendingRouteCommands[requestID], pending.replicaID == replicaID else {
        continue
      }
      finishPendingRouteCommand(requestID, with: error)
    }
  }
}
