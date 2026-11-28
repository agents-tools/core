import AgentsCore
import Foundation
import Testing

struct SourceAccessSettingsEditorTests {
  private static let direct = Data("version: 1\negress: directAllowed\n".utf8)
  private static let proxy = Data("version: 1\negress: proxyOnly\n".utf8)

  @Test func absentReadRepairAndResetUseTheSameUserPath() throws {
    let home = try temporaryDirectory()
    defer { removeTemporaryDirectory(home) }
    let environment = RuntimeEnvironment(environment: ["HOME": home.path])
    let empty = try SourceAccessSettingsEditor(environment: environment)
    #expect(empty.url.path == home.appendingPathComponent(".agents/source-access.yaml").path)
    #expect(empty.original == nil)
    #expect(try empty.inspect() == nil)
    try empty.save(empty.preview(nil))
    #expect(!FileManager.default.fileExists(atPath: empty.url.deletingLastPathComponent().path))

    let proposal = try empty.preview(Self.proxy)
    #expect(proposal.profile?.egress == .proxyOnly)
    #expect(proposal.hasChanges)
    #expect(!FileManager.default.fileExists(atPath: empty.url.path))
    try empty.save(proposal)
    #expect(try Data(contentsOf: empty.url) == Self.proxy)
    let attributes = try FileManager.default.attributesOfItem(atPath: empty.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    let malformed = Data("version: 1\negress: typo\n".utf8)
    try malformed.write(to: empty.url, options: .atomic)
    let broken = try SourceAccessSettingsEditor(environment: environment)
    #expect(broken.original == malformed)
    #expect(throws: SourceAccessSettingsError.self) { try broken.inspect() }
    try broken.save(broken.preview(Self.direct))
    let repaired = try SourceAccessSettingsEditor(environment: environment)
    #expect(try repaired.inspect()?.egress == .directAllowed)
    #expect(try !repaired.preview(Self.direct).hasChanges)

    let oversized = Data(repeating: 0x20, count: 65_537)
    try oversized.write(to: empty.url, options: .atomic)
    let oversizedEditor = try SourceAccessSettingsEditor(environment: environment)
    #expect(throws: SourceAccessSettingsError.self) { try oversizedEditor.inspect() }
    let reset = try oversizedEditor.preview(nil)
    #expect(reset.hasChanges)
    try oversizedEditor.save(reset)
    #expect(!FileManager.default.fileExists(atPath: empty.url.path))
  }

  @Test func simultaneousPreviewsCanOnlyPublishOneGeneration() async throws {
    let home = try temporaryDirectory()
    defer { removeTemporaryDirectory(home) }
    let environment = RuntimeEnvironment(environment: ["HOME": home.path])
    let first = try SourceAccessSettingsEditor(environment: environment)
    let second = try SourceAccessSettingsEditor(environment: environment)
    let direct = try first.preview(Self.direct)
    let proxy = try second.preview(Self.proxy)
    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { writers in
      for (editor, proposal) in [(first, direct), (second, proxy)] {
        writers.addTask {
          do {
            try editor.save(proposal)
            return true
          } catch SourceAccessSettingsError.changed {
            return false
          } catch {
            Issue.record("Unexpected save error: \(error)")
            return false
          }
        }
      }
      return await writers.reduce(into: []) { $0.append($1) }
    }
    #expect(results.filter { $0 }.count == 1)
    let saved = try Data(contentsOf: first.url)
    #expect(saved == Self.direct || saved == Self.proxy)
    let reopened = try SourceAccessSettingsEditor(environment: environment)
    let reset = try reopened.preview(nil)

    // Replacing the inode with identical bytes still invalidates a displayed edit.
    try saved.write(to: first.url, options: .atomic)
    #expect(throws: SourceAccessSettingsError.changed(first.url)) {
      try reopened.save(reset)
    }
    #expect(try Data(contentsOf: first.url) == saved)
  }

  @Test(arguments: [
    "profile link", "home link", "directory link", "hard link", "writable",
    "writable directory",
  ])
  func unsafeFileAndAncestryRefuseReadingAndSaving(_ shape: String) throws {
    let root = try temporaryDirectory()
    defer { removeTemporaryDirectory(root) }
    let realHome = root.appendingPathComponent("home")
    let realDirectory = realHome.appendingPathComponent(".agents")
    try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: false)
    let external = root.appendingPathComponent("profile")
    try Self.direct.write(to: external)
    var home = realHome
    if shape == "home link" {
      home = root.appendingPathComponent("redirected-home")
      try FileManager.default.createSymbolicLink(at: home, withDestinationURL: realHome)
    }
    if shape == "directory link" {
      try FileManager.default.createSymbolicLink(at: realDirectory, withDestinationURL: root)
    } else {
      try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
      let file = realDirectory.appendingPathComponent("source-access.yaml")
      if shape == "profile link" {
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
      } else if shape == "hard link" {
        try FileManager.default.linkItem(at: external, to: file)
      } else {
        try Self.direct.write(to: file)
        if shape == "writable" {
          try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        } else if shape == "writable directory" {
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: realDirectory.path)
        }
      }
    }
    let environment = RuntimeEnvironment(environment: ["HOME": home.path])
    #expect(
      throws: SourceAccessSettingsError.unsafeLocation(
        SourceAccessSettingsEditor.settingsURL(environment: environment))
    ) {
      try SourceAccessSettingsEditor(environment: environment)
    }
    #expect(try Data(contentsOf: external) == Self.direct)
  }

  @Test(arguments: [
    "",
    "version: 1",
    "version: 1\negress: auto",
    "version: 1\negress: null",
    "version: 1\negress: proxyOnly\negress: directAllowed",
    "version: 1\negress: proxyOnly\n---\nversion: 1\negress: directAllowed",
    "version: 1\negress: proxyOnly\nmirrors: [unexpected]",
    "version: 1\negress: proxyOnly\nmirrors: [{source: {host: github.com}, base: 'http://mirror.invalid', flavor: github}]",
    "version: 1\negress: proxyOnly\nmirrors: [{source: {host: github.com}, base: 'https://mirror.invalid/%2e%2e', flavor: github}]",
    "version: 1\negress: proxyOnly\nmirrors: [{source: {host: github.com}, base: 'https://mirror.invalid', flavor: artifactory}]",
    "version: 1\negress: directAllowed\nproviders: [{host: code.invalid, port: 65536, provider: github}]",
    "version: 1\negress: directAllowed\nproviders: [{host: code.invalid, provider: gitea}]",
    "version: 1\negress: directAllowed\nproviders: [{host: CODE.invalid, provider: github}, {host: code.invalid, port: 443, provider: gitlab}]",
    "version: 1\negress: directAllowed\ncredentials: [{route: direct, host: github.com, token: SYNTHETIC_VALUE}]",
    "version: 1\negress: directAllowed\ncredentials: [{route: direct, host: github.com, environmentVariable: '$PACKAGE_TOKEN'}]",
    "version: 1\negress: directAllowed\ncredentials: [{route: direct, host: github.com, path: /team/repo.git, environmentVariable: FIRST}, {route: direct, host: github.com, path: /team/repo, environmentVariable: SECOND}]",
    "version: 1\negress: directAllowed\ncredentials: [{route: direct, host: github.com, environmentVariable: PACKAGE_TOKEN, validationEndpoint: 'https://different.invalid/user'}]",
  ])
  func ambiguousOrUnsupportedMetadataIsRejected(_ document: String) {
    #expect(throws: SourceAccessSettingsError.self) {
      try SourceAccessProfile.parse(Data(document.utf8))
    }
  }

  @Test func inspectionExposesOnlyDeclaredMetadata() throws {
    let profile = try SourceAccessProfile.parse(
      Data(
        """
        version: 1
        egress: directAllowed
        providers:
          - host: Code.INVALID
            port: 8443
            provider: gitlab
        mirrors:
          - source: {host: code.invalid, port: 8443}
            base: https://archives.invalid:9443/api-base
            flavor: gitlab
            supportsQualifiedGitLabRefs: true
            requiresExactArchiveBytes: true
        credentials:
          - route: direct
            host: code.invalid
            port: 8443
            path: /org/repo.git
            environmentVariable: SYNTHETIC_PACKAGE_TOKEN
            exportable: true
            validationEndpoint: https://code.invalid:8443/api/v4/user
        """.utf8))
    let authority = try SourceAuthority(host: "code.invalid", port: 8443)
    #expect(profile.providers.first?.authority == authority)
    #expect(profile.providers.first?.provider == .gitlab)
    #expect(profile.mirrors.first?.source == authority)
    #expect(profile.mirrors.first?.supportsQualifiedGitLabRefs == true)
    #expect(profile.mirrors.first?.requiresExactArchiveBytes == true)
    let credential = try #require(profile.credentials.first)
    #expect(credential.authority == authority)
    #expect(credential.path == "/org/repo.git")
    #expect(credential.environmentVariable == "SYNTHETIC_PACKAGE_TOKEN")
    #expect(credential.exportable)
  }
}
