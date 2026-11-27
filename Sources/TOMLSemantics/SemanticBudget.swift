import Foundation

/// One serial operation's cumulative admission. Units bound logical storage/work, not RSS.
package final class SemanticBudget {
  package struct Limits {
    package var storage: Int
    package var work: Int
    package var nodes: Int
    package var depth: Int
    package var uninterruptedBytes: Int

    package init(storage: Int, work: Int, nodes: Int, depth: Int, uninterruptedBytes: Int) {
      self.storage = storage
      self.work = work
      self.nodes = nodes
      self.depth = depth
      self.uninterruptedBytes = uninterruptedBytes
    }
  }

  package enum Failure: Error {
    case exceeded(String)
    case cancelled
  }
  private var storage: Int
  private var work: Int
  private var nodes: Int
  package let limits: Limits
  private let cancellation: () -> Bool

  package init(limits: Limits, cancellation: @escaping () -> Bool = { false }) {
    self.limits = limits
    self.storage = limits.storage
    self.work = limits.work
    self.nodes = limits.nodes
    self.cancellation = cancellation
  }

  package func check() throws {
    if cancellation() || Task<Never, Never>.isCancelled { throw Failure.cancelled }
  }

  package func step(_ amount: Int = 1) throws {
    try check()
    guard amount >= 0, amount <= work else { throw Failure.exceeded("work") }
    work -= amount
  }

  package func allocate(_ amount: Int, stage: String) throws {
    try check()
    guard amount >= 0, amount <= storage else { throw Failure.exceeded(stage) }
    storage -= amount
  }

  package func enter(_ depth: Int) throws {
    try check()
    guard depth <= limits.depth else { throw Failure.exceeded("depth") }
  }

  package func node(depth: Int) throws {
    try enter(depth)
    guard nodes > 0 else { throw Failure.exceeded("nodes") }
    nodes -= 1
    try allocate(1, stage: "node")
  }

  package func equal(_ a: String, _ b: String) throws -> Bool {
    guard a.utf8.count == b.utf8.count else {
      try step()
      return false
    }
    for (x, y) in zip(a.utf8, b.utf8) {
      try step()
      if x != y { return false }
    }
    return true
  }

  /// The whole admitted envelope bounds every CST lexical run, including skipped trivia.
  package func admitCST(bytes: Int) throws {
    try check()
    guard bytes <= limits.uninterruptedBytes else {
      throw Failure.exceeded("CST uninterrupted input")
    }
    try step(bytes)
    guard bytes <= (Int.max - 1) / 4 else { throw Failure.exceeded("CST nodes") }
    let admittedNodes = bytes * 4 + 1
    guard admittedNodes <= nodes else { throw Failure.exceeded("CST nodes") }
    nodes -= admittedNodes
    try allocate(admittedNodes, stage: "CST nodes")
    try allocate(bytes, stage: "CST input")
  }
}
