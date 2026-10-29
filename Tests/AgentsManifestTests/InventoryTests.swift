import AgentsCore
import AgentsDescription
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import AgentsManifest

@Suite("Manifest construction inventory")
struct InventoryTests {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  @Test func contractSignaturesDefaultsAndLiteralProtocolsMatchRegistration() throws {
    let contract = try String(
      contentsOf: root.appendingPathComponent("Documentation/Proposals/AgentsManifest.md"),
      encoding: .utf8)
    let vocabulary = String(contract.prefix(upTo: contract.range(of: "### Targeting")!.lowerBound))
    let blocks = vocabulary.components(separatedBy: "```swift\n").dropFirst().compactMap {
      $0.components(separatedBy: "```").first
    }.filter { $0.hasPrefix("public ") }
    var signatures: [String] = []
    var namedTypes = Set(["String", "Int", "Bool"])
    var literalTypes: [String: Set<String>] = [:]
    let protocolKinds = [
      "ExpressibleByStringLiteral": "string", "ExpressibleByIntegerLiteral": "integer",
      "ExpressibleByBooleanLiteral": "boolean", "ExpressibleByNilLiteral": "nil",
      "ExpressibleByArrayLiteral": "array", "ExpressibleByDictionaryLiteral": "dictionary",
    ]
    for block in blocks {
      let tree = Parser.parse(source: block)
      let source = SourceText(Array(block.utf8), identity: DocumentIdentity("interface"))
      _ = try SyntaxValidation.guardTree(Syntax(tree), source: source)
      var pending: [(Syntax, String)] = [(Syntax(tree), "")]
      while let (node, owner) = pending.popLast() {
        var name = owner
        if let declaration = node.as(StructDeclSyntax.self) {
          name = declaration.name.text
          namedTypes.insert(name)
          for inherited in declaration.inheritanceClause?.inheritedTypes ?? [] {
            if let kind = protocolKinds[inherited.type.trimmedDescription] {
              literalTypes[name, default: []].insert(kind)
            }
          }
        } else if let declaration = node.as(EnumDeclSyntax.self) {
          name = declaration.name.text
          namedTypes.insert(name)
          for inherited in declaration.inheritanceClause?.inheritedTypes ?? [] {
            if let kind = protocolKinds[inherited.type.trimmedDescription] {
              literalTypes[name, default: []].insert(kind)
            }
          }
        } else if let declaration = node.as(TypeAliasDeclSyntax.self) {
          namedTypes.insert(declaration.name.text)
        } else if let method = node.as(FunctionDeclSyntax.self), name != "Version" {
          let parameters = method.signature.parameterClause.parameters.map { parameter in
            let defaultValue = parameter.defaultValue?.value.trimmedDescription ?? "required"
            return parameter.firstName.text + ":"
              + parameter.type.trimmedDescription.replacingOccurrences(of: " ", with: "") + "="
              + defaultValue
          }.joined(separator: ",")
          signatures.append(name + "." + method.name.text + "(" + parameters + ")")
        } else if let initializer = node.as(InitializerDeclSyntax.self), name == "Agents" {
          let parameters = initializer.signature.parameterClause.parameters.map { parameter in
            parameter.firstName.text + ":"
              + parameter.type.trimmedDescription.replacingOccurrences(of: " ", with: "") + "="
              + (parameter.defaultValue?.value.trimmedDescription ?? "required")
          }.joined(separator: ",")
          signatures.append("Agents.Agents(" + parameters + ")")
        }
        for child in node.children(viewMode: .sourceAccurate) { pending.append((child, name)) }
      }
    }
    #expect(namedTypes == Vocabulary.typeNames)
    #expect(literalTypes == Vocabulary.literalTypes)
    let inventory =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("Scripts/ManifestVocabulary.json")))
      as! [String: Any]
    let factories = inventory["factories"] as! [[String: Any]]
    let registered = factories.filter { $0["property"] == nil }.map { method in
      let parameters = (method["parameters"] as! [[String: String]]).map { parameter in
        parameter["label"]! + ":" + parameter["type"]!.replacingOccurrences(of: " ", with: "") + "="
          + (parameter["default"] ?? "required")
      }.joined(separator: ",")
      return (method["type"] as! String) + "." + (method["name"] as! String) + "(" + parameters
        + ")"
    }
    #expect(Set(signatures.filter { !$0.hasPrefix(".upToNext") }) == Set(registered))
    let enumCount = (inventory["enums"] as! [String: [[String: Any]]]).values.reduce(0) {
      $0 + $1.count
    }
    #expect(Vocabulary.signatures.count == factories.count + enumCount + 2)
    #expect(Vocabulary.signatures.filter { $0.type == "VersionRange" }.count == 2)
    #expect(
      Vocabulary.signatures.filter { $0.type == "SkillSelection" && $0.member == "all" }.count == 1)
  }

  @Test func allContractSwiftBlocksPassTheRealParser() throws {
    let contract = try String(
      contentsOf: root.appendingPathComponent("Documentation/Proposals/AgentsManifest.md"),
      encoding: .utf8)
    let directory = try temporaryManifestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (index, tail) in contract.components(separatedBy: "```swift\n").dropFirst().enumerated() {
      let block = tail.components(separatedBy: "```")[0]
      let file = directory.appendingPathComponent(
        "block\(index)." + (block.hasPrefix("public ") ? "swiftinterface" : "swift"))
      try Data(block.utf8).write(to: file)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["swiftc", "-frontend", "-parse", file.path]
      let errors = Pipe()
      process.standardError = errors
      try process.run()
      let errorData = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      #expect(
        process.terminationReason == .exit && process.terminationStatus == 0,
        "block \(index): \(String(decoding: errorData, as: UTF8.self))")
    }
  }
}
