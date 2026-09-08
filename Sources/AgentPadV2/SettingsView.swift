import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var coordinator: AppCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @State private var section: SettingsSection = .controls
  @State private var selectedControl: ControlID = .sw1
  @State private var sessionsExpanded = false
  @State private var brightnessDraft = 100.0

  var body: some View {
    VStack(spacing: 0) {
      statusHeader
      Divider()
      Picker("Section", selection: $section) {
        ForEach(SettingsSection.allCases, id: \.self) { item in
          Text(item.title).tag(item)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 190)
      .padding(.vertical, 10)
      Divider()

      switch section {
      case .controls:
        ScrollView { controlsPane.padding(16) }
      case .lighting:
        ScrollView { lightingPane.padding(20) }
      }
    }
    .onAppear {
      brightnessDraft = Double(coordinator.settings.lighting.brightnessPercent)
    }
    .tint(GraphiteStyle.selection)
    .background(GraphiteStyle.windowSurface.ignoresSafeArea())
  }

  private var statusHeader: some View {
    VStack(spacing: 6) {
      HStack(spacing: 12) {
        Text("AgentPad13").font(.headline)
        Spacer(minLength: 8)
        StatusBadge(label: "Device", value: deviceSummary, color: deviceStatusColor)
        StatusBadge(label: "Input", value: inputSummary, color: inputStatusColor)
        StatusBadge(label: "Codex", value: codexSummary, color: codexStatusColor)
        hooksMenu
        if coordinator.device.input == .permissionRequired {
          Button("Open Input Monitoring") { coordinator.openInputMonitoringSettings() }
            .controlSize(.small)
        } else if deviceNeedsRetry {
          Button("Retry") { coordinator.retryDevice() }
            .controlSize(.small)
        }
        if codexNeedsRefresh {
          Button("Refresh") { coordinator.refreshSessions() }
            .controlSize(.small)
        }
      }

      if let error = coordinator.lastError {
        Label(error, systemImage: "exclamationmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(GraphiteStyle.headerSurface)
  }

  private var hooksMenu: some View {
    Menu {
      switch coordinator.hookStatus {
      case .installed:
        Button("Remove Hooks") { coordinator.removeHooks() }
      case .notInstalled:
        Button("Install Hooks") { coordinator.installHooks() }
      case .needsRepair, .invalid:
        Button("Repair Hooks") { coordinator.installHooks() }
        Button("Remove Hooks") { coordinator.removeHooks() }
      }
      if coordinator.hookStatus != .installed {
        Divider()
        Text(coordinator.hooksPath)
      }
    } label: {
      StatusBadge(label: "Hooks", value: hooksSummary, color: hooksStatusColor)
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Codex hook setup")
  }

  private var controlsPane: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Text("Agent assignment")
          .font(.callout)
          .foregroundStyle(.secondary)
        Picker("Agent assignment", selection: assignmentMode) {
          ForEach(AssignmentMode.allCases, id: \.self) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 430)
        Spacer(minLength: 0)
      }
      Toggle("Focus chats on one press", isOn: focusOnSingleTap)
        .toggleStyle(.switch)
        .help("When off, press the same Agent Key twice within 350 ms to open its Codex chat.")

      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("AgentPad13").fontWeight(.medium)
            Spacer()
            Text("Select a key to configure it")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          keyGrid
          sessionsAndPins
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        Divider()
        inspector
          .frame(width: 232, alignment: .topLeading)
      }
    }
  }

  private var keyGrid: some View {
    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
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
    .padding(10)
    .background(GraphiteStyle.hardwareCanvas(for: colorScheme))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(GraphiteStyle.separator, lineWidth: 1)
    }
    .shadow(color: GraphiteStyle.canvasShadow(for: colorScheme), radius: 8, y: 3)
  }

  private func key(_ control: ControlID) -> some View {
    let binding = coordinator.binding(for: control)
    let session = coordinator.resolvedSession(for: control)
    let presentation = keyPresentation(control: control, binding: binding, session: session)
    let selected = selectedControl == control

    return Button {
      selectedControl = control
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(control.title)
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer(minLength: 4)
          if binding.role == .agent {
            StateDot(
              state: session?.state,
              color: session?.state.map(color(for:)),
              selected: session?.id == coordinator.selectedSessionID
            )
          }
        }
        Spacer(minLength: 0)
        Text(presentation.title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(presentation.detail)
          .font(.caption)
          .foregroundStyle(
            presentation.unavailable
              ? Color.red
              : Color(nsColor: .secondaryLabelColor)
          )
          .lineLimit(1)
      }
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
      .background(
        selected
          ? GraphiteStyle.selectionFill(for: colorScheme)
          : GraphiteStyle.keySurface(for: colorScheme)
      )
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(
            selected ? GraphiteStyle.selection : GraphiteStyle.keyBorder(for: colorScheme),
            lineWidth: selected ? 2 : 1
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(control.title), \(presentation.title), \(presentation.detail)")
  }

  private var inspector: some View {
    let binding = coordinator.binding(for: selectedControl)
    let session = coordinator.resolvedSession(for: selectedControl)
    let presentation = keyPresentation(
      control: selectedControl,
      binding: binding,
      session: session
    )

    return VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(selectedControl.title).font(.title3.weight(.medium))
        Text("\(presentation.title) · \(presentation.detail)")
          .font(.callout)
          .foregroundStyle(
            presentation.unavailable
              ? Color.red
              : Color(nsColor: .secondaryLabelColor)
          )
          .lineLimit(2)
      }

      VStack(alignment: .leading, spacing: 5) {
        Text("Role")
          .font(.callout)
          .foregroundStyle(.secondary)
        Picker("Role", selection: roleBinding) {
          ForEach(ControlRole.allCases, id: \.self) { role in
            Text(role.shortTitle).tag(role)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      switch binding.role {
      case .off:
        EmptyView()
      case .agent:
        agentInspector
      case .command:
        commandInspector
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(GraphiteStyle.inspectorSurface)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(GraphiteStyle.separator, lineWidth: 1)
    }
    .shadow(color: GraphiteStyle.panelShadow(for: colorScheme), radius: 5, y: 2)
  }

  private var agentInspector: some View {
    VStack(alignment: .leading, spacing: 14) {
      if coordinator.settings.assignmentMode == .custom {
        VStack(alignment: .leading, spacing: 5) {
          Text("Exact session")
            .font(.callout)
            .foregroundStyle(.secondary)
          SessionPicker(sessions: sortedSessions, selection: customSessionBinding)
        }
      } else {
        LabeledContent("Assignment") {
          Text("\(coordinator.settings.assignmentMode.title) · position \(agentPosition)")
            .foregroundStyle(.secondary)
        }
      }

      Picker("Keycap", selection: opticsBinding) {
        ForEach(KeyOptics.allCases, id: \.self) { optics in
          Text(optics.title).tag(optics)
        }
      }
      Toggle("Status light", isOn: statusLightBinding)
        .toggleStyle(.switch)
    }
  }

  private var commandInspector: some View {
    Picker("Command", selection: commandBinding) {
      ForEach(PilotCommand.allCases, id: \.self) { command in
        Text(command.title).tag(PilotCommand?.some(command))
      }
    }
  }

  private var sessionsAndPins: some View {
    DisclosureGroup(isExpanded: $sessionsExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        Button("Refresh Sessions") { coordinator.refreshSessions() }
          .controlSize(.small)
        if coordinator.settings.assignmentMode == .pinned {
          pinnedSessions
        } else {
          observedSessions
        }
      }
      .padding(.top, 8)
    } label: {
      HStack {
        Text("Sessions & Pins")
        Spacer()
        Text("\(coordinator.sessions.count) active · \(coordinator.settings.pinnedSessionIDs.count) pinned")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .padding(.top, 2)
  }

  private var observedSessions: some View {
    Group {
      if sortedSessions.isEmpty {
        Text("No Codex sessions available").foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(sortedSessions) { session in
              SessionIdentity(session: session)
            }
          }
        }
        .frame(maxHeight: 180)
      }
    }
  }

  private var pinnedSessions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Pinned order").fontWeight(.medium)
      if coordinator.settings.pinnedSessionIDs.isEmpty {
        Text("No pinned sessions").foregroundStyle(.secondary)
      } else {
        ForEach(
          Array(coordinator.settings.pinnedSessionIDs.enumerated()),
          id: \.offset
        ) { index, id in
          HStack(spacing: 8) {
            SessionIdentity(session: session(id), unavailableID: id)
            Spacer(minLength: 4)
            Button { movePin(at: index, by: -1) } label: {
              Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help("Move earlier")
            Button { movePin(at: index, by: 1) } label: {
              Image(systemName: "chevron.down")
            }
            .disabled(index == coordinator.settings.pinnedSessionIDs.count - 1)
            .help("Move later")
            Button { removePin(id) } label: {
              Image(systemName: "minus.circle")
            }
            .help("Unpin")
          }
          .buttonStyle(.borderless)
        }
      }

      Divider()
      Text("Available sessions").fontWeight(.medium)
      if availableSessions.isEmpty {
        Text("All available sessions are pinned").foregroundStyle(.secondary)
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(availableSessions) { session in
              HStack(spacing: 8) {
                SessionIdentity(session: session)
                Spacer(minLength: 4)
                Button { addPin(session.id) } label: {
                  Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Pin")
              }
            }
          }
        }
        .frame(maxHeight: 180)
      }
    }
  }

  private var lightingPane: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("State colors").font(.headline)
          Spacer()
          Text("Agent Keys follow their assigned session")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 16) {
          ColorPicker("Idle", selection: paletteBinding(.idle), supportsOpacity: false)
          ColorPicker("Working", selection: paletteBinding(.working), supportsOpacity: false)
          ColorPicker(
            "Input",
            selection: paletteBinding(.requiresInput),
            supportsOpacity: false
          )
          ColorPicker("Complete", selection: paletteBinding(.complete), supportsOpacity: false)
          ColorPicker("Error", selection: paletteBinding(.error), supportsOpacity: false)
        }
      }
      Divider()
      HStack(alignment: .top, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Brightness")
            Spacer()
            Text("\(Int(brightnessDraft))%")
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Slider(
            value: $brightnessDraft,
            in: 0...100,
            step: 1,
            onEditingChanged: { editing in
              guard !editing else { return }
              coordinator.updateSettings {
                $0.lighting.brightnessPercent = Int(brightnessDraft)
              }
            }
          )
        }
        .frame(maxWidth: .infinity)
        Picker("Turn lights off after", selection: autoOffBinding) {
          Text("Never").tag(Int?.none)
          Text("30 seconds").tag(Int?.some(30))
          Text("1 minute").tag(Int?.some(60))
          Text("3 minutes").tag(Int?.some(180))
          Text("5 minutes").tag(Int?.some(300))
          Text("15 minutes").tag(Int?.some(900))
          Text("30 minutes").tag(Int?.some(1_800))
          Text("1 hour").tag(Int?.some(3_600))
        }
        .frame(maxWidth: .infinity)
      }
      Divider()
      Toggle("Band installed", isOn: bandInstalledBinding)
        .toggleStyle(.switch)
      if coordinator.settings.lighting.band.installation == .installed {
        HStack(spacing: 28) {
          Picker("Behavior", selection: bandModeBinding) {
            Text("Off").tag(BandMode.off)
            Text("Overall attention").tag(BandMode.overallAttention)
          }
          Picker("Optics", selection: bandOpticsBinding) {
            ForEach(KeyOptics.allCases, id: \.self) { optics in
              Text(optics.title).tag(optics)
            }
          }
        }
      }
    }
    .frame(maxWidth: 680, alignment: .topLeading)
    .frame(maxWidth: .infinity, alignment: .top)
  }

  private var sortedSessions: [CodexSession] {
    coordinator.sessions.sorted {
      if $0.lastActivity != $1.lastActivity {
        return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
      }
      return $0.id < $1.id
    }
  }

  private var availableSessions: [CodexSession] {
    sortedSessions.filter { !coordinator.settings.pinnedSessionIDs.contains($0.id) }
  }

  private var agentPosition: Int {
    (agentControls.firstIndex(of: selectedControl) ?? 0) + 1
  }

  private var agentControls: [ControlID] {
    ControlID.allCases.filter { coordinator.binding(for: $0).role == .agent }
  }

  private func session(_ id: String) -> CodexSession? {
    coordinator.sessions.first { $0.id == id }
  }

  private func keyPresentation(
    control: ControlID,
    binding: ControlBinding,
    session: CodexSession?
  ) -> (title: String, detail: String, unavailable: Bool) {
    switch binding.role {
    case .off:
      return ("Off", "No action", false)
    case .command:
      return (binding.command?.title ?? "Choose command", "Command", false)
    case .agent:
      if let session {
        return (session.title, session.state?.title ?? "State unavailable", false)
      }
      if coordinator.settings.assignmentMode == .custom,
        let id = binding.customSessionID
      {
        if coordinator.sessions.contains(where: { $0.id == id }) {
          return ("Unassigned", "Already assigned", false)
        }
        return ("Unavailable session", shortIdentity(id), true)
      }
      if coordinator.settings.assignmentMode == .pinned,
        let position = agentControls.firstIndex(of: control),
        coordinator.settings.pinnedSessionIDs.indices.contains(position)
      {
        let id = coordinator.settings.pinnedSessionIDs[position]
        return ("Unavailable session", shortIdentity(id), true)
      }
      return ("Unassigned", "No session", false)
    }
  }

  private func addPin(_ id: String) {
    coordinator.updateSettings { settings in
      guard !settings.pinnedSessionIDs.contains(id) else { return }
      settings.pinnedSessionIDs.append(id)
    }
  }

  private func removePin(_ id: String) {
    coordinator.updateSettings { settings in
      settings.pinnedSessionIDs.removeAll { $0 == id }
    }
  }

  private func movePin(at index: Int, by offset: Int) {
    coordinator.updateSettings { settings in
      let destination = index + offset
      guard settings.pinnedSessionIDs.indices.contains(index),
        settings.pinnedSessionIDs.indices.contains(destination)
      else { return }
      settings.pinnedSessionIDs.swapAt(index, destination)
    }
  }

  private var assignmentMode: Binding<AssignmentMode> {
    Binding(
      get: { coordinator.settings.assignmentMode },
      set: { mode in coordinator.updateSettings { $0.assignmentMode = mode } }
    )
  }

  private var focusOnSingleTap: Binding<Bool> {
    Binding(
      get: { coordinator.settings.focusOnSingleTap },
      set: { enabled in coordinator.updateSettings { $0.focusOnSingleTap = enabled } }
    )
  }

  private var customSessionBinding: Binding<String?> {
    Binding(
      get: { coordinator.binding(for: selectedControl).customSessionID },
      set: { id in coordinator.updateBinding(selectedControl) { $0.customSessionID = id } }
    )
  }

  private var roleBinding: Binding<ControlRole> {
    Binding(
      get: { coordinator.binding(for: selectedControl).role },
      set: { role in
        coordinator.updateBinding(selectedControl) { binding in
          binding.role = role
          if role == .command, binding.command == nil {
            binding.command = .approve
          }
        }
      }
    )
  }

  private var commandBinding: Binding<PilotCommand?> {
    Binding(
      get: { coordinator.binding(for: selectedControl).command },
      set: { command in coordinator.updateBinding(selectedControl) { $0.command = command } }
    )
  }

  private var statusLightBinding: Binding<Bool> {
    Binding(
      get: {
        coordinator.settings.lighting.keys.first(where: { $0.control == selectedControl })?
          .statusEnabled ?? false
      },
      set: { enabled in
        coordinator.updateSettings { settings in
          guard let index = settings.lighting.keys.firstIndex(where: {
            $0.control == selectedControl
          }) else { return }
          settings.lighting.keys[index].statusEnabled = enabled
        }
      }
    )
  }

  private var opticsBinding: Binding<KeyOptics> {
    Binding(
      get: {
        coordinator.settings.lighting.keys.first(where: { $0.control == selectedControl })?
          .optics ?? .unknown
      },
      set: { optics in
        coordinator.updateSettings { settings in
          guard let index = settings.lighting.keys.firstIndex(where: {
            $0.control == selectedControl
          }) else { return }
          settings.lighting.keys[index].optics = optics
        }
      }
    )
  }

  private var autoOffBinding: Binding<Int?> {
    Binding(
      get: { coordinator.settings.lighting.autoOffSeconds },
      set: { value in coordinator.updateSettings { $0.lighting.autoOffSeconds = value } }
    )
  }

  private var bandInstalledBinding: Binding<Bool> {
    Binding(
      get: { coordinator.settings.lighting.band.installation == .installed },
      set: { installed in
        coordinator.updateSettings {
          $0.lighting.band.installation = installed ? .installed : .absent
        }
      }
    )
  }

  private var bandModeBinding: Binding<BandMode> {
    Binding(
      get: { coordinator.settings.lighting.band.mode },
      set: { value in coordinator.updateSettings { $0.lighting.band.mode = value } }
    )
  }

  private var bandOpticsBinding: Binding<KeyOptics> {
    Binding(
      get: { coordinator.settings.lighting.band.optics },
      set: { value in coordinator.updateSettings { $0.lighting.band.optics = value } }
    )
  }

  private func paletteBinding(_ state: CodexSessionState) -> Binding<Color> {
    Binding(
      get: { color(for: state) },
      set: { color in
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
        let rgb = RGBColor(
          red: UInt8((converted.redComponent * 255).rounded()),
          green: UInt8((converted.greenComponent * 255).rounded()),
          blue: UInt8((converted.blueComponent * 255).rounded())
        )
        coordinator.updateSettings { settings in
          switch state {
          case .idle: settings.lighting.palette.idle = rgb
          case .working: settings.lighting.palette.working = rgb
          case .requiresInput: settings.lighting.palette.requiresInput = rgb
          case .complete: settings.lighting.palette.complete = rgb
          case .error: settings.lighting.palette.error = rgb
          }
        }
      }
    )
  }

  private func color(for state: CodexSessionState) -> Color {
    let rgb = coordinator.settings.lighting.palette[state]
    return Color(
      red: Double(rgb.red) / 255,
      green: Double(rgb.green) / 255,
      blue: Double(rgb.blue) / 255
    )
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

  private var deviceStatusColor: Color {
    switch coordinator.device.connection {
    case .ready: .green
    case .checking: .orange
    case .stopped, .disconnected, .incompatible: .red
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

  private var inputStatusColor: Color {
    coordinator.device.input == .ready ? .green : .red
  }

  private var codexSummary: String {
    coordinator.codexStatus.replacingOccurrences(of: "Codex: ", with: "")
  }

  private var codexStatusColor: Color {
    if coordinator.codexStatus.contains("sessions") { return .green }
    if coordinator.codexStatus.contains("Refreshing") { return .orange }
    return .red
  }

  private var deviceNeedsRetry: Bool {
    guard coordinator.device.input == .ready else { return true }
    return switch coordinator.device.connection {
    case .ready, .checking: false
    case .stopped, .disconnected, .incompatible: true
    }
  }

  private var codexNeedsRefresh: Bool {
    !coordinator.codexStatus.contains("sessions")
      && !coordinator.codexStatus.contains("Refreshing")
  }

  private var hooksSummary: String {
    switch coordinator.hookStatus {
    case .installed: "Installed"
    case .notInstalled: "Not installed"
    case .needsRepair: "Repair needed"
    case .invalid: "Invalid"
    }
  }

  private var hooksStatusColor: Color {
    switch coordinator.hookStatus {
    case .installed: .green
    case .notInstalled: .orange
    case .needsRepair, .invalid: .red
    }
  }
}

private enum GraphiteStyle {
  static let windowSurface = Color(nsColor: .windowBackgroundColor)
  static let headerSurface = Color(nsColor: .controlBackgroundColor)
  static let inspectorSurface = Color(nsColor: .controlBackgroundColor)
  static let controlSurface = Color(nsColor: .textBackgroundColor)
  static let controlBorder = Color(nsColor: .gridColor)
  static let separator = Color(nsColor: .separatorColor)
  static let selection = Color(nsColor: .systemBlue)

  static func hardwareCanvas(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 13 / 255, green: 15 / 255, blue: 19 / 255)
      : Color(nsColor: .underPageBackgroundColor)
  }

  static func keySurface(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 23 / 255, green: 26 / 255, blue: 32 / 255)
      : Color(nsColor: .windowBackgroundColor)
  }

  static func keyBorder(for scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color.white.opacity(0.10)
      : Color(nsColor: .separatorColor)
  }

  static func selectionFill(for scheme: ColorScheme) -> Color {
    selection.opacity(scheme == .dark ? 0.16 : 0.10)
  }

  static func canvasShadow(for scheme: ColorScheme) -> Color {
    Color.black.opacity(scheme == .dark ? 0.28 : 0.08)
  }

  static func panelShadow(for scheme: ColorScheme) -> Color {
    Color.black.opacity(scheme == .dark ? 0.18 : 0.05)
  }
}

private enum SettingsSection: CaseIterable {
  case controls
  case lighting

  var title: String {
    switch self {
    case .controls: "Controls"
    case .lighting: "Lighting"
    }
  }
}

private struct StatusBadge: View {
  let label: String
  let value: String
  let color: Color

  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text("\(label) \(value)")
        .font(.callout)
        .lineLimit(1)
    }
    .foregroundStyle(.secondary)
  }
}

private struct StateDot: View {
  let state: CodexSessionState?
  var color: Color?
  var selected = false

  init(state: CodexSessionState?, color: Color? = nil, selected: Bool = false) {
    self.state = state
    self.color = color
    self.selected = selected
  }

  var body: some View {
    Circle()
      .fill(color ?? state?.displayColor ?? Color(nsColor: .separatorColor))
      .frame(width: 8, height: 8)
      .overlay {
        if selected {
          Circle()
            .stroke((color ?? state?.displayColor)?.opacity(0.35) ?? .clear, lineWidth: 3)
            .frame(width: 13, height: 13)
        }
      }
  }
}

private struct SessionIdentity: View {
  let session: CodexSession?
  var unavailableID: String?

  init(session: CodexSession?, unavailableID: String? = nil) {
    self.session = session
    self.unavailableID = unavailableID
  }

  var body: some View {
    HStack(spacing: 8) {
      StateDot(state: session?.state)
      VStack(alignment: .leading, spacing: 1) {
        Text(session?.title ?? "Unavailable session").lineLimit(1)
        Text(identity)
          .font(.caption)
          .foregroundStyle(
            session == nil ? Color.red : Color(nsColor: .secondaryLabelColor)
          )
          .lineLimit(1)
      }
    }
  }

  private var identity: String {
    guard let session else { return shortIdentity(unavailableID ?? "") }
    let location = session.path ?? "Codex"
    let state = session.state?.title ?? "State unavailable"
    return "\(state) · \(location) · \(shortIdentity(session.id))"
  }
}

private struct SessionPicker: View {
  let sessions: [CodexSession]
  @Binding var selection: String?
  @State private var presented = false
  @State private var query = ""

  var body: some View {
    Button {
      presented = true
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 1) {
          Text(selectedSession?.title ?? (selection == nil ? "Unassigned" : "Unavailable session"))
            .lineLimit(1)
          if let selection {
            Text(selectedSession.map(identity) ?? "Unavailable · \(shortIdentity(selection))")
              .font(.caption)
              .foregroundStyle(
                selectedSession == nil ? Color.red : Color(nsColor: .secondaryLabelColor)
              )
              .lineLimit(1)
          }
        }
        Spacer(minLength: 6)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
      .background(GraphiteStyle.controlSurface)
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(GraphiteStyle.controlBorder, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .popover(isPresented: $presented, arrowEdge: .trailing) {
      VStack(alignment: .leading, spacing: 8) {
        TextField("Search sessions", text: $query)
          .textFieldStyle(.roundedBorder)
        ScrollView {
          LazyVStack(spacing: 2) {
            choice(id: nil, title: "Unassigned", detail: "No session")
            if let selection, selectedSession == nil {
              choice(
                id: selection,
                title: "Unavailable session",
                detail: shortIdentity(selection),
                unavailable: true
              )
            }
            ForEach(filteredSessions) { session in
              choice(id: session.id, title: session.title, detail: identity(session))
            }
          }
        }
        .frame(height: 260)
      }
      .padding(12)
      .frame(width: 360)
    }
  }

  private var selectedSession: CodexSession? {
    guard let selection else { return nil }
    return sessions.first { $0.id == selection }
  }

  private var filteredSessions: [CodexSession] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return sessions }
    return sessions.filter {
      $0.title.localizedCaseInsensitiveContains(needle)
        || $0.id.localizedCaseInsensitiveContains(needle)
        || ($0.path?.localizedCaseInsensitiveContains(needle) ?? false)
    }
  }

  private func identity(_ session: CodexSession) -> String {
    let state = session.state?.title ?? "State unavailable"
    return "\(state) · \(session.path ?? "Codex") · \(shortIdentity(session.id))"
  }

  private func choice(
    id: String?,
    title: String,
    detail: String,
    unavailable: Bool = false
  ) -> some View {
    Button {
      selection = id
      presented = false
      query = ""
    } label: {
      HStack(spacing: 8) {
        Image(systemName: selection == id ? "checkmark" : "")
          .frame(width: 12)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).lineLimit(1)
          Text(detail)
            .font(.caption)
            .foregroundStyle(
              unavailable ? Color.red : Color(nsColor: .secondaryLabelColor)
            )
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private extension ControlRole {
  var shortTitle: String {
    switch self {
    case .off: "Off"
    case .agent: "Agent"
    case .command: "Command"
    }
  }
}

private extension AssignmentMode {
  var title: String {
    switch self {
    case .mostRecent: "Most Recent"
    case .pinned: "Pinned"
    case .priority: "Priority"
    case .custom: "Custom"
    }
  }
}

private extension PilotCommand {
  var title: String {
    switch self {
    case .approve: "Approve"
    case .decline: "Decline"
    case .continueInNewChat: "Continue in new chat"
    case .nextSession: "Next session"
    case .previousSession: "Previous session"
    case .refreshSessions: "Refresh sessions"
    case .openSettings: "Open Settings"
    }
  }
}

private extension CodexSessionState {
  var title: String {
    switch self {
    case .idle: "Idle"
    case .working: "Working"
    case .requiresInput: "Requires input"
    case .complete: "Complete"
    case .error: "Error"
    }
  }

  var displayColor: Color {
    switch self {
    case .idle: Color(nsColor: .secondaryLabelColor)
    case .working: .blue
    case .requiresInput: .orange
    case .complete: .green
    case .error: .red
    }
  }
}

private extension KeyOptics {
  var title: String {
    switch self {
    case .unknown: "Unknown"
    case .opaque: "Opaque"
    case .translucent: "Translucent"
    }
  }
}

private func shortIdentity(_ id: String) -> String {
  guard id.count > 10 else { return id }
  return "…\(id.suffix(8))"
}
