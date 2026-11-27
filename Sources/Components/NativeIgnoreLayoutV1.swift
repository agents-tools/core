import AgentsCore

/// Patterns form an ordered managed-block contribution for E's ignore preparation.
/// This renderer does not own a second ignore editor or infer ownership from matching lines.
enum NativeIgnoreLayoutV1 {
  static func patterns(_ input: ComponentRenderInput) throws -> [String] {
    try (input.fields["patterns"]?.array ?? []).enumerated().map { index, value in
      guard let pattern = value.text, !pattern.isEmpty,
        !pattern.utf8.contains(0), !pattern.utf8.contains(10), !pattern.utf8.contains(13)
      else {
        throw input.issue(
          ["patterns", String(index)], .invalid, "ignore pattern must occupy one nonempty line")
      }
      return pattern
    }
  }
}
