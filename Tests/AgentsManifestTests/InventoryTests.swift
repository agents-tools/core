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
    let inventory = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("Scripts/ManifestVocabulary.json")))
        as? [String: Any])
    let aliases = try #require(inventory["aliases"] as? [String: String])
    let contract = try String(
      contentsOf: root.appendingPathComponent("Documentation/Proposals/AgentsManifest.md"),
      encoding: .utf8)
    let vocabulary = String(contract.prefix(upTo: contract.range(of: "### Targeting")!.lowerBound))
    let blocks = vocabulary.components(separatedBy: "```swift\n").dropFirst().compactMap {
      $0.components(separatedBy: "```").first
    }.filter { $0.hasPrefix("public ") }
    var signatures: [String] = []
    var namedTypes = Set(["String", "Int", "Bool"])
    var literalTypes: [String: Set<LiteralKind>] = [:]
    let protocolKinds: [String: LiteralKind] = [
      "ExpressibleByStringLiteral": .string, "ExpressibleByIntegerLiteral": .integer,
      "ExpressibleByBooleanLiteral": .boolean, "ExpressibleByNilLiteral": .nilLiteral,
      "ExpressibleByArrayLiteral": .array, "ExpressibleByDictionaryLiteral": .dictionary,
    ]
    func typeSpelling(_ raw: String) -> String {
      var value = raw
      for (alias, type) in aliases {
        value = value.replacingOccurrences(of: alias, with: type)
      }
      return value.replacingOccurrences(of: "Range<Version>", with: "VersionRange")
        .filter { !$0.isWhitespace }
    }
    func signature(
      _ owner: String, _ member: String, _ parameters: [(String, String, String?)], callable: Bool
    ) -> String {
      owner + "." + member + "("
        + parameters.map {
          $0.0 + ":" + typeSpelling($0.1) + "=" + ($0.2?.filter { !$0.isWhitespace } ?? "required")
        }.joined(separator: ",") + ")" + (callable ? " call" : " member")
    }
    for block in blocks {
      let tree = Parser.parse(source: block)
      let source = SourceText(Array(block.utf8), identity: DocumentIdentity("interface"))
      _ = try SyntaxValidation.guardTree(Syntax(tree), source: source)
      var pending: [(Syntax, String)] = [(Syntax(tree), "")]
      while let (node, owner) = pending.popLast() {
        var name = owner
        let inheritance: InheritanceClauseSyntax?
        if let declaration = node.as(StructDeclSyntax.self) {
          name = declaration.name.text
          namedTypes.insert(name)
          inheritance = declaration.inheritanceClause
        } else if let declaration = node.as(EnumDeclSyntax.self) {
          name = declaration.name.text
          namedTypes.insert(name)
          inheritance = declaration.inheritanceClause
        } else {
          inheritance = nil
        }
        for inherited in inheritance?.inheritedTypes ?? [] {
          if let kind = protocolKinds[inherited.type.trimmedDescription] {
            literalTypes[name, default: []].insert(kind)
          }
        }
        if let declaration = node.as(ExtensionDeclSyntax.self),
          declaration.extendedType.trimmedDescription == "Range"
        {
          name = "VersionRange"
        } else if let declaration = node.as(TypeAliasDeclSyntax.self) {
          namedTypes.insert(declaration.name.text)
        } else if let method = node.as(FunctionDeclSyntax.self), name != "Version" {
          let parameters = method.signature.parameterClause.parameters.map {
            (
              $0.firstName.text, $0.type.trimmedDescription,
              $0.defaultValue?.value.trimmedDescription
            )
          }
          signatures.append(signature(name, method.name.text, parameters, callable: true))
        } else if let initializer = node.as(InitializerDeclSyntax.self), name == "Agents" {
          let parameters = initializer.signature.parameterClause.parameters.map {
            (
              $0.firstName.text, $0.type.trimmedDescription,
              $0.defaultValue?.value.trimmedDescription
            )
          }
          signatures.append(signature(name, "Agents", parameters, callable: true))
        } else if let declaration = node.as(EnumCaseDeclSyntax.self) {
          for element in declaration.elements {
            let parameters = (element.parameterClause?.parameters ?? []).map {
              (
                $0.firstName?.text ?? "_", $0.type.trimmedDescription,
                $0.defaultValue?.value.trimmedDescription
              )
            }
            signatures.append(
              signature(name, element.name.text, parameters, callable: !parameters.isEmpty))
          }
        } else if let declaration = node.as(VariableDeclSyntax.self),
          declaration.modifiers.contains(where: { $0.name.text == "static" })
        {
          for binding in declaration.bindings {
            let member = try #require(
              binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text)
            signatures.append(signature(name, member, [], callable: false))
          }
        }
        for child in node.children(viewMode: .sourceAccurate) { pending.append((child, name)) }
      }
    }
    func registeredType(_ type: ConstructionType) -> String {
      switch type {
      case .untyped: return "untyped"
      case .named(let name): return name
      case .array(let element): return "[" + registeredType(element) + "]"
      case .dictionary(let element): return "[String:" + registeredType(element) + "]"
      case .optional(let element): return registeredType(element) + "?"
      }
    }
    let registered = Vocabulary.signatures.map { value in
      signature(
        value.type, value.member,
        value.parameters.map {
          ($0.label, registeredType($0.type), $0.defaultValue.map { CanonicalPrinter().render($0) })
        }, callable: value.callable)
    }
    #expect(namedTypes == Vocabulary.typeNames)
    #expect(literalTypes == Vocabulary.literalTypes)
    #expect(signatures.sorted() == registered.sorted())
    #expect(Set(Vocabulary.scalarValues["Agent"]!.values) == Set(AgentID.allCases.map(\.rawValue)))
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
