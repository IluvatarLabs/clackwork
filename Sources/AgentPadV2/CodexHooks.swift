import CoreFoundation
import Foundation

/// Entrypoint for the separate transient hook executable. It forwards Codex's
/// bounded stdin payload to the running app and prints only an exact decision.
public enum CodexHookClient {
  public static func run() {
    guard let payload = readStandardInput(),
      let port = CFMessagePortCreateRemote(
        kCFAllocatorDefault,
        CodexHookServer.portName as CFString
      )
    else { return }

    var unmanagedReply: Unmanaged<CFData>?
    let status = CFMessagePortSendRequest(
      port,
      1,
      payload as CFData,
      2,
      58,
      CFRunLoopMode.defaultMode.rawValue,
      &unmanagedReply
    )
    guard status == kCFMessagePortSuccess,
      let reply = unmanagedReply?.takeRetainedValue() as Data?,
      !reply.isEmpty
    else { return }
    try? FileHandle.standardOutput.write(contentsOf: reply)
  }

  private static func readStandardInput() -> Data? {
    var input = Data()
    while input.count <= CodexHookServer.maximumPayloadBytes {
      let remaining = CodexHookServer.maximumPayloadBytes + 1 - input.count
      let chunk: Data?
      do {
        chunk = try FileHandle.standardInput.read(upToCount: min(8_192, remaining))
      } catch {
        return nil
      }
      guard let chunk, !chunk.isEmpty else { return input.isEmpty ? nil : input }
      input.append(chunk)
    }
    return nil
  }
}

enum CodexHookKind: String, Sendable {
  case sessionStart = "SessionStart"
  case userPromptSubmit = "UserPromptSubmit"
  case permissionRequest = "PermissionRequest"
  case stop = "Stop"
  case sessionEnd = "SessionEnd"

  var state: CodexSessionState? {
    switch self {
    case .sessionStart: .idle
    case .userPromptSubmit: .working
    case .permissionRequest: .requiresInput
    case .stop: .complete
    case .sessionEnd: nil
    }
  }
}

enum CodexPermissionDecision: Sendable {
  case allow
  case deny
}

struct CodexHookEvent: Sendable {
  let kind: CodexHookKind
  let sessionID: String
  let cwd: String?
  let responder: CodexPermissionResponder?
}

/// The live synchronous hook invocation. A physical Approve or Decline claims
/// it once; cancellation returns no decision so Codex keeps its normal prompt.
final class CodexPermissionResponder: @unchecked Sendable {
  private let condition = NSCondition()
  private var result: CodexPermissionDecision?
  private var closed = false

  @discardableResult
  func resolve(_ decision: CodexPermissionDecision) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard !closed else { return false }
    result = decision
    closed = true
    condition.signal()
    return true
  }

  func cancel() {
    condition.lock()
    guard !closed else {
      condition.unlock()
      return
    }
    closed = true
    condition.signal()
    condition.unlock()
  }

  fileprivate func waitForDecision(seconds: TimeInterval) -> CodexPermissionDecision? {
    condition.lock()
    defer { condition.unlock() }
    if !closed {
      _ = condition.wait(until: Date(timeIntervalSinceNow: seconds))
    }
    closed = true
    return result
  }
}

enum CodexHookServerError: LocalizedError {
  case alreadyRunning
  case unavailable

  var errorDescription: String? {
    switch self {
    case .alreadyRunning: "Codex hook delivery is already running."
    case .unavailable: "Codex hook delivery could not start."
    }
  }
}

/// One standard local request/reply port. The callback runs off the main actor,
/// so a waiting PermissionRequest never blocks keyboard input or the settings UI.
final class CodexHookServer: @unchecked Sendable {
  static let portName = "com.iluvatarlabs.AgentPad13.v2.codex-hooks"
  static let maximumPayloadBytes = 1_048_576

  private let handler: @MainActor @Sendable (CodexHookEvent) -> Void
  private let queue = DispatchQueue(label: "AgentPad13.CodexHooks")
  private var port: CFMessagePort?

  init(handler: @escaping @MainActor @Sendable (CodexHookEvent) -> Void) {
    self.handler = handler
  }

  func start() throws {
    guard port == nil else { throw CodexHookServerError.alreadyRunning }
    var context = CFMessagePortContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    var shouldFreeInfo = DarwinBoolean(false)
    guard let port = CFMessagePortCreateLocal(
      kCFAllocatorDefault,
      Self.portName as CFString,
      codexHookCallback,
      &context,
      &shouldFreeInfo
    ) else {
      throw CodexHookServerError.unavailable
    }
    CFMessagePortSetDispatchQueue(port, queue)
    self.port = port
  }

  func stop() {
    guard let port else { return }
    CFMessagePortInvalidate(port)
    self.port = nil
  }

  fileprivate func reply(to data: Data) -> Data {
    guard data.count <= Self.maximumPayloadBytes,
      let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: data),
      let event = payload.event
    else { return Data() }

    if event.kind == .permissionRequest, let responder = event.responder {
      Task { @MainActor [handler] in handler(event) }
      guard let decision = responder.waitForDecision(seconds: 55) else {
        return Data()
      }
      return Self.permissionOutput(decision) ?? Data()
    }

    Task { @MainActor [handler] in handler(event) }
    return Data()
  }

  private static func permissionOutput(_ decision: CodexPermissionDecision) -> Data? {
    var decisionObject: [String: Any] = [
      "behavior": decision == .allow ? "allow" : "deny"
    ]
    if decision == .deny {
      decisionObject["message"] = "Declined from Clackwork."
    }
    return try? JSONSerialization.data(withJSONObject: [
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": decisionObject,
      ]
    ])
  }

  deinit { stop() }
}

private let codexHookCallback: CFMessagePortCallBack = { _, _, data, info in
  guard let data, let info else { return nil }
  let server = Unmanaged<CodexHookServer>.fromOpaque(info).takeUnretainedValue()
  return Unmanaged.passRetained(server.reply(to: data as Data) as CFData)
}

private struct CodexHookPayload: Decodable {
  let sessionID: String
  let cwd: String?
  let hookEventName: String

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case cwd
    case hookEventName = "hook_event_name"
  }

  var event: CodexHookEvent? {
    guard let kind = CodexHookKind(rawValue: hookEventName),
      let sessionID = Self.valid(sessionID, maximum: 256)
    else { return nil }
    let responder = kind == .permissionRequest ? CodexPermissionResponder() : nil
    return CodexHookEvent(
      kind: kind,
      sessionID: sessionID,
      cwd: Self.valid(cwd, maximum: 4_096),
      responder: responder
    )
  }

  private static func valid(_ value: String?, maximum: Int) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= maximum,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return value
  }
}
