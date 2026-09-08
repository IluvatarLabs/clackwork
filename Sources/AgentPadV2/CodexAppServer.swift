import AppKit
import Darwin
import Foundation

struct CodexThread: Equatable, Sendable {
  let id: String
  let title: String
  let path: String?
  let lastActivity: Date?
}

enum CodexClientError: LocalizedError {
  case unavailable
  case launchFailed
  case timedOut
  case invalidResponse
  case rejected(String)
  case focusUnavailable

  var errorDescription: String? {
    switch self {
    case .unavailable: "Codex is not installed."
    case .launchFailed: "Codex could not be started."
    case .timedOut: "Codex did not respond in time."
    case .invalidResponse: "Codex returned an invalid response."
    case .rejected(let message): message
    case .focusUnavailable: "The Codex app could not open that chat."
    }
  }
}

/// The two bounded App Server operations used by the pilot. Each call owns one
/// short-lived stdio connection; there is no resident provider process.
struct CodexAppServer: Sendable {
  let executableURL: URL
  let environment: [String: String]
  var timeout: TimeInterval = 8

  static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> CodexAppServer {
    guard let executableURL = findExecutable(environment: environment) else {
      throw CodexClientError.unavailable
    }
    return CodexAppServer(executableURL: executableURL, environment: environment)
  }

  func listThreads() async throws -> [CodexThread] {
    let executableURL = executableURL
    let environment = environment
    let timeout = timeout
    return try await Task.detached(priority: .utility) {
      try Self.loadThreads(
        executableURL: executableURL,
        environment: environment,
        timeout: timeout
      )
    }.value
  }

  func fork(threadID: String) async throws -> CodexThread {
    guard let threadID = Self.validIdentifier(threadID) else {
      throw CodexClientError.invalidResponse
    }
    let executableURL = executableURL
    let environment = environment
    let timeout = timeout
    return try await Task.detached(priority: .userInitiated) {
      try Self.forkThread(
        threadID,
        executableURL: executableURL,
        environment: environment,
        timeout: timeout
      )
    }.value
  }

  @MainActor
  func focus(threadID: String) throws {
    guard let url = Self.threadURL(threadID), NSWorkspace.shared.open(url) else {
      throw CodexClientError.focusUnavailable
    }
  }

  static func threadURL(_ threadID: String) -> URL? {
    guard let threadID = validIdentifier(threadID),
      let encoded = threadID.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      )
    else { return nil }
    return URL(string: "codex://threads/\(encoded)")
  }

  private static func loadThreads(
    executableURL: URL,
    environment: [String: String],
    timeout: TimeInterval
  ) throws -> [CodexThread] {
    let process = try CodexWireProcess(
      executableURL: executableURL,
      environment: environment,
      timeout: timeout
    )
    defer { process.stop() }
    try process.initialize()

    var requestID = 1
    var cursor: String?
    var seenCursors = Set<String>()
    var threads: [String: CodexThread] = [:]

    repeat {
      var parameters: [String: Any] = [
        "limit": 100,
        "sortKey": "recency_at",
        "sortDirection": "desc",
        "archived": false,
        "useStateDbOnly": true,
        "sourceKinds": ["cli", "vscode", "appServer"],
      ]
      if let cursor { parameters["cursor"] = cursor }
      let result = try process.request(
        id: requestID,
        method: "thread/list",
        parameters: parameters
      )
      guard let rows = result["data"] as? [[String: Any]] else {
        throw CodexClientError.invalidResponse
      }
      for row in rows {
        let thread = try parseThread(row)
        guard threads[thread.id] == nil else {
          throw CodexClientError.invalidResponse
        }
        threads[thread.id] = thread
      }

      cursor = try nextCursor(in: result)
      if let cursor, !seenCursors.insert(cursor).inserted {
        throw CodexClientError.invalidResponse
      }
      requestID += 1
    } while cursor != nil

    return threads.values.sorted {
      if $0.lastActivity != $1.lastActivity {
        return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
      }
      return $0.id < $1.id
    }
  }

  private static func forkThread(
    _ threadID: String,
    executableURL: URL,
    environment: [String: String],
    timeout: TimeInterval
  ) throws -> CodexThread {
    let process = try CodexWireProcess(
      executableURL: executableURL,
      environment: environment,
      timeout: timeout
    )
    defer { process.stop() }
    try process.initialize()
    let result = try process.request(
      id: 1,
      method: "thread/fork",
      parameters: ["threadId": threadID]
    )
    guard let row = result["thread"] as? [String: Any] else {
      throw CodexClientError.invalidResponse
    }
    let thread = try parseThread(row)
    guard thread.id != threadID,
      (row["forkedFromId"] as? String) == threadID
    else {
      throw CodexClientError.invalidResponse
    }
    return thread
  }

  private static func parseThread(_ row: [String: Any]) throws -> CodexThread {
    guard let id = validIdentifier(row["id"] as? String) else {
      throw CodexClientError.invalidResponse
    }
    let name = validText(row["name"] as? String, maximum: 1_024)
    let preview = validText(row["preview"] as? String, maximum: 1_024)
    let path = validText(row["cwd"] as? String, maximum: 4_096)
    let timestamp = number(row["recencyAt"])
      ?? number(row["updatedAt"])
      ?? number(row["createdAt"])
    return CodexThread(
      id: id,
      title: name ?? preview ?? id,
      path: path,
      lastActivity: timestamp.flatMap {
        $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
      }
    )
  }

  private static func nextCursor(in result: [String: Any]) throws -> String? {
    guard let value = result["nextCursor"], !(value is NSNull) else { return nil }
    guard let cursor = validText(value as? String, maximum: 4_096) else {
      throw CodexClientError.invalidResponse
    }
    return cursor
  }

  private static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    return number.doubleValue
  }

  private static func validIdentifier(_ value: String?) -> String? {
    validText(value, maximum: 256)
  }

  private static func validText(_ value: String?, maximum: Int) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= maximum,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return value
  }

  private static func findExecutable(environment: [String: String]) -> URL? {
    var directories = (environment["PATH"] ?? "")
      .split(separator: ":", omittingEmptySubsequences: true)
      .map(String.init)
    let home = FileManager.default.homeDirectoryForCurrentUser
    directories += [
      home.appendingPathComponent(".local/bin").path,
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ]
    for directory in Array(Set(directories)) {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    for candidate in [
      URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
      home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex"),
    ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
    return nil
  }
}

private final class CodexWireProcess {
  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let deadline: UInt64
  private var buffer = Data()
  private var bytesRead = 0
  private var stopped = false

  init(
    executableURL: URL,
    environment: [String: String],
    timeout: TimeInterval
  ) throws {
    guard timeout.isFinite, timeout > 0, timeout <= 30 else {
      throw CodexClientError.timedOut
    }
    let process = Process()
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let input = inputPipe.fileHandleForWriting
    let output = outputPipe.fileHandleForReading
    guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw CodexClientError.launchFailed
    }
    let flags = fcntl(output.fileDescriptor, F_GETFL)
    guard flags >= 0,
      fcntl(output.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
    else { throw CodexClientError.launchFailed }

    process.executableURL = executableURL
    process.arguments = ["app-server", "--stdio"]
    process.environment = environment
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw CodexClientError.launchFailed
    }
    self.process = process
    self.input = input
    self.output = output
    deadline = DispatchTime.now().uptimeNanoseconds
      + UInt64(timeout * 1_000_000_000)
  }

  deinit { stop() }

  func initialize() throws {
    try send([
      "method": "initialize",
      "id": 0,
      "params": [
        "clientInfo": [
          "name": "agentpad13_v2",
          "title": "AgentPad13 V2",
          "version": "0.1.0",
        ]
      ],
    ])
    _ = try response(id: 0)
    try send(["method": "initialized", "params": [:]])
  }

  func request(
    id: Int,
    method: String,
    parameters: [String: Any]
  ) throws -> [String: Any] {
    try send(["method": method, "id": id, "params": parameters])
    let message = try response(id: id)
    if let error = message["error"], !(error is NSNull) {
      let detail = (error as? [String: Any])?["message"] as? String
      throw CodexClientError.rejected(detail ?? "Codex rejected \(method).")
    }
    guard let result = message["result"] as? [String: Any] else {
      throw CodexClientError.invalidResponse
    }
    return result
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    try? input.close()
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    try? output.close()
  }

  private func send(_ object: [String: Any]) throws {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw CodexClientError.invalidResponse
    }
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    do {
      try input.write(contentsOf: data)
    } catch {
      throw CodexClientError.invalidResponse
    }
  }

  private func response(id: Int) throws -> [String: Any] {
    while true {
      let data = try readLine()
      guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { throw CodexClientError.invalidResponse }
      guard let value = message["id"] else { continue }
      guard let number = value as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.intValue == id
      else { throw CodexClientError.invalidResponse }
      return message
    }
  }

  private func readLine() throws -> Data {
    while true {
      if let newline = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        if !line.isEmpty { return line }
      }
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { throw CodexClientError.timedOut }
      var descriptor = pollfd(
        fd: output.fileDescriptor,
        events: Int16(POLLIN | POLLHUP),
        revents: 0
      )
      let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
      let pollResult = Darwin.poll(&descriptor, 1, milliseconds)
      guard pollResult > 0 else {
        if pollResult == 0 { throw CodexClientError.timedOut }
        if errno == EINTR { continue }
        throw CodexClientError.invalidResponse
      }
      var chunk = [UInt8](repeating: 0, count: 8_192)
      let count = chunk.withUnsafeMutableBytes {
        Darwin.read(output.fileDescriptor, $0.baseAddress, $0.count)
      }
      if count > 0 {
        bytesRead += count
        guard bytesRead <= 4 * 1_024 * 1_024 else {
          throw CodexClientError.invalidResponse
        }
        buffer.append(contentsOf: chunk.prefix(count))
      } else if count == 0 {
        throw CodexClientError.invalidResponse
      } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
        throw CodexClientError.invalidResponse
      }
    }
  }
}
