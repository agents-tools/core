import AgentsCore
import Foundation
import Testing

struct ReadDependencyTests {
  @Test func codableRetainsEntryAndSubtreeAtTheSameURL() throws {
    let url = URL(fileURLWithPath: "/scope/absent")
    let values: [ReadDependency] = [.entry(url), .subtree(url)]
    #expect(Set(values).count == 2)
    #expect(values.map(\.url) == [url, url])
    let bytes = try JSONEncoder().encode(values)
    #expect(try JSONDecoder().decode([ReadDependency].self, from: bytes) == values)
    let expected = Data(
      "[{\"entry\":{\"_0\":\"file:///scope/absent\"}},{\"subtree\":{\"_0\":\"file:///scope/absent\"}}]"
        .utf8)
    #expect(try JSONDecoder().decode([ReadDependency].self, from: expected) == values)
    #expect(
      try JSONSerialization.jsonObject(with: bytes) as? NSArray == JSONSerialization.jsonObject(
        with: expected) as? NSArray)
  }
}
