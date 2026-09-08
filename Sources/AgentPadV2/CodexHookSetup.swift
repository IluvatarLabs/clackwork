import Darwin
import Foundation

enum CodexHookSetupStatus: Equatable, Sendable {
  case notInstalled
  case installed
  case needsRepair(String)
  case invalid(String)

  var description: String {
    switch self {
    case .notInstalled: "Codex hooks are not installed."
    case .installed: "Codex hooks are installed."
    case .needsRepair(let reason): "Codex hooks need repair: \(reason)"
    case .invalid(let reason): "Codex hooks are invalid: \(reason)"
    }
  }
}

enum CodexHookSetupError: LocalizedError {
  case invalidHome
  case bundledHelperMissing
  case invalidConfiguration
  case postcondition(String)

  var errorDescription: String? {
    switch self {
    case .invalidHome: "CODEX_HOME must be an absolute path."
    case .bundledHelperMissing: "The Clackwork Codex hook helper is missing."
    case .invalidConfiguration: "Codex hooks.json is not valid JSON hook configuration."
    case .postcondition(let message): message
    }
  }
}

/// Explicit additive setup for the five Codex facts used by the pilot. It
/// removes and replaces only handlers that name AgentPad13's stable helper.
struct CodexHookSetup: Sendable {
  let hooksURL: URL
  let bundledHelperURL: URL
  let helperURL: URL

  private static let events: [(name: String, timeout: Int)] = [
    ("SessionStart", 3),
    ("UserPromptSubmit", 3),
    ("PermissionRequest", 60),
    ("Stop", 3),
    ("SessionEnd", 3),
  ]

  static func live(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> CodexHookSetup {
    let home: URL
    if let configured = environment["CODEX_HOME"], !configured.isEmpty {
      guard configured.hasPrefix("/") else { throw CodexHookSetupError.invalidHome }
      home = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    } else {
      home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
    }
    guard let executableURL = Bundle.main.executableURL else {
      throw CodexHookSetupError.bundledHelperMissing
    }
    let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
      .appendingPathComponent("AgentPad13V2", isDirectory: true)
      .appendingPathComponent("CodexHooks", isDirectory: true)
    return CodexHookSetup(
      hooksURL: home.appendingPathComponent("hooks.json"),
      bundledHelperURL: executableURL,
      helperURL: supportDirectory.appendingPathComponent("AgentPadCodexHook")
    )
  }

  var expectedCommand: String {
    Self.shellQuoted(helperURL.path)
  }

  func status() -> CodexHookSetupStatus {
    do {
      guard FileManager.default.fileExists(atPath: hooksURL.path) else {
        return .notInstalled
      }
      let root = try readRoot()
      let counts = try ownedCounts(in: root)
      let installedCount = counts.values.reduce(0, +)
      guard installedCount > 0 else { return .notInstalled }
      guard Self.events.allSatisfy({ counts[$0.name] == 1 }),
        installedCount == Self.events.count
      else {
        return .needsRepair("the owned hook entries are incomplete or duplicated")
      }
      guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
        return .needsRepair("the staged hook helper is missing")
      }
      return .installed
    } catch {
      return .invalid(error.localizedDescription)
    }
  }

  @discardableResult
  func install() throws -> CodexHookSetupStatus {
    guard FileManager.default.isExecutableFile(atPath: bundledHelperURL.path) else {
      throw CodexHookSetupError.bundledHelperMissing
    }
    var root = try readRootIfPresent() ?? [:]
    try removeOwnedHandlers(from: &root)
    try addOwnedHandlers(to: &root)
    try stageHelper()
    try write(root)
    let result = status()
    guard result == .installed else {
      throw CodexHookSetupError.postcondition(result.description)
    }
    return result
  }

  @discardableResult
  func remove() throws -> CodexHookSetupStatus {
    if var root = try readRootIfPresent() {
      try removeOwnedHandlers(from: &root)
      try write(root)
    }
    if FileManager.default.fileExists(atPath: helperURL.path) {
      try FileManager.default.removeItem(at: helperURL)
    }
    let result = status()
    guard result == .notInstalled else {
      throw CodexHookSetupError.postcondition(result.description)
    }
    return result
  }

  private func addOwnedHandlers(to root: inout [String: Any]) throws {
    var hooks = try hooksDictionary(in: root)
    for event in Self.events {
      var groups = try groups(for: event.name, in: hooks)
      groups.append([
        "hooks": [[
          "type": "command",
          "command": expectedCommand,
          "timeout": event.timeout,
        ]]
      ])
      hooks[event.name] = groups
    }
    root["hooks"] = hooks
  }

  private func removeOwnedHandlers(from root: inout [String: Any]) throws {
    var hooks = try hooksDictionary(in: root)
    for eventName in Array(hooks.keys) {
      let existing = try groups(for: eventName, in: hooks)
      var retainedGroups: [[String: Any]] = []
      for var group in existing {
        guard let handlers = group["hooks"] as? [[String: Any]] else {
          throw CodexHookSetupError.invalidConfiguration
        }
        let retained = handlers.filter { ($0["command"] as? String) != expectedCommand }
        if !retained.isEmpty {
          group["hooks"] = retained
          retainedGroups.append(group)
        }
      }
      if retainedGroups.isEmpty {
        hooks.removeValue(forKey: eventName)
      } else {
        hooks[eventName] = retainedGroups
      }
    }
    if hooks.isEmpty {
      root.removeValue(forKey: "hooks")
    } else {
      root["hooks"] = hooks
    }
  }

  private func ownedCounts(in root: [String: Any]) throws -> [String: Int] {
    let hooks = try hooksDictionary(in: root)
    var counts: [String: Int] = [:]
    for eventName in hooks.keys {
      for group in try groups(for: eventName, in: hooks) {
        guard let handlers = group["hooks"] as? [[String: Any]] else {
          throw CodexHookSetupError.invalidConfiguration
        }
        counts[eventName, default: 0] += handlers.filter {
          ($0["command"] as? String) == expectedCommand
        }.count
      }
    }
    return counts
  }

  private func hooksDictionary(in root: [String: Any]) throws -> [String: Any] {
    guard let value = root["hooks"] else { return [:] }
    guard let hooks = value as? [String: Any] else {
      throw CodexHookSetupError.invalidConfiguration
    }
    return hooks
  }

  private func groups(
    for event: String,
    in hooks: [String: Any]
  ) throws -> [[String: Any]] {
    guard let value = hooks[event] else { return [] }
    guard let groups = value as? [[String: Any]] else {
      throw CodexHookSetupError.invalidConfiguration
    }
    return groups
  }

  private func readRootIfPresent() throws -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: hooksURL.path) else { return nil }
    return try readRoot()
  }

  private func readRoot() throws -> [String: Any] {
    let data = try Data(contentsOf: hooksURL)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw CodexHookSetupError.invalidConfiguration }
    return root
  }

  private func write(_ root: [String: Any]) throws {
    guard JSONSerialization.isValidJSONObject(root) else {
      throw CodexHookSetupError.invalidConfiguration
    }
    try FileManager.default.createDirectory(
      at: hooksURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let destination = FileManager.default.fileExists(atPath: hooksURL.path)
      ? hooksURL.resolvingSymlinksInPath()
      : hooksURL
    let data = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: destination, options: .atomic)
  }

  private func stageHelper() throws {
    try FileManager.default.createDirectory(
      at: helperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(contentsOf: bundledHelperURL).write(to: helperURL, options: .atomic)
    guard chmod(helperURL.path, 0o755) == 0 else {
      throw CodexHookSetupError.bundledHelperMissing
    }
  }

  private static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
