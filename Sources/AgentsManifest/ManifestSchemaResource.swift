import Foundation

/// The bundled field schema shared by manifest validation, generated help and editor clients.
public enum ManifestSchemaResource {
  /// Returns the resource's exact JSON bytes, including its scalar annotations, without reading
  /// a declaration or accessing a scope or network. Consumers must distribute the package's
  /// resource bundle with their executable. A missing or unreadable schema file throws an I/O error.
  public static func encodedJSON() throws -> [UInt8] {
    guard let url = Bundle.module.url(forResource: "agents.schema", withExtension: "json") else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    return try Array(Data(contentsOf: url))
  }
}
