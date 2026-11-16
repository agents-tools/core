import AgentsCore
import Foundation
import NativeDocuments

/// Opaque native preservation is confined to a verified native container and one recipient.
/// Decomposition consumes G's typed children, not a second parser hidden in a renderer.
enum NativePluginLayoutV1 {
  static func render(_ lowering: LockedLowering, _ input: ComponentRenderInput) throws
    -> [ReplayedArtifact]
  {
    _ = try input.checkedNative([:])
    guard input.fields["mode"]?.text == "native" else {
      throw input.issue(
        ["mode"], .integrationRequired,
        "decomposed plugins require G's typed child declarations linked/frozen with their source provenance"
      )
    }
    guard input.record.recipients == [input.request.surface.agent] else {
      throw input.issue(
        ["recipients"], .invalid,
        "opaque native plugin preservation requires exactly one native recipient")
    }
    guard input.fields["select"] == nil, input.fields["exclude"]?.array?.isEmpty ?? true else {
      throw input.issue(
        ["select", "exclude"], .invalid,
        "native container preservation cannot filter child components")
    }
    let route: NativeComponentRoute
    let manifest: String
    switch input.request.surface {
    case .claudeCode:
      route = .claudeSkillPlugin
      manifest = ".claude-plugin/plugin.json"
    case .geminiCLI where input.request.scope == .user:
      route = .geminiExtension
      manifest = "gemini-extension.json"
    case .cursorEditor where input.request.scope == .user:
      route = .cursorLocalPlugin
      manifest = ".cursor-plugin/plugin.json"
    default:
      throw input.issue(
        ["scope"], .unverified,
        "native container registration/loading is not established for this surface/scope")
    }
    let name = try input.filename()
    guard input.record.resources.count == 1, let id = input.record.resources.first,
      let record = input.ledger.resources[id], let root = input.resources[id],
      let entry = record.entries.first(where: { $0.path == manifest }), entry.kind == .file,
      let size = entry.byteCount, size <= input.limits.resourceBytes
    else {
      throw input.issue(
        ["path"], .invalid, "frozen native plugin requires its exact container manifest")
    }
    if input.request.surface == .geminiCLI,
      record.entries.contains(where: {
        [".gemini-extension-install.json", ".env"].contains($0.path)
      })
    {
      throw input.issue(
        ["path"], .invalid, "runtime-local extension metadata/settings cannot be vendor resources")
    }
    try input.budget.allocate(size, stage: "native plugin manifest")
    try input.budget.step(size)
    let bytes = try Data(contentsOf: PathSafety.resolvedChild(base: root, subpath: manifest))
    let document = try NativeDocument(bytes: bytes, format: .json, budget: input.budget)
    guard bytes.count == size,
      case .object(let manifestFields) = try document.read(.init(keys: []))?.value
    else {
      throw input.issue(["path"], .invalid, "native plugin manifest is not an exact JSON object")
    }
    for (key, value) in manifestFields {
      let metadata =
        input.request.surface == .geminiCLI
        ? ["name", "version"] : ["name", "version", "description"]
      guard metadata.contains(key) else {
        throw input.issue(
          ["manifest", key], .unverified,
          "this native manifest field's registration/path semantics are not captured by the fixed profile"
        )
      }
      guard case .string(let text) = value, !text.utf8.contains(0) else {
        throw input.issue(["manifest", key], .invalid, "native metadata must be a string")
      }
    }
    guard try document.read(.init(keys: ["name"]))?.value == .string(name) else {
      throw input.issue(
        ["name"], .invalid, "native manifest name does not match the frozen component")
    }
    if input.request.surface == .cursorEditor, case .string(let version) = manifestFields["version"]
    {
      do {
        guard try SourceRequirement.exact(version).canonicalized() == .exact(version) else {
          throw CoreError.invalidState("invalid native version")
        }
      } catch {
        throw input.issue(
          ["manifest", "version"], .invalid, "native plugin version must be canonical SemVer")
      }
    }
    if input.request.surface == .geminiCLI {
      guard name.range(of: #"^[a-zA-Z0-9-]+$"#, options: .regularExpression) != nil else {
        throw input.issue(
          ["name"], .invalid, "native extension name requires alphanumeric characters and hyphens")
      }
      guard case .string(let version) = manifestFields["version"], !version.isEmpty else {
        throw input.issue(
          ["manifest", "version"], .invalid, "native extension requires a version string")
      }
    }
    let envelope = input.envelope(
      route: route, path: name, selection: "nativePlugin",
      value: .init(object: ["resource": .init(id), "manifest": .init(manifest)]))
    return try input.emitted(lowering, envelope)
      + [.init(name: lowering.id + "/bundle", kind: .tree, tree: root)]
  }
}
