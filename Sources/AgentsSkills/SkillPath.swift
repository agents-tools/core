import Foundation

enum SkillPath {
  static func isValidSkillFile(_ file: String) -> Bool {
    guard !file.isEmpty else { return false }
    if file.hasPrefix("/") || file.hasPrefix("\\") || file.contains("..") {
      return false
    }
    return true
  }

  static func normalizeSkillPath(_ skillPath: String) -> String {
    var folderPath = skillPath
    if folderPath.hasSuffix("/SKILL.md") || folderPath.hasSuffix("\\SKILL.md") {
      folderPath = String(folderPath.dropLast(9))
    } else if folderPath.hasSuffix("SKILL.md") {
      folderPath = String(folderPath.dropLast(8))
    }
    if folderPath.hasSuffix("/") || folderPath.hasSuffix("\\") {
      folderPath = String(folderPath.dropLast())
    }
    return folderPath.replacingOccurrences(of: "\\", with: "/")
  }

  static func relativeSkillFilePath(root: String?, skillPath: String, separator: String)
    -> String?
  {
    guard let root else { return nil }
    if skillPath == root {
      return "SKILL.md"
    }
    guard skillPath.hasPrefix(root + separator) else {
      return nil
    }
    return String(skillPath.dropFirst(root.count + separator.count))
      .replacingOccurrences(of: separator, with: "/") + "/SKILL.md"
  }

}
