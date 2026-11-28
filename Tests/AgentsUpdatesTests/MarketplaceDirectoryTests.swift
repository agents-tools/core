import AgentsCore
import AgentsUpdates
import Foundation
import Testing

@Suite struct MarketplaceDirectoryTests {
  @Test func scopedCatalogsResolveAtTheirOwnerAndRevealInheritedRegistrationOnRemoval() throws {
    let f = try UpdateFixture()
    let env = f.environment
    let user = try MarketplaceRegistration(
      name: "tools", origin: .init(kind: .directory, location: "team"))
    let project = try MarketplaceRegistration(
      name: "tools",
      origin: .init(kind: .git, location: "./producer", ref: "stable", subpath: "market"))
    #expect(try MarketplaceDirectory.list(scope: .project, environment: env).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: f.store.directory.path))
    try MarketplaceDirectory.register(user, scope: .user, environment: env)
    let inherited = try MarketplaceDirectory.lookup("tools", scope: .project, environment: env)
    #expect(inherited.origin.location == env.homeDirectory.appendingPathComponent("team").path)
    try MarketplaceDirectory.register(project, scope: .project, environment: env)
    #expect(
      try MarketplaceDirectory.list(scope: .project, environment: env).map(\.scope) == [.project])
    #expect(try MarketplaceDirectory.lookup("tools", scope: .project, environment: env) == project)
    try MarketplaceDirectory.register(project, scope: .project, environment: env)
    #expect(throws: MarketplaceError.self) {
      try MarketplaceDirectory.register(user, scope: .project, environment: env)
    }
    try MarketplaceDirectory.unregister("tools", scope: .project, environment: env)
    #expect(
      try MarketplaceDirectory.lookup("tools", scope: .project, environment: env) == inherited)
    #expect(!FileManager.default.fileExists(atPath: f.store.resolvedURL.path))
    let file = f.store.directory.appendingPathComponent("marketplaces.yaml")
    try Data("tools: {git: https://example.com/a/b, ref: main, unknown: true}\n".utf8).write(
      to: file)
    #expect(throws: MarketplaceError.self) {
      try MarketplaceDirectory.list(scope: .project, environment: env)
    }
  }
}
