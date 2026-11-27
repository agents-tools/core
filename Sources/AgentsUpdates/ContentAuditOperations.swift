import AgentsCore
import AgentsInstructions
import Components
import Foundation

public enum ContentAuditOperations {
  /// Inspect recognized prompt surfaces under the selected project or home.
  public static func scan(
    scope: InstallScope = .project, agents: Set<AgentID> = Set(AgentID.allCases),
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> ContentAuditReport {
    inspect(file: nil, scope: scope, agents: agents, environment: environment)
  }

  /// Inspect one scope-contained file. Native settings use their registered field profile.
  /// An explicitly selected Markdown or plain text document is read as a whole.
  public static func scan(
    file: URL, scope: InstallScope = .project,
    environment: RuntimeEnvironment = RuntimeEnvironment()
  ) -> ContentAuditReport {
    inspect(file: file, scope: scope, agents: Set(AgentID.allCases), environment: environment)
  }

  private static func inspect(
    file: URL?, scope: InstallScope, agents: Set<AgentID>, environment: RuntimeEnvironment
  ) -> ContentAuditReport {
    let profile = ContentAuditProfile(scope: scope, environment: environment, agents: agents)
    let selected: String?
    if let file {
      guard let path = ContentAuditProfile.relative(file, to: profile.root), path != "." else {
        return ContentAuditInspection.failure(path: file.lastPathComponent, reason: .outsideScope)
      }
      selected = path
      if profile.excludes(path) || profile.explicitFormat(at: path) == nil {
        return .init(
          targets: [.init(path: path, ownership: .unknown, status: .skipped)],
          findings: [], readLocations: [])
      }
    } else {
      selected = nil
    }

    let store = StateStore(scope: scope, environment: environment)
    let tree: ContentAuditTree
    do {
      tree = try ContentAuditTree(profile: profile)
    } catch ContentAuditProblem.outsideScope {
      return ContentAuditInspection.failure(path: selected ?? ".", reason: .outsideScope)
    } catch {
      return ContentAuditInspection.failure(path: selected ?? ".", reason: .unreadable)
    }
    let state = store.directory.lastPathComponent
    let stateLocations =
      [state]
      + [
        "agents.resolved", ".agents.lock", "transaction.json", "transaction.new",
        "watch-refs.pending",
      ].map { state + "/" + $0 }
    do {
      return try store.withContentAuditLedger(root: tree.directory) { ledger in
        var inspection = ContentAuditInspection(
          profile: profile, tree: tree, store: store, ledger: ledger,
          checkRecordedContent: selected == nil)
        for location in stateLocations { inspection.record(location) }
        if ledger == nil {
          inspection.issue(state + "/agents.resolved", .ownershipUnavailable)
        }
        if let selected {
          inspection.inspect(
            selected, format: profile.explicitFormat(at: selected)!, required: true)
        } else {
          inspection.discover()
        }
        return inspection.report
      }
    } catch CoreError.recoveryPending {
      return ContentAuditInspection.failure(
        path: state, reason: .pendingRecovery,
        locations: stateLocations.map { profile.root.appendingPathComponent($0) })
    } catch {
      return ContentAuditInspection.failure(
        path: state + "/agents.resolved", reason: .ownershipUnavailable,
        locations: stateLocations.map { profile.root.appendingPathComponent($0) })
    }
  }
}

struct ContentAuditInspection {
  private static let maximumDepth = 64
  static let maximumFileBytes = 8 * 1024 * 1024
  private static let maximumReportFindings = 65_536
  private static let maximumEntries = 100_000

  let profile: ContentAuditProfile
  let tree: ContentAuditTree
  let store: StateStore
  let ledger: ResolvedLedger?
  private let claims: ContentAuditClaims
  private let checkRecordedContent: Bool
  private var targets: [Data: ContentAuditTarget] = [:]
  private var findings: [ContentAuditFinding] = []
  private var locations: [Data: URL] = [:]
  private var entries = 0
  private var exhausted = false

  init(
    profile: ContentAuditProfile, tree: ContentAuditTree, store: StateStore,
    ledger: ResolvedLedger?, checkRecordedContent: Bool
  ) {
    self.profile = profile
    self.tree = tree
    self.store = store
    self.ledger = ledger
    self.checkRecordedContent = checkRecordedContent
    claims = ContentAuditClaims(profile: profile, store: store, ledger: ledger)
  }

  var report: ContentAuditReport {
    let orderedTargets = targets.values.sorted {
      $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
    }
    let orderedFindings = findings.sorted {
      let a = $0.location
      let b = $1.location
      if !a.path.utf8.elementsEqual(b.path.utf8) {
        return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
      }
      return (
        a.line ?? 0, a.column ?? 0, a.field ?? "", a.promptLine ?? 0, a.promptColumn ?? 0,
        $0.reason.rawValue
      )
        < (
          b.line ?? 0, b.column ?? 0, b.field ?? "", b.promptLine ?? 0, b.promptColumn ?? 0,
          $1.reason.rawValue
        )
    }
    return .init(
      targets: orderedTargets, findings: orderedFindings,
      readLocations: locations.values.sorted {
        $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
      })
  }

  static func failure(
    path: String, reason: ContentAuditReason, locations: [URL] = []
  ) -> ContentAuditReport {
    .init(
      targets: [.init(path: path, ownership: .unknown, status: .incomplete)],
      findings: [diagnostic(path, reason, ownership: .unknown)], readLocations: locations)
  }

  mutating func record(_ path: String) {
    locations[Data(path.utf8)] =
      path == "." ? profile.root : profile.root.appendingPathComponent(path)
  }

  mutating func issue(
    _ path: String, _ reason: ContentAuditReason, ownership: ContentAuditOwnership = .unknown,
    field: String? = nil, coordinate: (line: Int, column: Int)? = nil
  ) {
    findings.append(
      Self.diagnostic(path, reason, ownership: ownership, field: field, coordinate: coordinate))
    targets[Data(path.utf8)] = .init(path: path, ownership: ownership, status: .incomplete)
  }

  private static func diagnostic(
    _ path: String, _ reason: ContentAuditReason, ownership: ContentAuditOwnership,
    field: String? = nil, coordinate: (line: Int, column: Int)? = nil
  ) -> ContentAuditFinding {
    .init(
      severity: .critical, reason: reason,
      location: .init(
        path: path, field: field, line: coordinate?.line, column: coordinate?.column,
        promptLine: nil, promptColumn: nil),
      ownership: ownership, codePoint: nil)
  }

  mutating func discover() {
    record(".")
    for path in profile.outsideScope.sorted() { issue(path, .outsideScope) }
    for (path, format) in profile.files.sorted(by: { $0.key < $1.key }) {
      inspect(path, format: format)
    }
    for pattern in profile.directories {
      guard !exhausted else { return }
      record(pattern.directory)
      do {
        if let directory = try tree.open(pattern.directory) {
          walk(directory, path: pattern.directory, pattern: pattern, depth: 0)
        }
      } catch ContentAuditProblem.unrelatedRepository {
        continue
      } catch {
        issue(pattern.directory, .unreadable)
      }
    }
    if !profile.nestedInstructions.isEmpty {
      walk(tree.directory, path: ".", pattern: nil, depth: 0)
    }
  }

  /// Profile traversal and nested context discovery share the same no-follow policy.
  /// A nested worktree starts at its own .git file or directory.
  private mutating func walk(
    _ directory: DirectoryHandle, path: String, pattern: ContentAuditProfile.Pattern?, depth: Int
  ) {
    guard !exhausted else { return }
    guard depth <= Self.maximumDepth else {
      issue(path, .unsupportedContent)
      return
    }
    record(path)
    do {
      for name in try directory.names()
      where !name.hasPrefix(".") && !ContentAuditProfile.excludesName(in: name) {
        guard !exhausted else { return }
        entries += 1
        if entries > Self.maximumEntries {
          exhausted = true
          issue(".", .unsupportedContent)
          return
        }
        let child = path == "." ? name : path + "/" + name
        guard !profile.excludes(child) else { continue }
        let match = pattern?.matches(name) ?? profile.nestedInstructions.contains(name)
        let format = pattern?.format ?? .text
        let kind = try ContentAuditFiles.kind(name, in: directory)
        if match && (kind != .directory || pattern != nil) {
          inspect(child, format: format)
          continue
        }
        if kind == .directory, let handle = try directory.directory(name) {
          if try ContentAuditFiles.kind(".git", in: handle) == nil {
            walk(handle, path: child, pattern: pattern, depth: depth + 1)
          }
        } else if kind == .symbolicLink && pattern?.selector == .named("SKILL.md") && depth == 0 {
          inspect(child + "/SKILL.md", format: format)
        }
      }
    } catch {
      issue(path, .unreadable)
    }
  }

  mutating func inspect(
    _ path: String, format: ContentAuditProfile.Format, required: Bool = false
  ) {
    guard !exhausted else { return }
    let key = Data(path.utf8)
    guard targets[key] == nil else { return }
    record(path)
    let recorded = claims.files[key] ?? []
    let skill = claims.skills[key]
    let whole = recorded.filter { $0.ownership == .generated }
    let regional = recorded.filter { $0.ownership != .generated }
    let baseOwnership: ContentAuditOwnership =
      !whole.isEmpty || skill != nil
      ? .managedFile : !regional.isEmpty ? .managedRegion : ledger == nil ? .unknown : .untracked
    do {
      guard let bytes = try read(path, skill: skill) else {
        if required { issue(path, .unreadable, ownership: baseOwnership) }
        return
      }
      guard let source = String(validating: bytes, as: UTF8.self) else {
        issue(path, .unsupportedContent, ownership: baseOwnership)
        return
      }
      if source.unicodeScalars.contains("\0") && format == .text {
        issue(path, .unsupportedContent, ownership: baseOwnership)
        return
      }
      targets[key] = .init(path: path, ownership: baseOwnership, status: .scanned)
      verifyHash(bytes, path: path, whole: whole, skill: skill)
      switch format {
      case .text:
        let importRange = try verifyText(
          bytes, path: path, regional: regional)
        let symbols = try ContentAuditUnicode.scan(source, leadingBOM: true)
        let individualOwnership = baseOwnership == .managedRegion ? .untracked : baseOwnership
        for symbol in symbols {
          let ownership =
            importRange?.contains(symbol.byteRange.lowerBound) == true
            ? .managedRegion : individualOwnership
          append(
            symbol, path: path, field: nil, coordinate: (symbol.line, symbol.column),
            ownership: ownership)
        }
      case .native(let native):
        try inspectNative(
          bytes, source: source, path: path, format: native, ownership: baseOwnership,
          authorities: claims.regions[key] ?? [])
      }
    } catch ContentAuditProblem.outsideScope {
      issue(path, .outsideScope, ownership: baseOwnership)
    } catch ContentAuditProblem.unrelatedRepository {
      if required || skill != nil { issue(path, .outsideScope, ownership: baseOwnership) }
    } catch ContentAuditProblem.unsupportedContent {
      issue(path, .unsupportedContent, ownership: baseOwnership)
    } catch {
      issue(path, .unreadable, ownership: baseOwnership)
    }
  }

  private mutating func read(_ path: String, skill: ContentAuditClaims.Skill?) throws -> Data? {
    if path.hasSuffix("/SKILL.md") {
      let slot = String(path.dropLast("/SKILL.md".count))
      if let (parent, name) = try tree.parent(of: slot),
        try ContentAuditFiles.kind(name, in: parent) == .symbolicLink
      {
        guard let skill else { throw ContentAuditProblem.outsideScope }
        return try readLinkedSkill(skill, parent: parent, name: name, slot: slot)
      }
    }
    guard let (parent, name) = try tree.parent(of: path),
      let kind = try ContentAuditFiles.kind(name, in: parent)
    else { return nil }
    guard kind != .symbolicLink else { throw ContentAuditProblem.outsideScope }
    return try ContentAuditFiles.readPrompt(name, in: parent, maximumBytes: Self.maximumFileBytes)
  }

  private mutating func readLinkedSkill(
    _ skill: ContentAuditClaims.Skill, parent: DirectoryHandle, name: String, slot: String
  ) throws -> Data {
    guard let ledger, let resource = ledger.resources[skill.resourceID],
      skill.mode == .link
        || (skill.mode == .edit && resource.kind == .liveEdit
          && ledger.sources[resource.source]?.kind == .local)
    else { throw ContentAuditProblem.outsideScope }
    let roots = [
      "project": store.environment.projectDirectory, "home": store.environment.homeDirectory,
      "state": store.directory,
    ]
    let destination: URL
    if let artifact = resource.artifact, resource.location != nil {
      destination = try SourceCache.artifactContentLocation(digest: artifact.digest)
        .resolve(roots: roots)
    } else {
      destination = try ArtifactAggregation.resourceDestination(
        skill.resourceID, ledger: ledger, store: store, roots: roots)
    }
    guard let target = ContentAuditProfile.relative(destination, to: profile.root), target != "."
    else {
      throw ContentAuditProblem.outsideScope
    }
    let retained =
      skill.mode == .link
      && target.utf8.starts(
        with: (store.directory.lastPathComponent + "/cache/").utf8)
    guard !profile.excludes(target, admittedCache: retained),
      skill.mode == .edit || retained
    else { throw ContentAuditProblem.outsideScope }
    let from = profile.root.appendingPathComponent(slot).deletingLastPathComponent().pathComponents
    let to = destination.pathComponents
    let common = zip(from, to).prefix { $0.utf8.elementsEqual($1.utf8) }.count
    let relativeLink = (Array(repeating: "..", count: from.count - common) + to.dropFirst(common))
      .joined(separator: "/")
    let spelling = try ContentAuditFiles.link(name, in: parent)
    guard
      spelling.utf8.elementsEqual(relativeLink.utf8)
        || spelling.utf8.elementsEqual(destination.path.utf8)
    else { throw ContentAuditProblem.outsideScope }
    var admittedRepository: String?
    if skill.mode == .edit {
      guard let source = ledger.sources[resource.source]?.location,
        let declaredRoot = ContentAuditProfile.relative(
          try source.resolve(roots: roots), to: profile.root),
        !profile.excludes(declaredRoot),
        declaredRoot == "." || target.utf8.elementsEqual(declaredRoot.utf8)
          || target.utf8.starts(with: (declaredRoot + "/").utf8)
      else { throw ContentAuditProblem.outsideScope }
      admittedRepository = declaredRoot
    }
    let entry = target + "/SKILL.md"
    record(entry)
    guard let targetDirectory = try tree.open(target, admittedRepository: admittedRepository) else {
      throw CoreError.notFound("retained skill prompt")
    }
    let bytes = try ContentAuditFiles.readPrompt(
      "SKILL.md", in: targetDirectory, maximumBytes: Self.maximumFileBytes)
    guard try ContentAuditFiles.link(name, in: parent).utf8.elementsEqual(spelling.utf8) else {
      throw CoreError.invalidState("skill link changed during content audit")
    }
    return bytes
  }

  private mutating func verifyHash(
    _ bytes: Data, path: String, whole: [LedgerDeployment], skill: ContentAuditClaims.Skill?
  ) {
    guard checkRecordedContent else { return }
    if !whole.isEmpty || skill?.expectedEntryHash != nil {
      let actual = "sha256:" + FileHash.sha256Hex(data: bytes)
      if whole.contains(where: { $0.expectedHash != actual })
        || skill?.expectedEntryHash.map({ $0 != actual }) == true
      {
        findings.append(Self.diagnostic(path, .contentDrift, ownership: .managedFile))
      }
    }
  }

  private mutating func verifyText(
    _ bytes: Data, path: String, regional: [LedgerDeployment]
  ) throws -> Range<Int>? {
    guard let record = regional.first(where: { $0.ownership == .importBlock }) else { return nil }
    guard let block = try InstructionTargets.auditImportBlock(bytes) else {
      if checkRecordedContent {
        findings.append(Self.diagnostic(path, .contentDrift, ownership: .managedRegion))
      }
      return nil
    }
    if checkRecordedContent
      && record.expectedHash != "sha256:" + FileHash.sha256Hex(data: block.normalized)
    {
      findings.append(Self.diagnostic(path, .contentDrift, ownership: .managedRegion))
    }
    return block.byteRange
  }

  private mutating func inspectNative(
    _ bytes: Data, source: String, path: String, format: NativePromptAudit.Format,
    ownership: ContentAuditOwnership, authorities: [LedgerNativeOwnedRegion]
  ) throws {
    let readback: NativePromptAudit.Readback
    do {
      readback = try NativePromptAudit.read(bytes, format: format, authorities: authorities)
    } catch NativePromptAudit.Failure.unsupported(let offset, let field) {
      let coordinate = offset.flatMap { ContentAuditUnicode.coordinates(in: source, at: [$0])[$0] }
      issue(path, .unsupportedContent, ownership: ownership, field: field, coordinate: coordinate)
      return
    } catch {
      issue(path, .unsupportedContent, ownership: ownership)
      return
    }
    if !readback.ownershipVerified {
      issue(path, .ownershipUnavailable, ownership: ownership)
    } else if readback.fields.isEmpty {
      targets[Data(path.utf8)] = .init(path: path, ownership: ownership, status: .skipped)
    }
    let sourceBytes = Array(bytes)
    var mapped: [(NativePromptAudit.Field, [ContentAuditScalar], [Int: Int])] = []
    var total = 0
    for field in readback.fields {
      let symbols = try ContentAuditUnicode.scan(field.text, leadingBOM: false)
      guard !symbols.isEmpty else { continue }
      total += symbols.count
      guard total <= ContentAuditUnicode.maximumFindings else {
        throw ContentAuditProblem.unsupportedContent
      }
      let offsets =
        field.sourceRange.map {
          ContentAuditSourceMap.offsets(
            in: sourceBytes, range: $0, decoded: field.text, toml: format.isTOML,
            requested: Set(symbols.map(\.byteRange.lowerBound)))
        } ?? [:]
      mapped.append((field, symbols, offsets))
    }
    let coordinates = ContentAuditUnicode.coordinates(
      in: source, at: mapped.flatMap { $0.2.values })
    for (field, symbols, offsets) in mapped {
      for symbol in symbols {
        let fieldOwnership: ContentAuditOwnership =
          ownership == .managedFile
          ? .managedFile
          : field.managed
            ? .managedRegion
            : (!readback.ownershipVerified || ledger == nil) ? .unknown : .untracked
        append(
          symbol, path: path, field: field.pointer,
          coordinate: offsets[symbol.byteRange.lowerBound].flatMap { coordinates[$0] },
          ownership: fieldOwnership)
      }
    }
  }

  private mutating func append(
    _ symbol: ContentAuditScalar, path: String, field: String?,
    coordinate: (line: Int, column: Int)?, ownership: ContentAuditOwnership
  ) {
    guard !exhausted else { return }
    if findings.count >= Self.maximumReportFindings {
      exhausted = true
      issue(path, .unsupportedContent, ownership: ownership)
      return
    }
    findings.append(
      .init(
        severity: symbol.severity, reason: symbol.reason,
        location: .init(
          path: path, field: field, line: coordinate?.line, column: coordinate?.column,
          promptLine: field == nil ? nil : symbol.line,
          promptColumn: field == nil ? nil : symbol.column),
        ownership: ownership, codePoint: symbol.codePoint))
  }
}

private struct ContentAuditClaims {
  struct Skill {
    let resourceID: String
    let mode: InstallMode
    let expectedEntryHash: String?
  }

  var files: [Data: [LedgerDeployment]] = [:]
  var skills: [Data: Skill] = [:]
  var regions: [Data: [LedgerNativeOwnedRegion]] = [:]

  init(profile: ContentAuditProfile, store: StateStore, ledger: ResolvedLedger?) {
    guard let ledger else { return }
    var lowerings: [String: LockedLowering] = [:]
    for lowering in ledger.lowerings {
      for deployment in lowering.deployments { lowerings[deployment] = lowering }
    }
    for deployment in ledger.deployments {
      guard let url = try? store.contentAuditLocation(deployment.target),
        let path = ContentAuditProfile.relative(url, to: profile.root),
        !profile.excludes(path)
      else { continue }
      if deployment.route == "agents/skill@1" {
        let entry = path + "/SKILL.md"
        guard profile.format(at: entry) == .text,
          let lowering = lowerings[deployment.id],
          let mode = lowering.layout.object?["mode"]?.text.flatMap(InstallMode.init(rawValue:)),
          let resourceID = lowering.resources.first
            ?? deployment.owners.first
            .flatMap({ ledger.components[$0]?.resources.first }),
          let resource = ledger.resources[resourceID]
        else { continue }
        skills[Data(entry.utf8)] = .init(
          resourceID: resourceID, mode: mode,
          expectedEntryHash: mode == .edit
            ? nil
            : resource.entries
              .first(where: { $0.path == "SKILL.md" && $0.kind == .file })?.object)
      } else if profile.explicitFormat(at: path) != nil {
        files[Data(path.utf8), default: []].append(deployment)
      }
    }
    for record in ledger.nativeAuthorities ?? [] {
      guard let url = try? store.contentAuditLocation(record.target),
        let path = ContentAuditProfile.relative(url, to: profile.root),
        !profile.excludes(path),
        case .native? = profile.format(at: path)
      else { continue }
      regions[Data(path.utf8), default: []].append(contentsOf: record.regions)
    }
  }
}
