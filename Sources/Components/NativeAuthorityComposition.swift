import AgentsCore
import Foundation
import NativeDocuments

/// Bridges durable local authority to one verified native preimage and its same-edit remap.
enum NativeAuthorityComposition {
  static func dialect(_ format: NativeDocumentFormat) -> String {
    switch format {
    case .json: "json"
    case .jsonc(let trailing): trailing ? "jsonc-trailing-commas" : "jsonc"
    case .toml: "toml"
    }
  }

  static func address(_ region: NativeRegion) throws -> [PrivateNativeAddressStep] {
    try region.steps.map {
      switch $0 {
      case .key(let key): return .key(key)
      case .occurrence(let e):
        if let key = e.idKey, let value = e.id { return .stableID(key: key, value: value) }
        guard let ordinal = e.ordinal else {
          throw CoreError.invalidState("missing native ordinal")
        }
        return .position(index: ordinal)
      }
    }
  }

  static func region(_ path: [PrivateNativeAddressStep], document: NativeDocument) throws
    -> NativeRegion
  {
    var result = NativeRegion(keys: [])
    for step in path {
      switch step {
      case .key(let key): result = NativeRegion(result.steps + [.key(key)])
      case .stableID(let key, let value):
        result = NativeRegion(result.steps + [.occurrence(.init(idKey: key, id: value))])
      case .position(let index):
        result = try document.validatedOccurrences(
          in: result, matching: document.arrayDigest(result), ordinals: [index])[0]
      }
    }
    return result
  }

  static func region(
    _ path: [LedgerNativePathStep], document: NativeDocument,
    arrays: [PrivateNativeArrayRecord]
  ) throws -> NativeRegion {
    var result = NativeRegion(keys: [])
    for step in path {
      switch step {
      case .key(let key): result = NativeRegion(result.steps + [.key(key)])
      case .stableID(let key, let value):
        result = NativeRegion(result.steps + [.occurrence(.init(idKey: key, id: value))])
      case .position(let index, let evidence):
        let digest: NativeArrayDigest
        switch evidence {
        case .semantic(let format, let hash):
          digest = .init(format: format, digest: String(hash.dropFirst("sha256:".count)))
        case .privateArray(let token):
          let coordinates = try address(result)
          guard let record = arrays.first(where: { $0.token == token && $0.path == coordinates })
          else {
            throw CoreError.invalidState("native array authority is stale")
          }
          digest = .init(
            format: record.semanticFormat,
            digest: String(record.semanticDigest.dropFirst("sha256:".count)))
        }
        result = try document.validatedOccurrences(in: result, matching: digest, ordinals: [index])[
          0]
      }
    }
    return result
  }

  struct Result {
    let regions: [LedgerNativeOwnedRegion]
    let containers: [LedgerNativeCreatedContainer]
    let transitions: [PrivateNativeArrayTransition]
  }

  static func finish(
    _ change: PreparedNativeChange, document: NativeDocument,
    owners: [(NativeObservation, [String])], containers: [NativeRegion],
    previousArrays: [PrivateNativeArrayRecord], sensitive: Bool,
    format: NativeDocumentFormat
  ) throws -> Result {
    var arrays: [PrivateNativeArrayRecord] = []
    var transitions: [PrivateNativeArrayTransition] = []
    for transition in change.arrayTransitions {
      let previous = previousArrays[transition.index]
      let current: PrivateNativeArrayRecord?
      if let region = transition.region, let digest = transition.digest {
        current = .init(
          path: try address(region), documentFormat: dialect(format),
          token: transition.canRetainToken ? previous.token : UUID(),
          semanticFormat: digest.format, semanticDigest: "sha256:" + digest.digest)
        arrays.append(current!)
      } else {
        current = nil
      }
      transitions.append(.init(previous: previous, current: current))
    }
    func path(_ region: NativeRegion) throws -> [LedgerNativePathStep] {
      var prefix = NativeRegion(keys: [])
      var result: [LedgerNativePathStep] = []
      for step in region.steps {
        switch step {
        case .key(let key): result.append(.key(key))
        case .occurrence(let e):
          if let key = e.idKey, let value = e.id {
            result.append(.stableID(key: key, value: value))
          } else {
            guard let ordinal = e.ordinal else {
              throw CoreError.invalidState("missing native ordinal")
            }
            let digest = try document.arrayDigest(prefix)
            let evidence: LedgerNativeArrayEvidence
            if sensitive {
              let coordinates = try address(prefix)
              let record: PrivateNativeArrayRecord
              if let existing = arrays.first(where: { $0.path == coordinates }) {
                record = existing
              } else {
                record = .init(
                  path: coordinates, documentFormat: dialect(format), token: UUID(),
                  semanticFormat: digest.format, semanticDigest: "sha256:" + digest.digest)
                arrays.append(record)
                transitions.append(.init(previous: nil, current: record))
              }
              evidence = .privateArray(token: record.token)
            } else {
              evidence = .semantic(format: digest.format, digest: "sha256:" + digest.digest)
            }
            result.append(.position(index: ordinal, evidence: evidence))
          }
        }
        prefix = NativeRegion(prefix.steps + [step])
      }
      return result
    }
    let regions = try owners.map {
      try LedgerNativeOwnedRegion(deployments: $0.1.sorted(), path: path($0.0.region))
    }
    var created: [LedgerNativeCreatedContainer] = []
    for container in containers {
      guard let observed = try document.read(container) else { continue }
      let p = try path(container)
      let ids = Set(
        regions.filter { $0.path.count > p.count && Array($0.path.prefix(p.count)) == p }.flatMap(
          \.deployments))
      if !ids.isEmpty {
        created.append(.init(deployments: ids.sorted(), path: p, kind: observed.nativeKind))
      }
    }
    return Result(regions: regions, containers: created, transitions: transitions)
  }
}
