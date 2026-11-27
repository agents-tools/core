import Foundation

/// YAML fields for transaction fixtures that need bytes without the declaration model.
package func manifestText(_ fields: String = "") -> Data {
  Data(("version: 1\n" + fields + (fields.hasSuffix("\n") || fields.isEmpty ? "" : "\n")).utf8)
}
