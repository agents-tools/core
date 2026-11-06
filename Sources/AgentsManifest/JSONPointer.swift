import Foundation

/// JSON Pointer segments escape tilde before slash; decoding reverses that order.
func pointerEscape(_ text: String) -> String {
  text.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
}

func pointerUnescape(_ text: String) -> String {
  text.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
}

func pointerSegments(_ pointer: String) -> [String] {
  guard !pointer.isEmpty else { return [] }
  return pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map {
    pointerUnescape(String($0))
  }
}
