import AgentsCore
import Components
import Foundation
import Testing

struct ImportProfileTests {
  @Test func pinnedProducerSamplesRemainReadOnlyAndReportUnconvertedSemantics() throws {
    let fixture = try ImportProfileFixture()
    #expect(
      FileHash.sha256Hex(data: Data(ImportPinnedFixtures.apmManifest.utf8))
        == "66261774fac336a23e4521fde39fb822e606527e32a0de8144993710bf4ce726")
    #expect(
      FileHash.sha256Hex(data: Data(ImportPinnedFixtures.rulesyncConfig.utf8))
        == "68c1da2097de1f81408cf08eac0f033cdf8c793d75d2e340cb10113b2f652fb7")
    try fixture.write("apm.yml", ImportPinnedFixtures.apmManifest)
    try fixture.write("rulesync.jsonc", ImportPinnedFixtures.rulesyncConfig)
    try fixture.directory(".rulesync")
    let before = try fixture.hash()
    let apm = try SourceImport.preview(fixture.input(.apmManifest, "apm.yml"))
    let rulesync = try SourceImport.preview(fixture.input(.rulesyncConfig, "rulesync.jsonc"))
    #expect(try fixture.hash() == before)
    #expect(apm.sources.count == 5)
    #expect(apm.selections.first?.values == ["copilot"])
    #expect(apm.selections.last?.automatic == true)
    #expect(apm.diagnostics.contains { $0.code == .incompletePin })
    #expect(!rulesync.diagnostics.contains { $0.code == .invalidInput })
    #expect(rulesync.diagnostics.contains { $0.code == .unconverted })
    #expect(rulesync.components.isEmpty)
  }

  @Test func apmCompositionNeedsMatchingCoordinatesAndCapturesExplicitContentHonestly() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write(
      "apm.yml",
      "name: fixture\nversion: '1.0.0'\ndependencies:\n  apm:\n    - git: https://github.com/acme/repo\n      path: exports\n      ref: main\n"
    )
    try fixture.write(
      "apm.lock.yaml",
      "lockfile_version: '1'\ndependencies:\n  - repo_url: https://github.com/acme/repo\n    virtual_path: exports\n    resolved_ref: main\n    resolved_commit: \(String(repeating: "a", count: 40))\n"
    )
    let result = try SourceImport.previewAPM(
      manifest: fixture.input(.apmManifest, "apm.yml"),
      lock: fixture.input(.apmLock, "apm.lock.yaml"))
    #expect(result.sources[0].pin.commit == String(repeating: "a", count: 40))
    #expect(result.sources[0].requestedRef == "main")
    #expect(
      result.sources[0].declaration?.requirement == .revision(String(repeating: "a", count: 40)))
    #expect(
      !result.diagnostics.contains {
        $0.code == .incompletePin && $0.location.document == "apm.yml"
      })
    try fixture.write(
      "apm.yml",
      "name: fixture\nversion: '1.0.0'\ndependencies:\n  apm:\n    - git: https://github.com/acme/repo\n      path: exports\n      ref: changed\n"
    )
    let mismatch = try SourceImport.previewAPM(
      manifest: fixture.input(.apmManifest, "apm.yml"),
      lock: fixture.input(.apmLock, "apm.lock.yaml"))
    #expect(mismatch.sources[0].pin.commit == nil)
    #expect(mismatch.diagnostics.contains { $0.code == .ambiguousSource })
    try fixture.write(
      "installed/review/SKILL.md",
      "---\nname: review\ndescription: fixture\nx-unknown: value\nenv: {TOKEN: secret-sentinel}\n---\nactual installed bytes\n"
    )
    var input = fixture.input(.apmLock, "apm.lock.yaml")
    input.installedSkills = ["review": "installed/review"]
    let before = try fixture.hash()
    let captured = try SourceImport.preview(input)
    #expect(try fixture.hash() == before)
    #expect(captured.resources.last?.observedHash?.hasPrefix("sha256:") == true)
    #expect(captured.resources.last?.requiresStandaloneSource == true)
    #expect(captured.components.count == 1)
    #expect(captured.sources.last?.pin.commit == nil)
    #expect(!captured.bindings.isEmpty)
    #expect(!String(reflecting: captured).contains("secret-sentinel"))
  }

  @Test func apmNativeSkillLayoutDoesNotGuessPluginFallbackOrTreatIncludesAsScope() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write(
      "apm.yml",
      "name: fixture\nversion: '1.0.0'\nincludes: [.apm/instructions]\ntargets: [codex]\n")
    try fixture.write(
      ".apm/skills/review/SKILL.md",
      "---\nname: review\ndescription: fixture\n---\nactual source bytes\n")
    try fixture.write(
      ".apm/instructions/review.instructions.md", "---\ndescription: review\n---\nbody\n")
    try fixture.write(
      "skills/fallback/SKILL.md",
      "---\nname: fallback\ndescription: fixture\n---\nunselected plugin-native bytes\n")
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(.apmManifest, "apm.yml"))
    #expect(try fixture.hash() == before)
    #expect(result.components.count == 1)
    #expect(result.resources.first?.producerName == "review")
    #expect(result.resources.first?.observedHash?.hasPrefix("sha256:") == true)
    #expect(result.resources.first?.requiresStandaloneSource == true)
    #expect(result.sources.first?.declaration?.location == ".apm/skills/review")
    #expect(
      result.diagnostics.contains {
        $0.code == .unconverted && $0.location.pointer.contains("layout")
      })
    #expect(result.selections.first?.values == ["codex"])
    #expect(result.selections.last?.values == [".apm/instructions"])
  }

  @Test func apmManifestPreservesIntentAndRefPrecedenceWithoutPinsOrScopeGuessing() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write(
      "apm.yml",
      """
      name: on
      version: '1.2.3'
      targets: [claude, codex]
      includes: [docs, .apm/skills]
      dependencies:
        apm:
          - git: https://github.com/acme/repo
            ref: main
            version: old-version
            path: packages/review
            skills: [review]
            targets: [claude]
            x-extra: not-retained
        mcp:
          - name: private
            env:
              TOKEN: secret-sentinel
      scripts:
        start: never-execute-sentinel
      devDependencies:
        apm: [acme/dev#v2]
      x-extension: secret-sentinel
      """)
    let before = try fixture.hash()
    let proposal = try SourceImport.preview(fixture.input(.apmManifest, "apm.yml"))
    #expect(try fixture.hash() == before)
    #expect(proposal.sources.count == 2)
    #expect(proposal.sources[0].requestedRef == "main")
    #expect(proposal.sources[0].declaration?.location == "https://github.com/acme/repo")
    #expect(proposal.sources[0].declaration?.path == "packages/review")
    #expect(proposal.sources.allSatisfy { $0.pin.commit == nil })
    #expect(proposal.components.isEmpty)
    #expect(proposal.resources.allSatisfy { $0.requiresStandaloneSource })
    #expect(proposal.selections.map(\.kind) == [.targets, .includes, .skills, .targets])
    #expect(!proposal.bindings.isEmpty)
    #expect(proposal.diagnostics.contains { $0.location.span?.line == 22 })
    #expect(!String(reflecting: proposal).contains("secret-sentinel"))
    #expect(!String(reflecting: proposal).contains("never-execute-sentinel"))
    #expect(proposal.profile.specificationStatus.contains("unratified"))
  }

  @Test func apmLocksKeepGitCommitRegistryIntegrityAndResolvedRefDistinct() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write(
      "apm.lock.yaml",
      """
      lockfile_version: '2'
      apm_version: '0.35.1'
      dependencies:
        - repo_url: https://github.com/acme/repo
          resolved_commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          resolved_ref: moving-branch
          version: '1.2.3'
          virtual_path: packages/review
          deployed_files: [.agents/skills/review/SKILL.md]
          tree_sha256: sha256:\(String(repeating: "b", count: 64))
        - repo_url: acme/archive
          source: registry
          version: '2.0.0'
          resolved_url: https://registry.example/archive.tgz
          resolved_hash: sha512:\(String(repeating: "c", count: 128))
        - repo_url: https://github.com/acme/unlocked
          resolved_ref: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      local_deployed_files: [.agents/skills/local/SKILL.md]
      mcp_configs:
        hidden:
          headers: {Authorization: secret-sentinel}
      """)
    let before = try fixture.hash()
    let proposal = try SourceImport.preview(fixture.input(.apmLock, "apm.lock.yaml"))
    #expect(try fixture.hash() == before)
    #expect(proposal.sources.count == 3)
    #expect(proposal.sources[0].pin.commit == String(repeating: "a", count: 40))
    #expect(proposal.sources[0].resolvedRef == "moving-branch")
    #expect(proposal.sources[0].pin.integrity?.kind == .apmDigest)
    #expect(proposal.sources[1].pin.commit == nil)
    #expect(
      proposal.sources[1].pin.integrity?.value == "sha512:" + String(repeating: "c", count: 128))
    #expect(proposal.sources[1].resolvedURL == "https://registry.example/archive.tgz")
    #expect(proposal.sources[2].pin.commit == nil)
    #expect(proposal.deployments.first?.files == [".agents/skills/review/SKILL.md"])
    #expect(proposal.components.isEmpty)
    #expect(!proposal.bindings.isEmpty)
    #expect(!String(reflecting: proposal).contains("secret-sentinel"))
  }

  @Test func rulesyncYAMLLocksAreDistinctAndDeploymentsDoNotInventSkillSourcePaths() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write(
      "gh.yml",
      """
      lockfile_version: '1'
      generated_at: '2026-01-01'
      installations:
        - source: acme/repo
          owner: acme
          repo: repo
          agent: codex
          scope: user
          skill: review
          requested_ref: main
          resolved_ref: main
          resolved_commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          install_dir: .agents/skills/review
          deployed_files: [.agents/skills/review/SKILL.md]
          content_hash: sha256:\(String(repeating: "b", count: 64))
          new_field: hidden
      """)
    let gh = try SourceImport.preview(fixture.input(.rulesyncGitHubV1, "gh.yml"))
    #expect(gh.sources.first?.pin.commit == String(repeating: "a", count: 40))
    #expect(gh.sources.first?.requestedRef == "main")
    #expect(gh.sources.first?.pin.integrity?.kind == .rulesyncSHA256)
    #expect(gh.resources.first?.path == nil)
    #expect(gh.deployments.first?.scope == "user")
    #expect(gh.deployments.first?.agent == "codex")
    #expect(gh.components.isEmpty)
    #expect(gh.diagnostics.contains { $0.code == .unconverted })
    try fixture.write(
      "mirror.yml",
      """
      lockfile_version: '1'
      generated_at: '2026-01-01'
      apm_version: rulesync-compat
      dependencies:
        - repo_url: https://github.com/acme/repo
          resolved_ref: main
          depth: 1
          package_type: apm_package
          content_hash: arbitrary-producer-string
          deployed_files: []
      """)
    let mirror = try SourceImport.preview(fixture.input(.rulesyncAPMV1, "mirror.yml"))
    #expect(mirror.sources.first?.pin.commit == nil)
    #expect(mirror.sources.first?.pin.integrity == nil)
    #expect(mirror.sources.first?.resolvedRef == "main")
    #expect(mirror.diagnostics.contains { $0.code == .incompletePin })
    #expect(mirror.profile.producerRevision != SourceImportProfile.apmLock.producerRevision)
    #expect(!String(reflecting: mirror).contains("arbitrary-producer-string"))
  }

  @Test(arguments: ["3", "true", "1"])
  func yamlLockVersionUsesStringIdentityAndRefusesCandidates(_ version: String) throws {
    let fixture = try ImportProfileFixture()
    try fixture.write("lock.yml", "lockfile_version: \(version)\ndependencies: []\n")
    let result = try SourceImport.preview(fixture.input(.apmLock, "lock.yml"))
    #expect(result.sources.isEmpty)
    #expect(result.diagnostics.first?.code == .unsupportedVersion)
    #expect(result.diagnostics.first?.location.span?.line == 1)
  }

  @Test func yamlAdmissionLocationsAndLimitsAreValueFree() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write("bad.yml", "name: secret-sentinel\nname: secret-sentinel\n")
    let result = try SourceImport.preview(fixture.input(.apmManifest, "bad.yml"))
    #expect(result.diagnostics.first?.code == .invalidInput)
    #expect(result.diagnostics.first?.location.span != nil)
    #expect(!String(reflecting: result).contains("secret-sentinel"))
    try fixture.write("deep.yml", "name: a\nversion: '1.0.0'\nx-extra: [[[[[deep]]]]]\n")
    var limits = SourceImportLimits()
    limits.depth = 3
    let bounded = try SourceImport.preview(fixture.input(.apmManifest, "deep.yml"), limits: limits)
    #expect(bounded.sources.isEmpty)
    #expect(bounded.diagnostics.last?.code == .invalidInput)
  }

  @Test func configJSONCPreservesBytesAndLocalOverrideDoesNotMergeSourceArrays() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write(
      "rulesync.jsonc",
      """
      // Explicit project config; no init-template discovery.
      {"sources":[{"source":"acme/base"}], "inputRoots":["primary"],
       "targets":["codex"], "features":["skills"],}
      """)
    try fixture.write(
      "local.jsonc",
      """
      {"sources":[{"source":"gitlab:acme/local@release:export", "skills":["*"]}],
       "inputRoot":"legacy", "targets":["claudecode"]}
      """)
    try fixture.directory("primary")
    let before = try fixture.hash()
    let result = try SourceImport.previewRulesync(configs: [
      fixture.input(.rulesyncConfig, "rulesync.jsonc"),
      fixture.input(.rulesyncConfig, "local.jsonc"),
    ])
    #expect(try fixture.hash() == before)
    #expect(result.orderedSources.count == 1)
    #expect(result.orderedSources[0].identity == "gitlab:acme/local@release:export")
    #expect(result.orderedSources[0].requestedRef == "release")
    #expect(result.orderedSources[0].skillsPath == "export")
    #expect(result.sources[0].declaration?.location == "https://gitlab.com/acme/local")
    #expect(result.selections.first?.values == ["claudecode"])
    #expect(!result.diagnostics.contains { $0.code == .missingResource })
  }

  @Test func remoteSourceOrderWinsIndependentlyOfSortedLockOrder() throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write(
      "rulesync.jsonc",
      """
      {"sources":[{"source":"z/first"},{"source":"a/last"}]}
      """)
    try fixture.write(
      "rulesync.lock",
      """
      {"lockfileVersion":1,"sources":{
       "a/last":{"resolvedRef":"\(String(repeating: "a", count: 40))","skillsPath":"skills","skillSelection":["*"],"skills":{"review":{"integrity":"sha256-\(String(repeating: "b", count: 64))"}}},
       "z/first":{"resolvedRef":"\(String(repeating: "c", count: 40))","skillsPath":"skills","skillSelection":["*"],"skills":{"review":{"integrity":"sha256-\(String(repeating: "d", count: 64))"}}}}}
      """)
    let before = try fixture.hash()
    let result = try SourceImport.previewRulesync(
      configs: [fixture.input(.rulesyncConfig, "rulesync.jsonc")],
      locks: [fixture.input(.rulesyncSourcesV1, "rulesync.lock")])
    #expect(try fixture.hash() == before)
    #expect(
      result.sources.filter { !$0.alias.contains("-skill-") }.map(\.pin.commit) == [
        String(repeating: "c", count: 40), String(repeating: "a", count: 40),
      ])
    #expect(result.resources.map(\.selected) == [true, false])
    #expect(result.components.count == 1)
    #expect(
      result.components.first?.declaration
        == .skills(source: "rulesync-source-0-skill-0", .init(select: .names(["review"]))))
    #expect(result.resources.map(\.sourceAlias) == ["rulesync-source-0", "rulesync-source-1"])
    #expect(result.resources.allSatisfy { $0.requiresStandaloneSource })
  }

  @Test func npmConfigRetainsRegistryAndSymbolicBindingWithoutConsultingEnvironment() throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write(
      "config.jsonc",
      "{\"sources\":[{\"source\":\"@acme/pkg\",\"transport\":\"npm\",\"ref\":\"latest\",\"registry\":\"https://registry.example\",\"tokenEnv\":\"IMPORT_PRIVATE_TOKEN\"}]}"
    )
    let result = try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"))
    #expect(result.orderedSources.first?.registry == "https://registry.example")
    #expect(result.sources.first?.registry == "https://registry.example")
    #expect(result.sources.first?.requestedRef == "latest")
    #expect(result.bindings.first?.environmentVariable == "IMPORT_PRIVATE_TOKEN")
    #expect(result.sources.first?.pin.commit == nil)
    #expect(result.sources.first?.pin.version == nil)
    #expect(result.diagnostics.contains { $0.code == .incompletePin })
    #expect(result.components.isEmpty)
  }

  @Test func repeatedRepositoryQualifiersUseExplicitConfigFieldsAndOccurrenceOrder() throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write(
      "config.jsonc",
      """
      {"sources":[{"source":"acme/repo", "path":"skills/a", "ref":"team/release"},
       {"source":"acme/repo", "path":"skills/a", "ref":"team/release"}]}
      """)
    let hash = String(repeating: "a", count: 40)
    try fixture.write(
      "lock.json",
      """
      {"lockfileVersion":1,"sources":{
       "acme/repo#path=skills/a&ref=team/release":{"requestedRef":"team/release","resolvedRef":"\(hash)","skillsPath":"skills/a","skills":{}},
       "acme/repo#path=skills/a&ref=team/release&entry=2":{"requestedRef":"team/release","resolvedRef":"\(hash)","skillsPath":"skills/a","skills":{}}}}
      """)
    let result = try SourceImport.previewRulesync(
      configs: [fixture.input(.rulesyncConfig, "config.jsonc")],
      locks: [fixture.input(.rulesyncSourcesV1, "lock.json")])
    #expect(result.sources.count == 2)
    #expect(result.sources.allSatisfy { $0.pin.commit == hash })
    #expect(
      !result.diagnostics.contains { $0.code == .ambiguousSource || $0.code == .incompletePin })
  }

  @Test func embeddedRulesyncSelectorPreservesExplicitSourceAndLockedResources() throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write(
      "config.jsonc", #"{"sources":[{"source":"acme/repo@main:skills"}]}"#)
    let commit = String(repeating: "a", count: 40)
    try fixture.write(
      "lock.json",
      """
      {"lockfileVersion":1,"sources":{"acme/repo@main:skills":{
        "requestedRef":"main","resolvedRef":"\(commit)","skillsPath":"skills",
        "skillSelection":["*"],"skills":{"review":{"integrity":"sha256-\(String(repeating: "b", count: 64))"}}}}}
      """)
    let before = try fixture.hash()
    var lock = fixture.input(.rulesyncSourcesV1, "lock.json")
    lock.sourceDeclarations = [
      "acme/repo@main:skills": .init(kind: .git, location: "https://github.com/acme/repo")
    ]
    let standalone = try SourceImport.preview(lock)
    let ordered = try SourceImport.previewRulesync(
      configs: [fixture.input(.rulesyncConfig, "config.jsonc")], locks: [lock])
    for result in [standalone, ordered] {
      #expect(result.bindings.isEmpty)
      #expect(result.sources.first?.producerIdentity == "acme/repo@main:skills")
      #expect(result.sources.first?.pin.commit == commit)
      #expect(result.sources.first?.requestedRef == "main")
      #expect(result.sources.last?.declaration?.location == "https://github.com/acme/repo")
      #expect(result.sources.last?.declaration?.requirement == .revision(commit))
      #expect(result.resources.map(\.path) == ["skills/review"])
      #expect(
        result.resources.first?.producerIntegrity?.value == "sha256-"
          + String(repeating: "b", count: 64))
      #expect(result.components.count == 1)
      #expect(
        !result.diagnostics.contains { $0.code == .ambiguousSource || $0.code == .incompletePin })
    }
    #expect(try fixture.hash() == before)
  }

  @Test func staleLockCannotBroadenCurrentSourceIntent() throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write(
      "config.jsonc", #"{"sources":[{"source":"acme/repo","ref":"new","skills":["*"]}]}"#)
    try fixture.write(
      "lock.json",
      "{\"lockfileVersion\":1,\"sources\":{\"acme/repo\":{\"requestedRef\":\"old\",\"resolvedRef\":\"\(String(repeating: "a", count: 40))\",\"skillsPath\":\"skills\",\"skillSelection\":[\"*\"],\"skills\":{\"review\":{\"integrity\":\"sha256-\(String(repeating: "b", count: 64))\"}}}}}"
    )
    let stale = try SourceImport.previewRulesync(
      configs: [fixture.input(.rulesyncConfig, "config.jsonc")],
      locks: [fixture.input(.rulesyncSourcesV1, "lock.json")])
    #expect(stale.sources.first?.pin.commit == nil)
    #expect(stale.resources.isEmpty)
    #expect(stale.components.isEmpty)
    #expect(stale.diagnostics.contains { $0.code == .ambiguousSource })
  }

  @Test(arguments: [
    #""skills":[]"#, #""rules":[]"#, #""skills":[],"rules":[]"#,
    #""skills":["*"],"rules":[]"#, #""skills":[],"rules":["*"]"#,
  ])
  func emptySelectionInvalidatesWholeRemoteSource(_ fields: String) throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write("config.jsonc", "{\"sources\":[{\"source\":\"acme/repo\",\(fields)}]}")
    try fixture.write(
      "lock.json",
      """
      {"lockfileVersion":1,"sources":{"acme/repo":{"resolvedRef":"\(String(repeating: "a", count: 40))",
        "skillsPath":"skills","skillSelection":["*"],"skills":{"review":{"integrity":"sha256-\(String(repeating: "b", count: 64))"}},
        "rulesPath":"rules","rules":{"overview":{"integrity":"sha256-\(String(repeating: "c", count: 64))"}}}}}
      """)
    let before = try fixture.hash()
    let result = try SourceImport.previewRulesync(
      configs: [fixture.input(.rulesyncConfig, "config.jsonc")],
      locks: [fixture.input(.rulesyncSourcesV1, "lock.json")])
    #expect(result.sources.isEmpty)
    #expect(result.orderedSources.isEmpty)
    #expect(result.resources.isEmpty)
    #expect(result.components.isEmpty)
    #expect(
      result.diagnostics.contains {
        $0.code == .invalidInput && $0.location.document == "config.jsonc"
          && ["/sources/0/skills", "/sources/0/rules"].contains($0.location.pointer)
      })
    #expect(try fixture.hash() == before)
  }

  @Test func defaultGitHubCredentialsAndUnknownTokenRequireBindingsWithoutLiterals() throws {
    let fixture = try ImportProfileFixture()
    try fixture.directory(".rulesync")
    try fixture.write(
      "config.jsonc",
      #"{"sources":[{"source":"https://user:SECRET_LOCATOR@github.com/acme/repo"},{"source":"acme/repo","token":"SECRET_FIELD"}]}"#
    )
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"))
    #expect(
      result.bindings.map(\.location.pointer) == ["/sources/0/source", "/sources/1/member[1]"])
    #expect(result.bindings.allSatisfy { $0.environmentVariable == nil })
    #expect(
      result.diagnostics.contains { $0.code == .unconverted && $0.location.pointer == "/sources/0" }
    )
    #expect(
      result.diagnostics.contains {
        $0.code == .unconverted && $0.location.pointer == "/sources/1/member[1]"
      })
    #expect(result.sources.map(\.producerIdentity) == ["acme/repo"])
    #expect(!String(reflecting: result).contains("SECRET_LOCATOR"))
    #expect(!String(reflecting: result).contains("SECRET_FIELD"))
    #expect(try fixture.hash() == before)
  }

  @Test func nativeInputConflictsAndYAMLCredentialLocatorsStayExplicit() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write("bad.jsonc", "{\"targets\":{},\"features\":[]}")
    let conflict = try SourceImport.preview(fixture.input(.rulesyncConfig, "bad.jsonc"))
    #expect(conflict.diagnostics.last?.code == .invalidInput)
    #expect(conflict.diagnostics.last?.location.span?.line == 1)
    try fixture.write(
      "bad.yml",
      "lockfile_version: '2'\ndependencies:\n  - repo_url: acme/archive\n    source: registry\n    version: '1.0.0'\n    resolved_hash: sha256:\(String(repeating: "a", count: 64))\n    resolved_url: https://user:secret-sentinel@registry.example/archive\n"
    )
    let secret = try SourceImport.preview(fixture.input(.apmLock, "bad.yml"))
    #expect(secret.sources.first?.resolvedURL == nil)
    #expect(!secret.bindings.isEmpty)
    #expect(secret.diagnostics.contains { $0.code == .incompletePin })
    #expect(!String(reflecting: secret).contains("secret-sentinel"))
    try fixture.write("bad.yml", "lockfile_version: '3'\ndependencies: []\n")
    try fixture.write(
      "installed/review/SKILL.md", "---\nname: review\ndescription: fixture\n---\nprivate\n")
    var request = fixture.input(.apmLock, "bad.yml")
    request.installedSkills = ["review": "installed/review"]
    let unsupported = try SourceImport.preview(request)
    #expect(unsupported.resources.isEmpty)
    #expect(unsupported.components.isEmpty)
  }

  @Test func localCuratedAndInputRootCollisionsSelectActualContent() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write("config.jsonc", "{\"inputRoots\":[\"one\",\"two\"]}")
    for (path, body) in [
      ("one/skills/.curated/review/SKILL.md", "curated-one"),
      ("one/skills/review/SKILL.md", "local-one"),
      ("two/skills/.curated/review/SKILL.md", "curated-two"),
      ("two/skills/review/SKILL.md", "local-two"),
      ("one/rules/.curated/overview.md", "curated-rule"),
      ("one/rules/overview.md", "local-rule"),
    ] { try fixture.write(path, "---\nname: review\ndescription: fixture\n---\n\(body)\n") }
    let before = try fixture.hash()
    let result = try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"))
    #expect(try fixture.hash() == before)
    #expect(result.resources.count == 2)
    let skill = try #require(result.resources.first { $0.kind == .skills })
    #expect(skill.path == ".")
    #expect(skill.observedHash != nil)
    #expect(result.sources.last?.declaration?.location == "two/skills/review")
    #expect(result.components.count == 1)
    #expect(result.diagnostics.filter { $0.message.contains("precedence") }.count == 4)
  }

  @Test func unknownSecretFieldsAndJSONCDuplicatesCannotEscape() throws {
    let fixture = try ImportProfileFixture()
    try fixture.write("config.jsonc", "{\"future\":{\"env\":{\"TOKEN\":\"secret-sentinel\"}}}")
    let result = try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"))
    #expect(!result.bindings.isEmpty)
    #expect(!String(reflecting: result).contains("secret-sentinel"))
    try fixture.write("duplicate.jsonc", "{\"sources\":[], /* keep */ \"\\u0073ources\":[]}")
    let duplicate = try SourceImport.preview(fixture.input(.rulesyncConfig, "duplicate.jsonc"))
    #expect(duplicate.sources.isEmpty)
    #expect(duplicate.diagnostics.last?.code == .invalidInput)
    var limits = SourceImportLimits()
    limits.documentBytes = 5
    #expect(
      try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"), limits: limits)
        .diagnostics.last?.code == .invalidInput)
  }

  @Test(arguments: ["alias", "entries", "bytes", "depth"])
  func capturedContentAdmissionRejectsMaliciousYAMLAndExceededBudgets(_ kind: String) throws {
    let fixture = try ImportProfileFixture()
    try fixture.write("lock.yml", "lockfile_version: '1'\ndependencies: []\n")
    let header =
      kind == "alias"
      ? "name: &hidden review\ndescription: *hidden\n"
      : "name: review\ndescription: fixture\nx-depth: [[[deep]]]\n"
    try fixture.write("installed/review/SKILL.md", "---\n" + header + "---\nbody\n")
    var limits = SourceImportLimits()
    if kind == "entries" { limits.resourceEntries = 1 }
    if kind == "bytes" { limits.resourceBytes = 10 }
    if kind == "depth" { limits.depth = 2 }
    var input = fixture.input(.apmLock, "lock.yml")
    input.installedSkills = ["review": "installed/review"]
    let before = try fixture.hash()
    let result = try SourceImport.preview(input, limits: limits)
    #expect(try fixture.hash() == before)
    #expect(result.resources.isEmpty)
    #expect(result.components.isEmpty)
    #expect(result.diagnostics.contains { $0.code == .missingResource })
    #expect(!String(reflecting: result).contains("hidden"))
  }

  @Test func inputRootsCannotEscapeOrReadLinkedContentOutsideBoundary() throws {
    let fixture = try ImportProfileFixture()
    let outside = try ImportProfileFixture()
    try outside.write(
      "skills/review/SKILL.md", "---\nname: review\ndescription: fixture\n---\nprivate\n")
    try fixture.write("config.jsonc", "{\"inputRoots\":[\"../outside\"]}")
    let traversal = try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"))
    #expect(traversal.diagnostics.contains { $0.code == .unsafePath })
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("linked"), withDestinationURL: outside.root)
    try fixture.write("config.jsonc", "{\"inputRoots\":[\"linked\"]}")
    let before = try outside.hash()
    let linked = try SourceImport.preview(fixture.input(.rulesyncConfig, "config.jsonc"))
    #expect(linked.resources.isEmpty)
    #expect(linked.diagnostics.contains { $0.code == .unsafePath })
    #expect(try outside.hash() == before)
  }
}

private final class ImportProfileFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "import-profiles-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func directory(_ path: String) throws {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(path), withIntermediateDirectories: true)
  }
  func write(_ path: String, _ text: String) throws {
    try directory((path as NSString).deletingLastPathComponent)
    try Data(text.utf8).write(to: root.appendingPathComponent(path))
  }
  func input(_ profile: SourceImportProfile, _ document: String) -> SourceImportInput {
    .init(profile: profile, root: root, document: document)
  }
  func hash() throws -> String { try FileHash.folderHash(root) }
}
