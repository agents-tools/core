import AgentsCore
import CPlatform
import Foundation
import Testing

struct AgentClientObservationTests {
  @Test func metadataReadsOrdinarySymlinksAndKeepsVersionAndBuildSeparate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("Editor.app")
    let metadata = bundle.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(
      at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    let source = root.appendingPathComponent("metadata.plist")
    let bytes = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "fixture.editor", "CFBundleShortVersionString": "3.27-preview",
        "CFBundleVersion": "42",
      ], format: .xml, options: 0)
    try bytes.write(to: source)
    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: source)
    let (state, version) = AgentClientObservation.bundleVersion(
      at: bundle, identifier: "fixture.editor")
    #expect(state == .present)
    #expect(version.version == "3.27-preview")
    #expect(version.build == "42")
    #expect(version.unknown == nil)
    #expect(version.metadata == metadata)
    #expect(
      AgentClientObservation.bundleVersion(at: bundle, identifier: "another.editor").0 == .invalid)
  }

  @Test func metadataFailuresAreBoundedAndDoNotReadNonRegularObjects() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing")
    #expect(throws: ClientVersionUnknownError.self) { try AgentClientObservation.metadata(missing) }
    let oversized = root.appendingPathComponent("oversized")
    try Data(repeating: 1, count: 1_048_577).write(to: oversized)
    do {
      _ = try AgentClientObservation.metadata(oversized)
      Issue.record("oversized metadata was admitted")
    } catch let error as ClientVersionUnknownError { #expect(error.reason == .oversizedMetadata) }
    let pipe = root.appendingPathComponent("pipe")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    do {
      _ = try AgentClientObservation.metadata(pipe)
      Issue.record("FIFO metadata was admitted")
    } catch let error as ClientVersionUnknownError { #expect(error.reason == .nonRegularMetadata) }
    let bundle = root.appendingPathComponent("Broken.app")
    let plist = bundle.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(
      at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: pipe)
    let nonRegular = AgentClientObservation.bundleVersion(at: bundle, identifier: "fixture")
    #expect(nonRegular.0 == .invalid)
    #expect(nonRegular.1.unknown == .nonRegularMetadata)
    try FileManager.default.removeItem(at: plist)
    try Data("invalid plist".utf8).write(to: plist)
    #expect(
      AgentClientObservation.bundleVersion(at: bundle, identifier: "fixture").1.unknown
        == .malformedMetadata)
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "fixture", "CFBundleVersion": "11"],
      format: .binary, options: 0
    ).write(to: plist)
    let observation = AgentClientObservation.bundleVersion(at: bundle, identifier: "fixture").1
    #expect(observation.unknown == .missingVersion)
    #expect(observation.build == "11")
  }
}
