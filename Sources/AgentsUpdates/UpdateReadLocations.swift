import AgentsCore
import AgentsInstructions
import Components
import Foundation

extension UpdateOperations {
  /// Only durable inputs are exposed; replay workspaces and borrowed source URLs stay private.
  static func readLocations(
    declarations: [Declaration], ledgers: [ResolvedLedger], store: StateStore
  ) throws -> [URL] {
    var paths = [store.declarationURL, store.resolvedURL, store.watchURL]
    let scopeRoot = store.scope == .user ? store.directory : store.environment.projectDirectory
    for declaration in declarations {
      for source in declaration.sources.values where source.kind == .local {
        paths.append(source.localURL(environment: source.environment?.runtime ?? store.environment))
      }
      func resourceRoot(_ alias: String?) throws -> URL? {
        guard let alias, alias != "." else { return scopeRoot }
        guard let source = declaration.sources[alias], source.kind == .local else { return nil }
        return try PathSafety.resolvedChild(
          base: source.localURL(environment: store.environment), subpath: source.path ?? ".")
      }
      func collect(_ components: [ComponentDeclaration]) throws {
        for component in components {
          for resource in component.resources {
            if let root = try resourceRoot(resource.source) {
              paths.append(try PathSafety.resolvedChild(base: root, subpath: resource.path))
            }
          }
          if case .skills(let alias, let selection) = component, let root = try resourceRoot(alias)
          {
            // Discovery reads the root even when it finds no selected members.
            paths.append(try PathSafety.resolvedChild(base: root, subpath: selection.path ?? "."))
          }
          guard case .instructions(let instructions) = component else { continue }
          let sections =
            instructions.sectionReferences
            + instructions.prompts.flatMap { $0.prompt.sectionReferences }
          let ownNames = sections.filter { $0.source == nil || $0.source == "." }.map(\.name)
          if store.scope == .project {
            paths += InstructionOperations.ownReadLocations(
              names: ownNames, environment: store.environment)
          }
          let appendRoot =
            store.scope == .user
            ? store.environment.homeDirectory : store.environment.projectDirectory
          for prompt in instructions.prompts {
            if let appendix = prompt.prompt.append {
              paths.append(try PathSafety.resolvedChild(base: appendRoot, subpath: appendix))
            }
          }
        }
      }
      try collect(declaration.components)
      for group in declaration.groups { try collect(group.components) }
    }
    for ledger in ledgers {
      func localRoot(_ id: String) throws -> URL? {
        guard let source = ledger.sources[id], source.kind == .local else { return nil }
        if let location = source.location { return try location.resolve(roots: store.ledgerRoots) }
        if let container = source.container { return try localRoot(container) }
        return nil
      }
      let explicitSources = Set(ledger.sourceUses.map(\.source))
      for (id, source) in ledger.sources {
        if let location = source.location {
          let root = try location.resolve(roots: store.ledgerRoots)
          // The linker's implicit live snapshot supplies provenance, not a whole-tree read.
          // Explicit local declarations above retain their independent whole-tree interests.
          let implicit =
            source.kind == .local && source.revision == "live"
            && source.container == nil
            && root.resolvingSymlinksInPath().path == scopeRoot.resolvingSymlinksInPath().path
          if !implicit || explicitSources.contains(id) { paths.append(root) }
        }
      }
      for occurrence in ledger.occurrences {
        if let root = try localRoot(occurrence.declaringSource) {
          paths.append(try PathSafety.resolvedChild(base: root, subpath: occurrence.manifestPath))
        }
        if let plugin = occurrence.pluginExpansion, let root = try localRoot(plugin.source) {
          paths.append(try PathSafety.resolvedChild(base: root, subpath: plugin.containerRoot))
          paths.append(try PathSafety.resolvedChild(base: root, subpath: plugin.document))
        }
      }
      for group in ledger.groups {
        if let root = try localRoot(group.source) {
          let directory = try PathSafety.resolvedChild(base: root, subpath: group.root)
          paths.append(
            directory.appendingPathComponent(
              directory.lastPathComponent == ".agent" ? "agents.yaml" : ".agent/agents.yaml"))
        }
      }
      for component in ledger.components.values {
        if component.kind == DeclaredComponentKind.skills.rawValue,
          let root = try localRoot(component.source)
        {
          paths.append(
            try PathSafety.resolvedChild(
              base: root, subpath: component.containerRoot ?? component.root))
        }
        if let value = component.payload.object?["localAppend"] {
          paths.append(try LedgerLocation(ledgerValue: value).resolve(roots: store.ledgerRoots))
        }
      }
      for deployment in ledger.deployments {
        paths.append(try deployment.target.resolve(roots: store.ledgerRoots))
      }
      for (id, resource) in ledger.resources {
        paths.append(try ArtifactAggregation.resourceDestination(id, ledger: ledger, store: store))
        if let root = try localRoot(resource.source) {
          let selected = try PathSafety.resolvedChild(base: root, subpath: resource.path)
          paths.append(selected)
          // Support directories also contain structural ancestors. Only actual entries and
          // link targets are recursive interests; those ancestors are not source-tree reads.
          for entry in resource.support where entry.kind != .directory {
            paths.append(try PathSafety.resolvedChild(base: root, subpath: entry.path))
          }
          let links =
            try resource.entries.filter { $0.kind == .symlink }.map {
              try PathSafety.resolvedChild(base: selected, subpath: $0.path)
            }
            + resource.support.filter { $0.kind == .symlink }.map {
              try PathSafety.resolvedChild(base: root, subpath: $0.path)
            }
          paths += links.map { $0.resolvingSymlinksInPath() }
        }
      }
    }
    return Array(Set(paths.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
  }
}
