import AgentsCore
import Foundation

enum UpdateSource {
  static func formatSourceInput(_ source: String, ref: String? = nil) -> String {
    guard let ref, !ref.isEmpty else { return source }
    return "\(source)#\(ref)"
  }

  static func buildUpdateInstallSource(
    source: String, sourceURL: String, ref: String? = nil, skillPath: String? = nil
  ) -> String {
    guard let skillPath else {
      return formatSourceInput(sourceURL, ref: ref)
    }
    return buildLocalUpdateSource(source: source, ref: ref, skillPath: skillPath)
  }

  static func buildLocalUpdateSource(
    source: String, ref: String? = nil, skillPath: String? = nil
  ) -> String {
    guard let skillPath else {
      return formatSourceInput(source, ref: ref)
    }
    let skillFolder = SkillPath.normalizeSkillPath(skillPath)
    let base = skillFolder.isEmpty ? source : "\(source)/\(skillFolder)"
    return formatSourceInput(base, ref: ref)
  }
}
