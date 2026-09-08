import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject {
  @Published private(set) var settings: AgentPadSettings
  @Published private(set) var sessions: [CodexSession] = []
  @Published private(set) var selectedSessionID: String?
  @Published private(set) var codexStatus = "Codex: Not connected"
  @Published private(set) var hookStatus: CodexHookSetupStatus = .notInstalled
  @Published private(set) var lastError: String?

  let device = AgentPadDevice()

  private var deviceChanges: AnyCancellable?
  private var terminationObserver: NSObjectProtocol?
  private var started = false
  private var codex: CodexAppServer?
  private var hookServer: CodexHookServer?
  private var pendingPermissions: [String: CodexPermissionResponder] = [:]
  private var refreshTask: Task<Void, Never>?
  private var continueTask: Task<Void, Never>?
  private var autoOffTask: Task<Void, Never>?
  private var settingsWindowController: NSWindowController?
  private var lightsAreAwake = true
  private var pendingCreatedFocusID: String?
  private var previousAgentPress: (control: ControlID, sessionID: String, time: TimeInterval)?

  init(defaults: UserDefaults = .standard) {
    settings = SettingsStore.load(from: defaults)
    deviceChanges = device.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
    }
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.shutdown() }
    }
    Task { @MainActor [weak self] in self?.start() }
  }

  var deviceStatus: String {
    let connection = switch device.connection {
    case .stopped: "Stopped"
    case .checking: "Checking"
    case .disconnected: "Disconnected"
    case .incompatible: "Incompatible"
    case .ready: "Connected"
    }
    let input = switch device.input {
    case .stopped: "Stopped"
    case .ready: "Ready"
    case .permissionRequired: "Input Monitoring required"
    case .failed: "Unavailable"
    }
    return "Device: \(connection) · Input: \(input)"
  }

  func start() {
    guard !started else { return }
    started = true
    device.start { [weak self] control in self?.handlePress(control) }
    do {
      codex = try CodexAppServer.live()
      let server = CodexHookServer { [weak self] event in self?.receive(event) }
      try server.start()
      hookServer = server
      refreshHookStatus()
      refreshSessions()
    } catch {
      codexStatus = "Codex: \(error.localizedDescription)"
    }
    redraw()
  }

  func shutdown() {
    guard started else { return }
    started = false
    refreshTask?.cancel()
    continueTask?.cancel()
    autoOffTask?.cancel()
    hookServer?.stop()
    hookServer = nil
    for responder in pendingPermissions.values { responder.cancel() }
    pendingPermissions.removeAll()
    device.shutdown()
  }

  func updateSettings(_ change: (inout AgentPadSettings) -> Void) {
    var updated = settings
    change(&updated)
    settings = updated
    do {
      try SettingsStore.save(updated)
      lastError = nil
    } catch {
      lastError = "Settings could not be saved."
    }
    redraw()
  }

  func replaceSessions(_ updated: [CodexSession]) {
    sessions = updated
    if let selectedSessionID, !updated.contains(where: { $0.id == selectedSessionID }) {
      self.selectedSessionID = nil
    }
    redraw()
  }

  func selectSession(_ id: String?) {
    selectedSessionID = id
    redraw()
  }

  func refreshSessions() {
    guard let codex else {
      codexStatus = "Codex: Not available"
      return
    }
    refreshTask?.cancel()
    codexStatus = "Codex: Refreshing"
    refreshTask = Task { [weak self] in
      do {
        let threads = try await codex.listThreads()
        try Task.checkCancellation()
        guard let self else { return }
        let current = Dictionary(uniqueKeysWithValues: self.sessions.map { ($0.id, $0) })
        self.replaceSessions(threads.map { thread in
          CodexSession(
            id: thread.id,
            title: thread.title,
            path: thread.path,
            lastActivity: thread.lastActivity,
            state: current[thread.id]?.state
          )
        })
        self.codexStatus = "Codex: \(threads.count) sessions"
      } catch is CancellationError {
      } catch {
        self?.codexStatus = "Codex: \(error.localizedDescription)"
      }
    }
  }

  func retryDevice() {
    device.retry()
    redraw()
  }

  func openInputMonitoringSettings() {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )!
    if !NSWorkspace.shared.open(url) {
      lastError = "Input Monitoring settings could not be opened."
    }
  }

  func showSettings() {
    if let window = settingsWindowController?.window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }

    let content = SettingsView(coordinator: self)
      .frame(minWidth: 700, idealWidth: 780, minHeight: 360, idealHeight: 560)
    let window = NSWindow(contentViewController: NSHostingController(rootView: content))
    window.title = "AgentPad13"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.minSize = NSSize(width: 700, height: 360)
    window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 560)
    window.setContentSize(NSSize(width: 780, height: 560))
    window.center()
    window.isReleasedWhenClosed = false

    let controller = NSWindowController(window: window)
    settingsWindowController = controller
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }

  func handlePress(_ control: ControlID) {
    redraw()
    let controlBinding = binding(for: control)
    switch controlBinding.role {
    case .off:
      return
    case .agent:
      guard let session = resolvedSession(for: control) else { return }
      selectSession(session.id)
      handleFocusGesture(control: control, sessionID: session.id)
    case .command:
      guard let command = controlBinding.command else { return }
      dispatchLocal(command)
    }
  }

  func installHooks() {
    do {
      let setup = try CodexHookSetup.live()
      hookStatus = try setup.install()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      refreshHookStatus()
    }
  }

  func removeHooks() {
    do {
      let setup = try CodexHookSetup.live()
      hookStatus = try setup.remove()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      refreshHookStatus()
    }
  }

  func refreshHookStatus() {
    do {
      hookStatus = try CodexHookSetup.live().status()
    } catch {
      hookStatus = .invalid(error.localizedDescription)
    }
  }

  var hooksPath: String {
    (try? CodexHookSetup.live().hooksURL.path) ?? "~/.codex/hooks.json"
  }

  func binding(for control: ControlID) -> ControlBinding {
    settings.controls.first(where: { $0.control == control })
      ?? ControlBinding(control: control)
  }

  func updateBinding(_ control: ControlID, _ change: (inout ControlBinding) -> Void) {
    updateSettings { settings in
      guard let index = settings.controls.firstIndex(where: { $0.control == control }) else {
        return
      }
      change(&settings.controls[index])
    }
  }

  func resolvedSession(for control: ControlID) -> CodexSession? {
    resolvedSessions()[control] ?? nil
  }

  func resolvedSessions() -> [ControlID: CodexSession?] {
    let agentControls = ControlID.allCases.filter { binding(for: $0).role == .agent }
    let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    var result: [ControlID: CodexSession?] = [:]

    switch settings.assignmentMode {
    case .custom:
      var used = Set<String>()
      for control in agentControls {
        let id = binding(for: control).customSessionID
        result[control] = id.flatMap { used.insert($0).inserted ? byID[$0] : nil }
      }
    case .pinned:
      for (offset, control) in agentControls.enumerated() {
        guard settings.pinnedSessionIDs.indices.contains(offset) else {
          result[control] = nil
          continue
        }
        result[control] = byID[settings.pinnedSessionIDs[offset]]
      }
    case .mostRecent:
      assign(sessions.sorted(by: recencyOrder), to: agentControls, result: &result)
    case .priority:
      assign(sessions.sorted(by: priorityOrder), to: agentControls, result: &result)
    }

    return result
  }

  func resolvedLight(for control: ControlID) -> (color: RGBColor, pulses: Bool)? {
    guard binding(for: control).role == .agent,
      settings.lighting.keys.first(where: { $0.control == control })?.statusEnabled == true,
      let session = resolvedSession(for: control),
      let state = session.state
    else { return nil }

    return (
      settings.lighting.palette[state],
      selectedSessionID == session.id
    )
  }

  private func assign(
    _ orderedSessions: [CodexSession],
    to controls: [ControlID],
    result: inout [ControlID: CodexSession?]
  ) {
    for (offset, control) in controls.enumerated() {
      result[control] = orderedSessions.indices.contains(offset) ? orderedSessions[offset] : nil
    }
  }

  private func recencyOrder(_ lhs: CodexSession, _ rhs: CodexSession) -> Bool {
    switch (lhs.lastActivity, rhs.lastActivity) {
    case let (left?, right?) where left != right: return left > right
    case (.some, nil): return true
    case (nil, .some): return false
    default: return lhs.id < rhs.id
    }
  }

  private func priorityOrder(_ lhs: CodexSession, _ rhs: CodexSession) -> Bool {
    let left = priority(lhs.state)
    let right = priority(rhs.state)
    return left == right ? recencyOrder(lhs, rhs) : left < right
  }

  private func priority(_ state: CodexSessionState?) -> Int {
    switch state {
    case .requiresInput: return 0
    case .complete, .error: return 1
    case .working: return 2
    case .idle: return 3
    case nil: return 4
    }
  }

  private func dispatchLocal(_ command: PilotCommand) {
    switch command {
    case .nextSession:
      cycleSession(by: 1)
    case .previousSession:
      cycleSession(by: -1)
    case .refreshSessions:
      refreshSessions()
    case .openSettings:
      showSettings()
    case .approve, .decline, .continueInNewChat:
      dispatchCodex(command)
    }
  }

  private func dispatchCodex(_ command: PilotCommand) {
    guard let selectedSessionID else {
      lastError = "Select a Codex session first."
      return
    }
    switch command {
    case .approve, .decline:
      guard let responder = pendingPermissions.removeValue(forKey: selectedSessionID) else {
        lastError = "No permission request is waiting for that session."
        return
      }
      let decision: CodexPermissionDecision = command == .approve ? .allow : .deny
      lastError = responder.resolve(decision) ? nil : "That permission request is no longer waiting."
    case .continueInNewChat:
      continueInNewChat(from: selectedSessionID)
    case .nextSession, .previousSession, .refreshSessions, .openSettings:
      return
    }
  }

  private func continueInNewChat(from sessionID: String) {
    guard let codex else {
      lastError = "Codex is not available."
      return
    }
    if pendingCreatedFocusID == sessionID {
      do {
        try codex.focus(threadID: sessionID)
        pendingCreatedFocusID = nil
        lastError = nil
      } catch {
        lastError = "The new chat exists, but Codex could not open it."
      }
      return
    }
    guard continueTask == nil else { return }
    continueTask = Task { [weak self] in
      do {
        let thread = try await codex.fork(threadID: sessionID)
        guard let self else { return }
        self.merge(thread: thread, state: nil)
        self.selectSession(thread.id)
        do {
          try codex.focus(threadID: thread.id)
          self.lastError = nil
        } catch {
          self.pendingCreatedFocusID = thread.id
          self.lastError = "The new chat exists, but Codex could not open it."
        }
      } catch {
        self?.lastError = error.localizedDescription
      }
      self?.continueTask = nil
    }
  }

  private func handleFocusGesture(control: ControlID, sessionID: String) {
    guard let codex else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let shouldFocus = settings.focusOnSingleTap
      || previousAgentPress.map {
        $0.control == control && $0.sessionID == sessionID && now - $0.time <= 0.35
      } == true
    previousAgentPress = settings.focusOnSingleTap
      ? nil
      : (control, sessionID, now)
    guard shouldFocus else { return }
    do {
      try codex.focus(threadID: sessionID)
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func receive(_ event: CodexHookEvent) {
    if event.kind == .sessionEnd {
      pendingPermissions.removeValue(forKey: event.sessionID)?.cancel()
      sessions.removeAll { $0.id == event.sessionID }
      if selectedSessionID == event.sessionID { selectedSessionID = nil }
      redraw()
      return
    }

    if let responder = event.responder {
      pendingPermissions.removeValue(forKey: event.sessionID)?.cancel()
      pendingPermissions[event.sessionID] = responder
    } else if event.kind != .permissionRequest {
      pendingPermissions.removeValue(forKey: event.sessionID)?.cancel()
    }

    let existing = sessions.first(where: { $0.id == event.sessionID })
    let thread = CodexThread(
      id: event.sessionID,
      title: existing?.title ?? event.sessionID,
      path: event.cwd ?? existing?.path,
      lastActivity: Date()
    )
    merge(thread: thread, state: event.kind.state)
  }

  private func merge(thread: CodexThread, state: CodexSessionState?) {
    let session = CodexSession(
      id: thread.id,
      title: thread.title,
      path: thread.path,
      lastActivity: thread.lastActivity,
      state: state
    )
    if let index = sessions.firstIndex(where: { $0.id == thread.id }) {
      sessions[index] = session
    } else {
      sessions.append(session)
    }
    redraw()
  }

  private func cycleSession(by offset: Int) {
    let ordered = sessions.sorted(by: recencyOrder)
    guard !ordered.isEmpty else { return }
    let current = ordered.firstIndex(where: { $0.id == selectedSessionID }) ?? 0
    let next = (current + offset + ordered.count) % ordered.count
    selectSession(ordered[next].id)
  }

  private func redraw() {
    lightsAreAwake = true
    scheduleAutoOff()
    renderLights()
  }

  private func renderLights() {
    var frame = AgentPadLEDFrame()
    guard lightsAreAwake else {
      device.apply(frame)
      return
    }
    for control in ControlID.keys {
      guard let address = AgentPadLEDAddress.key(control),
        let light = resolvedLight(for: control)
      else { continue }
      frame[address] = AgentPadLEDOutput(
        color: scaled(light.color),
        effect: light.pulses ? .pulse : .solid
      )
    }

    if let attention = sessions.sorted(by: priorityOrder).first(where: { $0.state != nil }),
      let state = attention.state
    {
      let output = AgentPadLEDOutput(
        color: scaled(settings.lighting.palette[state]),
        effect: .solid
      )
      frame[AgentPadLEDAddress.indicator] = output
      if settings.lighting.band.installation == .installed,
        settings.lighting.band.mode == .overallAttention
      {
        for address in AgentPadLEDAddress.band { frame[address] = output }
      }
    }
    device.apply(frame)
  }

  private func scheduleAutoOff() {
    autoOffTask?.cancel()
    guard let seconds = settings.lighting.autoOffSeconds, seconds > 0 else { return }
    autoOffTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard !Task.isCancelled, let self else { return }
      self.lightsAreAwake = false
      self.renderLights()
    }
  }

  private func scaled(_ color: RGBColor) -> RGBColor {
    let fraction = Double(min(max(settings.lighting.brightnessPercent, 0), 100)) / 100
    return RGBColor(
      red: UInt8(Double(color.red) * fraction),
      green: UInt8(Double(color.green) * fraction),
      blue: UInt8(Double(color.blue) * fraction)
    )
  }
}
