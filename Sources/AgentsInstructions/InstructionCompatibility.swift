import AgentsCore
import Foundation

/// Existing instruction ownership semantics, usable by locked reconstruction and conversion
/// validation without discovery, target selection or filesystem mutation.
package enum InstructionCompatibility {
  package static func obsolete(_ deployment: LedgerDeployment, before: Data?) throws -> Data? {
    guard let before else { return nil }
    switch deployment.ownership {
    case .generated:
      return Instructions.hash(before) == deployment.expectedHash ? nil : before
    case .importBlock:
      let edit = try Instructions.removeBlock(from: before)
      return deployment.created && !edit.hasCustomContent ? nil : edit.bytes
    case .ownedValues:
      throw CoreError.invalidState("structured ownership requires its locked document format")
    }
  }

  package static func renderPrompt(
    _ bytes: [Data], ids: [String], append: Data?, byteLimit: Int? = nil
  ) throws -> Data {
    guard bytes.count == ids.count else { throw CoreError.invalidState("prompt input count") }
    let sections = try zip(bytes, ids).map {
      try Instructions.validateSource($0.0, id: $0.1, allowRestrictions: true)
    }
    try checkOutput(sections, notice: false, append: append, byteLimit: byteLimit)
    return try Instructions.renderChatGPT(sections: sections, customContent: append)
  }

  package static func renderSections(_ bytes: [Data], ids: [String], byteLimit: Int? = nil) throws
    -> Data
  {
    guard bytes.count == ids.count else { throw CoreError.invalidState("instruction input count") }
    let sections = try zip(bytes, ids).map {
      try Instructions.validateSource($0.0, id: $0.1, allowRestrictions: true)
    }
    try checkOutput(sections, notice: true, append: nil, byteLimit: byteLimit)
    return Data(try Instructions.render(sections).utf8)
  }

  private static func checkOutput(
    _ sections: [InstructionSection], notice: Bool, append: Data?, byteLimit: Int?
  ) throws {
    guard var remaining = byteLimit else { return }
    func charge(_ count: Int) throws {
      guard count <= remaining else {
        throw CoreError.invalidState("rendered instruction byte budget")
      }
      remaining -= count
    }
    if notice { try charge(Instructions.notice.utf8.count + 2) }
    for (index, section) in sections.enumerated() {
      if index > 0 { try charge(2) }
      try charge(section.content.utf8.count)
    }
    try charge(1)
    if let append, !append.isEmpty {
      try charge(1)
      try charge(append.count)
    }
  }
}
