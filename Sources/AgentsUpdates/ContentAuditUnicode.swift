import Foundation

struct ContentAuditScalar {
  let codePoint: UInt32
  let reason: ContentAuditReason
  let severity: ContentAuditSeverity
  let byteRange: Range<Int>
  let line: Int
  let column: Int
}

enum ContentAuditUnicode {
  // Keeping diagnostics bounded also keeps a reviewed edit from silently omitting bytes.
  static let maximumFindings = 16_384

  static func scan(_ text: String, leadingBOM: Bool) throws -> [ContentAuditScalar] {
    var findings: [ContentAuditScalar] = []
    var bytes = 0
    var cursor = Coordinates()
    var previous: Unicode.Scalar?
    let contextualZWNJ = joiningOffsets(in: text)
    var utf16Offset = 0
    for character in text {
      let cluster = character.unicodeScalars
      let emojiTag = isStandardFlag(cluster)
      for index in cluster.indices {
        let scalar = cluster[index]
        let length = scalar.utf8.count
        let nextIndex = cluster.index(after: index)
        let next = nextIndex == cluster.endIndex ? nil : cluster[nextIndex]
        let position = cursor.position(for: scalar)
        if let (reason, severity) = classify(
          scalar, previous: previous, next: next, cluster: cluster, emojiTag: emojiTag,
          leadingBOM: leadingBOM && bytes == 0,
          joiningContext: contextualZWNJ.contains(utf16Offset))
        {
          guard findings.count < maximumFindings else {
            throw ContentAuditProblem.unsupportedContent
          }
          findings.append(
            .init(
              codePoint: scalar.value, reason: reason, severity: severity,
              byteRange: bytes..<bytes + length, line: position.line, column: position.column))
        }
        utf16Offset += scalar.value > 0xffff ? 2 : 1
        bytes += length
        previous = scalar
      }
    }
    return findings
  }

  static func coordinates(
    in text: String, at offsets: [Int]
  ) -> [Int: (line: Int, column: Int)] {
    let ordered = Set(offsets).sorted()
    var positions: [Int: (Int, Int)] = [:]
    var index = 0
    var byte = 0
    var cursor = Coordinates()
    for scalar in text.unicodeScalars {
      guard index < ordered.count else { break }
      let position = cursor.position(for: scalar)
      if byte == ordered[index] {
        positions[byte] = position
        index += 1
      }
      byte += scalar.utf8.count
    }
    if index < ordered.count, byte == ordered[index] {
      positions[byte] = (cursor.line, cursor.column)
    }
    return positions
  }

  private struct Coordinates {
    var line = 1
    var column = 1
    var afterCR = false

    mutating func position(for scalar: Unicode.Scalar) -> (line: Int, column: Int) {
      let current = (line, column)
      if scalar == "\r" || scalar == "\n" {
        if scalar == "\r" || !afterCR { line += 1 }
        column = 1
      } else {
        column += scalar.value > 0xffff ? 2 : 1
      }
      afterCR = scalar == "\r"
      return current
    }
  }

  private static func classify(
    _ scalar: Unicode.Scalar, previous: Unicode.Scalar?, next: Unicode.Scalar?,
    cluster: Character.UnicodeScalarView, emojiTag: Bool, leadingBOM: Bool, joiningContext: Bool
  ) -> (ContentAuditReason, ContentAuditSeverity)? {
    switch scalar.value {
    case 0xe0001...0xe007f:
      return emojiTag ? (.emojiTagSequence, .info) : (.tagCharacter, .critical)
    case 0x202a...0x202e, 0x2066...0x2069: return (.bidiControl, .critical)
    case 0xe0100...0xe01ef: return (.supplementaryVariationSelector, .critical)
    case 0x200c, 0x200d:
      let virama = previous?.properties.canonicalCombiningClass.rawValue == 9
      let emojiJoin = scalar.value == 0x200d && isEmojiJoin(previous, next, cluster: cluster)
      if virama || emojiJoin || joiningContext { return (.contextualJoiner, .info) }
      return (.zeroWidthCharacter, .warning)
    case 0x200b: return (.zeroWidthCharacter, .warning)
    case 0xfe0e where previous?.properties.isEmoji == true, 0xfe0f:
      return (.emojiPresentation, .info)
    case 0xfe00...0xfe0e: return (.variationSelector, .warning)
    case 0x061c, 0x200e, 0x200f: return (.bidiMark, .warning)
    case 0x2061...0x2064: return (.invisibleOperator, .warning)
    case 0xfff9...0xfffb: return (.annotationMarker, .warning)
    case 0x206a...0x206f: return (.deprecatedFormatting, .warning)
    case 0x00ad: return (.softHyphen, .warning)
    case 0xfeff: return leadingBOM ? nil : (.interiorBOM, .warning)
    case 0x0085, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
      return (.unusualWhitespace, .info)
    default: return nil
    }
  }

  private static func isStandardFlag(_ cluster: Character.UnicodeScalarView) -> Bool {
    guard cluster.first?.value == 0x1f3f4, cluster.last?.value == 0xe007f,
      cluster.count == 7
    else { return false }
    let region = cluster.dropFirst().dropLast().map(\.value)
    return region == [0xe0067, 0xe0062, 0xe0065, 0xe006e, 0xe0067]
      || region == [0xe0067, 0xe0062, 0xe0073, 0xe0063, 0xe0074]
      || region == [0xe0067, 0xe0062, 0xe0077, 0xe006c, 0xe0073]
  }

  private static let joiningPattern = try? NSRegularExpression(
    pattern:
      #"(?=[\p{Joining_Type=Left_Joining}\p{Joining_Type=Dual_Joining}]\p{Joining_Type=Transparent}*(\u200C)\p{Joining_Type=Transparent}*[\p{Joining_Type=Right_Joining}\p{Joining_Type=Dual_Joining}])"#
  )

  private static func joiningOffsets(in text: String) -> Set<Int> {
    guard text.unicodeScalars.contains("\u{200c}"), let joiningPattern else { return [] }
    return Set(
      joiningPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
        $0.range(at: 1).location
      })
  }

  private static func isEmojiJoin(
    _ previous: Unicode.Scalar?, _ next: Unicode.Scalar?, cluster: Character.UnicodeScalarView
  ) -> Bool {
    guard let previous, let next, next.value >= 0x00a9, next.properties.isEmoji else {
      return false
    }
    if previous.value >= 0x00a9, previous.properties.isEmoji { return true }
    if previous.value == 0xfe0f {
      return cluster.first.map { $0.value >= 0x00a9 && $0.properties.isEmoji } ?? false
    }
    return false
  }
}

enum ContentAuditProblem: Error {
  case unsupportedContent, outsideScope, unrelatedRepository
}
