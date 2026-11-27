import AgentsCore

/// Source references are roles in admitted declaration IR, not matching strings in YAML/native data.
enum SourceReferenceEdits {
  static func replacing(_ alias: String, with replacement: String, in root: DeclarationValue)
    -> [IREdit]
  {
    var edits: [IREdit] = []
    func visit(_ value: DeclarationValue, at pointer: String) {
      guard let record = value.record else { return }
      func reference(_ field: String) {
        if record[field]?.string == alias {
          edits.append(.set(pointer + "/" + field, .string(replacement)))
        }
      }
      func child(_ field: String) {
        if let value = record[field] { visit(value, at: pointer + "/" + field) }
      }
      func children(_ field: String) {
        for (index, value) in (record[field]?.elements ?? []).enumerated() {
          visit(value, at: pointer + "/" + field + "/" + String(index))
        }
      }
      switch record.kind {
      case "declaration":
        children("components")
        children("groups")
        children("uses")
        for (index, value) in (record["watch"]?.elements ?? []).enumerated()
        where value.string == alias {
          edits.append(.set("/watch/" + String(index), .string(replacement)))
        }
      case "group":
        children("components")
        children("uses")
      case "instructions":
        children("sections")
        children("chatGPT")
      case "prompt": children("sections")
      case "mcpServer": child("transport")
      case "hook", "lspServer": child("run")
      case "command", "subagent": child("prompt")
      case "skills", "plugin", "section", "exported", "path", "file": reference("source")
      case "executable", "stdio":
        reference("executableSource")
        child("workingDirectory")
      default: break
      }
    }
    visit(root, at: "")
    return edits
  }
}
