import Foundation

struct CodexSession: Identifiable, Equatable, Sendable {
  let id: String
  var title: String
  var path: String?
  var lastActivity: Date?
  var state: CodexSessionState?
}

enum CodexSessionState: String, Codable, CaseIterable, Sendable {
  case idle
  case working
  case requiresInput
  case complete
  case error
}

enum ControlID: String, Codable, CaseIterable, Identifiable, Sendable {
  case sw1
  case sw2
  case sw3
  case sw4
  case sw5
  case sw6
  case sw7
  case sw8
  case sw9
  case sw10
  case sw11
  case sw12
  case sw13
  case encoderPress
  case encoderLongPress
  case encoderClockwise
  case encoderCounterclockwise
  case joystickUp
  case joystickRight
  case joystickDown
  case joystickLeft

  var id: Self { self }

  static let keys: [ControlID] = [
    .sw1, .sw2, .sw3, .sw4, .sw5, .sw6, .sw7,
    .sw8, .sw9, .sw10, .sw11, .sw12, .sw13,
  ]

  var title: String {
    if rawValue.hasPrefix("sw") {
      return rawValue.uppercased()
    }
    return switch self {
    case .encoderPress: "Encoder press"
    case .encoderLongPress: "Encoder long press"
    case .encoderClockwise: "Encoder clockwise"
    case .encoderCounterclockwise: "Encoder counterclockwise"
    case .joystickUp: "Joystick up"
    case .joystickRight: "Joystick right"
    case .joystickDown: "Joystick down"
    case .joystickLeft: "Joystick left"
    default: rawValue
    }
  }
}

enum ControlRole: String, Codable, CaseIterable, Sendable {
  case off
  case agent
  case command
}

enum AssignmentMode: String, Codable, CaseIterable, Sendable {
  case mostRecent
  case pinned
  case priority
  case custom
}

enum PilotCommand: String, Codable, CaseIterable, Sendable {
  case approve
  case decline
  case continueInNewChat
  case nextSession
  case previousSession
  case refreshSessions
  case openSettings
}

struct ControlBinding: Codable, Equatable, Identifiable, Sendable {
  var control: ControlID
  var role: ControlRole
  var customSessionID: String?
  var command: PilotCommand?

  var id: ControlID { control }

  init(
    control: ControlID,
    role: ControlRole = .off,
    customSessionID: String? = nil,
    command: PilotCommand? = nil
  ) {
    self.control = control
    self.role = role
    self.customSessionID = customSessionID
    self.command = command
  }
}

struct RGBColor: Codable, Equatable, Sendable {
  var red: UInt8
  var green: UInt8
  var blue: UInt8
}

struct StatePalette: Codable, Equatable, Sendable {
  var idle = RGBColor(red: 255, green: 255, blue: 255)
  var working = RGBColor(red: 59, green: 130, blue: 246)
  var requiresInput = RGBColor(red: 245, green: 158, blue: 11)
  var complete = RGBColor(red: 0, green: 255, blue: 0)
  var error = RGBColor(red: 239, green: 68, blue: 68)

  subscript(state: CodexSessionState) -> RGBColor {
    switch state {
    case .idle: idle
    case .working: working
    case .requiresInput: requiresInput
    case .complete: complete
    case .error: error
    }
  }
}

enum KeyOptics: String, Codable, CaseIterable, Sendable {
  case unknown
  case opaque
  case translucent
}

struct KeyLightingIntent: Codable, Equatable, Identifiable, Sendable {
  var control: ControlID
  var optics: KeyOptics
  var statusEnabled: Bool

  var id: ControlID { control }
}

enum BandInstallation: String, Codable, CaseIterable, Sendable {
  case unknown
  case absent
  case installed
}

enum BandMode: String, Codable, CaseIterable, Sendable {
  case off
  case overallAttention
}

struct BandSettings: Codable, Equatable, Sendable {
  var installation: BandInstallation = .unknown
  var optics: KeyOptics = .unknown
  var mode: BandMode = .off
}

struct LightingSettings: Codable, Equatable, Sendable {
  var palette = StatePalette()
  var brightnessPercent = 100
  var autoOffSeconds: Int? = 180
  var keys = ControlID.keys.map {
    KeyLightingIntent(control: $0, optics: .unknown, statusEnabled: true)
  }
  var band = BandSettings()
}
