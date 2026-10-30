import Foundation

/// A language 1.0 declaration document whose root `Agents(...)` call receives `arguments`
/// verbatim, for fixtures that need declaration bytes without the declaration model.
package func manifestText(_ arguments: String = "") -> Data {
  let call = arguments.isEmpty ? "Agents()" : "Agents(\n  \(arguments)\n)"
  let header = "// agents-tools-version: 1.0\nimport AgentsDescription\n\n"
  return Data((header + "let agents = \(call)\n").utf8)
}
