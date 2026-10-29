import AgentsDescription

/// Source overloads share their first two location parameters and defaulted subpath.
/// Their remaining required parameters define the admitted requirement slots.
enum SourceRequirements {
  static let parameters: [ConstructionParameter] = {
    var names = Set<String>()
    return Vocabulary.signatures.filter { $0.type == "Source" }.flatMap {
      $0.parameters.dropFirst(2)
    }.filter { $0.defaultValue == nil && names.insert($0.name).inserted }
  }()

  static let labels = Set(parameters.map(\.label).filter { $0 != "_" })
}
