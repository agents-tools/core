/// Language 1.0 front-end bounds, grouped by their owner in the manifest contract.
/// Counts are charged by occurrence, including unused definitions and repeated origins.
package enum ManifestLimits {
  package enum Input {
    package static let bytes = 2_097_152
  }
  enum Admission {
    static let tokens = 100_000
    static let syntaxReservation = 100_000
    static let reservationBase = 16
    static let reservationPerUnit = 4
    static let squareDepth = 8
    static let delimiterDepth = 20
    static let commentDepth = 20
    static let additiveTerms = 32
  }
  enum Syntax {
    static let parserNesting = 20
    static let depth = 128
    static let nodes = 100_000
  }
  enum Evaluation {
    static let frames = 64
    static let steps = 100_000
  }
  enum Values {
    static let nodes = 100_000
    static let stringBytes = 16_777_216
    static let entries = 10_000
    static let depth = 64
  }
  enum Domain {
    static let steps = 100_000
  }
  enum Groups {
    static let activeReferences = 64
  }
  enum SourceMap {
    static let locations = 100_000
    static let origins = 1_000_000
    static let encodedBytes = 16_777_216
  }
  enum Output {
    static let encodedBytes = 33_554_432
  }
  enum Editing {
    static let comparisonPairs = 200_000
    static let steps = 1_000_000
    static let requests = 100
  }
  enum Diagnostics {
    static let warnings = 100
  }
}
