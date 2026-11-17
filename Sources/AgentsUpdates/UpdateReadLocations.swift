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
    for declaration in declarations {
      for source in declaration.sources.values where source.kind == .local {
        paths.append(source.localURL(environment: source.environment?.runtime ?? store.environment))
      }
      func collect(_ components: [ComponentDeclaration]) {
        for component in components {
          guard case .instructions(let instructions) = component else { continue }
          let sections =
            instructions.sectionReferences
            + instructions.prompts.flatMap { $0.prompt.sectionReferences }
          let ownNames = sections.filter { $0.source == nil || $0.source == "." }.map(\.name)
          if store.scope == .project {
            paths += InstructionOperations.ownReadLocations(
              names: ownNames, environment: store.environment)
          }
        }
      }
      collect(declaration.components)
      for group in declaration.groups { collect(group.components) }
    }
    for ledger in ledgers {
      for source in ledger.sources.values {
        if let location = source.location {
          paths.append(try location.resolve(roots: store.ledgerRoots))
        }
      }
      for component in ledger.components.values {
        if let value = component.payload.object?["localAppend"] {
          paths.append(try LedgerLocation(ledgerValue: value).resolve(roots: store.ledgerRoots))
        }
      }
      for deployment in ledger.deployments {
        paths.append(try deployment.target.resolve(roots: store.ledgerRoots))
      }
      for (id, resource) in ledger.resources {
        paths.append(try ArtifactAggregation.resourceDestination(id, ledger: ledger, store: store))
        if let source = ledger.sources[resource.source], source.kind == .local,
          let location = source.location
        {
          let root = try location.resolve(roots: store.ledgerRoots)
          paths.append(root.appendingPathComponent(try PathSafety.sanitizeSubpath(resource.path)))
        }
      }
    }
    return Array(Set(paths.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
  }
}
