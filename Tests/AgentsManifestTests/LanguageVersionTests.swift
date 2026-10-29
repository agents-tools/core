import AgentsCore
import Testing

@testable import AgentsManifest

@Suite("Manifest language version")
struct LanguageVersionTests {
  @Test func directiveDiagnosticsAreLexicalAndDistinct() throws {
    for (text, code) in [
      ("import AgentsDescription\nlet agents = Agents()", "manifest.version.missing"),
      (
        "// agents-tools-version: 01.0\nimport AgentsDescription\nlet agents = Agents()",
        "manifest.version.invalid"
      ),
      (
        "// agents-tools-version: 1.0 \nimport AgentsDescription\nlet agents = Agents()",
        "manifest.version.invalid"
      ),
      (
        "// agents-tools-version: 2.0\nimport AgentsDescription\nlet agents = Agents()",
        "manifest.version.unsupported"
      ),
      (
        manifestHeader + "// agents-tools-version: 1.0\nlet agents = Agents()",
        "manifest.version.duplicate"
      ),
    ] {
      do {
        _ = try DeclarationDocument(bytes: Array(text.utf8), identity: DocumentIdentity("manifest"))
        Issue.record("directive accepted")
      } catch let failure as ManifestFailure {
        #expect(failure.diagnostics[0].code == code)
        #expect(failure.metrics.parserCalls == 0)
      }
    }
    _ = try document("let text = \"// agents-tools-version: 1.0\"\nlet agents = Agents()")
  }

  @Test func versionDirectiveRejectsBareCRBeforeTheParser() throws {
    let directive = "// agents-tools-version: 1.0"
    for suffix in ["\r", "\rimport AgentsDescription\nlet agents = Agents()"] {
      do {
        _ = try DeclarationDocument(
          bytes: Array((directive + suffix).utf8), identity: DocumentIdentity("manifest"))
        Issue.record("bare CR directive accepted")
      } catch let failure as ManifestFailure {
        #expect(failure.diagnostics[0].code == "manifest.version.invalid")
        #expect(failure.metrics.parserCalls == 0)
        #expect(failure.diagnostics[0].span.start == directive.utf8.count)
        #expect(failure.diagnostics[0].span.line == 1)
        #expect(failure.diagnostics[0].span.column == directive.utf8.count + 1)
      }
    }
    for newline in ["\n", "\r\n"] {
      _ = try DeclarationDocument(
        bytes: Array(
          (directive + newline + "import AgentsDescription" + newline + "let agents = Agents()")
            .utf8), identity: DocumentIdentity("manifest"))
    }
    // EOF terminates the directive; the remaining grammar still requires an import.
    expectManifestFailure("manifest.syntax") {
      try DeclarationDocument(bytes: Array(directive.utf8), identity: DocumentIdentity("manifest"))
    }
  }
}
