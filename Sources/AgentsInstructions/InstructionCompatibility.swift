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

  package static func renderPrompt(_ bytes: [Data], ids: [String], append: Data?) throws -> Data {
    guard bytes.count == ids.count else { throw CoreError.invalidState("prompt input count") }
    let sections = try zip(bytes, ids).map {
      try Instructions.validateSource($0.0, id: $0.1, allowRestrictions: true)
    }
    return try Instructions.renderChatGPT(sections: sections, customContent: append)
  }

  package static func renderSections(_ bytes: [Data], ids: [String]) throws -> Data {
    guard bytes.count == ids.count else { throw CoreError.invalidState("instruction input count") }
    let sections = try zip(bytes, ids).map {
      try Instructions.validateSource($0.0, id: $0.1, allowRestrictions: true)
    }
    return Data(try Instructions.render(sections).utf8)
  }
}
