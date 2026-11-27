import AgentsCore
import Foundation
import NativeDocuments

package enum NativePromptAudit {
  package enum Format: Equatable, Sendable {
    case codexAgent, geminiCommand, claudeHooks, cursorHooks, commandHooks, antigravityHooks
    case openCodeJSON, openCodeJSONC
    package var isTOML: Bool { self == .codexAgent || self == .geminiCommand }
  }

  package struct Field {
    package let text: String
    package let pointer: String
    package let sourceRange: Range<Int>?
    package let managed: Bool
  }

  package struct Readback {
    package let fields: [Field]
    package let ownershipVerified: Bool
  }

  package enum Failure: Error {
    case unsupported(offset: Int?, field: String?)
  }

  package static func read(
    _ bytes: Data, format: Format, authorities: [LedgerNativeOwnedRegion]
  ) throws -> Readback {
    let limits = LedgerLimits.standard
    let document: NativeDocument
    do {
      document = try NativeDocument(
        bytes: bytes,
        format: format.isTOML
          ? .toml : format == .openCodeJSONC ? .jsonc(trailingCommas: true) : .json,
        budget: NativeDocumentBudget(
          limits: .init(
            storage: limits.resourceBytes, work: limits.encodedBytes, nodes: limits.nodes,
            depth: limits.depth, uninterruptedBytes: limits.resourceBytes)))
    } catch NativeDocumentError.invalidDocument(_, let range) {
      throw Failure.unsupported(offset: range?.lowerBound, field: nil)
    }
    let root = document.promptRoot
    guard root.isObject else { throw Failure.unsupported(offset: 0, field: nil) }

    var selected: [(node: NativePromptNode, pointer: String)] = []
    var rootKeys = Set<String>()
    func select(_ node: NativePromptNode, at pointer: String) throws {
      guard node.string != nil else {
        throw Failure.unsupported(offset: node.sourceRange?.lowerBound, field: pointer)
      }
      selected.append((node, pointer))
    }
    switch format {
    case .codexAgent, .geminiCommand:
      let key = format == .codexAgent ? "developer_instructions" : "prompt"
      if let value = root[key] { try select(value, at: "/" + key) }
      rootKeys.insert(key)
    case .openCodeJSON, .openCodeJSONC:
      for (section, key) in [("commands", "template"), ("agents", "system")] {
        guard let entries = root[section] else { continue }
        guard entries.isObject else {
          throw Failure.unsupported(offset: entries.sourceRange?.lowerBound, field: "/" + section)
        }
        rootKeys.insert(section)
        for (name, entry) in entries.fields {
          if let value = entry[key] {
            try select(value, at: "/" + section + "/" + pointerToken(name) + "/" + key)
          }
        }
      }
    case .antigravityHooks:
      break
    case .claudeHooks, .cursorHooks, .commandHooks:
      if let hooks = root["hooks"] {
        rootKeys.insert("hooks")
        guard hooks.isObject else {
          throw Failure.unsupported(offset: hooks.sourceRange?.lowerBound, field: "/hooks")
        }
        for (event, handlers) in hooks.fields {
          let path = "/hooks/" + pointerToken(event)
          guard handlers.isArray else {
            throw Failure.unsupported(offset: handlers.sourceRange?.lowerBound, field: path)
          }
          for (index, handler) in handlers.elements.enumerated() {
            let position = path + "/" + String(index)
            if format == .cursorHooks {
              try collect(handler, at: position, types: ["prompt"], select: select)
            } else if let group = handler["hooks"] {
              guard group.isArray else {
                throw Failure.unsupported(
                  offset: group.sourceRange?.lowerBound, field: position + "/hooks")
              }
              if format == .claudeHooks {
                for (child, hook) in group.elements.enumerated() {
                  try collect(
                    hook, at: position + "/hooks/" + String(child), types: ["prompt", "agent"],
                    select: select)
                }
              }
            } else {
              throw Failure.unsupported(offset: handler.sourceRange?.lowerBound, field: position)
            }
          }
        }
      }
    }
    guard !selected.isEmpty else { return .init(fields: [], ownershipVerified: true) }

    // Regional claims are meaningful for the native document generation they describe.
    var ranges: [Range<Int>] = []
    var verified = true
    for authority in authorities {
      guard case .key(let key)? = authority.path.first, rootKeys.contains(key)
      else { continue }
      do {
        let region = try NativeAuthorityComposition.region(
          authority.path, document: document, arrays: [])
        guard let readback = try document.promptNode(at: region),
          let range = readback.sourceRange
        else {
          verified = false
          continue
        }
        ranges.append(range)
      } catch {
        verified = false
      }
    }
    let fields = selected.compactMap { entry -> Field? in
      guard let value = entry.node.string else { return nil }
      let range = entry.node.sourceRange
      return Field(
        text: value, pointer: entry.pointer, sourceRange: range,
        managed: range.map { leaf in
          ranges.contains { $0.lowerBound <= leaf.lowerBound && $0.upperBound >= leaf.upperBound }
        } ?? false
      )
    }
    return .init(fields: fields, ownershipVerified: verified)
  }

  private static func pointerToken(_ value: String) -> String {
    value.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }

  private static func collect(
    _ handler: NativePromptNode, at position: String, types: Set<String>,
    select: (NativePromptNode, String) throws -> Void
  ) throws {
    guard handler.isObject, handler["hooks"] == nil else {
      throw Failure.unsupported(offset: handler.sourceRange?.lowerBound, field: position)
    }
    guard let type = handler["type"]?.string, types.contains(type) else { return }
    let pointer = position + "/prompt"
    guard let prompt = handler["prompt"] else {
      throw Failure.unsupported(offset: handler.sourceRange?.lowerBound, field: pointer)
    }
    try select(prompt, pointer)
  }
}
