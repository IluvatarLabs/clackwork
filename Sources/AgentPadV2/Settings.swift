import Foundation

struct AgentPadSettings: Codable, Equatable, Sendable {
  var controls: [ControlBinding]
  var assignmentMode: AssignmentMode
  var pinnedSessionIDs: [String]
  var focusOnSingleTap: Bool
  var lighting: LightingSettings

  static let defaults = AgentPadSettings(
    controls: ControlID.allCases.map { control in
      if control == .encoderLongPress {
        return ControlBinding(
          control: control,
          role: .command,
          command: .openSettings
        )
      }
      return ControlBinding(
        control: control,
        role: ControlID.keys.dropLast().contains(control) ? .agent : .off
      )
    },
    assignmentMode: .mostRecent,
    pinnedSessionIDs: [],
    focusOnSingleTap: false,
    lighting: LightingSettings()
  )
}

enum SettingsStore {
  private static let key = "AgentPadV2.settings"

  static func load(from defaults: UserDefaults = .standard) -> AgentPadSettings {
    guard
      let data = defaults.data(forKey: key),
      let settings = try? JSONDecoder().decode(AgentPadSettings.self, from: data)
    else {
      return .defaults
    }
    return settings
  }

  static func save(
    _ settings: AgentPadSettings,
    to defaults: UserDefaults = .standard
  ) throws {
    defaults.set(try JSONEncoder().encode(settings), forKey: key)
  }
}
