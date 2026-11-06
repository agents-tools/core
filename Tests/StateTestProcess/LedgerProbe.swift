import AgentsCore
import AgentsManifest
import Components
import Foundation

/// An internal assembly probe, deliberately absent from the production renderer table.
private let probeFormat = "test/generated-bundle@1"

func ledgerProbe(_ action: String, store: StateStore) throws {
  let roots = [
    "project": store.environment.projectDirectory, "home": store.environment.homeDirectory,
    "state": store.directory,
  ]
  let limits = LedgerLimits.standard
  let renderers: [String: LedgerRenderer] = [
    probeFormat: { lowering, ledger, resources in
      let destination = store.environment.projectDirectory.appendingPathComponent("probe-bundle")
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let manifest = try ResolvedLedgerCodec.bytes(lowering.inputs.map { ledger.components[$0]! })
      try manifest.write(to: destination.appendingPathComponent("manifest.json"))
      for (index, id) in lowering.resources.enumerated() {
        try FileManager.default.copyItem(
          at: resources[id]!, to: destination.appendingPathComponent("resource-\(index)"))
      }
      guard let registration = lowering.layout.object?["registration"],
        let values = lowering.layout.object?["values"]
      else { throw CoreError.invalidState("probe layout") }
      return [
        ReplayedArtifact(name: "bundle", kind: .tree, tree: destination),
        ReplayedArtifact(
          name: "registration", kind: .registration,
          bytes: try ResolvedLedgerCodec.bytes(registration)),
        ReplayedArtifact(name: "owned", kind: .ownedValues, values: values),
      ]
    }
  ]
  if action == "ledger-freeze" {
    let document = try DeclarationDocument(
      bytes: Array(Data(contentsOf: store.declarationURL)),
      identity: DocumentIdentity("probe/Agents.swift"))
    let ledger = try ComponentLinker.withLinkedComponents(
      document: document, store: store,
      platform: {
        #if os(macOS)
          return .macOS
        #else
          return .linux
        #endif
      }()
    ) { linked, session in
      try LedgerFreeze.freeze(
        linked, session: session,
        locations: .init(sources: [
          "local:" + store.environment.projectDirectory.path:
            LedgerLocation(kind: .registered, root: "project", path: ".")
        ]), limits: limits)
    }
    var candidate = ledger
    let inputs = ledger.occurrences.map(\.component)
    let resourceIDs = inputs.flatMap { ledger.components[$0]!.resources }
    candidate.lowerings = [
      LockedLowering(
        id: "bundle", format: probeFormat, inputs: inputs,
        resources: resourceIDs, deployments: [],
        layout: .init(object: [
          "registration": .init(object: ["root": .init("project"), "path": .init("plugins/bundle")]
          ),
          "values": .init(object: ["server": ledger.components[inputs[0]]!.payload]),
        ]),
        platform: {
          #if os(macOS)
            return "macos"
          #else
            return "linux"
          #endif
        }(), artifacts: [])
    ]
    candidate = try LedgerReplay.prepareLowerings(
      candidate, store: store, roots: roots,
      limits: limits, renderers: renderers)
    try ResolvedLedgerCodec.encode(candidate, limits: limits).write(to: store.resolvedURL)
  } else if action == "ledger-compatibility" {
    let ledger = try store.loadLedger(limits: limits)
    try LedgerReplay.withReplay(ledger, store: store, roots: roots, limits: limits) { artifacts in
      try ResolvedLedgerCodec.bytes(try artifacts.map { try $0.digest(limits: limits) })
        .write(
          to: store.environment.projectDirectory.appendingPathComponent(
            "compatibility-summary.json"))
    }
  } else if action == "ledger-replay" {
    let ledger = try store.loadLedger(limits: limits)
    try LedgerReplay.withReplay(
      ledger, store: store, roots: roots, limits: limits,
      renderers: renderers
    ) { artifacts in
      let summaries = try artifacts.map { try $0.digest(limits: limits) }
      try ResolvedLedgerCodec.bytes(summaries).write(
        to: store.environment.projectDirectory.appendingPathComponent("replay-summary.json"))
    }
  } else {
    throw CoreError.invalidState("unknown ledger probe")
  }
}
