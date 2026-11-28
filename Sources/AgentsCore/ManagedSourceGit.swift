import Foundation

/// Network Git uses an isolated home and, for fetches, a Core-owned bare configuration.
package struct ManagedSourceGit {
  let repository: SourceRepository
  let binding: SourceCredentialBinding
  let access: SourceAccessConfiguration

  static func select(_ route: SourceRoute, environment: RuntimeEnvironment) throws -> Self? {
    guard case .git(let repository?) = route,
      let binding = try route.credential(environment.sourceAccess)
    else { return nil }
    return Self(repository: repository, binding: binding, access: environment.sourceAccess)
  }

  func command(
    _ arguments: [String], lock: Int32? = nil, in mirror: URL? = nil
  ) throws -> ProcessOutput {
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let parent = try DirectoryHandle(at: temporary)
    let name = "agents-source-git-" + UUID().uuidString
    let workspace = try parent.createPrivateDirectory(name)
    defer { try? FileManager.default.removeItem(at: workspace.url) }
    var environment = ProcessRunner.isolatedGitEnvironment(in: workspace.url, network: true)
    environment["GIT_CEILING_DIRECTORIES"] = temporary.path

    let context: [String]
    let ancestry: DirectoryAccessEvidence?
    if let mirror {
      ancestry = try DirectoryAccessEvidence.capture(at: mirror)
      let directory = try DirectoryHandle(at: mirror)
      let config = try directory.read("config", maximumBytes: 4096)
      guard
        config == controlledConfiguration(sha256: false)
          || config == controlledConfiguration(sha256: true)
      else { throw SourceAccessError.routeChanged }
      context = ["--git-dir=" + mirror.path]
    } else {
      ancestry = nil
      context = []
    }

    var options =
      ProcessRunner.isolatedGitOptions + [
        "-c", "credential.useHttpPath=true", "-c", "credential.interactive=false",
        "-c", "fetch.recurseSubmodules=false", "-c", "submodule.recurse=false",
      ]
    if let certificate = GitAcquisition.fixtureCertificateAuthority {
      options += ["-c", "http.sslCAInfo=" + certificate.path]
    }
    let effective = try ProcessRunner.execute(
      "/usr/bin/git",
      arguments: options + context + ["ls-remote", "--get-url", "--", repository.url],
      workingDirectory: workspace.url, environment: environment, lock: lock)
    guard effective.exitCode == 0,
      effective.stdout.trimmingCharacters(in: .newlines).utf8.elementsEqual(repository.url.utf8)
    else { throw SourceAccessError.routeChanged }

    let fifo = workspace.url.appendingPathComponent("credential.pipe").path
    guard mkfifo(fifo, 0o600) == 0 else { throw SourceAccessError.requestFailed }
    let descriptor = open(fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw SourceAccessError.requestFailed }
    defer { close(descriptor) }
    try access.requireCurrentSettings()
    let secret = Data((try binding.value() + "\n").utf8)
    guard secret.withUnsafeBytes({ write(descriptor, $0.baseAddress, $0.count) }) == secret.count
    else { throw SourceAccessError.credentialUnavailable }

    let url = URLComponents(string: repository.url)!
    environment["AGENTS_SOURCE_GIT_HOST"] = url.host! + (url.port.map { ":\($0)" } ?? "")
    environment["AGENTS_SOURCE_GIT_PATH"] = String(repository.gitPath.dropFirst())
    environment["AGENTS_SOURCE_GIT_PIPE"] = fifo
    environment["AGENTS_SOURCE_GIT_USER"] = binding.gitUsername
    var network = options
    network += ["-c", "credential.helper=" + Self.helper]
    if let mirror { try ancestry?.validate(at: mirror) }
    let output = try ProcessRunner.execute(
      "/usr/bin/git", arguments: network + context + arguments,
      workingDirectory: workspace.url, environment: environment, lock: lock)
    guard output.exitCode == 0 else { throw SourceAccessError.requestFailed }
    return ProcessOutput(stdout: output.stdout, stderr: "", exitCode: 0)
  }

  func sealClonedConfiguration(_ mirror: URL) throws {
    let directory = try DirectoryHandle(at: mirror)
    let generated = try directory.read("config", maximumBytes: 4096)
    let sha256 = String(decoding: generated, as: UTF8.self).contains("objectformat = sha256")
    try directory.replaceFile(
      "config", through: "agents-config", with: controlledConfiguration(sha256: sha256),
      afterWrite: {}, afterRename: {})
  }

  private func controlledConfiguration(sha256: Bool) -> Data {
    var value = "[core]\n\trepositoryformatversion = \(sha256 ? 1 : 0)\n\tbare = true\n"
    if sha256 { value += "[extensions]\n\tobjectformat = sha256\n" }
    let quoted = repository.url.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    value += "[remote \"origin\"]\n\turl = \"\(quoted)\"\n"
    return Data(value.utf8)
  }

  // Git appends the action as an argument. Git and other subprocesses never inherit the
  // credential descriptor. The helper opens it only after matching the complete context.
  private static let helper = #"""
    !f() {
      [ "$1" = get ] || exit 0
      protocol= host= path=
      while IFS= read -r line && [ -n "$line" ]; do
        case "$line" in
          protocol=*) protocol=${line#protocol=} ;;
          host=*) host=${line#host=} ;;
          path=*) path=${line#path=} ;;
        esac
      done
      [ "$protocol" = https ] &&
        [ "$host" = "$AGENTS_SOURCE_GIT_HOST" ] &&
        [ "$path" = "$AGENTS_SOURCE_GIT_PATH" ] || exit 0
      IFS= read -r password < "$AGENTS_SOURCE_GIT_PIPE" || exit 1
      printf 'username=%s\npassword=%s\n' "$AGENTS_SOURCE_GIT_USER" "$password"
    }; f
    """#
}
