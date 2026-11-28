import CPlatform
import Foundation

/// Copies native JSON while interpreting only the selected metadata strings. Conversation
/// bodies pass through the chunk buffer, including strings that span many chunks.
final class BackupJSONStream {
  typealias Rewriter = ([String], String) throws -> String?

  private let source: FileHandle
  private let output: FileHandle?
  private let file: String
  private let selection: Set<[String]>
  private let prefixes: Set<[String]>
  private let rewrite: Rewriter
  // Six JSON bytes can encode one path byte. Larger strings are payload rather than path metadata.
  private static let maximumTokenBytes = 6 * Int(PATH_MAX) + 2
  private var input: [UInt8] = []
  private var cursor = 0
  private var buffer = Data()
  private(set) var changed = false

  init(
    _ source: URL, output: FileHandle? = nil, selection: Set<[String]>,
    rewrite: @escaping Rewriter
  ) throws {
    self.source = try FileHandle(forReadingFrom: source)
    self.output = output
    file = source.lastPathComponent
    self.selection = selection
    prefixes = Set(
      selection.flatMap { path in
        path.indices.map { Array(path.prefix($0)) }
      })
    self.rewrite = rewrite
  }

  func process(records: Bool = false) throws {
    try space()
    if records {
      while try peek() != nil {
        try object([])
        try space()
      }
    } else {
      try object([])
      try space()
      guard try peek() == nil else { throw failure }
    }
    if !buffer.isEmpty { try output?.write(contentsOf: buffer) }
  }

  private var failure: ClientBackupError { .unsupportedLayout(file) }

  private func peek() throws -> UInt8? {
    if cursor == input.count {
      input = Array(try source.read(upToCount: 64 * 1024) ?? Data())
      cursor = 0
    }
    return input.isEmpty ? nil : input[cursor]
  }

  private func emit(_ byte: UInt8) throws {
    guard let output else { return }
    buffer.append(byte)
    if buffer.count == 64 * 1024 {
      try output.write(contentsOf: buffer)
      buffer.removeAll(keepingCapacity: true)
    }
  }

  private func take(copy: Bool = true) throws -> UInt8 {
    guard let next = try peek() else { throw failure }
    cursor += 1
    if copy { try emit(next) }
    return next
  }

  private func expect(_ code: UInt8) throws {
    guard try take() == code else { throw failure }
  }

  private func space() throws {
    while let next = try peek(), [0x20, 0x09, 0x0d, 0x0a].contains(next) { _ = try take() }
  }

  private func string(copy: Bool) throws -> Data? {
    guard try take(copy: copy) == 0x22 else { throw failure }
    var raw: Data? = copy ? nil : Data([0x22])

    func transfer(_ bytes: some Collection<UInt8>) throws {
      if let count = raw?.count, count + bytes.count <= Self.maximumTokenBytes {
        raw?.append(contentsOf: bytes)
      } else {
        if let prefix = raw {
          buffer.append(prefix)
          raw = nil
        }
        if output != nil { buffer.append(contentsOf: bytes) }
        if buffer.count >= 64 * 1024 {
          try output?.write(contentsOf: buffer)
          buffer.removeAll(keepingCapacity: true)
        }
      }
    }

    while try peek() != nil {
      let start = cursor
      while cursor < input.count {
        let byte = input[cursor]
        if byte == 0x22 || byte == 0x5c || byte < 0x20 { break }
        cursor += 1
      }
      if cursor > start { try transfer(input[start..<cursor]) }
      if cursor == input.count { continue }
      let next = try take(copy: false)
      guard next >= 0x20 else { throw failure }
      try transfer(CollectionOfOne(next))
      if next == 0x22 { return raw }
      try transfer(CollectionOfOne(try take(copy: false)))
    }
    throw failure
  }

  private func text(_ bytes: Data) throws -> String {
    guard
      let value = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
        as? String
    else { throw failure }
    return value
  }

  private func metadata(_ path: [String]) throws {
    guard let raw = try string(copy: false) else { return }
    let original = try text(raw)
    let replacement = try rewrite(path, original)
    if let replacement, replacement != original {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      for byte in try encoder.encode(replacement) { try emit(byte) }
      changed = true
    } else {
      for byte in raw { try emit(byte) }
    }
  }

  private func object(_ path: [String]) throws {
    try expect(0x7b)
    try space()
    if try peek() == 0x7d {
      try expect(0x7d)
      return
    }
    while true {
      let raw = try string(copy: false)
      let member: [String]?
      if let raw {
        for byte in raw { try emit(byte) }
        member = try path + [text(raw)]
      } else {
        member = nil
      }
      try space()
      try expect(0x3a)
      try space()
      if let member, try prefixes.contains(member) && peek() == 0x7b {
        try object(member)
      } else if let member, selection.contains(member) {
        try field(member)
      } else {
        try skipValue()
      }
      try space()
      if try peek() == 0x7d {
        try expect(0x7d)
        return
      }
      try expect(0x2c)
      try space()
    }
  }

  private func field(_ path: [String]) throws {
    switch try peek() {
    case 0x22: try metadata(path)
    case 0x5b:
      try expect(0x5b)
      try space()
      if try peek() == 0x5d {
        try expect(0x5d)
        return
      }
      while true {
        if try peek() == 0x22 { try metadata(path) } else { try skipValue() }
        try space()
        if try peek() == 0x5d {
          try expect(0x5d)
          return
        }
        try expect(0x2c)
        try space()
      }
    default: try skipValue()
    }
  }

  private func skipValue() throws {
    guard let first = try peek() else { throw failure }
    if first == 0x22 {
      _ = try string(copy: true)
    } else if first == 0x7b || first == 0x5b {
      var closing: [UInt8] = []
      repeat {
        guard let next = try peek() else { throw failure }
        if next == 0x22 {
          _ = try string(copy: true)
          continue
        }
        _ = try take()
        switch next {
        case 0x7b: closing.append(0x7d)
        case 0x5b: closing.append(0x5d)
        case 0x7d, 0x5d:
          guard closing.popLast() == next else { throw failure }
        default: break
        }
      } while !closing.isEmpty
    } else {
      let delimiters: Set<UInt8> = [0x20, 0x09, 0x0d, 0x0a, 0x2c, 0x5d, 0x7d]
      guard !delimiters.contains(first) else { throw failure }
      while let next = try peek(), !delimiters.contains(next) { _ = try take() }
    }
  }
}
