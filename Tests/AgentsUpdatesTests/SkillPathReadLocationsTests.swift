import AgentsCore
import Foundation
import Testing

@testable import AgentsUpdates

struct SkillPathReadLocationsTests {
  @Test func ownSkillPathsKeepNarrowRootAndUnusedGroupDiscovery() throws {
    let f = try UpdateFixture()
    let declaration = Declaration(
      components: [.skills(source: ".", .init(select: .all, path: "selected/one"))],
      groups: [
        .init(
          name: "unused",
          components: [
            .skills(source: ".", .init(select: .names([]), path: "selected/two"))
          ])
      ])
    let paths = try UpdateOperations.readLocations(
      declarations: [declaration], ledgers: [], store: f.store)
    #expect(paths.contains(f.root.appendingPathComponent("selected/one")))
    #expect(paths.contains(f.root.appendingPathComponent("selected/two")))
    #expect(!paths.contains(f.root))
  }
}
