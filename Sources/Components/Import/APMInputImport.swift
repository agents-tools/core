import AgentsCore
import Foundation

extension SourceImport {
  /// Manifest intent and a caller-selected lock retain distinct provenance. Matching requires
  /// unambiguous repository, resource root and requested-ref evidence; no ref is resolved here.
  package static func previewAPM(
    manifest: SourceImportInput, lock: SourceImportInput?, limits: SourceImportLimits = .init()
  ) throws -> SourceImportProposal {
    guard manifest.profile == .apmManifest, lock == nil || lock?.profile == .apmLock else {
      var result = SourceImportProposal(profile: .apmManifest)
      result.diagnostics.append(
        .init(
          code: .invalidInput, location: .init(document: manifest.document, pointer: ""),
          message: "APM composition requires an explicit manifest and optional APM lock profile."))
      return result
    }
    var result = try preview(manifest, limits: limits)
    guard let lock else { return result }
    let locked = try preview(lock, limits: limits)
    result.diagnostics += locked.diagnostics
    result.bindings += locked.bindings
    result.deployments += locked.deployments
    result.selections += locked.selections
    // Keep every independent locked source and preservation plan, including transitives.
    result.sources += locked.sources
    result.resources += locked.resources
    result.components += locked.components
    for index in result.sources.indices where index < result.sources.count - locked.sources.count {
      let source = result.sources[index]
      guard let declaration = source.declaration, declaration.kind == .git,
        let identity = try? declaration.transportIdentity()
      else { continue }
      let matches = locked.sources.filter {
        guard let candidate = $0.declaration, candidate.kind == .git,
          (try? candidate.transportIdentity()) == identity,
          (candidate.path ?? ".") == (declaration.path ?? ".")
        else { return false }
        return true
      }
      guard matches.count == 1, let matched = matches.first else {
        if !matches.isEmpty {
          result.diagnostics.append(
            .init(
              code: .ambiguousSource, location: source.origin,
              message: "Multiple locked entries match this manifest source; no pin is selected."))
        }
        continue
      }
      if let requested = source.requestedRef,
        ![matched.resolvedRef, matched.requestedRef, matched.pin.commit].contains(requested)
      {
        result.diagnostics.append(
          .init(
            code: .ambiguousSource, location: source.origin,
            message: "Locked ref evidence does not match manifest intent; no pin is selected."))
        continue
      }
      guard let commit = matched.pin.commit else { continue }
      var exact = declaration
      exact.requirement = .revision(commit)
      result.sources[index] = .init(
        alias: source.alias, origin: source.origin, declaration: exact, pin: matched.pin,
        requestedRef: source.requestedRef, producerPath: source.producerPath,
        producerIdentity: source.producerIdentity, resolvedRef: matched.resolvedRef,
        developmentOnly: source.developmentOnly)
      result.diagnostics.removeAll {
        $0.code == .incompletePin && $0.location == source.origin
      }
    }
    return result
  }
}
