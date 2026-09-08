import CHIDAPI
import Combine
import Foundation
import IOKit.hid

enum AgentPadDeviceConnection: Equatable, Sendable {
  case stopped
  case checking
  case disconnected
  case incompatible(String)
  case ready
}

enum AgentPadInputState: Equatable, Sendable {
  case stopped
  case ready
  case permissionRequired
  case failed(String)
}

enum AgentPadLEDEffect: UInt8, Sendable {
  case solid = 0
  case pulse = 1
  case blink = 2
}

struct AgentPadLEDOutput: Equatable, Sendable {
  var color: RGBColor
  var effect: AgentPadLEDEffect

  static let off = AgentPadLEDOutput(
    color: RGBColor(red: 0, green: 0, blue: 0),
    effect: .solid
  )
}

struct AgentPadLEDFrame: Equatable, Sendable {
  static let count = 24

  private(set) var outputs = Array(
    repeating: AgentPadLEDOutput.off,
    count: AgentPadLEDFrame.count
  )

  subscript(address: Int) -> AgentPadLEDOutput {
    get {
      precondition((0..<Self.count).contains(address))
      return outputs[address]
    }
    set {
      precondition((0..<Self.count).contains(address))
      outputs[address] = newValue
    }
  }
}

enum AgentPadLEDAddress {
  static let indicator = 13
  static let band = 14...23

  static func key(_ control: ControlID) -> Int? {
    guard let index = ControlID.keys.firstIndex(of: control) else { return nil }
    return index
  }
}

@MainActor
final class AgentPadDevice: ObservableObject {
  @Published private(set) var connection: AgentPadDeviceConnection = .stopped
  @Published private(set) var input: AgentPadInputState = .stopped

  var connectionDidChange: ((AgentPadDeviceConnection) -> Void)?
  var onPress: ((ControlID) -> Void)?

  private let inputMonitor = AgentPadInputMonitor()
  private var transport: AgentPadHIDTransport?

  func start(onPress: @escaping (ControlID) -> Void) {
    self.onPress = onPress
    retry()
  }

  /// The only reconnect path. It retries ordinary HID input and performs one
  /// protocol PING before allowing the retained latest LED frame to resume.
  func retry() {
    inputMonitor.stop()
    do {
      try inputMonitor.start { [weak self] control in
        Task { @MainActor in self?.onPress?(control) }
      }
      input = .ready
    } catch AgentPadInputMonitor.InputError.permissionRequired {
      input = .permissionRequired
    } catch {
      input = .failed(error.localizedDescription)
    }

    let transport = transport ?? makeTransport()
    self.transport = transport
    publish(.checking)
    transport.checkReadiness { [weak self, weak transport] result in
      Task { @MainActor in
        guard let self, let transport, self.transport === transport else { return }
        switch result {
        case .success:
          self.publish(.ready)
        case .failure(.incompatible(let reason)):
          self.publish(.incompatible(reason))
        case .failure:
          self.publish(.disconnected)
        }
      }
    }
  }

  /// Submits one complete desired state. Transport work never blocks the main
  /// actor; an in-flight frame is followed only by the newest replacement.
  func apply(_ frame: AgentPadLEDFrame) {
    transport?.apply(frame)
  }

  /// Returns lighting ownership to firmware before closing either HID path.
  func shutdown() {
    inputMonitor.stop()
    input = .stopped
    transport?.clearAndStop()
    transport = nil
    onPress = nil
    publish(.stopped)
  }

  private func makeTransport() -> AgentPadHIDTransport {
    AgentPadHIDTransport { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.publish(.disconnected)
      }
    }
  }

  private func publish(_ state: AgentPadDeviceConnection) {
    connection = state
    connectionDidChange?(state)
  }
}

private final class AgentPadInputMonitor: @unchecked Sendable {
  enum InputError: LocalizedError {
    case permissionRequired
    case openFailed(IOReturn)

    var errorDescription: String? {
      switch self {
      case .permissionRequired:
        "Input Monitoring is required."
      case .openFailed(let code):
        "AgentPad13 input could not open (IOKit \(code))."
      }
    }
  }

  private var manager: IOHIDManager?
  private var onPress: (@Sendable (ControlID) -> Void)?

  func start(onPress: @escaping @Sendable (ControlID) -> Void) throws {
    guard manager == nil else { return }

    let manager = IOHIDManagerCreate(
      kCFAllocatorDefault,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )
    let match: [String: Any] = [
      kIOHIDVendorIDKey as String: AgentPadHIDProtocol.vendorID,
      kIOHIDProductIDKey as String: AgentPadHIDProtocol.productID,
    ]
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    IOHIDManagerRegisterInputValueCallback(
      manager,
      agentPadInputCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    IOHIDManagerScheduleWithRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )

    let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else {
      IOHIDManagerUnscheduleFromRunLoop(
        manager,
        CFRunLoopGetMain(),
        CFRunLoopMode.commonModes.rawValue
      )
      if result == kIOReturnNotPermitted {
        throw InputError.permissionRequired
      }
      throw InputError.openFailed(result)
    }

    self.onPress = onPress
    self.manager = manager
  }

  func stop() {
    guard let manager else { return }
    IOHIDManagerUnscheduleFromRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    self.manager = nil
    onPress = nil
  }

  fileprivate func receive(_ value: IOHIDValue) {
    guard IOHIDValueGetIntegerValue(value) != 0 else { return }
    let element = IOHIDValueGetElement(value)
    let page = Int(IOHIDElementGetUsagePage(element))
    let usage = Int(IOHIDElementGetUsage(element))

    let control: ControlID?
    if page == 0x07, (0x68...0x73).contains(usage) {
      control = ControlID.keys[usage - 0x68]
    } else if page == 0x0C, usage == 0xCD {
      control = .sw13
    } else {
      control = nil
    }
    if let control { onPress?(control) }
  }
}

private let agentPadInputCallback: IOHIDValueCallback = {
  context,
  result,
  _,
  value in
  guard result == kIOReturnSuccess, let context else { return }
  Unmanaged<AgentPadInputMonitor>.fromOpaque(context)
    .takeUnretainedValue()
    .receive(value)
}

private enum AgentPadHIDProtocol {
  static let vendorID = 0xFEED
  static let productID = 0x4C4D
  static let usagePage = 0xFF60
  static let usage = 0x61
  static let reportSize = 32
  static let protocolVersion: UInt8 = 1
  static let setKey: UInt8 = 0x01
  static let clear: UInt8 = 0x03
  static let ping: UInt8 = 0x04

  static func pingReport(token: UInt8) -> [UInt8] {
    padded([ping, token])
  }

  static func setKeyReport(address: Int, output: AgentPadLEDOutput) -> [UInt8] {
    var effect = output.effect
    if address == 0, output.color == AgentPadLEDOutput.off.color, effect == .solid {
      // Black/solid at address zero is byte-identical to Vial's handshake.
      effect = .pulse
    }
    return padded([
      setKey,
      UInt8(address),
      output.color.red,
      output.color.green,
      output.color.blue,
      effect.rawValue,
    ])
  }

  static let clearReport = padded([clear])

  static func validateCapabilities(_ report: [UInt8], token: UInt8) throws {
    guard report.count == reportSize,
      report[0] == ping,
      report[1] == token,
      report[2] == 0x4C,
      report[3] == 0x44,
      report[4] == protocolVersion,
      report[5] >= UInt8(AgentPadLEDFrame.count),
      report[7] & 0x01 != 0
    else {
      throw AgentPadHIDTransport.TransportError.incompatible(
        "AgentPad13 Raw HID protocol is incompatible."
      )
    }
  }

  private static func padded(_ bytes: [UInt8]) -> [UInt8] {
    bytes + Array(repeating: 0, count: reportSize - bytes.count)
  }
}

private final class AgentPadHIDTransport: @unchecked Sendable {
  enum TransportError: Error, Equatable {
    case noDevice
    case io
    case timeout
    case incompatible(String)
  }

  private let queue = DispatchQueue(label: "app.agentpad13.v2.hid")
  private let lock = NSLock()
  private let onFrameFailure: @Sendable () -> Void

  // Protected by lock.
  private var desiredFrame: AgentPadLEDFrame?
  private var frameWorkerScheduled = false
  private var framesBlocked = true
  private var readinessGeneration: UInt64 = 0
  private var stopped = false

  // Confined to queue.
  private var initialized = false
  private var handle: OpaquePointer?
  private var nextToken: UInt8 = 0xA5
  private var accepted = Array<AgentPadLEDOutput?>(
    repeating: nil,
    count: AgentPadLEDFrame.count
  )

  init(onFrameFailure: @escaping @Sendable () -> Void) {
    self.onFrameFailure = onFrameFailure
  }

  func apply(_ frame: AgentPadLEDFrame) {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    desiredFrame = frame
    scheduleFrameWorkerIfNeededLocked()
    lock.unlock()
  }

  func checkReadiness(
    completion: @escaping @Sendable (Result<Void, TransportError>) -> Void
  ) {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      completion(.failure(.noDevice))
      return
    }
    readinessGeneration &+= 1
    let generation = readinessGeneration
    framesBlocked = true
    lock.unlock()

    queue.async { [weak self] in
      guard let self else { return }
      let result: Result<Void, TransportError>
      do {
        try self.probe()
        result = .success(())
      } catch let error as TransportError {
        result = .failure(error)
      } catch {
        result = .failure(.io)
      }

      self.lock.lock()
      guard !self.stopped, generation == self.readinessGeneration else {
        self.lock.unlock()
        return
      }
      if case .success = result {
        self.accepted = Array(repeating: nil, count: AgentPadLEDFrame.count)
        self.framesBlocked = false
        self.scheduleFrameWorkerIfNeededLocked()
      }
      self.lock.unlock()
      completion(result)
    }
  }

  func clearAndStop() {
    lock.lock()
    guard !stopped else {
      lock.unlock()
      return
    }
    stopped = true
    readinessGeneration &+= 1
    framesBlocked = true
    desiredFrame = nil
    lock.unlock()

    queue.sync {
      if let handle {
        try? write(AgentPadHIDProtocol.clearReport, to: handle)
      }
      closeDevice()
      if initialized {
        hid_exit()
        initialized = false
      }
    }
  }

  private func scheduleFrameWorkerIfNeededLocked() {
    guard !framesBlocked, desiredFrame != nil, !frameWorkerScheduled else { return }
    frameWorkerScheduled = true
    queue.async { [weak self] in self?.drainFrames() }
  }

  private func drainFrames() {
    while true {
      lock.lock()
      guard !stopped, !framesBlocked, let frame = desiredFrame else {
        frameWorkerScheduled = false
        lock.unlock()
        return
      }
      desiredFrame = nil
      lock.unlock()

      do {
        try writeChangedOutputs(frame)
      } catch {
        lock.lock()
        accepted = Array(repeating: nil, count: AgentPadLEDFrame.count)
        framesBlocked = true
        if desiredFrame == nil { desiredFrame = frame }
        frameWorkerScheduled = false
        lock.unlock()
        onFrameFailure()
        return
      }
    }
  }

  private func writeChangedOutputs(_ frame: AgentPadLEDFrame) throws {
    let handle = try openDevice()
    for address in 0..<AgentPadLEDFrame.count {
      let output = frame.outputs[address]
      guard accepted[address] != output else { continue }
      try write(
        AgentPadHIDProtocol.setKeyReport(address: address, output: output),
        to: handle
      )
      accepted[address] = output
    }
  }

  private func probe() throws {
    let handle = try openDevice()
    try discardPendingInput(from: handle)
    let token = nextToken
    nextToken &+= 1
    let report = AgentPadHIDProtocol.pingReport(token: token)
    try write(report, to: handle)

    var input = [UInt8](repeating: 0, count: AgentPadHIDProtocol.reportSize)
    let deadline = Date().addingTimeInterval(0.5)
    while deadline.timeIntervalSinceNow > 0 {
      let milliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
      let count = input.withUnsafeMutableBufferPointer {
        hid_read_timeout(handle, $0.baseAddress, $0.count, milliseconds)
      }
      if count < 0 {
        closeDevice()
        throw TransportError.io
      }
      if count == 0 { throw TransportError.timeout }

      let reply = Array(input.prefix(Int(count)))
      guard reply.count >= 2, reply[0] == report[0], reply[1] == report[1] else {
        continue
      }
      try AgentPadHIDProtocol.validateCapabilities(reply, token: token)
      return
    }
    throw TransportError.timeout
  }

  private func openDevice() throws -> OpaquePointer {
    if let handle { return handle }
    if !initialized {
      guard hid_init() == 0 else { throw TransportError.io }
      hid_darwin_set_open_exclusive(0)
      initialized = true
    }

    guard let devices = hid_enumerate(
      UInt16(AgentPadHIDProtocol.vendorID),
      UInt16(AgentPadHIDProtocol.productID)
    ) else {
      throw TransportError.noDevice
    }
    defer { hid_free_enumeration(devices) }

    var candidate: UnsafeMutablePointer<hid_device_info>? = devices
    while let current = candidate {
      let info = current.pointee
      if Int(info.usage_page) == AgentPadHIDProtocol.usagePage,
        Int(info.usage) == AgentPadHIDProtocol.usage,
        let path = info.path
      {
        guard let opened = hid_open_path(path) else { throw TransportError.io }
        handle = opened
        return opened
      }
      candidate = info.next
    }
    throw TransportError.noDevice
  }

  private func write(_ report: [UInt8], to handle: OpaquePointer) throws {
    let bytes = [UInt8(0)] + report
    let count = bytes.withUnsafeBufferPointer {
      hid_write(handle, $0.baseAddress, $0.count)
    }
    guard count == bytes.count else {
      closeDevice()
      throw TransportError.io
    }
  }

  private func discardPendingInput(from handle: OpaquePointer) throws {
    var input = [UInt8](repeating: 0, count: AgentPadHIDProtocol.reportSize)
    while true {
      let count = input.withUnsafeMutableBufferPointer {
        hid_read_timeout(handle, $0.baseAddress, $0.count, 0)
      }
      if count < 0 {
        closeDevice()
        throw TransportError.io
      }
      if count == 0 { return }
    }
  }

  private func closeDevice() {
    if let handle { hid_close(handle) }
    handle = nil
  }
}
