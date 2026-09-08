import AppKit
import Darwin
import SwiftUI

@main
struct AgentPad13App: App {
  @StateObject private var coordinator: AppCoordinator
  private static let menuBarIcon: NSImage = {
    let image = Bundle.main.image(forResource: "AgentPad13MenuBarTemplate")!
    image.isTemplate = true
    return image
  }()

  init() {
    if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
      == "AgentPadCodexHook"
    {
      CodexHookClient.run()
      Darwin.exit(0)
    }
    _coordinator = StateObject(wrappedValue: AppCoordinator())
  }

  var body: some Scene {
    MenuBarExtra {
      AgentPadMenu(coordinator: coordinator)
    } label: {
      Image(nsImage: Self.menuBarIcon)
        .accessibilityLabel("Clackwork")
    }
    .menuBarExtraStyle(.window)
  }
}

private struct AgentPadMenu: View {
  @ObservedObject var coordinator: AppCoordinator
  @State private var selectedControl: ControlID = .sw1

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      status
      Divider()
      Picker("Assignment", selection: assignmentMode) {
        ForEach(AssignmentMode.allCases, id: \.self) { mode in
          Text(assignmentTitle(mode)).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      HStack(alignment: .top, spacing: 14) {
        keyGrid
        Divider()
        inspector
          .frame(width: 220, alignment: .topLeading)
      }
      Divider()
      HStack {
        Button("Refresh Sessions") { coordinator.refreshSessions() }
        Spacer()
        Button("Settings…") { coordinator.showSettings() }
        Button("Quit") {
          coordinator.shutdown()
          NSApp.terminate(nil)
        }
      }
    }
    .padding(14)
    .frame(width: 520)
  }

  private var status: some View {
    HStack(spacing: 12) {
      Text("Device: \(deviceSummary)")
      Text("Input: \(inputSummary)")
      Text(coordinator.codexStatus)
      Spacer(minLength: 4)
      if coordinator.device.input == .permissionRequired {
        Button("Open Input Monitoring") { coordinator.openInputMonitoringSettings() }
      } else if deviceNeedsRetry {
        Button("Retry") { coordinator.retryDevice() }
      }
    }
    .font(.callout)
  }

  private var keyGrid: some View {
    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
      ForEach(0..<3, id: \.self) { row in
        GridRow {
          ForEach(0..<4, id: \.self) { column in
            key(ControlID.keys[row * 4 + column])
          }
        }
      }
      GridRow {
        Color.clear.accessibilityHidden(true)
        key(.sw13).gridCellColumns(2)
        Color.clear.accessibilityHidden(true)
      }
    }
  }

  private func key(_ control: ControlID) -> some View {
    let selected = selectedControl == control
    return Button {
      selectedControl = control
    } label: {
      VStack(spacing: 2) {
        Text(control.title).font(.caption)
        Text(keyTitle(control))
          .font(.caption)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, minHeight: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(4)
    .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor))
    }
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var inspector: some View {
    let binding = coordinator.binding(for: selectedControl)
    return VStack(alignment: .leading, spacing: 10) {
      Text(selectedControl.title).font(.headline)
      Picker("Role", selection: role) {
        ForEach(ControlRole.allCases, id: \.self) { role in
          Text(roleTitle(role)).tag(role)
        }
      }
      .pickerStyle(.segmented)

      switch binding.role {
      case .off:
        EmptyView()
      case .agent:
        if coordinator.settings.assignmentMode == .custom {
          Picker("Session", selection: session) {
            Text("Unassigned").tag(String?.none)
            if let id = binding.customSessionID,
              !coordinator.sessions.contains(where: { $0.id == id })
            {
              Text("Unavailable · \(shortIdentity(id))").tag(String?.some(id))
            }
            ForEach(sortedSessions) { session in
              Text(sessionIdentity(session)).tag(String?.some(session.id))
            }
          }
        } else {
          LabeledContent("Session") {
            if let resolved = coordinator.resolvedSession(for: selectedControl) {
              Text(sessionIdentity(resolved)).lineLimit(2)
            } else {
              Text("Unassigned").foregroundStyle(.secondary)
            }
          }
        }
      case .command:
        Picker("Command", selection: command) {
          ForEach(PilotCommand.allCases, id: \.self) { command in
            Text(commandTitle(command)).tag(PilotCommand?.some(command))
          }
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var assignmentMode: Binding<AssignmentMode> {
    Binding(
      get: { coordinator.settings.assignmentMode },
      set: { mode in coordinator.updateSettings { $0.assignmentMode = mode } }
    )
  }

  private var role: Binding<ControlRole> {
    Binding(
      get: { coordinator.binding(for: selectedControl).role },
      set: { role in
        coordinator.updateBinding(selectedControl) { binding in
          binding.role = role
          if role == .command, binding.command == nil { binding.command = .approve }
        }
      }
    )
  }

  private var session: Binding<String?> {
    Binding(
      get: { coordinator.binding(for: selectedControl).customSessionID },
      set: { id in coordinator.updateBinding(selectedControl) { $0.customSessionID = id } }
    )
  }

  private var command: Binding<PilotCommand?> {
    Binding(
      get: { coordinator.binding(for: selectedControl).command },
      set: { command in coordinator.updateBinding(selectedControl) { $0.command = command } }
    )
  }

  private var sortedSessions: [CodexSession] {
    coordinator.sessions.sorted {
      if $0.lastActivity != $1.lastActivity {
        return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
      }
      return $0.id < $1.id
    }
  }

  private var deviceSummary: String {
    switch coordinator.device.connection {
    case .stopped: "Stopped"
    case .checking: "Checking"
    case .disconnected: "Disconnected"
    case .incompatible: "Incompatible"
    case .ready: "Connected"
    }
  }

  private var inputSummary: String {
    switch coordinator.device.input {
    case .stopped: "Stopped"
    case .ready: "Ready"
    case .permissionRequired: "Permission"
    case .failed: "Unavailable"
    }
  }

  private var deviceNeedsRetry: Bool {
    guard coordinator.device.input == .ready else { return true }
    return switch coordinator.device.connection {
    case .ready, .checking: false
    case .stopped, .disconnected, .incompatible: true
    }
  }

  private func keyTitle(_ control: ControlID) -> String {
    let binding = coordinator.binding(for: control)
    switch binding.role {
    case .off: return "Off"
    case .command: return binding.command.map(commandTitle) ?? "Command"
    case .agent: return coordinator.resolvedSession(for: control)?.title ?? "Unassigned"
    }
  }

  private func sessionIdentity(_ session: CodexSession) -> String {
    let state = session.state.map(stateTitle) ?? "State unavailable"
    return "\(session.title) · \(state) · \(session.path ?? "Codex") · \(shortIdentity(session.id))"
  }

  private func shortIdentity(_ id: String) -> String {
    id.count > 10 ? "…\(id.suffix(8))" : id
  }

  private func assignmentTitle(_ mode: AssignmentMode) -> String {
    switch mode {
    case .mostRecent: "Most Recent"
    case .pinned: "Pinned"
    case .priority: "Priority"
    case .custom: "Custom"
    }
  }

  private func roleTitle(_ role: ControlRole) -> String {
    switch role {
    case .off: "Off"
    case .agent: "Agent"
    case .command: "Command"
    }
  }

  private func commandTitle(_ command: PilotCommand) -> String {
    switch command {
    case .approve: "Approve"
    case .decline: "Decline"
    case .continueInNewChat: "Continue in new chat"
    case .nextSession: "Next session"
    case .previousSession: "Previous session"
    case .refreshSessions: "Refresh sessions"
    case .openSettings: "Open Settings"
    }
  }

  private func stateTitle(_ state: CodexSessionState) -> String {
    switch state {
    case .idle: "Idle"
    case .working: "Working"
    case .requiresInput: "Requires input"
    case .complete: "Complete"
    case .error: "Error"
    }
  }
}
