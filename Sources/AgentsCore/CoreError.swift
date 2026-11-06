import Foundation

public enum CoreError: Error, CustomStringConvertible, Equatable {
  case invalidSource(String)
  case unsafePath(String)
  case unsupported(String)
  case notFound(String)
  case invalidSkill(String)
  case invalidState(String)
  case commandFailed(String)
  /// Recovery completed; retry the operation against the recovered state.
  case transactionRecovered(String)
  /// Inspection found an interrupted transaction; a command that changes the scope recovers it.
  case recoveryPending(String)
  /// The scope has lock or watch state but no declaration at the given path.
  case missingDeclaration(String)

  public var description: String {
    switch self {
    case .invalidSource(let message):
      return "Invalid source: \(message)"
    case .unsafePath(let message):
      return "Unsafe path: \(message)"
    case .unsupported(let message):
      return "Unsupported: \(message)"
    case .notFound(let message):
      return "Not found: \(message)"
    case .invalidSkill(let message):
      return "Invalid skill: \(message)"
    case .invalidState(let message):
      return "Invalid state: \(message)"
    case .transactionRecovered(let path):
      return "Recovered interrupted transaction at \(path); retry the command"
    case .recoveryPending(let message):
      return message
    case .missingDeclaration(let path):
      return
        "Missing declaration at \(path): the scope has lock or watch state; restore the file "
        + "from version control, or remove the scope's state files to start again"
    case .commandFailed(let message):
      return "Command failed: \(message)"
    }
  }
}
