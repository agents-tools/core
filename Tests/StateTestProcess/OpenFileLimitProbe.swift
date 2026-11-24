import AgentsCore
import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

func openFileLimitProbe(_ mode: String, root: URL, store: StateStore) throws {
  #if os(Linux)
    let resource = Int32(RLIMIT_NOFILE.rawValue)
  #else
    let resource = RLIMIT_NOFILE
  #endif
  var before = rlimit()
  guard getrlimit(resource, &before) == 0 else {
    throw POSIXError(.EINVAL)
  }
  if mode == "bounded" {
    before.rlim_max = min(before.rlim_max, 64)
    before.rlim_cur = min(before.rlim_max, 32)
  } else if mode == "worker" {
    before.rlim_cur = min(before.rlim_max, 4096)
  } else {
    before.rlim_cur = min(before.rlim_max, 256)
  }
  guard setrlimit(resource, &before) == 0 else { throw POSIXError(.EINVAL) }

  if mode == "raised" || mode == "bounded" { ProcessLimits.raiseOpenFileLimit() }
  var after = rlimit()
  guard getrlimit(resource, &after) == 0 else { throw POSIXError(.EINVAL) }

  let large =
    if mode == "worker" {
      try sharedCoordinationWorkerProbe(store: store)
    } else {
      try sharedCoordinationAdmission(store: store, count: 96)
    }
  let result = """
    \(before.rlim_cur)
    \(before.rlim_max)
    \(after.rlim_cur)
    \(after.rlim_max)
    \(large)
    """
  try Data(result.utf8).write(to: root.appendingPathComponent("open-file-limit-\(mode)"))
}

private func sharedCoordinationAdmission(store: StateStore, count: Int) throws -> String {
  let routes = try (0..<count).map {
    try NativeTargetRoute.named(.claudeSkillPlugin, scope: .user, name: "generated-\($0)")
  }
  func read(_ footprint: Set<NativeTargetRoute>) throws {
    var calls = 0
    let value: Int? = try store.withReadLock(footprint: footprint) {
      calls += 1
      return nil
    }
    precondition(calls == 1 && value == nil)
  }
  try read(Set(routes.prefix(2)))
  do {
    try read(Set(routes))
    return "admitted"
  } catch  where error.localizedDescription.hasPrefix("Too many open files for this process:") {
    return error.localizedDescription
  }
}

private func sharedCoordinationWorkerProbe(store: StateStore) throws -> String {
  func check(_ code: Int32) throws {
    guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EINVAL) }
  }
  var attributes = pthread_attr_t()
  try check(pthread_attr_init(&attributes))
  defer { pthread_attr_destroy(&attributes) }
  try check(pthread_attr_setstacksize(&attributes, SharedCoordinationWorker.stackSize))
  #if os(Linux)
    var thread: pthread_t = 0
  #else
    var thread: pthread_t?
  #endif
  let worker = SharedCoordinationWorker(store: store)
  let argument = Unmanaged.passRetained(worker)
  let created = pthread_create(
    &thread, &attributes,
    { pointer in
      let argument: UnsafeMutableRawPointer? = pointer
      guard let argument else { return nil }
      let worker = Unmanaged<SharedCoordinationWorker>.fromOpaque(argument).takeRetainedValue()
      worker.run()
      return nil
    }, argument.toOpaque())
  if created != 0 {
    argument.release()
    try check(created)
  }
  #if os(Linux)
    try check(pthread_join(thread, nil))
  #else
    try check(pthread_join(thread!, nil))
  #endif
  guard let result = worker.result else {
    throw CoreError.invalidState("coordination worker did not report a result")
  }
  return try result.get()
}

private final class SharedCoordinationWorker {
  static let stackSize = 512 * 1024
  let store: StateStore
  var result: Result<String, any Error>?

  init(store: StateStore) { self.store = store }

  func run() {
    result = Result { try sharedCoordinationAdmission(store: store, count: 196) }
  }
}
