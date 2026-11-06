import CPlatform
import Foundation

/// Filesystem access diagnostics shared by descriptor and Foundation operations.
package enum FileSystem {
  static func permissionDenied(at url: URL) -> CoreError {
    .invalidState(
      "permission denied: \(url.path); check the directory's permissions and default ACL")
  }

  static func posixError(_ code: Int32, at url: URL, otherwise error: CoreError) -> CoreError {
    code == EACCES || code == EPERM ? permissionDenied(at: url) : error
  }

  static func requireAccess(
    _ mode: Int32, at url: URL, parent: Int32 = AT_FDCWD, name: String? = nil
  ) throws {
    let path = name ?? (parent == AT_FDCWD ? url.path : url.lastPathComponent)
    guard platform_access(parent, path, mode) == 0 else {
      throw posixError(errno, at: url, otherwise: .invalidState("cannot access \(url.path)"))
    }
  }

  package static func withAccessErrors<T>(at url: URL, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch let error as GitError {
      throw error
    } catch {
      throw denial(in: error, at: url) ?? error
    }
  }

  /// The permission-denied error for `error`, or nil when no cause in its chain is a denial.
  private static func denial(in error: Error, at url: URL) -> CoreError? {
    var cause: NSError? = error as NSError
    var denied = false
    var failingURL: URL?
    while let current = cause {
      // Preserve the innermost supplied path; the operation URL may be a copy destination.
      if let path = current.userInfo[NSFilePathErrorKey] as? String, !path.isEmpty {
        failingURL = URL(fileURLWithPath: path)
      } else if let url = current.userInfo[NSURLErrorKey] as? URL, url.isFileURL {
        failingURL = url
      }
      if (current.domain == NSPOSIXErrorDomain
        && [Int(EACCES), Int(EPERM)].contains(current.code))
        || (current.domain == NSCocoaErrorDomain
          && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(current.code))
      {
        denied = true
      }
      cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return denied ? permissionDenied(at: failingURL ?? url) : nil
  }

  package static func read(at url: URL) throws -> Data {
    try withAccessErrors(at: url) { try Data(contentsOf: url) }
  }

  /// Reads optional content whose absence or unreadability the caller tolerates. Only a
  /// permission denial throws, so an unusable environment is not mistaken for missing content.
  package static func readUnlessDenied(at url: URL) throws -> Data? {
    do {
      return try Data(contentsOf: url)
    } catch {
      if let denied = denial(in: error, at: url) { throw denied }
      return nil
    }
  }

  package static func createDirectory(at url: URL) throws {
    // Foundation callers permit existing aliases; descriptor operations still
    // pin the resolved ancestry and create each missing component with 0700.
    _ = try DirectoryHandle(at: url.resolvingSymlinksInPath(), create: true)
  }

  package static func requireWritableFile(at url: URL) throws {
    try requireAccess(R_OK | W_OK, at: url)
  }

  package static func write(_ data: Data, to url: URL) throws {
    let parent = try DirectoryHandle(at: url.deletingLastPathComponent().resolvingSymlinksInPath())
    try parent.write(url.lastPathComponent, data: data)
  }
}
