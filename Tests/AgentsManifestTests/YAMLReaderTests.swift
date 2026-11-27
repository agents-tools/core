import AgentsCore
import AgentsManifest
import Testing

struct YAMLReaderTests {
  @Test func readerRetainsOrderedDataAndYAML12ScalarIdentity() throws {
    let reader = try YAMLReader(
      bytes: Array(
        "name: on\r\nquoted: 'true'\r\nflag: true\r\nnumber: 0x10\r\né: [one, two]\r\n".utf8),
      identity: .init("producer.yml"))
    let pairs = try #require(reader.root.pairs)
    #expect(pairs.map { $0.key.text } == ["name", "quoted", "flag", "number", "é"])
    #expect(pairs[0].value.scalar?.text == "on")
    #expect(pairs[0].value.scalar?.quoted == false)
    #expect(pairs[1].value.scalar?.text == "true")
    #expect(pairs[1].value.scalar?.quoted == true)
    #expect(YAMLScalar.classify("on") == .string)
    #expect(YAMLScalar.classify("true") == .boolean)
    #expect(YAMLScalar.integer("0x10") == 16)
    #expect(pairs[4].value.items?.compactMap(\.text) == ["one", "two"])
    let span = reader.span(of: pairs[4].value)
    #expect(span.document == .init("producer.yml"))
    #expect(span.line == 5)
    #expect(span.column == 5)
    #expect(
      Array("name: on\r\nquoted: 'true'\r\nflag: true\r\nnumber: 0x10\r\né: ".utf8).count
        == span.start)
  }

  @Test(arguments: [
    "token: secret-sentinel\n\"\\u0074oken\": secret-sentinel\n",
    "token: secret-sentinel\ntoken: secret-sentinel\n",
    "token: &secret-sentinel value\nother: *secret-sentinel\n",
    "token: !secret-sentinel value\n",
    "true: secret-sentinel\n",
  ])
  func readerRefusesUnsupportedOrAmbiguousDataWithValueFreeLocatedFailure(_ text: String) throws {
    do {
      _ = try YAMLReader(bytes: Array(text.utf8), identity: .init("chosen.yml"))
      Issue.record("Expected YAML admission failure")
    } catch let failure as YAMLReadFailure {
      #expect(failure.span.document == .init("chosen.yml"))
      #expect(failure.span.line >= 1)
      #expect(failure.span.start <= text.utf8.count)
      #expect(!String(reflecting: failure).contains("secret-sentinel"))
      #expect(failure.description == "YAML input is not admitted.")
    }
  }
}
