import AgentsDescription

/// Each Source overload begins with name followed by one location argument.
/// The remaining required parameters define the admitted requirement slots.
enum SourceRequirements {
  private static let signatures = Vocabulary.signatures.filter { $0.type == "Source" }

  static let locations = Set(signatures.compactMap { $0.parameters.dropFirst().first?.label })
  static let locationsWithRequirements = Set(
    signatures.compactMap { signature in
      signature.parameters.dropFirst(2).contains { $0.defaultValue == nil }
        ? signature.parameters.dropFirst().first?.label : nil
    })

  static let parameters: [ConstructionParameter] = {
    var names = Set<String>()
    return signatures.flatMap {
      $0.parameters.dropFirst(2)
    }.filter { $0.defaultValue == nil && names.insert($0.name).inserted }
  }()

  static let labels = Set(parameters.map(\.label).filter { $0 != "_" })
}
