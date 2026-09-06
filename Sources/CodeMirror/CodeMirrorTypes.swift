import Foundation

public struct CodeMirrorSessionID: Hashable, Sendable, Codable {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

public struct CodeMirrorReplicaID: Hashable, Sendable, Codable {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

public struct CodeMirrorRevision: Hashable, Sendable, Codable, Comparable {
  public let rawValue: UInt64

  public init(_ rawValue: UInt64 = 0) {
    self.rawValue = rawValue
  }

  public static let zero = CodeMirrorRevision()

  public static func < (lhs: CodeMirrorRevision, rhs: CodeMirrorRevision) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public enum CodeMirrorLanguage: String, CaseIterable, Hashable, Sendable, Codable {
  case text
  case json
  case xml
  case graphql
}

public enum CodeMirrorColorScheme: String, Hashable, Sendable, Codable {
  case system
  case light
  case dark
}

public struct CodeMirrorAppearance: Equatable, Sendable, Codable {
  public var colorScheme: CodeMirrorColorScheme
  public var increaseContrast: Bool
  public var reduceMotion: Bool
  public var reduceTransparency: Bool

  public init(
    colorScheme: CodeMirrorColorScheme = .system,
    increaseContrast: Bool = false,
    reduceMotion: Bool = false,
    reduceTransparency: Bool = false
  ) {
    self.colorScheme = colorScheme
    self.increaseContrast = increaseContrast
    self.reduceMotion = reduceMotion
    self.reduceTransparency = reduceTransparency
  }
}

public struct CodeMirrorConfiguration: Equatable, Sendable, Codable {
  public var language: CodeMirrorLanguage
  public var isReadOnly: Bool
  public var wrapsLines: Bool
  public var showsLineNumbers: Bool
  public var commandTimeoutMilliseconds: Int
  public var maximumPendingTransactions: Int
  public var appearance: CodeMirrorAppearance
  public var editorName: String?

  public init(
    language: CodeMirrorLanguage = .text,
    isReadOnly: Bool = false,
    wrapsLines: Bool = false,
    showsLineNumbers: Bool = true,
    commandTimeoutMilliseconds: Int = 2_000,
    maximumPendingTransactions: Int = 64,
    appearance: CodeMirrorAppearance = CodeMirrorAppearance(),
    editorName: String? = nil
  ) {
    self.language = language
    self.isReadOnly = isReadOnly
    self.wrapsLines = wrapsLines
    self.showsLineNumbers = showsLineNumbers
    self.commandTimeoutMilliseconds = commandTimeoutMilliseconds
    self.maximumPendingTransactions = maximumPendingTransactions
    self.appearance = appearance
    self.editorName = editorName
  }

  internal var normalized: CodeMirrorConfiguration {
    var result = self
    result.commandTimeoutMilliseconds = max(1, commandTimeoutMilliseconds)
    result.maximumPendingTransactions = max(1, maximumPendingTransactions)
    return result
  }

  internal func withAppearance(_ appearance: CodeMirrorAppearance) -> CodeMirrorConfiguration {
    var result = self
    result.appearance = appearance
    return result
  }
}

public struct CodeMirrorSelection: Equatable, Hashable, Sendable, Codable {
  public var anchorUTF16: Int
  public var headUTF16: Int

  public init(anchorUTF16: Int, headUTF16: Int) {
    self.anchorUTF16 = anchorUTF16
    self.headUTF16 = headUTF16
  }
}

public struct CodeMirrorChange: Equatable, Hashable, Sendable, Codable {
  public var rangeUTF16: Range<Int>
  public var insertedText: String
  public var removedText: String

  public init(
    rangeUTF16: Range<Int>,
    insertedText: String,
    removedText: String = ""
  ) {
    self.rangeUTF16 = rangeUTF16
    self.insertedText = insertedText
    self.removedText = removedText
  }
}

public enum CodeMirrorCompositionPhase: Equatable, Hashable, Sendable, Codable {
  case none
  case began(UUID)
  case updated(UUID)
  case ended(UUID)
}

public struct CodeMirrorTransaction: Equatable, Hashable, Sendable, Codable {
  public let sessionID: CodeMirrorSessionID
  public let replicaID: CodeMirrorReplicaID
  public let loadID: UUID
  public let baseRevision: CodeMirrorRevision
  public let revision: CodeMirrorRevision
  public let changes: [CodeMirrorChange]
  public let selectionBefore: CodeMirrorSelection
  public let selectionAfter: CodeMirrorSelection
  public let composition: CodeMirrorCompositionPhase

  public init(
    sessionID: CodeMirrorSessionID,
    replicaID: CodeMirrorReplicaID,
    loadID: UUID,
    baseRevision: CodeMirrorRevision,
    revision: CodeMirrorRevision,
    changes: [CodeMirrorChange],
    selectionBefore: CodeMirrorSelection,
    selectionAfter: CodeMirrorSelection,
    composition: CodeMirrorCompositionPhase = .none
  ) {
    self.sessionID = sessionID
    self.replicaID = replicaID
    self.loadID = loadID
    self.baseRevision = baseRevision
    self.revision = revision
    self.changes = changes
    self.selectionBefore = selectionBefore
    self.selectionAfter = selectionAfter
    self.composition = composition
  }
}

public struct CodeMirrorSnapshot: Equatable, Sendable, Codable {
  public let sessionID: CodeMirrorSessionID
  public let revision: CodeMirrorRevision
  public let text: String
  public let selections: [CodeMirrorReplicaID: CodeMirrorSelection]

  public init(
    sessionID: CodeMirrorSessionID,
    revision: CodeMirrorRevision,
    text: String,
    selections: [CodeMirrorReplicaID: CodeMirrorSelection]
  ) {
    self.sessionID = sessionID
    self.revision = revision
    self.text = text
    self.selections = selections
  }
}

public enum CodeMirrorCommand: String, Equatable, Hashable, Sendable, Codable {
  case undo
  case redo
}

public enum CodeMirrorSessionError: Error, Equatable, Sendable, Codable {
  case invalidated
  case replicaUnavailable
  case staleRevision(expected: CodeMirrorRevision, actual: CodeMirrorRevision)
  case malformedChange
  case transportFailure
  case timeout
  case compositionInProgress
  case unsupportedCommand
  case formatUnavailable
  case conflictingEdit
}

extension CodeMirrorSessionError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidated:
      "The editor session has been invalidated."
    case .replicaUnavailable:
      "The editor replica is unavailable."
    case .staleRevision:
      "The editor revision is stale."
    case .malformedChange:
      "The editor change is malformed."
    case .transportFailure:
      "The editor transport failed."
    case .timeout:
      "The editor operation timed out."
    case .compositionInProgress:
      "Text composition is still in progress."
    case .unsupportedCommand:
      "The editor command is unsupported."
    case .formatUnavailable:
      "Formatting is unavailable for this document size or language."
    case .conflictingEdit:
      "The editor has a conflicting live edit."
    }
  }
}

public enum CodeMirrorEventDisposition: Sendable {
  case accept
  case replace(authoritativeText: String)
  case invalidate
}

public enum CodeMirrorEvent: Sendable {
  case ready(replicaID: CodeMirrorReplicaID, loadID: UUID)
  case transaction(CodeMirrorTransaction, snapshot: CodeMirrorSnapshot)
  case selection(
    replicaID: CodeMirrorReplicaID, revision: CodeMirrorRevision, selection: CodeMirrorSelection)
  case command(replicaID: CodeMirrorReplicaID, command: CodeMirrorCommand)
  case failure(replicaID: CodeMirrorReplicaID?, error: CodeMirrorSessionError)
}
