import CPlatform

public enum ProcessLimits {
  /// Best-effort increase of this process's soft open-file limit.
  /// Call from the owning executable at startup, before beginning scope operations.
  /// The hard limit is preserved. If the OS refuses, operations use the existing limit.
  public static func raiseOpenFileLimit() {
    platform_raise_open_file_limit()
  }
}
