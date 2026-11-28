import AgentsCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct RegistryAcquisition {
  private struct Metadata: Codable {
    let control: String?
    let vary: Set<String>
    let etag: String?
    let modified: String?
    let expires: Date
  }

  @TaskLocal static var transport: (@Sendable (URLRequest) async throws -> RegistryHTTP.Response)?

  let environment: RuntimeEnvironment
  let endpoint: URL

  func read<T>(
    _ request: URLRequest, anonymous: Bool, refresh: Bool, validate: (Data) throws -> T
  ) async throws -> T {
    let cache = AcquisitionCache(environment: environment)
    guard anonymous, let key = Self.identity(request) else {
      return try validate(fullResponse(await fetch(request), for: request).body)
    }
    var stored = try? cache.read(
      .http, key: key, maximumBytes: RegistryHTTP.responseLimit, touching: !refresh
    ) { value in
      let metadata = try JSONDecoder().decode(Metadata.self, from: value.metadata)
      guard metadata.vary.isSubset(of: ["accept"]),
        metadata.expires.timeIntervalSinceReferenceDate.isFinite,
        Self.validator(metadata.etag) == metadata.etag,
        Self.validator(metadata.modified) == metadata.modified,
        !Self.forbidsStorage(Self.directives(metadata.control))
      else { throw AcquisitionCacheError.invalidEntry }
      return (value, metadata)
    }
    if let (value, metadata) = stored, !refresh, metadata.expires > Date() {
      do { return try validate(value.data) } catch MCPRegistryError.invalidResponse {
        try cache.invalidate(.http, key: key, publication: value.publication)
        stored = nil
      }
    }
    let publication = stored?.0.publication ?? (try? cache.publication(.http, key: key))

    var conditional = request
    if let (_, metadata) = stored, !refresh, metadata.expires <= Date() {
      conditional.setValue(metadata.etag, forHTTPHeaderField: "If-None-Match")
      conditional.setValue(metadata.modified, forHTTPHeaderField: "If-Modified-Since")
    }

    let received = try await fetch(conditional)
    try requireRequestedURL(received, for: request)
    if received.status == 304 {
      guard let (value, old) = stored,
        conditional.value(forHTTPHeaderField: "If-None-Match") != nil
          || conditional.value(forHTTPHeaderField: "If-Modified-Since") != nil
      else { throw MCPRegistryError.httpStatus(304) }
      let vary = Self.vary(received.headers["vary"], old: old.vary)
      let admissible =
        vary == old.vary
        && Self.sameValidator(received.headers["etag"], as: old.etag)
        && (old.etag != nil
          || Self.sameValidator(received.headers["last-modified"], as: old.modified))
        && received.headers["set-cookie"] == nil && received.headers["set-cookie2"] == nil
        && received.headers["content-location"] == nil
      if admissible {
        let metadata = Self.metadata(received.headers, old: old, now: Date())
        if metadata == nil {
          try cache.invalidate(.http, key: key, publication: value.publication)
        }
        let result = try validate(value.data)
        if let metadata {
          save(
            value.data, metadata: metadata, cache: cache, key: key,
            condition: .publication(value.publication))
        }
        return result
      }

      try cache.invalidate(.http, key: key, publication: value.publication)
      let response = try fullResponse(await fetch(request), for: request)
      return try consume(response, cache: cache, key: key, stored: nil, validate: validate)
    }
    return try consume(
      fullResponse(received, for: request), cache: cache, key: key,
      stored: publication, validate: validate)
  }

  private func consume<T>(
    _ response: RegistryHTTP.Response, cache: AcquisitionCache, key: String, stored: UUID?,
    validate: (Data) throws -> T
  ) throws -> T {
    let metadata = Self.metadata(response.headers, old: nil, now: Date())
    if metadata == nil, let stored {
      try cache.invalidate(.http, key: key, publication: stored)
    }
    let result = try validate(response.body)
    if let metadata {
      save(
        response.body, metadata: metadata, cache: cache, key: key,
        condition: stored.map(AcquisitionCache.WriteCondition.publication) ?? .absent)
    }
    return result
  }

  private func save(
    _ data: Data, metadata: Metadata, cache: AcquisitionCache, key: String,
    condition: AcquisitionCache.WriteCondition
  ) {
    guard let encoded = try? JSONEncoder().encode(metadata) else { return }
    _ = try? cache.write(
      data, store: .http, key: key, object: FileHash.sha256Hex(data: data),
      metadata: encoded, condition: condition)
  }

  private func fetch(_ request: URLRequest) async throws -> RegistryHTTP.Response {
    try environment.requireMCPRegistry(endpoint)
    if let transport = Self.transport { return try await transport(request) }
    return try await RegistryHTTP().read(request)
  }

  private func requireRequestedURL(_ response: RegistryHTTP.Response, for request: URLRequest)
    throws
  {
    guard let url = request.url,
      url.absoluteString.utf8.elementsEqual(response.url.absoluteString.utf8)
    else { throw MCPRegistryError.redirectRejected }
  }

  private func fullResponse(
    _ response: RegistryHTTP.Response, for request: URLRequest
  ) throws -> RegistryHTTP.Response {
    try requireRequestedURL(response, for: request)
    guard response.status == 200 else { throw MCPRegistryError.httpStatus(response.status) }
    guard response.body.count <= RegistryHTTP.responseLimit else {
      throw MCPRegistryError.responseTooLarge
    }
    return response
  }

  private static func identity(_ request: URLRequest) -> String? {
    guard request.httpMethod == "GET", let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
      RegistryHTTP.validURL(components), components.scheme?.lowercased() == "https",
      (components.queryItems ?? []).allSatisfy({ field in
        !RegistryInput.isCredentialName(field.name)
          && !["x-amz-", "x-goog-"].contains(where: field.name.lowercased().hasPrefix)
      }),
      !request.httpShouldHandleCookies,
      let headers = request.allHTTPHeaderFields, headers.count == 1,
      let accept = request.value(forHTTPHeaderField: "Accept")
    else { return nil }
    return AcquisitionCache.key([
      ("method", Data("GET".utf8)), ("url", Data(url.absoluteString.utf8)),
      ("accept", Data(accept.utf8)),
    ])
  }

  private static func vary(_ value: String?, old: Set<String> = []) -> Set<String>? {
    guard let value else { return old }
    let fields = Set(
      value.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
      })
    return fields.isSubset(of: ["accept"]) ? fields : nil
  }

  private static func sameValidator(_ new: String?, as old: String?) -> Bool {
    guard let new, let old else { return true }
    return new.utf8.elementsEqual(old.utf8)
  }

  private static func metadata(
    _ headers: [String: String], old: Metadata?, now: Date
  ) -> Metadata? {
    guard headers["set-cookie"] == nil, headers["set-cookie2"] == nil,
      headers["content-location"] == nil,
      let vary = vary(headers["vary"], old: old?.vary ?? [])
    else { return nil }
    let control = headers["cache-control"] ?? old?.control
    let fields =
      control?.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
      } ?? []
    guard
      !fields.contains(where: { field in
        field.first.map { ["private", "no-store", "no-cache"].contains($0.lowercased()) } ?? false
      }), headers["pragma"]?.lowercased().contains("no-cache") != true
    else { return nil }

    let date = headers["date"].flatMap(Self.httpDate)
    let suppliedAge = headers["age"].flatMap(Int.init)
    if headers["age"] != nil, suppliedAge == nil || suppliedAge! < 0 { return nil }
    let age = max(Double(suppliedAge ?? 0), date.map { now.timeIntervalSince($0) } ?? 0)
    let ages = fields.filter { $0.first?.lowercased() == "max-age" }
    let expires: Date
    if !ages.isEmpty {
      guard ages.count == 1, ages[0].count == 2,
        let seconds = Int(ages[0][1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
        seconds >= 0
      else { return nil }
      expires = now.addingTimeInterval(Double(seconds) - age)
    } else if let until = headers["expires"].flatMap(Self.httpDate) {
      expires = now.addingTimeInterval(until.timeIntervalSince(date ?? now) - age)
    } else {
      expires = now
    }
    let etag = validator(headers["etag"]) ?? old?.etag
    let modified =
      validator(headers["last-modified"]).flatMap { httpDate($0) == nil ? nil : $0 }
      ?? old?.modified
    guard expires > now || etag != nil || modified != nil else { return nil }
    return Metadata(control: control, vary: vary, etag: etag, modified: modified, expires: expires)
  }

  private static func directives(_ control: String?) -> [[String]] {
    control?.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
    } ?? []
  }

  private static func forbidsStorage(_ fields: [[String]]) -> Bool {
    fields.contains { field in
      field.first.map { ["private", "no-store", "no-cache"].contains($0.lowercased()) } ?? false
    }
  }

  private static func validator(_ header: String?) -> String? {
    guard let header, !header.isEmpty, header.utf8.count <= 1024,
      RegistryHTTP.isHeaderValue(header)
    else { return nil }
    return header
  }

  private static func httpDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.date(from: value)
  }
}
