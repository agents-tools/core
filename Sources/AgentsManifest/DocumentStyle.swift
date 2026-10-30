import AgentsCore
import AgentsDescription
import Foundation

extension DocumentEditor {
  func style(at range: Range<Int>) throws -> (PrintStyle, String) {
    try charge(current.admission.nodes.count)
    let bytes = current.bytes
    var endings = Set<String>()
    var cursor = 0
    while cursor < bytes.count {
      if bytes[cursor] == UInt8(ascii: "\r") {
        if cursor + 1 < bytes.count && bytes[cursor + 1] == UInt8(ascii: "\n") {
          endings.insert("\r\n")
          cursor += 1
        } else {
          endings.insert("\r")
        }
      } else if bytes[cursor] == UInt8(ascii: "\n") {
        endings.insert("\n")
      }
      cursor += 1
    }
    guard endings.count <= 1 else {
      throw fail("manifest.edit.readOnly", "conflicting newline styles", range: range)
    }
    let indentation = indentation(at: range.lowerBound)
    let candidates = current.admission.nodes.filter { node in
      [.array, .dictionary, .call].contains(node.kind)
        && node.range.lowerBound <= range.lowerBound && node.range.upperBound >= range.upperBound
    }
    var unit: String?
    var trailingComma = true
    for container in candidates.sorted(by: { $0.range.count < $1.range.count }) {
      var units = Set<String>()
      let base = self.indentation(at: container.range.lowerBound)
      let offsets =
        container.kind == .dictionary
        ? container.keys.map { $0.range.lowerBound }
        : container.kind == .array
          ? container.children.map { current.admission.nodes[$0].range.lowerBound }
          : container.arguments.map {
            $0.labelRange?.lowerBound ?? current.admission.nodes[$0.value].range.lowerBound
          }
      for offset in offsets {
        let start = lineStart(offset)
        let prefix = current.source.spelling(start..<offset)
        guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
        guard prefix.hasPrefix(base), prefix.count > base.count else {
          throw fail("manifest.edit.readOnly", "conflicting local indentation", range: range)
        }
        units.insert(String(prefix.dropFirst(base.count)))
      }
      guard units.count <= 1 else {
        throw fail("manifest.edit.readOnly", "conflicting local indentation", range: range)
      }
      if let evidence = units.first {
        unit = evidence
        break
      }
    }
    for container in candidates.sorted(by: { $0.range.count < $1.range.count })
    where container.kind == .array || container.kind == .dictionary {
      guard let last = container.children.last,
        let token = current.admission.tokens.first(where: {
          $0.range.lowerBound >= current.admission.nodes[last].range.upperBound
        })
      else { continue }
      trailingComma = token.text == ","
      break
    }
    return (
      PrintStyle(
        indent: unit ?? "  ", newline: endings.first ?? "\n", trailingComma: trailingComma),
      indentation
    )
  }

  func indentation(at offset: Int) -> String {
    String(current.source.spelling(lineStart(offset)..<offset).prefix { $0 == " " || $0 == "\t" })
  }
}
